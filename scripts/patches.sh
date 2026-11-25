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
    "ZykKewoJc3Bpbl91bmxvY2tfaXJxcmVzdG9yZShnLT5sb2NrLCBnLmZsYWdzKTsKfQoKI2RlZmluZSBBRElPU19HVUFSRF9DQVQyKGEsIGIpIGEjI2IKI2Rl"
    "ZmluZSBBRElPU19HVUFSRF9DQVQoYSwgYikgQURJT1NfR1VBUkRfQ0FUMihhLCBiKQoKLyogYWRpb3NfZ3VhcmQoc3BpbmxvY2tfaXJxc2F2ZSkoJmxvY2sp"
    "ICovCiNkZWZpbmUgYWRpb3NfZ3VhcmQoLi4uKSBBRElPU19HVUFSRF9DQVQoYWRpb3NfZ3VhcmRfLCBfX1ZBX0FSR1NfXykKI2RlZmluZSBhZGlvc19ndWFy"
    "ZF9zcGlubG9ja19pcnFzYXZlKGxvY2spIFwKCXN0cnVjdCBhZGlvc19ndWFyZF9zcGlubG9ja19pcnFzYXZlIFwKCQlfX2F0dHJpYnV0ZV9fKChjbGVhbnVw"
    "KGFkaW9zX2d1YXJkX3NwaW5sb2NrX2lycXNhdmVfZmluaSkpKSBcCgkJQURJT1NfR1VBUkRfQ0FUKGFkb3NfZ3VhcmRfLCBfX0xJTkVfXykgPSBcCgkJYWRp"
    "b3NfZ3VhcmRfc3BpbmxvY2tfaXJxc2F2ZV9pbml0KGxvY2spCgovKiBhZGlvc19zY29wZWRfZ3VhcmQoc3BpbmxvY2tfaXJxc2F2ZSwgJmxvY2spIHsgLi4u"
    "IH0gKi8KI2RlZmluZSBhZGlvc19zY29wZWRfZ3VhcmQodHlwZSwgbG9jaykgXAoJZm9yIChzdHJ1Y3QgYWRpb3NfZ3VhcmRfc3BpbmxvY2tfaXJxc2F2ZSBh"
    "ZG9zX3NndWFyZF9fID0gXAoJCQlhZGlvc19ndWFyZF9zcGlubG9ja19pcnFzYXZlX2luaXQobG9jayk7IFwKCSAgICAgYWRvc19zZ3VhcmRfXy5sb2NrOyBc"
    "CgkgICAgICh7IHNwaW5fdW5sb2NrX2lycXJlc3RvcmUoYWRvc19zZ3VhcmRfXy5sb2NrLCBhZG9zX3NndWFyZF9fLmZsYWdzKTsgXAoJICAgICAgICBhZG9z"
    "X3NndWFyZF9fLmxvY2sgPSBOVUxMOyB9KSkKCgojZGVmaW5lIEFESU9TX1ZFUlNJT04gIjMuMy4wIgoKLyogUmVxdWVzdCBUeXBlczoKICoKICogVGllciAw"
    "IChIaWdoZXN0IFByaW9yaXR5KTogRW1lcmdlbmN5ICYgU3lzdGVtIEludGVncml0eSBSZXF1ZXN0cwogKiAtLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0t"
    "LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogKiAtIFRhcmdldDogUmVxdWVzdHMgd2l0aCB0aGUgQkxLX01RX0lOU0VSVF9BVF9IRUFE"
    "IGZsYWcuCiAqIC0gUHVycG9zZTogRm9yIGNyaXRpY2FsLCBub24tbmVnb3RpYWJsZSBvcGVyYXRpb25zIHN1Y2ggYXMgZGV2aWNlIGVycm9yCiAqICAgcmVj"
    "b3Zlcnkgb3IgZmx1c2ggc2VxdWVuY2VzIHRoYXQgbXVzdCBieXBhc3MgYWxsIG90aGVyIHNjaGVkdWxpbmcgbG9naWMuCiAqIC0gSW1wbGVtZW50YXRpb246"
    "IFBsYWNlZCBpbiBhIGRlZGljYXRlZCwgaGlnaC1wcmlvcml0eSBGSUZPIHF1ZXVlCiAqICAgKGBwcmlvX3F1ZXVlWzBdYCkgZm9yIGltbWVkaWF0ZSBkaXNw"
    "YXRjaC4KICoKICogVGllciAxIChNZWRpdW0gUHJpb3JpdHkpOiBBcHBsaWNhdGlvbiBSZXNwb25zaXZlbmVzcwogKiAtLS0tLS0tLS0tLS0tLS0tLS0tLS0t"
    "LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAqIC0gVGFyZ2V0OiBOb3JtYWwgc3luY2hyb25vdXMgcmVxdWVzdHMgKGUuZy4sIGZyb20gc3RhbmRh"
    "cmQgZmlsZSByZWFkcykuCiAqIC0gUHVycG9zZTogVG8gZW5zdXJlIGNvcnJlY3QgYXBwbGljYXRpb24gYmVoYXZpb3IgZm9yIG9wZXJhdGlvbnMgdGhhdAog"
    "KiAgIGRlcGVuZCBvbiBzZXF1ZW50aWFsIEkvTyBjb21wbGV0aW9uIChlLmcuLCBmaWxlIHN5c3RlbSBtb3VudHMpIGFuZCB0bwogKiAgIHByb3ZpZGUgbG93"
    "IGxhdGVuY3kgZm9yIGludGVyYWN0aXZlIGFwcGxpY2F0aW9ucy4KICogLSBJbXBsZW1lbnRhdGlvbjogVGhlIGRlYWRsaW5lIGZvciB0aGVzZSByZXF1ZXN0"
    "cyBpcyBzZXQgdG8gdGhlaXIgc3RhcnQKICogICB0aW1lIChgcnEtPnN0YXJ0X3RpbWVfbnNgKS4gVGhpcyBlZmZlY3RpdmVseSBlbmZvcmNlcyBGSUZPLWxp"
    "a2UgYmVoYXZpb3IKICogICB3aXRoaW4gdGhlIGRlYWRsaW5lLXNvcnRlZCByZWQtYmxhY2sgdHJlZSwgcHJldmVudGluZyBvdXQtb2Ytb3JkZXIKICogICBl"
    "eGVjdXRpb24gb2YgZGVwZW5kZW50IHN5bmNocm9ub3VzIG9wZXJhdGlvbnMuCiAqCiAqIFRpZXIgMiAoTm9ybWFsIFByaW9yaXR5KTogQmFja2dyb3VuZCBU"
    "aHJvdWdocHV0CiAqIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAqIC0gVGFyZ2V0OiBBc3luY2hyb25vdXMgcmVx"
    "dWVzdHMuCiAqIC0gUHVycG9zZTogVG8gbWF4aW1pemUgZGlzayB0aHJvdWdocHV0IGZvciBiYWNrZ3JvdW5kIHRhc2tzIHdoZXJlIGxhdGVuY3kKICogICBp"
    "cyBub3QgY3JpdGljYWwuCiAqIC0gSW1wbGVtZW50YXRpb246IFRoZXNlIGFyZSB0aGUgb25seSByZXF1ZXN0cyB3aGVyZSBBRElPUydzIGFkYXB0aXZlCiAq"
    "ICAgbGF0ZW5jeSBwcmVkaWN0aW9uIG1vZGVsIGlzIHVzZWQuIEEgZHluYW1pYyBkZWFkbGluZSBpcyBjYWxjdWxhdGVkIGJhc2VkCiAqICAgb24gdGhlIHBy"
    "ZWRpY3RlZCBJL08gbGF0ZW5jeSwgYWxsb3dpbmcgZm9yIGFnZ3Jlc3NpdmUgcmVvcmRlcmluZyB0bwogKiAgIG9wdGltaXplIEkvTyBlZmZpY2llbmN5Lgog"
    "KgogKiBJL08gYmFycmllciBndWFyYW50ZWVzIChSRVFfUFJFRkxVU0ggLyBSRVFfRlVBKSBhcmUgcHJvdmlkZWQgZW50aXJlbHkgYnkKICogdGhlIGJsb2Nr"
    "IGxheWVyJ3MgZmx1c2ggc3RhdGUgbWFjaGluZSAoYmxvY2svYmxrLWZsdXNoLmMpLCB3aGljaCBpcyB0aGUKICogbWVjaGFuaXNtIHRoYXQgcmVwbGFjZWQg"
    "d2hvbGUtcXVldWUgYmFycmllcnMgdXBzdHJlYW0gaW4gMi42LjM3LiBObwogKiBxdWV1ZS13aWRlIGJhcnJpZXIgaXMgaW1wbGVtZW50ZWQgb3IgbmVlZGVk"
    "IGhlcmU6CiAqIC0gYmxrX2luc2VydF9mbHVzaCgpIGFsd2F5cyBzdHJpcHMgUkVRX1BSRUZMVVNIIChhbmQgUkVRX0ZVQSB1bmxlc3MgdGhlCiAqICAgZGV2"
    "aWNlIHN1cHBvcnRzIGl0IGluIGhhcmR3YXJlKSBiZWZvcmUgYW55IHJlcXVlc3QgZXZlciByZWFjaGVzIHRoaXMKICogICBlbGV2YXRvcidzIC0+aW5zZXJ0"
    "X3JlcXVlc3RzKCksIGFuZCBhbHdheXMgc2V0cyBSRVFfU1lOQyBvbiBpdCwgc28gc3VjaAogKiAgIGEgcmVxdWVzdCBsYW5kcyBpbiBUaWVyIDEgKGltbWVk"
    "aWF0ZSBkZWFkbGluZSkgbGlrZSBhbnkgb3RoZXIKICogICBzeW5jaHJvbm91cyByZXF1ZXN0IC0tIG5ldmVyIGRlbGF5ZWQgYmVoaW5kIFRpZXIgMiByZW9y"
    "ZGVyaW5nLgogKiAtIFRoZSBkYXRhIHBvcnRpb24gb2YgYSByZXF1ZXN0IHRoYXQgbmVlZGVkIGFuIGFjdHVhbCBQUkVGTFVTSCBpcwogKiAgIHJlc3VibWl0"
    "dGVkIHZpYSBCTEtfTVFfSU5TRVJUX0FUX0hFQUQgb25jZSB0aGUgZmx1c2ggY29tcGxldGVzLCB3aGljaAogKiAgIGxhbmRzIGluIFRpZXIgMCBoZXJlLCBh"
    "aGVhZCBvZiBldmVyeXRoaW5nIGVsc2UuCiAqIC0gUkVRX1BSRUZMVVNIL1JFUV9GVUEgYW5kIFJRRl9GTFVTSF9TRVEgcmVxdWVzdHMgYXJlIGFscmVhZHkg"
    "ZXhjbHVkZWQKICogICBmcm9tIGJpby9yZXF1ZXN0IG1lcmdpbmcgYnkgdGhlIGdlbmVyaWMgYmxvY2sgbGF5ZXIgKHJxX21lcmdlYWJsZSgpLAogKiAgIGJs"
    "a19ycV9tZXJnZV9vaygpKSBiZWZvcmUgdGhpcyBlbGV2YXRvcidzIG1lcmdlIGNhbGxiYWNrcyBldmVyIHJ1bi4KICogLSBUaGUgc3ludGhlc2l6ZWQgcHVy"
    "ZSBSRVFfT1BfRkxVU0ggY29tbWFuZCBpdHNlbGYgYWx3YXlzIGJ5cGFzc2VzIHRoaXMKICogICBlbGV2YXRvciBlbnRpcmVseSAoYmxrX21xX2luc2VydF9y"
    "ZXF1ZXN0KCkgcm91dGVzIGl0IHN0cmFpZ2h0IHRvCiAqICAgaGN0eC0+ZGlzcGF0Y2gpLCBzbyBpdCBuZXZlciBuZWVkcyB0byBiZSByZWNvZ25pemVkIG9y"
    "IGhhbmRsZWQgaGVyZS4KICoKICogRGlzcGF0Y2ggTG9naWM6CiAqIFRoZSBzY2hlZHVsZXIgYWx3YXlzIGRpc3BhdGNoZXMgcmVxdWVzdHMgaW4gc3RyaWN0"
    "IHByaW9yaXR5IG9yZGVyOgogKiAxLiBwcmlvX3F1ZXVlWzBdIChUaWVyIDApCiAqIDIuIFRoZSBkZWFkbGluZS1zb3J0ZWQgYmF0Y2ggcXVldWUgKHdoaWNo"
    "IG5hdHVyYWxseSBwcmlvcml0aXplcyBUaWVyIDEKICogICAgb3ZlciBUaWVyIDIgZHVlIHRvIHRoZWlyIGNhbGN1bGF0ZWQgZGVhZGxpbmVzKS4KICovCgov"
    "LyBHbG9iYWwgdmFyaWFibGUgdG8gY29udHJvbCB0aGUgbGF0ZW5jeQpzdGF0aWMgdTY0IGRlZmF1bHRfZ2xvYmFsX2xhdGVuY3lfd2luZG93ICAgICAgICAg"
    "ICAgPSAxNjAwMDAwMFVMTDsKc3RhdGljIHU2NCBkZWZhdWx0X2dsb2JhbF9sYXRlbmN5X3dpbmRvd19yb3RhdGlvbmFsID0gMjIwMDAwMDBVTEw7Ci8vIFJh"
    "dGlvIGJlbG93IHdoaWNoIGJhdGNoIHF1ZXVlcyBzaG91bGQgYmUgcmVmaWxsZWQKc3RhdGljIHU4ICBkZWZhdWx0X2JxX3JlZmlsbF9iZWxvd19yYXRpbyA9"
    "IDIwOwovLyBNYXhpbXVtIGxhdGVuY3kgc2FtcGxlIHRvIGlucHV0CnN0YXRpYyB1NjQgZGVmYXVsdF9sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCA9IDUwMCAq"
    "IE5TRUNfUEVSX01TRUM7Ci8vIEJhdGNoIG9yZGVyaW5nIHN0cmF0ZWd5CnN0YXRpYyB1NjQgZGVmYXVsdF9iYXRjaF9vcmRlciA9IDA7CgovKiBDb21wbGlh"
    "bmNlIEZsYWdzOgogKiAweDE6IEFzeW5jIHJlcXVlc3RzIHdpbGwgbm90IGJlIHJlb3JkZXJlZCBiYXNlZCBvbiB0aGUgcHJlZGljdGVkIGxhdGVuY3kKICov"
    "CmVudW0gYWRpb3NfY29tcGxpYW5jZV9mbGFncyB7CglBRElPU19DRl9GSVhPUkRFUiAgPSAxVSA8PCAwLAp9OwoKLy8gRmxhZ3MgdG8gY29udHJvbCBjb21w"
    "bGlhbmNlIHdpdGggYmxvY2sgbGF5ZXIgY29uc3RyYWludHMKc3RhdGljIHU2NCBkZWZhdWx0X2NvbXBsaWFuY2VfZmxhZ3MgPSAweDA7CgovLyBEeW5hbWlj"
    "IHRocmVzaG9sZHMgZm9yIHNocmlua2FnZQpzdGF0aWMgdTMyIGRlZmF1bHRfbG1fc2hyaW5rX2F0X2tyZXFzICA9ICA1MDAwOwpzdGF0aWMgdTMyIGRlZmF1"
    "bHRfbG1fc2hyaW5rX2F0X2dieXRlcyA9ICAgIDUwOwpzdGF0aWMgdTMyIGRlZmF1bHRfbG1fc2hyaW5rX3Jlc2lzdCAgICA9ICAgICAyOwoKZW51bSBhZGlv"
    "c19vcHR5cGUgewoJQURJT1NfUkVBRCAgICA9IDAsCglBRElPU19XUklURSAgID0gMSwKCUFESU9TX0RJU0NBUkQgPSAyLAoJQURJT1NfT1RIRVIgICA9IDMs"
    "CglBRElPU19PUFRZUEVTID0gNCwKfTsKCi8vIExhdGVuY3kgdGFyZ2V0cyBmb3IgZWFjaCBvcGVyYXRpb24gdHlwZQpzdGF0aWMgdTY0IGRlZmF1bHRfbGF0"
    "ZW5jeV90YXJnZXRbQURJT1NfT1BUWVBFU10gPSB7CglbQURJT1NfUkVBRF0gICAgPSAgICAgMlVMTCAqIE5TRUNfUEVSX01TRUMsCglbQURJT1NfV1JJVEVd"
    "ICAgPSAgMjAwMFVMTCAqIE5TRUNfUEVSX01TRUMsCglbQURJT1NfRElTQ0FSRF0gPSAgODAwMFVMTCAqIE5TRUNfUEVSX01TRUMsCglbQURJT1NfT1RIRVJd"
    "ICAgPSAgICAgMFVMTCAqIE5TRUNfUEVSX01TRUMsCn07CgovLyBNYXhpbXVtIGJhdGNoIHNpemUgbGltaXRzIGZvciBlYWNoIG9wZXJhdGlvbiB0eXBlCnN0"
    "YXRpYyB1MzIgZGVmYXVsdF9iYXRjaF9saW1pdFtBRElPU19PUFRZUEVTXSA9IHsKCVtBRElPU19SRUFEXSAgICA9IDM2LAoJW0FESU9TX1dSSVRFXSAgID0g"
    "NzIsCglbQURJT1NfRElTQ0FSRF0gPSAgMSwKCVtBRElPU19PVEhFUl0gICA9ICAxLAp9OwoKZW51bSBhZGlvc19iYXRjaF9vcmRlciB7CglBRElPU19CT19P"
    "UFRZUEUgICA9IDAsCglBRElPU19CT19FTEVWQVRPUiA9IDEsCn07CgovLyBUaHJlc2hvbGRzIGZvciBsYXRlbmN5IG1vZGVsIGNvbnRyb2wKI2RlZmluZSBM"
    "TV9CTE9DS19TSVpFX1RIUkVTSE9MRCA0MDk2CiNkZWZpbmUgTE1fU0FNUExFU19USFJFU0hPTEQgICAgMTAyNAojZGVmaW5lIExNX0lOVEVSVkFMX1RIUkVT"
    "SE9MRCAgIDE1MDAKI2RlZmluZSBMTV9PVVRMSUVSX1BFUkNFTlRJTEUgICAgIDk5CiNkZWZpbmUgTE1fTEFUX0JVQ0tFVF9DT1VOVCAgICAgICA2NAoKI2Rl"
    "ZmluZSBBRElPU19QUV9MRVZFTFMgMgojZGVmaW5lIEFESU9TX0RMX1RZUEVTICAyCiNkZWZpbmUgQURJT1NfQlFfUEFHRVMgIDIKCnN0YXRpYyB1MzIgZGVm"
    "YXVsdF9kbF9wcmlvW0FESU9TX0RMX1RZUEVTXSA9IHs4LCAwfTsKCi8vIEJpdCBmbGFncyBmb3IgdGhlIGF0b21pYyBzdGF0ZSB2YXJpYWJsZSwgaW5kaWNh"
    "dGluZyB3aGljaCBxdWV1ZXMgaGF2ZSByZXF1ZXN0cy4KZW51bSBhZGlvc19zdGF0ZV9mbGFncyB7CglBRElPU19TVEFURV9QUV8wICAgICAgPSAxVSA8PCAw"
    "LAoJQURJT1NfU1RBVEVfUFFfMSAgICAgID0gMVUgPDwgMSwKCUFESU9TX1NUQVRFX0RMXzAgICAgICA9IDFVIDw8IDIsCglBRElPU19TVEFURV9ETF8xICAg"
    "ICAgPSAxVSA8PCAzLAoJQURJT1NfU1RBVEVfQlFfUEFHRV8wID0gMVUgPDwgNCwKCUFESU9TX1NUQVRFX0JRX1BBR0VfMSA9IDFVIDw8IDUsCn07CiNkZWZp"
    "bmUgQURJT1NfU1RBVEVfUFEgMAojZGVmaW5lIEFESU9TX1NUQVRFX0RMIDIKI2RlZmluZSBBRElPU19TVEFURV9CUSA0CgovLyBUZW1wb3JhbCBncmFudWxh"
    "cml0eSBvZiB0aGUgZGVhZGxpbmUgdHJlZSBub2RlIChkbF9ncm91cCkKI2RlZmluZSBBRElPU19RVUFOVFVNX1NISUZUIDIwCgojZGVmaW5lIEFESU9TX01B"
    "WF9JTlNFUlRTX1BFUl9MT0NLIDcyCiNkZWZpbmUgQURJT1NfTUFYX0RFTEVURVNfUEVSX0xPQ0sgMjQKCi8vIFN0cnVjdHVyZSB0byBob2xkIGxhdGVuY3kg"
    "YnVja2V0IGRhdGEgZm9yIHNtYWxsIHJlcXVlc3RzCnN0cnVjdCBsYXRlbmN5X2J1Y2tldF9zbWFsbCB7Cgl1NjQgd2VpZ2h0ZWRfc3VtX2xhdGVuY3k7Cgl1"
    "NjQgc3VtX29mX3dlaWdodHM7Cn07CgovLyBTdHJ1Y3R1cmUgdG8gaG9sZCBsYXRlbmN5IGJ1Y2tldCBkYXRhIGZvciBsYXJnZSByZXF1ZXN0cwpzdHJ1Y3Qg"
    "bGF0ZW5jeV9idWNrZXRfbGFyZ2UgewoJdTY0IHdlaWdodGVkX3N1bV9sYXRlbmN5OwoJdTY0IHdlaWdodGVkX3N1bV9ibG9ja19zaXplOwoJdTY0IHN1bV9v"
    "Zl93ZWlnaHRzOwp9OwoKLy8gU3RydWN0dXJlIHRvIGhvbGQgcGVyLWNwdSBidWNrZXRzLCBpbXByb3ZpbmcgZGF0YSBsb2NhbGl0eSBhbmQgY29kZSBjbGFy"
    "aXR5LgpzdHJ1Y3QgbG1fYnVja2V0cyB7CglzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfc21hbGwgc21hbGxfYnVja2V0W0xNX0xBVF9CVUNLRVRfQ09VTlRdOwoJ"
    "c3RydWN0IGxhdGVuY3lfYnVja2V0X2xhcmdlIGxhcmdlX2J1Y2tldFtMTV9MQVRfQlVDS0VUX0NPVU5UXTsKfTsKCi8vIFN0cnVjdHVyZSB0byBob2xkIFJD"
    "VS1wcm90ZWN0ZWQgbGF0ZW5jeSBtb2RlbCBwYXJhbWV0ZXJzCnN0cnVjdCBsYXRlbmN5X21vZGVsX3BhcmFtcyB7Cgl1NjQgYmFzZTsKCXU2NCBzbG9wZTsK"
    "CXU2NCBzbWFsbF9zdW1fZGVsYXk7Cgl1NjQgc21hbGxfY291bnQ7Cgl1NjQgbGFyZ2Vfc3VtX2RlbGF5OwoJdTY0IGxhcmdlX3N1bV9ic2l6ZTsKCXU2NCBs"
    "YXN0X3VwZGF0ZV9qaWZmaWVzOwoJc3RydWN0IHJjdV9oZWFkIHJjdTsKfTsKCi8vIFN0cnVjdHVyZSB0byBob2xkIHRoZSBsYXRlbmN5IG1vZGVsIGNvbnRl"
    "eHQgZGF0YQpzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCB7CglzcGlubG9ja190IHVwZGF0ZV9sb2NrOwoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zIF9fcmN1"
    "ICpwYXJhbXM7CgoJLy8gUGVyLUNQVSBidWNrZXRzIHRvIGF2b2lkIGxvY2sgY29udGVudGlvbiBvbiB0aGUgY29tcGxldGlvbiBwYXRoCglzdHJ1Y3QgbG1f"
    "YnVja2V0cyBfX3BlcmNwdSAqcGNwdV9idWNrZXRzOwoJLy8gUGVyLUNQVSBzbmFwc2hvdHMgZm9yIGRlbHRhLWJhc2VkIGFnZ3JlZ2F0aW9uIChhY2Nlc3Nl"
    "ZCB1bmRlciB1cGRhdGVfbG9jaykKCXN0cnVjdCBsbV9idWNrZXRzIF9fcGVyY3B1ICpwY3B1X3NuYXBzaG90OwoKCXUzMiBsbV9zaHJpbmtfYXRfa3JlcXM7"
    "Cgl1MzIgbG1fc2hyaW5rX2F0X2dieXRlczsKCXU4ICBsbV9zaHJpbmtfcmVzaXN0Owp9OwoKc3RydWN0IGFkaW9zX3BjcHVfY29tcGxldGlvbiB7Cgl1NjQg"
    "ICAgICBsYXN0X2NvbXBsZXRlZF90aW1lOwoJc2VjdG9yX3QgbGFzdF9jb21wbGV0ZWRfcG9zOwp9OwoKdW5pb24gYWRpb3NfaW5fZmxpZ2h0X3JxcyB7Cglh"
    "dG9taWM2NF90CWF0b21pYzsKCXU2NAkJCXNjYWxhcjsKCXN0cnVjdCB7CgkJdTY0IAljb3VudDogICAgICAgICAgMTY7CgkJdTY0IAl0b3RhbF9wcmVkX2xh"
    "dDogNDg7Cgl9Owp9OwoKLy8gQWRpb3Mgc2NoZWR1bGVyIGRhdGEKc3RydWN0IGFkaW9zX2RhdGEgewoJc3BpbmxvY2tfdCBwcV9sb2NrOwoJc3RydWN0IGxp"
    "c3RfaGVhZCBwcmlvX3F1ZXVlWzJdOwoKCXN0cnVjdCByYl9yb290X2NhY2hlZCBkbF90cmVlWzJdOwoJc3BpbmxvY2tfdCBsb2NrOwoJczY0IGRsX2JpYXM7"
    "CglzMzIgZGxfcHJpb1syXTsKCglhdG9taWNfdCBzdGF0ZTsKCXU4ICBicV9zdGF0ZVtBRElPU19CUV9QQUdFU107CgoJYm9vbCBtb2RlbHNfc3RhYmxlOwoK"
    "CXU2NCBnbG9iYWxfbGF0ZW5jeV93aW5kb3c7Cgl1NjQgY29tcGxpYW5jZV9mbGFnczsKCXU2NCBsYXRlbmN5X3RhcmdldFtBRElPU19PUFRZUEVTXTsKCXUz"
    "MiBiYXRjaF9saW1pdFtBRElPU19PUFRZUEVTXTsKCXUzMiBiYXRjaF9hY3R1YWxfbWF4X3NpemVbQURJT1NfT1BUWVBFU107Cgl1MzIgYmF0Y2hfYWN0dWFs"
    "X21heF90b3RhbDsKCXUzMiBhc3luY19kZXB0aDsKCXUzMiBsYXRfbW9kZWxfbGF0ZW5jeV9saW1pdDsKCXU4ICBicV9yZWZpbGxfYmVsb3dfcmF0aW87Cgl1"
    "OCAgaXNfcm90YXRpb25hbDsKCXU4ICBiYXRjaF9vcmRlcjsKCXU4ICBlbHZfZGlyZWN0aW9uOwoJc2VjdG9yX3QgaGVhZF9wb3M7CgoJYm9vbCBicV9wYWdl"
    "OwoJc3RydWN0IGxpc3RfaGVhZCBiYXRjaF9xdWV1ZVtBRElPU19CUV9QQUdFU11bQURJT1NfT1BUWVBFU107Cgl1MzIgYmF0Y2hfY291bnRbQURJT1NfQlFf"
    "UEFHRVNdW0FESU9TX09QVFlQRVNdOwoJdTggIGJxX2JhdGNoX29yZGVyW0FESU9TX0JRX1BBR0VTXTsKCXNwaW5sb2NrX3QgYnFfbG9jazsKCglzdHJ1Y3Qg"
    "bG1fYnVja2V0cyAqYWdncl9idWNrZXRzOwoKCXN0cnVjdCBsYXRlbmN5X21vZGVsIGxhdGVuY3lfbW9kZWxbQURJT1NfT1BUWVBFU107CglzdHJ1Y3QgdGlt"
    "ZXJfbGlzdCB1cGRhdGVfdGltZXI7CgoJdW5pb24gYWRpb3NfaW5fZmxpZ2h0X3JxcyBpbl9mbGlnaHRfcnFzOwoJYXRvbWljNjRfdCB0b3RhbF9wcmVkX2xh"
    "dDsKCglzdHJ1Y3QgYWRpb3NfcGNwdV9jb21wbGV0aW9uIF9fcGVyY3B1ICpwY3B1X2NvbXBsZXRpb247CgoJc3RydWN0IGttZW1fY2FjaGUgKnJxX2RhdGFf"
    "Y2FjaGU7CgltZW1wb29sX3QgKnJxX2RhdGFfcG9vbDsKCXN0cnVjdCBrbWVtX2NhY2hlICpkbF9ncm91cF9wb29sOwoKCXN0cnVjdCByZXF1ZXN0X3F1ZXVl"
    "ICpxdWV1ZTsKfTsKCi8vIExpc3Qgb2YgcmVxdWVzdHMgd2l0aCB0aGUgc2FtZSBkZWFkbGluZSBpbiB0aGUgZGVhZGxpbmUtc29ydGVkIHRyZWUKc3RydWN0"
    "IGRsX2dyb3VwIHsKCXN0cnVjdCByYl9ub2RlIG5vZGU7CglzdHJ1Y3QgbGlzdF9oZWFkIHJxczsKCXU2NCBkZWFkbGluZTsKfSBfX2F0dHJpYnV0ZV9fKChh"
    "bGlnbmVkKDY0KSkpOwoKLy8gU3RydWN0dXJlIHRvIGhvbGQgc2NoZWR1bGVyLXNwZWNpZmljIGRhdGEgZm9yIGVhY2ggcmVxdWVzdApzdHJ1Y3QgYWRpb3Nf"
    "cnFfZGF0YSB7CglzdHJ1Y3QgbGlzdF9oZWFkICpkbF9ncm91cDsKCXN0cnVjdCBsaXN0X2hlYWQgZGxfbm9kZTsKCglzdHJ1Y3QgcmVxdWVzdCAqcnE7Cgl1"
    "NjQgZGVhZGxpbmU7Cgl1NjQgcHJlZF9sYXQ7Cgl1MzIgYmxvY2tfc2l6ZTsKCWJvb2wgbWFuYWdlZDsKfSBfX2F0dHJpYnV0ZV9fKChhbGlnbmVkKDY0KSkp"
    "OwoKc3RhdGljIGNvbnN0IGludCBhZGlvc19wcmlvX3RvX3dtdWx0WzQwXSA9IHsKIC8qIC0yMCAqLyAgICAgODg3NjEsICAgICA3MTc1NSwgICAgIDU2NDgz"
    "LCAgICAgNDYyNzMsICAgICAzNjI5MSwKIC8qIC0xNSAqLyAgICAgMjkxNTQsICAgICAyMzI1NCwgICAgIDE4NzA1LCAgICAgMTQ5NDksICAgICAxMTkxNiwK"
    "IC8qIC0xMCAqLyAgICAgIDk1NDgsICAgICAgNzYyMCwgICAgICA2MTAwLCAgICAgIDQ5MDQsICAgICAgMzkwNiwKIC8qICAtNSAqLyAgICAgIDMxMjEsICAg"
    "ICAgMjUwMSwgICAgICAxOTkxLCAgICAgIDE1ODYsICAgICAgMTI3NywKIC8qICAgMCAqLyAgICAgIDEwMjQsICAgICAgIDgyMCwgICAgICAgNjU1LCAgICAg"
    "ICA1MjYsICAgICAgIDQyMywKIC8qICAgNSAqLyAgICAgICAzMzUsICAgICAgIDI3MiwgICAgICAgMjE1LCAgICAgICAxNzIsICAgICAgIDEzNywKIC8qICAx"
    "MCAqLyAgICAgICAxMTAsICAgICAgICA4NywgICAgICAgIDcwLCAgICAgICAgNTYsICAgICAgICA0NSwKIC8qICAxNSAqLyAgICAgICAgMzYsICAgICAgICAy"
    "OSwgICAgICAgIDIzLCAgICAgICAgMTgsICAgICAgICAxNSwKfTsKCnN0YXRpYyBpbmxpbmUgYm9vbCBjb21wbGlhbnQoc3RydWN0IGFkaW9zX2RhdGEgKmFk"
    "LCB1MzIgZmxhZykgewoJcmV0dXJuIGFkLT5jb21wbGlhbmNlX2ZsYWdzICYgZmxhZzsKfQoKLy8gQ291bnQgdGhlIG51bWJlciBvZiBlbnRyaWVzIGluIGFn"
    "Z3JlZ2F0ZWQgc21hbGwgYnVja2V0cwpzdGF0aWMgdTY0IGxtX2NvdW50X3NtYWxsX2VudHJpZXMoc3RydWN0IGxhdGVuY3lfYnVja2V0X3NtYWxsICpidWNr"
    "ZXRzKSB7Cgl1NjQgdG90YWxfd2VpZ2h0ID0gMDsKCWZvciAodTggaSA9IDA7IGkgPCBMTV9MQVRfQlVDS0VUX0NPVU5UOyBpKyspCgkJdG90YWxfd2VpZ2h0"
    "ICs9IGJ1Y2tldHNbaV0uc3VtX29mX3dlaWdodHM7CglyZXR1cm4gdG90YWxfd2VpZ2h0Owp9CgovLyBVcGRhdGUgdGhlIHNtYWxsIGJ1Y2tldHMgaW4gdGhl"
    "IGxhdGVuY3kgbW9kZWwgZnJvbSBhZ2dyZWdhdGVkIGRhdGEKc3RhdGljIGJvb2wgbG1fdXBkYXRlX3NtYWxsX2J1Y2tldHMoc3RydWN0IGxhdGVuY3lfbW9k"
    "ZWwgKm1vZGVsLAoJCXN0cnVjdCBsYXRlbmN5X21vZGVsX3BhcmFtcyAqcGFyYW1zLAoJCXN0cnVjdCBsYXRlbmN5X2J1Y2tldF9zbWFsbCAqYnVja2V0cywK"
    "CQl1NjQgdG90YWxfd2VpZ2h0LCBib29sIGNvdW50X2FsbCkgewoJdTY0IHN1bV9sYXRlbmN5ID0gMDsKCXU2NCBzdW1fd2VpZ2h0ID0gMDsKCXU2NCBjdW11"
    "bGF0aXZlX3dlaWdodCA9IDAsIHRocmVzaG9sZF93ZWlnaHQgPSAwOwoJdTggIG91dGxpZXJfdGhyZXNob2xkX2J1Y2tldCA9IDA7Cgl1OCAgb3V0bGllcl9w"
    "ZXJjZW50aWxlID0gTE1fT1VUTElFUl9QRVJDRU5USUxFOwoJdTggIHJlZHVjdGlvbjsKCglpZiAoY291bnRfYWxsKQoJCW91dGxpZXJfcGVyY2VudGlsZSA9"
    "IDEwMDsKCgkvLyBDYWxjdWxhdGUgdGhlIHRocmVzaG9sZCB3ZWlnaHQgZm9yIG91dGxpZXIgZGV0ZWN0aW9uCgl0aHJlc2hvbGRfd2VpZ2h0ID0gKHRvdGFs"
    "X3dlaWdodCAqIG91dGxpZXJfcGVyY2VudGlsZSkgLyAxMDA7CgoJLy8gSWRlbnRpZnkgdGhlIGJ1Y2tldCB0aGF0IGNvcnJlc3BvbmRzIHRvIHRoZSBvdXRs"
    "aWVyIHRocmVzaG9sZAoJZm9yICh1OCBpID0gMDsgaSA8IExNX0xBVF9CVUNLRVRfQ09VTlQ7IGkrKykgewoJCWN1bXVsYXRpdmVfd2VpZ2h0ICs9IGJ1Y2tl"
    "dHNbaV0uc3VtX29mX3dlaWdodHM7CgkJaWYgKGN1bXVsYXRpdmVfd2VpZ2h0ID49IHRocmVzaG9sZF93ZWlnaHQpIHsKCQkJb3V0bGllcl90aHJlc2hvbGRf"
    "YnVja2V0ID0gaTsKCQkJYnJlYWs7CgkJfQoJfQoKCS8vIENhbGN1bGF0ZSB0aGUgYXZlcmFnZSBsYXRlbmN5LCBleGNsdWRpbmcgb3V0bGllcnMKCWZvciAo"
    "dTggaSA9IDA7IGkgPD0gb3V0bGllcl90aHJlc2hvbGRfYnVja2V0OyBpKyspIHsKCQlzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfc21hbGwgKmJ1Y2tldCA9ICZi"
    "dWNrZXRzW2ldOwoJCWlmIChpIDwgb3V0bGllcl90aHJlc2hvbGRfYnVja2V0KSB7CgkJCXN1bV9sYXRlbmN5ICs9IGJ1Y2tldC0+d2VpZ2h0ZWRfc3VtX2xh"
    "dGVuY3k7CgkJCXN1bV93ZWlnaHQgKz0gYnVja2V0LT5zdW1fb2Zfd2VpZ2h0czsKCQl9IGVsc2UgewoJCQkvLyBUaGUgdGhyZXNob2xkIGJ1Y2tldCdzIGNv"
    "bnRyaWJ1dGlvbiBpcyBwcm9wb3J0aW9uYWwKCQkJdTY0IHJlbWFpbmluZ193ZWlnaHQgPQoJCQkJdGhyZXNob2xkX3dlaWdodCAtIChjdW11bGF0aXZlX3dl"
    "aWdodCAtIGJ1Y2tldC0+c3VtX29mX3dlaWdodHMpOwoJCQlpZiAoYnVja2V0LT5zdW1fb2Zfd2VpZ2h0cyA+IDApIHsKCQkJCXN1bV9sYXRlbmN5ICs9IGRp"
    "dl91NjQoYnVja2V0LT53ZWlnaHRlZF9zdW1fbGF0ZW5jeSAqCgkJCQkJcmVtYWluaW5nX3dlaWdodCwgYnVja2V0LT5zdW1fb2Zfd2VpZ2h0cyk7CgkJCQlz"
    "dW1fd2VpZ2h0ICs9IHJlbWFpbmluZ193ZWlnaHQ7CgkJCX0KCQl9Cgl9CgoJLy8gU2hyaW5rIHRoZSBtb2RlbCBpZiBpdCByZWFjaGVzIGF0IHRoZSByZWFk"
    "anVzdG1lbnQgdGhyZXNob2xkCglpZiAocGFyYW1zLT5zbWFsbF9jb3VudCA+PSAxMDAwVUxMICogbW9kZWwtPmxtX3Nocmlua19hdF9rcmVxcykgewoJCXJl"
    "ZHVjdGlvbiA9IG1vZGVsLT5sbV9zaHJpbmtfcmVzaXN0OwoJCWlmIChwYXJhbXMtPnNtYWxsX2NvdW50ID4+IHJlZHVjdGlvbikgewoJCQlwYXJhbXMtPnNt"
    "YWxsX3N1bV9kZWxheSAtPSBwYXJhbXMtPnNtYWxsX3N1bV9kZWxheSA+PiByZWR1Y3Rpb247CgkJCXBhcmFtcy0+c21hbGxfY291bnQgICAgIC09IHBhcmFt"
    "cy0+c21hbGxfY291bnQgICAgID4+IHJlZHVjdGlvbjsKCQl9Cgl9CgoJaWYgKCFzdW1fd2VpZ2h0KQoJCXJldHVybiBmYWxzZTsKCgkvLyBBY2N1bXVsYXRl"
    "IHRoZSBhdmVyYWdlIGxhdGVuY3kgaW50byB0aGUgc3RhdGlzdGljcwoJcGFyYW1zLT5zbWFsbF9zdW1fZGVsYXkgKz0gc3VtX2xhdGVuY3k7CglwYXJhbXMt"
    "PnNtYWxsX2NvdW50ICAgICArPSBzdW1fd2VpZ2h0OwoKCXJldHVybiB0cnVlOwp9CgovLyBDb3VudCB0aGUgbnVtYmVyIG9mIGVudHJpZXMgaW4gYWdncmVn"
    "YXRlZCBsYXJnZSBidWNrZXRzCnN0YXRpYyB1NjQgbG1fY291bnRfbGFyZ2VfZW50cmllcyhzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfbGFyZ2UgKmJ1Y2tldHMp"
    "IHsKCXU2NCB0b3RhbF93ZWlnaHQgPSAwOwoJZm9yICh1OCBpID0gMDsgaSA8IExNX0xBVF9CVUNLRVRfQ09VTlQ7IGkrKykKCQl0b3RhbF93ZWlnaHQgKz0g"
    "YnVja2V0c1tpXS5zdW1fb2Zfd2VpZ2h0czsKCXJldHVybiB0b3RhbF93ZWlnaHQ7Cn0KCi8vIFVwZGF0ZSB0aGUgbGFyZ2UgYnVja2V0cyBpbiB0aGUgbGF0"
    "ZW5jeSBtb2RlbCBmcm9tIGFnZ3JlZ2F0ZWQgZGF0YQpzdGF0aWMgYm9vbCBsbV91cGRhdGVfbGFyZ2VfYnVja2V0cyhzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAq"
    "bW9kZWwsCgkJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXMsCgkJc3RydWN0IGxhdGVuY3lfYnVja2V0X2xhcmdlICpidWNrZXRzLAoJCXU2"
    "NCB0b3RhbF93ZWlnaHQsIGJvb2wgY291bnRfYWxsKSB7CglzNjQgc3VtX2xhdGVuY3kgPSAwOwoJdTY0IHN1bV9ibG9ja19zaXplID0gMCwgaW50ZXJjZXB0"
    "OwoJdTY0IGN1bXVsYXRpdmVfd2VpZ2h0ID0gMCwgdGhyZXNob2xkX3dlaWdodCA9IDA7Cgl1NjQgc3VtX3dlaWdodCA9IDA7Cgl1OCAgb3V0bGllcl90aHJl"
    "c2hvbGRfYnVja2V0ID0gMDsKCXU4ICBvdXRsaWVyX3BlcmNlbnRpbGUgPSBMTV9PVVRMSUVSX1BFUkNFTlRJTEU7Cgl1OCAgcmVkdWN0aW9uOwoKCWlmIChj"
    "b3VudF9hbGwpCgkJb3V0bGllcl9wZXJjZW50aWxlID0gMTAwOwoKCS8vIENhbGN1bGF0ZSB0aGUgdGhyZXNob2xkIHdlaWdodCBmb3Igb3V0bGllciBkZXRl"
    "Y3Rpb24KCXRocmVzaG9sZF93ZWlnaHQgPSAodG90YWxfd2VpZ2h0ICogb3V0bGllcl9wZXJjZW50aWxlKSAvIDEwMDsKCgkvLyBJZGVudGlmeSB0aGUgYnVj"
    "a2V0IHRoYXQgY29ycmVzcG9uZHMgdG8gdGhlIG91dGxpZXIgdGhyZXNob2xkCglmb3IgKHU4IGkgPSAwOyBpIDwgTE1fTEFUX0JVQ0tFVF9DT1VOVDsgaSsr"
    "KSB7CgkJY3VtdWxhdGl2ZV93ZWlnaHQgKz0gYnVja2V0c1tpXS5zdW1fb2Zfd2VpZ2h0czsKCQlpZiAoY3VtdWxhdGl2ZV93ZWlnaHQgPj0gdGhyZXNob2xk"
    "X3dlaWdodCkgewoJCQlvdXRsaWVyX3RocmVzaG9sZF9idWNrZXQgPSBpOwoJCQlicmVhazsKCQl9Cgl9CgoJLy8gQ2FsY3VsYXRlIHRoZSBhdmVyYWdlIGxh"
    "dGVuY3kgYW5kIGJsb2NrIHNpemUsIGV4Y2x1ZGluZyBvdXRsaWVycwoJZm9yICh1OCBpID0gMDsgaSA8PSBvdXRsaWVyX3RocmVzaG9sZF9idWNrZXQ7IGkr"
    "KykgewoJCXN0cnVjdCBsYXRlbmN5X2J1Y2tldF9sYXJnZSAqYnVja2V0ID0gJmJ1Y2tldHNbaV07CgkJaWYgKGkgPCBvdXRsaWVyX3RocmVzaG9sZF9idWNr"
    "ZXQpIHsKCQkJc3VtX2xhdGVuY3kgKz0gYnVja2V0LT53ZWlnaHRlZF9zdW1fbGF0ZW5jeTsKCQkJc3VtX2Jsb2NrX3NpemUgKz0gYnVja2V0LT53ZWlnaHRl"
    "ZF9zdW1fYmxvY2tfc2l6ZTsKCQkJc3VtX3dlaWdodCArPSBidWNrZXQtPnN1bV9vZl93ZWlnaHRzOwoJCX0gZWxzZSB7CgkJCS8vIFRoZSB0aHJlc2hvbGQg"
    "YnVja2V0J3MgY29udHJpYnV0aW9uIGlzIHByb3BvcnRpb25hbAoJCQl1NjQgcmVtYWluaW5nX3dlaWdodCA9CgkJCQl0aHJlc2hvbGRfd2VpZ2h0IC0gKGN1"
    "bXVsYXRpdmVfd2VpZ2h0IC0gYnVja2V0LT5zdW1fb2Zfd2VpZ2h0cyk7CgkJCWlmIChidWNrZXQtPnN1bV9vZl93ZWlnaHRzID4gMCkgewoJCQkJc3VtX2xh"
    "dGVuY3kgKz0gZGl2X3U2NChidWNrZXQtPndlaWdodGVkX3N1bV9sYXRlbmN5ICoKCQkJCQlyZW1haW5pbmdfd2VpZ2h0LCBidWNrZXQtPnN1bV9vZl93ZWln"
    "aHRzKTsKCQkJCXN1bV9ibG9ja19zaXplICs9IGRpdl91NjQoYnVja2V0LT53ZWlnaHRlZF9zdW1fYmxvY2tfc2l6ZSAqCgkJCQkJcmVtYWluaW5nX3dlaWdo"
    "dCwgYnVja2V0LT5zdW1fb2Zfd2VpZ2h0cyk7CgkJCQlzdW1fd2VpZ2h0ICs9IHJlbWFpbmluZ193ZWlnaHQ7CgkJCX0KCQl9Cgl9CgoJaWYgKCFzdW1fd2Vp"
    "Z2h0KQoJCXJldHVybiBmYWxzZTsKCgkvLyBTaHJpbmsgdGhlIG1vZGVsIGlmIGl0IHJlYWNoZXMgYXQgdGhlIHJlYWRqdXN0bWVudCB0aHJlc2hvbGQKCWlm"
    "IChwYXJhbXMtPmxhcmdlX3N1bV9ic2l6ZSA+PSAweDQwMDAwMDAwVUxMICogbW9kZWwtPmxtX3Nocmlua19hdF9nYnl0ZXMpIHsKCQlyZWR1Y3Rpb24gPSBt"
    "b2RlbC0+bG1fc2hyaW5rX3Jlc2lzdDsKCQlpZiAocGFyYW1zLT5sYXJnZV9zdW1fYnNpemUgPj4gcmVkdWN0aW9uKSB7CgkJCXBhcmFtcy0+bGFyZ2Vfc3Vt"
    "X2RlbGF5IC09IHBhcmFtcy0+bGFyZ2Vfc3VtX2RlbGF5ID4+IHJlZHVjdGlvbjsKCQkJcGFyYW1zLT5sYXJnZV9zdW1fYnNpemUgLT0gcGFyYW1zLT5sYXJn"
    "ZV9zdW1fYnNpemUgPj4gcmVkdWN0aW9uOwoJCX0KCX0KCgkvLyBBY2N1bXVsYXRlIHRoZSBhdmVyYWdlIGRlbGF5IGludG8gdGhlIHN0YXRpc3RpY3MKCWlu"
    "dGVyY2VwdCA9IHBhcmFtcy0+YmFzZTsKCWlmIChzdW1fbGF0ZW5jeSA+IGludGVyY2VwdCkKCQlzdW1fbGF0ZW5jeSAtPSBpbnRlcmNlcHQ7CgoJcGFyYW1z"
    "LT5sYXJnZV9zdW1fZGVsYXkgKz0gc3VtX2xhdGVuY3k7CglwYXJhbXMtPmxhcmdlX3N1bV9ic2l6ZSArPSBzdW1fYmxvY2tfc2l6ZTsKCglyZXR1cm4gdHJ1"
    "ZTsKfQoKc3RhdGljIHZvaWQgcmVzZXRfYnVja2V0cyhzdHJ1Y3QgbG1fYnVja2V0cyAqYnVja2V0cykKeyBtZW1zZXQoYnVja2V0cywgMCwgc2l6ZW9mKCpi"
    "dWNrZXRzKSk7IH0KCnN0YXRpYyB2b2lkIGxtX3Jlc2V0X3BjcHVfYnVja2V0cyhzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwpIHsKCWludCBjcHU7Cglm"
    "b3JfZWFjaF9wb3NzaWJsZV9jcHUoY3B1KSB7CgkJcmVzZXRfYnVja2V0cyhwZXJfY3B1X3B0cihtb2RlbC0+cGNwdV9idWNrZXRzLCBjcHUpKTsKCQlyZXNl"
    "dF9idWNrZXRzKHBlcl9jcHVfcHRyKG1vZGVsLT5wY3B1X3NuYXBzaG90LCBjcHUpKTsKCX0KfQoKLy8gVXBkYXRlIHRoZSBsYXRlbmN5IG1vZGVsIHBhcmFt"
    "ZXRlcnMgYW5kIHN0YXRpc3RpY3MKc3RhdGljIHZvaWQgbGF0ZW5jeV9tb2RlbF91cGRhdGUoCgkJc3RydWN0IGFkaW9zX2RhdGEgKmFkLCBzdHJ1Y3QgbGF0"
    "ZW5jeV9tb2RlbCAqbW9kZWwpIHsKCXU2NCBub3c7Cgl1NjQgc21hbGxfd2VpZ2h0LCBsYXJnZV93ZWlnaHQ7Cglib29sIHRpbWVfZWxhcHNlZDsKCWJvb2wg"
    "c21hbGxfcHJvY2Vzc2VkID0gZmFsc2UsIGxhcmdlX3Byb2Nlc3NlZCA9IGZhbHNlOwoJc3RydWN0IGxtX2J1Y2tldHMgKmFnZ3IgPSBhZC0+YWdncl9idWNr"
    "ZXRzOwoJc3RydWN0IGxhdGVuY3lfYnVja2V0X3NtYWxsICphc2I7CglzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfbGFyZ2UgKmFsYjsKCXN0cnVjdCBsbV9idWNr"
    "ZXRzICpwY3B1X2IsICpzbmFwOwoJdW5zaWduZWQgbG9uZyBmbGFnczsKCWludCBjcHU7CglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbF9wYXJhbXMgKm9sZF9wYXJh"
    "bXMsICpuZXdfcGFyYW1zOwoKCXNwaW5fbG9ja19pcnFzYXZlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsKCglvbGRfcGFyYW1zID0gcmN1X2RlcmVm"
    "ZXJlbmNlX3Byb3RlY3RlZChtb2RlbC0+cGFyYW1zLAoJCQkJbG9ja2RlcF9pc19oZWxkKCZtb2RlbC0+dXBkYXRlX2xvY2spKTsKCW5ld19wYXJhbXMgPSBr"
    "bWVtZHVwKG9sZF9wYXJhbXMsIHNpemVvZigqbmV3X3BhcmFtcyksIEdGUF9BVE9NSUMpOwoJaWYgKCFuZXdfcGFyYW1zKSB7CgkJc3Bpbl91bmxvY2tfaXJx"
    "cmVzdG9yZSgmbW9kZWwtPnVwZGF0ZV9sb2NrLCBmbGFncyk7CgkJcmV0dXJuOwoJfQoKCS8vIEFnZ3JlZ2F0ZSBkZWx0YXMgZnJvbSBhbGwgQ1BVcyB1c2lu"
    "ZyBzbmFwc2hvdC1kZWx0YSBtZXRob2QuCgkvLyBQZXItQ1BVIGNvdW50ZXJzIGluY3JlYXNlIG1vbm90b25pY2FsbHk7IHdlIGNvbXB1dGUgZGVsdGEgPSBj"
    "dXJyZW50IC0gc25hcHNob3QuCglmb3JfZWFjaF9wb3NzaWJsZV9jcHUoY3B1KSB7CgkJcGNwdV9iID0gcGVyX2NwdV9wdHIobW9kZWwtPnBjcHVfYnVja2V0"
    "cywgY3B1KTsKCQlzbmFwICAgPSBwZXJfY3B1X3B0cihtb2RlbC0+cGNwdV9zbmFwc2hvdCwgY3B1KTsKCgkJZm9yICh1OCBpID0gMDsgaSA8IExNX0xBVF9C"
    "VUNLRVRfQ09VTlQ7IGkrKykgewoJCQl1NjQgc3cgID0gcGNwdV9iLT5zbWFsbF9idWNrZXRbaV0uc3VtX29mX3dlaWdodHM7CgkJCXU2NCBzbCAgPSBwY3B1"
    "X2ItPnNtYWxsX2J1Y2tldFtpXS53ZWlnaHRlZF9zdW1fbGF0ZW5jeTsKCQkJdTY0IGRzdyA9IHN3IC0gc25hcC0+c21hbGxfYnVja2V0W2ldLnN1bV9vZl93"
    "ZWlnaHRzOwoJCQl1NjQgZHNsID0gc2wgLSBzbmFwLT5zbWFsbF9idWNrZXRbaV0ud2VpZ2h0ZWRfc3VtX2xhdGVuY3k7CgkJCXNuYXAtPnNtYWxsX2J1Y2tl"
    "dFtpXS5zdW1fb2Zfd2VpZ2h0cyA9IHN3OwoJCQlzbmFwLT5zbWFsbF9idWNrZXRbaV0ud2VpZ2h0ZWRfc3VtX2xhdGVuY3kgPSBzbDsKCQkJaWYgKGRzdykg"
    "ewoJCQkJYXNiID0gJmFnZ3ItPnNtYWxsX2J1Y2tldFtpXTsKCQkJCWFzYi0+c3VtX29mX3dlaWdodHMgKz0gZHN3OwoJCQkJYXNiLT53ZWlnaHRlZF9zdW1f"
    "bGF0ZW5jeSArPSBkc2w7CgkJCX0KCgkJCXU2NCBsdyAgPSBwY3B1X2ItPmxhcmdlX2J1Y2tldFtpXS5zdW1fb2Zfd2VpZ2h0czsKCQkJdTY0IGxsICA9IHBj"
    "cHVfYi0+bGFyZ2VfYnVja2V0W2ldLndlaWdodGVkX3N1bV9sYXRlbmN5OwoJCQl1NjQgbGIgID0gcGNwdV9iLT5sYXJnZV9idWNrZXRbaV0ud2VpZ2h0ZWRf"
    "c3VtX2Jsb2NrX3NpemU7CgkJCXU2NCBkbHcgPSBsdyAtIHNuYXAtPmxhcmdlX2J1Y2tldFtpXS5zdW1fb2Zfd2VpZ2h0czsKCQkJdTY0IGRsbCA9IGxsIC0g"
    "c25hcC0+bGFyZ2VfYnVja2V0W2ldLndlaWdodGVkX3N1bV9sYXRlbmN5OwoJCQl1NjQgZGxiID0gbGIgLSBzbmFwLT5sYXJnZV9idWNrZXRbaV0ud2VpZ2h0"
    "ZWRfc3VtX2Jsb2NrX3NpemU7CgkJCXNuYXAtPmxhcmdlX2J1Y2tldFtpXS5zdW1fb2Zfd2VpZ2h0cyA9IGx3OwoJCQlzbmFwLT5sYXJnZV9idWNrZXRbaV0u"
    "d2VpZ2h0ZWRfc3VtX2xhdGVuY3kgPSBsbDsKCQkJc25hcC0+bGFyZ2VfYnVja2V0W2ldLndlaWdodGVkX3N1bV9ibG9ja19zaXplID0gbGI7CgkJCWlmIChk"
    "bHcpIHsKCQkJCWFsYiA9ICZhZ2dyLT5sYXJnZV9idWNrZXRbaV07CgkJCQlhbGItPnN1bV9vZl93ZWlnaHRzICs9IGRsdzsKCQkJCWFsYi0+d2VpZ2h0ZWRf"
    "c3VtX2xhdGVuY3kgKz0gZGxsOwoJCQkJYWxiLT53ZWlnaHRlZF9zdW1fYmxvY2tfc2l6ZSArPSBkbGI7CgkJCX0KCQl9Cgl9CgoJLy8gQ291bnQgdGhlIG51"
    "bWJlciBvZiBlbnRyaWVzIGluIGFnZ3JlZ2F0ZWQgYnVja2V0cwoJc21hbGxfd2VpZ2h0ID0gbG1fY291bnRfc21hbGxfZW50cmllcyhhZ2dyLT5zbWFsbF9i"
    "dWNrZXQpOwoJbGFyZ2Vfd2VpZ2h0ID0gbG1fY291bnRfbGFyZ2VfZW50cmllcyhhZ2dyLT5sYXJnZV9idWNrZXQpOwoKCS8vIFdoZXRoZXIgZW5vdWdoIHRp"
    "bWUgaGFzIGVsYXBzZWQgc2luY2UgdGhlIGxhc3QgdXBkYXRlCglub3cgPSBqaWZmaWVzOwoJdGltZV9lbGFwc2VkID0gdW5saWtlbHkoIW5ld19wYXJhbXMt"
    "PmJhc2UpIHx8CgkJbmV3X3BhcmFtcy0+bGFzdF91cGRhdGVfamlmZmllcyArCgkJbXNlY3NfdG9famlmZmllcyhMTV9JTlRFUlZBTF9USFJFU0hPTEQpIDw9"
    "IG5vdzsKCgkvLyBVcGRhdGUgc21hbGwgYnVja2V0cwoJaWYgKHNtYWxsX3dlaWdodCAmJiAodGltZV9lbGFwc2VkIHx8CgkJCUxNX1NBTVBMRVNfVEhSRVNI"
    "T0xEIDw9IHNtYWxsX3dlaWdodCB8fCAhbmV3X3BhcmFtcy0+YmFzZSkpIHsKCQlzbWFsbF9wcm9jZXNzZWQgPSBsbV91cGRhdGVfc21hbGxfYnVja2V0cyht"
    "b2RlbCwgbmV3X3BhcmFtcywKCQkJYWdnci0+c21hbGxfYnVja2V0LCBzbWFsbF93ZWlnaHQsICFuZXdfcGFyYW1zLT5iYXNlKTsKCQltZW1zZXQoJmFnZ3It"
    "PnNtYWxsX2J1Y2tldFswXSwgMCwgc2l6ZW9mKGFnZ3ItPnNtYWxsX2J1Y2tldCkpOwoJfQoJLy8gVXBkYXRlIGxhcmdlIGJ1Y2tldHMKCWlmIChsYXJnZV93"
    "ZWlnaHQgJiYgKHRpbWVfZWxhcHNlZCB8fAoJCQlMTV9TQU1QTEVTX1RIUkVTSE9MRCA8PSBsYXJnZV93ZWlnaHQgfHwgIW5ld19wYXJhbXMtPnNsb3BlKSkg"
    "ewoJCWxhcmdlX3Byb2Nlc3NlZCA9IGxtX3VwZGF0ZV9sYXJnZV9idWNrZXRzKG1vZGVsLCBuZXdfcGFyYW1zLAoJCQlhZ2dyLT5sYXJnZV9idWNrZXQsIGxh"
    "cmdlX3dlaWdodCwgIW5ld19wYXJhbXMtPnNsb3BlKTsKCQltZW1zZXQoJmFnZ3ItPmxhcmdlX2J1Y2tldFswXSwgMCwgc2l6ZW9mKGFnZ3ItPmxhcmdlX2J1"
    "Y2tldCkpOwoJfQoKCS8vIFVwZGF0ZSB0aGUgYmFzZSBwYXJhbWV0ZXIgaWYgc21hbGwgYnVja2V0IHdhcyBwcm9jZXNzZWQKCWlmIChzbWFsbF9wcm9jZXNz"
    "ZWQgJiYgbGlrZWx5KG5ld19wYXJhbXMtPnNtYWxsX2NvdW50KSkKCQluZXdfcGFyYW1zLT5iYXNlID0gZGl2X3U2NChuZXdfcGFyYW1zLT5zbWFsbF9zdW1f"
    "ZGVsYXksCgkJCW5ld19wYXJhbXMtPnNtYWxsX2NvdW50KTsKCgkvLyBVcGRhdGUgdGhlIHNsb3BlIHBhcmFtZXRlciBpZiBsYXJnZSBidWNrZXQgd2FzIHBy"
    "b2Nlc3NlZAoJaWYgKGxhcmdlX3Byb2Nlc3NlZCAmJiBsaWtlbHkobmV3X3BhcmFtcy0+bGFyZ2Vfc3VtX2JzaXplKSkKCQluZXdfcGFyYW1zLT5zbG9wZSA9"
    "IGRpdl91NjQobmV3X3BhcmFtcy0+bGFyZ2Vfc3VtX2RlbGF5LAoJCQlESVZfUk9VTkRfVVBfVUxMKG5ld19wYXJhbXMtPmxhcmdlX3N1bV9ic2l6ZSwgMTAy"
    "NCkpOwoKCS8vIFVwZGF0ZSBsYXN0IHVwZGF0ZWQgamlmZmllcyBpZiB1cGRhdGUgaGFwcGVuZWQgb3IgdGltZSBoYXMgZWxhcHNlZAoJaWYgKHNtYWxsX3By"
    "b2Nlc3NlZCB8fCBsYXJnZV9wcm9jZXNzZWQgfHwgdGltZV9lbGFwc2VkKQoJCW5ld19wYXJhbXMtPmxhc3RfdXBkYXRlX2ppZmZpZXMgPSBub3c7CgoJcmN1"
    "X2Fzc2lnbl9wb2ludGVyKG1vZGVsLT5wYXJhbXMsIG5ld19wYXJhbXMpOwoJc3Bpbl91bmxvY2tfaXJxcmVzdG9yZSgmbW9kZWwtPnVwZGF0ZV9sb2NrLCBm"
    "bGFncyk7CgoJa2ZyZWVfcmN1KG9sZF9wYXJhbXMsIHJjdSk7Cn0KCi8vIERldGVybWluZSB0aGUgYnVja2V0IGluZGV4IGZvciBhIGdpdmVuIG1lYXN1cmVk"
    "IGFuZCBwcmVkaWN0ZWQgbGF0ZW5jeQpzdGF0aWMgdTggbG1faW5wdXRfYnVja2V0X2luZGV4KHU2NCBtZWFzdXJlZCwgdTY0IHByZWRpY3RlZCkgewoJdTMy"
    "IGJ1Y2tldF9pbmRleDsKCglpZiAobWVhc3VyZWQgPCBwcmVkaWN0ZWQgKiAyKQoJCWJ1Y2tldF9pbmRleCA9IGRpdl91NjQoKG1lYXN1cmVkICogMjApLCBw"
    "cmVkaWN0ZWQpOwoJZWxzZSBpZiAobWVhc3VyZWQgPCBwcmVkaWN0ZWQgKiA1KQoJCWJ1Y2tldF9pbmRleCA9IGRpdl91NjQoKG1lYXN1cmVkICogMTApLCBw"
    "cmVkaWN0ZWQpICsgMjA7CgllbHNlCgkJYnVja2V0X2luZGV4ID0gZGl2X3U2NCgobWVhc3VyZWQgKiAzKSwgcHJlZGljdGVkKSArIDQwOwoKCWlmIChidWNr"
    "ZXRfaW5kZXggPj0gTE1fTEFUX0JVQ0tFVF9DT1VOVCkKCQlidWNrZXRfaW5kZXggPSBMTV9MQVRfQlVDS0VUX0NPVU5UIC0gMTsKCglyZXR1cm4gKHU4KWJ1"
    "Y2tldF9pbmRleDsKfQoKLy8gSW5wdXQgbGF0ZW5jeSBkYXRhIGludG8gdGhlIGxhdGVuY3kgbW9kZWwKc3RhdGljIHZvaWQgbGF0ZW5jeV9tb2RlbF9pbnB1"
    "dChzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQsCgkJc3RydWN0IGxhdGVuY3lfbW9kZWwgKm1vZGVsLAoJCXUzMiBibG9ja19zaXplLCB1NjQgbGF0ZW5jeSwgdTY0"
    "IHByZWRfbGF0LCB1MzIgd2VpZ2h0KSB7Cgl1bnNpZ25lZCBsb25nIGZsYWdzOwoJdTggYnVja2V0X2luZGV4OwoJc3RydWN0IGxtX2J1Y2tldHMgKmJ1Y2tl"
    "dHM7Cgl1NjQgY3VycmVudF9iYXNlOwoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXM7CgoJbG9jYWxfaXJxX3NhdmUoZmxhZ3MpOwoJYnVj"
    "a2V0cyA9IHBlcl9jcHVfcHRyKG1vZGVsLT5wY3B1X2J1Y2tldHMsIF9fc21wX3Byb2Nlc3Nvcl9pZCgpKTsKCglyY3VfcmVhZF9sb2NrKCk7CglwYXJhbXMg"
    "PSByY3VfZGVyZWZlcmVuY2UobW9kZWwtPnBhcmFtcyk7CgljdXJyZW50X2Jhc2UgPSBwYXJhbXMtPmJhc2U7CglyY3VfcmVhZF91bmxvY2soKTsKCglpZiAo"
    "YmxvY2tfc2l6ZSA8PSBMTV9CTE9DS19TSVpFX1RIUkVTSE9MRCkgewoJCS8vIEhhbmRsZSBzbWFsbCByZXF1ZXN0cwoJCWJ1Y2tldF9pbmRleCA9IGxtX2lu"
    "cHV0X2J1Y2tldF9pbmRleChsYXRlbmN5LCBjdXJyZW50X2Jhc2UgPzogMSk7CgoJCWJ1Y2tldHMtPnNtYWxsX2J1Y2tldFtidWNrZXRfaW5kZXhdLnN1bV9v"
    "Zl93ZWlnaHRzICs9IHdlaWdodDsKCQlidWNrZXRzLT5zbWFsbF9idWNrZXRbYnVja2V0X2luZGV4XS53ZWlnaHRlZF9zdW1fbGF0ZW5jeSArPQoJCQlsYXRl"
    "bmN5ICogd2VpZ2h0OwoKCQlsb2NhbF9pcnFfcmVzdG9yZShmbGFncyk7CgoJCWlmICh1bmxpa2VseSghY3VycmVudF9iYXNlKSkgewoJCQlsYXRlbmN5X21v"
    "ZGVsX3VwZGF0ZShhZCwgbW9kZWwpOwoJCQlyZXR1cm47CgkJfQoJfSBlbHNlIHsKCQkvLyBIYW5kbGUgbGFyZ2UgcmVxdWVzdHMKCQlpZiAoIWN1cnJlbnRf"
    "YmFzZSB8fCAhcHJlZF9sYXQpIHsKCQkJbG9jYWxfaXJxX3Jlc3RvcmUoZmxhZ3MpOwoJCQlyZXR1cm47CgkJfQoKCQlidWNrZXRfaW5kZXggPSBsbV9pbnB1"
    "dF9idWNrZXRfaW5kZXgobGF0ZW5jeSwgcHJlZF9sYXQpOwoKCQlidWNrZXRzLT5sYXJnZV9idWNrZXRbYnVja2V0X2luZGV4XS5zdW1fb2Zfd2VpZ2h0cyAr"
    "PSB3ZWlnaHQ7CgkJYnVja2V0cy0+bGFyZ2VfYnVja2V0W2J1Y2tldF9pbmRleF0ud2VpZ2h0ZWRfc3VtX2xhdGVuY3kgKz0KCQkJbGF0ZW5jeSAqIHdlaWdo"
    "dDsKCQlidWNrZXRzLT5sYXJnZV9idWNrZXRbYnVja2V0X2luZGV4XS53ZWlnaHRlZF9zdW1fYmxvY2tfc2l6ZSArPQoJCQlibG9ja19zaXplICogd2VpZ2h0"
    "OwoKCQlsb2NhbF9pcnFfcmVzdG9yZShmbGFncyk7Cgl9Cn0KCi8vIFByZWRpY3QgdGhlIGxhdGVuY3kgZm9yIGEgZ2l2ZW4gYmxvY2sgc2l6ZSB1c2luZyB0"
    "aGUgbGF0ZW5jeSBtb2RlbApzdGF0aWMgdTY0IGxhdGVuY3lfbW9kZWxfcHJlZGljdChzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwsIHUzMiBibG9ja19z"
    "aXplKSB7Cgl1NjQgcmVzdWx0OwoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXM7CgoJcmN1X3JlYWRfbG9jaygpOwoJcGFyYW1zID0gcmN1"
    "X2RlcmVmZXJlbmNlKG1vZGVsLT5wYXJhbXMpOwoKCXJlc3VsdCA9IHBhcmFtcy0+YmFzZTsKCWlmIChibG9ja19zaXplID4gTE1fQkxPQ0tfU0laRV9USFJF"
    "U0hPTEQpCgkJcmVzdWx0ICs9IHBhcmFtcy0+c2xvcGUgKgoJCQlESVZfUk9VTkRfVVBfVUxMKGJsb2NrX3NpemUgLSBMTV9CTE9DS19TSVpFX1RIUkVTSE9M"
    "RCwgMTAyNCk7CgoJcmN1X3JlYWRfdW5sb2NrKCk7CgoJcmV0dXJuIHJlc3VsdDsKfQoKLy8gRGV0ZXJtaW5lIHRoZSB0eXBlIG9mIG9wZXJhdGlvbiBiYXNl"
    "ZCBvbiByZXF1ZXN0IGZsYWdzCnN0YXRpYyB1OCBhZGlvc19vcHR5cGUoc3RydWN0IHJlcXVlc3QgKnJxKSB7Cglzd2l0Y2ggKHJxLT5jbWRfZmxhZ3MgJiBS"
    "RVFfT1BfTUFTSykgewoJY2FzZSBSRVFfT1BfUkVBRDoKCQlyZXR1cm4gQURJT1NfUkVBRDsKCWNhc2UgUkVRX09QX1dSSVRFOgoJCXJldHVybiBBRElPU19X"
    "UklURTsKCWNhc2UgUkVRX09QX0RJU0NBUkQ6CgkJcmV0dXJuIEFESU9TX0RJU0NBUkQ7CglkZWZhdWx0OgoJCXJldHVybiBBRElPU19PVEhFUjsKCX0KfQoK"
    "c3RhdGljIGlubGluZSB1OCBhZGlvc19vcHR5cGVfbm90X3JlYWQoc3RydWN0IHJlcXVlc3QgKnJxKSB7CglyZXR1cm4gKHJxLT5jbWRfZmxhZ3MgJiBSRVFf"
    "T1BfTUFTSykgIT0gUkVRX09QX1JFQUQ7Cn0KCi8vIEhlbHBlciBmdW5jdGlvbiB0byByZXRyaWV2ZSBhZGlvc19ycV9kYXRhIGZyb20gYSByZXF1ZXN0CnN0"
    "YXRpYyBpbmxpbmUgc3RydWN0IGFkaW9zX3JxX2RhdGEgKmdldF9ycV9kYXRhKHN0cnVjdCByZXF1ZXN0ICpycSkgewoJcmV0dXJuIHJxLT5lbHYucHJpdlsw"
    "XTsKfQoKc3RhdGljIGlubGluZQp2b2lkIHNldF9hZGlvc19zdGF0ZShzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQsIHUzMiBzaGlmdCwgdTMyIGlkeCwgYm9vbCBm"
    "bGFnKSB7CglpZiAoZmxhZykKCQlhdG9taWNfb3IoMVUgPDwgKGlkeCArIHNoaWZ0KSwgJmFkLT5zdGF0ZSk7CgllbHNlCgkJYXRvbWljX2FuZG5vdCgxVSA8"
    "PCAoaWR4ICsgc2hpZnQpLCAmYWQtPnN0YXRlKTsKfQoKc3RhdGljIGlubGluZSB1MzIgZ2V0X2FkaW9zX3N0YXRlKHN0cnVjdCBhZGlvc19kYXRhICphZCkK"
    "eyByZXR1cm4gYXRvbWljX3JlYWQoJmFkLT5zdGF0ZSk7IH0KCnN0YXRpYyBpbmxpbmUgdTMyIGV2YWxfdGhpc19hZGlvc19zdGF0ZSh1MzIgc3RhdGUsIHUz"
    "MiBzaGlmdCkKeyByZXR1cm4gKHN0YXRlID4+IHNoaWZ0KSAmIDB4MzsgfQoKc3RhdGljIGlubGluZSB1MzIgZXZhbF9hZGlvc19zdGF0ZShzdHJ1Y3QgYWRp"
    "b3NfZGF0YSAqYWQsIHUzMiBzaGlmdCkKeyByZXR1cm4gZXZhbF90aGlzX2FkaW9zX3N0YXRlKGdldF9hZGlvc19zdGF0ZShhZCksIHNoaWZ0KTsgfQoKLy8g"
    "QWRkIGEgcmVxdWVzdCB0byB0aGUgZGVhZGxpbmUtc29ydGVkIHJlZC1ibGFjayB0cmVlCnN0YXRpYyB2b2lkIGFkZF90b19kbF90cmVlKAoJCXN0cnVjdCBh"
    "ZGlvc19kYXRhICphZCwgYm9vbCBkbF9pZHgsIHN0cnVjdCByZXF1ZXN0ICpycSkgewoJc3RydWN0IHJiX3Jvb3RfY2FjaGVkICpyb290ID0gJmFkLT5kbF90"
    "cmVlW2RsX2lkeF07CglzdHJ1Y3QgcmJfbm9kZSAqKmxpbmsgPSAmKHJvb3QtPnJiX3Jvb3QucmJfbm9kZSksICpwYXJlbnQgPSBOVUxMOwoJYm9vbCBsZWZ0"
    "bW9zdCA9IHRydWU7CglzdHJ1Y3QgYWRpb3NfcnFfZGF0YSAqcmQgPSBnZXRfcnFfZGF0YShycSk7CglzdHJ1Y3QgZGxfZ3JvdXAgKmRsZzsKCXU2NCBkZWFk"
    "bGluZTsKCWJvb2wgd2FzX2VtcHR5ID0gUkJfRU1QVFlfUk9PVCgmcm9vdC0+cmJfcm9vdCk7CgoJLyogVGllci0yOiBTeW5jaHJvbm91cyBSZXF1ZXN0cwoJ"
    "ICogLSBOZWVkcyB0byBiZSBGSUZPIHdpdGhpbiBhIHNhbWUgb3B0eXBlCgkgKiAtIFJlbGF4ZWQgb3JkZXIgYmV0d2VlbiBkaWZmZXJlbnQgb3B0eXBlcwoJ"
    "ICogLSBiYXNpY2FsbHkgbmVlZHMgdG8gYmUgcHJvY2Vzc2VkIGluIGVhcmx5IHRpbWUgKi8KCXJkLT5kZWFkbGluZSA9IHJxLT5zdGFydF90aW1lX25zOwoK"
    "CS8qIFRpZXItMzogQXluY2hyb25vdXMgUmVxdWVzdHMKCSAqIC0gQ2FuIGJlIHJlb3JkZXJlZCBhbmQgZGVsYXllZCBmcmVlbHkgKi8KCWlmICghKHJxLT5j"
    "bWRfZmxhZ3MgJiBSRVFfU1lOQykpIHsKCQlyZC0+ZGVhZGxpbmUgKz0gYWQtPmxhdGVuY3lfdGFyZ2V0W2FkaW9zX29wdHlwZShycSldOwoJCWlmICghY29t"
    "cGxpYW50KGFkLCBBRElPU19DRl9GSVhPUkRFUikpCgkJCXJkLT5kZWFkbGluZSArPSByZC0+cHJlZF9sYXQ7Cgl9CgoJLy8gTm93IHF1YW50aXplIHRoZSBk"
    "ZWFkbGluZSAoLT4gZGxnLT5kZWFkbGluZSA9PSBSQi1UcmVlIGtleSkKCWRlYWRsaW5lID0gcmQtPmRlYWRsaW5lICYgfigoMVVMTCA8PCBBRElPU19RVUFO"
    "VFVNX1NISUZUKSAtIDEpOwoKCXdoaWxlICgqbGluaykgewoJCWRsZyA9IHJiX2VudHJ5KCpsaW5rLCBzdHJ1Y3QgZGxfZ3JvdXAsIG5vZGUpOwoJCXM2NCBk"
    "aWZmID0gZGVhZGxpbmUgLSBkbGctPmRlYWRsaW5lOwoKCQlwYXJlbnQgPSAqbGluazsKCQlpZiAoZGlmZiA8IDApIHsKCQkJbGluayA9ICYoKCpsaW5rKS0+"
    "cmJfbGVmdCk7CgkJfSBlbHNlIGlmIChkaWZmID4gMCkgewoJCQlsaW5rID0gJigoKmxpbmspLT5yYl9yaWdodCk7CgkJCWxlZnRtb3N0ID0gZmFsc2U7CgkJ"
    "fSBlbHNlIHsgLy8gZGlmZiA9PSAwCgkJCWdvdG8gZm91bmQ7CgkJfQoJfQoKCWRsZyA9IHJiX2VudHJ5X3NhZmUocGFyZW50LCBzdHJ1Y3QgZGxfZ3JvdXAs"
    "IG5vZGUpOwoJaWYgKCFkbGcgfHwgZGxnLT5kZWFkbGluZSAhPSBkZWFkbGluZSkgewoJCWRsZyA9IGttZW1fY2FjaGVfemFsbG9jKGFkLT5kbF9ncm91cF9w"
    "b29sLCBHRlBfQVRPTUlDKTsKCQlpZiAoIWRsZykKCQkJcmV0dXJuOwoJCWRsZy0+ZGVhZGxpbmUgPSBkZWFkbGluZTsKCQlJTklUX0xJU1RfSEVBRCgmZGxn"
    "LT5ycXMpOwoJCXJiX2xpbmtfbm9kZSgmZGxnLT5ub2RlLCBwYXJlbnQsIGxpbmspOwoJCXJiX2luc2VydF9jb2xvcl9jYWNoZWQoJmRsZy0+bm9kZSwgcm9v"
    "dCwgbGVmdG1vc3QpOwoJfQpmb3VuZDoKCWxpc3RfYWRkX3RhaWwoJnJkLT5kbF9ub2RlLCAmZGxnLT5ycXMpOwoJcmQtPmRsX2dyb3VwID0gJmRsZy0+cnFz"
    "OwoKCWlmICh3YXNfZW1wdHkpCgkJc2V0X2FkaW9zX3N0YXRlKGFkLCBBRElPU19TVEFURV9ETCwgZGxfaWR4LCB0cnVlKTsKfQoKLy8gUmVtb3ZlIGEgcmVx"
    "dWVzdCBmcm9tIHRoZSBkZWFkbGluZS1zb3J0ZWQgcmVkLWJsYWNrIHRyZWUKc3RhdGljIHZvaWQgZGVsX2Zyb21fZGxfdHJlZSgKCQlzdHJ1Y3QgYWRpb3Nf"
    "ZGF0YSAqYWQsIGJvb2wgZGxfaWR4LCBzdHJ1Y3QgcmVxdWVzdCAqcnEpIHsKCXN0cnVjdCByYl9yb290X2NhY2hlZCAqcm9vdCA9ICZhZC0+ZGxfdHJlZVtk"
    "bF9pZHhdOwoJc3RydWN0IGFkaW9zX3JxX2RhdGEgKnJkID0gZ2V0X3JxX2RhdGEocnEpOwoJc3RydWN0IGRsX2dyb3VwICpkbGcgPSBjb250YWluZXJfb2Yo"
    "cmQtPmRsX2dyb3VwLCBzdHJ1Y3QgZGxfZ3JvdXAsIHJxcyk7CgoJbGlzdF9kZWxfaW5pdCgmcmQtPmRsX25vZGUpOwoJaWYgKGxpc3RfZW1wdHkoJmRsZy0+"
    "cnFzKSkgewoJCXJiX2VyYXNlX2NhY2hlZCgmZGxnLT5ub2RlLCByb290KTsKCQlrbWVtX2NhY2hlX2ZyZWUoYWQtPmRsX2dyb3VwX3Bvb2wsIGRsZyk7Cgl9"
    "CglyZC0+ZGxfZ3JvdXAgPSBOVUxMOwoKCWlmIChSQl9FTVBUWV9ST09UKCZhZC0+ZGxfdHJlZVtkbF9pZHhdLnJiX3Jvb3QpKQoJCXNldF9hZGlvc19zdGF0"
    "ZShhZCwgQURJT1NfU1RBVEVfREwsIGRsX2lkeCwgZmFsc2UpOwp9CgovLyBSZW1vdmUgYSByZXF1ZXN0IGZyb20gdGhlIHNjaGVkdWxlcgpzdGF0aWMgdm9p"
    "ZCByZW1vdmVfcmVxdWVzdChzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQsIHN0cnVjdCByZXF1ZXN0ICpycSkgewoJYm9vbCBkbF9pZHggPSBhZGlvc19vcHR5cGVf"
    "bm90X3JlYWQocnEpOwoJc3RydWN0IHJlcXVlc3RfcXVldWUgKnEgPSBycS0+cTsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZCA9IGdldF9ycV9kYXRhKHJx"
    "KTsKCglsaXN0X2RlbF9pbml0KCZycS0+cXVldWVsaXN0KTsKCgkvLyBXZSBtaWdodCBub3QgYmUgb24gdGhlIHJidHJlZSwgaWYgd2UgYXJlIGRvaW5nIGFu"
    "IGluc2VydCBtZXJnZQoJaWYgKHJkLT5kbF9ncm91cCkKCQlkZWxfZnJvbV9kbF90cmVlKGFkLCBkbF9pZHgsIHJxKTsKCgllbHZfcnFoYXNoX2RlbChxLCBy"
    "cSk7CglpZiAocS0+bGFzdF9tZXJnZSA9PSBycSkKCQlxLT5sYXN0X21lcmdlID0gTlVMTDsKfQoKLy8gV2UgbGltaXQgdGhlIGRlcHRoIG9mIHJlcXVlc3Qg"
    "YWxsb2NhdGlvbiBmb3IgYXN5bmNocm9ub3VzIGFuZCB3cml0ZSByZXF1ZXN0cwpzdGF0aWMgdm9pZCBhZGlvc19saW1pdF9kZXB0aCh1bnNpZ25lZCBpbnQg"
    "b3BmLCBzdHJ1Y3QgYmxrX21xX2FsbG9jX2RhdGEgKmRhdGEpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGRhdGEtPnEtPmVsZXZhdG9yLT5lbGV2YXRv"
    "cl9kYXRhOwoKCS8vIERvIG5vdCB0aHJvdHRsZSBzeW5jaHJvbm91cyByZWFkcwoJaWYgKG9wX2lzX3N5bmMob3BmKSAmJiAhb3BfaXNfd3JpdGUob3BmKSkK"
    "CQlyZXR1cm47CgoJLyoKCSAqIHNiaXRtYXAncyBfX21hcF9kZXB0aF93aXRoX3NoYWxsb3coKSBoYXMgdGFrZW4gc2hhbGxvd19kZXB0aCBpbgoJICogd2hv"
    "bGUtcXVldWUgdW5pdHMgc2luY2UgNi4xMiAodGhlIHNhbWUgcmVsZWFzZSBtcS1kZWFkbGluZSdzCgkgKiBkZF90b193b3JkX2RlcHRoKCkgd2FzIGRyb3Bw"
    "ZWQpIGFuZCBkb2VzIHRoZSBwZXItd29yZCBkaXZpc2lvbgoJICogaXRzZWxmLiBQYXNzaW5nIGFuIGFscmVhZHkgcGVyLXdvcmQgdmFsdWUgaGVyZSAodGhl"
    "IG9sZAoJICogdG9fd29yZF9kZXB0aCgpIGhlbHBlcikgZ290IGl0IHNxdWFyZWQgYXdheTogd29yZF9kZXB0aF4yIC8KCSAqIHNiLT5kZXB0aCwgc2lsZW50"
    "bHkgY2FwcGluZyBhc3luYy93cml0ZSBhbGxvY2F0aW9uIGF0IDw9IDY0IHRhZ3MKCSAqIHJlZ2FyZGxlc3Mgb2YgYXN5bmNfZGVwdGguIFBhc3MgdGhlIHJh"
    "dyBxdWV1ZS13aWRlIGRlcHRoLCBtYXRjaGluZwoJICogbXEtZGVhZGxpbmUva3liZXIuCgkgKi8KCWRhdGEtPnNoYWxsb3dfZGVwdGggPSBhZC0+YXN5bmNf"
    "ZGVwdGg7Cn0KCi8vIFRoZSBudW1iZXIgb2YgcmVxdWVzdHMgaW4gdGhlIHF1ZXVlIHdhcyBub3RpZmllZCBmcm9tIHRoZSBibG9jayBsYXllcgpzdGF0aWMg"
    "dm9pZCBhZGlvc19kZXB0aF91cGRhdGVkKHN0cnVjdCBibGtfbXFfaHdfY3R4ICpoY3R4KSB7CglzdHJ1Y3QgcmVxdWVzdF9xdWV1ZSAqcSA9IGhjdHgtPnF1"
    "ZXVlOwoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gcS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgYmxrX21xX3RhZ3MgKnRhZ3MgPSBoY3R4"
    "LT5zY2hlZF90YWdzOwoKCWFkLT5hc3luY19kZXB0aCA9IHEtPm5yX3JlcXVlc3RzOwoKCXNiaXRtYXBfcXVldWVfbWluX3NoYWxsb3dfZGVwdGgoJnRhZ3Mt"
    "PmJpdG1hcF90YWdzLCBhZC0+YXN5bmNfZGVwdGgpOwp9CgovLyBIYW5kbGUgcmVxdWVzdCBtZXJnaW5nIGFmdGVyIGEgbWVyZ2Ugb3BlcmF0aW9uCnN0YXRp"
    "YyB2b2lkIGFkaW9zX3JlcXVlc3RfbWVyZ2VkKHN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxLCBzdHJ1Y3QgcmVxdWVzdCAqcmVxLAoJCQkJICBlbnVtIGVsdl9t"
    "ZXJnZSB0eXBlKSB7Cglib29sIGRsX2lkeCA9IGFkaW9zX29wdHlwZV9ub3RfcmVhZChyZXEpOwoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gcS0+ZWxldmF0"
    "b3ItPmVsZXZhdG9yX2RhdGE7CgoJLy8gUmVwb3NpdGlvbiByZXF1ZXN0IGluIHRoZSBkZWFkbGluZS1zb3J0ZWQgdHJlZQoJZGVsX2Zyb21fZGxfdHJlZShh"
    "ZCwgZGxfaWR4LCByZXEpOwoJYWRkX3RvX2RsX3RyZWUoYWQsIGRsX2lkeCwgcmVxKTsKfQoKLy8gSGFuZGxlIG1lcmdpbmcgb2YgcmVxdWVzdHMgYWZ0ZXIg"
    "b25lIGhhcyBiZWVuIG1lcmdlZCBpbnRvIGFub3RoZXIKc3RhdGljIHZvaWQgYWRpb3NfbWVyZ2VkX3JlcXVlc3RzKHN0cnVjdCByZXF1ZXN0X3F1ZXVlICpx"
    "LCBzdHJ1Y3QgcmVxdWVzdCAqcmVxLAoJCQkJICAgc3RydWN0IHJlcXVlc3QgKm5leHQpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IHEtPmVsZXZhdG9y"
    "LT5lbGV2YXRvcl9kYXRhOwoKCWxvY2tkZXBfYXNzZXJ0X2hlbGQoJmFkLT5sb2NrKTsKCgkvLyBraWxsIGtub3dsZWRnZSBvZiBuZXh0LCB0aGlzIG9uZSBp"
    "cyBhIGdvbmVyCglyZW1vdmVfcmVxdWVzdChhZCwgbmV4dCk7Cn0KCi8vIFRyeSB0byBtZXJnZSBhIGJpbyBpbnRvIGFuIGV4aXN0aW5nIHJxIGJlZm9yZSBh"
    "c3NvY2lhdGluZyBpdCB3aXRoIGFuIHJxCnN0YXRpYyBib29sIGFkaW9zX2Jpb19tZXJnZShzdHJ1Y3QgcmVxdWVzdF9xdWV1ZSAqcSwgc3RydWN0IGJpbyAq"
    "YmlvLAoJCXVuc2lnbmVkIGludCBucl9zZWdzKSB7Cgl1bnNpZ25lZCBsb25nIGZsYWdzOwoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gcS0+ZWxldmF0b3It"
    "PmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgcmVxdWVzdCAqZnJlZSA9IE5VTEw7Cglib29sIHJldDsKCglpZiAoIXNwaW5fdHJ5bG9ja19pcnFzYXZlKCZhZC0+"
    "bG9jaywgZmxhZ3MpKQoJCXJldHVybiBmYWxzZTsKCglyZXQgPSBibGtfbXFfc2NoZWRfdHJ5X21lcmdlKHEsIGJpbywgbnJfc2VncywgJmZyZWUpOwoJc3Bp"
    "bl91bmxvY2tfaXJxcmVzdG9yZSgmYWQtPmxvY2ssIGZsYWdzKTsKCglpZiAoZnJlZSkKCQlibGtfbXFfZnJlZV9yZXF1ZXN0KGZyZWUpOwoKCXJldHVybiBy"
    "ZXQ7Cn0KCnN0YXRpYyBib29sIG1lcmdlX29yX2luc2VydF90b19kbF90cmVlKHN0cnVjdCBhZGlvc19kYXRhICphZCwKCQlzdHJ1Y3QgcmVxdWVzdCAqcnEs"
    "IHN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxLCBzdHJ1Y3QgbGlzdF9oZWFkICpmcmVlKSB7CglpZiAoYWRpb3NfdHJ5X2luc2VydF9tZXJnZShxLCBycSwgZnJl"
    "ZSkpCgkJcmV0dXJuIHRydWU7CgoJYm9vbCBkbF9pZHggPSBhZGlvc19vcHR5cGVfbm90X3JlYWQocnEpOwoJYWRkX3RvX2RsX3RyZWUoYWQsIGRsX2lkeCwg"
    "cnEpOwoKCWlmIChycV9tZXJnZWFibGUocnEpKSB7CgkJZWx2X3JxaGFzaF9hZGQocSwgcnEpOwoJCWlmICghcS0+bGFzdF9tZXJnZSkKCQkJcS0+bGFzdF9t"
    "ZXJnZSA9IHJxOwoJfQoKCXJldHVybiBmYWxzZTsKfQoKc3RhdGljIHZvaWQgaW5zZXJ0X3RvX3ByaW9fcXVldWUoc3RydWN0IGFkaW9zX2RhdGEgKmFkLAoJ"
    "CXN0cnVjdCByZXF1ZXN0ICpycSwgYm9vbCBwcV9pZHgpIHsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZCA9IGdldF9ycV9kYXRhKHJxKTsKCgkvKiBXZSdy"
    "ZSBzdXJlIHRoYXQgcmQtPm1hbmFnZWQgPT0gdHJ1ZSAqLwoJdW5pb24gYWRpb3NfaW5fZmxpZ2h0X3JxcyBpZnIgPSB7CgkJLmNvdW50ICAgICAgICAgID0g"
    "MSwKCQkudG90YWxfcHJlZF9sYXQgPSByZC0+cHJlZF9sYXQsCgl9OwoJYXRvbWljNjRfYWRkKGlmci5zY2FsYXIsICZhZC0+aW5fZmxpZ2h0X3Jxcy5hdG9t"
    "aWMpOwoKCWFkaW9zX3Njb3BlZF9ndWFyZChzcGlubG9ja19pcnFzYXZlLCAmYWQtPnBxX2xvY2spIHsKCQlib29sIHdhc19lbXB0eSA9IGxpc3RfZW1wdHko"
    "JmFkLT5wcmlvX3F1ZXVlW3BxX2lkeF0pOwoJCWxpc3RfYWRkX3RhaWwoJnJxLT5xdWV1ZWxpc3QsICZhZC0+cHJpb19xdWV1ZVtwcV9pZHhdKTsKCQlpZiAo"
    "d2FzX2VtcHR5KQoJCQlzZXRfYWRpb3Nfc3RhdGUoYWQsIEFESU9TX1NUQVRFX1BRLCBwcV9pZHgsIHRydWUpOwoJfQp9CgovLyBJbnNlcnQgYSByZXF1ZXN0"
    "IGludG8gdGhlIHNjaGVkdWxlciAoYWZ0ZXIgUmVhZCAmIFdyaXRlIG1vZGVscyBzdGFiaWxpemVkKQpzdGF0aWMgdm9pZCBpbnNlcnRfcmVxdWVzdF9wb3N0"
    "X3N0YWJpbGl0eShzdHJ1Y3QgYmxrX21xX2h3X2N0eCAqaGN0eCwKCQlzdHJ1Y3QgcmVxdWVzdCAqcnEsIGJsa19pbnNlcnRfdCBpbnNlcnRfZmxhZ3MsIHN0"
    "cnVjdCBsaXN0X2hlYWQgKmZyZWUpIHsKCXN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxID0gaGN0eC0+cXVldWU7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBx"
    "LT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZCA9IGdldF9ycV9kYXRhKHJxKTsKCXU4IG9wdHlwZSA9IGFkaW9z"
    "X29wdHlwZShycSk7CgoJcmQtPm1hbmFnZWQgPSB0cnVlOwoJcmQtPmJsb2NrX3NpemUgPSBibGtfcnFfYnl0ZXMocnEpOwoJcmQtPnByZWRfbGF0ID0KCQls"
    "YXRlbmN5X21vZGVsX3ByZWRpY3QoJmFkLT5sYXRlbmN5X21vZGVsW29wdHlwZV0sIHJkLT5ibG9ja19zaXplKTsKCWlmICh1bmxpa2VseShyZC0+cHJlZF9s"
    "YXQgPiBhZC0+bGF0X21vZGVsX2xhdGVuY3lfbGltaXQpKQoJCXJkLT5wcmVkX2xhdCA9IGFkLT5sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdDsKCgkvKiBUaWVy"
    "LTA6IEJMS19NUV9JTlNFUlRfQVRfSEVBRCBSZXF1ZXN0cyAqLwoJaWYgKGluc2VydF9mbGFncyAmIEJMS19NUV9JTlNFUlRfQVRfSEVBRCkgewoJCWluc2Vy"
    "dF90b19wcmlvX3F1ZXVlKGFkLCBycSwgMCk7CgkJcmV0dXJuOwoJfQoKCWlmIChtZXJnZV9vcl9pbnNlcnRfdG9fZGxfdHJlZShhZCwgcnEsIHEsIGZyZWUp"
    "KQoJCXJldHVybjsKfQoKLy8gSW5zZXJ0IGEgcmVxdWVzdCBpbnRvIHRoZSBzY2hlZHVsZXIgKGJlZm9yZSBSZWFkICYgV3JpdGUgbW9kZWxzIHN0YWJpbGl6"
    "ZXMpCnN0YXRpYyB2b2lkIGluc2VydF9yZXF1ZXN0X3ByZV9zdGFiaWxpdHkoc3RydWN0IGJsa19tcV9od19jdHggKmhjdHgsCgkJc3RydWN0IHJlcXVlc3Qg"
    "KnJxLCBibGtfaW5zZXJ0X3QgaW5zZXJ0X2ZsYWdzLCBzdHJ1Y3QgbGlzdF9oZWFkICpmcmVlKSB7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBoY3R4LT5x"
    "dWV1ZS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgYWRpb3NfcnFfZGF0YSAqcmQgPSBnZXRfcnFfZGF0YShycSk7Cgl1OCBvcHR5cGUgPSBh"
    "ZGlvc19vcHR5cGUocnEpOwoJdTggcHFfaWR4ID0gIShpbnNlcnRfZmxhZ3MgJiBCTEtfTVFfSU5TRVJUX0FUX0hFQUQpOwoJYm9vbCBzdGFibGUgPSBmYWxz"
    "ZTsKCglyZC0+bWFuYWdlZCA9IHRydWU7CglyZC0+YmxvY2tfc2l6ZSA9IGJsa19ycV9ieXRlcyhycSk7CglyZC0+cHJlZF9sYXQgPQoJCWxhdGVuY3lfbW9k"
    "ZWxfcHJlZGljdCgmYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBlXSwgcmQtPmJsb2NrX3NpemUpOwoJaWYgKHVubGlrZWx5KHJkLT5wcmVkX2xhdCA+IGFkLT5s"
    "YXRfbW9kZWxfbGF0ZW5jeV9saW1pdCkpCgkJcmQtPnByZWRfbGF0ID0gYWQtPmxhdF9tb2RlbF9sYXRlbmN5X2xpbWl0OwoKCWluc2VydF90b19wcmlvX3F1"
    "ZXVlKGFkLCBycSwgcHFfaWR4KTsKCglyY3VfcmVhZF9sb2NrKCk7CglpZiAocmN1X2RlcmVmZXJlbmNlKGFkLT5sYXRlbmN5X21vZGVsW0FESU9TX1JFQURd"
    "LnBhcmFtcyktPmJhc2UgPiAwICYmCgkJcmN1X2RlcmVmZXJlbmNlKGFkLT5sYXRlbmN5X21vZGVsW0FESU9TX1dSSVRFXS5wYXJhbXMpLT5iYXNlID4gMCkK"
    "CQkJc3RhYmxlID0gdHJ1ZTsKCXJjdV9yZWFkX3VubG9jaygpOwoKCWlmIChzdGFibGUpCgkJYWQtPm1vZGVsc19zdGFibGUgPSB0cnVlOwp9CgovLyBJbnNl"
    "cnQgbXVsdGlwbGUgcmVxdWVzdHMgaW50byB0aGUgc2NoZWR1bGVyCnN0YXRpYyB2b2lkIGFkaW9zX2luc2VydF9yZXF1ZXN0cyhzdHJ1Y3QgYmxrX21xX2h3"
    "X2N0eCAqaGN0eCwKCQkJCSAgIHN0cnVjdCBsaXN0X2hlYWQgKmxpc3QsCgkJCQkgICBib29sIGRpc3BhdGNoX25vdykgewoJYmxrX2luc2VydF90IGluc2Vy"
    "dF9mbGFncyA9IDA7Cgkodm9pZClkaXNwYXRjaF9ub3c7CglzdHJ1Y3QgcmVxdWVzdF9xdWV1ZSAqcSA9IGhjdHgtPnF1ZXVlOwoJc3RydWN0IGFkaW9zX2Rh"
    "dGEgKmFkID0gcS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgcmVxdWVzdCAqcnE7Cglib29sIHN0b3AgPSBmYWxzZTsKCUxJU1RfSEVBRChm"
    "cmVlKTsKCglkbyB7CglhZGlvc19zY29wZWRfZ3VhcmQoc3BpbmxvY2tfaXJxc2F2ZSwgJmFkLT5sb2NrKQoJZm9yIChpbnQgaSA9IDA7IGkgPCBBRElPU19N"
    "QVhfSU5TRVJUU19QRVJfTE9DSzsgaSsrKSB7CgkJaWYgKGxpc3RfZW1wdHkobGlzdCkpIHsKCQkJc3RvcCA9IHRydWU7CgkJCWJyZWFrOwoJCX0KCQlycSA9"
    "IGxpc3RfZmlyc3RfZW50cnkobGlzdCwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7CgkJbGlzdF9kZWxfaW5pdCgmcnEtPnF1ZXVlbGlzdCk7CgkJaWYg"
    "KGxpa2VseShhZC0+bW9kZWxzX3N0YWJsZSkpCgkJCWluc2VydF9yZXF1ZXN0X3Bvc3Rfc3RhYmlsaXR5KGhjdHgsIHJxLCBpbnNlcnRfZmxhZ3MsICZmcmVl"
    "KTsKCQllbHNlCgkJCWluc2VydF9yZXF1ZXN0X3ByZV9zdGFiaWxpdHkoaGN0eCwgcnEsIGluc2VydF9mbGFncywgJmZyZWUpOwoJfX0gd2hpbGUgKCFzdG9w"
    "KTsKCglhZGlvc19mcmVlX3JlcXVlc3RzKCZmcmVlKTsKfQoKLy8gUHJlcGFyZSBhIHJlcXVlc3QgYmVmb3JlIGl0IGlzIGluc2VydGVkIGludG8gdGhlIHNj"
    "aGVkdWxlcgpzdGF0aWMgdm9pZCBhZGlvc19wcmVwYXJlX3JlcXVlc3Qoc3RydWN0IHJlcXVlc3QgKnJxLCBzdHJ1Y3QgYmlvICpiaW8pIHsKCSh2b2lkKWJp"
    "bzsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IHJxLT5xLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZDsKCgly"
    "ZCA9IG1lbXBvb2xfYWxsb2MoYWQtPnJxX2RhdGFfcG9vbCwgR0ZQX0FUT01JQyk7CgltZW1zZXQocmQsIDAsIHNpemVvZigqcmQpKTsKCXJkLT5ycSA9IHJx"
    "OwoJcnEtPmVsdi5wcml2WzBdID0gcmQ7Cn0KCnN0YXRpYyBzdHJ1Y3QgYWRpb3NfcnFfZGF0YSAqZ2V0X2RsX2ZpcnN0X3JkKHN0cnVjdCBhZGlvc19kYXRh"
    "ICphZCwgYm9vbCBpZHgpIHsKCXN0cnVjdCByYl9yb290X2NhY2hlZCAqcm9vdCA9ICZhZC0+ZGxfdHJlZVtpZHhdOwoJc3RydWN0IHJiX25vZGUgKmZpcnN0"
    "ID0gcmJfZmlyc3RfY2FjaGVkKHJvb3QpOwoJc3RydWN0IGRsX2dyb3VwICpkbF9ncm91cCA9IHJiX2VudHJ5KGZpcnN0LCBzdHJ1Y3QgZGxfZ3JvdXAsIG5v"
    "ZGUpOwoKCXJldHVybiBsaXN0X2ZpcnN0X2VudHJ5KCZkbF9ncm91cC0+cnFzLCBzdHJ1Y3QgYWRpb3NfcnFfZGF0YSwgZGxfbm9kZSk7Cn0KCi8vIENvbXBh"
    "cmlzb24gZnVuY3Rpb24gZm9yIHNvcnRpbmcgcmVxdWVzdHMgYnkgYmxvY2sgYWRkcmVzcwpzdGF0aWMgaW50IGNtcF9ycV9wb3Modm9pZCAqcHJpdiwKCQlj"
    "b25zdCBzdHJ1Y3QgbGlzdF9oZWFkICphLCBjb25zdCBzdHJ1Y3QgbGlzdF9oZWFkICpiKSB7CglzdHJ1Y3QgcmVxdWVzdCAqcnFfYSA9IGxpc3RfZW50cnko"
    "YSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7CglzdHJ1Y3QgcmVxdWVzdCAqcnFfYiA9IGxpc3RfZW50cnkoYiwgc3RydWN0IHJlcXVlc3QsIHF1ZXVl"
    "bGlzdCk7Cgl1NjQgcG9zX2EgPSBibGtfcnFfcG9zKHJxX2EpOwoJdTY0IHBvc19iID0gYmxrX3JxX3BvcyhycV9iKTsKCglyZXR1cm4gKGludCkocG9zX2Eg"
    "PiBwb3NfYikgLSAoaW50KShwb3NfYSA8IHBvc19iKTsKfQoKI2lmbmRlZiBsaXN0X2xhc3RfZW50cnlfb3JfbnVsbAojZGVmaW5lIGxpc3RfbGFzdF9lbnRy"
    "eV9vcl9udWxsKHB0ciwgdHlwZSwgbWVtYmVyKSBcCgkoIWxpc3RfZW1wdHkocHRyKSA/IGxpc3RfbGFzdF9lbnRyeShwdHIsIHR5cGUsIG1lbWJlcikgOiBO"
    "VUxMKQojZW5kaWYKCi8vIFVwZGF0ZSB0aGUgZWxldmF0b3IgZGlyZWN0aW9uCnN0YXRpYyB2b2lkIHVwZGF0ZV9lbHZfZGlyZWN0aW9uKHN0cnVjdCBhZGlv"
    "c19kYXRhICphZCkgewoJaWYgKCFhZC0+aXNfcm90YXRpb25hbCkKCQlyZXR1cm47CgoJYm9vbCBwYWdlID0gYWQtPmJxX3BhZ2U7CglzdHJ1Y3QgbGlzdF9o"
    "ZWFkICpxID0gJmFkLT5iYXRjaF9xdWV1ZVtwYWdlXVsxXTsKCWlmIChhZC0+YnFfYmF0Y2hfb3JkZXJbcGFnZV0gPCBBRElPU19CT19FTEVWQVRPUiB8fCBs"
    "aXN0X2VtcHR5KHEpKSB7CgkJYWQtPmVsdl9kaXJlY3Rpb24gPSAwOwoJCXJldHVybjsKCX0KCgkvLyBHZXQgZmlyc3QgYW5kIGxhc3QgcmVxdWVzdCBwb3Np"
    "dGlvbnMgaW4gdGhlIHF1ZXVlCglzdHJ1Y3QgcmVxdWVzdCAqcnFfYSA9IGxpc3RfZmlyc3RfZW50cnkocSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7"
    "CglzdHJ1Y3QgcmVxdWVzdCAqcnFfYiA9IGxpc3RfbGFzdF9lbnRyeSAocSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7Cgl1NjQgcG9zX2EgPSBibGtf"
    "cnFfcG9zKHJxX2EpOwoJdTY0IHBvc19iID0gYmxrX3JxX3BvcyhycV9iKTsKCXU2NCBhdmdfcnFfcG9zID0gKHBvc19hICsgcG9zX2IpID4+IDE7CgoJYWQt"
    "PmVsdl9kaXJlY3Rpb24gPSAhIShhZC0+aGVhZF9wb3MgPiBhdmdfcnFfcG9zKTsKfQoKLy8gRmlsbCB0aGUgYmF0Y2ggcXVldWVzIHdpdGggcmVxdWVzdHMg"
    "ZnJvbSB0aGUgZGVhZGxpbmUtc29ydGVkIHJlZC1ibGFjayB0cmVlCnN0YXRpYyBib29sIGZpbGxfYmF0Y2hfcXVldWVzKHN0cnVjdCBhZGlvc19kYXRhICph"
    "ZCwgdTY0IHRwbCkgewoJc3RydWN0IGFkaW9zX3JxX2RhdGEgKnJkOwoJc3RydWN0IHJlcXVlc3QgKnJxOwoJc3RydWN0IGxpc3RfaGVhZCAqZGVzdF9xOwoJ"
    "dTggIGRlc3RfaWR4OwoJdTY0IGFkZGVkX2xhdCA9IDA7Cgl1MzIgb3B0eXBlX2NvdW50W0FESU9TX09QVFlQRVNdID0gezB9OwoJdTMyIGNvdW50ID0gMDsK"
    "CXU4IG9wdHlwZTsKCWJvb2wgcGFnZSA9ICFhZC0+YnFfcGFnZSwgZGxfaWR4LCBiaWFzX2lkeCwgdXBkYXRlX2JpYXM7Cgl1MzIgZGxfcXVldWVkOwoJdTgg"
    "YnFfYmF0Y2hfb3JkZXI7Cglib29sIHN0b3AgPSBmYWxzZTsKCgkvLyBSZXNldCBiYXRjaCBxdWV1ZSBjb3VudHMgZm9yIHRoZSBiYWNrIHBhZ2UKCW1lbXNl"
    "dCgmYWQtPmJhdGNoX2NvdW50W3BhZ2VdLCAwLCBzaXplb2YoYWQtPmJhdGNoX2NvdW50W3BhZ2VdKSk7CgoJYWQtPmJxX2JhdGNoX29yZGVyW3BhZ2VdID0K"
    "CQlicV9iYXRjaF9vcmRlciA9IGFkLT5iYXRjaF9vcmRlcjsKCglkbyB7CglhZGlvc19zY29wZWRfZ3VhcmQoc3BpbmxvY2tfaXJxc2F2ZSwgJmFkLT5sb2Nr"
    "KQoJZm9yIChpbnQgaSA9IDA7IGkgPCBBRElPU19NQVhfREVMRVRFU19QRVJfTE9DSzsgaSsrKSB7CgkJYm9vbCBoYXNfYmFzZSA9IGZhbHNlOwoKCQlkbF9x"
    "dWV1ZWQgPSBldmFsX2FkaW9zX3N0YXRlKGFkLCBBRElPU19TVEFURV9ETCk7CgkJLy8gQ2hlY2sgaWYgdGhlcmUgYXJlIGFueSByZXF1ZXN0cyBxdWV1ZWQg"
    "aW4gdGhlIGRlYWRsaW5lIHRyZWUKCQlpZiAoIWRsX3F1ZXVlZCkgewoJCQlzdG9wID0gdHJ1ZTsKCQkJYnJlYWs7CgkJfQoKCQkvLyBSZWFkcyBpZiBib3Ro"
    "IHF1ZXVlcyBoYXZlIHJlcXVlc3RzLCBvdGhlcndpc2UgcGljayB0aGUgbm9uLWVtcHR5LgoJCWRsX2lkeCA9IGRsX3F1ZXVlZCA+PiAxOwoKCQkvLyBHZXQg"
    "dGhlIGZpcnN0IHJlcXVlc3QgZnJvbSB0aGUgZGVhZGxpbmUtc29ydGVkIHRyZWUKCQlyZCA9IGdldF9kbF9maXJzdF9yZChhZCwgZGxfaWR4KTsKCgkJYmlh"
    "c19pZHggPSBhZC0+ZGxfYmlhcyA8IDA7CgkJLy8gSWYgcmVhZCBhbmQgd3JpdGUgcmVxdWVzdHMgYXJlIHF1ZXVlZCwgY2hvb3NlIG9uZSBiYXNlZCBvbiBi"
    "aWFzCgkJaWYgKGRsX3F1ZXVlZCA9PSAweDMpIHsKCQkJc3RydWN0IGFkaW9zX3JxX2RhdGEgKnRyZFsyXSA9IHtnZXRfZGxfZmlyc3RfcmQoYWQsIDApLCBy"
    "ZH07CgkJCXJkID0gdHJkW2JpYXNfaWR4XTsKCgkJCXVwZGF0ZV9iaWFzID0gKHRyZFtiaWFzX2lkeF0tPmRlYWRsaW5lID4gdHJkWyFiaWFzX2lkeF0tPmRl"
    "YWRsaW5lKTsKCQl9IGVsc2UKCQkJdXBkYXRlX2JpYXMgPSAoYmlhc19pZHggPT0gZGxfaWR4KTsKCgkJcnEgPSByZC0+cnE7CgkJb3B0eXBlID0gYWRpb3Nf"
    "b3B0eXBlKHJxKTsKCgkJcmN1X3JlYWRfbG9jaygpOwoJCWhhc19iYXNlID0KCQkJISFyY3VfZGVyZWZlcmVuY2UoYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBl"
    "XS5wYXJhbXMpLT5iYXNlOwoJCXJjdV9yZWFkX3VubG9jaygpOwoKCQkvLyBDaGVjayBiYXRjaCBzaXplIGFuZCB0b3RhbCBwcmVkaWN0ZWQgbGF0ZW5jeQoJ"
    "CWlmIChjb3VudCAmJiAoIWhhc19iYXNlIHx8CgkJCQlhZC0+YmF0Y2hfY291bnRbcGFnZV1bb3B0eXBlXSA+PSBhZC0+YmF0Y2hfbGltaXRbb3B0eXBlXSB8"
    "fAoJCQkJKHRwbCArIGFkZGVkX2xhdCArIHJkLT5wcmVkX2xhdCkgPiBhZC0+Z2xvYmFsX2xhdGVuY3lfd2luZG93KSkgewoJCQlzdG9wID0gdHJ1ZTsKCQkJ"
    "YnJlYWs7CgkJfQoKCQlpZiAodXBkYXRlX2JpYXMpIHsKCQkJczY0IHNpZ24gPSAoKHM2NCliaWFzX2lkeCA8PCAxKSAtIDE7CgkJCWlmICh1bmxpa2VseSgh"
    "cmQtPnByZWRfbGF0KSkKCQkJCWFkLT5kbF9iaWFzID0gc2lnbjsKCQkJZWxzZQoJCQkJLy8gQWRqdXN0IHRoZSBiaWFzIGJhc2VkIG9uIHRoZSBwcmVkaWN0"
    "ZWQgbGF0ZW5jeQoJCQkJYWQtPmRsX2JpYXMgKz0gc2lnbiAqIChzNjQpKChyZC0+cHJlZF9sYXQgKgoJCQkJCWFkaW9zX3ByaW9fdG9fd211bHRbYWQtPmRs"
    "X3ByaW9bYmlhc19pZHhdICsgMjBdKSA+PiAxMCk7CgkJfQoKCQlyZW1vdmVfcmVxdWVzdChhZCwgcnEpOwoKCQkvLyBBZGQgcmVxdWVzdCB0byB0aGUgY29y"
    "cmVzcG9uZGluZyBiYXRjaCBxdWV1ZQoJCWRlc3RfaWR4ID0gKGJxX2JhdGNoX29yZGVyID09IEFESU9TX0JPX09QVFlQRSB8fCBvcHR5cGUgPT0gQURJT1Nf"
    "T1RIRVIpPwoJCQlvcHR5cGUgOiAhIShyZC0+ZGVhZGxpbmUgIT0gcnEtPnN0YXJ0X3RpbWVfbnMpOwoJCWRlc3RfcSA9ICZhZC0+YmF0Y2hfcXVldWVbcGFn"
    "ZV1bZGVzdF9pZHhdOwoJCWxpc3RfYWRkX3RhaWwoJnJxLT5xdWV1ZWxpc3QsIGRlc3RfcSk7CgkJYWQtPmJxX3N0YXRlW3BhZ2VdIHw9IDFVIDw8IGRlc3Rf"
    "aWR4OwoJCWFkLT5iYXRjaF9jb3VudFtwYWdlXVtvcHR5cGVdKys7CgkJb3B0eXBlX2NvdW50W29wdHlwZV0rKzsKCQlhZGRlZF9sYXQgKz0gcmQtPnByZWRf"
    "bGF0OwoJCWNvdW50Kys7Cgl9fSB3aGlsZSAoIXN0b3ApOwoKCWlmIChicV9iYXRjaF9vcmRlciA9PSBBRElPU19CT19FTEVWQVRPUiAmJiBhZC0+YmF0Y2hf"
    "Y291bnRbcGFnZV1bMV0gPiAxKQoJCQlsaXN0X3NvcnQoTlVMTCwgJmFkLT5iYXRjaF9xdWV1ZVtwYWdlXVsxXSwgY21wX3JxX3Bvcyk7CgoJaWYgKGNvdW50"
    "KSB7CgkJLyogV2UncmUgc3VyZSB0aGF0IGV2ZXJ5IHJlcXVlc3QncyByZC0+bWFuYWdlZCA9PSB0cnVlICovCgkJdW5pb24gYWRpb3NfaW5fZmxpZ2h0X3Jx"
    "cyBpZnIgPSB7CgkJCS5jb3VudCAgICAgICAgICA9IGNvdW50LAoJCQkudG90YWxfcHJlZF9sYXQgPSBhZGRlZF9sYXQsCgkJfTsKCQlhdG9taWM2NF9hZGQo"
    "aWZyLnNjYWxhciwgJmFkLT5pbl9mbGlnaHRfcnFzLmF0b21pYyk7CgoJCXNldF9hZGlvc19zdGF0ZShhZCwgQURJT1NfU1RBVEVfQlEsIHBhZ2UsIHRydWUp"
    "OwoKCQlmb3IgKG9wdHlwZSA9IDA7IG9wdHlwZSA8IEFESU9TX09QVFlQRVM7IG9wdHlwZSsrKQoJCQlpZiAoYWQtPmJhdGNoX2FjdHVhbF9tYXhfc2l6ZVtv"
    "cHR5cGVdIDwgb3B0eXBlX2NvdW50W29wdHlwZV0pCgkJCQlhZC0+YmF0Y2hfYWN0dWFsX21heF9zaXplW29wdHlwZV0gPSBvcHR5cGVfY291bnRbb3B0eXBl"
    "XTsKCQlpZiAoYWQtPmJhdGNoX2FjdHVhbF9tYXhfdG90YWwgPCBjb3VudCkKCQkJYWQtPmJhdGNoX2FjdHVhbF9tYXhfdG90YWwgPSBjb3VudDsKCX0KCXJl"
    "dHVybiBjb3VudDsKfQoKLy8gRmxpcCB0byB0aGUgbmV4dCBiYXRjaCBxdWV1ZSBwYWdlCnN0YXRpYyB2b2lkIGZsaXBfYnFfcGFnZShzdHJ1Y3QgYWRpb3Nf"
    "ZGF0YSAqYWQpIHsKCWFkLT5icV9wYWdlID0gIWFkLT5icV9wYWdlOwoJdXBkYXRlX2Vsdl9kaXJlY3Rpb24oYWQpOwp9CgovLyBQb3AgYSByZXF1ZXN0IGZy"
    "b20gdGhlIHNwZWNpZmllZCBpbmRleCAob3B0eXBlIG9yIGVsZXZhdG9yIHRpZXIpCnN0YXRpYyBpbmxpbmUgc3RydWN0IHJlcXVlc3QgKnBvcF9icV9yZXF1"
    "ZXN0KAoJCXN0cnVjdCBhZGlvc19kYXRhICphZCwgdTggaWR4LCBib29sIGRpcmVjdGlvbikgewoJYm9vbCBwYWdlID0gYWQtPmJxX3BhZ2U7CglzdHJ1Y3Qg"
    "bGlzdF9oZWFkICpxID0gJmFkLT5iYXRjaF9xdWV1ZVtwYWdlXVtpZHhdOwoJc3RydWN0IHJlcXVlc3QgKnJxID0gZGlyZWN0aW9uID8KCQlsaXN0X2xhc3Rf"
    "ZW50cnlfb3JfbnVsbCAocSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk6CgkJbGlzdF9maXJzdF9lbnRyeV9vcl9udWxsKHEsIHN0cnVjdCByZXF1ZXN0"
    "LCBxdWV1ZWxpc3QpOwoJaWYgKHJxKSB7CgkJbGlzdF9kZWxfaW5pdCgmcnEtPnF1ZXVlbGlzdCk7CgkJaWYgKGxpc3RfZW1wdHkocSkpCgkJCWFkLT5icV9z"
    "dGF0ZVtwYWdlXSAmPSB+KDFVIDw8IGlkeCk7Cgl9CglyZXR1cm4gcnE7Cn0KCnN0YXRpYyBzdHJ1Y3QgcmVxdWVzdCAqcG9wX25leHRfYnFfcmVxdWVzdF9v"
    "cHR5cGUoc3RydWN0IGFkaW9zX2RhdGEgKmFkKSB7Cgl1MzIgYnFfc3RhdGUgPSBhZC0+YnFfc3RhdGVbYWQtPmJxX3BhZ2VdOwoJaWYgKCFicV9zdGF0ZSkg"
    "cmV0dXJuIE5VTEw7CgoJc3RydWN0IHJlcXVlc3QgKnJxOwoJdTMyIGJxX2lkeCA9IF9fYnVpbHRpbl9jdHooYnFfc3RhdGUpOwoKCS8vIERpc3BhdGNoIGJh"
    "c2VkIG9uIG9wdHlwZSAoRklGTyB3aXRoaW4gZWFjaCkgb3Igc2luZ2xlLXF1ZXVlIGVsZXZhdG9yCglycSA9IHBvcF9icV9yZXF1ZXN0KGFkLCBicV9pZHgs"
    "IGZhbHNlKTsKCXJldHVybiBycTsKfQoKc3RhdGljIHN0cnVjdCByZXF1ZXN0ICpwb3BfbmV4dF9icV9yZXF1ZXN0X2VsZXZhdG9yKHN0cnVjdCBhZGlvc19k"
    "YXRhICphZCkgewoJdTMyIGJxX3N0YXRlID0gYWQtPmJxX3N0YXRlW2FkLT5icV9wYWdlXTsKCWlmICghYnFfc3RhdGUpIHJldHVybiBOVUxMOwoKCXN0cnVj"
    "dCByZXF1ZXN0ICpycTsKCXUzMiBicV9pZHggPSBfX2J1aWx0aW5fY3R6KGJxX3N0YXRlKTsKCWJvb2wgZGlyZWN0aW9uID0gKGJxX2lkeCA9PSAxKSAmIGFk"
    "LT5lbHZfZGlyZWN0aW9uOwoKCS8vIFRpZXItMiAoc3luYykgaXMgYWx3YXlzIGhpZ2ggcHJpb3JpdHkKCS8vIFRpZXItMyAoYXN5bmMpIHVzZXMgdGhlIHBy"
    "ZS1jYWxjdWxhdGVkIGVsZXZhdG9yIGRpcmVjdGlvbgoJcnEgPSBwb3BfYnFfcmVxdWVzdChhZCwgYnFfaWR4LCBkaXJlY3Rpb24pOwoKCS8qIElmIGJhdGNo"
    "IHF1ZXVlIGZvciB0aGUgc3luYyByZXF1ZXN0cyBqdXN0IGJlY2FtZSBlbXB0eSAqLwoJaWYgKGJxX2lkeCA9PSAwICYmIHJxICYmICEoYnFfc3RhdGUgJiAw"
    "eDEpKQoJCXVwZGF0ZV9lbHZfZGlyZWN0aW9uKGFkKTsKCglyZXR1cm4gcnE7Cn0KCi8vIFJldHVybnMgdGhlIHN0YXRlIG9mIHRoZSBiYXRjaCBxdWV1ZSBw"
    "YWdlCnN0YXRpYyBpbmxpbmUgYm9vbCBicV9wYWdlX2hhc19ycSh1MzIgYnFfc3RhdGUsIGJvb2wgcGFnZSkgewoJcmV0dXJuIGJxX3N0YXRlICYgKDFVIDw8"
    "IHBhZ2UpOwp9CgovLyBEaXNwYXRjaCBhIHJlcXVlc3QgZnJvbSB0aGUgYmF0Y2ggcXVldWVzCnN0YXRpYyBzdHJ1Y3QgcmVxdWVzdCAqZGlzcGF0Y2hfZnJv"
    "bV9icShzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQpIHsKCXN0cnVjdCByZXF1ZXN0ICpycTsKCglhZGlvc19ndWFyZChzcGlubG9ja19pcnFzYXZlKSgmYWQtPmJx"
    "X2xvY2spOwoKCXUzMiBzdGF0ZSA9IGdldF9hZGlvc19zdGF0ZShhZCk7Cgl1MzIgYnFfc3RhdGUgPSBldmFsX3RoaXNfYWRpb3Nfc3RhdGUoc3RhdGUsIEFE"
    "SU9TX1NUQVRFX0JRKTsKCXUzMiBicV9jdXJyX3BhZ2VfaGFzX3JxID0gYnFfcGFnZV9oYXNfcnEoYnFfc3RhdGUsIGFkLT5icV9wYWdlKTsKCXVuaW9uIGFk"
    "aW9zX2luX2ZsaWdodF9ycXMgaWZyOwoJaWZyLnNjYWxhciA9IGF0b21pYzY0X3JlYWQoJmFkLT5pbl9mbGlnaHRfcnFzLmF0b21pYyk7Cgl1NjQgdHBsID0g"
    "aWZyLnRvdGFsX3ByZWRfbGF0OwoKCS8vIFJlZmlsbCB0aGUgYmF0Y2ggcXVldWVzIGlmIHRoZSBiYWNrIHBhZ2UgaXMgZW1wdHksIGRsX3RyZWUgaGFzIHdv"
    "cmssIGFuZAoJLy8gY3VycmVudCBwYWdlIGlzIGVtcHR5IG9yIHRoZSB0b3RhbCBvbmdvaW5nIGxhdGVuY3kgaXMgYmVsb3cgdGhlIHRocmVzaG9sZAoJaWYg"
    "KCFicV9wYWdlX2hhc19ycShicV9zdGF0ZSwgIWFkLT5icV9wYWdlKSAmJgoJCQkoIWJxX2N1cnJfcGFnZV9oYXNfcnEgfHwgKCF0cGwgfHwgdHBsIDwgZGl2"
    "X3U2NCgKCQkJYWQtPmdsb2JhbF9sYXRlbmN5X3dpbmRvdyAqIGFkLT5icV9yZWZpbGxfYmVsb3dfcmF0aW8sIDEwMCkpKSAmJgoJCQlldmFsX3RoaXNfYWRp"
    "b3Nfc3RhdGUoc3RhdGUsIEFESU9TX1NUQVRFX0RMKSkKCQlmaWxsX2JhdGNoX3F1ZXVlcyhhZCwgdHBsKTsKCgkvLyBJZiBjdXJyZW50IGJhdGNoIHF1ZXVl"
    "IHBhZ2UgaXMgZW1wdHksIGFuZCB0aGUgb3RoZXIgcGFnZSBoYXMgd29yaywgZmxpcAoJaWYgKCFicV9jdXJyX3BhZ2VfaGFzX3JxICYmCgkJCWJxX3BhZ2Vf"
    "aGFzX3JxKGV2YWxfYWRpb3Nfc3RhdGUoYWQsIEFESU9TX1NUQVRFX0JRKSwgIWFkLT5icV9wYWdlKSkKCQlmbGlwX2JxX3BhZ2UoYWQpOwoKCS8vIFVzZSB0"
    "aGUgcGVyLXBhZ2Ugc3RhdGUgdG8gZGVjaWRlIHRoZSBkaXNwYXRjaCBsb2dpYywgZW5zdXJpbmcgY29ycmVjdG5lc3MKCXJxID0gKGFkLT5icV9iYXRjaF9v"
    "cmRlclthZC0+YnFfcGFnZV0gPT0gQURJT1NfQk9fRUxFVkFUT1IpID8KCQlwb3BfbmV4dF9icV9yZXF1ZXN0X2VsZXZhdG9yKGFkKToKCQlwb3BfbmV4dF9i"
    "cV9yZXF1ZXN0X29wdHlwZShhZCk7CgoJaWYgKHJxKSB7CgkJYm9vbCBwYWdlID0gYWQtPmJxX3BhZ2U7CgkJYm9vbCBpc19lbXB0eSA9ICFhZC0+YnFfc3Rh"
    "dGVbcGFnZV07CgkJaWYgKGlzX2VtcHR5KQoJCQlzZXRfYWRpb3Nfc3RhdGUoYWQsIEFESU9TX1NUQVRFX0JRLCBwYWdlLCBmYWxzZSk7CgkJcmV0dXJuIHJx"
    "OwoJfQoKCXJldHVybiBOVUxMOwp9CgovLyBEaXNwYXRjaCBhIHJlcXVlc3QgZnJvbSB0aGUgcHJpb3JpdHkgcXVldWUKc3RhdGljIHN0cnVjdCByZXF1ZXN0"
    "ICpkaXNwYXRjaF9mcm9tX3BxKHN0cnVjdCBhZGlvc19kYXRhICphZCkgewoJc3RydWN0IHJlcXVlc3QgKnJxID0gTlVMTDsKCglhZGlvc19ndWFyZChzcGlu"
    "bG9ja19pcnFzYXZlKSgmYWQtPnBxX2xvY2spOwoJdTMyIHBxX3N0YXRlID0gZXZhbF9hZGlvc19zdGF0ZShhZCwgQURJT1NfU1RBVEVfUFEpOwoJdTggIHBx"
    "X2lkeCA9IHBxX3N0YXRlID4+IDE7CglzdHJ1Y3QgbGlzdF9oZWFkICpxID0gJmFkLT5wcmlvX3F1ZXVlW3BxX2lkeF07CgoJaWYgKHVubGlrZWx5KGxpc3Rf"
    "ZW1wdHkocSkpKSByZXR1cm4gTlVMTDsKCglycSA9IGxpc3RfZmlyc3RfZW50cnkocSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7CglsaXN0X2RlbF9p"
    "bml0KCZycS0+cXVldWVsaXN0KTsKCWlmIChsaXN0X2VtcHR5KHEpKSB7CgkJc2V0X2FkaW9zX3N0YXRlKGFkLCBBRElPU19TVEFURV9QUSwgcHFfaWR4LCBm"
    "YWxzZSk7CgkJdXBkYXRlX2Vsdl9kaXJlY3Rpb24oYWQpOwoJfQoJcmV0dXJuIHJxOwp9CgoKLy8gRGlzcGF0Y2ggYSByZXF1ZXN0IHRvIHRoZSBoYXJkd2Fy"
    "ZSBxdWV1ZQpzdGF0aWMgc3RydWN0IHJlcXVlc3QgKmFkaW9zX2Rpc3BhdGNoX3JlcXVlc3Qoc3RydWN0IGJsa19tcV9od19jdHggKmhjdHgpIHsKCXN0cnVj"
    "dCBhZGlvc19kYXRhICphZCA9IGhjdHgtPnF1ZXVlLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCByZXF1ZXN0ICpycTsKCglycSA9IGRpc3Bh"
    "dGNoX2Zyb21fcHEoYWQpOwoJaWYgKHJxKQoJCWdvdG8gZm91bmQ7CgoJcnEgPSBkaXNwYXRjaF9mcm9tX2JxKGFkKTsKCWlmIChycSkKCQlnb3RvIGZvdW5k"
    "OwoKCXJldHVybiBOVUxMOwpmb3VuZDoKCWlmIChhZC0+aXNfcm90YXRpb25hbCkKCQlhZC0+aGVhZF9wb3MgPSBibGtfcnFfcG9zKHJxKSArIGJsa19ycV9z"
    "ZWN0b3JzKHJxKTsKCglycS0+cnFfZmxhZ3MgfD0gUlFGX1NUQVJURUQ7CglyZXR1cm4gcnE7Cn0KCi8vIFRpbWVyIGNhbGxiYWNrIGZ1bmN0aW9uIHRvIHBl"
    "cmlvZGljYWxseSB1cGRhdGUgbGF0ZW5jeSBtb2RlbHMKc3RhdGljIHZvaWQgdXBkYXRlX3RpbWVyX2NhbGxiYWNrKHN0cnVjdCB0aW1lcl9saXN0ICp0KSB7"
    "CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBmcm9tX3RpbWVyKGFkLCB0LCB1cGRhdGVfdGltZXIpOwoKCWZvciAodTggb3B0eXBlID0gMDsgb3B0eXBlIDwg"
    "QURJT1NfT1BUWVBFUzsgb3B0eXBlKyspCgkJbGF0ZW5jeV9tb2RlbF91cGRhdGUoYWQsICZhZC0+bGF0ZW5jeV9tb2RlbFtvcHR5cGVdKTsKfQoKLy8gSGFu"
    "ZGxlIHRoZSBjb21wbGV0aW9uIG9mIGEgcmVxdWVzdApzdGF0aWMgdm9pZCBhZGlvc19jb21wbGV0ZWRfcmVxdWVzdChzdHJ1Y3QgcmVxdWVzdCAqcnEsIHU2"
    "NCBub3cpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IHJxLT5xLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpy"
    "ZCA9IGdldF9ycV9kYXRhKHJxKTsKCXVuaW9uIGFkaW9zX2luX2ZsaWdodF9ycXMgaWZyID0geyAuc2NhbGFyID0gMCB9OwoKCWlmIChyZC0+bWFuYWdlZCkg"
    "ewoJCXVuaW9uIGFkaW9zX2luX2ZsaWdodF9ycXMgaWZyX3RvX3N1YiA9IHsKCQkJLmNvdW50ICAgICAgICAgID0gMSwKCQkJLnRvdGFsX3ByZWRfbGF0ID0g"
    "cmQtPnByZWRfbGF0LAoJCX07CgkJaWZyLnNjYWxhciA9IGF0b21pYzY0X3N1Yl9yZXR1cm4oCgkJCWlmcl90b19zdWIuc2NhbGFyLCAmYWQtPmluX2ZsaWdo"
    "dF9ycXMuYXRvbWljKTsKCX0KCXU4IG9wdHlwZSA9IGFkaW9zX29wdHlwZShycSk7CgoJdW5zaWduZWQgbG9uZyBmbGFnczsKCXN0cnVjdCBhZGlvc19wY3B1"
    "X2NvbXBsZXRpb24gKnBjOwoKCWxvY2FsX2lycV9zYXZlKGZsYWdzKTsKCXBjID0gdGhpc19jcHVfcHRyKGFkLT5wY3B1X2NvbXBsZXRpb24pOwoKCWlmIChv"
    "cHR5cGUgPT0gQURJT1NfT1RIRVIpIHsKCQkvLyBOb24tcG9zaXRpb25hbCBjb21tYW5kcyBtYWtlIHRoZSBoZWFkIHBvc2l0aW9uIHVucHJlZGljdGFibGUu"
    "CgkJLy8gSW52YWxpZGF0ZSBvdXIga25vd2xlZGdlIG9mIHRoZSBsYXN0IGNvbXBsZXRlZCBwb3NpdGlvbi4KCQlpZiAoYWQtPmlzX3JvdGF0aW9uYWwpCgkJ"
    "CXBjLT5sYXN0X2NvbXBsZXRlZF9wb3MgPSAwOwoJCWxvY2FsX2lycV9yZXN0b3JlKGZsYWdzKTsKCQlyZXR1cm47Cgl9CgoJdTY0IGxjdCA9IHBjLT5sYXN0"
    "X2NvbXBsZXRlZF90aW1lID86IHJxLT5pb19zdGFydF90aW1lX25zOwoJcGMtPmxhc3RfY29tcGxldGVkX3RpbWUgPSAoaWZyLmNvdW50KSA/IG5vdyA6IDA7"
    "CgoJaWYgKCFycS0+aW9fc3RhcnRfdGltZV9ucyB8fCAhcmQtPmJsb2NrX3NpemUgfHwgdW5saWtlbHkobm93IDwgbGN0KSkgewoJCWxvY2FsX2lycV9yZXN0"
    "b3JlKGZsYWdzKTsKCQlyZXR1cm47Cgl9CgoJdTY0IGxhdGVuY3kgPSBub3cgLSBsY3Q7CgoJdTMyIHdlaWdodCA9IDE7CglpZiAoYWQtPmlzX3JvdGF0aW9u"
    "YWwpIHsKCQlzZWN0b3JfdCBjdXJyZW50X3BvcyA9IGJsa19ycV9wb3MocnEpOwoJCS8vIE9ubHkgY2FsY3VsYXRlIHNlZWsgZGlzdGFuY2UgaWYgd2UgaGF2"
    "ZSBhIHZhbGlkIGxhc3QgcG9zaXRpb24uCgkJaWYgKHBjLT5sYXN0X2NvbXBsZXRlZF9wb3MgPiAwKSB7CgkJCXU2NCBzZWVrX2Rpc3RhbmNlID0gYWJzKAoJ"
    "CQkJKHM2NCljdXJyZW50X3BvcyAtIChzNjQpcGMtPmxhc3RfY29tcGxldGVkX3Bvcyk7CgkJCWlmIChzZWVrX2Rpc3RhbmNlKQoJCQkJd2VpZ2h0ID0gNjUg"
    "LSBfX2J1aWx0aW5fY2x6bGwoc2Vla19kaXN0YW5jZSk7CgkJfQoJCS8vIFVwZGF0ZSAob3IgcmUtc3luY2hyb25pemUpIG91ciBrbm93bGVkZ2Ugb2YgdGhl"
    "IGhlYWQgcG9zaXRpb24uCgkJcGMtPmxhc3RfY29tcGxldGVkX3BvcyA9IGN1cnJlbnRfcG9zICsgYmxrX3JxX3NlY3RvcnMocnEpOwoJfQoKCWxvY2FsX2ly"
    "cV9yZXN0b3JlKGZsYWdzKTsKCglpZiAobGF0ZW5jeSA+IGFkLT5sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCkKCQlyZXR1cm47CgoJbGF0ZW5jeV9tb2RlbF9p"
    "bnB1dChhZCwgJmFkLT5sYXRlbmN5X21vZGVsW29wdHlwZV0sCgkJcmQtPmJsb2NrX3NpemUsIGxhdGVuY3ksIHJkLT5wcmVkX2xhdCwgd2VpZ2h0KTsKCXRp"
    "bWVyX3JlZHVjZSgmYWQtPnVwZGF0ZV90aW1lciwgamlmZmllcyArIG1zZWNzX3RvX2ppZmZpZXMoMTAwKSk7Cn0KCi8vIENsZWFuIHVwIGFmdGVyIGEgcmVx"
    "dWVzdCBpcyBmaW5pc2hlZApzdGF0aWMgdm9pZCBhZGlvc19maW5pc2hfcmVxdWVzdChzdHJ1Y3QgcmVxdWVzdCAqcnEpIHsKCXN0cnVjdCBhZGlvc19kYXRh"
    "ICphZCA9IHJxLT5xLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCglpZiAocnEtPmVsdi5wcml2WzBdKSB7CgkJLy8gRnJlZSBhZGlvc19ycV9kYXRhIGJh"
    "Y2sgdG8gdGhlIG1lbW9yeSBwb29sCgkJbWVtcG9vbF9mcmVlKGdldF9ycV9kYXRhKHJxKSwgYWQtPnJxX2RhdGFfcG9vbCk7CgkJcnEtPmVsdi5wcml2WzBd"
    "ID0gTlVMTDsKCX0KfQoKLy8gQ2hlY2sgaWYgdGhlcmUgYXJlIGFueSByZXF1ZXN0cyBhdmFpbGFibGUgZm9yIGRpc3BhdGNoCnN0YXRpYyBib29sIGFkaW9z"
    "X2hhc193b3JrKHN0cnVjdCBibGtfbXFfaHdfY3R4ICpoY3R4KSB7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBoY3R4LT5xdWV1ZS0+ZWxldmF0b3ItPmVs"
    "ZXZhdG9yX2RhdGE7CgoJcmV0dXJuIGF0b21pY19yZWFkKCZhZC0+c3RhdGUpICE9IDA7Cn0KCi8vIEluaXRpYWxpemUgdGhlIHNjaGVkdWxlci1zcGVjaWZp"
    "YyBkYXRhIGZvciBhIGhhcmR3YXJlIHF1ZXVlCnN0YXRpYyBpbnQgYWRpb3NfaW5pdF9oY3R4KHN0cnVjdCBibGtfbXFfaHdfY3R4ICpoY3R4LCB1bnNpZ25l"
    "ZCBpbnQgaGN0eF9pZHgpIHsKCWFkaW9zX2RlcHRoX3VwZGF0ZWQoaGN0eCk7CglyZXR1cm4gMDsKfQoKLy8gSW5pdGlhbGl6ZSB0aGUgc2NoZWR1bGVyLXNw"
    "ZWNpZmljIGRhdGEgd2hlbiBpbml0aWFsaXppbmcgdGhlIHJlcXVlc3QgcXVldWUKc3RhdGljIGludCBhZGlvc19pbml0X3NjaGVkKHN0cnVjdCByZXF1ZXN0"
    "X3F1ZXVlICpxLCBzdHJ1Y3QgZWxldmF0b3JfdHlwZSAqZSkgewoJc3RydWN0IGFkaW9zX2RhdGEgKmFkOwoJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplcTsK"
    "CWludCByZXQgPSAtRU5PTUVNOwoJdTggb3B0eXBlID0gMDsKCgllcSA9IGVsZXZhdG9yX2FsbG9jKHEsIGUpOwoJaWYgKCFlcSkgewoJCXByX2VycigiYWRp"
    "b3M6IEZhaWxlZCB0byBhbGxvY2F0ZSB0aGUgZWxldmF0b3JcbiIpOwoJCXJldHVybiByZXQ7Cgl9CgoJYWQgPSBremFsbG9jX25vZGUoc2l6ZW9mKCphZCks"
    "IEdGUF9LRVJORUwsIHEtPm5vZGUpOwoJaWYgKCFhZCkgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBjcmVhdGUgYWRpb3NfZGF0YVxuIik7CgkJZ290"
    "byBwdXRfZXE7Cgl9CgoJLy8gQ3JlYXRlIGEgbWVtb3J5IHBvb2wgZm9yIGFkaW9zX3JxX2RhdGEKCWFkLT5ycV9kYXRhX2NhY2hlID0ga21lbV9jYWNoZV9j"
    "cmVhdGUoImFkaW9zX3JxX2RhdGEiLAoJCQkJCQlzaXplb2Yoc3RydWN0IGFkaW9zX3JxX2RhdGEpLAoJCQkJCQkwLCBTTEFCX0hXQ0FDSEVfQUxJR04sIE5V"
    "TEwpOwoJaWYgKCFhZC0+cnFfZGF0YV9jYWNoZSkgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBjcmVhdGUgcnFfZGF0YV9jYWNoZVxuIik7CgkJZ290"
    "byBmcmVlX2FkOwoJfQoKCWFkLT5ycV9kYXRhX3Bvb2wgPSBtZW1wb29sX2NyZWF0ZV9zbGFiX3Bvb2woCgkJCQkJCXEtPm5yX3JlcXVlc3RzLCBhZC0+cnFf"
    "ZGF0YV9jYWNoZSk7CglpZiAoIWFkLT5ycV9kYXRhX3Bvb2wpIHsKCQlwcl9lcnIoImFkaW9zOiBGYWlsZWQgdG8gY3JlYXRlIHJxX2RhdGFfcG9vbFxuIik7"
    "CgkJZ290byBkZXN0cm95X3JxX2RhdGFfY2FjaGU7Cgl9CgoJLyogQ3JlYXRlIGEgbWVtb3J5IHBvb2wgZm9yIGRsX2dyb3VwICovCglhZC0+ZGxfZ3JvdXBf"
    "cG9vbCA9IGttZW1fY2FjaGVfY3JlYXRlKCJkbF9ncm91cF9wb29sIiwKCQkJCQkJc2l6ZW9mKHN0cnVjdCBkbF9ncm91cCksCgkJCQkJCTAsIFNMQUJfSFdD"
    "QUNIRV9BTElHTiwgTlVMTCk7CglpZiAoIWFkLT5kbF9ncm91cF9wb29sKSB7CgkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGNyZWF0ZSBkbF9ncm91cF9w"
    "b29sXG4iKTsKCQlnb3RvIGRlc3Ryb3lfcnFfZGF0YV9wb29sOwoJfQoKCWZvciAoaW50IGkgPSAwOyBpIDwgQURJT1NfUFFfTEVWRUxTOyBpKyspCgkJSU5J"
    "VF9MSVNUX0hFQUQoJmFkLT5wcmlvX3F1ZXVlW2ldKTsKCglmb3IgKHU4IGkgPSAwOyBpIDwgQURJT1NfRExfVFlQRVM7IGkrKykgewoJCWFkLT5kbF90cmVl"
    "W2ldID0gUkJfUk9PVF9DQUNIRUQ7CgkJYWQtPmRsX3ByaW9baV0gPSBkZWZhdWx0X2RsX3ByaW9baV07Cgl9CglhZC0+ZGxfYmlhcyA9IDA7CgoJZm9yICh1"
    "OCBwYWdlID0gMDsgcGFnZSA8IEFESU9TX0JRX1BBR0VTOyBwYWdlKyspCgkJZm9yIChvcHR5cGUgPSAwOyBvcHR5cGUgPCBBRElPU19PUFRZUEVTOyBvcHR5"
    "cGUrKykKCQkJSU5JVF9MSVNUX0hFQUQoJmFkLT5iYXRjaF9xdWV1ZVtwYWdlXVtvcHR5cGVdKTsKCglhZC0+YWdncl9idWNrZXRzID0ga3phbGxvYyhzaXpl"
    "b2YoKmFkLT5hZ2dyX2J1Y2tldHMpLCBHRlBfS0VSTkVMKTsKCWlmICghYWQtPmFnZ3JfYnVja2V0cykgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBh"
    "bGxvY2F0ZSBhZ2dyZWdhdGlvbiBidWNrZXRzXG4iKTsKCQlnb3RvIGRlc3Ryb3lfZGxfZ3JvdXBfcG9vbDsKCX0KCglhZC0+cGNwdV9jb21wbGV0aW9uID0g"
    "YWxsb2NfcGVyY3B1KHN0cnVjdCBhZGlvc19wY3B1X2NvbXBsZXRpb24pOwoJaWYgKCFhZC0+cGNwdV9jb21wbGV0aW9uKSB7CgkJcHJfZXJyKCJhZGlvczog"
    "RmFpbGVkIHRvIGFsbG9jYXRlIHBlci1DUFUgY29tcGxldGlvbiBkYXRhXG4iKTsKCQlnb3RvIGZyZWVfYWdncl9idWNrZXRzOwoJfQoKCWZvciAob3B0eXBl"
    "ID0gMDsgb3B0eXBlIDwgQURJT1NfT1BUWVBFUzsgb3B0eXBlKyspIHsKCQlzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9k"
    "ZWxbb3B0eXBlXTsKCQlzdHJ1Y3QgbGF0ZW5jeV9tb2RlbF9wYXJhbXMgKnBhcmFtczsKCgkJc3Bpbl9sb2NrX2luaXQoJm1vZGVsLT51cGRhdGVfbG9jayk7"
    "CgkJcGFyYW1zID0ga3phbGxvYyhzaXplb2YoKnBhcmFtcyksIEdGUF9LRVJORUwpOwoJCWlmICghcGFyYW1zKSB7CgkJCXByX2VycigiYWRpb3M6IEZhaWxl"
    "ZCB0byBhbGxvY2F0ZSBsYXRlbmN5X21vZGVsX3BhcmFtc1xuIik7CgkJCWdvdG8gZnJlZV9idWNrZXRzOwoJCX0KCQlwYXJhbXMtPmxhc3RfdXBkYXRlX2pp"
    "ZmZpZXMgPSBqaWZmaWVzOwoJCVJDVV9JTklUX1BPSU5URVIobW9kZWwtPnBhcmFtcywgcGFyYW1zKTsKCgkJbW9kZWwtPnBjcHVfYnVja2V0cyA9IGFsbG9j"
    "X3BlcmNwdShzdHJ1Y3QgbG1fYnVja2V0cyk7CgkJaWYgKCFtb2RlbC0+cGNwdV9idWNrZXRzKSB7CgkJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBhbGxv"
    "Y2F0ZSBwZXItQ1BVIGJ1Y2tldHNcbiIpOwoJCQlrZnJlZShwYXJhbXMpOwoJCQlnb3RvIGZyZWVfYnVja2V0czsKCQl9CgoJCW1vZGVsLT5wY3B1X3NuYXBz"
    "aG90ID0gYWxsb2NfcGVyY3B1KHN0cnVjdCBsbV9idWNrZXRzKTsKCQlpZiAoIW1vZGVsLT5wY3B1X3NuYXBzaG90KSB7CgkJCXByX2VycigiYWRpb3M6IEZh"
    "aWxlZCB0byBhbGxvY2F0ZSBwZXItQ1BVIHNuYXBzaG90XG4iKTsKCQkJZnJlZV9wZXJjcHUobW9kZWwtPnBjcHVfYnVja2V0cyk7CgkJCWtmcmVlKHBhcmFt"
    "cyk7CgkJCWdvdG8gZnJlZV9idWNrZXRzOwoJCX0KCgkJbW9kZWwtPmxtX3Nocmlua19hdF9rcmVxcyAgPSBkZWZhdWx0X2xtX3Nocmlua19hdF9rcmVxczsK"
    "CQltb2RlbC0+bG1fc2hyaW5rX2F0X2dieXRlcyA9IGRlZmF1bHRfbG1fc2hyaW5rX2F0X2dieXRlczsKCQltb2RlbC0+bG1fc2hyaW5rX3Jlc2lzdCAgICA9"
    "IGRlZmF1bHRfbG1fc2hyaW5rX3Jlc2lzdDsKCX0KCglmb3IgKG9wdHlwZSA9IDA7IG9wdHlwZSA8IEFESU9TX09QVFlQRVM7IG9wdHlwZSsrKSB7CgkJYWQt"
    "PmxhdGVuY3lfdGFyZ2V0W29wdHlwZV0gPSBkZWZhdWx0X2xhdGVuY3lfdGFyZ2V0W29wdHlwZV07CgkJYWQtPmJhdGNoX2xpbWl0W29wdHlwZV0gPSBkZWZh"
    "dWx0X2JhdGNoX2xpbWl0W29wdHlwZV07Cgl9CgoJZXEtPmVsZXZhdG9yX2RhdGEgPSBhZDsKCglhZC0+aXNfcm90YXRpb25hbCA9ICEhKHEtPmxpbWl0cy5m"
    "ZWF0dXJlcyAmIEJMS19GRUFUX1JPVEFUSU9OQUwpOwoJYWQtPmdsb2JhbF9sYXRlbmN5X3dpbmRvdyA9IChhZC0+aXNfcm90YXRpb25hbCk/CgkJZGVmYXVs"
    "dF9nbG9iYWxfbGF0ZW5jeV93aW5kb3dfcm90YXRpb25hbDoKCQlkZWZhdWx0X2dsb2JhbF9sYXRlbmN5X3dpbmRvdzsKCWFkLT5icV9yZWZpbGxfYmVsb3df"
    "cmF0aW8gPSBkZWZhdWx0X2JxX3JlZmlsbF9iZWxvd19yYXRpbzsKCWFkLT5sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCA9IGRlZmF1bHRfbGF0X21vZGVsX2xh"
    "dGVuY3lfbGltaXQ7CglhZC0+YmF0Y2hfb3JkZXIgPSBkZWZhdWx0X2JhdGNoX29yZGVyOwoJYWQtPmNvbXBsaWFuY2VfZmxhZ3MgPSBkZWZhdWx0X2NvbXBs"
    "aWFuY2VfZmxhZ3M7CgoJYWQtPm1vZGVsc19zdGFibGUgPSBmYWxzZTsKCglhdG9taWNfc2V0KCZhZC0+c3RhdGUsIDApOwoKCXNwaW5fbG9ja19pbml0KCZh"
    "ZC0+bG9jayk7CglzcGluX2xvY2tfaW5pdCgmYWQtPnBxX2xvY2spOwoJc3Bpbl9sb2NrX2luaXQoJmFkLT5icV9sb2NrKTsKCgl0aW1lcl9zZXR1cCgmYWQt"
    "PnVwZGF0ZV90aW1lciwgdXBkYXRlX3RpbWVyX2NhbGxiYWNrLCAwKTsKCgkvKiBXZSBkaXNwYXRjaCBmcm9tIHJlcXVlc3QgcXVldWUgd2lkZSBpbnN0ZWFk"
    "IG9mIGh3IHF1ZXVlICovCglibGtfcXVldWVfZmxhZ19zZXQoUVVFVUVfRkxBR19TUV9TQ0hFRCwgcSk7CgoJYWQtPnF1ZXVlID0gcTsKCWJsa19zdGF0X2Vu"
    "YWJsZV9hY2NvdW50aW5nKHEpOwoKCXEtPmVsZXZhdG9yID0gZXE7CglyZXR1cm4gMDsKCmZyZWVfYnVja2V0czoKCXByX2VycigiYWRpb3M6IEZhaWxlZCB0"
    "byBhbGxvY2F0ZSBwZXItY3B1IGJ1Y2tldHNcbiIpOwoJd2hpbGUgKG9wdHlwZS0tID4gMCkgewoJCXN0cnVjdCBsYXRlbmN5X21vZGVsICpwcmV2X21vZGVs"
    "ID0gJmFkLT5sYXRlbmN5X21vZGVsW29wdHlwZV07CgkJa2ZyZWUocmN1X2FjY2Vzc19wb2ludGVyKHByZXZfbW9kZWwtPnBhcmFtcykpOwoJCWZyZWVfcGVy"
    "Y3B1KHByZXZfbW9kZWwtPnBjcHVfc25hcHNob3QpOwoJCWZyZWVfcGVyY3B1KHByZXZfbW9kZWwtPnBjcHVfYnVja2V0cyk7Cgl9CglmcmVlX3BlcmNwdShh"
    "ZC0+cGNwdV9jb21wbGV0aW9uKTsKZnJlZV9hZ2dyX2J1Y2tldHM6CglrZnJlZShhZC0+YWdncl9idWNrZXRzKTsKZGVzdHJveV9kbF9ncm91cF9wb29sOgoJ"
    "a21lbV9jYWNoZV9kZXN0cm95KGFkLT5kbF9ncm91cF9wb29sKTsKZGVzdHJveV9ycV9kYXRhX3Bvb2w6CgltZW1wb29sX2Rlc3Ryb3koYWQtPnJxX2RhdGFf"
    "cG9vbCk7CmRlc3Ryb3lfcnFfZGF0YV9jYWNoZToKCWttZW1fY2FjaGVfZGVzdHJveShhZC0+cnFfZGF0YV9jYWNoZSk7CmZyZWVfYWQ6CglrZnJlZShhZCk7"
    "CnB1dF9lcToKCWtvYmplY3RfcHV0KCZlcS0+a29iaik7CglyZXR1cm4gcmV0Owp9CgovLyBDbGVhbiB1cCBhbmQgZnJlZSByZXNvdXJjZXMgd2hlbiBleGl0"
    "aW5nIHRoZSBzY2hlZHVsZXIKc3RhdGljIHZvaWQgYWRpb3NfZXhpdF9zY2hlZChzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUpIHsKCXN0cnVjdCBhZGlvc19k"
    "YXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7CgoJdGltZXJfc2h1dGRvd25fc3luYygmYWQtPnVwZGF0ZV90aW1lcik7CgoJZm9yIChpbnQgaSA9IDA7IGkg"
    "PCAyOyBpKyspCgkJV0FSTl9PTl9PTkNFKCFsaXN0X2VtcHR5KCZhZC0+cHJpb19xdWV1ZVtpXSkpOwoKCWZvciAodTggaSA9IDA7IGkgPCBBRElPU19PUFRZ"
    "UEVTOyBpKyspIHsKCQlzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbaV07CgkJc3RydWN0IGxhdGVuY3lfbW9kZWxf"
    "cGFyYW1zICpwYXJhbXMgPSByY3VfYWNjZXNzX3BvaW50ZXIobW9kZWwtPnBhcmFtcyk7CgoJCVJDVV9JTklUX1BPSU5URVIobW9kZWwtPnBhcmFtcywgTlVM"
    "TCk7CgkJa2ZyZWVfcmN1KHBhcmFtcywgcmN1KTsKCgkJZnJlZV9wZXJjcHUobW9kZWwtPnBjcHVfc25hcHNob3QpOwoJCWZyZWVfcGVyY3B1KG1vZGVsLT5w"
    "Y3B1X2J1Y2tldHMpOwoJfQoKCXN5bmNocm9uaXplX3JjdSgpOwoKCWZyZWVfcGVyY3B1KGFkLT5wY3B1X2NvbXBsZXRpb24pOwoJa2ZyZWUoYWQtPmFnZ3Jf"
    "YnVja2V0cyk7CgoJbWVtcG9vbF9kZXN0cm95KGFkLT5ycV9kYXRhX3Bvb2wpOwoJa21lbV9jYWNoZV9kZXN0cm95KGFkLT5ycV9kYXRhX2NhY2hlKTsKCglp"
    "ZiAoYWQtPmRsX2dyb3VwX3Bvb2wpCgkJa21lbV9jYWNoZV9kZXN0cm95KGFkLT5kbF9ncm91cF9wb29sKTsKCglibGtfc3RhdF9kaXNhYmxlX2FjY291bnRp"
    "bmcoYWQtPnF1ZXVlKTsKCglrZnJlZShhZCk7Cn0KCnN0YXRpYyB2b2lkIHNpZGVsb2FkX2xhdGVuY3lfbW9kZWwoCgkJc3RydWN0IGxhdGVuY3lfbW9kZWwg"
    "Km1vZGVsLCB1NjQgYmFzZSwgdTY0IHNsb3BlKSB7CglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbF9wYXJhbXMgKm9sZF9wYXJhbXMsICpuZXdfcGFyYW1zOwoJdW5z"
    "aWduZWQgbG9uZyBmbGFnczsKCgluZXdfcGFyYW1zID0ga3phbGxvYyhzaXplb2YoKm5ld19wYXJhbXMpLCBHRlBfS0VSTkVMKTsKCWlmICghbmV3X3BhcmFt"
    "cykKCQlyZXR1cm47CgoJc3Bpbl9sb2NrX2lycXNhdmUoJm1vZGVsLT51cGRhdGVfbG9jaywgZmxhZ3MpOwoKCW9sZF9wYXJhbXMgPSByY3VfZGVyZWZlcmVu"
    "Y2VfcHJvdGVjdGVkKG1vZGVsLT5wYXJhbXMsCgkJCWxvY2tkZXBfaXNfaGVsZCgmbW9kZWwtPnVwZGF0ZV9sb2NrKSk7CgoJbmV3X3BhcmFtcy0+bGFzdF91"
    "cGRhdGVfamlmZmllcyA9IGppZmZpZXM7CgoJLy8gSW5pdGlhbGl6ZSBiYXNlIGFuZCBpdHMgc3RhdGlzdGljcyBhcyBhIHNpbmdsZSBzYW1wbGUuCgluZXdf"
    "cGFyYW1zLT5iYXNlID0gYmFzZTsKCW5ld19wYXJhbXMtPnNtYWxsX3N1bV9kZWxheSA9IGJhc2U7CgluZXdfcGFyYW1zLT5zbWFsbF9jb3VudCA9IDE7CgoJ"
    "Ly8gSW5pdGlhbGl6ZSBzbG9wZSBhbmQgaXRzIHN0YXRpc3RpY3MgYXMgYSBzaW5nbGUgc2FtcGxlLgoJbmV3X3BhcmFtcy0+c2xvcGUgPSBzbG9wZTsKCW5l"
    "d19wYXJhbXMtPmxhcmdlX3N1bV9kZWxheSA9IHNsb3BlOwoJbmV3X3BhcmFtcy0+bGFyZ2Vfc3VtX2JzaXplID0gMTAyNDsgLyogQ29ycmVzcG9uZHMgdG8g"
    "MSBLaUIgKi8KCglsbV9yZXNldF9wY3B1X2J1Y2tldHMobW9kZWwpOwoKCXJjdV9hc3NpZ25fcG9pbnRlcihtb2RlbC0+cGFyYW1zLCBuZXdfcGFyYW1zKTsK"
    "CXNwaW5fdW5sb2NrX2lycXJlc3RvcmUoJm1vZGVsLT51cGRhdGVfbG9jaywgZmxhZ3MpOwoKCWtmcmVlX3JjdShvbGRfcGFyYW1zLCByY3UpOwp9CgovLyBE"
    "ZWZpbmUgc3lzZnMgYXR0cmlidXRlcyBmb3Igb3BlcmF0aW9uIHR5cGVzCiNkZWZpbmUgU1lTRlNfT1BUWVBFX0RFQ0wobmFtZSwgb3B0eXBlKSBcCnN0YXRp"
    "YyBzc2l6ZV90IGFkaW9zX2xhdF9tb2RlbF8jI25hbWUjI19zaG93KCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjaGFyICpwYWdlKSB7IFwKCXN0"
    "cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXN0cnVjdCBsYXRlbmN5X21vZGVsICptb2RlbCA9ICZhZC0+bGF0ZW5jeV9tb2Rl"
    "bFtvcHR5cGVdOyBcCglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbF9wYXJhbXMgKnBhcmFtczsgXAoJc3NpemVfdCBsZW4gPSAwOyBcCgl1NjQgYmFzZSwgc2xvcGU7"
    "IFwKCXJjdV9yZWFkX2xvY2soKTsgXAoJcGFyYW1zID0gcmN1X2RlcmVmZXJlbmNlKG1vZGVsLT5wYXJhbXMpOyBcCgliYXNlID0gcGFyYW1zLT5iYXNlOyBc"
    "CglzbG9wZSA9IHBhcmFtcy0+c2xvcGU7IFwKCXJjdV9yZWFkX3VubG9jaygpOyBcCglsZW4gKz0gc3ByaW50ZihwYWdlLCAgICAgICAiYmFzZSA6ICVsbHUg"
    "bnNcbiIsIGJhc2UpOyBcCglsZW4gKz0gc3ByaW50ZihwYWdlICsgbGVuLCAic2xvcGU6ICVsbHUgbnMvS2lCXG4iLCBzbG9wZSk7IFwKCXJldHVybiBsZW47"
    "IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zX2xhdF9tb2RlbF8jI25hbWUjI19zdG9yZSggXAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY29uc3Qg"
    "Y2hhciAqcGFnZSwgc2l6ZV90IGNvdW50KSB7IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXN0cnVjdCBsYXRlbmN5"
    "X21vZGVsICptb2RlbCA9ICZhZC0+bGF0ZW5jeV9tb2RlbFtvcHR5cGVdOyBcCgl1NjQgYmFzZSwgc2xvcGU7IFwKCWludCByZXQ7IFwKCXJldCA9IHNzY2Fu"
    "ZihwYWdlLCAiJWxsdSAlbGx1IiwgJmJhc2UsICZzbG9wZSk7IFwKCWlmIChyZXQgIT0gMikgXAoJCXJldHVybiAtRUlOVkFMOyBcCglzaWRlbG9hZF9sYXRl"
    "bmN5X21vZGVsKG1vZGVsLCBiYXNlLCBzbG9wZSk7IFwKCXJlc2V0X2J1Y2tldHMoYWQtPmFnZ3JfYnVja2V0cyk7IFwKCXJldHVybiBjb3VudDsgXAp9IFwK"
    "c3RhdGljIHNzaXplX3QgYWRpb3NfbGF0X3RhcmdldF8jI25hbWUjI19zaG93KCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjaGFyICpwYWdlKSB7"
    "IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXJldHVybiBzcHJpbnRmKHBhZ2UsICIlbGx1XG4iLCBhZC0+bGF0ZW5j"
    "eV90YXJnZXRbb3B0eXBlXSk7IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zX2xhdF90YXJnZXRfIyNuYW1lIyNfc3RvcmUoIFwKCQlzdHJ1Y3QgZWxldmF0"
    "b3JfcXVldWUgKmUsIGNvbnN0IGNoYXIgKnBhZ2UsIHNpemVfdCBjb3VudCkgeyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRh"
    "OyBcCgl1bnNpZ25lZCBsb25nIG5zZWM7IFwKCWludCByZXQ7IFwKCXJldCA9IGtzdHJ0b3VsKHBhZ2UsIDEwLCAmbnNlYyk7IFwKCWlmIChyZXQpIFwKCQly"
    "ZXR1cm4gcmV0OyBcCglzaWRlbG9hZF9sYXRlbmN5X21vZGVsKCZhZC0+bGF0ZW5jeV9tb2RlbFtvcHR5cGVdLCAwLCAwKTsgXAoJYWQtPmxhdGVuY3lfdGFy"
    "Z2V0W29wdHlwZV0gPSBuc2VjOyBcCglyZXR1cm4gY291bnQ7IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zX2JhdGNoX2xpbWl0XyMjbmFtZSMjX3Nob3co"
    "IFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNoYXIgKnBhZ2UpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsg"
    "XAoJcmV0dXJuIHNwcmludGYocGFnZSwgIiV1XG4iLCBhZC0+YmF0Y2hfbGltaXRbb3B0eXBlXSk7IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zX2JhdGNo"
    "X2xpbWl0XyMjbmFtZSMjX3N0b3JlKCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3QgY291bnQpIHsgXAoJ"
    "dW5zaWduZWQgbG9uZyBtYXhfYmF0Y2g7IFwKCWludCByZXQ7IFwKCXJldCA9IGtzdHJ0b3VsKHBhZ2UsIDEwLCAmbWF4X2JhdGNoKTsgXAoJaWYgKHJldCB8"
    "fCBtYXhfYmF0Y2ggPT0gMCkgXAoJCXJldHVybiAtRUlOVkFMOyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBcCglhZC0+"
    "YmF0Y2hfbGltaXRbb3B0eXBlXSA9IG1heF9iYXRjaDsgXAoJcmV0dXJuIGNvdW50OyBcCn0KClNZU0ZTX09QVFlQRV9ERUNMKHJlYWQsIEFESU9TX1JFQUQp"
    "OwpTWVNGU19PUFRZUEVfREVDTCh3cml0ZSwgQURJT1NfV1JJVEUpOwpTWVNGU19PUFRZUEVfREVDTChkaXNjYXJkLCBBRElPU19ESVNDQVJEKTsKCi8vIFNo"
    "b3cgdGhlIG1heGltdW0gYmF0Y2ggc2l6ZSBhY3R1YWxseSBhY2hpZXZlZCBmb3IgZWFjaCBvcGVyYXRpb24gdHlwZQpzdGF0aWMgc3NpemVfdCBhZGlvc19i"
    "YXRjaF9hY3R1YWxfbWF4X3Nob3coCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjaGFyICpwYWdlKSB7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBl"
    "LT5lbGV2YXRvcl9kYXRhOwoJdTMyIHRvdGFsX2NvdW50LCByZWFkX2NvdW50LCB3cml0ZV9jb3VudCwgZGlzY2FyZF9jb3VudDsKCgl0b3RhbF9jb3VudCA9"
    "IGFkLT5iYXRjaF9hY3R1YWxfbWF4X3RvdGFsOwoJcmVhZF9jb3VudCA9IGFkLT5iYXRjaF9hY3R1YWxfbWF4X3NpemVbQURJT1NfUkVBRF07Cgl3cml0ZV9j"
    "b3VudCA9IGFkLT5iYXRjaF9hY3R1YWxfbWF4X3NpemVbQURJT1NfV1JJVEVdOwoJZGlzY2FyZF9jb3VudCA9IGFkLT5iYXRjaF9hY3R1YWxfbWF4X3NpemVb"
    "QURJT1NfRElTQ0FSRF07CgoJcmV0dXJuIHNwcmludGYocGFnZSwKCQkiVG90YWwgIDogJXVcbkRpc2NhcmQ6ICV1XG5SZWFkICAgOiAldVxuV3JpdGUgIDog"
    "JXVcbiIsCgkJdG90YWxfY291bnQsIGRpc2NhcmRfY291bnQsIHJlYWRfY291bnQsIHdyaXRlX2NvdW50KTsKfQoKI2RlZmluZSBTWVNGU19VTExfREVDTChm"
    "aWVsZCwgbWluX3ZhbCwgbWF4X3ZhbCkgXApzdGF0aWMgc3NpemVfdCBhZGlvc18jI2ZpZWxkIyNfc2hvdyggXAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAq"
    "ZSwgY2hhciAqcGFnZSkgeyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBcCglyZXR1cm4gc3ByaW50ZihwYWdlLCAiJWxs"
    "dVxuIiwgYWQtPmZpZWxkKTsgXAp9IFwKc3RhdGljIHNzaXplX3QgYWRpb3NfIyNmaWVsZCMjX3N0b3JlKCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICpl"
    "LCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3QgY291bnQpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsgXAoJdW5zaWdu"
    "ZWQgbG9uZyB2YWw7IFwKCWludCByZXQ7IFwKCXJldCA9IGtzdHJ0b3VsKHBhZ2UsIDEwLCAmdmFsKTsgXAoJaWYgKHJldCB8fCB2YWwgPCAobWluX3ZhbCkg"
    "fHwgdmFsID4gKG1heF92YWwpKSBcCgkJcmV0dXJuIC1FSU5WQUw7IFwKCWFkLT5maWVsZCA9IHZhbDsgXAoJcmV0dXJuIGNvdW50OyBcCn0KClNZU0ZTX1VM"
    "TF9ERUNMKGdsb2JhbF9sYXRlbmN5X3dpbmRvdywgMCwgVUxMT05HX01BWCkKU1lTRlNfVUxMX0RFQ0woY29tcGxpYW5jZV9mbGFncywgMCwgVUxMT05HX01B"
    "WCkKCiNkZWZpbmUgU1lTRlNfSU5UX0RFQ0woZmllbGQsIG1pbl92YWwsIG1heF92YWwpIFwKc3RhdGljIHNzaXplX3QgYWRpb3NfIyNmaWVsZCMjX3Nob3co"
    "IFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNoYXIgKnBhZ2UpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsg"
    "XAoJcmV0dXJuIHNwcmludGYocGFnZSwgIiVkXG4iLCBhZC0+ZmllbGQpOyBcCn0gXApzdGF0aWMgc3NpemVfdCBhZGlvc18jI2ZpZWxkIyNfc3RvcmUoIFwK"
    "CQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNvbnN0IGNoYXIgKnBhZ2UsIHNpemVfdCBjb3VudCkgeyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBl"
    "LT5lbGV2YXRvcl9kYXRhOyBcCglpbnQgdmFsOyBcCglpbnQgcmV0OyBcCglyZXQgPSBrc3RydG9pbnQocGFnZSwgMTAsICZ2YWwpOyBcCglpZiAocmV0IHx8"
    "IHZhbCA8IChtaW5fdmFsKSB8fCB2YWwgPiAobWF4X3ZhbCkpIFwKCQlyZXR1cm4gLUVJTlZBTDsgXAoJYWQtPmZpZWxkID0gdmFsOyBcCglyZXR1cm4gY291"
    "bnQ7IFwKfQoKU1lTRlNfSU5UX0RFQ0woYnFfcmVmaWxsX2JlbG93X3JhdGlvLCAwLCAxMDApClNZU0ZTX0lOVF9ERUNMKGxhdF9tb2RlbF9sYXRlbmN5X2xp"
    "bWl0LCAwLCAyKk5TRUNfUEVSX1NFQykKU1lTRlNfSU5UX0RFQ0woYmF0Y2hfb3JkZXIsIEFESU9TX0JPX09QVFlQRSwgISFhZC0+aXNfcm90YXRpb25hbCkK"
    "Ci8vIFNob3cgdGhlIHJlYWQgcHJpb3JpdHkKc3RhdGljIHNzaXplX3QgYWRpb3NfcmVhZF9wcmlvcml0eV9zaG93KAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1"
    "ZSAqZSwgY2hhciAqcGFnZSkgewoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsKCXJldHVybiBzcHJpbnRmKHBhZ2UsICIlZFxu"
    "IiwgYWQtPmRsX3ByaW9bMF0pOwp9CgovLyBTZXQgdGhlIHJlYWQgcHJpb3JpdHkKc3RhdGljIHNzaXplX3QgYWRpb3NfcmVhZF9wcmlvcml0eV9zdG9yZSgK"
    "CQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNvbnN0IGNoYXIgKnBhZ2UsIHNpemVfdCBjb3VudCkgewoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+"
    "ZWxldmF0b3JfZGF0YTsKCWludCBwcmlvOwoJaW50IHJldDsKCglyZXQgPSBrc3RydG9pbnQocGFnZSwgMTAsICZwcmlvKTsKCWlmIChyZXQgfHwgcHJpbyA8"
    "IC0yMCB8fCBwcmlvID4gMTkpCgkJcmV0dXJuIC1FSU5WQUw7CgoJYWRpb3NfZ3VhcmQoc3BpbmxvY2tfaXJxc2F2ZSkoJmFkLT5sb2NrKTsKCWFkLT5kbF9w"
    "cmlvWzBdID0gcHJpbzsKCWFkLT5kbF9iaWFzID0gMDsKCglyZXR1cm4gY291bnQ7Cn0KCi8vIFJlc2V0IGJhdGNoIHF1ZXVlIHN0YXRpc3RpY3MKc3RhdGlj"
    "IHNzaXplX3QgYWRpb3NfcmVzZXRfYnFfc3RhdHNfc3RvcmUoCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3Qg"
    "Y291bnQpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7Cgl1bnNpZ25lZCBsb25nIHZhbDsKCWludCByZXQ7CgoJcmV0ID0g"
    "a3N0cnRvdWwocGFnZSwgMTAsICZ2YWwpOwoJaWYgKHJldCB8fCB2YWwgIT0gMSkKCQlyZXR1cm4gLUVJTlZBTDsKCglmb3IgKHU4IGkgPSAwOyBpIDwgQURJ"
    "T1NfT1BUWVBFUzsgaSsrKQoJCWFkLT5iYXRjaF9hY3R1YWxfbWF4X3NpemVbaV0gPSAwOwoKCWFkLT5iYXRjaF9hY3R1YWxfbWF4X3RvdGFsID0gMDsKCgly"
    "ZXR1cm4gY291bnQ7Cn0KCi8vIFJlc2V0IHRoZSBsYXRlbmN5IG1vZGVsIHBhcmFtZXRlcnMgb3IgbG9hZCB0aGVtIGZyb20gdXNlciBpbnB1dApzdGF0aWMg"
    "c3NpemVfdCBhZGlvc19yZXNldF9sYXRfbW9kZWxfc3RvcmUoCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3Qg"
    "Y291bnQpCnsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWw7CglpbnQgcmV0"
    "OwoKCS8qCgkgKiBEaWZmZXJlbnRpYXRlIGJldHdlZW4gdHdvIG1vZGVzIGJhc2VkIG9uIGlucHV0IGZvcm1hdDoKCSAqIDEuICIxIjogRnVsbHkgcmVzZXQg"
    "dGhlIG1vZGVsIChiYWNrd2FyZCBjb21wYXRpYmlsaXR5KS4KCSAqIDIuICJSX2Jhc2UgUl9zbG9wZSBXX2Jhc2UgV19zbG9wZSBEX2Jhc2UgRF9zbG9wZSI6"
    "IExvYWQgdmFsdWVzLgoJICovCglpZiAoIXN0cmNocihwYWdlLCAnICcpKSB7CgkJLy8gTW9kZSAxOiBGdWxsIHJlc2V0LgoJCXVuc2lnbmVkIGxvbmcgdmFs"
    "OwoKCQlyZXQgPSBrc3RydG91bChwYWdlLCAxMCwgJnZhbCk7CgkJaWYgKHJldCB8fCB2YWwgIT0gMSkKCQkJcmV0dXJuIC1FSU5WQUw7CgoJCWZvciAodTgg"
    "aSA9IDA7IGkgPCBBRElPU19PUFRZUEVTOyBpKyspIHsKCQkJbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbaV07CgkJCXNpZGVsb2FkX2xhdGVuY3lfbW9k"
    "ZWwobW9kZWwsIDAsIDApOwoJCX0KCX0gZWxzZSB7CgkJLy8gTW9kZSAyOiBMb2FkIGluaXRpYWwgdmFsdWVzIGZvciBhbGwgbGF0ZW5jeSBtb2RlbHMuCgkJ"
    "dTY0IHBhcmFtc1szXVsyXTsgLyogMDpiYXNlLCAxOnNsb3BlIGZvciBSLCBXLCBEICovCgoJCXJldCA9IHNzY2FuZihwYWdlLCAiJWxsdSAlbGx1ICVsbHUg"
    "JWxsdSAlbGx1ICVsbHUiLAoJCQkmcGFyYW1zW0FESU9TX1JFQUQgICBdWzBdLCAmcGFyYW1zW0FESU9TX1JFQUQgICBdWzFdLAoJCQkmcGFyYW1zW0FESU9T"
    "X1dSSVRFICBdWzBdLCAmcGFyYW1zW0FESU9TX1dSSVRFICBdWzFdLAoJCQkmcGFyYW1zW0FESU9TX0RJU0NBUkRdWzBdLCAmcGFyYW1zW0FESU9TX0RJU0NB"
    "UkRdWzFdKTsKCgkJaWYgKHJldCAhPSA2KQoJCQlyZXR1cm4gLUVJTlZBTDsKCgkJZm9yICh1OCBpID0gQURJT1NfUkVBRDsgaSA8PSBBRElPU19ESVNDQVJE"
    "OyBpKyspIHsKCQkJbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbaV07CgkJCXNpZGVsb2FkX2xhdGVuY3lfbW9kZWwobW9kZWwsIHBhcmFtc1tpXVswXSwg"
    "cGFyYW1zW2ldWzFdKTsKCQl9Cgl9CglyZXNldF9idWNrZXRzKGFkLT5hZ2dyX2J1Y2tldHMpOwoKCXJldHVybiBjb3VudDsKfQoKLy8gU2hvdyB0aGUgQURJ"
    "T1MgdmVyc2lvbgpzdGF0aWMgc3NpemVfdCBhZGlvc192ZXJzaW9uX3Nob3coc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjaGFyICpwYWdlKSB7CglyZXR1"
    "cm4gc3ByaW50ZihwYWdlLCAiJXNcbiIsIEFESU9TX1ZFUlNJT04pOwp9CgovLyBEZWZpbmUgc3lzZnMgYXR0cmlidXRlcyBmb3IgZHluYW1pYyB0aHJlc2hv"
    "bGRzCiNkZWZpbmUgU0hSSU5LX1RIUkVTSE9MRF9BVFRSX1JXKG5hbWUsIG1vZGVsX2ZpZWxkLCBtaW5fdmFsdWUsIG1heF92YWx1ZSkgXApzdGF0aWMgc3Np"
    "emVfdCBhZGlvc19zaHJpbmtfIyNuYW1lIyNfc3RvcmUoIFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNvbnN0IGNoYXIgKnBhZ2UsIHNpemVfdCBj"
    "b3VudCkgeyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBcCgl1bnNpZ25lZCBsb25nIHZhbDsgXAoJaW50IHJldDsgXAoJ"
    "cmV0ID0ga3N0cnRvdWwocGFnZSwgMTAsICZ2YWwpOyBcCglpZiAocmV0IHx8IHZhbCA8IG1pbl92YWx1ZSB8fCB2YWwgPiBtYXhfdmFsdWUpIFwKCQlyZXR1"
    "cm4gLUVJTlZBTDsgXAoJZm9yICh1OCBpID0gMDsgaSA8IEFESU9TX09QVFlQRVM7IGkrKykgeyBcCgkJc3RydWN0IGxhdGVuY3lfbW9kZWwgKm1vZGVsID0g"
    "JmFkLT5sYXRlbmN5X21vZGVsW2ldOyBcCgkJdW5zaWduZWQgbG9uZyBmbGFnczsgXAoJCXNwaW5fbG9ja19pcnFzYXZlKCZtb2RlbC0+dXBkYXRlX2xvY2ss"
    "IGZsYWdzKTsgXAoJCW1vZGVsLT5tb2RlbF9maWVsZCA9IHZhbDsgXAoJCXNwaW5fdW5sb2NrX2lycXJlc3RvcmUoJm1vZGVsLT51cGRhdGVfbG9jaywgZmxh"
    "Z3MpOyBcCgl9IFwKCXJldHVybiBjb3VudDsgXAp9IFwKc3RhdGljIHNzaXplX3QgYWRpb3Nfc2hyaW5rXyMjbmFtZSMjX3Nob3coIFwKCQlzdHJ1Y3QgZWxl"
    "dmF0b3JfcXVldWUgKmUsIGNoYXIgKnBhZ2UpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsgXAoJdTMyIHZhbCA9IDA7"
    "IFwKCXVuc2lnbmVkIGxvbmcgZmxhZ3M7IFwKCXN0cnVjdCBsYXRlbmN5X21vZGVsICptb2RlbCA9ICZhZC0+bGF0ZW5jeV9tb2RlbFswXTsgXAoJc3Bpbl9s"
    "b2NrX2lycXNhdmUoJm1vZGVsLT51cGRhdGVfbG9jaywgZmxhZ3MpOyBcCgl2YWwgPSBtb2RlbC0+bW9kZWxfZmllbGQ7IFwKCXNwaW5fdW5sb2NrX2lycXJl"
    "c3RvcmUoJm1vZGVsLT51cGRhdGVfbG9jaywgZmxhZ3MpOyBcCglyZXR1cm4gc3ByaW50ZihwYWdlLCAiJXVcbiIsIHZhbCk7IFwKfQoKU0hSSU5LX1RIUkVT"
    "SE9MRF9BVFRSX1JXKGF0X2tyZXFzLCAgbG1fc2hyaW5rX2F0X2tyZXFzLCAgMSwgMTAwMDAwKQpTSFJJTktfVEhSRVNIT0xEX0FUVFJfUlcoYXRfZ2J5dGVz"
    "LCBsbV9zaHJpbmtfYXRfZ2J5dGVzLCAxLCAgIDEwMDApClNIUklOS19USFJFU0hPTERfQVRUUl9SVyhyZXNpc3QsICAgIGxtX3Nocmlua19yZXNpc3QsICAg"
    "IDEsICAgICAgMykKCi8vIERlZmluZSBzeXNmcyBhdHRyaWJ1dGVzCiNkZWZpbmUgQURfQVRUUihuYW1lLCBzaG93X2Z1bmMsIHN0b3JlX2Z1bmMpIFwKCV9f"
    "QVRUUihuYW1lLCAwNjQ0LCBzaG93X2Z1bmMsIHN0b3JlX2Z1bmMpCiNkZWZpbmUgQURfQVRUUl9SVyhuYW1lKSBcCglfX0FUVFIobmFtZSwgMDY0NCwgYWRp"
    "b3NfIyNuYW1lIyNfc2hvdywgYWRpb3NfIyNuYW1lIyNfc3RvcmUpCiNkZWZpbmUgQURfQVRUUl9STyhuYW1lKSBcCglfX0FUVFIobmFtZSwgMDQ0NCwgYWRp"
    "b3NfIyNuYW1lIyNfc2hvdywgTlVMTCkKI2RlZmluZSBBRF9BVFRSX1dPKG5hbWUpIFwKCV9fQVRUUihuYW1lLCAwMjAwLCBOVUxMLCBhZGlvc18jI25hbWUj"
    "I19zdG9yZSkKCi8vIERlZmluZSBzeXNmcyBhdHRyaWJ1dGVzIGZvciBBRElPUyBzY2hlZHVsZXIKc3RhdGljIHN0cnVjdCBlbHZfZnNfZW50cnkgYWRpb3Nf"
    "c2NoZWRfYXR0cnNbXSA9IHsKCUFEX0FUVFJfUk8oYmF0Y2hfYWN0dWFsX21heCksCglBRF9BVFRSX1JXKGJxX3JlZmlsbF9iZWxvd19yYXRpbyksCglBRF9B"
    "VFRSX1JXKGdsb2JhbF9sYXRlbmN5X3dpbmRvdyksCglBRF9BVFRSX1JXKGxhdF9tb2RlbF9sYXRlbmN5X2xpbWl0KSwKCUFEX0FUVFJfUlcoYmF0Y2hfb3Jk"
    "ZXIpLAoJQURfQVRUUl9SVyhjb21wbGlhbmNlX2ZsYWdzKSwKCglBRF9BVFRSX1JXKGJhdGNoX2xpbWl0X3JlYWQpLAoJQURfQVRUUl9SVyhiYXRjaF9saW1p"
    "dF93cml0ZSksCglBRF9BVFRSX1JXKGJhdGNoX2xpbWl0X2Rpc2NhcmQpLAoKCUFEX0FUVFJfUlcobGF0X21vZGVsX3JlYWQpLAoJQURfQVRUUl9SVyhsYXRf"
    "bW9kZWxfd3JpdGUpLAoJQURfQVRUUl9SVyhsYXRfbW9kZWxfZGlzY2FyZCksCgoJQURfQVRUUl9SVyhsYXRfdGFyZ2V0X3JlYWQpLAoJQURfQVRUUl9SVyhs"
    "YXRfdGFyZ2V0X3dyaXRlKSwKCUFEX0FUVFJfUlcobGF0X3RhcmdldF9kaXNjYXJkKSwKCglBRF9BVFRSX1JXKHNocmlua19hdF9rcmVxcyksCglBRF9BVFRS"
    "X1JXKHNocmlua19hdF9nYnl0ZXMpLAoJQURfQVRUUl9SVyhzaHJpbmtfcmVzaXN0KSwKCglBRF9BVFRSX1JXKHJlYWRfcHJpb3JpdHkpLAoKCUFEX0FUVFJf"
    "V08ocmVzZXRfYnFfc3RhdHMpLAoJQURfQVRUUl9XTyhyZXNldF9sYXRfbW9kZWwpLAoJQURfQVRUUihhZGlvc192ZXJzaW9uLCBhZGlvc192ZXJzaW9uX3No"
    "b3csIE5VTEwpLAoKCV9fQVRUUl9OVUxMCn07CgovLyBEZWZpbmUgdGhlIEFESU9TIHNjaGVkdWxlciB0eXBlCnN0YXRpYyBzdHJ1Y3QgZWxldmF0b3JfdHlw"
    "ZSBtcV9hZGlvcyA9IHsKCS5vcHMgPSB7CgkJLm5leHRfcmVxdWVzdAkJPSBlbHZfcmJfbGF0dGVyX3JlcXVlc3QsCgkJLmZvcm1lcl9yZXF1ZXN0CQk9IGVs"
    "dl9yYl9mb3JtZXJfcmVxdWVzdCwKCQkubGltaXRfZGVwdGgJCT0gYWRpb3NfbGltaXRfZGVwdGgsCgkJLmRlcHRoX3VwZGF0ZWQJCT0gYWRpb3NfZGVwdGhf"
    "dXBkYXRlZCwKCQkucmVxdWVzdF9tZXJnZWQJCT0gYWRpb3NfcmVxdWVzdF9tZXJnZWQsCgkJLnJlcXVlc3RzX21lcmdlZAk9IGFkaW9zX21lcmdlZF9yZXF1"
    "ZXN0cywKCQkuYmlvX21lcmdlCQkJPSBhZGlvc19iaW9fbWVyZ2UsCgkJLmluc2VydF9yZXF1ZXN0cwk9IGFkaW9zX2luc2VydF9yZXF1ZXN0cywKCQkucHJl"
    "cGFyZV9yZXF1ZXN0CT0gYWRpb3NfcHJlcGFyZV9yZXF1ZXN0LAoJCS5kaXNwYXRjaF9yZXF1ZXN0CT0gYWRpb3NfZGlzcGF0Y2hfcmVxdWVzdCwKCQkuY29t"
    "cGxldGVkX3JlcXVlc3QJPSBhZGlvc19jb21wbGV0ZWRfcmVxdWVzdCwKCQkuZmluaXNoX3JlcXVlc3QJCT0gYWRpb3NfZmluaXNoX3JlcXVlc3QsCgkJLmhh"
    "c193b3JrCQkJPSBhZGlvc19oYXNfd29yaywKCQkuaW5pdF9oY3R4CQkJPSBhZGlvc19pbml0X2hjdHgsCgkJLmluaXRfc2NoZWQJCQk9IGFkaW9zX2luaXRf"
    "c2NoZWQsCgkJLmV4aXRfc2NoZWQJCQk9IGFkaW9zX2V4aXRfc2NoZWQsCgl9LAoJLmVsZXZhdG9yX2F0dHJzID0gYWRpb3Nfc2NoZWRfYXR0cnMsCgkuZWxl"
    "dmF0b3JfbmFtZSA9ICJhZGlvcyIsCgkuZWxldmF0b3Jfb3duZXIgPSBUSElTX01PRFVMRSwKfTsKTU9EVUxFX0FMSUFTKCJtcS1hZGlvcy1pb3NjaGVkIik7"
    "CgojZGVmaW5lIEFESU9TX1BST0dOQU1FICJBZGFwdGl2ZSBEZWFkbGluZSBJL08gU2NoZWR1bGVyIgojZGVmaW5lIEFESU9TX0FVVEhPUiAgICJNYXNhaGl0"
    "byBTdXp1a2kiCgovLyBJbml0aWFsaXplIHRoZSBBRElPUyBzY2hlZHVsZXIgbW9kdWxlCnN0YXRpYyBpbnQgX19pbml0IGFkaW9zX2luaXQodm9pZCkgewoJ"
    "cHJpbnRrKEtFUk5fSU5GTyAiJXMgJXMgYnkgJXNcbiIsCgkJQURJT1NfUFJPR05BTUUsIEFESU9TX1ZFUlNJT04sIEFESU9TX0FVVEhPUik7CglyZXR1cm4g"
    "ZWx2X3JlZ2lzdGVyKCZtcV9hZGlvcyk7Cn0KCi8vIEV4aXQgdGhlIEFESU9TIHNjaGVkdWxlciBtb2R1bGUKc3RhdGljIHZvaWQgX19leGl0IGFkaW9zX2V4"
    "aXQodm9pZCkgewoJZWx2X3VucmVnaXN0ZXIoJm1xX2FkaW9zKTsKfQoKbW9kdWxlX2luaXQoYWRpb3NfaW5pdCk7Cm1vZHVsZV9leGl0KGFkaW9zX2V4aXQp"
    "OwoKTU9EVUxFX0FVVEhPUihBRElPU19BVVRIT1IpOwpNT0RVTEVfTElDRU5TRSgiR1BMIik7Ck1PRFVMRV9ERVNDUklQVElPTihBRElPU19QUk9HTkFNRSk7"
    "Cg=="
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
