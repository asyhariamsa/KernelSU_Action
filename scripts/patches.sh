#!/usr/bin/env bash
# Kernel source patching: SUSFS, path_umount backport, hide_stuff, manual hooks.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must point at the kernel source tree}
WORKSPACE=${WORKSPACE:-$(cd "${KERNEL_DIR}/.." && pwd)}
# Resolved from this file's location, not $PWD -- several helpers below run
# with the working directory changed into the kernel tree.
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ====================================================================== SUSFS

# susfs_branch_for KVER -- map a kernel version onto a susfs4ksu branch.
#
# susfs4ksu is branched per kernel version. The GKI branches are named after
# the Android release they ship with; where a kernel version spans two Android
# releases (5.10 -> android12/android13, 5.15 -> android13/android14) we pick
# the older, which is the one the vast majority of trees are based on.
# Override with SUSFS_BRANCH when that guess is wrong.
susfs_branch_for() {
	case "$1" in
		4.9)  echo "kernel-4.9" ;;
		4.14) echo "kernel-4.14" ;;
		4.19) echo "kernel-4.19" ;;
		5.4)  echo "kernel-5.4" ;;
		5.10) echo "gki-android12-5.10" ;;
		5.15) echo "gki-android13-5.15" ;;
		6.1)  echo "gki-android14-6.1" ;;
		6.6)  echo "gki-android15-6.6" ;;
		6.12) echo "gki-android16-6.12" ;;
		*)    echo "" ;;
	esac
}

susfs_apply() {
	local repo=${SUSFS_REPO:-https://gitlab.com/simonpunk/susfs4ksu.git}
	local branch=${SUSFS_BRANCH:-auto}
	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version from ${KERNEL_DIR}/Makefile"

	group "Applying SUSFS"

	if [ "$branch" = "auto" ]; then
		branch=$(susfs_branch_for "$kver")
		[ -n "$branch" ] || die "no susfs4ksu branch is known for kernel ${kver}; set SUSFS_BRANCH explicitly.
       Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"
		info "kernel ${kver} -> susfs branch '${branch}'"
	fi

	ref_exists "$repo" "$branch" \
		|| die "susfs4ksu has no branch '${branch}'.
       Available: $(git ls-remote --heads "$repo" | awk '{print $2}' | sed 's@refs/heads/@@' | tr '\n' ' ')"

	local susfs_dir="${WORKSPACE}/susfs4ksu"
	rm -rf "$susfs_dir"
	retry 3 git clone -q --depth=1 -b "$branch" "$repo" "$susfs_dir" \
		|| die "failed to clone ${repo} @ ${branch}"

	local kp="${susfs_dir}/kernel_patches"
	[ -d "$kp" ] || die "unexpected susfs4ksu layout: ${kp} missing"

	# 1. Drop in the SUSFS sources. The non-GKI branches carry sus_su.c too.
	info "copying SUSFS sources into the kernel tree"
	cp -v "${kp}/fs/"*.c              "${KERNEL_DIR}/fs/"            2>/dev/null || true
	cp -v "${kp}/include/linux/"*.h   "${KERNEL_DIR}/include/linux/" 2>/dev/null || true

	# 2. Patch the kernel itself.
	local kernel_patch="${kp}/50_add_susfs_in_${branch}.patch"
	[ -f "$kernel_patch" ] || {
		# Fall back to whatever 50_* patch the branch actually ships.
		kernel_patch=$(find "$kp" -maxdepth 1 -name '50_add_susfs_in_*.patch' | head -n1)
	}
	[ -n "$kernel_patch" ] && [ -f "$kernel_patch" ] \
		|| die "no 50_add_susfs_in_*.patch found in ${kp}"

	( cd "$KERNEL_DIR" && apply_patch "$kernel_patch" 1 ) \
		|| die "the SUSFS kernel patch did not apply cleanly.
       This usually means SUSFS_BRANCH does not match your kernel. Detected
       kernel ${kver}, used branch '${branch}'."

	# 3. Patch the KernelSU side -- but only when the variant does not already
	#    ship SUSFS support. SukiSU-Ultra's 'builtin' branch, for instance,
	#    declares CONFIG_KSU_SUSFS itself; applying the patch on top conflicts.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	local ksu_patch="${kp}/KernelSU/10_enable_susfs_for_ksu.patch"

	if susfs_is_bundled; then
		info "${KSU_NAME:-the selected variant} already bundles SUSFS at ref '${KSU_REF_RESOLVED:-}'; skipping 10_enable_susfs_for_ksu.patch"
	elif [ ! -d "$ksu_dir" ]; then
		warn "KernelSU directory ${ksu_dir} not found; skipping the KernelSU-side SUSFS patch"
	elif [ ! -f "$ksu_patch" ]; then
		warn "branch ${branch} ships no KernelSU/10_enable_susfs_for_ksu.patch; skipping"
	else
		( cd "$ksu_dir" && apply_patch "$ksu_patch" 1 ) || {
			warn "the KernelSU-side SUSFS patch did not apply."
			warn "susfs4ksu's non-GKI branches were last updated in early 2025 and still"
			warn "target the old flat KernelSU layout; modern forks have since moved to a"
			warn "modular kernel/ tree. Try a variant/ref whose layout matches, or a fork"
			warn "that bundles SUSFS itself (e.g. KSU_VARIANT=sukisu-ultra KSU_REF=builtin)."
			die "SUSFS integration failed"
		}
	fi

	# Record the SUSFS version for the build summary.
	local sv
	sv=$(sed -nE 's/.*SUSFS_VERSION[[:space:]]+"([^"]+)".*/\1/p' \
		"${KERNEL_DIR}/include/linux/susfs.h" 2>/dev/null | head -n1)
	export_env SUSFS_VERSION "${sv:-unknown}"
	export_env SUSFS_BRANCH_RESOLVED "$branch"
	ok "SUSFS ${sv:-?} applied from branch ${branch}"
	summary "| SUSFS | \`${sv:-unknown}\` (branch \`${branch}\`) |"
	endgroup
}

# Does the selected variant+ref already contain SUSFS?
susfs_is_bundled() {
	local bundled=${KSU_SUSFS_BUNDLED_REFS:--} ref=${KSU_REF_RESOLVED:-}
	[ "$bundled" = "-" ] && return 1
	local r
	for r in $bundled; do
		[ "$r" = "$ref" ] && return 0
	done
	# Fall back to inspecting the tree, which is authoritative.
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"
	[ -d "$ksu_dir" ] && grep -rqs 'CONFIG_KSU_SUSFS\|config KSU_SUSFS' "${ksu_dir}/kernel/Kconfig" 2>/dev/null
}

susfs_defconfig() {
	local defconfig=$1
	local ksu_dir="${KERNEL_DIR}/${KSU_DIR:-KernelSU}"

	# The SUSFS option set is NOT stable across branches, so it is discovered
	# from the Kconfig that was actually patched in rather than hardcoded.
	#
	# Concretely: the GKI branches ship SUSFS v2.x, which declares SUS_MAP and
	# has dropped the AUTO_ADD_*/SUS_OVERLAYFS/HAS_MAGIC_MOUNT knobs. The
	# non-GKI branches are still on v1.5.5 (last touched early 2025), which is
	# the exact opposite: it has the AUTO_ADD_* family and no SUS_MAP. A
	# hardcoded list is therefore wrong on one side or the other -- and wrong
	# in the silent direction, since an unknown symbol in a defconfig is simply
	# dropped, leaving the feature off with no warning.
	local syms
	syms=$(grep -rhoE '^[[:space:]]*config[[:space:]]+KSU_SUSFS[A-Z_]*' \
			"$ksu_dir" "${KERNEL_DIR}/fs/Kconfig" "${KERNEL_DIR}/drivers/kernelsu" 2>/dev/null \
		| awk '{print $2}' | sort -u)

	if [ -z "$syms" ]; then
		die "found no KSU_SUSFS Kconfig symbols to enable.
       The SUSFS sources are in the tree but nothing declares its options, so
       the feature would silently compile out and you would ship a kernel that
       looks patched but hides nothing. Check that the KernelSU-side patch
       applied, or pick a variant that bundles SUSFS."
	fi

	local s enabled=0
	for s in $syms; do
		case "$s" in
			# sus_su is the legacy in-kernel su backend, superseded by the
			# manager; overlayfs hiding conflicts with magic mount. Both are
			# off in the reference builds.
			KSU_SUSFS_SUS_SU | KSU_SUSFS_SUS_OVERLAYFS)
				kconf_disable "$defconfig" "CONFIG_${s}" ;;
			*)
				kconf_enable "$defconfig" "CONFIG_${s}"; enabled=$((enabled + 1)) ;;
		esac
	done
	ok "enabled ${enabled} SUSFS options discovered from Kconfig"
	debug "SUSFS symbols: $(printf '%s ' $syms)"
}

# =============================================================== path_umount

# path_umount() landed upstream in Linux 5.9. KernelSU uses it to unmount its
# own overlays before handing control to an app that is checking for root, so
# on older trees it has to be backported or module unmounting silently no-ops.
#
# The body below is upstream's, unchanged. It is inserted immediately before
# the comment that introduces the umount syscall, which puts it after
# do_umount() -- its only forward dependency -- in every tree from 4.9 to 5.4.
path_umount_apply() {
	local ns="${KERNEL_DIR}/fs/namespace.c"
	group "Backporting path_umount()"

	local kver
	kver=$(kernel_version "$KERNEL_DIR") || die "cannot read kernel version"

	if ver_ge "$kver" "5.9"; then
		info "kernel ${kver} already provides path_umount() upstream; nothing to do"
		endgroup; return 0
	fi
	[ -f "$ns" ] || die "fs/namespace.c not found"

	if grep -q '^int path_umount\|^static int path_umount' "$ns"; then
		info "path_umount() is already present in fs/namespace.c; nothing to do"
		endgroup; return 0
	fi

	local anchor='Now umount can handle mount points as well as block devices'
	grep -q "$anchor" "$ns" \
		|| die "could not find the insertion point in fs/namespace.c; patch this kernel manually"

	local snippet
	snippet=$(mktemp)
	# 'can_umount' is a separate helper upstream; guard it in case a partial
	# backport already added it.
	if ! grep -q 'static int can_umount' "$ns"; then
		cat >>"$snippet" <<'EOF'
static int can_umount(const struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);

	if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
		return -EINVAL;
	if (!may_mount())
		return -EPERM;
	if (path->dentry != path->mnt->mnt_root)
		return -EINVAL;
	if (!check_mnt(mnt))
		return -EINVAL;
	if (mnt->mnt.mnt_flags & MNT_LOCKED) /* Check optimistically */
		return -EINVAL;
	if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
		return -EPERM;
	return 0;
}

EOF
	fi
	cat >>"$snippet" <<'EOF'
int path_umount(struct path *path, int flags)
{
	struct mount *mnt = real_mount(path->mnt);
	int ret;

	ret = can_umount(path, flags);
	if (!ret)
		ret = do_umount(mnt, flags);

	/* we mustn't call path_put() as that would clear mnt_expiry_mark */
	dput(path->dentry);
	mntput_no_expire(mnt);
	return ret;
}

EOF

	# Insert before the line *above* the anchor comment body, i.e. at the '/*'
	# that opens it.
	local lineno
	lineno=$(grep -n "$anchor" "$ns" | head -n1 | cut -d: -f1)
	# Walk back to the opening '/*' of that comment block.
	local start=$lineno
	while [ "$start" -gt 1 ] && ! sed -n "${start}p" "$ns" | grep -q '/\*'; do
		start=$((start - 1))
	done

	local tmp
	tmp=$(mktemp)
	head -n "$((start - 1))" "$ns" >"$tmp"
	cat "$snippet" >>"$tmp"
	tail -n "+${start}" "$ns" >>"$tmp"
	mv "$tmp" "$ns"
	rm -f "$snippet"

	grep -q '^int path_umount' "$ns" || die "path_umount() insertion failed"
	ok "path_umount() backported into fs/namespace.c (kernel ${kver})"
	summary "| path_umount | backported (kernel ${kver}) |"
	endgroup
}

# ============================================================== extra patches

SUKISU_PATCH_REPO=${SUKISU_PATCH_REPO:-https://github.com/ShirkNeko/SukiSU_patch.git}

# Clone the shared patch/tool repo once, on demand.
sukisu_patch_dir() {
	local dir="${WORKSPACE}/SukiSU_patch"
	if [ ! -d "$dir" ]; then
		retry 3 git clone -q --depth=1 "$SUKISU_PATCH_REPO" "$dir" \
			|| die "failed to clone ${SUKISU_PATCH_REPO}"
	fi
	printf '%s' "$dir"
}

# hide_stuff removes the most obvious KernelSU fingerprints from the build.
hide_stuff_apply() {
	group "Applying hide_stuff"
	local dir patch
	dir=$(sukisu_patch_dir)
	patch="${dir}/69_hide_stuff.patch"
	[ -f "$patch" ] || { warn "69_hide_stuff.patch not found in the patch repo; skipping"; endgroup; return 0; }
	( cd "$KERNEL_DIR" && apply_patch "$patch" 1 ) || warn "hide_stuff did not apply cleanly; continuing"
	endgroup
}

# Manual/syscall hook patches for pre-GKI trees, used when the fork expects the
# hooks to already exist in the kernel source rather than hooking via kprobes.
hooks_patch_apply() {
	local variant=${KSU_VARIANT:-none} kver
	kver=$(kernel_version "$KERNEL_DIR") || return 0

	group "Applying manual syscall hooks (kernel ${kver})"

	# ReSukiSU publishes scope-minimised hook patches keyed by kernel version.
	if [ "$variant" = "resukisu" ]; then
		local dir="${WORKSPACE}/ReSukiSU_Patches"
		[ -d "$dir" ] || retry 3 git clone -q --depth=1 \
			https://github.com/ReSukiSU/ReSukiSU_Patches.git "$dir" || true
		local p="${dir}/scope-minimized/kernel-${kver}.patch"
		if [ -f "$p" ]; then
			( cd "$KERNEL_DIR" && apply_patch "$p" 1 ) && { endgroup; return 0; }
		else
			info "ReSukiSU ships no scope-minimized patch for kernel ${kver}"
		fi
	fi

	# SukiSU's patch repo carries per-version hook patches too.
	if [ "$variant" = "sukisu-ultra" ]; then
		local dir p
		dir=$(sukisu_patch_dir)
		for p in "${dir}/${kver}/"*hook*.patch "${dir}/hooks/syscall_hooks.patch"; do
			[ -f "$p" ] || continue
			if ( cd "$KERNEL_DIR" && apply_patch "$p" 1 ); then endgroup; return 0; fi
		done
	fi

	# Fall back to the in-repo sed script, which is what this action shipped
	# historically and still works for the 4.9-5.4 KernelSU 0.9.x hook API.
	info "falling back to the bundled legacy hook script"
	( cd "$KERNEL_DIR" && bash "${REPO_ROOT}/patches/legacy_ksu_hooks.sh" )
	endgroup
}

# ======================================================================== KPM

# SukiSU-Ultra's Kernel Patch Module support needs a post-link step: the
# patch_linux tool rewrites the built Image and emits oImage.
kpm_patch_image() {
	local image=$1
	group "Applying KPM (patch_linux)"
	local dir tool
	dir=$(sukisu_patch_dir)
	tool="${dir}/kpm/patch_linux"
	[ -f "$tool" ] || die "kpm/patch_linux not found in ${SUKISU_PATCH_REPO}"
	chmod +x "$tool"
	( cd "$(dirname "$image")" && "$tool" "$(basename "$image")" ) \
		|| die "patch_linux failed"
	local out
	out="$(dirname "$image")/oImage"
	[ -f "$out" ] || die "patch_linux did not produce oImage"
	mv -f "$out" "$image"
	ok "KPM applied to $(basename "$image")"
	summary "| KPM | applied |"
	endgroup
}

# --------------------------------------------------------------------- main ---

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
	case "${1:-all}" in
		susfs)        susfs_apply ;;
		path_umount)  path_umount_apply ;;
		hide_stuff)   hide_stuff_apply ;;
		hooks)        hooks_patch_apply ;;
		kpm)          kpm_patch_image "$2" ;;
		all)
			# This kernel tree ignores CONFIG_LOCALVERSION in its Makefile;
			# the uname suffix comes from the root localversion file instead.
			# Override it so KERNEL_NAME actually appears in `uname -r`.
			if [ -n "${KERNEL_NAME:-}" ]; then
				printf -- '-%s\n' "$KERNEL_NAME" > "${KERNEL_DIR}/localversion"
				info "localversion set to -${KERNEL_NAME}"
			fi

			# Remove the source tree's per-process uname spoof. Disclosure
			# detects it as "uname spoofing (bpfloader/netbpfload/netd)".
			SYS_C="${KERNEL_DIR}/kernel/sys.c"
			if [ -f "$SYS_C" ] && grep -q '"bpfloader"' "$SYS_C"; then
				python3 - "$SYS_C" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = (
    '\tif (!strncmp(current->comm, "bpfloader", 9) ||\n'
    '\t    !strncmp(current->comm, "netbpfload", 10) ||\n'
    '\t    !strncmp(current->comm, "netd", 4)) {\n'
    '\t\tstrcpy(tmp.release, "5.10.239");\n'
    '\t\tpr_debug("fake uname: %s/%d release=%s\\n",\n'
    '\t\t\t current->comm, current->pid, tmp.release);\n'
    '\t}\n'
)
if old in s:
    open(p, "w").write(s.replace(old, "", 1))
PY
				info "kernel/sys.c: per-process uname spoof removed"
			fi


# ------------------------------------------------------------------ ADIOS ---
# Adaptive Deadline I/O Scheduler, ported from firelzrd/adios 3.3.0 (6.12)
# to Linux 5.4. Kept as a NON-default scheduler: Kyber stays the default, so a
# bad ADIOS run can be recovered by a plain reboot (no reflash needed).
adios_apply() {
	group "Installing ADIOS I/O scheduler (5.4 port)"
	local blk="${KERNEL_DIR}/block"
	[ -d "$blk" ] || die "block/ directory not found"

	python3 - "$blk" <<'PY'
import sys, os, base64
blk = sys.argv[1]

src = base64.b64decode(
    "Ly8gU1BEWC1MaWNlbnNlLUlkZW50aWZpZXI6IEdQTC0yLjAKLyoKICogQWRhcHRpdmUgRGVhZGxpbmUgSS9PIFNjaGVkdWxlciAoQURJT1MpCiAqIENvcHly"
    "aWdodCAoQykgMjAyNSBNYXNhaGl0byBTdXp1a2kKICovCiNpbmNsdWRlIDxsaW51eC9iaW8uaD4KI2luY2x1ZGUgPGxpbnV4L2Jsa2Rldi5oPgojaW5jbHVk"
    "ZSA8bGludXgvY29tcGlsZXIuaD4KI2luY2x1ZGUgPGxpbnV4L2ZzLmg+CiNpbmNsdWRlIDxsaW51eC9pbml0Lmg+CiNpbmNsdWRlIDxsaW51eC9rZXJuZWwu"
    "aD4KI2luY2x1ZGUgPGxpbnV4L21vZHVsZS5oPgojaW5jbHVkZSA8bGludXgvcmJ0cmVlLmg+CiNpbmNsdWRlIDxsaW51eC9zYml0bWFwLmg+CiNpbmNsdWRl"
    "IDxsaW51eC9tZW1wb29sLmg+CiNpbmNsdWRlIDxsaW51eC9zbGFiLmg+CiNpbmNsdWRlIDxsaW51eC90aW1la2VlcGluZy5oPgojaW5jbHVkZSA8bGludXgv"
    "cGVyY3B1Lmg+CiNpbmNsdWRlIDxsaW51eC9zdHJpbmcuaD4KI2luY2x1ZGUgPGxpbnV4L2xpc3Rfc29ydC5oPgojaW5jbHVkZSA8bGludXgvcmN1cGRhdGUu"
    "aD4KCiNpbmNsdWRlIDxsaW51eC9lbGV2YXRvci5oPgojaW5jbHVkZSAiYmxrLmgiCiNpbmNsdWRlICJibGstbXEuaCIKLyogLS0tLSBjaHJvbGxvOiBMaW51"
    "eCA1LjQgY29tcGF0aWJpbGl0eSBzaGltcyAtLS0tICovCmV4dGVybiBib29sIGJsa19tcV9zY2hlZF90cnlfbWVyZ2Uoc3RydWN0IHJlcXVlc3RfcXVldWUg"
    "KnEsIHN0cnVjdCBiaW8gKmJpbywKCQl1bnNpZ25lZCBpbnQgbnJfc2Vncywgc3RydWN0IHJlcXVlc3QgKiptZXJnZWRfcmVxdWVzdCk7Cgp0eXBlZGVmIHVu"
    "c2lnbmVkIGludCBibGtfaW5zZXJ0X3Q7CiNkZWZpbmUgQkxLX01RX0lOU0VSVF9BVF9IRUFECTAKCi8qIDUuNCBoYXMgbm8gYmxrX21xX3NjaGVkX3RyeV9p"
    "bnNlcnRfbWVyZ2UoKTsga2VlcGluZyByZXF1ZXN0LXJlcXVlc3QgbWVyZ2luZwogKiBkaXNhYmxlZCBvbmx5IGNvc3RzIGEgbGl0dGxlIHRocm91Z2hwdXQs"
    "IGNvcnJlY3RuZXNzIGlzIHVuY2hhbmdlZC4gKi8Kc3RhdGljIGlubGluZSBib29sIGFkaW9zX3RyeV9pbnNlcnRfbWVyZ2Uoc3RydWN0IHJlcXVlc3RfcXVl"
    "dWUgKnEsCgkJc3RydWN0IHJlcXVlc3QgKnJxLCBzdHJ1Y3QgbGlzdF9oZWFkICpmcmVlKQp7CglyZXR1cm4gZmFsc2U7Cn0KCnN0YXRpYyBpbmxpbmUgdm9p"
    "ZCBhZGlvc19mcmVlX3JlcXVlc3RzKHN0cnVjdCBsaXN0X2hlYWQgKmxpc3QpCnsKCXN0cnVjdCByZXF1ZXN0ICpycSwgKnRtcDsKCWxpc3RfZm9yX2VhY2hf"
    "ZW50cnlfc2FmZShycSwgdG1wLCBsaXN0LCBxdWV1ZWxpc3QpCgkJYmxrX21xX2ZyZWVfcmVxdWVzdChycSk7Cn0KCnN0cnVjdCBhZGlvc19ndWFyZF9zcGlu"
    "bG9ja19pcnFzYXZlIHsKCXNwaW5sb2NrX3QgKmxvY2s7Cgl1bnNpZ25lZCBsb25nIGZsYWdzOwp9OwoKc3RhdGljIGlubGluZSBzdHJ1Y3QgYWRpb3NfZ3Vh"
    "cmRfc3BpbmxvY2tfaXJxc2F2ZQphZGlvc19ndWFyZF9zcGlubG9ja19pcnFzYXZlX2luaXQoc3BpbmxvY2tfdCAqbG9jaykKewoJc3RydWN0IGFkaW9zX2d1"
    "YXJkX3NwaW5sb2NrX2lycXNhdmUgZzsKCglnLmxvY2sgPSBsb2NrOwoJc3Bpbl9sb2NrX2lycXNhdmUobG9jaywgZy5mbGFncyk7CglyZXR1cm4gZzsKfQoK"
    "c3RhdGljIGlubGluZSB2b2lkCmFkaW9zX2d1YXJkX3NwaW5sb2NrX2lycXNhdmVfZmluaShzdHJ1Y3QgYWRpb3NfZ3VhcmRfc3BpbmxvY2tfaXJxc2F2ZSAq"
    "ZykKewoJc3Bpbl91bmxvY2tfaXJxcmVzdG9yZShnLT5sb2NrLCBnLT5mbGFncyk7Cn0KCiNkZWZpbmUgQURJT1NfR1VBUkRfQ0FUMihhLCBiKSBhIyNiCiNk"
    "ZWZpbmUgQURJT1NfR1VBUkRfQ0FUKGEsIGIpIEFESU9TX0dVQVJEX0NBVDIoYSwgYikKCi8qIGFkaW9zX2d1YXJkKHNwaW5sb2NrX2lycXNhdmUpKCZsb2Nr"
    "KSAqLwojZGVmaW5lIGFkaW9zX2d1YXJkKC4uLikgQURJT1NfR1VBUkRfQ0FUKGFkaW9zX2d1YXJkXywgX19WQV9BUkdTX18pCiNkZWZpbmUgYWRpb3NfZ3Vh"
    "cmRfc3BpbmxvY2tfaXJxc2F2ZShsb2NrKSBcCglzdHJ1Y3QgYWRpb3NfZ3VhcmRfc3BpbmxvY2tfaXJxc2F2ZSBcCgkJX19hdHRyaWJ1dGVfXygoY2xlYW51"
    "cChhZGlvc19ndWFyZF9zcGlubG9ja19pcnFzYXZlX2ZpbmkpKSkgXAoJCUFESU9TX0dVQVJEX0NBVChhZG9zX2d1YXJkXywgX19MSU5FX18pID0gXAoJCWFk"
    "aW9zX2d1YXJkX3NwaW5sb2NrX2lycXNhdmVfaW5pdChsb2NrKQoKLyogYWRpb3Nfc2NvcGVkX2d1YXJkKHNwaW5sb2NrX2lycXNhdmUsICZsb2NrKSB7IC4u"
    "LiB9ICovCiNkZWZpbmUgYWRpb3Nfc2NvcGVkX2d1YXJkKHR5cGUsIGxvY2spIFwKCWZvciAoc3RydWN0IGFkaW9zX2d1YXJkX3NwaW5sb2NrX2lycXNhdmUg"
    "YWRvc19zZ3VhcmRfXyA9IFwKCQkJYWRpb3NfZ3VhcmRfc3BpbmxvY2tfaXJxc2F2ZV9pbml0KGxvY2spOyBcCgkgICAgIGFkb3Nfc2d1YXJkX18ubG9jazsg"
    "XAoJICAgICAoc3Bpbl91bmxvY2tfaXJxcmVzdG9yZShhZG9zX3NndWFyZF9fLmxvY2ssIGFkb3Nfc2d1YXJkX18uZmxhZ3MpLCBcCgkgICAgICBhZG9zX3Nn"
    "dWFyZF9fLmxvY2sgPSBOVUxMKSkKCgojZGVmaW5lIEFESU9TX1ZFUlNJT04gIjMuMy4wIgoKLyogUmVxdWVzdCBUeXBlczoKICoKICogVGllciAwIChIaWdo"
    "ZXN0IFByaW9yaXR5KTogRW1lcmdlbmN5ICYgU3lzdGVtIEludGVncml0eSBSZXF1ZXN0cwogKiAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t"
    "LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogKiAtIFRhcmdldDogUmVxdWVzdHMgd2l0aCB0aGUgQkxLX01RX0lOU0VSVF9BVF9IRUFEIGZsYWcu"
    "CiAqIC0gUHVycG9zZTogRm9yIGNyaXRpY2FsLCBub24tbmVnb3RpYWJsZSBvcGVyYXRpb25zIHN1Y2ggYXMgZGV2aWNlIGVycm9yCiAqICAgcmVjb3Zlcnkg"
    "b3IgZmx1c2ggc2VxdWVuY2VzIHRoYXQgbXVzdCBieXBhc3MgYWxsIG90aGVyIHNjaGVkdWxpbmcgbG9naWMuCiAqIC0gSW1wbGVtZW50YXRpb246IFBsYWNl"
    "ZCBpbiBhIGRlZGljYXRlZCwgaGlnaC1wcmlvcml0eSBGSUZPIHF1ZXVlCiAqICAgKGBwcmlvX3F1ZXVlWzBdYCkgZm9yIGltbWVkaWF0ZSBkaXNwYXRjaC4K"
    "ICoKICogVGllciAxIChNZWRpdW0gUHJpb3JpdHkpOiBBcHBsaWNhdGlvbiBSZXNwb25zaXZlbmVzcwogKiAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t"
    "LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAqIC0gVGFyZ2V0OiBOb3JtYWwgc3luY2hyb25vdXMgcmVxdWVzdHMgKGUuZy4sIGZyb20gc3RhbmRhcmQgZmls"
    "ZSByZWFkcykuCiAqIC0gUHVycG9zZTogVG8gZW5zdXJlIGNvcnJlY3QgYXBwbGljYXRpb24gYmVoYXZpb3IgZm9yIG9wZXJhdGlvbnMgdGhhdAogKiAgIGRl"
    "cGVuZCBvbiBzZXF1ZW50aWFsIEkvTyBjb21wbGV0aW9uIChlLmcuLCBmaWxlIHN5c3RlbSBtb3VudHMpIGFuZCB0bwogKiAgIHByb3ZpZGUgbG93IGxhdGVu"
    "Y3kgZm9yIGludGVyYWN0aXZlIGFwcGxpY2F0aW9ucy4KICogLSBJbXBsZW1lbnRhdGlvbjogVGhlIGRlYWRsaW5lIGZvciB0aGVzZSByZXF1ZXN0cyBpcyBz"
    "ZXQgdG8gdGhlaXIgc3RhcnQKICogICB0aW1lIChgcnEtPnN0YXJ0X3RpbWVfbnNgKS4gVGhpcyBlZmZlY3RpdmVseSBlbmZvcmNlcyBGSUZPLWxpa2UgYmVo"
    "YXZpb3IKICogICB3aXRoaW4gdGhlIGRlYWRsaW5lLXNvcnRlZCByZWQtYmxhY2sgdHJlZSwgcHJldmVudGluZyBvdXQtb2Ytb3JkZXIKICogICBleGVjdXRp"
    "b24gb2YgZGVwZW5kZW50IHN5bmNocm9ub3VzIG9wZXJhdGlvbnMuCiAqCiAqIFRpZXIgMiAoTm9ybWFsIFByaW9yaXR5KTogQmFja2dyb3VuZCBUaHJvdWdo"
    "cHV0CiAqIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAqIC0gVGFyZ2V0OiBBc3luY2hyb25vdXMgcmVxdWVzdHMu"
    "CiAqIC0gUHVycG9zZTogVG8gbWF4aW1pemUgZGlzayB0aHJvdWdocHV0IGZvciBiYWNrZ3JvdW5kIHRhc2tzIHdoZXJlIGxhdGVuY3kKICogICBpcyBub3Qg"
    "Y3JpdGljYWwuCiAqIC0gSW1wbGVtZW50YXRpb246IFRoZXNlIGFyZSB0aGUgb25seSByZXF1ZXN0cyB3aGVyZSBBRElPUydzIGFkYXB0aXZlCiAqICAgbGF0"
    "ZW5jeSBwcmVkaWN0aW9uIG1vZGVsIGlzIHVzZWQuIEEgZHluYW1pYyBkZWFkbGluZSBpcyBjYWxjdWxhdGVkIGJhc2VkCiAqICAgb24gdGhlIHByZWRpY3Rl"
    "ZCBJL08gbGF0ZW5jeSwgYWxsb3dpbmcgZm9yIGFnZ3Jlc3NpdmUgcmVvcmRlcmluZyB0bwogKiAgIG9wdGltaXplIEkvTyBlZmZpY2llbmN5LgogKgogKiBJ"
    "L08gYmFycmllciBndWFyYW50ZWVzIChSRVFfUFJFRkxVU0ggLyBSRVFfRlVBKSBhcmUgcHJvdmlkZWQgZW50aXJlbHkgYnkKICogdGhlIGJsb2NrIGxheWVy"
    "J3MgZmx1c2ggc3RhdGUgbWFjaGluZSAoYmxvY2svYmxrLWZsdXNoLmMpLCB3aGljaCBpcyB0aGUKICogbWVjaGFuaXNtIHRoYXQgcmVwbGFjZWQgd2hvbGUt"
    "cXVldWUgYmFycmllcnMgdXBzdHJlYW0gaW4gMi42LjM3LiBObwogKiBxdWV1ZS13aWRlIGJhcnJpZXIgaXMgaW1wbGVtZW50ZWQgb3IgbmVlZGVkIGhlcmU6"
    "CiAqIC0gYmxrX2luc2VydF9mbHVzaCgpIGFsd2F5cyBzdHJpcHMgUkVRX1BSRUZMVVNIIChhbmQgUkVRX0ZVQSB1bmxlc3MgdGhlCiAqICAgZGV2aWNlIHN1"
    "cHBvcnRzIGl0IGluIGhhcmR3YXJlKSBiZWZvcmUgYW55IHJlcXVlc3QgZXZlciByZWFjaGVzIHRoaXMKICogICBlbGV2YXRvcidzIC0+aW5zZXJ0X3JlcXVl"
    "c3RzKCksIGFuZCBhbHdheXMgc2V0cyBSRVFfU1lOQyBvbiBpdCwgc28gc3VjaAogKiAgIGEgcmVxdWVzdCBsYW5kcyBpbiBUaWVyIDEgKGltbWVkaWF0ZSBk"
    "ZWFkbGluZSkgbGlrZSBhbnkgb3RoZXIKICogICBzeW5jaHJvbm91cyByZXF1ZXN0IC0tIG5ldmVyIGRlbGF5ZWQgYmVoaW5kIFRpZXIgMiByZW9yZGVyaW5n"
    "LgogKiAtIFRoZSBkYXRhIHBvcnRpb24gb2YgYSByZXF1ZXN0IHRoYXQgbmVlZGVkIGFuIGFjdHVhbCBQUkVGTFVTSCBpcwogKiAgIHJlc3VibWl0dGVkIHZp"
    "YSBCTEtfTVFfSU5TRVJUX0FUX0hFQUQgb25jZSB0aGUgZmx1c2ggY29tcGxldGVzLCB3aGljaAogKiAgIGxhbmRzIGluIFRpZXIgMCBoZXJlLCBhaGVhZCBv"
    "ZiBldmVyeXRoaW5nIGVsc2UuCiAqIC0gUkVRX1BSRUZMVVNIL1JFUV9GVUEgYW5kIFJRRl9GTFVTSF9TRVEgcmVxdWVzdHMgYXJlIGFscmVhZHkgZXhjbHVk"
    "ZWQKICogICBmcm9tIGJpby9yZXF1ZXN0IG1lcmdpbmcgYnkgdGhlIGdlbmVyaWMgYmxvY2sgbGF5ZXIgKHJxX21lcmdlYWJsZSgpLAogKiAgIGJsa19ycV9t"
    "ZXJnZV9vaygpKSBiZWZvcmUgdGhpcyBlbGV2YXRvcidzIG1lcmdlIGNhbGxiYWNrcyBldmVyIHJ1bi4KICogLSBUaGUgc3ludGhlc2l6ZWQgcHVyZSBSRVFf"
    "T1BfRkxVU0ggY29tbWFuZCBpdHNlbGYgYWx3YXlzIGJ5cGFzc2VzIHRoaXMKICogICBlbGV2YXRvciBlbnRpcmVseSAoYmxrX21xX2luc2VydF9yZXF1ZXN0"
    "KCkgcm91dGVzIGl0IHN0cmFpZ2h0IHRvCiAqICAgaGN0eC0+ZGlzcGF0Y2gpLCBzbyBpdCBuZXZlciBuZWVkcyB0byBiZSByZWNvZ25pemVkIG9yIGhhbmRs"
    "ZWQgaGVyZS4KICoKICogRGlzcGF0Y2ggTG9naWM6CiAqIFRoZSBzY2hlZHVsZXIgYWx3YXlzIGRpc3BhdGNoZXMgcmVxdWVzdHMgaW4gc3RyaWN0IHByaW9y"
    "aXR5IG9yZGVyOgogKiAxLiBwcmlvX3F1ZXVlWzBdIChUaWVyIDApCiAqIDIuIFRoZSBkZWFkbGluZS1zb3J0ZWQgYmF0Y2ggcXVldWUgKHdoaWNoIG5hdHVy"
    "YWxseSBwcmlvcml0aXplcyBUaWVyIDEKICogICAgb3ZlciBUaWVyIDIgZHVlIHRvIHRoZWlyIGNhbGN1bGF0ZWQgZGVhZGxpbmVzKS4KICovCgovLyBHbG9i"
    "YWwgdmFyaWFibGUgdG8gY29udHJvbCB0aGUgbGF0ZW5jeQpzdGF0aWMgdTY0IGRlZmF1bHRfZ2xvYmFsX2xhdGVuY3lfd2luZG93ICAgICAgICAgICAgPSAx"
    "NjAwMDAwMFVMTDsKc3RhdGljIHU2NCBkZWZhdWx0X2dsb2JhbF9sYXRlbmN5X3dpbmRvd19yb3RhdGlvbmFsID0gMjIwMDAwMDBVTEw7Ci8vIFJhdGlvIGJl"
    "bG93IHdoaWNoIGJhdGNoIHF1ZXVlcyBzaG91bGQgYmUgcmVmaWxsZWQKc3RhdGljIHU4ICBkZWZhdWx0X2JxX3JlZmlsbF9iZWxvd19yYXRpbyA9IDIwOwov"
    "LyBNYXhpbXVtIGxhdGVuY3kgc2FtcGxlIHRvIGlucHV0CnN0YXRpYyB1NjQgZGVmYXVsdF9sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCA9IDUwMCAqIE5TRUNf"
    "UEVSX01TRUM7Ci8vIEJhdGNoIG9yZGVyaW5nIHN0cmF0ZWd5CnN0YXRpYyB1NjQgZGVmYXVsdF9iYXRjaF9vcmRlciA9IDA7CgovKiBDb21wbGlhbmNlIEZs"
    "YWdzOgogKiAweDE6IEFzeW5jIHJlcXVlc3RzIHdpbGwgbm90IGJlIHJlb3JkZXJlZCBiYXNlZCBvbiB0aGUgcHJlZGljdGVkIGxhdGVuY3kKICovCmVudW0g"
    "YWRpb3NfY29tcGxpYW5jZV9mbGFncyB7CglBRElPU19DRl9GSVhPUkRFUiAgPSAxVSA8PCAwLAp9OwoKLy8gRmxhZ3MgdG8gY29udHJvbCBjb21wbGlhbmNl"
    "IHdpdGggYmxvY2sgbGF5ZXIgY29uc3RyYWludHMKc3RhdGljIHU2NCBkZWZhdWx0X2NvbXBsaWFuY2VfZmxhZ3MgPSAweDA7CgovLyBEeW5hbWljIHRocmVz"
    "aG9sZHMgZm9yIHNocmlua2FnZQpzdGF0aWMgdTMyIGRlZmF1bHRfbG1fc2hyaW5rX2F0X2tyZXFzICA9ICA1MDAwOwpzdGF0aWMgdTMyIGRlZmF1bHRfbG1f"
    "c2hyaW5rX2F0X2dieXRlcyA9ICAgIDUwOwpzdGF0aWMgdTMyIGRlZmF1bHRfbG1fc2hyaW5rX3Jlc2lzdCAgICA9ICAgICAyOwoKZW51bSBhZGlvc19vcHR5"
    "cGUgewoJQURJT1NfUkVBRCAgICA9IDAsCglBRElPU19XUklURSAgID0gMSwKCUFESU9TX0RJU0NBUkQgPSAyLAoJQURJT1NfT1RIRVIgICA9IDMsCglBRElP"
    "U19PUFRZUEVTID0gNCwKfTsKCi8vIExhdGVuY3kgdGFyZ2V0cyBmb3IgZWFjaCBvcGVyYXRpb24gdHlwZQpzdGF0aWMgdTY0IGRlZmF1bHRfbGF0ZW5jeV90"
    "YXJnZXRbQURJT1NfT1BUWVBFU10gPSB7CglbQURJT1NfUkVBRF0gICAgPSAgICAgMlVMTCAqIE5TRUNfUEVSX01TRUMsCglbQURJT1NfV1JJVEVdICAgPSAg"
    "MjAwMFVMTCAqIE5TRUNfUEVSX01TRUMsCglbQURJT1NfRElTQ0FSRF0gPSAgODAwMFVMTCAqIE5TRUNfUEVSX01TRUMsCglbQURJT1NfT1RIRVJdICAgPSAg"
    "ICAgMFVMTCAqIE5TRUNfUEVSX01TRUMsCn07CgovLyBNYXhpbXVtIGJhdGNoIHNpemUgbGltaXRzIGZvciBlYWNoIG9wZXJhdGlvbiB0eXBlCnN0YXRpYyB1"
    "MzIgZGVmYXVsdF9iYXRjaF9saW1pdFtBRElPU19PUFRZUEVTXSA9IHsKCVtBRElPU19SRUFEXSAgICA9IDM2LAoJW0FESU9TX1dSSVRFXSAgID0gNzIsCglb"
    "QURJT1NfRElTQ0FSRF0gPSAgMSwKCVtBRElPU19PVEhFUl0gICA9ICAxLAp9OwoKZW51bSBhZGlvc19iYXRjaF9vcmRlciB7CglBRElPU19CT19PUFRZUEUg"
    "ICA9IDAsCglBRElPU19CT19FTEVWQVRPUiA9IDEsCn07CgovLyBUaHJlc2hvbGRzIGZvciBsYXRlbmN5IG1vZGVsIGNvbnRyb2wKI2RlZmluZSBMTV9CTE9D"
    "S19TSVpFX1RIUkVTSE9MRCA0MDk2CiNkZWZpbmUgTE1fU0FNUExFU19USFJFU0hPTEQgICAgMTAyNAojZGVmaW5lIExNX0lOVEVSVkFMX1RIUkVTSE9MRCAg"
    "IDE1MDAKI2RlZmluZSBMTV9PVVRMSUVSX1BFUkNFTlRJTEUgICAgIDk5CiNkZWZpbmUgTE1fTEFUX0JVQ0tFVF9DT1VOVCAgICAgICA2NAoKI2RlZmluZSBB"
    "RElPU19QUV9MRVZFTFMgMgojZGVmaW5lIEFESU9TX0RMX1RZUEVTICAyCiNkZWZpbmUgQURJT1NfQlFfUEFHRVMgIDIKCnN0YXRpYyB1MzIgZGVmYXVsdF9k"
    "bF9wcmlvW0FESU9TX0RMX1RZUEVTXSA9IHs4LCAwfTsKCi8vIEJpdCBmbGFncyBmb3IgdGhlIGF0b21pYyBzdGF0ZSB2YXJpYWJsZSwgaW5kaWNhdGluZyB3"
    "aGljaCBxdWV1ZXMgaGF2ZSByZXF1ZXN0cy4KZW51bSBhZGlvc19zdGF0ZV9mbGFncyB7CglBRElPU19TVEFURV9QUV8wICAgICAgPSAxVSA8PCAwLAoJQURJ"
    "T1NfU1RBVEVfUFFfMSAgICAgID0gMVUgPDwgMSwKCUFESU9TX1NUQVRFX0RMXzAgICAgICA9IDFVIDw8IDIsCglBRElPU19TVEFURV9ETF8xICAgICAgPSAx"
    "VSA8PCAzLAoJQURJT1NfU1RBVEVfQlFfUEFHRV8wID0gMVUgPDwgNCwKCUFESU9TX1NUQVRFX0JRX1BBR0VfMSA9IDFVIDw8IDUsCn07CiNkZWZpbmUgQURJ"
    "T1NfU1RBVEVfUFEgMAojZGVmaW5lIEFESU9TX1NUQVRFX0RMIDIKI2RlZmluZSBBRElPU19TVEFURV9CUSA0CgovLyBUZW1wb3JhbCBncmFudWxhcml0eSBv"
    "ZiB0aGUgZGVhZGxpbmUgdHJlZSBub2RlIChkbF9ncm91cCkKI2RlZmluZSBBRElPU19RVUFOVFVNX1NISUZUIDIwCgojZGVmaW5lIEFESU9TX01BWF9JTlNF"
    "UlRTX1BFUl9MT0NLIDcyCiNkZWZpbmUgQURJT1NfTUFYX0RFTEVURVNfUEVSX0xPQ0sgMjQKCi8vIFN0cnVjdHVyZSB0byBob2xkIGxhdGVuY3kgYnVja2V0"
    "IGRhdGEgZm9yIHNtYWxsIHJlcXVlc3RzCnN0cnVjdCBsYXRlbmN5X2J1Y2tldF9zbWFsbCB7Cgl1NjQgd2VpZ2h0ZWRfc3VtX2xhdGVuY3k7Cgl1NjQgc3Vt"
    "X29mX3dlaWdodHM7Cn07CgovLyBTdHJ1Y3R1cmUgdG8gaG9sZCBsYXRlbmN5IGJ1Y2tldCBkYXRhIGZvciBsYXJnZSByZXF1ZXN0cwpzdHJ1Y3QgbGF0ZW5j"
    "eV9idWNrZXRfbGFyZ2UgewoJdTY0IHdlaWdodGVkX3N1bV9sYXRlbmN5OwoJdTY0IHdlaWdodGVkX3N1bV9ibG9ja19zaXplOwoJdTY0IHN1bV9vZl93ZWln"
    "aHRzOwp9OwoKLy8gU3RydWN0dXJlIHRvIGhvbGQgcGVyLWNwdSBidWNrZXRzLCBpbXByb3ZpbmcgZGF0YSBsb2NhbGl0eSBhbmQgY29kZSBjbGFyaXR5Lgpz"
    "dHJ1Y3QgbG1fYnVja2V0cyB7CglzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfc21hbGwgc21hbGxfYnVja2V0W0xNX0xBVF9CVUNLRVRfQ09VTlRdOwoJc3RydWN0"
    "IGxhdGVuY3lfYnVja2V0X2xhcmdlIGxhcmdlX2J1Y2tldFtMTV9MQVRfQlVDS0VUX0NPVU5UXTsKfTsKCi8vIFN0cnVjdHVyZSB0byBob2xkIFJDVS1wcm90"
    "ZWN0ZWQgbGF0ZW5jeSBtb2RlbCBwYXJhbWV0ZXJzCnN0cnVjdCBsYXRlbmN5X21vZGVsX3BhcmFtcyB7Cgl1NjQgYmFzZTsKCXU2NCBzbG9wZTsKCXU2NCBz"
    "bWFsbF9zdW1fZGVsYXk7Cgl1NjQgc21hbGxfY291bnQ7Cgl1NjQgbGFyZ2Vfc3VtX2RlbGF5OwoJdTY0IGxhcmdlX3N1bV9ic2l6ZTsKCXU2NCBsYXN0X3Vw"
    "ZGF0ZV9qaWZmaWVzOwoJc3RydWN0IHJjdV9oZWFkIHJjdTsKfTsKCi8vIFN0cnVjdHVyZSB0byBob2xkIHRoZSBsYXRlbmN5IG1vZGVsIGNvbnRleHQgZGF0"
    "YQpzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCB7CglzcGlubG9ja190IHVwZGF0ZV9sb2NrOwoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zIF9fcmN1ICpwYXJh"
    "bXM7CgoJLy8gUGVyLUNQVSBidWNrZXRzIHRvIGF2b2lkIGxvY2sgY29udGVudGlvbiBvbiB0aGUgY29tcGxldGlvbiBwYXRoCglzdHJ1Y3QgbG1fYnVja2V0"
    "cyBfX3BlcmNwdSAqcGNwdV9idWNrZXRzOwoJLy8gUGVyLUNQVSBzbmFwc2hvdHMgZm9yIGRlbHRhLWJhc2VkIGFnZ3JlZ2F0aW9uIChhY2Nlc3NlZCB1bmRl"
    "ciB1cGRhdGVfbG9jaykKCXN0cnVjdCBsbV9idWNrZXRzIF9fcGVyY3B1ICpwY3B1X3NuYXBzaG90OwoKCXUzMiBsbV9zaHJpbmtfYXRfa3JlcXM7Cgl1MzIg"
    "bG1fc2hyaW5rX2F0X2dieXRlczsKCXU4ICBsbV9zaHJpbmtfcmVzaXN0Owp9OwoKc3RydWN0IGFkaW9zX3BjcHVfY29tcGxldGlvbiB7Cgl1NjQgICAgICBs"
    "YXN0X2NvbXBsZXRlZF90aW1lOwoJc2VjdG9yX3QgbGFzdF9jb21wbGV0ZWRfcG9zOwp9OwoKdW5pb24gYWRpb3NfaW5fZmxpZ2h0X3JxcyB7CglhdG9taWM2"
    "NF90CWF0b21pYzsKCXU2NAkJCXNjYWxhcjsKCXN0cnVjdCB7CgkJdTY0IAljb3VudDogICAgICAgICAgMTY7CgkJdTY0IAl0b3RhbF9wcmVkX2xhdDogNDg7"
    "Cgl9Owp9OwoKLy8gQWRpb3Mgc2NoZWR1bGVyIGRhdGEKc3RydWN0IGFkaW9zX2RhdGEgewoJc3BpbmxvY2tfdCBwcV9sb2NrOwoJc3RydWN0IGxpc3RfaGVh"
    "ZCBwcmlvX3F1ZXVlWzJdOwoKCXN0cnVjdCByYl9yb290X2NhY2hlZCBkbF90cmVlWzJdOwoJc3BpbmxvY2tfdCBsb2NrOwoJczY0IGRsX2JpYXM7CglzMzIg"
    "ZGxfcHJpb1syXTsKCglhdG9taWNfdCBzdGF0ZTsKCXU4ICBicV9zdGF0ZVtBRElPU19CUV9QQUdFU107CgoJYm9vbCBtb2RlbHNfc3RhYmxlOwoKCXU2NCBn"
    "bG9iYWxfbGF0ZW5jeV93aW5kb3c7Cgl1NjQgY29tcGxpYW5jZV9mbGFnczsKCXU2NCBsYXRlbmN5X3RhcmdldFtBRElPU19PUFRZUEVTXTsKCXUzMiBiYXRj"
    "aF9saW1pdFtBRElPU19PUFRZUEVTXTsKCXUzMiBiYXRjaF9hY3R1YWxfbWF4X3NpemVbQURJT1NfT1BUWVBFU107Cgl1MzIgYmF0Y2hfYWN0dWFsX21heF90"
    "b3RhbDsKCXUzMiBhc3luY19kZXB0aDsKCXUzMiBsYXRfbW9kZWxfbGF0ZW5jeV9saW1pdDsKCXU4ICBicV9yZWZpbGxfYmVsb3dfcmF0aW87Cgl1OCAgaXNf"
    "cm90YXRpb25hbDsKCXU4ICBiYXRjaF9vcmRlcjsKCXU4ICBlbHZfZGlyZWN0aW9uOwoJc2VjdG9yX3QgaGVhZF9wb3M7CgoJYm9vbCBicV9wYWdlOwoJc3Ry"
    "dWN0IGxpc3RfaGVhZCBiYXRjaF9xdWV1ZVtBRElPU19CUV9QQUdFU11bQURJT1NfT1BUWVBFU107Cgl1MzIgYmF0Y2hfY291bnRbQURJT1NfQlFfUEFHRVNd"
    "W0FESU9TX09QVFlQRVNdOwoJdTggIGJxX2JhdGNoX29yZGVyW0FESU9TX0JRX1BBR0VTXTsKCXNwaW5sb2NrX3QgYnFfbG9jazsKCglzdHJ1Y3QgbG1fYnVj"
    "a2V0cyAqYWdncl9idWNrZXRzOwoKCXN0cnVjdCBsYXRlbmN5X21vZGVsIGxhdGVuY3lfbW9kZWxbQURJT1NfT1BUWVBFU107CglzdHJ1Y3QgdGltZXJfbGlz"
    "dCB1cGRhdGVfdGltZXI7CgoJdW5pb24gYWRpb3NfaW5fZmxpZ2h0X3JxcyBpbl9mbGlnaHRfcnFzOwoJYXRvbWljNjRfdCB0b3RhbF9wcmVkX2xhdDsKCglz"
    "dHJ1Y3QgYWRpb3NfcGNwdV9jb21wbGV0aW9uIF9fcGVyY3B1ICpwY3B1X2NvbXBsZXRpb247CgoJc3RydWN0IGttZW1fY2FjaGUgKnJxX2RhdGFfY2FjaGU7"
    "CgltZW1wb29sX3QgKnJxX2RhdGFfcG9vbDsKCXN0cnVjdCBrbWVtX2NhY2hlICpkbF9ncm91cF9wb29sOwoKCXN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxdWV1"
    "ZTsKfTsKCi8vIExpc3Qgb2YgcmVxdWVzdHMgd2l0aCB0aGUgc2FtZSBkZWFkbGluZSBpbiB0aGUgZGVhZGxpbmUtc29ydGVkIHRyZWUKc3RydWN0IGRsX2dy"
    "b3VwIHsKCXN0cnVjdCByYl9ub2RlIG5vZGU7CglzdHJ1Y3QgbGlzdF9oZWFkIHJxczsKCXU2NCBkZWFkbGluZTsKfSBfX2F0dHJpYnV0ZV9fKChhbGlnbmVk"
    "KDY0KSkpOwoKLy8gU3RydWN0dXJlIHRvIGhvbGQgc2NoZWR1bGVyLXNwZWNpZmljIGRhdGEgZm9yIGVhY2ggcmVxdWVzdApzdHJ1Y3QgYWRpb3NfcnFfZGF0"
    "YSB7CglzdHJ1Y3QgbGlzdF9oZWFkICpkbF9ncm91cDsKCXN0cnVjdCBsaXN0X2hlYWQgZGxfbm9kZTsKCglzdHJ1Y3QgcmVxdWVzdCAqcnE7Cgl1NjQgZGVh"
    "ZGxpbmU7Cgl1NjQgcHJlZF9sYXQ7Cgl1MzIgYmxvY2tfc2l6ZTsKCWJvb2wgbWFuYWdlZDsKfSBfX2F0dHJpYnV0ZV9fKChhbGlnbmVkKDY0KSkpOwoKc3Rh"
    "dGljIGNvbnN0IGludCBhZGlvc19wcmlvX3RvX3dtdWx0WzQwXSA9IHsKIC8qIC0yMCAqLyAgICAgODg3NjEsICAgICA3MTc1NSwgICAgIDU2NDgzLCAgICAg"
    "NDYyNzMsICAgICAzNjI5MSwKIC8qIC0xNSAqLyAgICAgMjkxNTQsICAgICAyMzI1NCwgICAgIDE4NzA1LCAgICAgMTQ5NDksICAgICAxMTkxNiwKIC8qIC0x"
    "MCAqLyAgICAgIDk1NDgsICAgICAgNzYyMCwgICAgICA2MTAwLCAgICAgIDQ5MDQsICAgICAgMzkwNiwKIC8qICAtNSAqLyAgICAgIDMxMjEsICAgICAgMjUw"
    "MSwgICAgICAxOTkxLCAgICAgIDE1ODYsICAgICAgMTI3NywKIC8qICAgMCAqLyAgICAgIDEwMjQsICAgICAgIDgyMCwgICAgICAgNjU1LCAgICAgICA1MjYs"
    "ICAgICAgIDQyMywKIC8qICAgNSAqLyAgICAgICAzMzUsICAgICAgIDI3MiwgICAgICAgMjE1LCAgICAgICAxNzIsICAgICAgIDEzNywKIC8qICAxMCAqLyAg"
    "ICAgICAxMTAsICAgICAgICA4NywgICAgICAgIDcwLCAgICAgICAgNTYsICAgICAgICA0NSwKIC8qICAxNSAqLyAgICAgICAgMzYsICAgICAgICAyOSwgICAg"
    "ICAgIDIzLCAgICAgICAgMTgsICAgICAgICAxNSwKfTsKCnN0YXRpYyBpbmxpbmUgYm9vbCBjb21wbGlhbnQoc3RydWN0IGFkaW9zX2RhdGEgKmFkLCB1MzIg"
    "ZmxhZykgewoJcmV0dXJuIGFkLT5jb21wbGlhbmNlX2ZsYWdzICYgZmxhZzsKfQoKLy8gQ291bnQgdGhlIG51bWJlciBvZiBlbnRyaWVzIGluIGFnZ3JlZ2F0"
    "ZWQgc21hbGwgYnVja2V0cwpzdGF0aWMgdTY0IGxtX2NvdW50X3NtYWxsX2VudHJpZXMoc3RydWN0IGxhdGVuY3lfYnVja2V0X3NtYWxsICpidWNrZXRzKSB7"
    "Cgl1NjQgdG90YWxfd2VpZ2h0ID0gMDsKCWZvciAodTggaSA9IDA7IGkgPCBMTV9MQVRfQlVDS0VUX0NPVU5UOyBpKyspCgkJdG90YWxfd2VpZ2h0ICs9IGJ1"
    "Y2tldHNbaV0uc3VtX29mX3dlaWdodHM7CglyZXR1cm4gdG90YWxfd2VpZ2h0Owp9CgovLyBVcGRhdGUgdGhlIHNtYWxsIGJ1Y2tldHMgaW4gdGhlIGxhdGVu"
    "Y3kgbW9kZWwgZnJvbSBhZ2dyZWdhdGVkIGRhdGEKc3RhdGljIGJvb2wgbG1fdXBkYXRlX3NtYWxsX2J1Y2tldHMoc3RydWN0IGxhdGVuY3lfbW9kZWwgKm1v"
    "ZGVsLAoJCXN0cnVjdCBsYXRlbmN5X21vZGVsX3BhcmFtcyAqcGFyYW1zLAoJCXN0cnVjdCBsYXRlbmN5X2J1Y2tldF9zbWFsbCAqYnVja2V0cywKCQl1NjQg"
    "dG90YWxfd2VpZ2h0LCBib29sIGNvdW50X2FsbCkgewoJdTY0IHN1bV9sYXRlbmN5ID0gMDsKCXU2NCBzdW1fd2VpZ2h0ID0gMDsKCXU2NCBjdW11bGF0aXZl"
    "X3dlaWdodCA9IDAsIHRocmVzaG9sZF93ZWlnaHQgPSAwOwoJdTggIG91dGxpZXJfdGhyZXNob2xkX2J1Y2tldCA9IDA7Cgl1OCAgb3V0bGllcl9wZXJjZW50"
    "aWxlID0gTE1fT1VUTElFUl9QRVJDRU5USUxFOwoJdTggIHJlZHVjdGlvbjsKCglpZiAoY291bnRfYWxsKQoJCW91dGxpZXJfcGVyY2VudGlsZSA9IDEwMDsK"
    "CgkvLyBDYWxjdWxhdGUgdGhlIHRocmVzaG9sZCB3ZWlnaHQgZm9yIG91dGxpZXIgZGV0ZWN0aW9uCgl0aHJlc2hvbGRfd2VpZ2h0ID0gKHRvdGFsX3dlaWdo"
    "dCAqIG91dGxpZXJfcGVyY2VudGlsZSkgLyAxMDA7CgoJLy8gSWRlbnRpZnkgdGhlIGJ1Y2tldCB0aGF0IGNvcnJlc3BvbmRzIHRvIHRoZSBvdXRsaWVyIHRo"
    "cmVzaG9sZAoJZm9yICh1OCBpID0gMDsgaSA8IExNX0xBVF9CVUNLRVRfQ09VTlQ7IGkrKykgewoJCWN1bXVsYXRpdmVfd2VpZ2h0ICs9IGJ1Y2tldHNbaV0u"
    "c3VtX29mX3dlaWdodHM7CgkJaWYgKGN1bXVsYXRpdmVfd2VpZ2h0ID49IHRocmVzaG9sZF93ZWlnaHQpIHsKCQkJb3V0bGllcl90aHJlc2hvbGRfYnVja2V0"
    "ID0gaTsKCQkJYnJlYWs7CgkJfQoJfQoKCS8vIENhbGN1bGF0ZSB0aGUgYXZlcmFnZSBsYXRlbmN5LCBleGNsdWRpbmcgb3V0bGllcnMKCWZvciAodTggaiA9"
    "IDA7IGogPD0gb3V0bGllcl90aHJlc2hvbGRfYnVja2V0OyBqKyspIHsKCQlzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfc21hbGwgKmJ1Y2tldCA9ICZidWNrZXRz"
    "W2pdOwoJCWlmIChqIDwgb3V0bGllcl90aHJlc2hvbGRfYnVja2V0KSB7CgkJCXN1bV9sYXRlbmN5ICs9IGJ1Y2tldC0+d2VpZ2h0ZWRfc3VtX2xhdGVuY3k7"
    "CgkJCXN1bV93ZWlnaHQgKz0gYnVja2V0LT5zdW1fb2Zfd2VpZ2h0czsKCQl9IGVsc2UgewoJCQkvLyBUaGUgdGhyZXNob2xkIGJ1Y2tldCdzIGNvbnRyaWJ1"
    "dGlvbiBpcyBwcm9wb3J0aW9uYWwKCQkJdTY0IHJlbWFpbmluZ193ZWlnaHQgPQoJCQkJdGhyZXNob2xkX3dlaWdodCAtIChjdW11bGF0aXZlX3dlaWdodCAt"
    "IGJ1Y2tldC0+c3VtX29mX3dlaWdodHMpOwoJCQlpZiAoYnVja2V0LT5zdW1fb2Zfd2VpZ2h0cyA+IDApIHsKCQkJCXN1bV9sYXRlbmN5ICs9IGRpdl91NjQo"
    "YnVja2V0LT53ZWlnaHRlZF9zdW1fbGF0ZW5jeSAqCgkJCQkJcmVtYWluaW5nX3dlaWdodCwgYnVja2V0LT5zdW1fb2Zfd2VpZ2h0cyk7CgkJCQlzdW1fd2Vp"
    "Z2h0ICs9IHJlbWFpbmluZ193ZWlnaHQ7CgkJCX0KCQl9Cgl9CgoJLy8gU2hyaW5rIHRoZSBtb2RlbCBpZiBpdCByZWFjaGVzIGF0IHRoZSByZWFkanVzdG1l"
    "bnQgdGhyZXNob2xkCglpZiAocGFyYW1zLT5zbWFsbF9jb3VudCA+PSAxMDAwVUxMICogbW9kZWwtPmxtX3Nocmlua19hdF9rcmVxcykgewoJCXJlZHVjdGlv"
    "biA9IG1vZGVsLT5sbV9zaHJpbmtfcmVzaXN0OwoJCWlmIChwYXJhbXMtPnNtYWxsX2NvdW50ID4+IHJlZHVjdGlvbikgewoJCQlwYXJhbXMtPnNtYWxsX3N1"
    "bV9kZWxheSAtPSBwYXJhbXMtPnNtYWxsX3N1bV9kZWxheSA+PiByZWR1Y3Rpb247CgkJCXBhcmFtcy0+c21hbGxfY291bnQgICAgIC09IHBhcmFtcy0+c21h"
    "bGxfY291bnQgICAgID4+IHJlZHVjdGlvbjsKCQl9Cgl9CgoJaWYgKCFzdW1fd2VpZ2h0KQoJCXJldHVybiBmYWxzZTsKCgkvLyBBY2N1bXVsYXRlIHRoZSBh"
    "dmVyYWdlIGxhdGVuY3kgaW50byB0aGUgc3RhdGlzdGljcwoJcGFyYW1zLT5zbWFsbF9zdW1fZGVsYXkgKz0gc3VtX2xhdGVuY3k7CglwYXJhbXMtPnNtYWxs"
    "X2NvdW50ICAgICArPSBzdW1fd2VpZ2h0OwoKCXJldHVybiB0cnVlOwp9CgovLyBDb3VudCB0aGUgbnVtYmVyIG9mIGVudHJpZXMgaW4gYWdncmVnYXRlZCBs"
    "YXJnZSBidWNrZXRzCnN0YXRpYyB1NjQgbG1fY291bnRfbGFyZ2VfZW50cmllcyhzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfbGFyZ2UgKmJ1Y2tldHMpIHsKCXU2"
    "NCB0b3RhbF93ZWlnaHQgPSAwOwoJZm9yICh1OCBpID0gMDsgaSA8IExNX0xBVF9CVUNLRVRfQ09VTlQ7IGkrKykKCQl0b3RhbF93ZWlnaHQgKz0gYnVja2V0"
    "c1tpXS5zdW1fb2Zfd2VpZ2h0czsKCXJldHVybiB0b3RhbF93ZWlnaHQ7Cn0KCi8vIFVwZGF0ZSB0aGUgbGFyZ2UgYnVja2V0cyBpbiB0aGUgbGF0ZW5jeSBt"
    "b2RlbCBmcm9tIGFnZ3JlZ2F0ZWQgZGF0YQpzdGF0aWMgYm9vbCBsbV91cGRhdGVfbGFyZ2VfYnVja2V0cyhzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWws"
    "CgkJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXMsCgkJc3RydWN0IGxhdGVuY3lfYnVja2V0X2xhcmdlICpidWNrZXRzLAoJCXU2NCB0b3Rh"
    "bF93ZWlnaHQsIGJvb2wgY291bnRfYWxsKSB7CglzNjQgc3VtX2xhdGVuY3kgPSAwOwoJdTY0IHN1bV9ibG9ja19zaXplID0gMCwgaW50ZXJjZXB0OwoJdTY0"
    "IGN1bXVsYXRpdmVfd2VpZ2h0ID0gMCwgdGhyZXNob2xkX3dlaWdodCA9IDA7Cgl1NjQgc3VtX3dlaWdodCA9IDA7Cgl1OCAgb3V0bGllcl90aHJlc2hvbGRf"
    "YnVja2V0ID0gMDsKCXU4ICBvdXRsaWVyX3BlcmNlbnRpbGUgPSBMTV9PVVRMSUVSX1BFUkNFTlRJTEU7Cgl1OCAgcmVkdWN0aW9uOwoKCWlmIChjb3VudF9h"
    "bGwpCgkJb3V0bGllcl9wZXJjZW50aWxlID0gMTAwOwoKCS8vIENhbGN1bGF0ZSB0aGUgdGhyZXNob2xkIHdlaWdodCBmb3Igb3V0bGllciBkZXRlY3Rpb24K"
    "CXRocmVzaG9sZF93ZWlnaHQgPSAodG90YWxfd2VpZ2h0ICogb3V0bGllcl9wZXJjZW50aWxlKSAvIDEwMDsKCgkvLyBJZGVudGlmeSB0aGUgYnVja2V0IHRo"
    "YXQgY29ycmVzcG9uZHMgdG8gdGhlIG91dGxpZXIgdGhyZXNob2xkCglmb3IgKHU4IGkgPSAwOyBpIDwgTE1fTEFUX0JVQ0tFVF9DT1VOVDsgaSsrKSB7CgkJ"
    "Y3VtdWxhdGl2ZV93ZWlnaHQgKz0gYnVja2V0c1tpXS5zdW1fb2Zfd2VpZ2h0czsKCQlpZiAoY3VtdWxhdGl2ZV93ZWlnaHQgPj0gdGhyZXNob2xkX3dlaWdo"
    "dCkgewoJCQlvdXRsaWVyX3RocmVzaG9sZF9idWNrZXQgPSBpOwoJCQlicmVhazsKCQl9Cgl9CgoJLy8gQ2FsY3VsYXRlIHRoZSBhdmVyYWdlIGxhdGVuY3kg"
    "YW5kIGJsb2NrIHNpemUsIGV4Y2x1ZGluZyBvdXRsaWVycwoJZm9yICh1OCBqID0gMDsgaiA8PSBvdXRsaWVyX3RocmVzaG9sZF9idWNrZXQ7IGorKykgewoJ"
    "CXN0cnVjdCBsYXRlbmN5X2J1Y2tldF9sYXJnZSAqYnVja2V0ID0gJmJ1Y2tldHNbal07CgkJaWYgKGogPCBvdXRsaWVyX3RocmVzaG9sZF9idWNrZXQpIHsK"
    "CQkJc3VtX2xhdGVuY3kgKz0gYnVja2V0LT53ZWlnaHRlZF9zdW1fbGF0ZW5jeTsKCQkJc3VtX2Jsb2NrX3NpemUgKz0gYnVja2V0LT53ZWlnaHRlZF9zdW1f"
    "YmxvY2tfc2l6ZTsKCQkJc3VtX3dlaWdodCArPSBidWNrZXQtPnN1bV9vZl93ZWlnaHRzOwoJCX0gZWxzZSB7CgkJCS8vIFRoZSB0aHJlc2hvbGQgYnVja2V0"
    "J3MgY29udHJpYnV0aW9uIGlzIHByb3BvcnRpb25hbAoJCQl1NjQgcmVtYWluaW5nX3dlaWdodCA9CgkJCQl0aHJlc2hvbGRfd2VpZ2h0IC0gKGN1bXVsYXRp"
    "dmVfd2VpZ2h0IC0gYnVja2V0LT5zdW1fb2Zfd2VpZ2h0cyk7CgkJCWlmIChidWNrZXQtPnN1bV9vZl93ZWlnaHRzID4gMCkgewoJCQkJc3VtX2xhdGVuY3kg"
    "Kz0gZGl2X3U2NChidWNrZXQtPndlaWdodGVkX3N1bV9sYXRlbmN5ICoKCQkJCQlyZW1haW5pbmdfd2VpZ2h0LCBidWNrZXQtPnN1bV9vZl93ZWlnaHRzKTsK"
    "CQkJCXN1bV9ibG9ja19zaXplICs9IGRpdl91NjQoYnVja2V0LT53ZWlnaHRlZF9zdW1fYmxvY2tfc2l6ZSAqCgkJCQkJcmVtYWluaW5nX3dlaWdodCwgYnVj"
    "a2V0LT5zdW1fb2Zfd2VpZ2h0cyk7CgkJCQlzdW1fd2VpZ2h0ICs9IHJlbWFpbmluZ193ZWlnaHQ7CgkJCX0KCQl9Cgl9CgoJaWYgKCFzdW1fd2VpZ2h0KQoJ"
    "CXJldHVybiBmYWxzZTsKCgkvLyBTaHJpbmsgdGhlIG1vZGVsIGlmIGl0IHJlYWNoZXMgYXQgdGhlIHJlYWRqdXN0bWVudCB0aHJlc2hvbGQKCWlmIChwYXJh"
    "bXMtPmxhcmdlX3N1bV9ic2l6ZSA+PSAweDQwMDAwMDAwVUxMICogbW9kZWwtPmxtX3Nocmlua19hdF9nYnl0ZXMpIHsKCQlyZWR1Y3Rpb24gPSBtb2RlbC0+"
    "bG1fc2hyaW5rX3Jlc2lzdDsKCQlpZiAocGFyYW1zLT5sYXJnZV9zdW1fYnNpemUgPj4gcmVkdWN0aW9uKSB7CgkJCXBhcmFtcy0+bGFyZ2Vfc3VtX2RlbGF5"
    "IC09IHBhcmFtcy0+bGFyZ2Vfc3VtX2RlbGF5ID4+IHJlZHVjdGlvbjsKCQkJcGFyYW1zLT5sYXJnZV9zdW1fYnNpemUgLT0gcGFyYW1zLT5sYXJnZV9zdW1f"
    "YnNpemUgPj4gcmVkdWN0aW9uOwoJCX0KCX0KCgkvLyBBY2N1bXVsYXRlIHRoZSBhdmVyYWdlIGRlbGF5IGludG8gdGhlIHN0YXRpc3RpY3MKCWludGVyY2Vw"
    "dCA9IHBhcmFtcy0+YmFzZTsKCWlmIChzdW1fbGF0ZW5jeSA+IGludGVyY2VwdCkKCQlzdW1fbGF0ZW5jeSAtPSBpbnRlcmNlcHQ7CgoJcGFyYW1zLT5sYXJn"
    "ZV9zdW1fZGVsYXkgKz0gc3VtX2xhdGVuY3k7CglwYXJhbXMtPmxhcmdlX3N1bV9ic2l6ZSArPSBzdW1fYmxvY2tfc2l6ZTsKCglyZXR1cm4gdHJ1ZTsKfQoK"
    "c3RhdGljIHZvaWQgcmVzZXRfYnVja2V0cyhzdHJ1Y3QgbG1fYnVja2V0cyAqYnVja2V0cykKeyBtZW1zZXQoYnVja2V0cywgMCwgc2l6ZW9mKCpidWNrZXRz"
    "KSk7IH0KCnN0YXRpYyB2b2lkIGxtX3Jlc2V0X3BjcHVfYnVja2V0cyhzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwpIHsKCWludCBjcHU7Cglmb3JfZWFj"
    "aF9wb3NzaWJsZV9jcHUoY3B1KSB7CgkJcmVzZXRfYnVja2V0cyhwZXJfY3B1X3B0cihtb2RlbC0+cGNwdV9idWNrZXRzLCBjcHUpKTsKCQlyZXNldF9idWNr"
    "ZXRzKHBlcl9jcHVfcHRyKG1vZGVsLT5wY3B1X3NuYXBzaG90LCBjcHUpKTsKCX0KfQoKLy8gVXBkYXRlIHRoZSBsYXRlbmN5IG1vZGVsIHBhcmFtZXRlcnMg"
    "YW5kIHN0YXRpc3RpY3MKc3RhdGljIHZvaWQgbGF0ZW5jeV9tb2RlbF91cGRhdGUoCgkJc3RydWN0IGFkaW9zX2RhdGEgKmFkLCBzdHJ1Y3QgbGF0ZW5jeV9t"
    "b2RlbCAqbW9kZWwpIHsKCXU2NCBub3c7Cgl1NjQgc21hbGxfd2VpZ2h0LCBsYXJnZV93ZWlnaHQ7Cglib29sIHRpbWVfZWxhcHNlZDsKCWJvb2wgc21hbGxf"
    "cHJvY2Vzc2VkID0gZmFsc2UsIGxhcmdlX3Byb2Nlc3NlZCA9IGZhbHNlOwoJc3RydWN0IGxtX2J1Y2tldHMgKmFnZ3IgPSBhZC0+YWdncl9idWNrZXRzOwoJ"
    "c3RydWN0IGxhdGVuY3lfYnVja2V0X3NtYWxsICphc2I7CglzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfbGFyZ2UgKmFsYjsKCXN0cnVjdCBsbV9idWNrZXRzICpw"
    "Y3B1X2IsICpzbmFwOwoJdW5zaWduZWQgbG9uZyBmbGFnczsKCWludCBjcHU7CglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbF9wYXJhbXMgKm9sZF9wYXJhbXMsICpu"
    "ZXdfcGFyYW1zOwoKCXNwaW5fbG9ja19pcnFzYXZlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsKCglvbGRfcGFyYW1zID0gcmN1X2RlcmVmZXJlbmNl"
    "X3Byb3RlY3RlZChtb2RlbC0+cGFyYW1zLAoJCQkJbG9ja2RlcF9pc19oZWxkKCZtb2RlbC0+dXBkYXRlX2xvY2spKTsKCW5ld19wYXJhbXMgPSBrbWVtZHVw"
    "KG9sZF9wYXJhbXMsIHNpemVvZigqbmV3X3BhcmFtcyksIEdGUF9BVE9NSUMpOwoJaWYgKCFuZXdfcGFyYW1zKSB7CgkJc3Bpbl91bmxvY2tfaXJxcmVzdG9y"
    "ZSgmbW9kZWwtPnVwZGF0ZV9sb2NrLCBmbGFncyk7CgkJcmV0dXJuOwoJfQoKCS8vIEFnZ3JlZ2F0ZSBkZWx0YXMgZnJvbSBhbGwgQ1BVcyB1c2luZyBzbmFw"
    "c2hvdC1kZWx0YSBtZXRob2QuCgkvLyBQZXItQ1BVIGNvdW50ZXJzIGluY3JlYXNlIG1vbm90b25pY2FsbHk7IHdlIGNvbXB1dGUgZGVsdGEgPSBjdXJyZW50"
    "IC0gc25hcHNob3QuCglmb3JfZWFjaF9wb3NzaWJsZV9jcHUoY3B1KSB7CgkJcGNwdV9iID0gcGVyX2NwdV9wdHIobW9kZWwtPnBjcHVfYnVja2V0cywgY3B1"
    "KTsKCQlzbmFwICAgPSBwZXJfY3B1X3B0cihtb2RlbC0+cGNwdV9zbmFwc2hvdCwgY3B1KTsKCgkJZm9yICh1OCBpID0gMDsgaSA8IExNX0xBVF9CVUNLRVRf"
    "Q09VTlQ7IGkrKykgewoJCQl1NjQgc3cgID0gcGNwdV9iLT5zbWFsbF9idWNrZXRbaV0uc3VtX29mX3dlaWdodHM7CgkJCXU2NCBzbCAgPSBwY3B1X2ItPnNt"
    "YWxsX2J1Y2tldFtpXS53ZWlnaHRlZF9zdW1fbGF0ZW5jeTsKCQkJdTY0IGRzdyA9IHN3IC0gc25hcC0+c21hbGxfYnVja2V0W2ldLnN1bV9vZl93ZWlnaHRz"
    "OwoJCQl1NjQgZHNsID0gc2wgLSBzbmFwLT5zbWFsbF9idWNrZXRbaV0ud2VpZ2h0ZWRfc3VtX2xhdGVuY3k7CgkJCXNuYXAtPnNtYWxsX2J1Y2tldFtpXS5z"
    "dW1fb2Zfd2VpZ2h0cyA9IHN3OwoJCQlzbmFwLT5zbWFsbF9idWNrZXRbaV0ud2VpZ2h0ZWRfc3VtX2xhdGVuY3kgPSBzbDsKCQkJaWYgKGRzdykgewoJCQkJ"
    "YXNiID0gJmFnZ3ItPnNtYWxsX2J1Y2tldFtpXTsKCQkJCWFzYi0+c3VtX29mX3dlaWdodHMgKz0gZHN3OwoJCQkJYXNiLT53ZWlnaHRlZF9zdW1fbGF0ZW5j"
    "eSArPSBkc2w7CgkJCX0KCgkJCXU2NCBsdyAgPSBwY3B1X2ItPmxhcmdlX2J1Y2tldFtpXS5zdW1fb2Zfd2VpZ2h0czsKCQkJdTY0IGxsICA9IHBjcHVfYi0+"
    "bGFyZ2VfYnVja2V0W2ldLndlaWdodGVkX3N1bV9sYXRlbmN5OwoJCQl1NjQgbGIgID0gcGNwdV9iLT5sYXJnZV9idWNrZXRbaV0ud2VpZ2h0ZWRfc3VtX2Js"
    "b2NrX3NpemU7CgkJCXU2NCBkbHcgPSBsdyAtIHNuYXAtPmxhcmdlX2J1Y2tldFtpXS5zdW1fb2Zfd2VpZ2h0czsKCQkJdTY0IGRsbCA9IGxsIC0gc25hcC0+"
    "bGFyZ2VfYnVja2V0W2ldLndlaWdodGVkX3N1bV9sYXRlbmN5OwoJCQl1NjQgZGxiID0gbGIgLSBzbmFwLT5sYXJnZV9idWNrZXRbaV0ud2VpZ2h0ZWRfc3Vt"
    "X2Jsb2NrX3NpemU7CgkJCXNuYXAtPmxhcmdlX2J1Y2tldFtpXS5zdW1fb2Zfd2VpZ2h0cyA9IGx3OwoJCQlzbmFwLT5sYXJnZV9idWNrZXRbaV0ud2VpZ2h0"
    "ZWRfc3VtX2xhdGVuY3kgPSBsbDsKCQkJc25hcC0+bGFyZ2VfYnVja2V0W2ldLndlaWdodGVkX3N1bV9ibG9ja19zaXplID0gbGI7CgkJCWlmIChkbHcpIHsK"
    "CQkJCWFsYiA9ICZhZ2dyLT5sYXJnZV9idWNrZXRbaV07CgkJCQlhbGItPnN1bV9vZl93ZWlnaHRzICs9IGRsdzsKCQkJCWFsYi0+d2VpZ2h0ZWRfc3VtX2xh"
    "dGVuY3kgKz0gZGxsOwoJCQkJYWxiLT53ZWlnaHRlZF9zdW1fYmxvY2tfc2l6ZSArPSBkbGI7CgkJCX0KCQl9Cgl9CgoJLy8gQ291bnQgdGhlIG51bWJlciBv"
    "ZiBlbnRyaWVzIGluIGFnZ3JlZ2F0ZWQgYnVja2V0cwoJc21hbGxfd2VpZ2h0ID0gbG1fY291bnRfc21hbGxfZW50cmllcyhhZ2dyLT5zbWFsbF9idWNrZXQp"
    "OwoJbGFyZ2Vfd2VpZ2h0ID0gbG1fY291bnRfbGFyZ2VfZW50cmllcyhhZ2dyLT5sYXJnZV9idWNrZXQpOwoKCS8vIFdoZXRoZXIgZW5vdWdoIHRpbWUgaGFz"
    "IGVsYXBzZWQgc2luY2UgdGhlIGxhc3QgdXBkYXRlCglub3cgPSBqaWZmaWVzOwoJdGltZV9lbGFwc2VkID0gdW5saWtlbHkoIW5ld19wYXJhbXMtPmJhc2Up"
    "IHx8CgkJbmV3X3BhcmFtcy0+bGFzdF91cGRhdGVfamlmZmllcyArCgkJbXNlY3NfdG9famlmZmllcyhMTV9JTlRFUlZBTF9USFJFU0hPTEQpIDw9IG5vdzsK"
    "CgkvLyBVcGRhdGUgc21hbGwgYnVja2V0cwoJaWYgKHNtYWxsX3dlaWdodCAmJiAodGltZV9lbGFwc2VkIHx8CgkJCUxNX1NBTVBMRVNfVEhSRVNIT0xEIDw9"
    "IHNtYWxsX3dlaWdodCB8fCAhbmV3X3BhcmFtcy0+YmFzZSkpIHsKCQlzbWFsbF9wcm9jZXNzZWQgPSBsbV91cGRhdGVfc21hbGxfYnVja2V0cyhtb2RlbCwg"
    "bmV3X3BhcmFtcywKCQkJYWdnci0+c21hbGxfYnVja2V0LCBzbWFsbF93ZWlnaHQsICFuZXdfcGFyYW1zLT5iYXNlKTsKCQltZW1zZXQoJmFnZ3ItPnNtYWxs"
    "X2J1Y2tldFswXSwgMCwgc2l6ZW9mKGFnZ3ItPnNtYWxsX2J1Y2tldCkpOwoJfQoJLy8gVXBkYXRlIGxhcmdlIGJ1Y2tldHMKCWlmIChsYXJnZV93ZWlnaHQg"
    "JiYgKHRpbWVfZWxhcHNlZCB8fAoJCQlMTV9TQU1QTEVTX1RIUkVTSE9MRCA8PSBsYXJnZV93ZWlnaHQgfHwgIW5ld19wYXJhbXMtPnNsb3BlKSkgewoJCWxh"
    "cmdlX3Byb2Nlc3NlZCA9IGxtX3VwZGF0ZV9sYXJnZV9idWNrZXRzKG1vZGVsLCBuZXdfcGFyYW1zLAoJCQlhZ2dyLT5sYXJnZV9idWNrZXQsIGxhcmdlX3dl"
    "aWdodCwgIW5ld19wYXJhbXMtPnNsb3BlKTsKCQltZW1zZXQoJmFnZ3ItPmxhcmdlX2J1Y2tldFswXSwgMCwgc2l6ZW9mKGFnZ3ItPmxhcmdlX2J1Y2tldCkp"
    "OwoJfQoKCS8vIFVwZGF0ZSB0aGUgYmFzZSBwYXJhbWV0ZXIgaWYgc21hbGwgYnVja2V0IHdhcyBwcm9jZXNzZWQKCWlmIChzbWFsbF9wcm9jZXNzZWQgJiYg"
    "bGlrZWx5KG5ld19wYXJhbXMtPnNtYWxsX2NvdW50KSkKCQluZXdfcGFyYW1zLT5iYXNlID0gZGl2X3U2NChuZXdfcGFyYW1zLT5zbWFsbF9zdW1fZGVsYXks"
    "CgkJCW5ld19wYXJhbXMtPnNtYWxsX2NvdW50KTsKCgkvLyBVcGRhdGUgdGhlIHNsb3BlIHBhcmFtZXRlciBpZiBsYXJnZSBidWNrZXQgd2FzIHByb2Nlc3Nl"
    "ZAoJaWYgKGxhcmdlX3Byb2Nlc3NlZCAmJiBsaWtlbHkobmV3X3BhcmFtcy0+bGFyZ2Vfc3VtX2JzaXplKSkKCQluZXdfcGFyYW1zLT5zbG9wZSA9IGRpdl91"
    "NjQobmV3X3BhcmFtcy0+bGFyZ2Vfc3VtX2RlbGF5LAoJCQlESVZfUk9VTkRfVVBfVUxMKG5ld19wYXJhbXMtPmxhcmdlX3N1bV9ic2l6ZSwgMTAyNCkpOwoK"
    "CS8vIFVwZGF0ZSBsYXN0IHVwZGF0ZWQgamlmZmllcyBpZiB1cGRhdGUgaGFwcGVuZWQgb3IgdGltZSBoYXMgZWxhcHNlZAoJaWYgKHNtYWxsX3Byb2Nlc3Nl"
    "ZCB8fCBsYXJnZV9wcm9jZXNzZWQgfHwgdGltZV9lbGFwc2VkKQoJCW5ld19wYXJhbXMtPmxhc3RfdXBkYXRlX2ppZmZpZXMgPSBub3c7CgoJcmN1X2Fzc2ln"
    "bl9wb2ludGVyKG1vZGVsLT5wYXJhbXMsIG5ld19wYXJhbXMpOwoJc3Bpbl91bmxvY2tfaXJxcmVzdG9yZSgmbW9kZWwtPnVwZGF0ZV9sb2NrLCBmbGFncyk7"
    "CgoJa2ZyZWVfcmN1KG9sZF9wYXJhbXMsIHJjdSk7Cn0KCi8vIERldGVybWluZSB0aGUgYnVja2V0IGluZGV4IGZvciBhIGdpdmVuIG1lYXN1cmVkIGFuZCBw"
    "cmVkaWN0ZWQgbGF0ZW5jeQpzdGF0aWMgdTggbG1faW5wdXRfYnVja2V0X2luZGV4KHU2NCBtZWFzdXJlZCwgdTY0IHByZWRpY3RlZCkgewoJdTMyIGJ1Y2tl"
    "dF9pbmRleDsKCglpZiAobWVhc3VyZWQgPCBwcmVkaWN0ZWQgKiAyKQoJCWJ1Y2tldF9pbmRleCA9IGRpdl91NjQoKG1lYXN1cmVkICogMjApLCBwcmVkaWN0"
    "ZWQpOwoJZWxzZSBpZiAobWVhc3VyZWQgPCBwcmVkaWN0ZWQgKiA1KQoJCWJ1Y2tldF9pbmRleCA9IGRpdl91NjQoKG1lYXN1cmVkICogMTApLCBwcmVkaWN0"
    "ZWQpICsgMjA7CgllbHNlCgkJYnVja2V0X2luZGV4ID0gZGl2X3U2NCgobWVhc3VyZWQgKiAzKSwgcHJlZGljdGVkKSArIDQwOwoKCWlmIChidWNrZXRfaW5k"
    "ZXggPj0gTE1fTEFUX0JVQ0tFVF9DT1VOVCkKCQlidWNrZXRfaW5kZXggPSBMTV9MQVRfQlVDS0VUX0NPVU5UIC0gMTsKCglyZXR1cm4gKHU4KWJ1Y2tldF9p"
    "bmRleDsKfQoKLy8gSW5wdXQgbGF0ZW5jeSBkYXRhIGludG8gdGhlIGxhdGVuY3kgbW9kZWwKc3RhdGljIHZvaWQgbGF0ZW5jeV9tb2RlbF9pbnB1dChzdHJ1"
    "Y3QgYWRpb3NfZGF0YSAqYWQsCgkJc3RydWN0IGxhdGVuY3lfbW9kZWwgKm1vZGVsLAoJCXUzMiBibG9ja19zaXplLCB1NjQgbGF0ZW5jeSwgdTY0IHByZWRf"
    "bGF0LCB1MzIgd2VpZ2h0KSB7Cgl1bnNpZ25lZCBsb25nIGZsYWdzOwoJdTggYnVja2V0X2luZGV4OwoJc3RydWN0IGxtX2J1Y2tldHMgKmJ1Y2tldHM7Cgl1"
    "NjQgY3VycmVudF9iYXNlOwoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXM7CgoJbG9jYWxfaXJxX3NhdmUoZmxhZ3MpOwoJYnVja2V0cyA9"
    "IHBlcl9jcHVfcHRyKG1vZGVsLT5wY3B1X2J1Y2tldHMsIF9fc21wX3Byb2Nlc3Nvcl9pZCgpKTsKCglyY3VfcmVhZF9sb2NrKCk7CglwYXJhbXMgPSByY3Vf"
    "ZGVyZWZlcmVuY2UobW9kZWwtPnBhcmFtcyk7CgljdXJyZW50X2Jhc2UgPSBwYXJhbXMtPmJhc2U7CglyY3VfcmVhZF91bmxvY2soKTsKCglpZiAoYmxvY2tf"
    "c2l6ZSA8PSBMTV9CTE9DS19TSVpFX1RIUkVTSE9MRCkgewoJCS8vIEhhbmRsZSBzbWFsbCByZXF1ZXN0cwoJCWJ1Y2tldF9pbmRleCA9IGxtX2lucHV0X2J1"
    "Y2tldF9pbmRleChsYXRlbmN5LCBjdXJyZW50X2Jhc2UgPzogMSk7CgoJCWJ1Y2tldHMtPnNtYWxsX2J1Y2tldFtidWNrZXRfaW5kZXhdLnN1bV9vZl93ZWln"
    "aHRzICs9IHdlaWdodDsKCQlidWNrZXRzLT5zbWFsbF9idWNrZXRbYnVja2V0X2luZGV4XS53ZWlnaHRlZF9zdW1fbGF0ZW5jeSArPQoJCQlsYXRlbmN5ICog"
    "d2VpZ2h0OwoKCQlsb2NhbF9pcnFfcmVzdG9yZShmbGFncyk7CgoJCWlmICh1bmxpa2VseSghY3VycmVudF9iYXNlKSkgewoJCQlsYXRlbmN5X21vZGVsX3Vw"
    "ZGF0ZShhZCwgbW9kZWwpOwoJCQlyZXR1cm47CgkJfQoJfSBlbHNlIHsKCQkvLyBIYW5kbGUgbGFyZ2UgcmVxdWVzdHMKCQlpZiAoIWN1cnJlbnRfYmFzZSB8"
    "fCAhcHJlZF9sYXQpIHsKCQkJbG9jYWxfaXJxX3Jlc3RvcmUoZmxhZ3MpOwoJCQlyZXR1cm47CgkJfQoKCQlidWNrZXRfaW5kZXggPSBsbV9pbnB1dF9idWNr"
    "ZXRfaW5kZXgobGF0ZW5jeSwgcHJlZF9sYXQpOwoKCQlidWNrZXRzLT5sYXJnZV9idWNrZXRbYnVja2V0X2luZGV4XS5zdW1fb2Zfd2VpZ2h0cyArPSB3ZWln"
    "aHQ7CgkJYnVja2V0cy0+bGFyZ2VfYnVja2V0W2J1Y2tldF9pbmRleF0ud2VpZ2h0ZWRfc3VtX2xhdGVuY3kgKz0KCQkJbGF0ZW5jeSAqIHdlaWdodDsKCQli"
    "dWNrZXRzLT5sYXJnZV9idWNrZXRbYnVja2V0X2luZGV4XS53ZWlnaHRlZF9zdW1fYmxvY2tfc2l6ZSArPQoJCQlibG9ja19zaXplICogd2VpZ2h0OwoKCQls"
    "b2NhbF9pcnFfcmVzdG9yZShmbGFncyk7Cgl9Cn0KCi8vIFByZWRpY3QgdGhlIGxhdGVuY3kgZm9yIGEgZ2l2ZW4gYmxvY2sgc2l6ZSB1c2luZyB0aGUgbGF0"
    "ZW5jeSBtb2RlbApzdGF0aWMgdTY0IGxhdGVuY3lfbW9kZWxfcHJlZGljdChzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwsIHUzMiBibG9ja19zaXplKSB7"
    "Cgl1NjQgcmVzdWx0OwoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXM7CgoJcmN1X3JlYWRfbG9jaygpOwoJcGFyYW1zID0gcmN1X2RlcmVm"
    "ZXJlbmNlKG1vZGVsLT5wYXJhbXMpOwoKCXJlc3VsdCA9IHBhcmFtcy0+YmFzZTsKCWlmIChibG9ja19zaXplID4gTE1fQkxPQ0tfU0laRV9USFJFU0hPTEQp"
    "CgkJcmVzdWx0ICs9IHBhcmFtcy0+c2xvcGUgKgoJCQlESVZfUk9VTkRfVVBfVUxMKGJsb2NrX3NpemUgLSBMTV9CTE9DS19TSVpFX1RIUkVTSE9MRCwgMTAy"
    "NCk7CgoJcmN1X3JlYWRfdW5sb2NrKCk7CgoJcmV0dXJuIHJlc3VsdDsKfQoKLy8gRGV0ZXJtaW5lIHRoZSB0eXBlIG9mIG9wZXJhdGlvbiBiYXNlZCBvbiBy"
    "ZXF1ZXN0IGZsYWdzCnN0YXRpYyB1OCBhZGlvc19vcHR5cGUoc3RydWN0IHJlcXVlc3QgKnJxKSB7Cglzd2l0Y2ggKHJxLT5jbWRfZmxhZ3MgJiBSRVFfT1Bf"
    "TUFTSykgewoJY2FzZSBSRVFfT1BfUkVBRDoKCQlyZXR1cm4gQURJT1NfUkVBRDsKCWNhc2UgUkVRX09QX1dSSVRFOgoJCXJldHVybiBBRElPU19XUklURTsK"
    "CWNhc2UgUkVRX09QX0RJU0NBUkQ6CgkJcmV0dXJuIEFESU9TX0RJU0NBUkQ7CglkZWZhdWx0OgoJCXJldHVybiBBRElPU19PVEhFUjsKCX0KfQoKc3RhdGlj"
    "IGlubGluZSB1OCBhZGlvc19vcHR5cGVfbm90X3JlYWQoc3RydWN0IHJlcXVlc3QgKnJxKSB7CglyZXR1cm4gKHJxLT5jbWRfZmxhZ3MgJiBSRVFfT1BfTUFT"
    "SykgIT0gUkVRX09QX1JFQUQ7Cn0KCi8vIEhlbHBlciBmdW5jdGlvbiB0byByZXRyaWV2ZSBhZGlvc19ycV9kYXRhIGZyb20gYSByZXF1ZXN0CnN0YXRpYyBp"
    "bmxpbmUgc3RydWN0IGFkaW9zX3JxX2RhdGEgKmdldF9ycV9kYXRhKHN0cnVjdCByZXF1ZXN0ICpycSkgewoJcmV0dXJuIHJxLT5lbHYucHJpdlswXTsKfQoK"
    "c3RhdGljIGlubGluZQp2b2lkIHNldF9hZGlvc19zdGF0ZShzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQsIHUzMiBzaGlmdCwgdTMyIGlkeCwgYm9vbCBmbGFnKSB7"
    "CglpZiAoZmxhZykKCQlhdG9taWNfb3IoMVUgPDwgKGlkeCArIHNoaWZ0KSwgJmFkLT5zdGF0ZSk7CgllbHNlCgkJYXRvbWljX2FuZG5vdCgxVSA8PCAoaWR4"
    "ICsgc2hpZnQpLCAmYWQtPnN0YXRlKTsKfQoKc3RhdGljIGlubGluZSB1MzIgZ2V0X2FkaW9zX3N0YXRlKHN0cnVjdCBhZGlvc19kYXRhICphZCkKeyByZXR1"
    "cm4gYXRvbWljX3JlYWQoJmFkLT5zdGF0ZSk7IH0KCnN0YXRpYyBpbmxpbmUgdTMyIGV2YWxfdGhpc19hZGlvc19zdGF0ZSh1MzIgc3RhdGUsIHUzMiBzaGlm"
    "dCkKeyByZXR1cm4gKHN0YXRlID4+IHNoaWZ0KSAmIDB4MzsgfQoKc3RhdGljIGlubGluZSB1MzIgZXZhbF9hZGlvc19zdGF0ZShzdHJ1Y3QgYWRpb3NfZGF0"
    "YSAqYWQsIHUzMiBzaGlmdCkKeyByZXR1cm4gZXZhbF90aGlzX2FkaW9zX3N0YXRlKGdldF9hZGlvc19zdGF0ZShhZCksIHNoaWZ0KTsgfQoKLy8gQWRkIGEg"
    "cmVxdWVzdCB0byB0aGUgZGVhZGxpbmUtc29ydGVkIHJlZC1ibGFjayB0cmVlCnN0YXRpYyB2b2lkIGFkZF90b19kbF90cmVlKAoJCXN0cnVjdCBhZGlvc19k"
    "YXRhICphZCwgYm9vbCBkbF9pZHgsIHN0cnVjdCByZXF1ZXN0ICpycSkgewoJc3RydWN0IHJiX3Jvb3RfY2FjaGVkICpyb290ID0gJmFkLT5kbF90cmVlW2Rs"
    "X2lkeF07CglzdHJ1Y3QgcmJfbm9kZSAqKmxpbmsgPSAmKHJvb3QtPnJiX3Jvb3QucmJfbm9kZSksICpwYXJlbnQgPSBOVUxMOwoJYm9vbCBsZWZ0bW9zdCA9"
    "IHRydWU7CglzdHJ1Y3QgYWRpb3NfcnFfZGF0YSAqcmQgPSBnZXRfcnFfZGF0YShycSk7CglzdHJ1Y3QgZGxfZ3JvdXAgKmRsZzsKCXU2NCBkZWFkbGluZTsK"
    "CWJvb2wgd2FzX2VtcHR5ID0gUkJfRU1QVFlfUk9PVCgmcm9vdC0+cmJfcm9vdCk7CgoJLyogVGllci0yOiBTeW5jaHJvbm91cyBSZXF1ZXN0cwoJICogLSBO"
    "ZWVkcyB0byBiZSBGSUZPIHdpdGhpbiBhIHNhbWUgb3B0eXBlCgkgKiAtIFJlbGF4ZWQgb3JkZXIgYmV0d2VlbiBkaWZmZXJlbnQgb3B0eXBlcwoJICogLSBi"
    "YXNpY2FsbHkgbmVlZHMgdG8gYmUgcHJvY2Vzc2VkIGluIGVhcmx5IHRpbWUgKi8KCXJkLT5kZWFkbGluZSA9IHJxLT5zdGFydF90aW1lX25zOwoKCS8qIFRp"
    "ZXItMzogQXluY2hyb25vdXMgUmVxdWVzdHMKCSAqIC0gQ2FuIGJlIHJlb3JkZXJlZCBhbmQgZGVsYXllZCBmcmVlbHkgKi8KCWlmICghKHJxLT5jbWRfZmxh"
    "Z3MgJiBSRVFfU1lOQykpIHsKCQlyZC0+ZGVhZGxpbmUgKz0gYWQtPmxhdGVuY3lfdGFyZ2V0W2FkaW9zX29wdHlwZShycSldOwoJCWlmICghY29tcGxpYW50"
    "KGFkLCBBRElPU19DRl9GSVhPUkRFUikpCgkJCXJkLT5kZWFkbGluZSArPSByZC0+cHJlZF9sYXQ7Cgl9CgoJLy8gTm93IHF1YW50aXplIHRoZSBkZWFkbGlu"
    "ZSAoLT4gZGxnLT5kZWFkbGluZSA9PSBSQi1UcmVlIGtleSkKCWRlYWRsaW5lID0gcmQtPmRlYWRsaW5lICYgfigoMVVMTCA8PCBBRElPU19RVUFOVFVNX1NI"
    "SUZUKSAtIDEpOwoKCXdoaWxlICgqbGluaykgewoJCWRsZyA9IHJiX2VudHJ5KCpsaW5rLCBzdHJ1Y3QgZGxfZ3JvdXAsIG5vZGUpOwoJCXM2NCBkaWZmID0g"
    "ZGVhZGxpbmUgLSBkbGctPmRlYWRsaW5lOwoKCQlwYXJlbnQgPSAqbGluazsKCQlpZiAoZGlmZiA8IDApIHsKCQkJbGluayA9ICYoKCpsaW5rKS0+cmJfbGVm"
    "dCk7CgkJfSBlbHNlIGlmIChkaWZmID4gMCkgewoJCQlsaW5rID0gJigoKmxpbmspLT5yYl9yaWdodCk7CgkJCWxlZnRtb3N0ID0gZmFsc2U7CgkJfSBlbHNl"
    "IHsgLy8gZGlmZiA9PSAwCgkJCWdvdG8gZm91bmQ7CgkJfQoJfQoKCWRsZyA9IHJiX2VudHJ5X3NhZmUocGFyZW50LCBzdHJ1Y3QgZGxfZ3JvdXAsIG5vZGUp"
    "OwoJaWYgKCFkbGcgfHwgZGxnLT5kZWFkbGluZSAhPSBkZWFkbGluZSkgewoJCWRsZyA9IGttZW1fY2FjaGVfemFsbG9jKGFkLT5kbF9ncm91cF9wb29sLCBH"
    "RlBfQVRPTUlDKTsKCQlpZiAoIWRsZykKCQkJcmV0dXJuOwoJCWRsZy0+ZGVhZGxpbmUgPSBkZWFkbGluZTsKCQlJTklUX0xJU1RfSEVBRCgmZGxnLT5ycXMp"
    "OwoJCXJiX2xpbmtfbm9kZSgmZGxnLT5ub2RlLCBwYXJlbnQsIGxpbmspOwoJCXJiX2luc2VydF9jb2xvcl9jYWNoZWQoJmRsZy0+bm9kZSwgcm9vdCwgbGVm"
    "dG1vc3QpOwoJfQpmb3VuZDoKCWxpc3RfYWRkX3RhaWwoJnJkLT5kbF9ub2RlLCAmZGxnLT5ycXMpOwoJcmQtPmRsX2dyb3VwID0gJmRsZy0+cnFzOwoKCWlm"
    "ICh3YXNfZW1wdHkpCgkJc2V0X2FkaW9zX3N0YXRlKGFkLCBBRElPU19TVEFURV9ETCwgZGxfaWR4LCB0cnVlKTsKfQoKLy8gUmVtb3ZlIGEgcmVxdWVzdCBm"
    "cm9tIHRoZSBkZWFkbGluZS1zb3J0ZWQgcmVkLWJsYWNrIHRyZWUKc3RhdGljIHZvaWQgZGVsX2Zyb21fZGxfdHJlZSgKCQlzdHJ1Y3QgYWRpb3NfZGF0YSAq"
    "YWQsIGJvb2wgZGxfaWR4LCBzdHJ1Y3QgcmVxdWVzdCAqcnEpIHsKCXN0cnVjdCByYl9yb290X2NhY2hlZCAqcm9vdCA9ICZhZC0+ZGxfdHJlZVtkbF9pZHhd"
    "OwoJc3RydWN0IGFkaW9zX3JxX2RhdGEgKnJkID0gZ2V0X3JxX2RhdGEocnEpOwoJc3RydWN0IGRsX2dyb3VwICpkbGcgPSBjb250YWluZXJfb2YocmQtPmRs"
    "X2dyb3VwLCBzdHJ1Y3QgZGxfZ3JvdXAsIHJxcyk7CgoJbGlzdF9kZWxfaW5pdCgmcmQtPmRsX25vZGUpOwoJaWYgKGxpc3RfZW1wdHkoJmRsZy0+cnFzKSkg"
    "ewoJCXJiX2VyYXNlX2NhY2hlZCgmZGxnLT5ub2RlLCByb290KTsKCQlrbWVtX2NhY2hlX2ZyZWUoYWQtPmRsX2dyb3VwX3Bvb2wsIGRsZyk7Cgl9CglyZC0+"
    "ZGxfZ3JvdXAgPSBOVUxMOwoKCWlmIChSQl9FTVBUWV9ST09UKCZhZC0+ZGxfdHJlZVtkbF9pZHhdLnJiX3Jvb3QpKQoJCXNldF9hZGlvc19zdGF0ZShhZCwg"
    "QURJT1NfU1RBVEVfREwsIGRsX2lkeCwgZmFsc2UpOwp9CgovLyBSZW1vdmUgYSByZXF1ZXN0IGZyb20gdGhlIHNjaGVkdWxlcgpzdGF0aWMgdm9pZCByZW1v"
    "dmVfcmVxdWVzdChzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQsIHN0cnVjdCByZXF1ZXN0ICpycSkgewoJYm9vbCBkbF9pZHggPSBhZGlvc19vcHR5cGVfbm90X3Jl"
    "YWQocnEpOwoJc3RydWN0IHJlcXVlc3RfcXVldWUgKnEgPSBycS0+cTsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZCA9IGdldF9ycV9kYXRhKHJxKTsKCgls"
    "aXN0X2RlbF9pbml0KCZycS0+cXVldWVsaXN0KTsKCgkvLyBXZSBtaWdodCBub3QgYmUgb24gdGhlIHJidHJlZSwgaWYgd2UgYXJlIGRvaW5nIGFuIGluc2Vy"
    "dCBtZXJnZQoJaWYgKHJkLT5kbF9ncm91cCkKCQlkZWxfZnJvbV9kbF90cmVlKGFkLCBkbF9pZHgsIHJxKTsKCgllbHZfcnFoYXNoX2RlbChxLCBycSk7Cglp"
    "ZiAocS0+bGFzdF9tZXJnZSA9PSBycSkKCQlxLT5sYXN0X21lcmdlID0gTlVMTDsKfQoKLy8gV2UgbGltaXQgdGhlIGRlcHRoIG9mIHJlcXVlc3QgYWxsb2Nh"
    "dGlvbiBmb3IgYXN5bmNocm9ub3VzIGFuZCB3cml0ZSByZXF1ZXN0cwpzdGF0aWMgdm9pZCBhZGlvc19saW1pdF9kZXB0aCh1bnNpZ25lZCBpbnQgb3BmLCBz"
    "dHJ1Y3QgYmxrX21xX2FsbG9jX2RhdGEgKmRhdGEpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGRhdGEtPnEtPmVsZXZhdG9yLT5lbGV2YXRvcl9kYXRh"
    "OwoKCS8vIERvIG5vdCB0aHJvdHRsZSBzeW5jaHJvbm91cyByZWFkcwoJaWYgKG9wX2lzX3N5bmMob3BmKSAmJiAhb3BfaXNfd3JpdGUob3BmKSkKCQlyZXR1"
    "cm47CgoJLyoKCSAqIHNiaXRtYXAncyBfX21hcF9kZXB0aF93aXRoX3NoYWxsb3coKSBoYXMgdGFrZW4gc2hhbGxvd19kZXB0aCBpbgoJICogd2hvbGUtcXVl"
    "dWUgdW5pdHMgc2luY2UgNi4xMiAodGhlIHNhbWUgcmVsZWFzZSBtcS1kZWFkbGluZSdzCgkgKiBkZF90b193b3JkX2RlcHRoKCkgd2FzIGRyb3BwZWQpIGFu"
    "ZCBkb2VzIHRoZSBwZXItd29yZCBkaXZpc2lvbgoJICogaXRzZWxmLiBQYXNzaW5nIGFuIGFscmVhZHkgcGVyLXdvcmQgdmFsdWUgaGVyZSAodGhlIG9sZAoJ"
    "ICogdG9fd29yZF9kZXB0aCgpIGhlbHBlcikgZ290IGl0IHNxdWFyZWQgYXdheTogd29yZF9kZXB0aF4yIC8KCSAqIHNiLT5kZXB0aCwgc2lsZW50bHkgY2Fw"
    "cGluZyBhc3luYy93cml0ZSBhbGxvY2F0aW9uIGF0IDw9IDY0IHRhZ3MKCSAqIHJlZ2FyZGxlc3Mgb2YgYXN5bmNfZGVwdGguIFBhc3MgdGhlIHJhdyBxdWV1"
    "ZS13aWRlIGRlcHRoLCBtYXRjaGluZwoJICogbXEtZGVhZGxpbmUva3liZXIuCgkgKi8KCWRhdGEtPnNoYWxsb3dfZGVwdGggPSBhZC0+YXN5bmNfZGVwdGg7"
    "Cn0KCi8vIFRoZSBudW1iZXIgb2YgcmVxdWVzdHMgaW4gdGhlIHF1ZXVlIHdhcyBub3RpZmllZCBmcm9tIHRoZSBibG9jayBsYXllcgpzdGF0aWMgdm9pZCBh"
    "ZGlvc19kZXB0aF91cGRhdGVkKHN0cnVjdCBibGtfbXFfaHdfY3R4ICpoY3R4KSB7CglzdHJ1Y3QgcmVxdWVzdF9xdWV1ZSAqcSA9IGhjdHgtPnF1ZXVlOwoJ"
    "c3RydWN0IGFkaW9zX2RhdGEgKmFkID0gcS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgYmxrX21xX3RhZ3MgKnRhZ3MgPSBoY3R4LT5zY2hl"
    "ZF90YWdzOwoKCWFkLT5hc3luY19kZXB0aCA9IHEtPm5yX3JlcXVlc3RzOwoKCXNiaXRtYXBfcXVldWVfbWluX3NoYWxsb3dfZGVwdGgoJnRhZ3MtPmJpdG1h"
    "cF90YWdzLCBhZC0+YXN5bmNfZGVwdGgpOwp9CgovLyBIYW5kbGUgcmVxdWVzdCBtZXJnaW5nIGFmdGVyIGEgbWVyZ2Ugb3BlcmF0aW9uCnN0YXRpYyB2b2lk"
    "IGFkaW9zX3JlcXVlc3RfbWVyZ2VkKHN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxLCBzdHJ1Y3QgcmVxdWVzdCAqcmVxLAoJCQkJICBlbnVtIGVsdl9tZXJnZSB0"
    "eXBlKSB7Cglib29sIGRsX2lkeCA9IGFkaW9zX29wdHlwZV9ub3RfcmVhZChyZXEpOwoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gcS0+ZWxldmF0b3ItPmVs"
    "ZXZhdG9yX2RhdGE7CgoJLy8gUmVwb3NpdGlvbiByZXF1ZXN0IGluIHRoZSBkZWFkbGluZS1zb3J0ZWQgdHJlZQoJZGVsX2Zyb21fZGxfdHJlZShhZCwgZGxf"
    "aWR4LCByZXEpOwoJYWRkX3RvX2RsX3RyZWUoYWQsIGRsX2lkeCwgcmVxKTsKfQoKLy8gSGFuZGxlIG1lcmdpbmcgb2YgcmVxdWVzdHMgYWZ0ZXIgb25lIGhh"
    "cyBiZWVuIG1lcmdlZCBpbnRvIGFub3RoZXIKc3RhdGljIHZvaWQgYWRpb3NfbWVyZ2VkX3JlcXVlc3RzKHN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxLCBzdHJ1"
    "Y3QgcmVxdWVzdCAqcmVxLAoJCQkJICAgc3RydWN0IHJlcXVlc3QgKm5leHQpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IHEtPmVsZXZhdG9yLT5lbGV2"
    "YXRvcl9kYXRhOwoKCWxvY2tkZXBfYXNzZXJ0X2hlbGQoJmFkLT5sb2NrKTsKCgkvLyBraWxsIGtub3dsZWRnZSBvZiBuZXh0LCB0aGlzIG9uZSBpcyBhIGdv"
    "bmVyCglyZW1vdmVfcmVxdWVzdChhZCwgbmV4dCk7Cn0KCi8vIFRyeSB0byBtZXJnZSBhIGJpbyBpbnRvIGFuIGV4aXN0aW5nIHJxIGJlZm9yZSBhc3NvY2lh"
    "dGluZyBpdCB3aXRoIGFuIHJxCnN0YXRpYyBib29sIGFkaW9zX2Jpb19tZXJnZShzdHJ1Y3QgcmVxdWVzdF9xdWV1ZSAqcSwgc3RydWN0IGJpbyAqYmlvLAoJ"
    "CXVuc2lnbmVkIGludCBucl9zZWdzKSB7Cgl1bnNpZ25lZCBsb25nIGZsYWdzOwoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gcS0+ZWxldmF0b3ItPmVsZXZh"
    "dG9yX2RhdGE7CglzdHJ1Y3QgcmVxdWVzdCAqZnJlZSA9IE5VTEw7Cglib29sIHJldDsKCglpZiAoIXNwaW5fdHJ5bG9ja19pcnFzYXZlKCZhZC0+bG9jaywg"
    "ZmxhZ3MpKQoJCXJldHVybiBmYWxzZTsKCglyZXQgPSBibGtfbXFfc2NoZWRfdHJ5X21lcmdlKHEsIGJpbywgbnJfc2VncywgJmZyZWUpOwoJc3Bpbl91bmxv"
    "Y2tfaXJxcmVzdG9yZSgmYWQtPmxvY2ssIGZsYWdzKTsKCglpZiAoZnJlZSkKCQlibGtfbXFfZnJlZV9yZXF1ZXN0KGZyZWUpOwoKCXJldHVybiByZXQ7Cn0K"
    "CnN0YXRpYyBib29sIG1lcmdlX29yX2luc2VydF90b19kbF90cmVlKHN0cnVjdCBhZGlvc19kYXRhICphZCwKCQlzdHJ1Y3QgcmVxdWVzdCAqcnEsIHN0cnVj"
    "dCByZXF1ZXN0X3F1ZXVlICpxLCBzdHJ1Y3QgbGlzdF9oZWFkICpmcmVlKSB7CglpZiAoYWRpb3NfdHJ5X2luc2VydF9tZXJnZShxLCBycSwgZnJlZSkpCgkJ"
    "cmV0dXJuIHRydWU7CgoJYm9vbCBkbF9pZHggPSBhZGlvc19vcHR5cGVfbm90X3JlYWQocnEpOwoJYWRkX3RvX2RsX3RyZWUoYWQsIGRsX2lkeCwgcnEpOwoK"
    "CWlmIChycV9tZXJnZWFibGUocnEpKSB7CgkJZWx2X3JxaGFzaF9hZGQocSwgcnEpOwoJCWlmICghcS0+bGFzdF9tZXJnZSkKCQkJcS0+bGFzdF9tZXJnZSA9"
    "IHJxOwoJfQoKCXJldHVybiBmYWxzZTsKfQoKc3RhdGljIHZvaWQgaW5zZXJ0X3RvX3ByaW9fcXVldWUoc3RydWN0IGFkaW9zX2RhdGEgKmFkLAoJCXN0cnVj"
    "dCByZXF1ZXN0ICpycSwgYm9vbCBwcV9pZHgpIHsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZCA9IGdldF9ycV9kYXRhKHJxKTsKCgkvKiBXZSdyZSBzdXJl"
    "IHRoYXQgcmQtPm1hbmFnZWQgPT0gdHJ1ZSAqLwoJdW5pb24gYWRpb3NfaW5fZmxpZ2h0X3JxcyBpZnIgPSB7CgkJLmNvdW50ICAgICAgICAgID0gMSwKCQku"
    "dG90YWxfcHJlZF9sYXQgPSByZC0+cHJlZF9sYXQsCgl9OwoJYXRvbWljNjRfYWRkKGlmci5zY2FsYXIsICZhZC0+aW5fZmxpZ2h0X3Jxcy5hdG9taWMpOwoK"
    "CWFkaW9zX3Njb3BlZF9ndWFyZChzcGlubG9ja19pcnFzYXZlLCAmYWQtPnBxX2xvY2spIHsKCQlib29sIHdhc19lbXB0eSA9IGxpc3RfZW1wdHkoJmFkLT5w"
    "cmlvX3F1ZXVlW3BxX2lkeF0pOwoJCWxpc3RfYWRkX3RhaWwoJnJxLT5xdWV1ZWxpc3QsICZhZC0+cHJpb19xdWV1ZVtwcV9pZHhdKTsKCQlpZiAod2FzX2Vt"
    "cHR5KQoJCQlzZXRfYWRpb3Nfc3RhdGUoYWQsIEFESU9TX1NUQVRFX1BRLCBwcV9pZHgsIHRydWUpOwoJfQp9CgovLyBJbnNlcnQgYSByZXF1ZXN0IGludG8g"
    "dGhlIHNjaGVkdWxlciAoYWZ0ZXIgUmVhZCAmIFdyaXRlIG1vZGVscyBzdGFiaWxpemVkKQpzdGF0aWMgdm9pZCBpbnNlcnRfcmVxdWVzdF9wb3N0X3N0YWJp"
    "bGl0eShzdHJ1Y3QgYmxrX21xX2h3X2N0eCAqaGN0eCwKCQlzdHJ1Y3QgcmVxdWVzdCAqcnEsIGJsa19pbnNlcnRfdCBpbnNlcnRfZmxhZ3MsIHN0cnVjdCBs"
    "aXN0X2hlYWQgKmZyZWUpIHsKCXN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxID0gaGN0eC0+cXVldWU7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBxLT5lbGV2"
    "YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZCA9IGdldF9ycV9kYXRhKHJxKTsKCXU4IG9wdHlwZSA9IGFkaW9zX29wdHlw"
    "ZShycSk7CgoJcmQtPm1hbmFnZWQgPSB0cnVlOwoJcmQtPmJsb2NrX3NpemUgPSBibGtfcnFfYnl0ZXMocnEpOwoJcmQtPnByZWRfbGF0ID0KCQlsYXRlbmN5"
    "X21vZGVsX3ByZWRpY3QoJmFkLT5sYXRlbmN5X21vZGVsW29wdHlwZV0sIHJkLT5ibG9ja19zaXplKTsKCWlmICh1bmxpa2VseShyZC0+cHJlZF9sYXQgPiBh"
    "ZC0+bGF0X21vZGVsX2xhdGVuY3lfbGltaXQpKQoJCXJkLT5wcmVkX2xhdCA9IGFkLT5sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdDsKCgkvKiBUaWVyLTA6IEJM"
    "S19NUV9JTlNFUlRfQVRfSEVBRCBSZXF1ZXN0cyAqLwoJaWYgKGluc2VydF9mbGFncyAmIEJMS19NUV9JTlNFUlRfQVRfSEVBRCkgewoJCWluc2VydF90b19w"
    "cmlvX3F1ZXVlKGFkLCBycSwgMCk7CgkJcmV0dXJuOwoJfQoKCWlmIChtZXJnZV9vcl9pbnNlcnRfdG9fZGxfdHJlZShhZCwgcnEsIHEsIGZyZWUpKQoJCXJl"
    "dHVybjsKfQoKLy8gSW5zZXJ0IGEgcmVxdWVzdCBpbnRvIHRoZSBzY2hlZHVsZXIgKGJlZm9yZSBSZWFkICYgV3JpdGUgbW9kZWxzIHN0YWJpbGl6ZXMpCnN0"
    "YXRpYyB2b2lkIGluc2VydF9yZXF1ZXN0X3ByZV9zdGFiaWxpdHkoc3RydWN0IGJsa19tcV9od19jdHggKmhjdHgsCgkJc3RydWN0IHJlcXVlc3QgKnJxLCBi"
    "bGtfaW5zZXJ0X3QgaW5zZXJ0X2ZsYWdzLCBzdHJ1Y3QgbGlzdF9oZWFkICpmcmVlKSB7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBoY3R4LT5xdWV1ZS0+"
    "ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgYWRpb3NfcnFfZGF0YSAqcmQgPSBnZXRfcnFfZGF0YShycSk7Cgl1OCBvcHR5cGUgPSBhZGlvc19v"
    "cHR5cGUocnEpOwoJdTggcHFfaWR4ID0gIShpbnNlcnRfZmxhZ3MgJiBCTEtfTVFfSU5TRVJUX0FUX0hFQUQpOwoJYm9vbCBzdGFibGUgPSBmYWxzZTsKCgly"
    "ZC0+bWFuYWdlZCA9IHRydWU7CglyZC0+YmxvY2tfc2l6ZSA9IGJsa19ycV9ieXRlcyhycSk7CglyZC0+cHJlZF9sYXQgPQoJCWxhdGVuY3lfbW9kZWxfcHJl"
    "ZGljdCgmYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBlXSwgcmQtPmJsb2NrX3NpemUpOwoJaWYgKHVubGlrZWx5KHJkLT5wcmVkX2xhdCA+IGFkLT5sYXRfbW9k"
    "ZWxfbGF0ZW5jeV9saW1pdCkpCgkJcmQtPnByZWRfbGF0ID0gYWQtPmxhdF9tb2RlbF9sYXRlbmN5X2xpbWl0OwoKCWluc2VydF90b19wcmlvX3F1ZXVlKGFk"
    "LCBycSwgcHFfaWR4KTsKCglyY3VfcmVhZF9sb2NrKCk7CglpZiAocmN1X2RlcmVmZXJlbmNlKGFkLT5sYXRlbmN5X21vZGVsW0FESU9TX1JFQURdLnBhcmFt"
    "cyktPmJhc2UgPiAwICYmCgkJcmN1X2RlcmVmZXJlbmNlKGFkLT5sYXRlbmN5X21vZGVsW0FESU9TX1dSSVRFXS5wYXJhbXMpLT5iYXNlID4gMCkKCQkJc3Rh"
    "YmxlID0gdHJ1ZTsKCXJjdV9yZWFkX3VubG9jaygpOwoKCWlmIChzdGFibGUpCgkJYWQtPm1vZGVsc19zdGFibGUgPSB0cnVlOwp9CgovLyBJbnNlcnQgbXVs"
    "dGlwbGUgcmVxdWVzdHMgaW50byB0aGUgc2NoZWR1bGVyCnN0YXRpYyB2b2lkIGFkaW9zX2luc2VydF9yZXF1ZXN0cyhzdHJ1Y3QgYmxrX21xX2h3X2N0eCAq"
    "aGN0eCwKCQkJCSAgIHN0cnVjdCBsaXN0X2hlYWQgKmxpc3QsCgkJCQkgICBib29sIGRpc3BhdGNoX25vdykgewoJYmxrX2luc2VydF90IGluc2VydF9mbGFn"
    "cyA9IDA7Cgkodm9pZClkaXNwYXRjaF9ub3c7CglzdHJ1Y3QgcmVxdWVzdF9xdWV1ZSAqcSA9IGhjdHgtPnF1ZXVlOwoJc3RydWN0IGFkaW9zX2RhdGEgKmFk"
    "ID0gcS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgcmVxdWVzdCAqcnE7Cglib29sIHN0b3AgPSBmYWxzZTsKCUxJU1RfSEVBRChmcmVlKTsK"
    "CglkbyB7CglhZGlvc19zY29wZWRfZ3VhcmQoc3BpbmxvY2tfaXJxc2F2ZSwgJmFkLT5sb2NrKQoJZm9yIChpbnQgaSA9IDA7IGkgPCBBRElPU19NQVhfSU5T"
    "RVJUU19QRVJfTE9DSzsgaSsrKSB7CgkJaWYgKGxpc3RfZW1wdHkobGlzdCkpIHsKCQkJc3RvcCA9IHRydWU7CgkJCWJyZWFrOwoJCX0KCQlycSA9IGxpc3Rf"
    "Zmlyc3RfZW50cnkobGlzdCwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7CgkJbGlzdF9kZWxfaW5pdCgmcnEtPnF1ZXVlbGlzdCk7CgkJaWYgKGxpa2Vs"
    "eShhZC0+bW9kZWxzX3N0YWJsZSkpCgkJCWluc2VydF9yZXF1ZXN0X3Bvc3Rfc3RhYmlsaXR5KGhjdHgsIHJxLCBpbnNlcnRfZmxhZ3MsICZmcmVlKTsKCQll"
    "bHNlCgkJCWluc2VydF9yZXF1ZXN0X3ByZV9zdGFiaWxpdHkoaGN0eCwgcnEsIGluc2VydF9mbGFncywgJmZyZWUpOwoJfX0gd2hpbGUgKCFzdG9wKTsKCglh"
    "ZGlvc19mcmVlX3JlcXVlc3RzKCZmcmVlKTsKfQoKLy8gUHJlcGFyZSBhIHJlcXVlc3QgYmVmb3JlIGl0IGlzIGluc2VydGVkIGludG8gdGhlIHNjaGVkdWxl"
    "cgpzdGF0aWMgdm9pZCBhZGlvc19wcmVwYXJlX3JlcXVlc3Qoc3RydWN0IHJlcXVlc3QgKnJxLCBzdHJ1Y3QgYmlvICpiaW8pIHsKCSh2b2lkKWJpbzsKCXN0"
    "cnVjdCBhZGlvc19kYXRhICphZCA9IHJxLT5xLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZDsKCglyZCA9IG1l"
    "bXBvb2xfYWxsb2MoYWQtPnJxX2RhdGFfcG9vbCwgR0ZQX0FUT01JQyk7CgltZW1zZXQocmQsIDAsIHNpemVvZigqcmQpKTsKCXJkLT5ycSA9IHJxOwoJcnEt"
    "PmVsdi5wcml2WzBdID0gcmQ7Cn0KCnN0YXRpYyBzdHJ1Y3QgYWRpb3NfcnFfZGF0YSAqZ2V0X2RsX2ZpcnN0X3JkKHN0cnVjdCBhZGlvc19kYXRhICphZCwg"
    "Ym9vbCBpZHgpIHsKCXN0cnVjdCByYl9yb290X2NhY2hlZCAqcm9vdCA9ICZhZC0+ZGxfdHJlZVtpZHhdOwoJc3RydWN0IHJiX25vZGUgKmZpcnN0ID0gcmJf"
    "Zmlyc3RfY2FjaGVkKHJvb3QpOwoJc3RydWN0IGRsX2dyb3VwICpkbF9ncm91cCA9IHJiX2VudHJ5KGZpcnN0LCBzdHJ1Y3QgZGxfZ3JvdXAsIG5vZGUpOwoK"
    "CXJldHVybiBsaXN0X2ZpcnN0X2VudHJ5KCZkbF9ncm91cC0+cnFzLCBzdHJ1Y3QgYWRpb3NfcnFfZGF0YSwgZGxfbm9kZSk7Cn0KCi8vIENvbXBhcmlzb24g"
    "ZnVuY3Rpb24gZm9yIHNvcnRpbmcgcmVxdWVzdHMgYnkgYmxvY2sgYWRkcmVzcwpzdGF0aWMgaW50IGNtcF9ycV9wb3Modm9pZCAqcHJpdiwKCQlzdHJ1Y3Qg"
    "bGlzdF9oZWFkICphLCBzdHJ1Y3QgbGlzdF9oZWFkICpiKSB7CglzdHJ1Y3QgcmVxdWVzdCAqcnFfYSA9IGxpc3RfZW50cnkoYSwgc3RydWN0IHJlcXVlc3Qs"
    "IHF1ZXVlbGlzdCk7CglzdHJ1Y3QgcmVxdWVzdCAqcnFfYiA9IGxpc3RfZW50cnkoYiwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7Cgl1NjQgcG9zX2Eg"
    "PSBibGtfcnFfcG9zKHJxX2EpOwoJdTY0IHBvc19iID0gYmxrX3JxX3BvcyhycV9iKTsKCglyZXR1cm4gKGludCkocG9zX2EgPiBwb3NfYikgLSAoaW50KShw"
    "b3NfYSA8IHBvc19iKTsKfQoKI2lmbmRlZiBsaXN0X2xhc3RfZW50cnlfb3JfbnVsbAojZGVmaW5lIGxpc3RfbGFzdF9lbnRyeV9vcl9udWxsKHB0ciwgdHlw"
    "ZSwgbWVtYmVyKSBcCgkoIWxpc3RfZW1wdHkocHRyKSA/IGxpc3RfbGFzdF9lbnRyeShwdHIsIHR5cGUsIG1lbWJlcikgOiBOVUxMKQojZW5kaWYKCi8vIFVw"
    "ZGF0ZSB0aGUgZWxldmF0b3IgZGlyZWN0aW9uCnN0YXRpYyB2b2lkIHVwZGF0ZV9lbHZfZGlyZWN0aW9uKHN0cnVjdCBhZGlvc19kYXRhICphZCkgewoJaWYg"
    "KCFhZC0+aXNfcm90YXRpb25hbCkKCQlyZXR1cm47CgoJYm9vbCBwYWdlID0gYWQtPmJxX3BhZ2U7CglzdHJ1Y3QgbGlzdF9oZWFkICpxID0gJmFkLT5iYXRj"
    "aF9xdWV1ZVtwYWdlXVsxXTsKCWlmIChhZC0+YnFfYmF0Y2hfb3JkZXJbcGFnZV0gPCBBRElPU19CT19FTEVWQVRPUiB8fCBsaXN0X2VtcHR5KHEpKSB7CgkJ"
    "YWQtPmVsdl9kaXJlY3Rpb24gPSAwOwoJCXJldHVybjsKCX0KCgkvLyBHZXQgZmlyc3QgYW5kIGxhc3QgcmVxdWVzdCBwb3NpdGlvbnMgaW4gdGhlIHF1ZXVl"
    "CglzdHJ1Y3QgcmVxdWVzdCAqcnFfYSA9IGxpc3RfZmlyc3RfZW50cnkocSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7CglzdHJ1Y3QgcmVxdWVzdCAq"
    "cnFfYiA9IGxpc3RfbGFzdF9lbnRyeSAocSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7Cgl1NjQgcG9zX2EgPSBibGtfcnFfcG9zKHJxX2EpOwoJdTY0"
    "IHBvc19iID0gYmxrX3JxX3BvcyhycV9iKTsKCXU2NCBhdmdfcnFfcG9zID0gKHBvc19hICsgcG9zX2IpID4+IDE7CgoJYWQtPmVsdl9kaXJlY3Rpb24gPSAh"
    "IShhZC0+aGVhZF9wb3MgPiBhdmdfcnFfcG9zKTsKfQoKLy8gRmlsbCB0aGUgYmF0Y2ggcXVldWVzIHdpdGggcmVxdWVzdHMgZnJvbSB0aGUgZGVhZGxpbmUt"
    "c29ydGVkIHJlZC1ibGFjayB0cmVlCnN0YXRpYyBib29sIGZpbGxfYmF0Y2hfcXVldWVzKHN0cnVjdCBhZGlvc19kYXRhICphZCwgdTY0IHRwbCkgewoJc3Ry"
    "dWN0IGFkaW9zX3JxX2RhdGEgKnJkOwoJc3RydWN0IHJlcXVlc3QgKnJxOwoJc3RydWN0IGxpc3RfaGVhZCAqZGVzdF9xOwoJdTggIGRlc3RfaWR4OwoJdTY0"
    "IGFkZGVkX2xhdCA9IDA7Cgl1MzIgb3B0eXBlX2NvdW50W0FESU9TX09QVFlQRVNdID0gezB9OwoJdTMyIGNvdW50ID0gMDsKCXU4IG9wdHlwZTsKCWJvb2wg"
    "cGFnZSA9ICFhZC0+YnFfcGFnZSwgZGxfaWR4LCBiaWFzX2lkeCwgdXBkYXRlX2JpYXM7Cgl1MzIgZGxfcXVldWVkOwoJdTggYnFfYmF0Y2hfb3JkZXI7Cgli"
    "b29sIHN0b3AgPSBmYWxzZTsKCgkvLyBSZXNldCBiYXRjaCBxdWV1ZSBjb3VudHMgZm9yIHRoZSBiYWNrIHBhZ2UKCW1lbXNldCgmYWQtPmJhdGNoX2NvdW50"
    "W3BhZ2VdLCAwLCBzaXplb2YoYWQtPmJhdGNoX2NvdW50W3BhZ2VdKSk7CgoJYWQtPmJxX2JhdGNoX29yZGVyW3BhZ2VdID0KCQlicV9iYXRjaF9vcmRlciA9"
    "IGFkLT5iYXRjaF9vcmRlcjsKCglkbyB7CglhZGlvc19zY29wZWRfZ3VhcmQoc3BpbmxvY2tfaXJxc2F2ZSwgJmFkLT5sb2NrKQoJZm9yIChpbnQgaSA9IDA7"
    "IGkgPCBBRElPU19NQVhfREVMRVRFU19QRVJfTE9DSzsgaSsrKSB7CgkJYm9vbCBoYXNfYmFzZSA9IGZhbHNlOwoKCQlkbF9xdWV1ZWQgPSBldmFsX2FkaW9z"
    "X3N0YXRlKGFkLCBBRElPU19TVEFURV9ETCk7CgkJLy8gQ2hlY2sgaWYgdGhlcmUgYXJlIGFueSByZXF1ZXN0cyBxdWV1ZWQgaW4gdGhlIGRlYWRsaW5lIHRy"
    "ZWUKCQlpZiAoIWRsX3F1ZXVlZCkgewoJCQlzdG9wID0gdHJ1ZTsKCQkJYnJlYWs7CgkJfQoKCQkvLyBSZWFkcyBpZiBib3RoIHF1ZXVlcyBoYXZlIHJlcXVl"
    "c3RzLCBvdGhlcndpc2UgcGljayB0aGUgbm9uLWVtcHR5LgoJCWRsX2lkeCA9IGRsX3F1ZXVlZCA+PiAxOwoKCQkvLyBHZXQgdGhlIGZpcnN0IHJlcXVlc3Qg"
    "ZnJvbSB0aGUgZGVhZGxpbmUtc29ydGVkIHRyZWUKCQlyZCA9IGdldF9kbF9maXJzdF9yZChhZCwgZGxfaWR4KTsKCgkJYmlhc19pZHggPSBhZC0+ZGxfYmlh"
    "cyA8IDA7CgkJLy8gSWYgcmVhZCBhbmQgd3JpdGUgcmVxdWVzdHMgYXJlIHF1ZXVlZCwgY2hvb3NlIG9uZSBiYXNlZCBvbiBiaWFzCgkJaWYgKGRsX3F1ZXVl"
    "ZCA9PSAweDMpIHsKCQkJc3RydWN0IGFkaW9zX3JxX2RhdGEgKnRyZFsyXSA9IHtnZXRfZGxfZmlyc3RfcmQoYWQsIDApLCByZH07CgkJCXJkID0gdHJkW2Jp"
    "YXNfaWR4XTsKCgkJCXVwZGF0ZV9iaWFzID0gKHRyZFtiaWFzX2lkeF0tPmRlYWRsaW5lID4gdHJkWyFiaWFzX2lkeF0tPmRlYWRsaW5lKTsKCQl9IGVsc2UK"
    "CQkJdXBkYXRlX2JpYXMgPSAoYmlhc19pZHggPT0gZGxfaWR4KTsKCgkJcnEgPSByZC0+cnE7CgkJb3B0eXBlID0gYWRpb3Nfb3B0eXBlKHJxKTsKCgkJcmN1"
    "X3JlYWRfbG9jaygpOwoJCWhhc19iYXNlID0KCQkJISFyY3VfZGVyZWZlcmVuY2UoYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBlXS5wYXJhbXMpLT5iYXNlOwoJ"
    "CXJjdV9yZWFkX3VubG9jaygpOwoKCQkvLyBDaGVjayBiYXRjaCBzaXplIGFuZCB0b3RhbCBwcmVkaWN0ZWQgbGF0ZW5jeQoJCWlmIChjb3VudCAmJiAoIWhh"
    "c19iYXNlIHx8CgkJCQlhZC0+YmF0Y2hfY291bnRbcGFnZV1bb3B0eXBlXSA+PSBhZC0+YmF0Y2hfbGltaXRbb3B0eXBlXSB8fAoJCQkJKHRwbCArIGFkZGVk"
    "X2xhdCArIHJkLT5wcmVkX2xhdCkgPiBhZC0+Z2xvYmFsX2xhdGVuY3lfd2luZG93KSkgewoJCQlzdG9wID0gdHJ1ZTsKCQkJYnJlYWs7CgkJfQoKCQlpZiAo"
    "dXBkYXRlX2JpYXMpIHsKCQkJczY0IHNpZ24gPSAoKHM2NCliaWFzX2lkeCA8PCAxKSAtIDE7CgkJCWlmICh1bmxpa2VseSghcmQtPnByZWRfbGF0KSkKCQkJ"
    "CWFkLT5kbF9iaWFzID0gc2lnbjsKCQkJZWxzZQoJCQkJLy8gQWRqdXN0IHRoZSBiaWFzIGJhc2VkIG9uIHRoZSBwcmVkaWN0ZWQgbGF0ZW5jeQoJCQkJYWQt"
    "PmRsX2JpYXMgKz0gc2lnbiAqIChzNjQpKChyZC0+cHJlZF9sYXQgKgoJCQkJCWFkaW9zX3ByaW9fdG9fd211bHRbYWQtPmRsX3ByaW9bYmlhc19pZHhdICsg"
    "MjBdKSA+PiAxMCk7CgkJfQoKCQlyZW1vdmVfcmVxdWVzdChhZCwgcnEpOwoKCQkvLyBBZGQgcmVxdWVzdCB0byB0aGUgY29ycmVzcG9uZGluZyBiYXRjaCBx"
    "dWV1ZQoJCWRlc3RfaWR4ID0gKGJxX2JhdGNoX29yZGVyID09IEFESU9TX0JPX09QVFlQRSB8fCBvcHR5cGUgPT0gQURJT1NfT1RIRVIpPwoJCQlvcHR5cGUg"
    "OiAhIShyZC0+ZGVhZGxpbmUgIT0gcnEtPnN0YXJ0X3RpbWVfbnMpOwoJCWRlc3RfcSA9ICZhZC0+YmF0Y2hfcXVldWVbcGFnZV1bZGVzdF9pZHhdOwoJCWxp"
    "c3RfYWRkX3RhaWwoJnJxLT5xdWV1ZWxpc3QsIGRlc3RfcSk7CgkJYWQtPmJxX3N0YXRlW3BhZ2VdIHw9IDFVIDw8IGRlc3RfaWR4OwoJCWFkLT5iYXRjaF9j"
    "b3VudFtwYWdlXVtvcHR5cGVdKys7CgkJb3B0eXBlX2NvdW50W29wdHlwZV0rKzsKCQlhZGRlZF9sYXQgKz0gcmQtPnByZWRfbGF0OwoJCWNvdW50Kys7Cgl9"
    "fSB3aGlsZSAoIXN0b3ApOwoKCWlmIChicV9iYXRjaF9vcmRlciA9PSBBRElPU19CT19FTEVWQVRPUiAmJiBhZC0+YmF0Y2hfY291bnRbcGFnZV1bMV0gPiAx"
    "KQoJCQlsaXN0X3NvcnQoTlVMTCwgJmFkLT5iYXRjaF9xdWV1ZVtwYWdlXVsxXSwgY21wX3JxX3Bvcyk7CgoJaWYgKGNvdW50KSB7CgkJLyogV2UncmUgc3Vy"
    "ZSB0aGF0IGV2ZXJ5IHJlcXVlc3QncyByZC0+bWFuYWdlZCA9PSB0cnVlICovCgkJdW5pb24gYWRpb3NfaW5fZmxpZ2h0X3JxcyBpZnIgPSB7CgkJCS5jb3Vu"
    "dCAgICAgICAgICA9IGNvdW50LAoJCQkudG90YWxfcHJlZF9sYXQgPSBhZGRlZF9sYXQsCgkJfTsKCQlhdG9taWM2NF9hZGQoaWZyLnNjYWxhciwgJmFkLT5p"
    "bl9mbGlnaHRfcnFzLmF0b21pYyk7CgoJCXNldF9hZGlvc19zdGF0ZShhZCwgQURJT1NfU1RBVEVfQlEsIHBhZ2UsIHRydWUpOwoKCQlmb3IgKG9wdHlwZSA9"
    "IDA7IG9wdHlwZSA8IEFESU9TX09QVFlQRVM7IG9wdHlwZSsrKQoJCQlpZiAoYWQtPmJhdGNoX2FjdHVhbF9tYXhfc2l6ZVtvcHR5cGVdIDwgb3B0eXBlX2Nv"
    "dW50W29wdHlwZV0pCgkJCQlhZC0+YmF0Y2hfYWN0dWFsX21heF9zaXplW29wdHlwZV0gPSBvcHR5cGVfY291bnRbb3B0eXBlXTsKCQlpZiAoYWQtPmJhdGNo"
    "X2FjdHVhbF9tYXhfdG90YWwgPCBjb3VudCkKCQkJYWQtPmJhdGNoX2FjdHVhbF9tYXhfdG90YWwgPSBjb3VudDsKCX0KCXJldHVybiBjb3VudDsKfQoKLy8g"
    "RmxpcCB0byB0aGUgbmV4dCBiYXRjaCBxdWV1ZSBwYWdlCnN0YXRpYyB2b2lkIGZsaXBfYnFfcGFnZShzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQpIHsKCWFkLT5i"
    "cV9wYWdlID0gIWFkLT5icV9wYWdlOwoJdXBkYXRlX2Vsdl9kaXJlY3Rpb24oYWQpOwp9CgovLyBQb3AgYSByZXF1ZXN0IGZyb20gdGhlIHNwZWNpZmllZCBp"
    "bmRleCAob3B0eXBlIG9yIGVsZXZhdG9yIHRpZXIpCnN0YXRpYyBpbmxpbmUgc3RydWN0IHJlcXVlc3QgKnBvcF9icV9yZXF1ZXN0KAoJCXN0cnVjdCBhZGlv"
    "c19kYXRhICphZCwgdTggaWR4LCBib29sIGRpcmVjdGlvbikgewoJYm9vbCBwYWdlID0gYWQtPmJxX3BhZ2U7CglzdHJ1Y3QgbGlzdF9oZWFkICpxID0gJmFk"
    "LT5iYXRjaF9xdWV1ZVtwYWdlXVtpZHhdOwoJc3RydWN0IHJlcXVlc3QgKnJxID0gZGlyZWN0aW9uID8KCQlsaXN0X2xhc3RfZW50cnlfb3JfbnVsbCAocSwg"
    "c3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk6CgkJbGlzdF9maXJzdF9lbnRyeV9vcl9udWxsKHEsIHN0cnVjdCByZXF1ZXN0LCBxdWV1ZWxpc3QpOwoJaWYg"
    "KHJxKSB7CgkJbGlzdF9kZWxfaW5pdCgmcnEtPnF1ZXVlbGlzdCk7CgkJaWYgKGxpc3RfZW1wdHkocSkpCgkJCWFkLT5icV9zdGF0ZVtwYWdlXSAmPSB+KDFV"
    "IDw8IGlkeCk7Cgl9CglyZXR1cm4gcnE7Cn0KCnN0YXRpYyBzdHJ1Y3QgcmVxdWVzdCAqcG9wX25leHRfYnFfcmVxdWVzdF9vcHR5cGUoc3RydWN0IGFkaW9z"
    "X2RhdGEgKmFkKSB7Cgl1MzIgYnFfc3RhdGUgPSBhZC0+YnFfc3RhdGVbYWQtPmJxX3BhZ2VdOwoJaWYgKCFicV9zdGF0ZSkgcmV0dXJuIE5VTEw7CgoJc3Ry"
    "dWN0IHJlcXVlc3QgKnJxOwoJdTMyIGJxX2lkeCA9IF9fYnVpbHRpbl9jdHooYnFfc3RhdGUpOwoKCS8vIERpc3BhdGNoIGJhc2VkIG9uIG9wdHlwZSAoRklG"
    "TyB3aXRoaW4gZWFjaCkgb3Igc2luZ2xlLXF1ZXVlIGVsZXZhdG9yCglycSA9IHBvcF9icV9yZXF1ZXN0KGFkLCBicV9pZHgsIGZhbHNlKTsKCXJldHVybiBy"
    "cTsKfQoKc3RhdGljIHN0cnVjdCByZXF1ZXN0ICpwb3BfbmV4dF9icV9yZXF1ZXN0X2VsZXZhdG9yKHN0cnVjdCBhZGlvc19kYXRhICphZCkgewoJdTMyIGJx"
    "X3N0YXRlID0gYWQtPmJxX3N0YXRlW2FkLT5icV9wYWdlXTsKCWlmICghYnFfc3RhdGUpIHJldHVybiBOVUxMOwoKCXN0cnVjdCByZXF1ZXN0ICpycTsKCXUz"
    "MiBicV9pZHggPSBfX2J1aWx0aW5fY3R6KGJxX3N0YXRlKTsKCWJvb2wgZGlyZWN0aW9uID0gKGJxX2lkeCA9PSAxKSAmIGFkLT5lbHZfZGlyZWN0aW9uOwoK"
    "CS8vIFRpZXItMiAoc3luYykgaXMgYWx3YXlzIGhpZ2ggcHJpb3JpdHkKCS8vIFRpZXItMyAoYXN5bmMpIHVzZXMgdGhlIHByZS1jYWxjdWxhdGVkIGVsZXZh"
    "dG9yIGRpcmVjdGlvbgoJcnEgPSBwb3BfYnFfcmVxdWVzdChhZCwgYnFfaWR4LCBkaXJlY3Rpb24pOwoKCS8qIElmIGJhdGNoIHF1ZXVlIGZvciB0aGUgc3lu"
    "YyByZXF1ZXN0cyBqdXN0IGJlY2FtZSBlbXB0eSAqLwoJaWYgKGJxX2lkeCA9PSAwICYmIHJxICYmICEoYnFfc3RhdGUgJiAweDEpKQoJCXVwZGF0ZV9lbHZf"
    "ZGlyZWN0aW9uKGFkKTsKCglyZXR1cm4gcnE7Cn0KCi8vIFJldHVybnMgdGhlIHN0YXRlIG9mIHRoZSBiYXRjaCBxdWV1ZSBwYWdlCnN0YXRpYyBpbmxpbmUg"
    "Ym9vbCBicV9wYWdlX2hhc19ycSh1MzIgYnFfc3RhdGUsIGJvb2wgcGFnZSkgewoJcmV0dXJuIGJxX3N0YXRlICYgKDFVIDw8IHBhZ2UpOwp9CgovLyBEaXNw"
    "YXRjaCBhIHJlcXVlc3QgZnJvbSB0aGUgYmF0Y2ggcXVldWVzCnN0YXRpYyBzdHJ1Y3QgcmVxdWVzdCAqZGlzcGF0Y2hfZnJvbV9icShzdHJ1Y3QgYWRpb3Nf"
    "ZGF0YSAqYWQpIHsKCXN0cnVjdCByZXF1ZXN0ICpycTsKCglhZGlvc19ndWFyZChzcGlubG9ja19pcnFzYXZlKSgmYWQtPmJxX2xvY2spOwoKCXUzMiBzdGF0"
    "ZSA9IGdldF9hZGlvc19zdGF0ZShhZCk7Cgl1MzIgYnFfc3RhdGUgPSBldmFsX3RoaXNfYWRpb3Nfc3RhdGUoc3RhdGUsIEFESU9TX1NUQVRFX0JRKTsKCXUz"
    "MiBicV9jdXJyX3BhZ2VfaGFzX3JxID0gYnFfcGFnZV9oYXNfcnEoYnFfc3RhdGUsIGFkLT5icV9wYWdlKTsKCXVuaW9uIGFkaW9zX2luX2ZsaWdodF9ycXMg"
    "aWZyOwoJaWZyLnNjYWxhciA9IGF0b21pYzY0X3JlYWQoJmFkLT5pbl9mbGlnaHRfcnFzLmF0b21pYyk7Cgl1NjQgdHBsID0gaWZyLnRvdGFsX3ByZWRfbGF0"
    "OwoKCS8vIFJlZmlsbCB0aGUgYmF0Y2ggcXVldWVzIGlmIHRoZSBiYWNrIHBhZ2UgaXMgZW1wdHksIGRsX3RyZWUgaGFzIHdvcmssIGFuZAoJLy8gY3VycmVu"
    "dCBwYWdlIGlzIGVtcHR5IG9yIHRoZSB0b3RhbCBvbmdvaW5nIGxhdGVuY3kgaXMgYmVsb3cgdGhlIHRocmVzaG9sZAoJaWYgKCFicV9wYWdlX2hhc19ycShi"
    "cV9zdGF0ZSwgIWFkLT5icV9wYWdlKSAmJgoJCQkoIWJxX2N1cnJfcGFnZV9oYXNfcnEgfHwgKCF0cGwgfHwgdHBsIDwgZGl2X3U2NCgKCQkJYWQtPmdsb2Jh"
    "bF9sYXRlbmN5X3dpbmRvdyAqIGFkLT5icV9yZWZpbGxfYmVsb3dfcmF0aW8sIDEwMCkpKSAmJgoJCQlldmFsX3RoaXNfYWRpb3Nfc3RhdGUoc3RhdGUsIEFE"
    "SU9TX1NUQVRFX0RMKSkKCQlmaWxsX2JhdGNoX3F1ZXVlcyhhZCwgdHBsKTsKCgkvLyBJZiBjdXJyZW50IGJhdGNoIHF1ZXVlIHBhZ2UgaXMgZW1wdHksIGFu"
    "ZCB0aGUgb3RoZXIgcGFnZSBoYXMgd29yaywgZmxpcAoJaWYgKCFicV9jdXJyX3BhZ2VfaGFzX3JxICYmCgkJCWJxX3BhZ2VfaGFzX3JxKGV2YWxfYWRpb3Nf"
    "c3RhdGUoYWQsIEFESU9TX1NUQVRFX0JRKSwgIWFkLT5icV9wYWdlKSkKCQlmbGlwX2JxX3BhZ2UoYWQpOwoKCS8vIFVzZSB0aGUgcGVyLXBhZ2Ugc3RhdGUg"
    "dG8gZGVjaWRlIHRoZSBkaXNwYXRjaCBsb2dpYywgZW5zdXJpbmcgY29ycmVjdG5lc3MKCXJxID0gKGFkLT5icV9iYXRjaF9vcmRlclthZC0+YnFfcGFnZV0g"
    "PT0gQURJT1NfQk9fRUxFVkFUT1IpID8KCQlwb3BfbmV4dF9icV9yZXF1ZXN0X2VsZXZhdG9yKGFkKToKCQlwb3BfbmV4dF9icV9yZXF1ZXN0X29wdHlwZShh"
    "ZCk7CgoJaWYgKHJxKSB7CgkJYm9vbCBwYWdlID0gYWQtPmJxX3BhZ2U7CgkJYm9vbCBpc19lbXB0eSA9ICFhZC0+YnFfc3RhdGVbcGFnZV07CgkJaWYgKGlz"
    "X2VtcHR5KQoJCQlzZXRfYWRpb3Nfc3RhdGUoYWQsIEFESU9TX1NUQVRFX0JRLCBwYWdlLCBmYWxzZSk7CgkJcmV0dXJuIHJxOwoJfQoKCXJldHVybiBOVUxM"
    "Owp9CgovLyBEaXNwYXRjaCBhIHJlcXVlc3QgZnJvbSB0aGUgcHJpb3JpdHkgcXVldWUKc3RhdGljIHN0cnVjdCByZXF1ZXN0ICpkaXNwYXRjaF9mcm9tX3Bx"
    "KHN0cnVjdCBhZGlvc19kYXRhICphZCkgewoJc3RydWN0IHJlcXVlc3QgKnJxID0gTlVMTDsKCglhZGlvc19ndWFyZChzcGlubG9ja19pcnFzYXZlKSgmYWQt"
    "PnBxX2xvY2spOwoJdTMyIHBxX3N0YXRlID0gZXZhbF9hZGlvc19zdGF0ZShhZCwgQURJT1NfU1RBVEVfUFEpOwoJdTggIHBxX2lkeCA9IHBxX3N0YXRlID4+"
    "IDE7CglzdHJ1Y3QgbGlzdF9oZWFkICpxID0gJmFkLT5wcmlvX3F1ZXVlW3BxX2lkeF07CgoJaWYgKHVubGlrZWx5KGxpc3RfZW1wdHkocSkpKSByZXR1cm4g"
    "TlVMTDsKCglycSA9IGxpc3RfZmlyc3RfZW50cnkocSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7CglsaXN0X2RlbF9pbml0KCZycS0+cXVldWVsaXN0"
    "KTsKCWlmIChsaXN0X2VtcHR5KHEpKSB7CgkJc2V0X2FkaW9zX3N0YXRlKGFkLCBBRElPU19TVEFURV9QUSwgcHFfaWR4LCBmYWxzZSk7CgkJdXBkYXRlX2Vs"
    "dl9kaXJlY3Rpb24oYWQpOwoJfQoJcmV0dXJuIHJxOwp9CgoKLy8gRGlzcGF0Y2ggYSByZXF1ZXN0IHRvIHRoZSBoYXJkd2FyZSBxdWV1ZQpzdGF0aWMgc3Ry"
    "dWN0IHJlcXVlc3QgKmFkaW9zX2Rpc3BhdGNoX3JlcXVlc3Qoc3RydWN0IGJsa19tcV9od19jdHggKmhjdHgpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9"
    "IGhjdHgtPnF1ZXVlLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCByZXF1ZXN0ICpycTsKCglycSA9IGRpc3BhdGNoX2Zyb21fcHEoYWQpOwoJ"
    "aWYgKHJxKQoJCWdvdG8gZm91bmQ7CgoJcnEgPSBkaXNwYXRjaF9mcm9tX2JxKGFkKTsKCWlmIChycSkKCQlnb3RvIGZvdW5kOwoKCXJldHVybiBOVUxMOwpm"
    "b3VuZDoKCWlmIChhZC0+aXNfcm90YXRpb25hbCkKCQlhZC0+aGVhZF9wb3MgPSBibGtfcnFfcG9zKHJxKSArIGJsa19ycV9zZWN0b3JzKHJxKTsKCglycS0+"
    "cnFfZmxhZ3MgfD0gUlFGX1NUQVJURUQ7CglyZXR1cm4gcnE7Cn0KCi8vIFRpbWVyIGNhbGxiYWNrIGZ1bmN0aW9uIHRvIHBlcmlvZGljYWxseSB1cGRhdGUg"
    "bGF0ZW5jeSBtb2RlbHMKc3RhdGljIHZvaWQgdXBkYXRlX3RpbWVyX2NhbGxiYWNrKHN0cnVjdCB0aW1lcl9saXN0ICp0KSB7CglzdHJ1Y3QgYWRpb3NfZGF0"
    "YSAqYWQgPSBmcm9tX3RpbWVyKGFkLCB0LCB1cGRhdGVfdGltZXIpOwoKCWZvciAodTggb3B0eXBlID0gMDsgb3B0eXBlIDwgQURJT1NfT1BUWVBFUzsgb3B0"
    "eXBlKyspCgkJbGF0ZW5jeV9tb2RlbF91cGRhdGUoYWQsICZhZC0+bGF0ZW5jeV9tb2RlbFtvcHR5cGVdKTsKfQoKLy8gSGFuZGxlIHRoZSBjb21wbGV0aW9u"
    "IG9mIGEgcmVxdWVzdApzdGF0aWMgdm9pZCBhZGlvc19jb21wbGV0ZWRfcmVxdWVzdChzdHJ1Y3QgcmVxdWVzdCAqcnEsIHU2NCBub3cpIHsKCXN0cnVjdCBh"
    "ZGlvc19kYXRhICphZCA9IHJxLT5xLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZCA9IGdldF9ycV9kYXRhKHJx"
    "KTsKCXVuaW9uIGFkaW9zX2luX2ZsaWdodF9ycXMgaWZyID0geyAuc2NhbGFyID0gMCB9OwoKCWlmIChyZC0+bWFuYWdlZCkgewoJCXVuaW9uIGFkaW9zX2lu"
    "X2ZsaWdodF9ycXMgaWZyX3RvX3N1YiA9IHsKCQkJLmNvdW50ICAgICAgICAgID0gMSwKCQkJLnRvdGFsX3ByZWRfbGF0ID0gcmQtPnByZWRfbGF0LAoJCX07"
    "CgkJaWZyLnNjYWxhciA9IGF0b21pYzY0X3N1Yl9yZXR1cm4oCgkJCWlmcl90b19zdWIuc2NhbGFyLCAmYWQtPmluX2ZsaWdodF9ycXMuYXRvbWljKTsKCX0K"
    "CXU4IG9wdHlwZSA9IGFkaW9zX29wdHlwZShycSk7CgoJdW5zaWduZWQgbG9uZyBmbGFnczsKCXN0cnVjdCBhZGlvc19wY3B1X2NvbXBsZXRpb24gKnBjOwoK"
    "CWxvY2FsX2lycV9zYXZlKGZsYWdzKTsKCXBjID0gdGhpc19jcHVfcHRyKGFkLT5wY3B1X2NvbXBsZXRpb24pOwoKCWlmIChvcHR5cGUgPT0gQURJT1NfT1RI"
    "RVIpIHsKCQkvLyBOb24tcG9zaXRpb25hbCBjb21tYW5kcyBtYWtlIHRoZSBoZWFkIHBvc2l0aW9uIHVucHJlZGljdGFibGUuCgkJLy8gSW52YWxpZGF0ZSBv"
    "dXIga25vd2xlZGdlIG9mIHRoZSBsYXN0IGNvbXBsZXRlZCBwb3NpdGlvbi4KCQlpZiAoYWQtPmlzX3JvdGF0aW9uYWwpCgkJCXBjLT5sYXN0X2NvbXBsZXRl"
    "ZF9wb3MgPSAwOwoJCWxvY2FsX2lycV9yZXN0b3JlKGZsYWdzKTsKCQlyZXR1cm47Cgl9CgoJdTY0IGxjdCA9IHBjLT5sYXN0X2NvbXBsZXRlZF90aW1lID86"
    "IHJxLT5pb19zdGFydF90aW1lX25zOwoJcGMtPmxhc3RfY29tcGxldGVkX3RpbWUgPSAoaWZyLmNvdW50KSA/IG5vdyA6IDA7CgoJaWYgKCFycS0+aW9fc3Rh"
    "cnRfdGltZV9ucyB8fCAhcmQtPmJsb2NrX3NpemUgfHwgdW5saWtlbHkobm93IDwgbGN0KSkgewoJCWxvY2FsX2lycV9yZXN0b3JlKGZsYWdzKTsKCQlyZXR1"
    "cm47Cgl9CgoJdTY0IGxhdGVuY3kgPSBub3cgLSBsY3Q7CgoJdTMyIHdlaWdodCA9IDE7CglpZiAoYWQtPmlzX3JvdGF0aW9uYWwpIHsKCQlzZWN0b3JfdCBj"
    "dXJyZW50X3BvcyA9IGJsa19ycV9wb3MocnEpOwoJCS8vIE9ubHkgY2FsY3VsYXRlIHNlZWsgZGlzdGFuY2UgaWYgd2UgaGF2ZSBhIHZhbGlkIGxhc3QgcG9z"
    "aXRpb24uCgkJaWYgKHBjLT5sYXN0X2NvbXBsZXRlZF9wb3MgPiAwKSB7CgkJCXU2NCBzZWVrX2Rpc3RhbmNlID0gYWJzKAoJCQkJKHM2NCljdXJyZW50X3Bv"
    "cyAtIChzNjQpcGMtPmxhc3RfY29tcGxldGVkX3Bvcyk7CgkJCWlmIChzZWVrX2Rpc3RhbmNlKQoJCQkJd2VpZ2h0ID0gNjUgLSBfX2J1aWx0aW5fY2x6bGwo"
    "c2Vla19kaXN0YW5jZSk7CgkJfQoJCS8vIFVwZGF0ZSAob3IgcmUtc3luY2hyb25pemUpIG91ciBrbm93bGVkZ2Ugb2YgdGhlIGhlYWQgcG9zaXRpb24uCgkJ"
    "cGMtPmxhc3RfY29tcGxldGVkX3BvcyA9IGN1cnJlbnRfcG9zICsgYmxrX3JxX3NlY3RvcnMocnEpOwoJfQoKCWxvY2FsX2lycV9yZXN0b3JlKGZsYWdzKTsK"
    "CglpZiAobGF0ZW5jeSA+IGFkLT5sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCkKCQlyZXR1cm47CgoJbGF0ZW5jeV9tb2RlbF9pbnB1dChhZCwgJmFkLT5sYXRl"
    "bmN5X21vZGVsW29wdHlwZV0sCgkJcmQtPmJsb2NrX3NpemUsIGxhdGVuY3ksIHJkLT5wcmVkX2xhdCwgd2VpZ2h0KTsKCXRpbWVyX3JlZHVjZSgmYWQtPnVw"
    "ZGF0ZV90aW1lciwgamlmZmllcyArIG1zZWNzX3RvX2ppZmZpZXMoMTAwKSk7Cn0KCi8vIENsZWFuIHVwIGFmdGVyIGEgcmVxdWVzdCBpcyBmaW5pc2hlZApz"
    "dGF0aWMgdm9pZCBhZGlvc19maW5pc2hfcmVxdWVzdChzdHJ1Y3QgcmVxdWVzdCAqcnEpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IHJxLT5xLT5lbGV2"
    "YXRvci0+ZWxldmF0b3JfZGF0YTsKCglpZiAocnEtPmVsdi5wcml2WzBdKSB7CgkJLy8gRnJlZSBhZGlvc19ycV9kYXRhIGJhY2sgdG8gdGhlIG1lbW9yeSBw"
    "b29sCgkJbWVtcG9vbF9mcmVlKGdldF9ycV9kYXRhKHJxKSwgYWQtPnJxX2RhdGFfcG9vbCk7CgkJcnEtPmVsdi5wcml2WzBdID0gTlVMTDsKCX0KfQoKLy8g"
    "Q2hlY2sgaWYgdGhlcmUgYXJlIGFueSByZXF1ZXN0cyBhdmFpbGFibGUgZm9yIGRpc3BhdGNoCnN0YXRpYyBib29sIGFkaW9zX2hhc193b3JrKHN0cnVjdCBi"
    "bGtfbXFfaHdfY3R4ICpoY3R4KSB7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBoY3R4LT5xdWV1ZS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CgoJcmV0"
    "dXJuIGF0b21pY19yZWFkKCZhZC0+c3RhdGUpICE9IDA7Cn0KCi8vIEluaXRpYWxpemUgdGhlIHNjaGVkdWxlci1zcGVjaWZpYyBkYXRhIGZvciBhIGhhcmR3"
    "YXJlIHF1ZXVlCnN0YXRpYyBpbnQgYWRpb3NfaW5pdF9oY3R4KHN0cnVjdCBibGtfbXFfaHdfY3R4ICpoY3R4LCB1bnNpZ25lZCBpbnQgaGN0eF9pZHgpIHsK"
    "CWFkaW9zX2RlcHRoX3VwZGF0ZWQoaGN0eCk7CglyZXR1cm4gMDsKfQoKLy8gSW5pdGlhbGl6ZSB0aGUgc2NoZWR1bGVyLXNwZWNpZmljIGRhdGEgd2hlbiBp"
    "bml0aWFsaXppbmcgdGhlIHJlcXVlc3QgcXVldWUKc3RhdGljIGludCBhZGlvc19pbml0X3NjaGVkKHN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxLCBzdHJ1Y3Qg"
    "ZWxldmF0b3JfdHlwZSAqZSkgewoJc3RydWN0IGFkaW9zX2RhdGEgKmFkOwoJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplcTsKCWludCByZXQgPSAtRU5PTUVN"
    "OwoJdTggb3B0eXBlID0gMDsKCgllcSA9IGVsZXZhdG9yX2FsbG9jKHEsIGUpOwoJaWYgKCFlcSkgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBhbGxv"
    "Y2F0ZSB0aGUgZWxldmF0b3JcbiIpOwoJCXJldHVybiByZXQ7Cgl9CgoJYWQgPSBremFsbG9jX25vZGUoc2l6ZW9mKCphZCksIEdGUF9LRVJORUwsIHEtPm5v"
    "ZGUpOwoJaWYgKCFhZCkgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBjcmVhdGUgYWRpb3NfZGF0YVxuIik7CgkJZ290byBwdXRfZXE7Cgl9CgoJLy8g"
    "Q3JlYXRlIGEgbWVtb3J5IHBvb2wgZm9yIGFkaW9zX3JxX2RhdGEKCWFkLT5ycV9kYXRhX2NhY2hlID0ga21lbV9jYWNoZV9jcmVhdGUoImFkaW9zX3JxX2Rh"
    "dGEiLAoJCQkJCQlzaXplb2Yoc3RydWN0IGFkaW9zX3JxX2RhdGEpLAoJCQkJCQkwLCBTTEFCX0hXQ0FDSEVfQUxJR04sIE5VTEwpOwoJaWYgKCFhZC0+cnFf"
    "ZGF0YV9jYWNoZSkgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBjcmVhdGUgcnFfZGF0YV9jYWNoZVxuIik7CgkJZ290byBmcmVlX2FkOwoJfQoKCWFk"
    "LT5ycV9kYXRhX3Bvb2wgPSBtZW1wb29sX2NyZWF0ZV9zbGFiX3Bvb2woCgkJCQkJCXEtPm5yX3JlcXVlc3RzLCBhZC0+cnFfZGF0YV9jYWNoZSk7CglpZiAo"
    "IWFkLT5ycV9kYXRhX3Bvb2wpIHsKCQlwcl9lcnIoImFkaW9zOiBGYWlsZWQgdG8gY3JlYXRlIHJxX2RhdGFfcG9vbFxuIik7CgkJZ290byBkZXN0cm95X3Jx"
    "X2RhdGFfY2FjaGU7Cgl9CgoJLyogQ3JlYXRlIGEgbWVtb3J5IHBvb2wgZm9yIGRsX2dyb3VwICovCglhZC0+ZGxfZ3JvdXBfcG9vbCA9IGttZW1fY2FjaGVf"
    "Y3JlYXRlKCJkbF9ncm91cF9wb29sIiwKCQkJCQkJc2l6ZW9mKHN0cnVjdCBkbF9ncm91cCksCgkJCQkJCTAsIFNMQUJfSFdDQUNIRV9BTElHTiwgTlVMTCk7"
    "CglpZiAoIWFkLT5kbF9ncm91cF9wb29sKSB7CgkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGNyZWF0ZSBkbF9ncm91cF9wb29sXG4iKTsKCQlnb3RvIGRl"
    "c3Ryb3lfcnFfZGF0YV9wb29sOwoJfQoKCWZvciAoaW50IGkgPSAwOyBpIDwgQURJT1NfUFFfTEVWRUxTOyBpKyspCgkJSU5JVF9MSVNUX0hFQUQoJmFkLT5w"
    "cmlvX3F1ZXVlW2ldKTsKCglmb3IgKHU4IGogPSAwOyBqIDwgQURJT1NfRExfVFlQRVM7IGorKykgewoJCWFkLT5kbF90cmVlW2pdID0gUkJfUk9PVF9DQUNI"
    "RUQ7CgkJYWQtPmRsX3ByaW9bal0gPSBkZWZhdWx0X2RsX3ByaW9bal07Cgl9CglhZC0+ZGxfYmlhcyA9IDA7CgoJZm9yICh1OCBwYWdlID0gMDsgcGFnZSA8"
    "IEFESU9TX0JRX1BBR0VTOyBwYWdlKyspCgkJZm9yIChvcHR5cGUgPSAwOyBvcHR5cGUgPCBBRElPU19PUFRZUEVTOyBvcHR5cGUrKykKCQkJSU5JVF9MSVNU"
    "X0hFQUQoJmFkLT5iYXRjaF9xdWV1ZVtwYWdlXVtvcHR5cGVdKTsKCglhZC0+YWdncl9idWNrZXRzID0ga3phbGxvYyhzaXplb2YoKmFkLT5hZ2dyX2J1Y2tl"
    "dHMpLCBHRlBfS0VSTkVMKTsKCWlmICghYWQtPmFnZ3JfYnVja2V0cykgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBhbGxvY2F0ZSBhZ2dyZWdhdGlv"
    "biBidWNrZXRzXG4iKTsKCQlnb3RvIGRlc3Ryb3lfZGxfZ3JvdXBfcG9vbDsKCX0KCglhZC0+cGNwdV9jb21wbGV0aW9uID0gYWxsb2NfcGVyY3B1KHN0cnVj"
    "dCBhZGlvc19wY3B1X2NvbXBsZXRpb24pOwoJaWYgKCFhZC0+cGNwdV9jb21wbGV0aW9uKSB7CgkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGFsbG9jYXRl"
    "IHBlci1DUFUgY29tcGxldGlvbiBkYXRhXG4iKTsKCQlnb3RvIGZyZWVfYWdncl9idWNrZXRzOwoJfQoKCWZvciAob3B0eXBlID0gMDsgb3B0eXBlIDwgQURJ"
    "T1NfT1BUWVBFUzsgb3B0eXBlKyspIHsKCQlzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBlXTsKCQlzdHJ1"
    "Y3QgbGF0ZW5jeV9tb2RlbF9wYXJhbXMgKnBhcmFtczsKCgkJc3Bpbl9sb2NrX2luaXQoJm1vZGVsLT51cGRhdGVfbG9jayk7CgkJcGFyYW1zID0ga3phbGxv"
    "YyhzaXplb2YoKnBhcmFtcyksIEdGUF9LRVJORUwpOwoJCWlmICghcGFyYW1zKSB7CgkJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBhbGxvY2F0ZSBsYXRl"
    "bmN5X21vZGVsX3BhcmFtc1xuIik7CgkJCWdvdG8gZnJlZV9idWNrZXRzOwoJCX0KCQlwYXJhbXMtPmxhc3RfdXBkYXRlX2ppZmZpZXMgPSBqaWZmaWVzOwoJ"
    "CVJDVV9JTklUX1BPSU5URVIobW9kZWwtPnBhcmFtcywgcGFyYW1zKTsKCgkJbW9kZWwtPnBjcHVfYnVja2V0cyA9IGFsbG9jX3BlcmNwdShzdHJ1Y3QgbG1f"
    "YnVja2V0cyk7CgkJaWYgKCFtb2RlbC0+cGNwdV9idWNrZXRzKSB7CgkJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBhbGxvY2F0ZSBwZXItQ1BVIGJ1Y2tl"
    "dHNcbiIpOwoJCQlrZnJlZShwYXJhbXMpOwoJCQlnb3RvIGZyZWVfYnVja2V0czsKCQl9CgoJCW1vZGVsLT5wY3B1X3NuYXBzaG90ID0gYWxsb2NfcGVyY3B1"
    "KHN0cnVjdCBsbV9idWNrZXRzKTsKCQlpZiAoIW1vZGVsLT5wY3B1X3NuYXBzaG90KSB7CgkJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBhbGxvY2F0ZSBw"
    "ZXItQ1BVIHNuYXBzaG90XG4iKTsKCQkJZnJlZV9wZXJjcHUobW9kZWwtPnBjcHVfYnVja2V0cyk7CgkJCWtmcmVlKHBhcmFtcyk7CgkJCWdvdG8gZnJlZV9i"
    "dWNrZXRzOwoJCX0KCgkJbW9kZWwtPmxtX3Nocmlua19hdF9rcmVxcyAgPSBkZWZhdWx0X2xtX3Nocmlua19hdF9rcmVxczsKCQltb2RlbC0+bG1fc2hyaW5r"
    "X2F0X2dieXRlcyA9IGRlZmF1bHRfbG1fc2hyaW5rX2F0X2dieXRlczsKCQltb2RlbC0+bG1fc2hyaW5rX3Jlc2lzdCAgICA9IGRlZmF1bHRfbG1fc2hyaW5r"
    "X3Jlc2lzdDsKCX0KCglmb3IgKG9wdHlwZSA9IDA7IG9wdHlwZSA8IEFESU9TX09QVFlQRVM7IG9wdHlwZSsrKSB7CgkJYWQtPmxhdGVuY3lfdGFyZ2V0W29w"
    "dHlwZV0gPSBkZWZhdWx0X2xhdGVuY3lfdGFyZ2V0W29wdHlwZV07CgkJYWQtPmJhdGNoX2xpbWl0W29wdHlwZV0gPSBkZWZhdWx0X2JhdGNoX2xpbWl0W29w"
    "dHlwZV07Cgl9CgoJZXEtPmVsZXZhdG9yX2RhdGEgPSBhZDsKCglhZC0+aXNfcm90YXRpb25hbCA9ICFibGtfcXVldWVfbm9ucm90KHEpOwoJYWQtPmdsb2Jh"
    "bF9sYXRlbmN5X3dpbmRvdyA9IChhZC0+aXNfcm90YXRpb25hbCk/CgkJZGVmYXVsdF9nbG9iYWxfbGF0ZW5jeV93aW5kb3dfcm90YXRpb25hbDoKCQlkZWZh"
    "dWx0X2dsb2JhbF9sYXRlbmN5X3dpbmRvdzsKCWFkLT5icV9yZWZpbGxfYmVsb3dfcmF0aW8gPSBkZWZhdWx0X2JxX3JlZmlsbF9iZWxvd19yYXRpbzsKCWFk"
    "LT5sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCA9IGRlZmF1bHRfbGF0X21vZGVsX2xhdGVuY3lfbGltaXQ7CglhZC0+YmF0Y2hfb3JkZXIgPSBkZWZhdWx0X2Jh"
    "dGNoX29yZGVyOwoJYWQtPmNvbXBsaWFuY2VfZmxhZ3MgPSBkZWZhdWx0X2NvbXBsaWFuY2VfZmxhZ3M7CgoJYWQtPm1vZGVsc19zdGFibGUgPSBmYWxzZTsK"
    "CglhdG9taWNfc2V0KCZhZC0+c3RhdGUsIDApOwoKCXNwaW5fbG9ja19pbml0KCZhZC0+bG9jayk7CglzcGluX2xvY2tfaW5pdCgmYWQtPnBxX2xvY2spOwoJ"
    "c3Bpbl9sb2NrX2luaXQoJmFkLT5icV9sb2NrKTsKCgl0aW1lcl9zZXR1cCgmYWQtPnVwZGF0ZV90aW1lciwgdXBkYXRlX3RpbWVyX2NhbGxiYWNrLCAwKTsK"
    "CgkvKiBXZSBkaXNwYXRjaCBmcm9tIHJlcXVlc3QgcXVldWUgd2lkZSBpbnN0ZWFkIG9mIGh3IHF1ZXVlICovCgoJYWQtPnF1ZXVlID0gcTsKCWJsa19zdGF0"
    "X2VuYWJsZV9hY2NvdW50aW5nKHEpOwoKCXEtPmVsZXZhdG9yID0gZXE7CglyZXR1cm4gMDsKCmZyZWVfYnVja2V0czoKCXByX2VycigiYWRpb3M6IEZhaWxl"
    "ZCB0byBhbGxvY2F0ZSBwZXItY3B1IGJ1Y2tldHNcbiIpOwoJd2hpbGUgKG9wdHlwZS0tID4gMCkgewoJCXN0cnVjdCBsYXRlbmN5X21vZGVsICpwcmV2X21v"
    "ZGVsID0gJmFkLT5sYXRlbmN5X21vZGVsW29wdHlwZV07CgkJa2ZyZWUocmN1X2FjY2Vzc19wb2ludGVyKHByZXZfbW9kZWwtPnBhcmFtcykpOwoJCWZyZWVf"
    "cGVyY3B1KHByZXZfbW9kZWwtPnBjcHVfc25hcHNob3QpOwoJCWZyZWVfcGVyY3B1KHByZXZfbW9kZWwtPnBjcHVfYnVja2V0cyk7Cgl9CglmcmVlX3BlcmNw"
    "dShhZC0+cGNwdV9jb21wbGV0aW9uKTsKZnJlZV9hZ2dyX2J1Y2tldHM6CglrZnJlZShhZC0+YWdncl9idWNrZXRzKTsKZGVzdHJveV9kbF9ncm91cF9wb29s"
    "OgoJa21lbV9jYWNoZV9kZXN0cm95KGFkLT5kbF9ncm91cF9wb29sKTsKZGVzdHJveV9ycV9kYXRhX3Bvb2w6CgltZW1wb29sX2Rlc3Ryb3koYWQtPnJxX2Rh"
    "dGFfcG9vbCk7CmRlc3Ryb3lfcnFfZGF0YV9jYWNoZToKCWttZW1fY2FjaGVfZGVzdHJveShhZC0+cnFfZGF0YV9jYWNoZSk7CmZyZWVfYWQ6CglrZnJlZShh"
    "ZCk7CnB1dF9lcToKCWtvYmplY3RfcHV0KCZlcS0+a29iaik7CglyZXR1cm4gcmV0Owp9CgovLyBDbGVhbiB1cCBhbmQgZnJlZSByZXNvdXJjZXMgd2hlbiBl"
    "eGl0aW5nIHRoZSBzY2hlZHVsZXIKc3RhdGljIHZvaWQgYWRpb3NfZXhpdF9zY2hlZChzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUpIHsKCXN0cnVjdCBhZGlv"
    "c19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7CgoJZGVsX3RpbWVyX3N5bmMoJmFkLT51cGRhdGVfdGltZXIpOwoKCWZvciAoaW50IGkgPSAwOyBpIDwg"
    "MjsgaSsrKQoJCVdBUk5fT05fT05DRSghbGlzdF9lbXB0eSgmYWQtPnByaW9fcXVldWVbaV0pKTsKCglmb3IgKHU4IGogPSAwOyBqIDwgQURJT1NfT1BUWVBF"
    "UzsgaisrKSB7CgkJc3RydWN0IGxhdGVuY3lfbW9kZWwgKm1vZGVsID0gJmFkLT5sYXRlbmN5X21vZGVsW2pdOwoJCXN0cnVjdCBsYXRlbmN5X21vZGVsX3Bh"
    "cmFtcyAqcGFyYW1zID0gcmN1X2FjY2Vzc19wb2ludGVyKG1vZGVsLT5wYXJhbXMpOwoKCQlSQ1VfSU5JVF9QT0lOVEVSKG1vZGVsLT5wYXJhbXMsIE5VTEwp"
    "OwoJCWtmcmVlX3JjdShwYXJhbXMsIHJjdSk7CgoJCWZyZWVfcGVyY3B1KG1vZGVsLT5wY3B1X3NuYXBzaG90KTsKCQlmcmVlX3BlcmNwdShtb2RlbC0+cGNw"
    "dV9idWNrZXRzKTsKCX0KCglzeW5jaHJvbml6ZV9yY3UoKTsKCglmcmVlX3BlcmNwdShhZC0+cGNwdV9jb21wbGV0aW9uKTsKCWtmcmVlKGFkLT5hZ2dyX2J1"
    "Y2tldHMpOwoKCW1lbXBvb2xfZGVzdHJveShhZC0+cnFfZGF0YV9wb29sKTsKCWttZW1fY2FjaGVfZGVzdHJveShhZC0+cnFfZGF0YV9jYWNoZSk7CgoJaWYg"
    "KGFkLT5kbF9ncm91cF9wb29sKQoJCWttZW1fY2FjaGVfZGVzdHJveShhZC0+ZGxfZ3JvdXBfcG9vbCk7CgoJYmxrX3N0YXRfZGlzYWJsZV9hY2NvdW50aW5n"
    "KGFkLT5xdWV1ZSk7CgoJa2ZyZWUoYWQpOwp9CgpzdGF0aWMgdm9pZCBzaWRlbG9hZF9sYXRlbmN5X21vZGVsKAoJCXN0cnVjdCBsYXRlbmN5X21vZGVsICpt"
    "b2RlbCwgdTY0IGJhc2UsIHU2NCBzbG9wZSkgewoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpvbGRfcGFyYW1zLCAqbmV3X3BhcmFtczsKCXVuc2ln"
    "bmVkIGxvbmcgZmxhZ3M7CgoJbmV3X3BhcmFtcyA9IGt6YWxsb2Moc2l6ZW9mKCpuZXdfcGFyYW1zKSwgR0ZQX0tFUk5FTCk7CglpZiAoIW5ld19wYXJhbXMp"
    "CgkJcmV0dXJuOwoKCXNwaW5fbG9ja19pcnFzYXZlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsKCglvbGRfcGFyYW1zID0gcmN1X2RlcmVmZXJlbmNl"
    "X3Byb3RlY3RlZChtb2RlbC0+cGFyYW1zLAoJCQlsb2NrZGVwX2lzX2hlbGQoJm1vZGVsLT51cGRhdGVfbG9jaykpOwoKCW5ld19wYXJhbXMtPmxhc3RfdXBk"
    "YXRlX2ppZmZpZXMgPSBqaWZmaWVzOwoKCS8vIEluaXRpYWxpemUgYmFzZSBhbmQgaXRzIHN0YXRpc3RpY3MgYXMgYSBzaW5nbGUgc2FtcGxlLgoJbmV3X3Bh"
    "cmFtcy0+YmFzZSA9IGJhc2U7CgluZXdfcGFyYW1zLT5zbWFsbF9zdW1fZGVsYXkgPSBiYXNlOwoJbmV3X3BhcmFtcy0+c21hbGxfY291bnQgPSAxOwoKCS8v"
    "IEluaXRpYWxpemUgc2xvcGUgYW5kIGl0cyBzdGF0aXN0aWNzIGFzIGEgc2luZ2xlIHNhbXBsZS4KCW5ld19wYXJhbXMtPnNsb3BlID0gc2xvcGU7CgluZXdf"
    "cGFyYW1zLT5sYXJnZV9zdW1fZGVsYXkgPSBzbG9wZTsKCW5ld19wYXJhbXMtPmxhcmdlX3N1bV9ic2l6ZSA9IDEwMjQ7IC8qIENvcnJlc3BvbmRzIHRvIDEg"
    "S2lCICovCgoJbG1fcmVzZXRfcGNwdV9idWNrZXRzKG1vZGVsKTsKCglyY3VfYXNzaWduX3BvaW50ZXIobW9kZWwtPnBhcmFtcywgbmV3X3BhcmFtcyk7Cglz"
    "cGluX3VubG9ja19pcnFyZXN0b3JlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsKCglrZnJlZV9yY3Uob2xkX3BhcmFtcywgcmN1KTsKfQoKLy8gRGVm"
    "aW5lIHN5c2ZzIGF0dHJpYnV0ZXMgZm9yIG9wZXJhdGlvbiB0eXBlcwojZGVmaW5lIFNZU0ZTX09QVFlQRV9ERUNMKG5hbWUsIG9wdHlwZSkgXApzdGF0aWMg"
    "c3NpemVfdCBhZGlvc19sYXRfbW9kZWxfIyNuYW1lIyNfc2hvdyggXAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY2hhciAqcGFnZSkgeyBcCglzdHJ1"
    "Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBcCglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxb"
    "b3B0eXBlXTsgXAoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXM7IFwKCXNzaXplX3QgbGVuID0gMDsgXAoJdTY0IGJhc2UsIHNsb3BlOyBc"
    "CglyY3VfcmVhZF9sb2NrKCk7IFwKCXBhcmFtcyA9IHJjdV9kZXJlZmVyZW5jZShtb2RlbC0+cGFyYW1zKTsgXAoJYmFzZSA9IHBhcmFtcy0+YmFzZTsgXAoJ"
    "c2xvcGUgPSBwYXJhbXMtPnNsb3BlOyBcCglyY3VfcmVhZF91bmxvY2soKTsgXAoJbGVuICs9IHNwcmludGYocGFnZSwgICAgICAgImJhc2UgOiAlbGx1IG5z"
    "XG4iLCBiYXNlKTsgXAoJbGVuICs9IHNwcmludGYocGFnZSArIGxlbiwgInNsb3BlOiAlbGx1IG5zL0tpQlxuIiwgc2xvcGUpOyBcCglyZXR1cm4gbGVuOyBc"
    "Cn0gXApzdGF0aWMgc3NpemVfdCBhZGlvc19sYXRfbW9kZWxfIyNuYW1lIyNfc3RvcmUoIFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNvbnN0IGNo"
    "YXIgKnBhZ2UsIHNpemVfdCBjb3VudCkgeyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBcCglzdHJ1Y3QgbGF0ZW5jeV9t"
    "b2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBlXTsgXAoJdTY0IGJhc2UsIHNsb3BlOyBcCglpbnQgcmV0OyBcCglyZXQgPSBzc2NhbmYo"
    "cGFnZSwgIiVsbHUgJWxsdSIsICZiYXNlLCAmc2xvcGUpOyBcCglpZiAocmV0ICE9IDIpIFwKCQlyZXR1cm4gLUVJTlZBTDsgXAoJc2lkZWxvYWRfbGF0ZW5j"
    "eV9tb2RlbChtb2RlbCwgYmFzZSwgc2xvcGUpOyBcCglyZXNldF9idWNrZXRzKGFkLT5hZ2dyX2J1Y2tldHMpOyBcCglyZXR1cm4gY291bnQ7IFwKfSBcCnN0"
    "YXRpYyBzc2l6ZV90IGFkaW9zX2xhdF90YXJnZXRfIyNuYW1lIyNfc2hvdyggXAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY2hhciAqcGFnZSkgeyBc"
    "CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBcCglyZXR1cm4gc3ByaW50ZihwYWdlLCAiJWxsdVxuIiwgYWQtPmxhdGVuY3lf"
    "dGFyZ2V0W29wdHlwZV0pOyBcCn0gXApzdGF0aWMgc3NpemVfdCBhZGlvc19sYXRfdGFyZ2V0XyMjbmFtZSMjX3N0b3JlKCBcCgkJc3RydWN0IGVsZXZhdG9y"
    "X3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3QgY291bnQpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsg"
    "XAoJdW5zaWduZWQgbG9uZyBuc2VjOyBcCglpbnQgcmV0OyBcCglyZXQgPSBrc3RydG91bChwYWdlLCAxMCwgJm5zZWMpOyBcCglpZiAocmV0KSBcCgkJcmV0"
    "dXJuIHJldDsgXAoJc2lkZWxvYWRfbGF0ZW5jeV9tb2RlbCgmYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBlXSwgMCwgMCk7IFwKCWFkLT5sYXRlbmN5X3Rhcmdl"
    "dFtvcHR5cGVdID0gbnNlYzsgXAoJcmV0dXJuIGNvdW50OyBcCn0gXApzdGF0aWMgc3NpemVfdCBhZGlvc19iYXRjaF9saW1pdF8jI25hbWUjI19zaG93KCBc"
    "CgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjaGFyICpwYWdlKSB7IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwK"
    "CXJldHVybiBzcHJpbnRmKHBhZ2UsICIldVxuIiwgYWQtPmJhdGNoX2xpbWl0W29wdHlwZV0pOyBcCn0gXApzdGF0aWMgc3NpemVfdCBhZGlvc19iYXRjaF9s"
    "aW1pdF8jI25hbWUjI19zdG9yZSggXAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY29uc3QgY2hhciAqcGFnZSwgc2l6ZV90IGNvdW50KSB7IFwKCXVu"
    "c2lnbmVkIGxvbmcgbWF4X2JhdGNoOyBcCglpbnQgcmV0OyBcCglyZXQgPSBrc3RydG91bChwYWdlLCAxMCwgJm1heF9iYXRjaCk7IFwKCWlmIChyZXQgfHwg"
    "bWF4X2JhdGNoID09IDApIFwKCQlyZXR1cm4gLUVJTlZBTDsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsgXAoJYWQtPmJh"
    "dGNoX2xpbWl0W29wdHlwZV0gPSBtYXhfYmF0Y2g7IFwKCXJldHVybiBjb3VudDsgXAp9CgpTWVNGU19PUFRZUEVfREVDTChyZWFkLCBBRElPU19SRUFEKTsK"
    "U1lTRlNfT1BUWVBFX0RFQ0wod3JpdGUsIEFESU9TX1dSSVRFKTsKU1lTRlNfT1BUWVBFX0RFQ0woZGlzY2FyZCwgQURJT1NfRElTQ0FSRCk7CgovLyBTaG93"
    "IHRoZSBtYXhpbXVtIGJhdGNoIHNpemUgYWN0dWFsbHkgYWNoaWV2ZWQgZm9yIGVhY2ggb3BlcmF0aW9uIHR5cGUKc3RhdGljIHNzaXplX3QgYWRpb3NfYmF0"
    "Y2hfYWN0dWFsX21heF9zaG93KAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY2hhciAqcGFnZSkgewoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+"
    "ZWxldmF0b3JfZGF0YTsKCXUzMiB0b3RhbF9jb3VudCwgcmVhZF9jb3VudCwgd3JpdGVfY291bnQsIGRpc2NhcmRfY291bnQ7CgoJdG90YWxfY291bnQgPSBh"
    "ZC0+YmF0Y2hfYWN0dWFsX21heF90b3RhbDsKCXJlYWRfY291bnQgPSBhZC0+YmF0Y2hfYWN0dWFsX21heF9zaXplW0FESU9TX1JFQURdOwoJd3JpdGVfY291"
    "bnQgPSBhZC0+YmF0Y2hfYWN0dWFsX21heF9zaXplW0FESU9TX1dSSVRFXTsKCWRpc2NhcmRfY291bnQgPSBhZC0+YmF0Y2hfYWN0dWFsX21heF9zaXplW0FE"
    "SU9TX0RJU0NBUkRdOwoKCXJldHVybiBzcHJpbnRmKHBhZ2UsCgkJIlRvdGFsICA6ICV1XG5EaXNjYXJkOiAldVxuUmVhZCAgIDogJXVcbldyaXRlICA6ICV1"
    "XG4iLAoJCXRvdGFsX2NvdW50LCBkaXNjYXJkX2NvdW50LCByZWFkX2NvdW50LCB3cml0ZV9jb3VudCk7Cn0KCiNkZWZpbmUgU1lTRlNfVUxMX0RFQ0woZmll"
    "bGQsIG1pbl92YWwsIG1heF92YWwpIFwKc3RhdGljIHNzaXplX3QgYWRpb3NfIyNmaWVsZCMjX3Nob3coIFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUs"
    "IGNoYXIgKnBhZ2UpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsgXAoJcmV0dXJuIHNwcmludGYocGFnZSwgIiVsbHVc"
    "biIsIGFkLT5maWVsZCk7IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zXyMjZmllbGQjI19zdG9yZSggXAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwg"
    "Y29uc3QgY2hhciAqcGFnZSwgc2l6ZV90IGNvdW50KSB7IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXVuc2lnbmVk"
    "IGxvbmcgdmFsOyBcCglpbnQgcmV0OyBcCglyZXQgPSBrc3RydG91bChwYWdlLCAxMCwgJnZhbCk7IFwKCWlmIChyZXQgfHwgdmFsIDwgKG1pbl92YWwpIHx8"
    "IHZhbCA+IChtYXhfdmFsKSkgXAoJCXJldHVybiAtRUlOVkFMOyBcCglhZC0+ZmllbGQgPSB2YWw7IFwKCXJldHVybiBjb3VudDsgXAp9CgpTWVNGU19VTExf"
    "REVDTChnbG9iYWxfbGF0ZW5jeV93aW5kb3csIDAsIFVMTE9OR19NQVgpClNZU0ZTX1VMTF9ERUNMKGNvbXBsaWFuY2VfZmxhZ3MsIDAsIFVMTE9OR19NQVgp"
    "CgojZGVmaW5lIFNZU0ZTX0lOVF9ERUNMKGZpZWxkLCBtaW5fdmFsLCBtYXhfdmFsKSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zXyMjZmllbGQjI19zaG93KCBc"
    "CgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjaGFyICpwYWdlKSB7IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwK"
    "CXJldHVybiBzcHJpbnRmKHBhZ2UsICIlZFxuIiwgYWQtPmZpZWxkKTsgXAp9IFwKc3RhdGljIHNzaXplX3QgYWRpb3NfIyNmaWVsZCMjX3N0b3JlKCBcCgkJ"
    "c3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3QgY291bnQpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+"
    "ZWxldmF0b3JfZGF0YTsgXAoJaW50IHZhbDsgXAoJaW50IHJldDsgXAoJcmV0ID0ga3N0cnRvaW50KHBhZ2UsIDEwLCAmdmFsKTsgXAoJaWYgKHJldCB8fCB2"
    "YWwgPCAobWluX3ZhbCkgfHwgdmFsID4gKG1heF92YWwpKSBcCgkJcmV0dXJuIC1FSU5WQUw7IFwKCWFkLT5maWVsZCA9IHZhbDsgXAoJcmV0dXJuIGNvdW50"
    "OyBcCn0KClNZU0ZTX0lOVF9ERUNMKGJxX3JlZmlsbF9iZWxvd19yYXRpbywgMCwgMTAwKQpTWVNGU19JTlRfREVDTChsYXRfbW9kZWxfbGF0ZW5jeV9saW1p"
    "dCwgMCwgMipOU0VDX1BFUl9TRUMpClNZU0ZTX0lOVF9ERUNMKGJhdGNoX29yZGVyLCBBRElPU19CT19PUFRZUEUsICEhYWQtPmlzX3JvdGF0aW9uYWwpCgov"
    "LyBTaG93IHRoZSByZWFkIHByaW9yaXR5CnN0YXRpYyBzc2l6ZV90IGFkaW9zX3JlYWRfcHJpb3JpdHlfc2hvdygKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUg"
    "KmUsIGNoYXIgKnBhZ2UpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7CglyZXR1cm4gc3ByaW50ZihwYWdlLCAiJWRcbiIs"
    "IGFkLT5kbF9wcmlvWzBdKTsKfQoKLy8gU2V0IHRoZSByZWFkIHByaW9yaXR5CnN0YXRpYyBzc2l6ZV90IGFkaW9zX3JlYWRfcHJpb3JpdHlfc3RvcmUoCgkJ"
    "c3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3QgY291bnQpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVs"
    "ZXZhdG9yX2RhdGE7CglpbnQgcHJpbzsKCWludCByZXQ7CgoJcmV0ID0ga3N0cnRvaW50KHBhZ2UsIDEwLCAmcHJpbyk7CglpZiAocmV0IHx8IHByaW8gPCAt"
    "MjAgfHwgcHJpbyA+IDE5KQoJCXJldHVybiAtRUlOVkFMOwoKCWFkaW9zX2d1YXJkKHNwaW5sb2NrX2lycXNhdmUpKCZhZC0+bG9jayk7CglhZC0+ZGxfcHJp"
    "b1swXSA9IHByaW87CglhZC0+ZGxfYmlhcyA9IDA7CgoJcmV0dXJuIGNvdW50Owp9CgovLyBSZXNldCBiYXRjaCBxdWV1ZSBzdGF0aXN0aWNzCnN0YXRpYyBz"
    "c2l6ZV90IGFkaW9zX3Jlc2V0X2JxX3N0YXRzX3N0b3JlKAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY29uc3QgY2hhciAqcGFnZSwgc2l6ZV90IGNv"
    "dW50KSB7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOwoJdW5zaWduZWQgbG9uZyB2YWw7CglpbnQgcmV0OwoKCXJldCA9IGtz"
    "dHJ0b3VsKHBhZ2UsIDEwLCAmdmFsKTsKCWlmIChyZXQgfHwgdmFsICE9IDEpCgkJcmV0dXJuIC1FSU5WQUw7CgoJZm9yICh1OCBpID0gMDsgaSA8IEFESU9T"
    "X09QVFlQRVM7IGkrKykKCQlhZC0+YmF0Y2hfYWN0dWFsX21heF9zaXplW2ldID0gMDsKCglhZC0+YmF0Y2hfYWN0dWFsX21heF90b3RhbCA9IDA7CgoJcmV0"
    "dXJuIGNvdW50Owp9CgovLyBSZXNldCB0aGUgbGF0ZW5jeSBtb2RlbCBwYXJhbWV0ZXJzIG9yIGxvYWQgdGhlbSBmcm9tIHVzZXIgaW5wdXQKc3RhdGljIHNz"
    "aXplX3QgYWRpb3NfcmVzZXRfbGF0X21vZGVsX3N0b3JlKAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY29uc3QgY2hhciAqcGFnZSwgc2l6ZV90IGNv"
    "dW50KQp7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOwoJc3RydWN0IGxhdGVuY3lfbW9kZWwgKm1vZGVsOwoJaW50IHJldDsK"
    "CgkvKgoJICogRGlmZmVyZW50aWF0ZSBiZXR3ZWVuIHR3byBtb2RlcyBiYXNlZCBvbiBpbnB1dCBmb3JtYXQ6CgkgKiAxLiAiMSI6IEZ1bGx5IHJlc2V0IHRo"
    "ZSBtb2RlbCAoYmFja3dhcmQgY29tcGF0aWJpbGl0eSkuCgkgKiAyLiAiUl9iYXNlIFJfc2xvcGUgV19iYXNlIFdfc2xvcGUgRF9iYXNlIERfc2xvcGUiOiBM"
    "b2FkIHZhbHVlcy4KCSAqLwoJaWYgKCFzdHJjaHIocGFnZSwgJyAnKSkgewoJCS8vIE1vZGUgMTogRnVsbCByZXNldC4KCQl1bnNpZ25lZCBsb25nIHZhbDsK"
    "CgkJcmV0ID0ga3N0cnRvdWwocGFnZSwgMTAsICZ2YWwpOwoJCWlmIChyZXQgfHwgdmFsICE9IDEpCgkJCXJldHVybiAtRUlOVkFMOwoKCQlmb3IgKHU4IGkg"
    "PSAwOyBpIDwgQURJT1NfT1BUWVBFUzsgaSsrKSB7CgkJCW1vZGVsID0gJmFkLT5sYXRlbmN5X21vZGVsW2ldOwoJCQlzaWRlbG9hZF9sYXRlbmN5X21vZGVs"
    "KG1vZGVsLCAwLCAwKTsKCQl9Cgl9IGVsc2UgewoJCS8vIE1vZGUgMjogTG9hZCBpbml0aWFsIHZhbHVlcyBmb3IgYWxsIGxhdGVuY3kgbW9kZWxzLgoJCXU2"
    "NCBwYXJhbXNbM11bMl07IC8qIDA6YmFzZSwgMTpzbG9wZSBmb3IgUiwgVywgRCAqLwoKCQlyZXQgPSBzc2NhbmYocGFnZSwgIiVsbHUgJWxsdSAlbGx1ICVs"
    "bHUgJWxsdSAlbGx1IiwKCQkJJnBhcmFtc1tBRElPU19SRUFEICAgXVswXSwgJnBhcmFtc1tBRElPU19SRUFEICAgXVsxXSwKCQkJJnBhcmFtc1tBRElPU19X"
    "UklURSAgXVswXSwgJnBhcmFtc1tBRElPU19XUklURSAgXVsxXSwKCQkJJnBhcmFtc1tBRElPU19ESVNDQVJEXVswXSwgJnBhcmFtc1tBRElPU19ESVNDQVJE"
    "XVsxXSk7CgoJCWlmIChyZXQgIT0gNikKCQkJcmV0dXJuIC1FSU5WQUw7CgoJCWZvciAodTggaSA9IEFESU9TX1JFQUQ7IGkgPD0gQURJT1NfRElTQ0FSRDsg"
    "aSsrKSB7CgkJCW1vZGVsID0gJmFkLT5sYXRlbmN5X21vZGVsW2ldOwoJCQlzaWRlbG9hZF9sYXRlbmN5X21vZGVsKG1vZGVsLCBwYXJhbXNbaV1bMF0sIHBh"
    "cmFtc1tpXVsxXSk7CgkJfQoJfQoJcmVzZXRfYnVja2V0cyhhZC0+YWdncl9idWNrZXRzKTsKCglyZXR1cm4gY291bnQ7Cn0KCi8vIFNob3cgdGhlIEFESU9T"
    "IHZlcnNpb24Kc3RhdGljIHNzaXplX3QgYWRpb3NfdmVyc2lvbl9zaG93KHN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY2hhciAqcGFnZSkgewoJcmV0dXJu"
    "IHNwcmludGYocGFnZSwgIiVzXG4iLCBBRElPU19WRVJTSU9OKTsKfQoKLy8gRGVmaW5lIHN5c2ZzIGF0dHJpYnV0ZXMgZm9yIGR5bmFtaWMgdGhyZXNob2xk"
    "cwojZGVmaW5lIFNIUklOS19USFJFU0hPTERfQVRUUl9SVyhuYW1lLCBtb2RlbF9maWVsZCwgbWluX3ZhbHVlLCBtYXhfdmFsdWUpIFwKc3RhdGljIHNzaXpl"
    "X3QgYWRpb3Nfc2hyaW5rXyMjbmFtZSMjX3N0b3JlKCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3QgY291"
    "bnQpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsgXAoJdW5zaWduZWQgbG9uZyB2YWw7IFwKCWludCByZXQ7IFwKCXJl"
    "dCA9IGtzdHJ0b3VsKHBhZ2UsIDEwLCAmdmFsKTsgXAoJaWYgKHJldCB8fCB2YWwgPCBtaW5fdmFsdWUgfHwgdmFsID4gbWF4X3ZhbHVlKSBcCgkJcmV0dXJu"
    "IC1FSU5WQUw7IFwKCWZvciAodTggaSA9IDA7IGkgPCBBRElPU19PUFRZUEVTOyBpKyspIHsgXAoJCXN0cnVjdCBsYXRlbmN5X21vZGVsICptb2RlbCA9ICZh"
    "ZC0+bGF0ZW5jeV9tb2RlbFtpXTsgXAoJCXVuc2lnbmVkIGxvbmcgZmxhZ3M7IFwKCQlzcGluX2xvY2tfaXJxc2F2ZSgmbW9kZWwtPnVwZGF0ZV9sb2NrLCBm"
    "bGFncyk7IFwKCQltb2RlbC0+bW9kZWxfZmllbGQgPSB2YWw7IFwKCQlzcGluX3VubG9ja19pcnFyZXN0b3JlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdz"
    "KTsgXAoJfSBcCglyZXR1cm4gY291bnQ7IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zX3Nocmlua18jI25hbWUjI19zaG93KCBcCgkJc3RydWN0IGVsZXZh"
    "dG9yX3F1ZXVlICplLCBjaGFyICpwYWdlKSB7IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXUzMiB2YWwgPSAwOyBc"
    "Cgl1bnNpZ25lZCBsb25nIGZsYWdzOyBcCglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbMF07IFwKCXNwaW5fbG9j"
    "a19pcnFzYXZlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsgXAoJdmFsID0gbW9kZWwtPm1vZGVsX2ZpZWxkOyBcCglzcGluX3VubG9ja19pcnFyZXN0"
    "b3JlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsgXAoJcmV0dXJuIHNwcmludGYocGFnZSwgIiV1XG4iLCB2YWwpOyBcCn0KClNIUklOS19USFJFU0hP"
    "TERfQVRUUl9SVyhhdF9rcmVxcywgIGxtX3Nocmlua19hdF9rcmVxcywgIDEsIDEwMDAwMCkKU0hSSU5LX1RIUkVTSE9MRF9BVFRSX1JXKGF0X2dieXRlcywg"
    "bG1fc2hyaW5rX2F0X2dieXRlcywgMSwgICAxMDAwKQpTSFJJTktfVEhSRVNIT0xEX0FUVFJfUlcocmVzaXN0LCAgICBsbV9zaHJpbmtfcmVzaXN0LCAgICAx"
    "LCAgICAgIDMpCgovLyBEZWZpbmUgc3lzZnMgYXR0cmlidXRlcwojZGVmaW5lIEFEX0FUVFIobmFtZSwgc2hvd19mdW5jLCBzdG9yZV9mdW5jKSBcCglfX0FU"
    "VFIobmFtZSwgMDY0NCwgc2hvd19mdW5jLCBzdG9yZV9mdW5jKQojZGVmaW5lIEFEX0FUVFJfUlcobmFtZSkgXAoJX19BVFRSKG5hbWUsIDA2NDQsIGFkaW9z"
    "XyMjbmFtZSMjX3Nob3csIGFkaW9zXyMjbmFtZSMjX3N0b3JlKQojZGVmaW5lIEFEX0FUVFJfUk8obmFtZSkgXAoJX19BVFRSKG5hbWUsIDA0NDQsIGFkaW9z"
    "XyMjbmFtZSMjX3Nob3csIE5VTEwpCiNkZWZpbmUgQURfQVRUUl9XTyhuYW1lKSBcCglfX0FUVFIobmFtZSwgMDIwMCwgTlVMTCwgYWRpb3NfIyNuYW1lIyNf"
    "c3RvcmUpCgovLyBEZWZpbmUgc3lzZnMgYXR0cmlidXRlcyBmb3IgQURJT1Mgc2NoZWR1bGVyCnN0YXRpYyBzdHJ1Y3QgZWx2X2ZzX2VudHJ5IGFkaW9zX3Nj"
    "aGVkX2F0dHJzW10gPSB7CglBRF9BVFRSX1JPKGJhdGNoX2FjdHVhbF9tYXgpLAoJQURfQVRUUl9SVyhicV9yZWZpbGxfYmVsb3dfcmF0aW8pLAoJQURfQVRU"
    "Ul9SVyhnbG9iYWxfbGF0ZW5jeV93aW5kb3cpLAoJQURfQVRUUl9SVyhsYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCksCglBRF9BVFRSX1JXKGJhdGNoX29yZGVy"
    "KSwKCUFEX0FUVFJfUlcoY29tcGxpYW5jZV9mbGFncyksCgoJQURfQVRUUl9SVyhiYXRjaF9saW1pdF9yZWFkKSwKCUFEX0FUVFJfUlcoYmF0Y2hfbGltaXRf"
    "d3JpdGUpLAoJQURfQVRUUl9SVyhiYXRjaF9saW1pdF9kaXNjYXJkKSwKCglBRF9BVFRSX1JXKGxhdF9tb2RlbF9yZWFkKSwKCUFEX0FUVFJfUlcobGF0X21v"
    "ZGVsX3dyaXRlKSwKCUFEX0FUVFJfUlcobGF0X21vZGVsX2Rpc2NhcmQpLAoKCUFEX0FUVFJfUlcobGF0X3RhcmdldF9yZWFkKSwKCUFEX0FUVFJfUlcobGF0"
    "X3RhcmdldF93cml0ZSksCglBRF9BVFRSX1JXKGxhdF90YXJnZXRfZGlzY2FyZCksCgoJQURfQVRUUl9SVyhzaHJpbmtfYXRfa3JlcXMpLAoJQURfQVRUUl9S"
    "VyhzaHJpbmtfYXRfZ2J5dGVzKSwKCUFEX0FUVFJfUlcoc2hyaW5rX3Jlc2lzdCksCgoJQURfQVRUUl9SVyhyZWFkX3ByaW9yaXR5KSwKCglBRF9BVFRSX1dP"
    "KHJlc2V0X2JxX3N0YXRzKSwKCUFEX0FUVFJfV08ocmVzZXRfbGF0X21vZGVsKSwKCUFEX0FUVFIoYWRpb3NfdmVyc2lvbiwgYWRpb3NfdmVyc2lvbl9zaG93"
    "LCBOVUxMKSwKCglfX0FUVFJfTlVMTAp9OwoKLy8gRGVmaW5lIHRoZSBBRElPUyBzY2hlZHVsZXIgdHlwZQpzdGF0aWMgc3RydWN0IGVsZXZhdG9yX3R5cGUg"
    "bXFfYWRpb3MgPSB7Cgkub3BzID0gewoJCS5uZXh0X3JlcXVlc3QJCT0gZWx2X3JiX2xhdHRlcl9yZXF1ZXN0LAoJCS5mb3JtZXJfcmVxdWVzdAkJPSBlbHZf"
    "cmJfZm9ybWVyX3JlcXVlc3QsCgkJLmxpbWl0X2RlcHRoCQk9IGFkaW9zX2xpbWl0X2RlcHRoLAoJCS5kZXB0aF91cGRhdGVkCQk9IGFkaW9zX2RlcHRoX3Vw"
    "ZGF0ZWQsCgkJLnJlcXVlc3RfbWVyZ2VkCQk9IGFkaW9zX3JlcXVlc3RfbWVyZ2VkLAoJCS5yZXF1ZXN0c19tZXJnZWQJPSBhZGlvc19tZXJnZWRfcmVxdWVz"
    "dHMsCgkJLmJpb19tZXJnZQkJCT0gYWRpb3NfYmlvX21lcmdlLAoJCS5pbnNlcnRfcmVxdWVzdHMJPSBhZGlvc19pbnNlcnRfcmVxdWVzdHMsCgkJLnByZXBh"
    "cmVfcmVxdWVzdAk9IGFkaW9zX3ByZXBhcmVfcmVxdWVzdCwKCQkuZGlzcGF0Y2hfcmVxdWVzdAk9IGFkaW9zX2Rpc3BhdGNoX3JlcXVlc3QsCgkJLmNvbXBs"
    "ZXRlZF9yZXF1ZXN0CT0gYWRpb3NfY29tcGxldGVkX3JlcXVlc3QsCgkJLmZpbmlzaF9yZXF1ZXN0CQk9IGFkaW9zX2ZpbmlzaF9yZXF1ZXN0LAoJCS5oYXNf"
    "d29yawkJCT0gYWRpb3NfaGFzX3dvcmssCgkJLmluaXRfaGN0eAkJCT0gYWRpb3NfaW5pdF9oY3R4LAoJCS5pbml0X3NjaGVkCQkJPSBhZGlvc19pbml0X3Nj"
    "aGVkLAoJCS5leGl0X3NjaGVkCQkJPSBhZGlvc19leGl0X3NjaGVkLAoJfSwKCS5lbGV2YXRvcl9hdHRycyA9IGFkaW9zX3NjaGVkX2F0dHJzLAoJLmVsZXZh"
    "dG9yX25hbWUgPSAiYWRpb3MiLAoJLmVsZXZhdG9yX293bmVyID0gVEhJU19NT0RVTEUsCn07Ck1PRFVMRV9BTElBUygibXEtYWRpb3MtaW9zY2hlZCIpOwoK"
    "I2RlZmluZSBBRElPU19QUk9HTkFNRSAiQWRhcHRpdmUgRGVhZGxpbmUgSS9PIFNjaGVkdWxlciIKI2RlZmluZSBBRElPU19BVVRIT1IgICAiTWFzYWhpdG8g"
    "U3V6dWtpIgoKLy8gSW5pdGlhbGl6ZSB0aGUgQURJT1Mgc2NoZWR1bGVyIG1vZHVsZQpzdGF0aWMgaW50IF9faW5pdCBhZGlvc19pbml0KHZvaWQpIHsKCXBy"
    "aW50ayhLRVJOX0lORk8gIiVzICVzIGJ5ICVzXG4iLAoJCUFESU9TX1BST0dOQU1FLCBBRElPU19WRVJTSU9OLCBBRElPU19BVVRIT1IpOwoJcmV0dXJuIGVs"
    "dl9yZWdpc3RlcigmbXFfYWRpb3MpOwp9CgovLyBFeGl0IHRoZSBBRElPUyBzY2hlZHVsZXIgbW9kdWxlCnN0YXRpYyB2b2lkIF9fZXhpdCBhZGlvc19leGl0"
    "KHZvaWQpIHsKCWVsdl91bnJlZ2lzdGVyKCZtcV9hZGlvcyk7Cn0KCm1vZHVsZV9pbml0KGFkaW9zX2luaXQpOwptb2R1bGVfZXhpdChhZGlvc19leGl0KTsK"
    "Ck1PRFVMRV9BVVRIT1IoQURJT1NfQVVUSE9SKTsKTU9EVUxFX0xJQ0VOU0UoIkdQTCIpOwpNT0RVTEVfREVTQ1JJUFRJT04oQURJT1NfUFJPR05BTUUpOwo="
)
with open(os.path.join(blk, "adios.c"), "wb") as f:
    f.write(src)

kc = os.path.join(blk, "Kconfig.iosched")
s = open(kc).read()
if "config MQ_IOSCHED_ADIOS" not in s:
    s += """
config MQ_IOSCHED_ADIOS
	tristate "Adaptive Deadline I/O scheduler"
	depends on BLOCK
	default n
	help
	  Adaptive Deadline I/O Scheduler (ADIOS), ported to 5.4 for veux.
	  This is a 5.4 compatibility port: request-to-request merging is
	  disabled and the sysreg stack-canary path is not used.

"""
    open(kc, "w").write(s)

mk = os.path.join(blk, "Makefile")
s = open(mk).read()
if "adios.o" not in s:
    s += "\nobj-$(CONFIG_MQ_IOSCHED_ADIOS) += adios.o\n"
    open(mk, "w").write(s)
PY
	info "ADIOS 5.4 port installed (block/adios.c + Kconfig + Makefile)"
	endgroup
}

			# Expose all hardware LUT frequencies by bypassing the DTB's
			# qcom,cpufreq-table filter. DTB itself is NOT replaced, so
			# wifi/touch/display stay on the ROM's known-good DTB.
			CPUFREQ_C="${KERNEL_DIR}/drivers/cpufreq/qcom-cpufreq-hw.c"
			if [ -f "$CPUFREQ_C" ] && grep -q 'of_find_freq' "$CPUFREQ_C"; then
				python3 - "$CPUFREQ_C" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = (
    'static bool of_find_freq(u32 *of_table, int of_len, long frequency)\n'
    '{\n'
    '\tint i;\n'
    '\n'
    '\tif (!of_table)\n'
    '\t\treturn true;\n'
    '\n'
    '\tfor (i = 0; i < of_len; i++) {\n'
    '\t\tif (frequency == of_table[i])\n'
    '\t\t\treturn true;\n'
    '\t}\n'
    '\n'
    '\treturn false;\n'
    '}'
)
new = (
    'static bool of_find_freq(u32 *of_table, int of_len, long frequency)\n'
    '{\n'
    '\t/* Ignore qcom,cpufreq-table from DTB: expose every hardware LUT OPP. */\n'
    '\treturn true;\n'
    '}'
)
if old in s:
    open(p, "w").write(s.replace(old, new, 1))
PY
				info "qcom-cpufreq-hw: DTB frequency filter bypassed"
			fi

			adios_apply

			# Order matters and this is the tested one (4.19 + SukiSU builtin
			# + SUSFS 1.5.5, no rejects):
			#   path_umount and the hook patches both key off textual anchors
			#   in files that SUSFS later rewrites, so they go first.
			if is_true "${ENABLE_PATH_UMOUNT:-false}"; then path_umount_apply; fi

			# Driven by the *resolved* hook mode, not the raw setting, so that
			# KSU_HOOK_MODE=auto on a pre-GKI kernel still gets its hooks
			# patched in rather than only getting the Kconfig symbol set.
			if [ "${KSU_VARIANT:-none}" != "none" ] &&
			   [ "${KSU_HOOK_MODE_RESOLVED:-}" = "manual" ]; then
				hooks_patch_apply
			fi

			if is_true "${ENABLE_SUSFS:-false}";      then susfs_apply;      fi
			if is_true "${ENABLE_HIDE_STUFF:-false}"; then hide_stuff_apply; fi
			;;
		*) die "unknown patch step '$1'" ;;
	esac
fi
