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
    "aD4KI2luY2x1ZGUgPGxpbnV4L21hdGguaD4KI2luY2x1ZGUgPGxpbnV4L21vZHVsZS5oPgojaW5jbHVkZSA8bGludXgvcmJ0cmVlLmg+CiNpbmNsdWRlIDxs"
    "aW51eC9zYml0bWFwLmg+CiNpbmNsdWRlIDxsaW51eC9tZW1wb29sLmg+CiNpbmNsdWRlIDxsaW51eC9zbGFiLmg+CiNpbmNsdWRlIDxsaW51eC90aW1la2Vl"
    "cGluZy5oPgojaW5jbHVkZSA8bGludXgvcGVyY3B1Lmg+CiNpbmNsdWRlIDxsaW51eC9zdHJpbmcuaD4KI2luY2x1ZGUgPGxpbnV4L2xpc3Rfc29ydC5oPgoj"
    "aW5jbHVkZSA8bGludXgvcmN1cGRhdGUuaD4KCiNpbmNsdWRlICJlbGV2YXRvci5oIgojaW5jbHVkZSAiYmxrLmgiCiNpbmNsdWRlICJibGstbXEuaCIKLyog"
    "LS0tLSBjaHJvbGxvOiBMaW51eCA1LjQgY29tcGF0aWJpbGl0eSBzaGltcyAtLS0tICovCmV4dGVybiBib29sIGJsa19tcV9zY2hlZF90cnlfbWVyZ2Uoc3Ry"
    "dWN0IHJlcXVlc3RfcXVldWUgKnEsIHN0cnVjdCBiaW8gKmJpbywKCQl1bnNpZ25lZCBpbnQgbnJfc2Vncywgc3RydWN0IHJlcXVlc3QgKiptZXJnZWRfcmVx"
    "dWVzdCk7Cgp0eXBlZGVmIHVuc2lnbmVkIGludCBibGtfaW5zZXJ0X3Q7CiNkZWZpbmUgQkxLX01RX0lOU0VSVF9BVF9IRUFECTAKCi8qIDUuNCBoYXMgbm8g"
    "YmxrX21xX3NjaGVkX3RyeV9pbnNlcnRfbWVyZ2UoKTsga2VlcGluZyByZXF1ZXN0LXJlcXVlc3QgbWVyZ2luZwogKiBkaXNhYmxlZCBvbmx5IGNvc3RzIGEg"
    "bGl0dGxlIHRocm91Z2hwdXQsIGNvcnJlY3RuZXNzIGlzIHVuY2hhbmdlZC4gKi8Kc3RhdGljIGlubGluZSBib29sIGFkaW9zX3RyeV9pbnNlcnRfbWVyZ2Uo"
    "c3RydWN0IHJlcXVlc3RfcXVldWUgKnEsCgkJc3RydWN0IHJlcXVlc3QgKnJxLCBzdHJ1Y3QgbGlzdF9oZWFkICpmcmVlKQp7CglyZXR1cm4gZmFsc2U7Cn0K"
    "CnN0YXRpYyBpbmxpbmUgdm9pZCBhZGlvc19mcmVlX3JlcXVlc3RzKHN0cnVjdCBsaXN0X2hlYWQgKmxpc3QpCnsKCXN0cnVjdCByZXF1ZXN0ICpycSwgKnRt"
    "cDsKCWxpc3RfZm9yX2VhY2hfZW50cnlfc2FmZShycSwgdG1wLCBsaXN0LCBxdWV1ZWxpc3QpCgkJYmxrX21xX2ZyZWVfcmVxdWVzdChycSk7Cn0KCnN0cnVj"
    "dCBhZGlvc19ndWFyZF9zcGlubG9ja19pcnFzYXZlIHsKCXNwaW5sb2NrX3QgKmxvY2s7Cgl1bnNpZ25lZCBsb25nIGZsYWdzOwp9OwoKc3RhdGljIGlubGlu"
    "ZSBzdHJ1Y3QgYWRpb3NfZ3VhcmRfc3BpbmxvY2tfaXJxc2F2ZQphZGlvc19ndWFyZF9zcGlubG9ja19pcnFzYXZlX2luaXQoc3BpbmxvY2tfdCAqbG9jaykK"
    "ewoJc3RydWN0IGFkaW9zX2d1YXJkX3NwaW5sb2NrX2lycXNhdmUgZzsKCglnLmxvY2sgPSBsb2NrOwoJc3Bpbl9sb2NrX2lycXNhdmUobG9jaywgZy5mbGFn"
    "cyk7CglyZXR1cm4gZzsKfQoKc3RhdGljIGlubGluZSB2b2lkCmFkaW9zX2d1YXJkX3NwaW5sb2NrX2lycXNhdmVfZmluaShzdHJ1Y3QgYWRpb3NfZ3VhcmRf"
    "c3BpbmxvY2tfaXJxc2F2ZSAqZykKewoJc3Bpbl91bmxvY2tfaXJxcmVzdG9yZShnLT5sb2NrLCBnLmZsYWdzKTsKfQoKI2RlZmluZSBBRElPU19HVUFSRF9D"
    "QVQyKGEsIGIpIGEjI2IKI2RlZmluZSBBRElPU19HVUFSRF9DQVQoYSwgYikgQURJT1NfR1VBUkRfQ0FUMihhLCBiKQoKLyogYWRpb3NfZ3VhcmQoc3Bpbmxv"
    "Y2tfaXJxc2F2ZSkoJmxvY2spICovCiNkZWZpbmUgYWRpb3NfZ3VhcmQoLi4uKSBBRElPU19HVUFSRF9DQVQoYWRpb3NfZ3VhcmRfLCBfX1ZBX0FSR1NfXykK"
    "I2RlZmluZSBhZGlvc19ndWFyZF9zcGlubG9ja19pcnFzYXZlKGxvY2spIFwKCXN0cnVjdCBhZGlvc19ndWFyZF9zcGlubG9ja19pcnFzYXZlIFwKCQlfX2F0"
    "dHJpYnV0ZV9fKChjbGVhbnVwKGFkaW9zX2d1YXJkX3NwaW5sb2NrX2lycXNhdmVfZmluaSkpKSBcCgkJQURJT1NfR1VBUkRfQ0FUKGFkb3NfZ3VhcmRfLCBf"
    "X0xJTkVfXykgPSBcCgkJYWRpb3NfZ3VhcmRfc3BpbmxvY2tfaXJxc2F2ZV9pbml0KGxvY2spCgovKiBhZGlvc19zY29wZWRfZ3VhcmQoc3BpbmxvY2tfaXJx"
    "c2F2ZSwgJmxvY2spIHsgLi4uIH0gKi8KI2RlZmluZSBhZGlvc19zY29wZWRfZ3VhcmQodHlwZSwgbG9jaykgXAoJZm9yIChzdHJ1Y3QgYWRpb3NfZ3VhcmRf"
    "c3BpbmxvY2tfaXJxc2F2ZSBhZG9zX3NndWFyZF9fID0gXAoJCQlhZGlvc19ndWFyZF9zcGlubG9ja19pcnFzYXZlX2luaXQobG9jayk7IFwKCSAgICAgYWRv"
    "c19zZ3VhcmRfXy5sb2NrOyBcCgkgICAgICh7IHNwaW5fdW5sb2NrX2lycXJlc3RvcmUoYWRvc19zZ3VhcmRfXy5sb2NrLCBhZG9zX3NndWFyZF9fLmZsYWdz"
    "KTsgXAoJICAgICAgICBhZG9zX3NndWFyZF9fLmxvY2sgPSBOVUxMOyB9KSkKCgojZGVmaW5lIEFESU9TX1ZFUlNJT04gIjMuMy4wIgoKLyogUmVxdWVzdCBU"
    "eXBlczoKICoKICogVGllciAwIChIaWdoZXN0IFByaW9yaXR5KTogRW1lcmdlbmN5ICYgU3lzdGVtIEludGVncml0eSBSZXF1ZXN0cwogKiAtLS0tLS0tLS0t"
    "LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLQogKiAtIFRhcmdldDogUmVxdWVzdHMgd2l0aCB0aGUgQkxL"
    "X01RX0lOU0VSVF9BVF9IRUFEIGZsYWcuCiAqIC0gUHVycG9zZTogRm9yIGNyaXRpY2FsLCBub24tbmVnb3RpYWJsZSBvcGVyYXRpb25zIHN1Y2ggYXMgZGV2"
    "aWNlIGVycm9yCiAqICAgcmVjb3Zlcnkgb3IgZmx1c2ggc2VxdWVuY2VzIHRoYXQgbXVzdCBieXBhc3MgYWxsIG90aGVyIHNjaGVkdWxpbmcgbG9naWMuCiAq"
    "IC0gSW1wbGVtZW50YXRpb246IFBsYWNlZCBpbiBhIGRlZGljYXRlZCwgaGlnaC1wcmlvcml0eSBGSUZPIHF1ZXVlCiAqICAgKGBwcmlvX3F1ZXVlWzBdYCkg"
    "Zm9yIGltbWVkaWF0ZSBkaXNwYXRjaC4KICoKICogVGllciAxIChNZWRpdW0gUHJpb3JpdHkpOiBBcHBsaWNhdGlvbiBSZXNwb25zaXZlbmVzcwogKiAtLS0t"
    "LS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAqIC0gVGFyZ2V0OiBOb3JtYWwgc3luY2hyb25vdXMgcmVxdWVzdHMg"
    "KGUuZy4sIGZyb20gc3RhbmRhcmQgZmlsZSByZWFkcykuCiAqIC0gUHVycG9zZTogVG8gZW5zdXJlIGNvcnJlY3QgYXBwbGljYXRpb24gYmVoYXZpb3IgZm9y"
    "IG9wZXJhdGlvbnMgdGhhdAogKiAgIGRlcGVuZCBvbiBzZXF1ZW50aWFsIEkvTyBjb21wbGV0aW9uIChlLmcuLCBmaWxlIHN5c3RlbSBtb3VudHMpIGFuZCB0"
    "bwogKiAgIHByb3ZpZGUgbG93IGxhdGVuY3kgZm9yIGludGVyYWN0aXZlIGFwcGxpY2F0aW9ucy4KICogLSBJbXBsZW1lbnRhdGlvbjogVGhlIGRlYWRsaW5l"
    "IGZvciB0aGVzZSByZXF1ZXN0cyBpcyBzZXQgdG8gdGhlaXIgc3RhcnQKICogICB0aW1lIChgcnEtPnN0YXJ0X3RpbWVfbnNgKS4gVGhpcyBlZmZlY3RpdmVs"
    "eSBlbmZvcmNlcyBGSUZPLWxpa2UgYmVoYXZpb3IKICogICB3aXRoaW4gdGhlIGRlYWRsaW5lLXNvcnRlZCByZWQtYmxhY2sgdHJlZSwgcHJldmVudGluZyBv"
    "dXQtb2Ytb3JkZXIKICogICBleGVjdXRpb24gb2YgZGVwZW5kZW50IHN5bmNocm9ub3VzIG9wZXJhdGlvbnMuCiAqCiAqIFRpZXIgMiAoTm9ybWFsIFByaW9y"
    "aXR5KTogQmFja2dyb3VuZCBUaHJvdWdocHV0CiAqIC0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tLS0tCiAqIC0gVGFyZ2V0"
    "OiBBc3luY2hyb25vdXMgcmVxdWVzdHMuCiAqIC0gUHVycG9zZTogVG8gbWF4aW1pemUgZGlzayB0aHJvdWdocHV0IGZvciBiYWNrZ3JvdW5kIHRhc2tzIHdo"
    "ZXJlIGxhdGVuY3kKICogICBpcyBub3QgY3JpdGljYWwuCiAqIC0gSW1wbGVtZW50YXRpb246IFRoZXNlIGFyZSB0aGUgb25seSByZXF1ZXN0cyB3aGVyZSBB"
    "RElPUydzIGFkYXB0aXZlCiAqICAgbGF0ZW5jeSBwcmVkaWN0aW9uIG1vZGVsIGlzIHVzZWQuIEEgZHluYW1pYyBkZWFkbGluZSBpcyBjYWxjdWxhdGVkIGJh"
    "c2VkCiAqICAgb24gdGhlIHByZWRpY3RlZCBJL08gbGF0ZW5jeSwgYWxsb3dpbmcgZm9yIGFnZ3Jlc3NpdmUgcmVvcmRlcmluZyB0bwogKiAgIG9wdGltaXpl"
    "IEkvTyBlZmZpY2llbmN5LgogKgogKiBJL08gYmFycmllciBndWFyYW50ZWVzIChSRVFfUFJFRkxVU0ggLyBSRVFfRlVBKSBhcmUgcHJvdmlkZWQgZW50aXJl"
    "bHkgYnkKICogdGhlIGJsb2NrIGxheWVyJ3MgZmx1c2ggc3RhdGUgbWFjaGluZSAoYmxvY2svYmxrLWZsdXNoLmMpLCB3aGljaCBpcyB0aGUKICogbWVjaGFu"
    "aXNtIHRoYXQgcmVwbGFjZWQgd2hvbGUtcXVldWUgYmFycmllcnMgdXBzdHJlYW0gaW4gMi42LjM3LiBObwogKiBxdWV1ZS13aWRlIGJhcnJpZXIgaXMgaW1w"
    "bGVtZW50ZWQgb3IgbmVlZGVkIGhlcmU6CiAqIC0gYmxrX2luc2VydF9mbHVzaCgpIGFsd2F5cyBzdHJpcHMgUkVRX1BSRUZMVVNIIChhbmQgUkVRX0ZVQSB1"
    "bmxlc3MgdGhlCiAqICAgZGV2aWNlIHN1cHBvcnRzIGl0IGluIGhhcmR3YXJlKSBiZWZvcmUgYW55IHJlcXVlc3QgZXZlciByZWFjaGVzIHRoaXMKICogICBl"
    "bGV2YXRvcidzIC0+aW5zZXJ0X3JlcXVlc3RzKCksIGFuZCBhbHdheXMgc2V0cyBSRVFfU1lOQyBvbiBpdCwgc28gc3VjaAogKiAgIGEgcmVxdWVzdCBsYW5k"
    "cyBpbiBUaWVyIDEgKGltbWVkaWF0ZSBkZWFkbGluZSkgbGlrZSBhbnkgb3RoZXIKICogICBzeW5jaHJvbm91cyByZXF1ZXN0IC0tIG5ldmVyIGRlbGF5ZWQg"
    "YmVoaW5kIFRpZXIgMiByZW9yZGVyaW5nLgogKiAtIFRoZSBkYXRhIHBvcnRpb24gb2YgYSByZXF1ZXN0IHRoYXQgbmVlZGVkIGFuIGFjdHVhbCBQUkVGTFVT"
    "SCBpcwogKiAgIHJlc3VibWl0dGVkIHZpYSBCTEtfTVFfSU5TRVJUX0FUX0hFQUQgb25jZSB0aGUgZmx1c2ggY29tcGxldGVzLCB3aGljaAogKiAgIGxhbmRz"
    "IGluIFRpZXIgMCBoZXJlLCBhaGVhZCBvZiBldmVyeXRoaW5nIGVsc2UuCiAqIC0gUkVRX1BSRUZMVVNIL1JFUV9GVUEgYW5kIFJRRl9GTFVTSF9TRVEgcmVx"
    "dWVzdHMgYXJlIGFscmVhZHkgZXhjbHVkZWQKICogICBmcm9tIGJpby9yZXF1ZXN0IG1lcmdpbmcgYnkgdGhlIGdlbmVyaWMgYmxvY2sgbGF5ZXIgKHJxX21l"
    "cmdlYWJsZSgpLAogKiAgIGJsa19ycV9tZXJnZV9vaygpKSBiZWZvcmUgdGhpcyBlbGV2YXRvcidzIG1lcmdlIGNhbGxiYWNrcyBldmVyIHJ1bi4KICogLSBU"
    "aGUgc3ludGhlc2l6ZWQgcHVyZSBSRVFfT1BfRkxVU0ggY29tbWFuZCBpdHNlbGYgYWx3YXlzIGJ5cGFzc2VzIHRoaXMKICogICBlbGV2YXRvciBlbnRpcmVs"
    "eSAoYmxrX21xX2luc2VydF9yZXF1ZXN0KCkgcm91dGVzIGl0IHN0cmFpZ2h0IHRvCiAqICAgaGN0eC0+ZGlzcGF0Y2gpLCBzbyBpdCBuZXZlciBuZWVkcyB0"
    "byBiZSByZWNvZ25pemVkIG9yIGhhbmRsZWQgaGVyZS4KICoKICogRGlzcGF0Y2ggTG9naWM6CiAqIFRoZSBzY2hlZHVsZXIgYWx3YXlzIGRpc3BhdGNoZXMg"
    "cmVxdWVzdHMgaW4gc3RyaWN0IHByaW9yaXR5IG9yZGVyOgogKiAxLiBwcmlvX3F1ZXVlWzBdIChUaWVyIDApCiAqIDIuIFRoZSBkZWFkbGluZS1zb3J0ZWQg"
    "YmF0Y2ggcXVldWUgKHdoaWNoIG5hdHVyYWxseSBwcmlvcml0aXplcyBUaWVyIDEKICogICAgb3ZlciBUaWVyIDIgZHVlIHRvIHRoZWlyIGNhbGN1bGF0ZWQg"
    "ZGVhZGxpbmVzKS4KICovCgovLyBHbG9iYWwgdmFyaWFibGUgdG8gY29udHJvbCB0aGUgbGF0ZW5jeQpzdGF0aWMgdTY0IGRlZmF1bHRfZ2xvYmFsX2xhdGVu"
    "Y3lfd2luZG93ICAgICAgICAgICAgPSAxNjAwMDAwMFVMTDsKc3RhdGljIHU2NCBkZWZhdWx0X2dsb2JhbF9sYXRlbmN5X3dpbmRvd19yb3RhdGlvbmFsID0g"
    "MjIwMDAwMDBVTEw7Ci8vIFJhdGlvIGJlbG93IHdoaWNoIGJhdGNoIHF1ZXVlcyBzaG91bGQgYmUgcmVmaWxsZWQKc3RhdGljIHU4ICBkZWZhdWx0X2JxX3Jl"
    "ZmlsbF9iZWxvd19yYXRpbyA9IDIwOwovLyBNYXhpbXVtIGxhdGVuY3kgc2FtcGxlIHRvIGlucHV0CnN0YXRpYyB1NjQgZGVmYXVsdF9sYXRfbW9kZWxfbGF0"
    "ZW5jeV9saW1pdCA9IDUwMCAqIE5TRUNfUEVSX01TRUM7Ci8vIEJhdGNoIG9yZGVyaW5nIHN0cmF0ZWd5CnN0YXRpYyB1NjQgZGVmYXVsdF9iYXRjaF9vcmRl"
    "ciA9IDA7CgovKiBDb21wbGlhbmNlIEZsYWdzOgogKiAweDE6IEFzeW5jIHJlcXVlc3RzIHdpbGwgbm90IGJlIHJlb3JkZXJlZCBiYXNlZCBvbiB0aGUgcHJl"
    "ZGljdGVkIGxhdGVuY3kKICovCmVudW0gYWRpb3NfY29tcGxpYW5jZV9mbGFncyB7CglBRElPU19DRl9GSVhPUkRFUiAgPSAxVSA8PCAwLAp9OwoKLy8gRmxh"
    "Z3MgdG8gY29udHJvbCBjb21wbGlhbmNlIHdpdGggYmxvY2sgbGF5ZXIgY29uc3RyYWludHMKc3RhdGljIHU2NCBkZWZhdWx0X2NvbXBsaWFuY2VfZmxhZ3Mg"
    "PSAweDA7CgovLyBEeW5hbWljIHRocmVzaG9sZHMgZm9yIHNocmlua2FnZQpzdGF0aWMgdTMyIGRlZmF1bHRfbG1fc2hyaW5rX2F0X2tyZXFzICA9ICA1MDAw"
    "OwpzdGF0aWMgdTMyIGRlZmF1bHRfbG1fc2hyaW5rX2F0X2dieXRlcyA9ICAgIDUwOwpzdGF0aWMgdTMyIGRlZmF1bHRfbG1fc2hyaW5rX3Jlc2lzdCAgICA9"
    "ICAgICAyOwoKZW51bSBhZGlvc19vcHR5cGUgewoJQURJT1NfUkVBRCAgICA9IDAsCglBRElPU19XUklURSAgID0gMSwKCUFESU9TX0RJU0NBUkQgPSAyLAoJ"
    "QURJT1NfT1RIRVIgICA9IDMsCglBRElPU19PUFRZUEVTID0gNCwKfTsKCi8vIExhdGVuY3kgdGFyZ2V0cyBmb3IgZWFjaCBvcGVyYXRpb24gdHlwZQpzdGF0"
    "aWMgdTY0IGRlZmF1bHRfbGF0ZW5jeV90YXJnZXRbQURJT1NfT1BUWVBFU10gPSB7CglbQURJT1NfUkVBRF0gICAgPSAgICAgMlVMTCAqIE5TRUNfUEVSX01T"
    "RUMsCglbQURJT1NfV1JJVEVdICAgPSAgMjAwMFVMTCAqIE5TRUNfUEVSX01TRUMsCglbQURJT1NfRElTQ0FSRF0gPSAgODAwMFVMTCAqIE5TRUNfUEVSX01T"
    "RUMsCglbQURJT1NfT1RIRVJdICAgPSAgICAgMFVMTCAqIE5TRUNfUEVSX01TRUMsCn07CgovLyBNYXhpbXVtIGJhdGNoIHNpemUgbGltaXRzIGZvciBlYWNo"
    "IG9wZXJhdGlvbiB0eXBlCnN0YXRpYyB1MzIgZGVmYXVsdF9iYXRjaF9saW1pdFtBRElPU19PUFRZUEVTXSA9IHsKCVtBRElPU19SRUFEXSAgICA9IDM2LAoJ"
    "W0FESU9TX1dSSVRFXSAgID0gNzIsCglbQURJT1NfRElTQ0FSRF0gPSAgMSwKCVtBRElPU19PVEhFUl0gICA9ICAxLAp9OwoKZW51bSBhZGlvc19iYXRjaF9v"
    "cmRlciB7CglBRElPU19CT19PUFRZUEUgICA9IDAsCglBRElPU19CT19FTEVWQVRPUiA9IDEsCn07CgovLyBUaHJlc2hvbGRzIGZvciBsYXRlbmN5IG1vZGVs"
    "IGNvbnRyb2wKI2RlZmluZSBMTV9CTE9DS19TSVpFX1RIUkVTSE9MRCA0MDk2CiNkZWZpbmUgTE1fU0FNUExFU19USFJFU0hPTEQgICAgMTAyNAojZGVmaW5l"
    "IExNX0lOVEVSVkFMX1RIUkVTSE9MRCAgIDE1MDAKI2RlZmluZSBMTV9PVVRMSUVSX1BFUkNFTlRJTEUgICAgIDk5CiNkZWZpbmUgTE1fTEFUX0JVQ0tFVF9D"
    "T1VOVCAgICAgICA2NAoKI2RlZmluZSBBRElPU19QUV9MRVZFTFMgMgojZGVmaW5lIEFESU9TX0RMX1RZUEVTICAyCiNkZWZpbmUgQURJT1NfQlFfUEFHRVMg"
    "IDIKCnN0YXRpYyB1MzIgZGVmYXVsdF9kbF9wcmlvW0FESU9TX0RMX1RZUEVTXSA9IHs4LCAwfTsKCi8vIEJpdCBmbGFncyBmb3IgdGhlIGF0b21pYyBzdGF0"
    "ZSB2YXJpYWJsZSwgaW5kaWNhdGluZyB3aGljaCBxdWV1ZXMgaGF2ZSByZXF1ZXN0cy4KZW51bSBhZGlvc19zdGF0ZV9mbGFncyB7CglBRElPU19TVEFURV9Q"
    "UV8wICAgICAgPSAxVSA8PCAwLAoJQURJT1NfU1RBVEVfUFFfMSAgICAgID0gMVUgPDwgMSwKCUFESU9TX1NUQVRFX0RMXzAgICAgICA9IDFVIDw8IDIsCglB"
    "RElPU19TVEFURV9ETF8xICAgICAgPSAxVSA8PCAzLAoJQURJT1NfU1RBVEVfQlFfUEFHRV8wID0gMVUgPDwgNCwKCUFESU9TX1NUQVRFX0JRX1BBR0VfMSA9"
    "IDFVIDw8IDUsCn07CiNkZWZpbmUgQURJT1NfU1RBVEVfUFEgMAojZGVmaW5lIEFESU9TX1NUQVRFX0RMIDIKI2RlZmluZSBBRElPU19TVEFURV9CUSA0Cgov"
    "LyBUZW1wb3JhbCBncmFudWxhcml0eSBvZiB0aGUgZGVhZGxpbmUgdHJlZSBub2RlIChkbF9ncm91cCkKI2RlZmluZSBBRElPU19RVUFOVFVNX1NISUZUIDIw"
    "CgojZGVmaW5lIEFESU9TX01BWF9JTlNFUlRTX1BFUl9MT0NLIDcyCiNkZWZpbmUgQURJT1NfTUFYX0RFTEVURVNfUEVSX0xPQ0sgMjQKCi8vIFN0cnVjdHVy"
    "ZSB0byBob2xkIGxhdGVuY3kgYnVja2V0IGRhdGEgZm9yIHNtYWxsIHJlcXVlc3RzCnN0cnVjdCBsYXRlbmN5X2J1Y2tldF9zbWFsbCB7Cgl1NjQgd2VpZ2h0"
    "ZWRfc3VtX2xhdGVuY3k7Cgl1NjQgc3VtX29mX3dlaWdodHM7Cn07CgovLyBTdHJ1Y3R1cmUgdG8gaG9sZCBsYXRlbmN5IGJ1Y2tldCBkYXRhIGZvciBsYXJn"
    "ZSByZXF1ZXN0cwpzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfbGFyZ2UgewoJdTY0IHdlaWdodGVkX3N1bV9sYXRlbmN5OwoJdTY0IHdlaWdodGVkX3N1bV9ibG9j"
    "a19zaXplOwoJdTY0IHN1bV9vZl93ZWlnaHRzOwp9OwoKLy8gU3RydWN0dXJlIHRvIGhvbGQgcGVyLWNwdSBidWNrZXRzLCBpbXByb3ZpbmcgZGF0YSBsb2Nh"
    "bGl0eSBhbmQgY29kZSBjbGFyaXR5LgpzdHJ1Y3QgbG1fYnVja2V0cyB7CglzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfc21hbGwgc21hbGxfYnVja2V0W0xNX0xB"
    "VF9CVUNLRVRfQ09VTlRdOwoJc3RydWN0IGxhdGVuY3lfYnVja2V0X2xhcmdlIGxhcmdlX2J1Y2tldFtMTV9MQVRfQlVDS0VUX0NPVU5UXTsKfTsKCi8vIFN0"
    "cnVjdHVyZSB0byBob2xkIFJDVS1wcm90ZWN0ZWQgbGF0ZW5jeSBtb2RlbCBwYXJhbWV0ZXJzCnN0cnVjdCBsYXRlbmN5X21vZGVsX3BhcmFtcyB7Cgl1NjQg"
    "YmFzZTsKCXU2NCBzbG9wZTsKCXU2NCBzbWFsbF9zdW1fZGVsYXk7Cgl1NjQgc21hbGxfY291bnQ7Cgl1NjQgbGFyZ2Vfc3VtX2RlbGF5OwoJdTY0IGxhcmdl"
    "X3N1bV9ic2l6ZTsKCXU2NCBsYXN0X3VwZGF0ZV9qaWZmaWVzOwoJc3RydWN0IHJjdV9oZWFkIHJjdTsKfTsKCi8vIFN0cnVjdHVyZSB0byBob2xkIHRoZSBs"
    "YXRlbmN5IG1vZGVsIGNvbnRleHQgZGF0YQpzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCB7CglzcGlubG9ja190IHVwZGF0ZV9sb2NrOwoJc3RydWN0IGxhdGVuY3lf"
    "bW9kZWxfcGFyYW1zIF9fcmN1ICpwYXJhbXM7CgoJLy8gUGVyLUNQVSBidWNrZXRzIHRvIGF2b2lkIGxvY2sgY29udGVudGlvbiBvbiB0aGUgY29tcGxldGlv"
    "biBwYXRoCglzdHJ1Y3QgbG1fYnVja2V0cyBfX3BlcmNwdSAqcGNwdV9idWNrZXRzOwoJLy8gUGVyLUNQVSBzbmFwc2hvdHMgZm9yIGRlbHRhLWJhc2VkIGFn"
    "Z3JlZ2F0aW9uIChhY2Nlc3NlZCB1bmRlciB1cGRhdGVfbG9jaykKCXN0cnVjdCBsbV9idWNrZXRzIF9fcGVyY3B1ICpwY3B1X3NuYXBzaG90OwoKCXUzMiBs"
    "bV9zaHJpbmtfYXRfa3JlcXM7Cgl1MzIgbG1fc2hyaW5rX2F0X2dieXRlczsKCXU4ICBsbV9zaHJpbmtfcmVzaXN0Owp9OwoKc3RydWN0IGFkaW9zX3BjcHVf"
    "Y29tcGxldGlvbiB7Cgl1NjQgICAgICBsYXN0X2NvbXBsZXRlZF90aW1lOwoJc2VjdG9yX3QgbGFzdF9jb21wbGV0ZWRfcG9zOwp9OwoKdW5pb24gYWRpb3Nf"
    "aW5fZmxpZ2h0X3JxcyB7CglhdG9taWM2NF90CWF0b21pYzsKCXU2NAkJCXNjYWxhcjsKCXN0cnVjdCB7CgkJdTY0IAljb3VudDogICAgICAgICAgMTY7CgkJ"
    "dTY0IAl0b3RhbF9wcmVkX2xhdDogNDg7Cgl9Owp9OwoKLy8gQWRpb3Mgc2NoZWR1bGVyIGRhdGEKc3RydWN0IGFkaW9zX2RhdGEgewoJc3BpbmxvY2tfdCBw"
    "cV9sb2NrOwoJc3RydWN0IGxpc3RfaGVhZCBwcmlvX3F1ZXVlWzJdOwoKCXN0cnVjdCByYl9yb290X2NhY2hlZCBkbF90cmVlWzJdOwoJc3BpbmxvY2tfdCBs"
    "b2NrOwoJczY0IGRsX2JpYXM7CglzMzIgZGxfcHJpb1syXTsKCglhdG9taWNfdCBzdGF0ZTsKCXU4ICBicV9zdGF0ZVtBRElPU19CUV9QQUdFU107CgoJYm9v"
    "bCBtb2RlbHNfc3RhYmxlOwoKCXU2NCBnbG9iYWxfbGF0ZW5jeV93aW5kb3c7Cgl1NjQgY29tcGxpYW5jZV9mbGFnczsKCXU2NCBsYXRlbmN5X3RhcmdldFtB"
    "RElPU19PUFRZUEVTXTsKCXUzMiBiYXRjaF9saW1pdFtBRElPU19PUFRZUEVTXTsKCXUzMiBiYXRjaF9hY3R1YWxfbWF4X3NpemVbQURJT1NfT1BUWVBFU107"
    "Cgl1MzIgYmF0Y2hfYWN0dWFsX21heF90b3RhbDsKCXUzMiBhc3luY19kZXB0aDsKCXUzMiBsYXRfbW9kZWxfbGF0ZW5jeV9saW1pdDsKCXU4ICBicV9yZWZp"
    "bGxfYmVsb3dfcmF0aW87Cgl1OCAgaXNfcm90YXRpb25hbDsKCXU4ICBiYXRjaF9vcmRlcjsKCXU4ICBlbHZfZGlyZWN0aW9uOwoJc2VjdG9yX3QgaGVhZF9w"
    "b3M7CgoJYm9vbCBicV9wYWdlOwoJc3RydWN0IGxpc3RfaGVhZCBiYXRjaF9xdWV1ZVtBRElPU19CUV9QQUdFU11bQURJT1NfT1BUWVBFU107Cgl1MzIgYmF0"
    "Y2hfY291bnRbQURJT1NfQlFfUEFHRVNdW0FESU9TX09QVFlQRVNdOwoJdTggIGJxX2JhdGNoX29yZGVyW0FESU9TX0JRX1BBR0VTXTsKCXNwaW5sb2NrX3Qg"
    "YnFfbG9jazsKCglzdHJ1Y3QgbG1fYnVja2V0cyAqYWdncl9idWNrZXRzOwoKCXN0cnVjdCBsYXRlbmN5X21vZGVsIGxhdGVuY3lfbW9kZWxbQURJT1NfT1BU"
    "WVBFU107CglzdHJ1Y3QgdGltZXJfbGlzdCB1cGRhdGVfdGltZXI7CgoJdW5pb24gYWRpb3NfaW5fZmxpZ2h0X3JxcyBpbl9mbGlnaHRfcnFzOwoJYXRvbWlj"
    "NjRfdCB0b3RhbF9wcmVkX2xhdDsKCglzdHJ1Y3QgYWRpb3NfcGNwdV9jb21wbGV0aW9uIF9fcGVyY3B1ICpwY3B1X2NvbXBsZXRpb247CgoJc3RydWN0IGtt"
    "ZW1fY2FjaGUgKnJxX2RhdGFfY2FjaGU7CgltZW1wb29sX3QgKnJxX2RhdGFfcG9vbDsKCXN0cnVjdCBrbWVtX2NhY2hlICpkbF9ncm91cF9wb29sOwoKCXN0"
    "cnVjdCByZXF1ZXN0X3F1ZXVlICpxdWV1ZTsKfTsKCi8vIExpc3Qgb2YgcmVxdWVzdHMgd2l0aCB0aGUgc2FtZSBkZWFkbGluZSBpbiB0aGUgZGVhZGxpbmUt"
    "c29ydGVkIHRyZWUKc3RydWN0IGRsX2dyb3VwIHsKCXN0cnVjdCByYl9ub2RlIG5vZGU7CglzdHJ1Y3QgbGlzdF9oZWFkIHJxczsKCXU2NCBkZWFkbGluZTsK"
    "fSBfX2F0dHJpYnV0ZV9fKChhbGlnbmVkKDY0KSkpOwoKLy8gU3RydWN0dXJlIHRvIGhvbGQgc2NoZWR1bGVyLXNwZWNpZmljIGRhdGEgZm9yIGVhY2ggcmVx"
    "dWVzdApzdHJ1Y3QgYWRpb3NfcnFfZGF0YSB7CglzdHJ1Y3QgbGlzdF9oZWFkICpkbF9ncm91cDsKCXN0cnVjdCBsaXN0X2hlYWQgZGxfbm9kZTsKCglzdHJ1"
    "Y3QgcmVxdWVzdCAqcnE7Cgl1NjQgZGVhZGxpbmU7Cgl1NjQgcHJlZF9sYXQ7Cgl1MzIgYmxvY2tfc2l6ZTsKCWJvb2wgbWFuYWdlZDsKfSBfX2F0dHJpYnV0"
    "ZV9fKChhbGlnbmVkKDY0KSkpOwoKc3RhdGljIGNvbnN0IGludCBhZGlvc19wcmlvX3RvX3dtdWx0WzQwXSA9IHsKIC8qIC0yMCAqLyAgICAgODg3NjEsICAg"
    "ICA3MTc1NSwgICAgIDU2NDgzLCAgICAgNDYyNzMsICAgICAzNjI5MSwKIC8qIC0xNSAqLyAgICAgMjkxNTQsICAgICAyMzI1NCwgICAgIDE4NzA1LCAgICAg"
    "MTQ5NDksICAgICAxMTkxNiwKIC8qIC0xMCAqLyAgICAgIDk1NDgsICAgICAgNzYyMCwgICAgICA2MTAwLCAgICAgIDQ5MDQsICAgICAgMzkwNiwKIC8qICAt"
    "NSAqLyAgICAgIDMxMjEsICAgICAgMjUwMSwgICAgICAxOTkxLCAgICAgIDE1ODYsICAgICAgMTI3NywKIC8qICAgMCAqLyAgICAgIDEwMjQsICAgICAgIDgy"
    "MCwgICAgICAgNjU1LCAgICAgICA1MjYsICAgICAgIDQyMywKIC8qICAgNSAqLyAgICAgICAzMzUsICAgICAgIDI3MiwgICAgICAgMjE1LCAgICAgICAxNzIs"
    "ICAgICAgIDEzNywKIC8qICAxMCAqLyAgICAgICAxMTAsICAgICAgICA4NywgICAgICAgIDcwLCAgICAgICAgNTYsICAgICAgICA0NSwKIC8qICAxNSAqLyAg"
    "ICAgICAgMzYsICAgICAgICAyOSwgICAgICAgIDIzLCAgICAgICAgMTgsICAgICAgICAxNSwKfTsKCnN0YXRpYyBpbmxpbmUgYm9vbCBjb21wbGlhbnQoc3Ry"
    "dWN0IGFkaW9zX2RhdGEgKmFkLCB1MzIgZmxhZykgewoJcmV0dXJuIGFkLT5jb21wbGlhbmNlX2ZsYWdzICYgZmxhZzsKfQoKLy8gQ291bnQgdGhlIG51bWJl"
    "ciBvZiBlbnRyaWVzIGluIGFnZ3JlZ2F0ZWQgc21hbGwgYnVja2V0cwpzdGF0aWMgdTY0IGxtX2NvdW50X3NtYWxsX2VudHJpZXMoc3RydWN0IGxhdGVuY3lf"
    "YnVja2V0X3NtYWxsICpidWNrZXRzKSB7Cgl1NjQgdG90YWxfd2VpZ2h0ID0gMDsKCWZvciAodTggaSA9IDA7IGkgPCBMTV9MQVRfQlVDS0VUX0NPVU5UOyBp"
    "KyspCgkJdG90YWxfd2VpZ2h0ICs9IGJ1Y2tldHNbaV0uc3VtX29mX3dlaWdodHM7CglyZXR1cm4gdG90YWxfd2VpZ2h0Owp9CgovLyBVcGRhdGUgdGhlIHNt"
    "YWxsIGJ1Y2tldHMgaW4gdGhlIGxhdGVuY3kgbW9kZWwgZnJvbSBhZ2dyZWdhdGVkIGRhdGEKc3RhdGljIGJvb2wgbG1fdXBkYXRlX3NtYWxsX2J1Y2tldHMo"
    "c3RydWN0IGxhdGVuY3lfbW9kZWwgKm1vZGVsLAoJCXN0cnVjdCBsYXRlbmN5X21vZGVsX3BhcmFtcyAqcGFyYW1zLAoJCXN0cnVjdCBsYXRlbmN5X2J1Y2tl"
    "dF9zbWFsbCAqYnVja2V0cywKCQl1NjQgdG90YWxfd2VpZ2h0LCBib29sIGNvdW50X2FsbCkgewoJdTY0IHN1bV9sYXRlbmN5ID0gMDsKCXU2NCBzdW1fd2Vp"
    "Z2h0ID0gMDsKCXU2NCBjdW11bGF0aXZlX3dlaWdodCA9IDAsIHRocmVzaG9sZF93ZWlnaHQgPSAwOwoJdTggIG91dGxpZXJfdGhyZXNob2xkX2J1Y2tldCA9"
    "IDA7Cgl1OCAgb3V0bGllcl9wZXJjZW50aWxlID0gTE1fT1VUTElFUl9QRVJDRU5USUxFOwoJdTggIHJlZHVjdGlvbjsKCglpZiAoY291bnRfYWxsKQoJCW91"
    "dGxpZXJfcGVyY2VudGlsZSA9IDEwMDsKCgkvLyBDYWxjdWxhdGUgdGhlIHRocmVzaG9sZCB3ZWlnaHQgZm9yIG91dGxpZXIgZGV0ZWN0aW9uCgl0aHJlc2hv"
    "bGRfd2VpZ2h0ID0gKHRvdGFsX3dlaWdodCAqIG91dGxpZXJfcGVyY2VudGlsZSkgLyAxMDA7CgoJLy8gSWRlbnRpZnkgdGhlIGJ1Y2tldCB0aGF0IGNvcnJl"
    "c3BvbmRzIHRvIHRoZSBvdXRsaWVyIHRocmVzaG9sZAoJZm9yICh1OCBpID0gMDsgaSA8IExNX0xBVF9CVUNLRVRfQ09VTlQ7IGkrKykgewoJCWN1bXVsYXRp"
    "dmVfd2VpZ2h0ICs9IGJ1Y2tldHNbaV0uc3VtX29mX3dlaWdodHM7CgkJaWYgKGN1bXVsYXRpdmVfd2VpZ2h0ID49IHRocmVzaG9sZF93ZWlnaHQpIHsKCQkJ"
    "b3V0bGllcl90aHJlc2hvbGRfYnVja2V0ID0gaTsKCQkJYnJlYWs7CgkJfQoJfQoKCS8vIENhbGN1bGF0ZSB0aGUgYXZlcmFnZSBsYXRlbmN5LCBleGNsdWRp"
    "bmcgb3V0bGllcnMKCWZvciAodTggaSA9IDA7IGkgPD0gb3V0bGllcl90aHJlc2hvbGRfYnVja2V0OyBpKyspIHsKCQlzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRf"
    "c21hbGwgKmJ1Y2tldCA9ICZidWNrZXRzW2ldOwoJCWlmIChpIDwgb3V0bGllcl90aHJlc2hvbGRfYnVja2V0KSB7CgkJCXN1bV9sYXRlbmN5ICs9IGJ1Y2tl"
    "dC0+d2VpZ2h0ZWRfc3VtX2xhdGVuY3k7CgkJCXN1bV93ZWlnaHQgKz0gYnVja2V0LT5zdW1fb2Zfd2VpZ2h0czsKCQl9IGVsc2UgewoJCQkvLyBUaGUgdGhy"
    "ZXNob2xkIGJ1Y2tldCdzIGNvbnRyaWJ1dGlvbiBpcyBwcm9wb3J0aW9uYWwKCQkJdTY0IHJlbWFpbmluZ193ZWlnaHQgPQoJCQkJdGhyZXNob2xkX3dlaWdo"
    "dCAtIChjdW11bGF0aXZlX3dlaWdodCAtIGJ1Y2tldC0+c3VtX29mX3dlaWdodHMpOwoJCQlpZiAoYnVja2V0LT5zdW1fb2Zfd2VpZ2h0cyA+IDApIHsKCQkJ"
    "CXN1bV9sYXRlbmN5ICs9IGRpdl91NjQoYnVja2V0LT53ZWlnaHRlZF9zdW1fbGF0ZW5jeSAqCgkJCQkJcmVtYWluaW5nX3dlaWdodCwgYnVja2V0LT5zdW1f"
    "b2Zfd2VpZ2h0cyk7CgkJCQlzdW1fd2VpZ2h0ICs9IHJlbWFpbmluZ193ZWlnaHQ7CgkJCX0KCQl9Cgl9CgoJLy8gU2hyaW5rIHRoZSBtb2RlbCBpZiBpdCBy"
    "ZWFjaGVzIGF0IHRoZSByZWFkanVzdG1lbnQgdGhyZXNob2xkCglpZiAocGFyYW1zLT5zbWFsbF9jb3VudCA+PSAxMDAwVUxMICogbW9kZWwtPmxtX3Nocmlu"
    "a19hdF9rcmVxcykgewoJCXJlZHVjdGlvbiA9IG1vZGVsLT5sbV9zaHJpbmtfcmVzaXN0OwoJCWlmIChwYXJhbXMtPnNtYWxsX2NvdW50ID4+IHJlZHVjdGlv"
    "bikgewoJCQlwYXJhbXMtPnNtYWxsX3N1bV9kZWxheSAtPSBwYXJhbXMtPnNtYWxsX3N1bV9kZWxheSA+PiByZWR1Y3Rpb247CgkJCXBhcmFtcy0+c21hbGxf"
    "Y291bnQgICAgIC09IHBhcmFtcy0+c21hbGxfY291bnQgICAgID4+IHJlZHVjdGlvbjsKCQl9Cgl9CgoJaWYgKCFzdW1fd2VpZ2h0KQoJCXJldHVybiBmYWxz"
    "ZTsKCgkvLyBBY2N1bXVsYXRlIHRoZSBhdmVyYWdlIGxhdGVuY3kgaW50byB0aGUgc3RhdGlzdGljcwoJcGFyYW1zLT5zbWFsbF9zdW1fZGVsYXkgKz0gc3Vt"
    "X2xhdGVuY3k7CglwYXJhbXMtPnNtYWxsX2NvdW50ICAgICArPSBzdW1fd2VpZ2h0OwoKCXJldHVybiB0cnVlOwp9CgovLyBDb3VudCB0aGUgbnVtYmVyIG9m"
    "IGVudHJpZXMgaW4gYWdncmVnYXRlZCBsYXJnZSBidWNrZXRzCnN0YXRpYyB1NjQgbG1fY291bnRfbGFyZ2VfZW50cmllcyhzdHJ1Y3QgbGF0ZW5jeV9idWNr"
    "ZXRfbGFyZ2UgKmJ1Y2tldHMpIHsKCXU2NCB0b3RhbF93ZWlnaHQgPSAwOwoJZm9yICh1OCBpID0gMDsgaSA8IExNX0xBVF9CVUNLRVRfQ09VTlQ7IGkrKykK"
    "CQl0b3RhbF93ZWlnaHQgKz0gYnVja2V0c1tpXS5zdW1fb2Zfd2VpZ2h0czsKCXJldHVybiB0b3RhbF93ZWlnaHQ7Cn0KCi8vIFVwZGF0ZSB0aGUgbGFyZ2Ug"
    "YnVja2V0cyBpbiB0aGUgbGF0ZW5jeSBtb2RlbCBmcm9tIGFnZ3JlZ2F0ZWQgZGF0YQpzdGF0aWMgYm9vbCBsbV91cGRhdGVfbGFyZ2VfYnVja2V0cyhzdHJ1"
    "Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwsCgkJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXMsCgkJc3RydWN0IGxhdGVuY3lfYnVja2V0X2xh"
    "cmdlICpidWNrZXRzLAoJCXU2NCB0b3RhbF93ZWlnaHQsIGJvb2wgY291bnRfYWxsKSB7CglzNjQgc3VtX2xhdGVuY3kgPSAwOwoJdTY0IHN1bV9ibG9ja19z"
    "aXplID0gMCwgaW50ZXJjZXB0OwoJdTY0IGN1bXVsYXRpdmVfd2VpZ2h0ID0gMCwgdGhyZXNob2xkX3dlaWdodCA9IDA7Cgl1NjQgc3VtX3dlaWdodCA9IDA7"
    "Cgl1OCAgb3V0bGllcl90aHJlc2hvbGRfYnVja2V0ID0gMDsKCXU4ICBvdXRsaWVyX3BlcmNlbnRpbGUgPSBMTV9PVVRMSUVSX1BFUkNFTlRJTEU7Cgl1OCAg"
    "cmVkdWN0aW9uOwoKCWlmIChjb3VudF9hbGwpCgkJb3V0bGllcl9wZXJjZW50aWxlID0gMTAwOwoKCS8vIENhbGN1bGF0ZSB0aGUgdGhyZXNob2xkIHdlaWdo"
    "dCBmb3Igb3V0bGllciBkZXRlY3Rpb24KCXRocmVzaG9sZF93ZWlnaHQgPSAodG90YWxfd2VpZ2h0ICogb3V0bGllcl9wZXJjZW50aWxlKSAvIDEwMDsKCgkv"
    "LyBJZGVudGlmeSB0aGUgYnVja2V0IHRoYXQgY29ycmVzcG9uZHMgdG8gdGhlIG91dGxpZXIgdGhyZXNob2xkCglmb3IgKHU4IGkgPSAwOyBpIDwgTE1fTEFU"
    "X0JVQ0tFVF9DT1VOVDsgaSsrKSB7CgkJY3VtdWxhdGl2ZV93ZWlnaHQgKz0gYnVja2V0c1tpXS5zdW1fb2Zfd2VpZ2h0czsKCQlpZiAoY3VtdWxhdGl2ZV93"
    "ZWlnaHQgPj0gdGhyZXNob2xkX3dlaWdodCkgewoJCQlvdXRsaWVyX3RocmVzaG9sZF9idWNrZXQgPSBpOwoJCQlicmVhazsKCQl9Cgl9CgoJLy8gQ2FsY3Vs"
    "YXRlIHRoZSBhdmVyYWdlIGxhdGVuY3kgYW5kIGJsb2NrIHNpemUsIGV4Y2x1ZGluZyBvdXRsaWVycwoJZm9yICh1OCBpID0gMDsgaSA8PSBvdXRsaWVyX3Ro"
    "cmVzaG9sZF9idWNrZXQ7IGkrKykgewoJCXN0cnVjdCBsYXRlbmN5X2J1Y2tldF9sYXJnZSAqYnVja2V0ID0gJmJ1Y2tldHNbaV07CgkJaWYgKGkgPCBvdXRs"
    "aWVyX3RocmVzaG9sZF9idWNrZXQpIHsKCQkJc3VtX2xhdGVuY3kgKz0gYnVja2V0LT53ZWlnaHRlZF9zdW1fbGF0ZW5jeTsKCQkJc3VtX2Jsb2NrX3NpemUg"
    "Kz0gYnVja2V0LT53ZWlnaHRlZF9zdW1fYmxvY2tfc2l6ZTsKCQkJc3VtX3dlaWdodCArPSBidWNrZXQtPnN1bV9vZl93ZWlnaHRzOwoJCX0gZWxzZSB7CgkJ"
    "CS8vIFRoZSB0aHJlc2hvbGQgYnVja2V0J3MgY29udHJpYnV0aW9uIGlzIHByb3BvcnRpb25hbAoJCQl1NjQgcmVtYWluaW5nX3dlaWdodCA9CgkJCQl0aHJl"
    "c2hvbGRfd2VpZ2h0IC0gKGN1bXVsYXRpdmVfd2VpZ2h0IC0gYnVja2V0LT5zdW1fb2Zfd2VpZ2h0cyk7CgkJCWlmIChidWNrZXQtPnN1bV9vZl93ZWlnaHRz"
    "ID4gMCkgewoJCQkJc3VtX2xhdGVuY3kgKz0gZGl2X3U2NChidWNrZXQtPndlaWdodGVkX3N1bV9sYXRlbmN5ICoKCQkJCQlyZW1haW5pbmdfd2VpZ2h0LCBi"
    "dWNrZXQtPnN1bV9vZl93ZWlnaHRzKTsKCQkJCXN1bV9ibG9ja19zaXplICs9IGRpdl91NjQoYnVja2V0LT53ZWlnaHRlZF9zdW1fYmxvY2tfc2l6ZSAqCgkJ"
    "CQkJcmVtYWluaW5nX3dlaWdodCwgYnVja2V0LT5zdW1fb2Zfd2VpZ2h0cyk7CgkJCQlzdW1fd2VpZ2h0ICs9IHJlbWFpbmluZ193ZWlnaHQ7CgkJCX0KCQl9"
    "Cgl9CgoJaWYgKCFzdW1fd2VpZ2h0KQoJCXJldHVybiBmYWxzZTsKCgkvLyBTaHJpbmsgdGhlIG1vZGVsIGlmIGl0IHJlYWNoZXMgYXQgdGhlIHJlYWRqdXN0"
    "bWVudCB0aHJlc2hvbGQKCWlmIChwYXJhbXMtPmxhcmdlX3N1bV9ic2l6ZSA+PSAweDQwMDAwMDAwVUxMICogbW9kZWwtPmxtX3Nocmlua19hdF9nYnl0ZXMp"
    "IHsKCQlyZWR1Y3Rpb24gPSBtb2RlbC0+bG1fc2hyaW5rX3Jlc2lzdDsKCQlpZiAocGFyYW1zLT5sYXJnZV9zdW1fYnNpemUgPj4gcmVkdWN0aW9uKSB7CgkJ"
    "CXBhcmFtcy0+bGFyZ2Vfc3VtX2RlbGF5IC09IHBhcmFtcy0+bGFyZ2Vfc3VtX2RlbGF5ID4+IHJlZHVjdGlvbjsKCQkJcGFyYW1zLT5sYXJnZV9zdW1fYnNp"
    "emUgLT0gcGFyYW1zLT5sYXJnZV9zdW1fYnNpemUgPj4gcmVkdWN0aW9uOwoJCX0KCX0KCgkvLyBBY2N1bXVsYXRlIHRoZSBhdmVyYWdlIGRlbGF5IGludG8g"
    "dGhlIHN0YXRpc3RpY3MKCWludGVyY2VwdCA9IHBhcmFtcy0+YmFzZTsKCWlmIChzdW1fbGF0ZW5jeSA+IGludGVyY2VwdCkKCQlzdW1fbGF0ZW5jeSAtPSBp"
    "bnRlcmNlcHQ7CgoJcGFyYW1zLT5sYXJnZV9zdW1fZGVsYXkgKz0gc3VtX2xhdGVuY3k7CglwYXJhbXMtPmxhcmdlX3N1bV9ic2l6ZSArPSBzdW1fYmxvY2tf"
    "c2l6ZTsKCglyZXR1cm4gdHJ1ZTsKfQoKc3RhdGljIHZvaWQgcmVzZXRfYnVja2V0cyhzdHJ1Y3QgbG1fYnVja2V0cyAqYnVja2V0cykKeyBtZW1zZXQoYnVj"
    "a2V0cywgMCwgc2l6ZW9mKCpidWNrZXRzKSk7IH0KCnN0YXRpYyB2b2lkIGxtX3Jlc2V0X3BjcHVfYnVja2V0cyhzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9k"
    "ZWwpIHsKCWludCBjcHU7Cglmb3JfZWFjaF9wb3NzaWJsZV9jcHUoY3B1KSB7CgkJcmVzZXRfYnVja2V0cyhwZXJfY3B1X3B0cihtb2RlbC0+cGNwdV9idWNr"
    "ZXRzLCBjcHUpKTsKCQlyZXNldF9idWNrZXRzKHBlcl9jcHVfcHRyKG1vZGVsLT5wY3B1X3NuYXBzaG90LCBjcHUpKTsKCX0KfQoKLy8gVXBkYXRlIHRoZSBs"
    "YXRlbmN5IG1vZGVsIHBhcmFtZXRlcnMgYW5kIHN0YXRpc3RpY3MKc3RhdGljIHZvaWQgbGF0ZW5jeV9tb2RlbF91cGRhdGUoCgkJc3RydWN0IGFkaW9zX2Rh"
    "dGEgKmFkLCBzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwpIHsKCXU2NCBub3c7Cgl1NjQgc21hbGxfd2VpZ2h0LCBsYXJnZV93ZWlnaHQ7Cglib29sIHRp"
    "bWVfZWxhcHNlZDsKCWJvb2wgc21hbGxfcHJvY2Vzc2VkID0gZmFsc2UsIGxhcmdlX3Byb2Nlc3NlZCA9IGZhbHNlOwoJc3RydWN0IGxtX2J1Y2tldHMgKmFn"
    "Z3IgPSBhZC0+YWdncl9idWNrZXRzOwoJc3RydWN0IGxhdGVuY3lfYnVja2V0X3NtYWxsICphc2I7CglzdHJ1Y3QgbGF0ZW5jeV9idWNrZXRfbGFyZ2UgKmFs"
    "YjsKCXN0cnVjdCBsbV9idWNrZXRzICpwY3B1X2IsICpzbmFwOwoJdW5zaWduZWQgbG9uZyBmbGFnczsKCWludCBjcHU7CglzdHJ1Y3QgbGF0ZW5jeV9tb2Rl"
    "bF9wYXJhbXMgKm9sZF9wYXJhbXMsICpuZXdfcGFyYW1zOwoKCXNwaW5fbG9ja19pcnFzYXZlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsKCglvbGRf"
    "cGFyYW1zID0gcmN1X2RlcmVmZXJlbmNlX3Byb3RlY3RlZChtb2RlbC0+cGFyYW1zLAoJCQkJbG9ja2RlcF9pc19oZWxkKCZtb2RlbC0+dXBkYXRlX2xvY2sp"
    "KTsKCW5ld19wYXJhbXMgPSBrbWVtZHVwKG9sZF9wYXJhbXMsIHNpemVvZigqbmV3X3BhcmFtcyksIEdGUF9BVE9NSUMpOwoJaWYgKCFuZXdfcGFyYW1zKSB7"
    "CgkJc3Bpbl91bmxvY2tfaXJxcmVzdG9yZSgmbW9kZWwtPnVwZGF0ZV9sb2NrLCBmbGFncyk7CgkJcmV0dXJuOwoJfQoKCS8vIEFnZ3JlZ2F0ZSBkZWx0YXMg"
    "ZnJvbSBhbGwgQ1BVcyB1c2luZyBzbmFwc2hvdC1kZWx0YSBtZXRob2QuCgkvLyBQZXItQ1BVIGNvdW50ZXJzIGluY3JlYXNlIG1vbm90b25pY2FsbHk7IHdl"
    "IGNvbXB1dGUgZGVsdGEgPSBjdXJyZW50IC0gc25hcHNob3QuCglmb3JfZWFjaF9wb3NzaWJsZV9jcHUoY3B1KSB7CgkJcGNwdV9iID0gcGVyX2NwdV9wdHIo"
    "bW9kZWwtPnBjcHVfYnVja2V0cywgY3B1KTsKCQlzbmFwICAgPSBwZXJfY3B1X3B0cihtb2RlbC0+cGNwdV9zbmFwc2hvdCwgY3B1KTsKCgkJZm9yICh1OCBp"
    "ID0gMDsgaSA8IExNX0xBVF9CVUNLRVRfQ09VTlQ7IGkrKykgewoJCQl1NjQgc3cgID0gcGNwdV9iLT5zbWFsbF9idWNrZXRbaV0uc3VtX29mX3dlaWdodHM7"
    "CgkJCXU2NCBzbCAgPSBwY3B1X2ItPnNtYWxsX2J1Y2tldFtpXS53ZWlnaHRlZF9zdW1fbGF0ZW5jeTsKCQkJdTY0IGRzdyA9IHN3IC0gc25hcC0+c21hbGxf"
    "YnVja2V0W2ldLnN1bV9vZl93ZWlnaHRzOwoJCQl1NjQgZHNsID0gc2wgLSBzbmFwLT5zbWFsbF9idWNrZXRbaV0ud2VpZ2h0ZWRfc3VtX2xhdGVuY3k7CgkJ"
    "CXNuYXAtPnNtYWxsX2J1Y2tldFtpXS5zdW1fb2Zfd2VpZ2h0cyA9IHN3OwoJCQlzbmFwLT5zbWFsbF9idWNrZXRbaV0ud2VpZ2h0ZWRfc3VtX2xhdGVuY3kg"
    "PSBzbDsKCQkJaWYgKGRzdykgewoJCQkJYXNiID0gJmFnZ3ItPnNtYWxsX2J1Y2tldFtpXTsKCQkJCWFzYi0+c3VtX29mX3dlaWdodHMgKz0gZHN3OwoJCQkJ"
    "YXNiLT53ZWlnaHRlZF9zdW1fbGF0ZW5jeSArPSBkc2w7CgkJCX0KCgkJCXU2NCBsdyAgPSBwY3B1X2ItPmxhcmdlX2J1Y2tldFtpXS5zdW1fb2Zfd2VpZ2h0"
    "czsKCQkJdTY0IGxsICA9IHBjcHVfYi0+bGFyZ2VfYnVja2V0W2ldLndlaWdodGVkX3N1bV9sYXRlbmN5OwoJCQl1NjQgbGIgID0gcGNwdV9iLT5sYXJnZV9i"
    "dWNrZXRbaV0ud2VpZ2h0ZWRfc3VtX2Jsb2NrX3NpemU7CgkJCXU2NCBkbHcgPSBsdyAtIHNuYXAtPmxhcmdlX2J1Y2tldFtpXS5zdW1fb2Zfd2VpZ2h0czsK"
    "CQkJdTY0IGRsbCA9IGxsIC0gc25hcC0+bGFyZ2VfYnVja2V0W2ldLndlaWdodGVkX3N1bV9sYXRlbmN5OwoJCQl1NjQgZGxiID0gbGIgLSBzbmFwLT5sYXJn"
    "ZV9idWNrZXRbaV0ud2VpZ2h0ZWRfc3VtX2Jsb2NrX3NpemU7CgkJCXNuYXAtPmxhcmdlX2J1Y2tldFtpXS5zdW1fb2Zfd2VpZ2h0cyA9IGx3OwoJCQlzbmFw"
    "LT5sYXJnZV9idWNrZXRbaV0ud2VpZ2h0ZWRfc3VtX2xhdGVuY3kgPSBsbDsKCQkJc25hcC0+bGFyZ2VfYnVja2V0W2ldLndlaWdodGVkX3N1bV9ibG9ja19z"
    "aXplID0gbGI7CgkJCWlmIChkbHcpIHsKCQkJCWFsYiA9ICZhZ2dyLT5sYXJnZV9idWNrZXRbaV07CgkJCQlhbGItPnN1bV9vZl93ZWlnaHRzICs9IGRsdzsK"
    "CQkJCWFsYi0+d2VpZ2h0ZWRfc3VtX2xhdGVuY3kgKz0gZGxsOwoJCQkJYWxiLT53ZWlnaHRlZF9zdW1fYmxvY2tfc2l6ZSArPSBkbGI7CgkJCX0KCQl9Cgl9"
    "CgoJLy8gQ291bnQgdGhlIG51bWJlciBvZiBlbnRyaWVzIGluIGFnZ3JlZ2F0ZWQgYnVja2V0cwoJc21hbGxfd2VpZ2h0ID0gbG1fY291bnRfc21hbGxfZW50"
    "cmllcyhhZ2dyLT5zbWFsbF9idWNrZXQpOwoJbGFyZ2Vfd2VpZ2h0ID0gbG1fY291bnRfbGFyZ2VfZW50cmllcyhhZ2dyLT5sYXJnZV9idWNrZXQpOwoKCS8v"
    "IFdoZXRoZXIgZW5vdWdoIHRpbWUgaGFzIGVsYXBzZWQgc2luY2UgdGhlIGxhc3QgdXBkYXRlCglub3cgPSBqaWZmaWVzOwoJdGltZV9lbGFwc2VkID0gdW5s"
    "aWtlbHkoIW5ld19wYXJhbXMtPmJhc2UpIHx8CgkJbmV3X3BhcmFtcy0+bGFzdF91cGRhdGVfamlmZmllcyArCgkJbXNlY3NfdG9famlmZmllcyhMTV9JTlRF"
    "UlZBTF9USFJFU0hPTEQpIDw9IG5vdzsKCgkvLyBVcGRhdGUgc21hbGwgYnVja2V0cwoJaWYgKHNtYWxsX3dlaWdodCAmJiAodGltZV9lbGFwc2VkIHx8CgkJ"
    "CUxNX1NBTVBMRVNfVEhSRVNIT0xEIDw9IHNtYWxsX3dlaWdodCB8fCAhbmV3X3BhcmFtcy0+YmFzZSkpIHsKCQlzbWFsbF9wcm9jZXNzZWQgPSBsbV91cGRh"
    "dGVfc21hbGxfYnVja2V0cyhtb2RlbCwgbmV3X3BhcmFtcywKCQkJYWdnci0+c21hbGxfYnVja2V0LCBzbWFsbF93ZWlnaHQsICFuZXdfcGFyYW1zLT5iYXNl"
    "KTsKCQltZW1zZXQoJmFnZ3ItPnNtYWxsX2J1Y2tldFswXSwgMCwgc2l6ZW9mKGFnZ3ItPnNtYWxsX2J1Y2tldCkpOwoJfQoJLy8gVXBkYXRlIGxhcmdlIGJ1"
    "Y2tldHMKCWlmIChsYXJnZV93ZWlnaHQgJiYgKHRpbWVfZWxhcHNlZCB8fAoJCQlMTV9TQU1QTEVTX1RIUkVTSE9MRCA8PSBsYXJnZV93ZWlnaHQgfHwgIW5l"
    "d19wYXJhbXMtPnNsb3BlKSkgewoJCWxhcmdlX3Byb2Nlc3NlZCA9IGxtX3VwZGF0ZV9sYXJnZV9idWNrZXRzKG1vZGVsLCBuZXdfcGFyYW1zLAoJCQlhZ2dy"
    "LT5sYXJnZV9idWNrZXQsIGxhcmdlX3dlaWdodCwgIW5ld19wYXJhbXMtPnNsb3BlKTsKCQltZW1zZXQoJmFnZ3ItPmxhcmdlX2J1Y2tldFswXSwgMCwgc2l6"
    "ZW9mKGFnZ3ItPmxhcmdlX2J1Y2tldCkpOwoJfQoKCS8vIFVwZGF0ZSB0aGUgYmFzZSBwYXJhbWV0ZXIgaWYgc21hbGwgYnVja2V0IHdhcyBwcm9jZXNzZWQK"
    "CWlmIChzbWFsbF9wcm9jZXNzZWQgJiYgbGlrZWx5KG5ld19wYXJhbXMtPnNtYWxsX2NvdW50KSkKCQluZXdfcGFyYW1zLT5iYXNlID0gZGl2X3U2NChuZXdf"
    "cGFyYW1zLT5zbWFsbF9zdW1fZGVsYXksCgkJCW5ld19wYXJhbXMtPnNtYWxsX2NvdW50KTsKCgkvLyBVcGRhdGUgdGhlIHNsb3BlIHBhcmFtZXRlciBpZiBs"
    "YXJnZSBidWNrZXQgd2FzIHByb2Nlc3NlZAoJaWYgKGxhcmdlX3Byb2Nlc3NlZCAmJiBsaWtlbHkobmV3X3BhcmFtcy0+bGFyZ2Vfc3VtX2JzaXplKSkKCQlu"
    "ZXdfcGFyYW1zLT5zbG9wZSA9IGRpdl91NjQobmV3X3BhcmFtcy0+bGFyZ2Vfc3VtX2RlbGF5LAoJCQlESVZfUk9VTkRfVVBfVUxMKG5ld19wYXJhbXMtPmxh"
    "cmdlX3N1bV9ic2l6ZSwgMTAyNCkpOwoKCS8vIFVwZGF0ZSBsYXN0IHVwZGF0ZWQgamlmZmllcyBpZiB1cGRhdGUgaGFwcGVuZWQgb3IgdGltZSBoYXMgZWxh"
    "cHNlZAoJaWYgKHNtYWxsX3Byb2Nlc3NlZCB8fCBsYXJnZV9wcm9jZXNzZWQgfHwgdGltZV9lbGFwc2VkKQoJCW5ld19wYXJhbXMtPmxhc3RfdXBkYXRlX2pp"
    "ZmZpZXMgPSBub3c7CgoJcmN1X2Fzc2lnbl9wb2ludGVyKG1vZGVsLT5wYXJhbXMsIG5ld19wYXJhbXMpOwoJc3Bpbl91bmxvY2tfaXJxcmVzdG9yZSgmbW9k"
    "ZWwtPnVwZGF0ZV9sb2NrLCBmbGFncyk7CgoJa2ZyZWVfcmN1KG9sZF9wYXJhbXMsIHJjdSk7Cn0KCi8vIERldGVybWluZSB0aGUgYnVja2V0IGluZGV4IGZv"
    "ciBhIGdpdmVuIG1lYXN1cmVkIGFuZCBwcmVkaWN0ZWQgbGF0ZW5jeQpzdGF0aWMgdTggbG1faW5wdXRfYnVja2V0X2luZGV4KHU2NCBtZWFzdXJlZCwgdTY0"
    "IHByZWRpY3RlZCkgewoJdTMyIGJ1Y2tldF9pbmRleDsKCglpZiAobWVhc3VyZWQgPCBwcmVkaWN0ZWQgKiAyKQoJCWJ1Y2tldF9pbmRleCA9IGRpdl91NjQo"
    "KG1lYXN1cmVkICogMjApLCBwcmVkaWN0ZWQpOwoJZWxzZSBpZiAobWVhc3VyZWQgPCBwcmVkaWN0ZWQgKiA1KQoJCWJ1Y2tldF9pbmRleCA9IGRpdl91NjQo"
    "KG1lYXN1cmVkICogMTApLCBwcmVkaWN0ZWQpICsgMjA7CgllbHNlCgkJYnVja2V0X2luZGV4ID0gZGl2X3U2NCgobWVhc3VyZWQgKiAzKSwgcHJlZGljdGVk"
    "KSArIDQwOwoKCWlmIChidWNrZXRfaW5kZXggPj0gTE1fTEFUX0JVQ0tFVF9DT1VOVCkKCQlidWNrZXRfaW5kZXggPSBMTV9MQVRfQlVDS0VUX0NPVU5UIC0g"
    "MTsKCglyZXR1cm4gKHU4KWJ1Y2tldF9pbmRleDsKfQoKLy8gSW5wdXQgbGF0ZW5jeSBkYXRhIGludG8gdGhlIGxhdGVuY3kgbW9kZWwKc3RhdGljIHZvaWQg"
    "bGF0ZW5jeV9tb2RlbF9pbnB1dChzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQsCgkJc3RydWN0IGxhdGVuY3lfbW9kZWwgKm1vZGVsLAoJCXUzMiBibG9ja19zaXpl"
    "LCB1NjQgbGF0ZW5jeSwgdTY0IHByZWRfbGF0LCB1MzIgd2VpZ2h0KSB7Cgl1bnNpZ25lZCBsb25nIGZsYWdzOwoJdTggYnVja2V0X2luZGV4OwoJc3RydWN0"
    "IGxtX2J1Y2tldHMgKmJ1Y2tldHM7Cgl1NjQgY3VycmVudF9iYXNlOwoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXM7CgoJbG9jYWxfaXJx"
    "X3NhdmUoZmxhZ3MpOwoJYnVja2V0cyA9IHBlcl9jcHVfcHRyKG1vZGVsLT5wY3B1X2J1Y2tldHMsIF9fc21wX3Byb2Nlc3Nvcl9pZCgpKTsKCglyY3VfcmVh"
    "ZF9sb2NrKCk7CglwYXJhbXMgPSByY3VfZGVyZWZlcmVuY2UobW9kZWwtPnBhcmFtcyk7CgljdXJyZW50X2Jhc2UgPSBwYXJhbXMtPmJhc2U7CglyY3VfcmVh"
    "ZF91bmxvY2soKTsKCglpZiAoYmxvY2tfc2l6ZSA8PSBMTV9CTE9DS19TSVpFX1RIUkVTSE9MRCkgewoJCS8vIEhhbmRsZSBzbWFsbCByZXF1ZXN0cwoJCWJ1"
    "Y2tldF9pbmRleCA9IGxtX2lucHV0X2J1Y2tldF9pbmRleChsYXRlbmN5LCBjdXJyZW50X2Jhc2UgPzogMSk7CgoJCWJ1Y2tldHMtPnNtYWxsX2J1Y2tldFti"
    "dWNrZXRfaW5kZXhdLnN1bV9vZl93ZWlnaHRzICs9IHdlaWdodDsKCQlidWNrZXRzLT5zbWFsbF9idWNrZXRbYnVja2V0X2luZGV4XS53ZWlnaHRlZF9zdW1f"
    "bGF0ZW5jeSArPQoJCQlsYXRlbmN5ICogd2VpZ2h0OwoKCQlsb2NhbF9pcnFfcmVzdG9yZShmbGFncyk7CgoJCWlmICh1bmxpa2VseSghY3VycmVudF9iYXNl"
    "KSkgewoJCQlsYXRlbmN5X21vZGVsX3VwZGF0ZShhZCwgbW9kZWwpOwoJCQlyZXR1cm47CgkJfQoJfSBlbHNlIHsKCQkvLyBIYW5kbGUgbGFyZ2UgcmVxdWVz"
    "dHMKCQlpZiAoIWN1cnJlbnRfYmFzZSB8fCAhcHJlZF9sYXQpIHsKCQkJbG9jYWxfaXJxX3Jlc3RvcmUoZmxhZ3MpOwoJCQlyZXR1cm47CgkJfQoKCQlidWNr"
    "ZXRfaW5kZXggPSBsbV9pbnB1dF9idWNrZXRfaW5kZXgobGF0ZW5jeSwgcHJlZF9sYXQpOwoKCQlidWNrZXRzLT5sYXJnZV9idWNrZXRbYnVja2V0X2luZGV4"
    "XS5zdW1fb2Zfd2VpZ2h0cyArPSB3ZWlnaHQ7CgkJYnVja2V0cy0+bGFyZ2VfYnVja2V0W2J1Y2tldF9pbmRleF0ud2VpZ2h0ZWRfc3VtX2xhdGVuY3kgKz0K"
    "CQkJbGF0ZW5jeSAqIHdlaWdodDsKCQlidWNrZXRzLT5sYXJnZV9idWNrZXRbYnVja2V0X2luZGV4XS53ZWlnaHRlZF9zdW1fYmxvY2tfc2l6ZSArPQoJCQli"
    "bG9ja19zaXplICogd2VpZ2h0OwoKCQlsb2NhbF9pcnFfcmVzdG9yZShmbGFncyk7Cgl9Cn0KCi8vIFByZWRpY3QgdGhlIGxhdGVuY3kgZm9yIGEgZ2l2ZW4g"
    "YmxvY2sgc2l6ZSB1c2luZyB0aGUgbGF0ZW5jeSBtb2RlbApzdGF0aWMgdTY0IGxhdGVuY3lfbW9kZWxfcHJlZGljdChzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAq"
    "bW9kZWwsIHUzMiBibG9ja19zaXplKSB7Cgl1NjQgcmVzdWx0OwoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXM7CgoJcmN1X3JlYWRfbG9j"
    "aygpOwoJcGFyYW1zID0gcmN1X2RlcmVmZXJlbmNlKG1vZGVsLT5wYXJhbXMpOwoKCXJlc3VsdCA9IHBhcmFtcy0+YmFzZTsKCWlmIChibG9ja19zaXplID4g"
    "TE1fQkxPQ0tfU0laRV9USFJFU0hPTEQpCgkJcmVzdWx0ICs9IHBhcmFtcy0+c2xvcGUgKgoJCQlESVZfUk9VTkRfVVBfVUxMKGJsb2NrX3NpemUgLSBMTV9C"
    "TE9DS19TSVpFX1RIUkVTSE9MRCwgMTAyNCk7CgoJcmN1X3JlYWRfdW5sb2NrKCk7CgoJcmV0dXJuIHJlc3VsdDsKfQoKLy8gRGV0ZXJtaW5lIHRoZSB0eXBl"
    "IG9mIG9wZXJhdGlvbiBiYXNlZCBvbiByZXF1ZXN0IGZsYWdzCnN0YXRpYyB1OCBhZGlvc19vcHR5cGUoc3RydWN0IHJlcXVlc3QgKnJxKSB7Cglzd2l0Y2gg"
    "KHJxLT5jbWRfZmxhZ3MgJiBSRVFfT1BfTUFTSykgewoJY2FzZSBSRVFfT1BfUkVBRDoKCQlyZXR1cm4gQURJT1NfUkVBRDsKCWNhc2UgUkVRX09QX1dSSVRF"
    "OgoJCXJldHVybiBBRElPU19XUklURTsKCWNhc2UgUkVRX09QX0RJU0NBUkQ6CgkJcmV0dXJuIEFESU9TX0RJU0NBUkQ7CglkZWZhdWx0OgoJCXJldHVybiBB"
    "RElPU19PVEhFUjsKCX0KfQoKc3RhdGljIGlubGluZSB1OCBhZGlvc19vcHR5cGVfbm90X3JlYWQoc3RydWN0IHJlcXVlc3QgKnJxKSB7CglyZXR1cm4gKHJx"
    "LT5jbWRfZmxhZ3MgJiBSRVFfT1BfTUFTSykgIT0gUkVRX09QX1JFQUQ7Cn0KCi8vIEhlbHBlciBmdW5jdGlvbiB0byByZXRyaWV2ZSBhZGlvc19ycV9kYXRh"
    "IGZyb20gYSByZXF1ZXN0CnN0YXRpYyBpbmxpbmUgc3RydWN0IGFkaW9zX3JxX2RhdGEgKmdldF9ycV9kYXRhKHN0cnVjdCByZXF1ZXN0ICpycSkgewoJcmV0"
    "dXJuIHJxLT5lbHYucHJpdlswXTsKfQoKc3RhdGljIGlubGluZQp2b2lkIHNldF9hZGlvc19zdGF0ZShzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQsIHUzMiBzaGlm"
    "dCwgdTMyIGlkeCwgYm9vbCBmbGFnKSB7CglpZiAoZmxhZykKCQlhdG9taWNfb3IoMVUgPDwgKGlkeCArIHNoaWZ0KSwgJmFkLT5zdGF0ZSk7CgllbHNlCgkJ"
    "YXRvbWljX2FuZG5vdCgxVSA8PCAoaWR4ICsgc2hpZnQpLCAmYWQtPnN0YXRlKTsKfQoKc3RhdGljIGlubGluZSB1MzIgZ2V0X2FkaW9zX3N0YXRlKHN0cnVj"
    "dCBhZGlvc19kYXRhICphZCkKeyByZXR1cm4gYXRvbWljX3JlYWQoJmFkLT5zdGF0ZSk7IH0KCnN0YXRpYyBpbmxpbmUgdTMyIGV2YWxfdGhpc19hZGlvc19z"
    "dGF0ZSh1MzIgc3RhdGUsIHUzMiBzaGlmdCkKeyByZXR1cm4gKHN0YXRlID4+IHNoaWZ0KSAmIDB4MzsgfQoKc3RhdGljIGlubGluZSB1MzIgZXZhbF9hZGlv"
    "c19zdGF0ZShzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQsIHUzMiBzaGlmdCkKeyByZXR1cm4gZXZhbF90aGlzX2FkaW9zX3N0YXRlKGdldF9hZGlvc19zdGF0ZShh"
    "ZCksIHNoaWZ0KTsgfQoKLy8gQWRkIGEgcmVxdWVzdCB0byB0aGUgZGVhZGxpbmUtc29ydGVkIHJlZC1ibGFjayB0cmVlCnN0YXRpYyB2b2lkIGFkZF90b19k"
    "bF90cmVlKAoJCXN0cnVjdCBhZGlvc19kYXRhICphZCwgYm9vbCBkbF9pZHgsIHN0cnVjdCByZXF1ZXN0ICpycSkgewoJc3RydWN0IHJiX3Jvb3RfY2FjaGVk"
    "ICpyb290ID0gJmFkLT5kbF90cmVlW2RsX2lkeF07CglzdHJ1Y3QgcmJfbm9kZSAqKmxpbmsgPSAmKHJvb3QtPnJiX3Jvb3QucmJfbm9kZSksICpwYXJlbnQg"
    "PSBOVUxMOwoJYm9vbCBsZWZ0bW9zdCA9IHRydWU7CglzdHJ1Y3QgYWRpb3NfcnFfZGF0YSAqcmQgPSBnZXRfcnFfZGF0YShycSk7CglzdHJ1Y3QgZGxfZ3Jv"
    "dXAgKmRsZzsKCXU2NCBkZWFkbGluZTsKCWJvb2wgd2FzX2VtcHR5ID0gUkJfRU1QVFlfUk9PVCgmcm9vdC0+cmJfcm9vdCk7CgoJLyogVGllci0yOiBTeW5j"
    "aHJvbm91cyBSZXF1ZXN0cwoJICogLSBOZWVkcyB0byBiZSBGSUZPIHdpdGhpbiBhIHNhbWUgb3B0eXBlCgkgKiAtIFJlbGF4ZWQgb3JkZXIgYmV0d2VlbiBk"
    "aWZmZXJlbnQgb3B0eXBlcwoJICogLSBiYXNpY2FsbHkgbmVlZHMgdG8gYmUgcHJvY2Vzc2VkIGluIGVhcmx5IHRpbWUgKi8KCXJkLT5kZWFkbGluZSA9IHJx"
    "LT5zdGFydF90aW1lX25zOwoKCS8qIFRpZXItMzogQXluY2hyb25vdXMgUmVxdWVzdHMKCSAqIC0gQ2FuIGJlIHJlb3JkZXJlZCBhbmQgZGVsYXllZCBmcmVl"
    "bHkgKi8KCWlmICghKHJxLT5jbWRfZmxhZ3MgJiBSRVFfU1lOQykpIHsKCQlyZC0+ZGVhZGxpbmUgKz0gYWQtPmxhdGVuY3lfdGFyZ2V0W2FkaW9zX29wdHlw"
    "ZShycSldOwoJCWlmICghY29tcGxpYW50KGFkLCBBRElPU19DRl9GSVhPUkRFUikpCgkJCXJkLT5kZWFkbGluZSArPSByZC0+cHJlZF9sYXQ7Cgl9CgoJLy8g"
    "Tm93IHF1YW50aXplIHRoZSBkZWFkbGluZSAoLT4gZGxnLT5kZWFkbGluZSA9PSBSQi1UcmVlIGtleSkKCWRlYWRsaW5lID0gcmQtPmRlYWRsaW5lICYgfigo"
    "MVVMTCA8PCBBRElPU19RVUFOVFVNX1NISUZUKSAtIDEpOwoKCXdoaWxlICgqbGluaykgewoJCWRsZyA9IHJiX2VudHJ5KCpsaW5rLCBzdHJ1Y3QgZGxfZ3Jv"
    "dXAsIG5vZGUpOwoJCXM2NCBkaWZmID0gZGVhZGxpbmUgLSBkbGctPmRlYWRsaW5lOwoKCQlwYXJlbnQgPSAqbGluazsKCQlpZiAoZGlmZiA8IDApIHsKCQkJ"
    "bGluayA9ICYoKCpsaW5rKS0+cmJfbGVmdCk7CgkJfSBlbHNlIGlmIChkaWZmID4gMCkgewoJCQlsaW5rID0gJigoKmxpbmspLT5yYl9yaWdodCk7CgkJCWxl"
    "ZnRtb3N0ID0gZmFsc2U7CgkJfSBlbHNlIHsgLy8gZGlmZiA9PSAwCgkJCWdvdG8gZm91bmQ7CgkJfQoJfQoKCWRsZyA9IHJiX2VudHJ5X3NhZmUocGFyZW50"
    "LCBzdHJ1Y3QgZGxfZ3JvdXAsIG5vZGUpOwoJaWYgKCFkbGcgfHwgZGxnLT5kZWFkbGluZSAhPSBkZWFkbGluZSkgewoJCWRsZyA9IGttZW1fY2FjaGVfemFs"
    "bG9jKGFkLT5kbF9ncm91cF9wb29sLCBHRlBfQVRPTUlDKTsKCQlpZiAoIWRsZykKCQkJcmV0dXJuOwoJCWRsZy0+ZGVhZGxpbmUgPSBkZWFkbGluZTsKCQlJ"
    "TklUX0xJU1RfSEVBRCgmZGxnLT5ycXMpOwoJCXJiX2xpbmtfbm9kZSgmZGxnLT5ub2RlLCBwYXJlbnQsIGxpbmspOwoJCXJiX2luc2VydF9jb2xvcl9jYWNo"
    "ZWQoJmRsZy0+bm9kZSwgcm9vdCwgbGVmdG1vc3QpOwoJfQpmb3VuZDoKCWxpc3RfYWRkX3RhaWwoJnJkLT5kbF9ub2RlLCAmZGxnLT5ycXMpOwoJcmQtPmRs"
    "X2dyb3VwID0gJmRsZy0+cnFzOwoKCWlmICh3YXNfZW1wdHkpCgkJc2V0X2FkaW9zX3N0YXRlKGFkLCBBRElPU19TVEFURV9ETCwgZGxfaWR4LCB0cnVlKTsK"
    "fQoKLy8gUmVtb3ZlIGEgcmVxdWVzdCBmcm9tIHRoZSBkZWFkbGluZS1zb3J0ZWQgcmVkLWJsYWNrIHRyZWUKc3RhdGljIHZvaWQgZGVsX2Zyb21fZGxfdHJl"
    "ZSgKCQlzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQsIGJvb2wgZGxfaWR4LCBzdHJ1Y3QgcmVxdWVzdCAqcnEpIHsKCXN0cnVjdCByYl9yb290X2NhY2hlZCAqcm9v"
    "dCA9ICZhZC0+ZGxfdHJlZVtkbF9pZHhdOwoJc3RydWN0IGFkaW9zX3JxX2RhdGEgKnJkID0gZ2V0X3JxX2RhdGEocnEpOwoJc3RydWN0IGRsX2dyb3VwICpk"
    "bGcgPSBjb250YWluZXJfb2YocmQtPmRsX2dyb3VwLCBzdHJ1Y3QgZGxfZ3JvdXAsIHJxcyk7CgoJbGlzdF9kZWxfaW5pdCgmcmQtPmRsX25vZGUpOwoJaWYg"
    "KGxpc3RfZW1wdHkoJmRsZy0+cnFzKSkgewoJCXJiX2VyYXNlX2NhY2hlZCgmZGxnLT5ub2RlLCByb290KTsKCQlrbWVtX2NhY2hlX2ZyZWUoYWQtPmRsX2dy"
    "b3VwX3Bvb2wsIGRsZyk7Cgl9CglyZC0+ZGxfZ3JvdXAgPSBOVUxMOwoKCWlmIChSQl9FTVBUWV9ST09UKCZhZC0+ZGxfdHJlZVtkbF9pZHhdLnJiX3Jvb3Qp"
    "KQoJCXNldF9hZGlvc19zdGF0ZShhZCwgQURJT1NfU1RBVEVfREwsIGRsX2lkeCwgZmFsc2UpOwp9CgovLyBSZW1vdmUgYSByZXF1ZXN0IGZyb20gdGhlIHNj"
    "aGVkdWxlcgpzdGF0aWMgdm9pZCByZW1vdmVfcmVxdWVzdChzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQsIHN0cnVjdCByZXF1ZXN0ICpycSkgewoJYm9vbCBkbF9p"
    "ZHggPSBhZGlvc19vcHR5cGVfbm90X3JlYWQocnEpOwoJc3RydWN0IHJlcXVlc3RfcXVldWUgKnEgPSBycS0+cTsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpy"
    "ZCA9IGdldF9ycV9kYXRhKHJxKTsKCglsaXN0X2RlbF9pbml0KCZycS0+cXVldWVsaXN0KTsKCgkvLyBXZSBtaWdodCBub3QgYmUgb24gdGhlIHJidHJlZSwg"
    "aWYgd2UgYXJlIGRvaW5nIGFuIGluc2VydCBtZXJnZQoJaWYgKHJkLT5kbF9ncm91cCkKCQlkZWxfZnJvbV9kbF90cmVlKGFkLCBkbF9pZHgsIHJxKTsKCgll"
    "bHZfcnFoYXNoX2RlbChxLCBycSk7CglpZiAocS0+bGFzdF9tZXJnZSA9PSBycSkKCQlxLT5sYXN0X21lcmdlID0gTlVMTDsKfQoKLy8gV2UgbGltaXQgdGhl"
    "IGRlcHRoIG9mIHJlcXVlc3QgYWxsb2NhdGlvbiBmb3IgYXN5bmNocm9ub3VzIGFuZCB3cml0ZSByZXF1ZXN0cwpzdGF0aWMgdm9pZCBhZGlvc19saW1pdF9k"
    "ZXB0aCh1bnNpZ25lZCBpbnQgb3BmLCBzdHJ1Y3QgYmxrX21xX2FsbG9jX2RhdGEgKmRhdGEpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGRhdGEtPnEt"
    "PmVsZXZhdG9yLT5lbGV2YXRvcl9kYXRhOwoKCS8vIERvIG5vdCB0aHJvdHRsZSBzeW5jaHJvbm91cyByZWFkcwoJaWYgKG9wX2lzX3N5bmMob3BmKSAmJiAh"
    "b3BfaXNfd3JpdGUob3BmKSkKCQlyZXR1cm47CgoJLyoKCSAqIHNiaXRtYXAncyBfX21hcF9kZXB0aF93aXRoX3NoYWxsb3coKSBoYXMgdGFrZW4gc2hhbGxv"
    "d19kZXB0aCBpbgoJICogd2hvbGUtcXVldWUgdW5pdHMgc2luY2UgNi4xMiAodGhlIHNhbWUgcmVsZWFzZSBtcS1kZWFkbGluZSdzCgkgKiBkZF90b193b3Jk"
    "X2RlcHRoKCkgd2FzIGRyb3BwZWQpIGFuZCBkb2VzIHRoZSBwZXItd29yZCBkaXZpc2lvbgoJICogaXRzZWxmLiBQYXNzaW5nIGFuIGFscmVhZHkgcGVyLXdv"
    "cmQgdmFsdWUgaGVyZSAodGhlIG9sZAoJICogdG9fd29yZF9kZXB0aCgpIGhlbHBlcikgZ290IGl0IHNxdWFyZWQgYXdheTogd29yZF9kZXB0aF4yIC8KCSAq"
    "IHNiLT5kZXB0aCwgc2lsZW50bHkgY2FwcGluZyBhc3luYy93cml0ZSBhbGxvY2F0aW9uIGF0IDw9IDY0IHRhZ3MKCSAqIHJlZ2FyZGxlc3Mgb2YgYXN5bmNf"
    "ZGVwdGguIFBhc3MgdGhlIHJhdyBxdWV1ZS13aWRlIGRlcHRoLCBtYXRjaGluZwoJICogbXEtZGVhZGxpbmUva3liZXIuCgkgKi8KCWRhdGEtPnNoYWxsb3df"
    "ZGVwdGggPSBhZC0+YXN5bmNfZGVwdGg7Cn0KCi8vIFRoZSBudW1iZXIgb2YgcmVxdWVzdHMgaW4gdGhlIHF1ZXVlIHdhcyBub3RpZmllZCBmcm9tIHRoZSBi"
    "bG9jayBsYXllcgpzdGF0aWMgdm9pZCBhZGlvc19kZXB0aF91cGRhdGVkKHN0cnVjdCBibGtfbXFfaHdfY3R4ICpoY3R4KSB7CglzdHJ1Y3QgcmVxdWVzdF9x"
    "dWV1ZSAqcSA9IGhjdHgtPnF1ZXVlOwoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gcS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgYmxrX21x"
    "X3RhZ3MgKnRhZ3MgPSBoY3R4LT5zY2hlZF90YWdzOwoKCWFkLT5hc3luY19kZXB0aCA9IHEtPm5yX3JlcXVlc3RzOwoKCXNiaXRtYXBfcXVldWVfbWluX3No"
    "YWxsb3dfZGVwdGgoJnRhZ3MtPmJpdG1hcF90YWdzLCBhZC0+YXN5bmNfZGVwdGgpOwp9CgovLyBIYW5kbGUgcmVxdWVzdCBtZXJnaW5nIGFmdGVyIGEgbWVy"
    "Z2Ugb3BlcmF0aW9uCnN0YXRpYyB2b2lkIGFkaW9zX3JlcXVlc3RfbWVyZ2VkKHN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxLCBzdHJ1Y3QgcmVxdWVzdCAqcmVx"
    "LAoJCQkJICBlbnVtIGVsdl9tZXJnZSB0eXBlKSB7Cglib29sIGRsX2lkeCA9IGFkaW9zX29wdHlwZV9ub3RfcmVhZChyZXEpOwoJc3RydWN0IGFkaW9zX2Rh"
    "dGEgKmFkID0gcS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CgoJLy8gUmVwb3NpdGlvbiByZXF1ZXN0IGluIHRoZSBkZWFkbGluZS1zb3J0ZWQgdHJlZQoJ"
    "ZGVsX2Zyb21fZGxfdHJlZShhZCwgZGxfaWR4LCByZXEpOwoJYWRkX3RvX2RsX3RyZWUoYWQsIGRsX2lkeCwgcmVxKTsKfQoKLy8gSGFuZGxlIG1lcmdpbmcg"
    "b2YgcmVxdWVzdHMgYWZ0ZXIgb25lIGhhcyBiZWVuIG1lcmdlZCBpbnRvIGFub3RoZXIKc3RhdGljIHZvaWQgYWRpb3NfbWVyZ2VkX3JlcXVlc3RzKHN0cnVj"
    "dCByZXF1ZXN0X3F1ZXVlICpxLCBzdHJ1Y3QgcmVxdWVzdCAqcmVxLAoJCQkJICAgc3RydWN0IHJlcXVlc3QgKm5leHQpIHsKCXN0cnVjdCBhZGlvc19kYXRh"
    "ICphZCA9IHEtPmVsZXZhdG9yLT5lbGV2YXRvcl9kYXRhOwoKCWxvY2tkZXBfYXNzZXJ0X2hlbGQoJmFkLT5sb2NrKTsKCgkvLyBraWxsIGtub3dsZWRnZSBv"
    "ZiBuZXh0LCB0aGlzIG9uZSBpcyBhIGdvbmVyCglyZW1vdmVfcmVxdWVzdChhZCwgbmV4dCk7Cn0KCi8vIFRyeSB0byBtZXJnZSBhIGJpbyBpbnRvIGFuIGV4"
    "aXN0aW5nIHJxIGJlZm9yZSBhc3NvY2lhdGluZyBpdCB3aXRoIGFuIHJxCnN0YXRpYyBib29sIGFkaW9zX2Jpb19tZXJnZShzdHJ1Y3QgcmVxdWVzdF9xdWV1"
    "ZSAqcSwgc3RydWN0IGJpbyAqYmlvLAoJCXVuc2lnbmVkIGludCBucl9zZWdzKSB7Cgl1bnNpZ25lZCBsb25nIGZsYWdzOwoJc3RydWN0IGFkaW9zX2RhdGEg"
    "KmFkID0gcS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgcmVxdWVzdCAqZnJlZSA9IE5VTEw7Cglib29sIHJldDsKCglpZiAoIXNwaW5fdHJ5"
    "bG9ja19pcnFzYXZlKCZhZC0+bG9jaywgZmxhZ3MpKQoJCXJldHVybiBmYWxzZTsKCglyZXQgPSBibGtfbXFfc2NoZWRfdHJ5X21lcmdlKHEsIGJpbywgbnJf"
    "c2VncywgJmZyZWUpOwoJc3Bpbl91bmxvY2tfaXJxcmVzdG9yZSgmYWQtPmxvY2ssIGZsYWdzKTsKCglpZiAoZnJlZSkKCQlibGtfbXFfZnJlZV9yZXF1ZXN0"
    "KGZyZWUpOwoKCXJldHVybiByZXQ7Cn0KCnN0YXRpYyBib29sIG1lcmdlX29yX2luc2VydF90b19kbF90cmVlKHN0cnVjdCBhZGlvc19kYXRhICphZCwKCQlz"
    "dHJ1Y3QgcmVxdWVzdCAqcnEsIHN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxLCBzdHJ1Y3QgbGlzdF9oZWFkICpmcmVlKSB7CglpZiAoYWRpb3NfdHJ5X2luc2Vy"
    "dF9tZXJnZShxLCBycSwgZnJlZSkpCgkJcmV0dXJuIHRydWU7CgoJYm9vbCBkbF9pZHggPSBhZGlvc19vcHR5cGVfbm90X3JlYWQocnEpOwoJYWRkX3RvX2Rs"
    "X3RyZWUoYWQsIGRsX2lkeCwgcnEpOwoKCWlmIChycV9tZXJnZWFibGUocnEpKSB7CgkJZWx2X3JxaGFzaF9hZGQocSwgcnEpOwoJCWlmICghcS0+bGFzdF9t"
    "ZXJnZSkKCQkJcS0+bGFzdF9tZXJnZSA9IHJxOwoJfQoKCXJldHVybiBmYWxzZTsKfQoKc3RhdGljIHZvaWQgaW5zZXJ0X3RvX3ByaW9fcXVldWUoc3RydWN0"
    "IGFkaW9zX2RhdGEgKmFkLAoJCXN0cnVjdCByZXF1ZXN0ICpycSwgYm9vbCBwcV9pZHgpIHsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZCA9IGdldF9ycV9k"
    "YXRhKHJxKTsKCgkvKiBXZSdyZSBzdXJlIHRoYXQgcmQtPm1hbmFnZWQgPT0gdHJ1ZSAqLwoJdW5pb24gYWRpb3NfaW5fZmxpZ2h0X3JxcyBpZnIgPSB7CgkJ"
    "LmNvdW50ICAgICAgICAgID0gMSwKCQkudG90YWxfcHJlZF9sYXQgPSByZC0+cHJlZF9sYXQsCgl9OwoJYXRvbWljNjRfYWRkKGlmci5zY2FsYXIsICZhZC0+"
    "aW5fZmxpZ2h0X3Jxcy5hdG9taWMpOwoKCWFkaW9zX3Njb3BlZF9ndWFyZChzcGlubG9ja19pcnFzYXZlLCAmYWQtPnBxX2xvY2spIHsKCQlib29sIHdhc19l"
    "bXB0eSA9IGxpc3RfZW1wdHkoJmFkLT5wcmlvX3F1ZXVlW3BxX2lkeF0pOwoJCWxpc3RfYWRkX3RhaWwoJnJxLT5xdWV1ZWxpc3QsICZhZC0+cHJpb19xdWV1"
    "ZVtwcV9pZHhdKTsKCQlpZiAod2FzX2VtcHR5KQoJCQlzZXRfYWRpb3Nfc3RhdGUoYWQsIEFESU9TX1NUQVRFX1BRLCBwcV9pZHgsIHRydWUpOwoJfQp9Cgov"
    "LyBJbnNlcnQgYSByZXF1ZXN0IGludG8gdGhlIHNjaGVkdWxlciAoYWZ0ZXIgUmVhZCAmIFdyaXRlIG1vZGVscyBzdGFiaWxpemVkKQpzdGF0aWMgdm9pZCBp"
    "bnNlcnRfcmVxdWVzdF9wb3N0X3N0YWJpbGl0eShzdHJ1Y3QgYmxrX21xX2h3X2N0eCAqaGN0eCwKCQlzdHJ1Y3QgcmVxdWVzdCAqcnEsIGJsa19pbnNlcnRf"
    "dCBpbnNlcnRfZmxhZ3MsIHN0cnVjdCBsaXN0X2hlYWQgKmZyZWUpIHsKCXN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxID0gaGN0eC0+cXVldWU7CglzdHJ1Y3Qg"
    "YWRpb3NfZGF0YSAqYWQgPSBxLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCBhZGlvc19ycV9kYXRhICpyZCA9IGdldF9ycV9kYXRhKHJxKTsK"
    "CXU4IG9wdHlwZSA9IGFkaW9zX29wdHlwZShycSk7CgoJcmQtPm1hbmFnZWQgPSB0cnVlOwoJcmQtPmJsb2NrX3NpemUgPSBibGtfcnFfYnl0ZXMocnEpOwoJ"
    "cmQtPnByZWRfbGF0ID0KCQlsYXRlbmN5X21vZGVsX3ByZWRpY3QoJmFkLT5sYXRlbmN5X21vZGVsW29wdHlwZV0sIHJkLT5ibG9ja19zaXplKTsKCWlmICh1"
    "bmxpa2VseShyZC0+cHJlZF9sYXQgPiBhZC0+bGF0X21vZGVsX2xhdGVuY3lfbGltaXQpKQoJCXJkLT5wcmVkX2xhdCA9IGFkLT5sYXRfbW9kZWxfbGF0ZW5j"
    "eV9saW1pdDsKCgkvKiBUaWVyLTA6IEJMS19NUV9JTlNFUlRfQVRfSEVBRCBSZXF1ZXN0cyAqLwoJaWYgKGluc2VydF9mbGFncyAmIEJMS19NUV9JTlNFUlRf"
    "QVRfSEVBRCkgewoJCWluc2VydF90b19wcmlvX3F1ZXVlKGFkLCBycSwgMCk7CgkJcmV0dXJuOwoJfQoKCWlmIChtZXJnZV9vcl9pbnNlcnRfdG9fZGxfdHJl"
    "ZShhZCwgcnEsIHEsIGZyZWUpKQoJCXJldHVybjsKfQoKLy8gSW5zZXJ0IGEgcmVxdWVzdCBpbnRvIHRoZSBzY2hlZHVsZXIgKGJlZm9yZSBSZWFkICYgV3Jp"
    "dGUgbW9kZWxzIHN0YWJpbGl6ZXMpCnN0YXRpYyB2b2lkIGluc2VydF9yZXF1ZXN0X3ByZV9zdGFiaWxpdHkoc3RydWN0IGJsa19tcV9od19jdHggKmhjdHgs"
    "CgkJc3RydWN0IHJlcXVlc3QgKnJxLCBibGtfaW5zZXJ0X3QgaW5zZXJ0X2ZsYWdzLCBzdHJ1Y3QgbGlzdF9oZWFkICpmcmVlKSB7CglzdHJ1Y3QgYWRpb3Nf"
    "ZGF0YSAqYWQgPSBoY3R4LT5xdWV1ZS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgYWRpb3NfcnFfZGF0YSAqcmQgPSBnZXRfcnFfZGF0YShy"
    "cSk7Cgl1OCBvcHR5cGUgPSBhZGlvc19vcHR5cGUocnEpOwoJdTggcHFfaWR4ID0gIShpbnNlcnRfZmxhZ3MgJiBCTEtfTVFfSU5TRVJUX0FUX0hFQUQpOwoJ"
    "Ym9vbCBzdGFibGUgPSBmYWxzZTsKCglyZC0+bWFuYWdlZCA9IHRydWU7CglyZC0+YmxvY2tfc2l6ZSA9IGJsa19ycV9ieXRlcyhycSk7CglyZC0+cHJlZF9s"
    "YXQgPQoJCWxhdGVuY3lfbW9kZWxfcHJlZGljdCgmYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBlXSwgcmQtPmJsb2NrX3NpemUpOwoJaWYgKHVubGlrZWx5KHJk"
    "LT5wcmVkX2xhdCA+IGFkLT5sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCkpCgkJcmQtPnByZWRfbGF0ID0gYWQtPmxhdF9tb2RlbF9sYXRlbmN5X2xpbWl0OwoK"
    "CWluc2VydF90b19wcmlvX3F1ZXVlKGFkLCBycSwgcHFfaWR4KTsKCglyY3VfcmVhZF9sb2NrKCk7CglpZiAocmN1X2RlcmVmZXJlbmNlKGFkLT5sYXRlbmN5"
    "X21vZGVsW0FESU9TX1JFQURdLnBhcmFtcyktPmJhc2UgPiAwICYmCgkJcmN1X2RlcmVmZXJlbmNlKGFkLT5sYXRlbmN5X21vZGVsW0FESU9TX1dSSVRFXS5w"
    "YXJhbXMpLT5iYXNlID4gMCkKCQkJc3RhYmxlID0gdHJ1ZTsKCXJjdV9yZWFkX3VubG9jaygpOwoKCWlmIChzdGFibGUpCgkJYWQtPm1vZGVsc19zdGFibGUg"
    "PSB0cnVlOwp9CgovLyBJbnNlcnQgbXVsdGlwbGUgcmVxdWVzdHMgaW50byB0aGUgc2NoZWR1bGVyCnN0YXRpYyB2b2lkIGFkaW9zX2luc2VydF9yZXF1ZXN0"
    "cyhzdHJ1Y3QgYmxrX21xX2h3X2N0eCAqaGN0eCwKCQkJCSAgIHN0cnVjdCBsaXN0X2hlYWQgKmxpc3QsCgkJCQkgICBib29sIGRpc3BhdGNoX25vdykgewoJ"
    "YmxrX2luc2VydF90IGluc2VydF9mbGFncyA9IDA7Cgkodm9pZClkaXNwYXRjaF9ub3c7CglzdHJ1Y3QgcmVxdWVzdF9xdWV1ZSAqcSA9IGhjdHgtPnF1ZXVl"
    "OwoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gcS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgcmVxdWVzdCAqcnE7Cglib29sIHN0b3AgPSBm"
    "YWxzZTsKCUxJU1RfSEVBRChmcmVlKTsKCglkbyB7CglhZGlvc19zY29wZWRfZ3VhcmQoc3BpbmxvY2tfaXJxc2F2ZSwgJmFkLT5sb2NrKQoJZm9yIChpbnQg"
    "aSA9IDA7IGkgPCBBRElPU19NQVhfSU5TRVJUU19QRVJfTE9DSzsgaSsrKSB7CgkJaWYgKGxpc3RfZW1wdHkobGlzdCkpIHsKCQkJc3RvcCA9IHRydWU7CgkJ"
    "CWJyZWFrOwoJCX0KCQlycSA9IGxpc3RfZmlyc3RfZW50cnkobGlzdCwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7CgkJbGlzdF9kZWxfaW5pdCgmcnEt"
    "PnF1ZXVlbGlzdCk7CgkJaWYgKGxpa2VseShhZC0+bW9kZWxzX3N0YWJsZSkpCgkJCWluc2VydF9yZXF1ZXN0X3Bvc3Rfc3RhYmlsaXR5KGhjdHgsIHJxLCBp"
    "bnNlcnRfZmxhZ3MsICZmcmVlKTsKCQllbHNlCgkJCWluc2VydF9yZXF1ZXN0X3ByZV9zdGFiaWxpdHkoaGN0eCwgcnEsIGluc2VydF9mbGFncywgJmZyZWUp"
    "OwoJfX0gd2hpbGUgKCFzdG9wKTsKCglhZGlvc19mcmVlX3JlcXVlc3RzKCZmcmVlKTsKfQoKLy8gUHJlcGFyZSBhIHJlcXVlc3QgYmVmb3JlIGl0IGlzIGlu"
    "c2VydGVkIGludG8gdGhlIHNjaGVkdWxlcgpzdGF0aWMgdm9pZCBhZGlvc19wcmVwYXJlX3JlcXVlc3Qoc3RydWN0IHJlcXVlc3QgKnJxLCBzdHJ1Y3QgYmlv"
    "ICpiaW8pIHsKCSh2b2lkKWJpbzsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IHJxLT5xLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCBhZGlv"
    "c19ycV9kYXRhICpyZDsKCglyZCA9IG1lbXBvb2xfYWxsb2MoYWQtPnJxX2RhdGFfcG9vbCwgR0ZQX0FUT01JQyk7CgltZW1zZXQocmQsIDAsIHNpemVvZigq"
    "cmQpKTsKCXJkLT5ycSA9IHJxOwoJcnEtPmVsdi5wcml2WzBdID0gcmQ7Cn0KCnN0YXRpYyBzdHJ1Y3QgYWRpb3NfcnFfZGF0YSAqZ2V0X2RsX2ZpcnN0X3Jk"
    "KHN0cnVjdCBhZGlvc19kYXRhICphZCwgYm9vbCBpZHgpIHsKCXN0cnVjdCByYl9yb290X2NhY2hlZCAqcm9vdCA9ICZhZC0+ZGxfdHJlZVtpZHhdOwoJc3Ry"
    "dWN0IHJiX25vZGUgKmZpcnN0ID0gcmJfZmlyc3RfY2FjaGVkKHJvb3QpOwoJc3RydWN0IGRsX2dyb3VwICpkbF9ncm91cCA9IHJiX2VudHJ5KGZpcnN0LCBz"
    "dHJ1Y3QgZGxfZ3JvdXAsIG5vZGUpOwoKCXJldHVybiBsaXN0X2ZpcnN0X2VudHJ5KCZkbF9ncm91cC0+cnFzLCBzdHJ1Y3QgYWRpb3NfcnFfZGF0YSwgZGxf"
    "bm9kZSk7Cn0KCi8vIENvbXBhcmlzb24gZnVuY3Rpb24gZm9yIHNvcnRpbmcgcmVxdWVzdHMgYnkgYmxvY2sgYWRkcmVzcwpzdGF0aWMgaW50IGNtcF9ycV9w"
    "b3Modm9pZCAqcHJpdiwKCQljb25zdCBzdHJ1Y3QgbGlzdF9oZWFkICphLCBjb25zdCBzdHJ1Y3QgbGlzdF9oZWFkICpiKSB7CglzdHJ1Y3QgcmVxdWVzdCAq"
    "cnFfYSA9IGxpc3RfZW50cnkoYSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7CglzdHJ1Y3QgcmVxdWVzdCAqcnFfYiA9IGxpc3RfZW50cnkoYiwgc3Ry"
    "dWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7Cgl1NjQgcG9zX2EgPSBibGtfcnFfcG9zKHJxX2EpOwoJdTY0IHBvc19iID0gYmxrX3JxX3BvcyhycV9iKTsKCgly"
    "ZXR1cm4gKGludCkocG9zX2EgPiBwb3NfYikgLSAoaW50KShwb3NfYSA8IHBvc19iKTsKfQoKI2lmbmRlZiBsaXN0X2xhc3RfZW50cnlfb3JfbnVsbAojZGVm"
    "aW5lIGxpc3RfbGFzdF9lbnRyeV9vcl9udWxsKHB0ciwgdHlwZSwgbWVtYmVyKSBcCgkoIWxpc3RfZW1wdHkocHRyKSA/IGxpc3RfbGFzdF9lbnRyeShwdHIs"
    "IHR5cGUsIG1lbWJlcikgOiBOVUxMKQojZW5kaWYKCi8vIFVwZGF0ZSB0aGUgZWxldmF0b3IgZGlyZWN0aW9uCnN0YXRpYyB2b2lkIHVwZGF0ZV9lbHZfZGly"
    "ZWN0aW9uKHN0cnVjdCBhZGlvc19kYXRhICphZCkgewoJaWYgKCFhZC0+aXNfcm90YXRpb25hbCkKCQlyZXR1cm47CgoJYm9vbCBwYWdlID0gYWQtPmJxX3Bh"
    "Z2U7CglzdHJ1Y3QgbGlzdF9oZWFkICpxID0gJmFkLT5iYXRjaF9xdWV1ZVtwYWdlXVsxXTsKCWlmIChhZC0+YnFfYmF0Y2hfb3JkZXJbcGFnZV0gPCBBRElP"
    "U19CT19FTEVWQVRPUiB8fCBsaXN0X2VtcHR5KHEpKSB7CgkJYWQtPmVsdl9kaXJlY3Rpb24gPSAwOwoJCXJldHVybjsKCX0KCgkvLyBHZXQgZmlyc3QgYW5k"
    "IGxhc3QgcmVxdWVzdCBwb3NpdGlvbnMgaW4gdGhlIHF1ZXVlCglzdHJ1Y3QgcmVxdWVzdCAqcnFfYSA9IGxpc3RfZmlyc3RfZW50cnkocSwgc3RydWN0IHJl"
    "cXVlc3QsIHF1ZXVlbGlzdCk7CglzdHJ1Y3QgcmVxdWVzdCAqcnFfYiA9IGxpc3RfbGFzdF9lbnRyeSAocSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk7"
    "Cgl1NjQgcG9zX2EgPSBibGtfcnFfcG9zKHJxX2EpOwoJdTY0IHBvc19iID0gYmxrX3JxX3BvcyhycV9iKTsKCXU2NCBhdmdfcnFfcG9zID0gKHBvc19hICsg"
    "cG9zX2IpID4+IDE7CgoJYWQtPmVsdl9kaXJlY3Rpb24gPSAhIShhZC0+aGVhZF9wb3MgPiBhdmdfcnFfcG9zKTsKfQoKLy8gRmlsbCB0aGUgYmF0Y2ggcXVl"
    "dWVzIHdpdGggcmVxdWVzdHMgZnJvbSB0aGUgZGVhZGxpbmUtc29ydGVkIHJlZC1ibGFjayB0cmVlCnN0YXRpYyBib29sIGZpbGxfYmF0Y2hfcXVldWVzKHN0"
    "cnVjdCBhZGlvc19kYXRhICphZCwgdTY0IHRwbCkgewoJc3RydWN0IGFkaW9zX3JxX2RhdGEgKnJkOwoJc3RydWN0IHJlcXVlc3QgKnJxOwoJc3RydWN0IGxp"
    "c3RfaGVhZCAqZGVzdF9xOwoJdTggIGRlc3RfaWR4OwoJdTY0IGFkZGVkX2xhdCA9IDA7Cgl1MzIgb3B0eXBlX2NvdW50W0FESU9TX09QVFlQRVNdID0gezB9"
    "OwoJdTMyIGNvdW50ID0gMDsKCXU4IG9wdHlwZTsKCWJvb2wgcGFnZSA9ICFhZC0+YnFfcGFnZSwgZGxfaWR4LCBiaWFzX2lkeCwgdXBkYXRlX2JpYXM7Cgl1"
    "MzIgZGxfcXVldWVkOwoJdTggYnFfYmF0Y2hfb3JkZXI7Cglib29sIHN0b3AgPSBmYWxzZTsKCgkvLyBSZXNldCBiYXRjaCBxdWV1ZSBjb3VudHMgZm9yIHRo"
    "ZSBiYWNrIHBhZ2UKCW1lbXNldCgmYWQtPmJhdGNoX2NvdW50W3BhZ2VdLCAwLCBzaXplb2YoYWQtPmJhdGNoX2NvdW50W3BhZ2VdKSk7CgoJYWQtPmJxX2Jh"
    "dGNoX29yZGVyW3BhZ2VdID0KCQlicV9iYXRjaF9vcmRlciA9IGFkLT5iYXRjaF9vcmRlcjsKCglkbyB7CglhZGlvc19zY29wZWRfZ3VhcmQoc3BpbmxvY2tf"
    "aXJxc2F2ZSwgJmFkLT5sb2NrKQoJZm9yIChpbnQgaSA9IDA7IGkgPCBBRElPU19NQVhfREVMRVRFU19QRVJfTE9DSzsgaSsrKSB7CgkJYm9vbCBoYXNfYmFz"
    "ZSA9IGZhbHNlOwoKCQlkbF9xdWV1ZWQgPSBldmFsX2FkaW9zX3N0YXRlKGFkLCBBRElPU19TVEFURV9ETCk7CgkJLy8gQ2hlY2sgaWYgdGhlcmUgYXJlIGFu"
    "eSByZXF1ZXN0cyBxdWV1ZWQgaW4gdGhlIGRlYWRsaW5lIHRyZWUKCQlpZiAoIWRsX3F1ZXVlZCkgewoJCQlzdG9wID0gdHJ1ZTsKCQkJYnJlYWs7CgkJfQoK"
    "CQkvLyBSZWFkcyBpZiBib3RoIHF1ZXVlcyBoYXZlIHJlcXVlc3RzLCBvdGhlcndpc2UgcGljayB0aGUgbm9uLWVtcHR5LgoJCWRsX2lkeCA9IGRsX3F1ZXVl"
    "ZCA+PiAxOwoKCQkvLyBHZXQgdGhlIGZpcnN0IHJlcXVlc3QgZnJvbSB0aGUgZGVhZGxpbmUtc29ydGVkIHRyZWUKCQlyZCA9IGdldF9kbF9maXJzdF9yZChh"
    "ZCwgZGxfaWR4KTsKCgkJYmlhc19pZHggPSBhZC0+ZGxfYmlhcyA8IDA7CgkJLy8gSWYgcmVhZCBhbmQgd3JpdGUgcmVxdWVzdHMgYXJlIHF1ZXVlZCwgY2hv"
    "b3NlIG9uZSBiYXNlZCBvbiBiaWFzCgkJaWYgKGRsX3F1ZXVlZCA9PSAweDMpIHsKCQkJc3RydWN0IGFkaW9zX3JxX2RhdGEgKnRyZFsyXSA9IHtnZXRfZGxf"
    "Zmlyc3RfcmQoYWQsIDApLCByZH07CgkJCXJkID0gdHJkW2JpYXNfaWR4XTsKCgkJCXVwZGF0ZV9iaWFzID0gKHRyZFtiaWFzX2lkeF0tPmRlYWRsaW5lID4g"
    "dHJkWyFiaWFzX2lkeF0tPmRlYWRsaW5lKTsKCQl9IGVsc2UKCQkJdXBkYXRlX2JpYXMgPSAoYmlhc19pZHggPT0gZGxfaWR4KTsKCgkJcnEgPSByZC0+cnE7"
    "CgkJb3B0eXBlID0gYWRpb3Nfb3B0eXBlKHJxKTsKCgkJcmN1X3JlYWRfbG9jaygpOwoJCWhhc19iYXNlID0KCQkJISFyY3VfZGVyZWZlcmVuY2UoYWQtPmxh"
    "dGVuY3lfbW9kZWxbb3B0eXBlXS5wYXJhbXMpLT5iYXNlOwoJCXJjdV9yZWFkX3VubG9jaygpOwoKCQkvLyBDaGVjayBiYXRjaCBzaXplIGFuZCB0b3RhbCBw"
    "cmVkaWN0ZWQgbGF0ZW5jeQoJCWlmIChjb3VudCAmJiAoIWhhc19iYXNlIHx8CgkJCQlhZC0+YmF0Y2hfY291bnRbcGFnZV1bb3B0eXBlXSA+PSBhZC0+YmF0"
    "Y2hfbGltaXRbb3B0eXBlXSB8fAoJCQkJKHRwbCArIGFkZGVkX2xhdCArIHJkLT5wcmVkX2xhdCkgPiBhZC0+Z2xvYmFsX2xhdGVuY3lfd2luZG93KSkgewoJ"
    "CQlzdG9wID0gdHJ1ZTsKCQkJYnJlYWs7CgkJfQoKCQlpZiAodXBkYXRlX2JpYXMpIHsKCQkJczY0IHNpZ24gPSAoKHM2NCliaWFzX2lkeCA8PCAxKSAtIDE7"
    "CgkJCWlmICh1bmxpa2VseSghcmQtPnByZWRfbGF0KSkKCQkJCWFkLT5kbF9iaWFzID0gc2lnbjsKCQkJZWxzZQoJCQkJLy8gQWRqdXN0IHRoZSBiaWFzIGJh"
    "c2VkIG9uIHRoZSBwcmVkaWN0ZWQgbGF0ZW5jeQoJCQkJYWQtPmRsX2JpYXMgKz0gc2lnbiAqIChzNjQpKChyZC0+cHJlZF9sYXQgKgoJCQkJCWFkaW9zX3By"
    "aW9fdG9fd211bHRbYWQtPmRsX3ByaW9bYmlhc19pZHhdICsgMjBdKSA+PiAxMCk7CgkJfQoKCQlyZW1vdmVfcmVxdWVzdChhZCwgcnEpOwoKCQkvLyBBZGQg"
    "cmVxdWVzdCB0byB0aGUgY29ycmVzcG9uZGluZyBiYXRjaCBxdWV1ZQoJCWRlc3RfaWR4ID0gKGJxX2JhdGNoX29yZGVyID09IEFESU9TX0JPX09QVFlQRSB8"
    "fCBvcHR5cGUgPT0gQURJT1NfT1RIRVIpPwoJCQlvcHR5cGUgOiAhIShyZC0+ZGVhZGxpbmUgIT0gcnEtPnN0YXJ0X3RpbWVfbnMpOwoJCWRlc3RfcSA9ICZh"
    "ZC0+YmF0Y2hfcXVldWVbcGFnZV1bZGVzdF9pZHhdOwoJCWxpc3RfYWRkX3RhaWwoJnJxLT5xdWV1ZWxpc3QsIGRlc3RfcSk7CgkJYWQtPmJxX3N0YXRlW3Bh"
    "Z2VdIHw9IDFVIDw8IGRlc3RfaWR4OwoJCWFkLT5iYXRjaF9jb3VudFtwYWdlXVtvcHR5cGVdKys7CgkJb3B0eXBlX2NvdW50W29wdHlwZV0rKzsKCQlhZGRl"
    "ZF9sYXQgKz0gcmQtPnByZWRfbGF0OwoJCWNvdW50Kys7Cgl9fSB3aGlsZSAoIXN0b3ApOwoKCWlmIChicV9iYXRjaF9vcmRlciA9PSBBRElPU19CT19FTEVW"
    "QVRPUiAmJiBhZC0+YmF0Y2hfY291bnRbcGFnZV1bMV0gPiAxKQoJCQlsaXN0X3NvcnQoTlVMTCwgJmFkLT5iYXRjaF9xdWV1ZVtwYWdlXVsxXSwgY21wX3Jx"
    "X3Bvcyk7CgoJaWYgKGNvdW50KSB7CgkJLyogV2UncmUgc3VyZSB0aGF0IGV2ZXJ5IHJlcXVlc3QncyByZC0+bWFuYWdlZCA9PSB0cnVlICovCgkJdW5pb24g"
    "YWRpb3NfaW5fZmxpZ2h0X3JxcyBpZnIgPSB7CgkJCS5jb3VudCAgICAgICAgICA9IGNvdW50LAoJCQkudG90YWxfcHJlZF9sYXQgPSBhZGRlZF9sYXQsCgkJ"
    "fTsKCQlhdG9taWM2NF9hZGQoaWZyLnNjYWxhciwgJmFkLT5pbl9mbGlnaHRfcnFzLmF0b21pYyk7CgoJCXNldF9hZGlvc19zdGF0ZShhZCwgQURJT1NfU1RB"
    "VEVfQlEsIHBhZ2UsIHRydWUpOwoKCQlmb3IgKG9wdHlwZSA9IDA7IG9wdHlwZSA8IEFESU9TX09QVFlQRVM7IG9wdHlwZSsrKQoJCQlpZiAoYWQtPmJhdGNo"
    "X2FjdHVhbF9tYXhfc2l6ZVtvcHR5cGVdIDwgb3B0eXBlX2NvdW50W29wdHlwZV0pCgkJCQlhZC0+YmF0Y2hfYWN0dWFsX21heF9zaXplW29wdHlwZV0gPSBv"
    "cHR5cGVfY291bnRbb3B0eXBlXTsKCQlpZiAoYWQtPmJhdGNoX2FjdHVhbF9tYXhfdG90YWwgPCBjb3VudCkKCQkJYWQtPmJhdGNoX2FjdHVhbF9tYXhfdG90"
    "YWwgPSBjb3VudDsKCX0KCXJldHVybiBjb3VudDsKfQoKLy8gRmxpcCB0byB0aGUgbmV4dCBiYXRjaCBxdWV1ZSBwYWdlCnN0YXRpYyB2b2lkIGZsaXBfYnFf"
    "cGFnZShzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQpIHsKCWFkLT5icV9wYWdlID0gIWFkLT5icV9wYWdlOwoJdXBkYXRlX2Vsdl9kaXJlY3Rpb24oYWQpOwp9Cgov"
    "LyBQb3AgYSByZXF1ZXN0IGZyb20gdGhlIHNwZWNpZmllZCBpbmRleCAob3B0eXBlIG9yIGVsZXZhdG9yIHRpZXIpCnN0YXRpYyBpbmxpbmUgc3RydWN0IHJl"
    "cXVlc3QgKnBvcF9icV9yZXF1ZXN0KAoJCXN0cnVjdCBhZGlvc19kYXRhICphZCwgdTggaWR4LCBib29sIGRpcmVjdGlvbikgewoJYm9vbCBwYWdlID0gYWQt"
    "PmJxX3BhZ2U7CglzdHJ1Y3QgbGlzdF9oZWFkICpxID0gJmFkLT5iYXRjaF9xdWV1ZVtwYWdlXVtpZHhdOwoJc3RydWN0IHJlcXVlc3QgKnJxID0gZGlyZWN0"
    "aW9uID8KCQlsaXN0X2xhc3RfZW50cnlfb3JfbnVsbCAocSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVlbGlzdCk6CgkJbGlzdF9maXJzdF9lbnRyeV9vcl9udWxs"
    "KHEsIHN0cnVjdCByZXF1ZXN0LCBxdWV1ZWxpc3QpOwoJaWYgKHJxKSB7CgkJbGlzdF9kZWxfaW5pdCgmcnEtPnF1ZXVlbGlzdCk7CgkJaWYgKGxpc3RfZW1w"
    "dHkocSkpCgkJCWFkLT5icV9zdGF0ZVtwYWdlXSAmPSB+KDFVIDw8IGlkeCk7Cgl9CglyZXR1cm4gcnE7Cn0KCnN0YXRpYyBzdHJ1Y3QgcmVxdWVzdCAqcG9w"
    "X25leHRfYnFfcmVxdWVzdF9vcHR5cGUoc3RydWN0IGFkaW9zX2RhdGEgKmFkKSB7Cgl1MzIgYnFfc3RhdGUgPSBhZC0+YnFfc3RhdGVbYWQtPmJxX3BhZ2Vd"
    "OwoJaWYgKCFicV9zdGF0ZSkgcmV0dXJuIE5VTEw7CgoJc3RydWN0IHJlcXVlc3QgKnJxOwoJdTMyIGJxX2lkeCA9IF9fYnVpbHRpbl9jdHooYnFfc3RhdGUp"
    "OwoKCS8vIERpc3BhdGNoIGJhc2VkIG9uIG9wdHlwZSAoRklGTyB3aXRoaW4gZWFjaCkgb3Igc2luZ2xlLXF1ZXVlIGVsZXZhdG9yCglycSA9IHBvcF9icV9y"
    "ZXF1ZXN0KGFkLCBicV9pZHgsIGZhbHNlKTsKCXJldHVybiBycTsKfQoKc3RhdGljIHN0cnVjdCByZXF1ZXN0ICpwb3BfbmV4dF9icV9yZXF1ZXN0X2VsZXZh"
    "dG9yKHN0cnVjdCBhZGlvc19kYXRhICphZCkgewoJdTMyIGJxX3N0YXRlID0gYWQtPmJxX3N0YXRlW2FkLT5icV9wYWdlXTsKCWlmICghYnFfc3RhdGUpIHJl"
    "dHVybiBOVUxMOwoKCXN0cnVjdCByZXF1ZXN0ICpycTsKCXUzMiBicV9pZHggPSBfX2J1aWx0aW5fY3R6KGJxX3N0YXRlKTsKCWJvb2wgZGlyZWN0aW9uID0g"
    "KGJxX2lkeCA9PSAxKSAmIGFkLT5lbHZfZGlyZWN0aW9uOwoKCS8vIFRpZXItMiAoc3luYykgaXMgYWx3YXlzIGhpZ2ggcHJpb3JpdHkKCS8vIFRpZXItMyAo"
    "YXN5bmMpIHVzZXMgdGhlIHByZS1jYWxjdWxhdGVkIGVsZXZhdG9yIGRpcmVjdGlvbgoJcnEgPSBwb3BfYnFfcmVxdWVzdChhZCwgYnFfaWR4LCBkaXJlY3Rp"
    "b24pOwoKCS8qIElmIGJhdGNoIHF1ZXVlIGZvciB0aGUgc3luYyByZXF1ZXN0cyBqdXN0IGJlY2FtZSBlbXB0eSAqLwoJaWYgKGJxX2lkeCA9PSAwICYmIHJx"
    "ICYmICEoYnFfc3RhdGUgJiAweDEpKQoJCXVwZGF0ZV9lbHZfZGlyZWN0aW9uKGFkKTsKCglyZXR1cm4gcnE7Cn0KCi8vIFJldHVybnMgdGhlIHN0YXRlIG9m"
    "IHRoZSBiYXRjaCBxdWV1ZSBwYWdlCnN0YXRpYyBpbmxpbmUgYm9vbCBicV9wYWdlX2hhc19ycSh1MzIgYnFfc3RhdGUsIGJvb2wgcGFnZSkgewoJcmV0dXJu"
    "IGJxX3N0YXRlICYgKDFVIDw8IHBhZ2UpOwp9CgovLyBEaXNwYXRjaCBhIHJlcXVlc3QgZnJvbSB0aGUgYmF0Y2ggcXVldWVzCnN0YXRpYyBzdHJ1Y3QgcmVx"
    "dWVzdCAqZGlzcGF0Y2hfZnJvbV9icShzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQpIHsKCXN0cnVjdCByZXF1ZXN0ICpycTsKCglhZGlvc19ndWFyZChzcGlubG9j"
    "a19pcnFzYXZlKSgmYWQtPmJxX2xvY2spOwoKCXUzMiBzdGF0ZSA9IGdldF9hZGlvc19zdGF0ZShhZCk7Cgl1MzIgYnFfc3RhdGUgPSBldmFsX3RoaXNfYWRp"
    "b3Nfc3RhdGUoc3RhdGUsIEFESU9TX1NUQVRFX0JRKTsKCXUzMiBicV9jdXJyX3BhZ2VfaGFzX3JxID0gYnFfcGFnZV9oYXNfcnEoYnFfc3RhdGUsIGFkLT5i"
    "cV9wYWdlKTsKCXVuaW9uIGFkaW9zX2luX2ZsaWdodF9ycXMgaWZyOwoJaWZyLnNjYWxhciA9IGF0b21pYzY0X3JlYWQoJmFkLT5pbl9mbGlnaHRfcnFzLmF0"
    "b21pYyk7Cgl1NjQgdHBsID0gaWZyLnRvdGFsX3ByZWRfbGF0OwoKCS8vIFJlZmlsbCB0aGUgYmF0Y2ggcXVldWVzIGlmIHRoZSBiYWNrIHBhZ2UgaXMgZW1w"
    "dHksIGRsX3RyZWUgaGFzIHdvcmssIGFuZAoJLy8gY3VycmVudCBwYWdlIGlzIGVtcHR5IG9yIHRoZSB0b3RhbCBvbmdvaW5nIGxhdGVuY3kgaXMgYmVsb3cg"
    "dGhlIHRocmVzaG9sZAoJaWYgKCFicV9wYWdlX2hhc19ycShicV9zdGF0ZSwgIWFkLT5icV9wYWdlKSAmJgoJCQkoIWJxX2N1cnJfcGFnZV9oYXNfcnEgfHwg"
    "KCF0cGwgfHwgdHBsIDwgZGl2X3U2NCgKCQkJYWQtPmdsb2JhbF9sYXRlbmN5X3dpbmRvdyAqIGFkLT5icV9yZWZpbGxfYmVsb3dfcmF0aW8sIDEwMCkpKSAm"
    "JgoJCQlldmFsX3RoaXNfYWRpb3Nfc3RhdGUoc3RhdGUsIEFESU9TX1NUQVRFX0RMKSkKCQlmaWxsX2JhdGNoX3F1ZXVlcyhhZCwgdHBsKTsKCgkvLyBJZiBj"
    "dXJyZW50IGJhdGNoIHF1ZXVlIHBhZ2UgaXMgZW1wdHksIGFuZCB0aGUgb3RoZXIgcGFnZSBoYXMgd29yaywgZmxpcAoJaWYgKCFicV9jdXJyX3BhZ2VfaGFz"
    "X3JxICYmCgkJCWJxX3BhZ2VfaGFzX3JxKGV2YWxfYWRpb3Nfc3RhdGUoYWQsIEFESU9TX1NUQVRFX0JRKSwgIWFkLT5icV9wYWdlKSkKCQlmbGlwX2JxX3Bh"
    "Z2UoYWQpOwoKCS8vIFVzZSB0aGUgcGVyLXBhZ2Ugc3RhdGUgdG8gZGVjaWRlIHRoZSBkaXNwYXRjaCBsb2dpYywgZW5zdXJpbmcgY29ycmVjdG5lc3MKCXJx"
    "ID0gKGFkLT5icV9iYXRjaF9vcmRlclthZC0+YnFfcGFnZV0gPT0gQURJT1NfQk9fRUxFVkFUT1IpID8KCQlwb3BfbmV4dF9icV9yZXF1ZXN0X2VsZXZhdG9y"
    "KGFkKToKCQlwb3BfbmV4dF9icV9yZXF1ZXN0X29wdHlwZShhZCk7CgoJaWYgKHJxKSB7CgkJYm9vbCBwYWdlID0gYWQtPmJxX3BhZ2U7CgkJYm9vbCBpc19l"
    "bXB0eSA9ICFhZC0+YnFfc3RhdGVbcGFnZV07CgkJaWYgKGlzX2VtcHR5KQoJCQlzZXRfYWRpb3Nfc3RhdGUoYWQsIEFESU9TX1NUQVRFX0JRLCBwYWdlLCBm"
    "YWxzZSk7CgkJcmV0dXJuIHJxOwoJfQoKCXJldHVybiBOVUxMOwp9CgovLyBEaXNwYXRjaCBhIHJlcXVlc3QgZnJvbSB0aGUgcHJpb3JpdHkgcXVldWUKc3Rh"
    "dGljIHN0cnVjdCByZXF1ZXN0ICpkaXNwYXRjaF9mcm9tX3BxKHN0cnVjdCBhZGlvc19kYXRhICphZCkgewoJc3RydWN0IHJlcXVlc3QgKnJxID0gTlVMTDsK"
    "CglhZGlvc19ndWFyZChzcGlubG9ja19pcnFzYXZlKSgmYWQtPnBxX2xvY2spOwoJdTMyIHBxX3N0YXRlID0gZXZhbF9hZGlvc19zdGF0ZShhZCwgQURJT1Nf"
    "U1RBVEVfUFEpOwoJdTggIHBxX2lkeCA9IHBxX3N0YXRlID4+IDE7CglzdHJ1Y3QgbGlzdF9oZWFkICpxID0gJmFkLT5wcmlvX3F1ZXVlW3BxX2lkeF07CgoJ"
    "aWYgKHVubGlrZWx5KGxpc3RfZW1wdHkocSkpKSByZXR1cm4gTlVMTDsKCglycSA9IGxpc3RfZmlyc3RfZW50cnkocSwgc3RydWN0IHJlcXVlc3QsIHF1ZXVl"
    "bGlzdCk7CglsaXN0X2RlbF9pbml0KCZycS0+cXVldWVsaXN0KTsKCWlmIChsaXN0X2VtcHR5KHEpKSB7CgkJc2V0X2FkaW9zX3N0YXRlKGFkLCBBRElPU19T"
    "VEFURV9QUSwgcHFfaWR4LCBmYWxzZSk7CgkJdXBkYXRlX2Vsdl9kaXJlY3Rpb24oYWQpOwoJfQoJcmV0dXJuIHJxOwp9CgoKLy8gRGlzcGF0Y2ggYSByZXF1"
    "ZXN0IHRvIHRoZSBoYXJkd2FyZSBxdWV1ZQpzdGF0aWMgc3RydWN0IHJlcXVlc3QgKmFkaW9zX2Rpc3BhdGNoX3JlcXVlc3Qoc3RydWN0IGJsa19tcV9od19j"
    "dHggKmhjdHgpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGhjdHgtPnF1ZXVlLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVjdCByZXF1ZXN0"
    "ICpycTsKCglycSA9IGRpc3BhdGNoX2Zyb21fcHEoYWQpOwoJaWYgKHJxKQoJCWdvdG8gZm91bmQ7CgoJcnEgPSBkaXNwYXRjaF9mcm9tX2JxKGFkKTsKCWlm"
    "IChycSkKCQlnb3RvIGZvdW5kOwoKCXJldHVybiBOVUxMOwpmb3VuZDoKCWlmIChhZC0+aXNfcm90YXRpb25hbCkKCQlhZC0+aGVhZF9wb3MgPSBibGtfcnFf"
    "cG9zKHJxKSArIGJsa19ycV9zZWN0b3JzKHJxKTsKCglycS0+cnFfZmxhZ3MgfD0gUlFGX1NUQVJURUQ7CglyZXR1cm4gcnE7Cn0KCi8vIFRpbWVyIGNhbGxi"
    "YWNrIGZ1bmN0aW9uIHRvIHBlcmlvZGljYWxseSB1cGRhdGUgbGF0ZW5jeSBtb2RlbHMKc3RhdGljIHZvaWQgdXBkYXRlX3RpbWVyX2NhbGxiYWNrKHN0cnVj"
    "dCB0aW1lcl9saXN0ICp0KSB7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBmcm9tX3RpbWVyKGFkLCB0LCB1cGRhdGVfdGltZXIpOwoKCWZvciAodTggb3B0"
    "eXBlID0gMDsgb3B0eXBlIDwgQURJT1NfT1BUWVBFUzsgb3B0eXBlKyspCgkJbGF0ZW5jeV9tb2RlbF91cGRhdGUoYWQsICZhZC0+bGF0ZW5jeV9tb2RlbFtv"
    "cHR5cGVdKTsKfQoKLy8gSGFuZGxlIHRoZSBjb21wbGV0aW9uIG9mIGEgcmVxdWVzdApzdGF0aWMgdm9pZCBhZGlvc19jb21wbGV0ZWRfcmVxdWVzdChzdHJ1"
    "Y3QgcmVxdWVzdCAqcnEsIHU2NCBub3cpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IHJxLT5xLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCXN0cnVj"
    "dCBhZGlvc19ycV9kYXRhICpyZCA9IGdldF9ycV9kYXRhKHJxKTsKCXVuaW9uIGFkaW9zX2luX2ZsaWdodF9ycXMgaWZyID0geyAuc2NhbGFyID0gMCB9OwoK"
    "CWlmIChyZC0+bWFuYWdlZCkgewoJCXVuaW9uIGFkaW9zX2luX2ZsaWdodF9ycXMgaWZyX3RvX3N1YiA9IHsKCQkJLmNvdW50ICAgICAgICAgID0gMSwKCQkJ"
    "LnRvdGFsX3ByZWRfbGF0ID0gcmQtPnByZWRfbGF0LAoJCX07CgkJaWZyLnNjYWxhciA9IGF0b21pYzY0X3N1Yl9yZXR1cm4oCgkJCWlmcl90b19zdWIuc2Nh"
    "bGFyLCAmYWQtPmluX2ZsaWdodF9ycXMuYXRvbWljKTsKCX0KCXU4IG9wdHlwZSA9IGFkaW9zX29wdHlwZShycSk7CgoJdW5zaWduZWQgbG9uZyBmbGFnczsK"
    "CXN0cnVjdCBhZGlvc19wY3B1X2NvbXBsZXRpb24gKnBjOwoKCWxvY2FsX2lycV9zYXZlKGZsYWdzKTsKCXBjID0gdGhpc19jcHVfcHRyKGFkLT5wY3B1X2Nv"
    "bXBsZXRpb24pOwoKCWlmIChvcHR5cGUgPT0gQURJT1NfT1RIRVIpIHsKCQkvLyBOb24tcG9zaXRpb25hbCBjb21tYW5kcyBtYWtlIHRoZSBoZWFkIHBvc2l0"
    "aW9uIHVucHJlZGljdGFibGUuCgkJLy8gSW52YWxpZGF0ZSBvdXIga25vd2xlZGdlIG9mIHRoZSBsYXN0IGNvbXBsZXRlZCBwb3NpdGlvbi4KCQlpZiAoYWQt"
    "PmlzX3JvdGF0aW9uYWwpCgkJCXBjLT5sYXN0X2NvbXBsZXRlZF9wb3MgPSAwOwoJCWxvY2FsX2lycV9yZXN0b3JlKGZsYWdzKTsKCQlyZXR1cm47Cgl9CgoJ"
    "dTY0IGxjdCA9IHBjLT5sYXN0X2NvbXBsZXRlZF90aW1lID86IHJxLT5pb19zdGFydF90aW1lX25zOwoJcGMtPmxhc3RfY29tcGxldGVkX3RpbWUgPSAoaWZy"
    "LmNvdW50KSA/IG5vdyA6IDA7CgoJaWYgKCFycS0+aW9fc3RhcnRfdGltZV9ucyB8fCAhcmQtPmJsb2NrX3NpemUgfHwgdW5saWtlbHkobm93IDwgbGN0KSkg"
    "ewoJCWxvY2FsX2lycV9yZXN0b3JlKGZsYWdzKTsKCQlyZXR1cm47Cgl9CgoJdTY0IGxhdGVuY3kgPSBub3cgLSBsY3Q7CgoJdTMyIHdlaWdodCA9IDE7Cglp"
    "ZiAoYWQtPmlzX3JvdGF0aW9uYWwpIHsKCQlzZWN0b3JfdCBjdXJyZW50X3BvcyA9IGJsa19ycV9wb3MocnEpOwoJCS8vIE9ubHkgY2FsY3VsYXRlIHNlZWsg"
    "ZGlzdGFuY2UgaWYgd2UgaGF2ZSBhIHZhbGlkIGxhc3QgcG9zaXRpb24uCgkJaWYgKHBjLT5sYXN0X2NvbXBsZXRlZF9wb3MgPiAwKSB7CgkJCXU2NCBzZWVr"
    "X2Rpc3RhbmNlID0gYWJzKAoJCQkJKHM2NCljdXJyZW50X3BvcyAtIChzNjQpcGMtPmxhc3RfY29tcGxldGVkX3Bvcyk7CgkJCWlmIChzZWVrX2Rpc3RhbmNl"
    "KQoJCQkJd2VpZ2h0ID0gNjUgLSBfX2J1aWx0aW5fY2x6bGwoc2Vla19kaXN0YW5jZSk7CgkJfQoJCS8vIFVwZGF0ZSAob3IgcmUtc3luY2hyb25pemUpIG91"
    "ciBrbm93bGVkZ2Ugb2YgdGhlIGhlYWQgcG9zaXRpb24uCgkJcGMtPmxhc3RfY29tcGxldGVkX3BvcyA9IGN1cnJlbnRfcG9zICsgYmxrX3JxX3NlY3RvcnMo"
    "cnEpOwoJfQoKCWxvY2FsX2lycV9yZXN0b3JlKGZsYWdzKTsKCglpZiAobGF0ZW5jeSA+IGFkLT5sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCkKCQlyZXR1cm47"
    "CgoJbGF0ZW5jeV9tb2RlbF9pbnB1dChhZCwgJmFkLT5sYXRlbmN5X21vZGVsW29wdHlwZV0sCgkJcmQtPmJsb2NrX3NpemUsIGxhdGVuY3ksIHJkLT5wcmVk"
    "X2xhdCwgd2VpZ2h0KTsKCXRpbWVyX3JlZHVjZSgmYWQtPnVwZGF0ZV90aW1lciwgamlmZmllcyArIG1zZWNzX3RvX2ppZmZpZXMoMTAwKSk7Cn0KCi8vIENs"
    "ZWFuIHVwIGFmdGVyIGEgcmVxdWVzdCBpcyBmaW5pc2hlZApzdGF0aWMgdm9pZCBhZGlvc19maW5pc2hfcmVxdWVzdChzdHJ1Y3QgcmVxdWVzdCAqcnEpIHsK"
    "CXN0cnVjdCBhZGlvc19kYXRhICphZCA9IHJxLT5xLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCglpZiAocnEtPmVsdi5wcml2WzBdKSB7CgkJLy8gRnJl"
    "ZSBhZGlvc19ycV9kYXRhIGJhY2sgdG8gdGhlIG1lbW9yeSBwb29sCgkJbWVtcG9vbF9mcmVlKGdldF9ycV9kYXRhKHJxKSwgYWQtPnJxX2RhdGFfcG9vbCk7"
    "CgkJcnEtPmVsdi5wcml2WzBdID0gTlVMTDsKCX0KfQoKLy8gQ2hlY2sgaWYgdGhlcmUgYXJlIGFueSByZXF1ZXN0cyBhdmFpbGFibGUgZm9yIGRpc3BhdGNo"
    "CnN0YXRpYyBib29sIGFkaW9zX2hhc193b3JrKHN0cnVjdCBibGtfbXFfaHdfY3R4ICpoY3R4KSB7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBoY3R4LT5x"
    "dWV1ZS0+ZWxldmF0b3ItPmVsZXZhdG9yX2RhdGE7CgoJcmV0dXJuIGF0b21pY19yZWFkKCZhZC0+c3RhdGUpICE9IDA7Cn0KCi8vIEluaXRpYWxpemUgdGhl"
    "IHNjaGVkdWxlci1zcGVjaWZpYyBkYXRhIGZvciBhIGhhcmR3YXJlIHF1ZXVlCnN0YXRpYyBpbnQgYWRpb3NfaW5pdF9oY3R4KHN0cnVjdCBibGtfbXFfaHdf"
    "Y3R4ICpoY3R4LCB1bnNpZ25lZCBpbnQgaGN0eF9pZHgpIHsKCWFkaW9zX2RlcHRoX3VwZGF0ZWQoaGN0eCk7CglyZXR1cm4gMDsKfQoKLy8gSW5pdGlhbGl6"
    "ZSB0aGUgc2NoZWR1bGVyLXNwZWNpZmljIGRhdGEgd2hlbiBpbml0aWFsaXppbmcgdGhlIHJlcXVlc3QgcXVldWUKc3RhdGljIGludCBhZGlvc19pbml0X3Nj"
    "aGVkKHN0cnVjdCByZXF1ZXN0X3F1ZXVlICpxLCBzdHJ1Y3QgZWxldmF0b3JfdHlwZSAqZSkgewoJc3RydWN0IGFkaW9zX2RhdGEgKmFkOwoJc3RydWN0IGVs"
    "ZXZhdG9yX3F1ZXVlICplcTsKCWludCByZXQgPSAtRU5PTUVNOwoJdTggb3B0eXBlID0gMDsKCgllcSA9IGVsZXZhdG9yX2FsbG9jKHEsIGUpOwoJaWYgKCFl"
    "cSkgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBhbGxvY2F0ZSB0aGUgZWxldmF0b3JcbiIpOwoJCXJldHVybiByZXQ7Cgl9CgoJYWQgPSBremFsbG9j"
    "X25vZGUoc2l6ZW9mKCphZCksIEdGUF9LRVJORUwsIHEtPm5vZGUpOwoJaWYgKCFhZCkgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBjcmVhdGUgYWRp"
    "b3NfZGF0YVxuIik7CgkJZ290byBwdXRfZXE7Cgl9CgoJLy8gQ3JlYXRlIGEgbWVtb3J5IHBvb2wgZm9yIGFkaW9zX3JxX2RhdGEKCWFkLT5ycV9kYXRhX2Nh"
    "Y2hlID0ga21lbV9jYWNoZV9jcmVhdGUoImFkaW9zX3JxX2RhdGEiLAoJCQkJCQlzaXplb2Yoc3RydWN0IGFkaW9zX3JxX2RhdGEpLAoJCQkJCQkwLCBTTEFC"
    "X0hXQ0FDSEVfQUxJR04sIE5VTEwpOwoJaWYgKCFhZC0+cnFfZGF0YV9jYWNoZSkgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBjcmVhdGUgcnFfZGF0"
    "YV9jYWNoZVxuIik7CgkJZ290byBmcmVlX2FkOwoJfQoKCWFkLT5ycV9kYXRhX3Bvb2wgPSBtZW1wb29sX2NyZWF0ZV9zbGFiX3Bvb2woCgkJCQkJCXEtPm5y"
    "X3JlcXVlc3RzLCBhZC0+cnFfZGF0YV9jYWNoZSk7CglpZiAoIWFkLT5ycV9kYXRhX3Bvb2wpIHsKCQlwcl9lcnIoImFkaW9zOiBGYWlsZWQgdG8gY3JlYXRl"
    "IHJxX2RhdGFfcG9vbFxuIik7CgkJZ290byBkZXN0cm95X3JxX2RhdGFfY2FjaGU7Cgl9CgoJLyogQ3JlYXRlIGEgbWVtb3J5IHBvb2wgZm9yIGRsX2dyb3Vw"
    "ICovCglhZC0+ZGxfZ3JvdXBfcG9vbCA9IGttZW1fY2FjaGVfY3JlYXRlKCJkbF9ncm91cF9wb29sIiwKCQkJCQkJc2l6ZW9mKHN0cnVjdCBkbF9ncm91cCks"
    "CgkJCQkJCTAsIFNMQUJfSFdDQUNIRV9BTElHTiwgTlVMTCk7CglpZiAoIWFkLT5kbF9ncm91cF9wb29sKSB7CgkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRv"
    "IGNyZWF0ZSBkbF9ncm91cF9wb29sXG4iKTsKCQlnb3RvIGRlc3Ryb3lfcnFfZGF0YV9wb29sOwoJfQoKCWZvciAoaW50IGkgPSAwOyBpIDwgQURJT1NfUFFf"
    "TEVWRUxTOyBpKyspCgkJSU5JVF9MSVNUX0hFQUQoJmFkLT5wcmlvX3F1ZXVlW2ldKTsKCglmb3IgKHU4IGkgPSAwOyBpIDwgQURJT1NfRExfVFlQRVM7IGkr"
    "KykgewoJCWFkLT5kbF90cmVlW2ldID0gUkJfUk9PVF9DQUNIRUQ7CgkJYWQtPmRsX3ByaW9baV0gPSBkZWZhdWx0X2RsX3ByaW9baV07Cgl9CglhZC0+ZGxf"
    "YmlhcyA9IDA7CgoJZm9yICh1OCBwYWdlID0gMDsgcGFnZSA8IEFESU9TX0JRX1BBR0VTOyBwYWdlKyspCgkJZm9yIChvcHR5cGUgPSAwOyBvcHR5cGUgPCBB"
    "RElPU19PUFRZUEVTOyBvcHR5cGUrKykKCQkJSU5JVF9MSVNUX0hFQUQoJmFkLT5iYXRjaF9xdWV1ZVtwYWdlXVtvcHR5cGVdKTsKCglhZC0+YWdncl9idWNr"
    "ZXRzID0ga3phbGxvYyhzaXplb2YoKmFkLT5hZ2dyX2J1Y2tldHMpLCBHRlBfS0VSTkVMKTsKCWlmICghYWQtPmFnZ3JfYnVja2V0cykgewoJCXByX2Vycigi"
    "YWRpb3M6IEZhaWxlZCB0byBhbGxvY2F0ZSBhZ2dyZWdhdGlvbiBidWNrZXRzXG4iKTsKCQlnb3RvIGRlc3Ryb3lfZGxfZ3JvdXBfcG9vbDsKCX0KCglhZC0+"
    "cGNwdV9jb21wbGV0aW9uID0gYWxsb2NfcGVyY3B1KHN0cnVjdCBhZGlvc19wY3B1X2NvbXBsZXRpb24pOwoJaWYgKCFhZC0+cGNwdV9jb21wbGV0aW9uKSB7"
    "CgkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGFsbG9jYXRlIHBlci1DUFUgY29tcGxldGlvbiBkYXRhXG4iKTsKCQlnb3RvIGZyZWVfYWdncl9idWNrZXRz"
    "OwoJfQoKCWZvciAob3B0eXBlID0gMDsgb3B0eXBlIDwgQURJT1NfT1BUWVBFUzsgb3B0eXBlKyspIHsKCQlzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwg"
    "PSAmYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBlXTsKCQlzdHJ1Y3QgbGF0ZW5jeV9tb2RlbF9wYXJhbXMgKnBhcmFtczsKCgkJc3Bpbl9sb2NrX2luaXQoJm1v"
    "ZGVsLT51cGRhdGVfbG9jayk7CgkJcGFyYW1zID0ga3phbGxvYyhzaXplb2YoKnBhcmFtcyksIEdGUF9LRVJORUwpOwoJCWlmICghcGFyYW1zKSB7CgkJCXBy"
    "X2VycigiYWRpb3M6IEZhaWxlZCB0byBhbGxvY2F0ZSBsYXRlbmN5X21vZGVsX3BhcmFtc1xuIik7CgkJCWdvdG8gZnJlZV9idWNrZXRzOwoJCX0KCQlwYXJh"
    "bXMtPmxhc3RfdXBkYXRlX2ppZmZpZXMgPSBqaWZmaWVzOwoJCVJDVV9JTklUX1BPSU5URVIobW9kZWwtPnBhcmFtcywgcGFyYW1zKTsKCgkJbW9kZWwtPnBj"
    "cHVfYnVja2V0cyA9IGFsbG9jX3BlcmNwdShzdHJ1Y3QgbG1fYnVja2V0cyk7CgkJaWYgKCFtb2RlbC0+cGNwdV9idWNrZXRzKSB7CgkJCXByX2VycigiYWRp"
    "b3M6IEZhaWxlZCB0byBhbGxvY2F0ZSBwZXItQ1BVIGJ1Y2tldHNcbiIpOwoJCQlrZnJlZShwYXJhbXMpOwoJCQlnb3RvIGZyZWVfYnVja2V0czsKCQl9CgoJ"
    "CW1vZGVsLT5wY3B1X3NuYXBzaG90ID0gYWxsb2NfcGVyY3B1KHN0cnVjdCBsbV9idWNrZXRzKTsKCQlpZiAoIW1vZGVsLT5wY3B1X3NuYXBzaG90KSB7CgkJ"
    "CXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBhbGxvY2F0ZSBwZXItQ1BVIHNuYXBzaG90XG4iKTsKCQkJZnJlZV9wZXJjcHUobW9kZWwtPnBjcHVfYnVja2V0"
    "cyk7CgkJCWtmcmVlKHBhcmFtcyk7CgkJCWdvdG8gZnJlZV9idWNrZXRzOwoJCX0KCgkJbW9kZWwtPmxtX3Nocmlua19hdF9rcmVxcyAgPSBkZWZhdWx0X2xt"
    "X3Nocmlua19hdF9rcmVxczsKCQltb2RlbC0+bG1fc2hyaW5rX2F0X2dieXRlcyA9IGRlZmF1bHRfbG1fc2hyaW5rX2F0X2dieXRlczsKCQltb2RlbC0+bG1f"
    "c2hyaW5rX3Jlc2lzdCAgICA9IGRlZmF1bHRfbG1fc2hyaW5rX3Jlc2lzdDsKCX0KCglmb3IgKG9wdHlwZSA9IDA7IG9wdHlwZSA8IEFESU9TX09QVFlQRVM7"
    "IG9wdHlwZSsrKSB7CgkJYWQtPmxhdGVuY3lfdGFyZ2V0W29wdHlwZV0gPSBkZWZhdWx0X2xhdGVuY3lfdGFyZ2V0W29wdHlwZV07CgkJYWQtPmJhdGNoX2xp"
    "bWl0W29wdHlwZV0gPSBkZWZhdWx0X2JhdGNoX2xpbWl0W29wdHlwZV07Cgl9CgoJZXEtPmVsZXZhdG9yX2RhdGEgPSBhZDsKCglhZC0+aXNfcm90YXRpb25h"
    "bCA9ICEhKHEtPmxpbWl0cy5mZWF0dXJlcyAmIEJMS19GRUFUX1JPVEFUSU9OQUwpOwoJYWQtPmdsb2JhbF9sYXRlbmN5X3dpbmRvdyA9IChhZC0+aXNfcm90"
    "YXRpb25hbCk/CgkJZGVmYXVsdF9nbG9iYWxfbGF0ZW5jeV93aW5kb3dfcm90YXRpb25hbDoKCQlkZWZhdWx0X2dsb2JhbF9sYXRlbmN5X3dpbmRvdzsKCWFk"
    "LT5icV9yZWZpbGxfYmVsb3dfcmF0aW8gPSBkZWZhdWx0X2JxX3JlZmlsbF9iZWxvd19yYXRpbzsKCWFkLT5sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCA9IGRl"
    "ZmF1bHRfbGF0X21vZGVsX2xhdGVuY3lfbGltaXQ7CglhZC0+YmF0Y2hfb3JkZXIgPSBkZWZhdWx0X2JhdGNoX29yZGVyOwoJYWQtPmNvbXBsaWFuY2VfZmxh"
    "Z3MgPSBkZWZhdWx0X2NvbXBsaWFuY2VfZmxhZ3M7CgoJYWQtPm1vZGVsc19zdGFibGUgPSBmYWxzZTsKCglhdG9taWNfc2V0KCZhZC0+c3RhdGUsIDApOwoK"
    "CXNwaW5fbG9ja19pbml0KCZhZC0+bG9jayk7CglzcGluX2xvY2tfaW5pdCgmYWQtPnBxX2xvY2spOwoJc3Bpbl9sb2NrX2luaXQoJmFkLT5icV9sb2NrKTsK"
    "Cgl0aW1lcl9zZXR1cCgmYWQtPnVwZGF0ZV90aW1lciwgdXBkYXRlX3RpbWVyX2NhbGxiYWNrLCAwKTsKCgkvKiBXZSBkaXNwYXRjaCBmcm9tIHJlcXVlc3Qg"
    "cXVldWUgd2lkZSBpbnN0ZWFkIG9mIGh3IHF1ZXVlICovCglibGtfcXVldWVfZmxhZ19zZXQoUVVFVUVfRkxBR19TUV9TQ0hFRCwgcSk7CgoJYWQtPnF1ZXVl"
    "ID0gcTsKCWJsa19zdGF0X2VuYWJsZV9hY2NvdW50aW5nKHEpOwoKCXEtPmVsZXZhdG9yID0gZXE7CglyZXR1cm4gMDsKCmZyZWVfYnVja2V0czoKCXByX2Vy"
    "cigiYWRpb3M6IEZhaWxlZCB0byBhbGxvY2F0ZSBwZXItY3B1IGJ1Y2tldHNcbiIpOwoJd2hpbGUgKG9wdHlwZS0tID4gMCkgewoJCXN0cnVjdCBsYXRlbmN5"
    "X21vZGVsICpwcmV2X21vZGVsID0gJmFkLT5sYXRlbmN5X21vZGVsW29wdHlwZV07CgkJa2ZyZWUocmN1X2FjY2Vzc19wb2ludGVyKHByZXZfbW9kZWwtPnBh"
    "cmFtcykpOwoJCWZyZWVfcGVyY3B1KHByZXZfbW9kZWwtPnBjcHVfc25hcHNob3QpOwoJCWZyZWVfcGVyY3B1KHByZXZfbW9kZWwtPnBjcHVfYnVja2V0cyk7"
    "Cgl9CglmcmVlX3BlcmNwdShhZC0+cGNwdV9jb21wbGV0aW9uKTsKZnJlZV9hZ2dyX2J1Y2tldHM6CglrZnJlZShhZC0+YWdncl9idWNrZXRzKTsKZGVzdHJv"
    "eV9kbF9ncm91cF9wb29sOgoJa21lbV9jYWNoZV9kZXN0cm95KGFkLT5kbF9ncm91cF9wb29sKTsKZGVzdHJveV9ycV9kYXRhX3Bvb2w6CgltZW1wb29sX2Rl"
    "c3Ryb3koYWQtPnJxX2RhdGFfcG9vbCk7CmRlc3Ryb3lfcnFfZGF0YV9jYWNoZToKCWttZW1fY2FjaGVfZGVzdHJveShhZC0+cnFfZGF0YV9jYWNoZSk7CmZy"
    "ZWVfYWQ6CglrZnJlZShhZCk7CnB1dF9lcToKCWtvYmplY3RfcHV0KCZlcS0+a29iaik7CglyZXR1cm4gcmV0Owp9CgovLyBDbGVhbiB1cCBhbmQgZnJlZSBy"
    "ZXNvdXJjZXMgd2hlbiBleGl0aW5nIHRoZSBzY2hlZHVsZXIKc3RhdGljIHZvaWQgYWRpb3NfZXhpdF9zY2hlZChzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUp"
    "IHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7CgoJdGltZXJfc2h1dGRvd25fc3luYygmYWQtPnVwZGF0ZV90aW1lcik7CgoJ"
    "Zm9yIChpbnQgaSA9IDA7IGkgPCAyOyBpKyspCgkJV0FSTl9PTl9PTkNFKCFsaXN0X2VtcHR5KCZhZC0+cHJpb19xdWV1ZVtpXSkpOwoKCWZvciAodTggaSA9"
    "IDA7IGkgPCBBRElPU19PUFRZUEVTOyBpKyspIHsKCQlzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbaV07CgkJc3Ry"
    "dWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1zICpwYXJhbXMgPSByY3VfYWNjZXNzX3BvaW50ZXIobW9kZWwtPnBhcmFtcyk7CgoJCVJDVV9JTklUX1BPSU5URVIo"
    "bW9kZWwtPnBhcmFtcywgTlVMTCk7CgkJa2ZyZWVfcmN1KHBhcmFtcywgcmN1KTsKCgkJZnJlZV9wZXJjcHUobW9kZWwtPnBjcHVfc25hcHNob3QpOwoJCWZy"
    "ZWVfcGVyY3B1KG1vZGVsLT5wY3B1X2J1Y2tldHMpOwoJfQoKCXN5bmNocm9uaXplX3JjdSgpOwoKCWZyZWVfcGVyY3B1KGFkLT5wY3B1X2NvbXBsZXRpb24p"
    "OwoJa2ZyZWUoYWQtPmFnZ3JfYnVja2V0cyk7CgoJbWVtcG9vbF9kZXN0cm95KGFkLT5ycV9kYXRhX3Bvb2wpOwoJa21lbV9jYWNoZV9kZXN0cm95KGFkLT5y"
    "cV9kYXRhX2NhY2hlKTsKCglpZiAoYWQtPmRsX2dyb3VwX3Bvb2wpCgkJa21lbV9jYWNoZV9kZXN0cm95KGFkLT5kbF9ncm91cF9wb29sKTsKCglibGtfc3Rh"
    "dF9kaXNhYmxlX2FjY291bnRpbmcoYWQtPnF1ZXVlKTsKCglrZnJlZShhZCk7Cn0KCnN0YXRpYyB2b2lkIHNpZGVsb2FkX2xhdGVuY3lfbW9kZWwoCgkJc3Ry"
    "dWN0IGxhdGVuY3lfbW9kZWwgKm1vZGVsLCB1NjQgYmFzZSwgdTY0IHNsb3BlKSB7CglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbF9wYXJhbXMgKm9sZF9wYXJhbXMs"
    "ICpuZXdfcGFyYW1zOwoJdW5zaWduZWQgbG9uZyBmbGFnczsKCgluZXdfcGFyYW1zID0ga3phbGxvYyhzaXplb2YoKm5ld19wYXJhbXMpLCBHRlBfS0VSTkVM"
    "KTsKCWlmICghbmV3X3BhcmFtcykKCQlyZXR1cm47CgoJc3Bpbl9sb2NrX2lycXNhdmUoJm1vZGVsLT51cGRhdGVfbG9jaywgZmxhZ3MpOwoKCW9sZF9wYXJh"
    "bXMgPSByY3VfZGVyZWZlcmVuY2VfcHJvdGVjdGVkKG1vZGVsLT5wYXJhbXMsCgkJCWxvY2tkZXBfaXNfaGVsZCgmbW9kZWwtPnVwZGF0ZV9sb2NrKSk7CgoJ"
    "bmV3X3BhcmFtcy0+bGFzdF91cGRhdGVfamlmZmllcyA9IGppZmZpZXM7CgoJLy8gSW5pdGlhbGl6ZSBiYXNlIGFuZCBpdHMgc3RhdGlzdGljcyBhcyBhIHNp"
    "bmdsZSBzYW1wbGUuCgluZXdfcGFyYW1zLT5iYXNlID0gYmFzZTsKCW5ld19wYXJhbXMtPnNtYWxsX3N1bV9kZWxheSA9IGJhc2U7CgluZXdfcGFyYW1zLT5z"
    "bWFsbF9jb3VudCA9IDE7CgoJLy8gSW5pdGlhbGl6ZSBzbG9wZSBhbmQgaXRzIHN0YXRpc3RpY3MgYXMgYSBzaW5nbGUgc2FtcGxlLgoJbmV3X3BhcmFtcy0+"
    "c2xvcGUgPSBzbG9wZTsKCW5ld19wYXJhbXMtPmxhcmdlX3N1bV9kZWxheSA9IHNsb3BlOwoJbmV3X3BhcmFtcy0+bGFyZ2Vfc3VtX2JzaXplID0gMTAyNDsg"
    "LyogQ29ycmVzcG9uZHMgdG8gMSBLaUIgKi8KCglsbV9yZXNldF9wY3B1X2J1Y2tldHMobW9kZWwpOwoKCXJjdV9hc3NpZ25fcG9pbnRlcihtb2RlbC0+cGFy"
    "YW1zLCBuZXdfcGFyYW1zKTsKCXNwaW5fdW5sb2NrX2lycXJlc3RvcmUoJm1vZGVsLT51cGRhdGVfbG9jaywgZmxhZ3MpOwoKCWtmcmVlX3JjdShvbGRfcGFy"
    "YW1zLCByY3UpOwp9CgovLyBEZWZpbmUgc3lzZnMgYXR0cmlidXRlcyBmb3Igb3BlcmF0aW9uIHR5cGVzCiNkZWZpbmUgU1lTRlNfT1BUWVBFX0RFQ0wobmFt"
    "ZSwgb3B0eXBlKSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zX2xhdF9tb2RlbF8jI25hbWUjI19zaG93KCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBj"
    "aGFyICpwYWdlKSB7IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXN0cnVjdCBsYXRlbmN5X21vZGVsICptb2RlbCA9"
    "ICZhZC0+bGF0ZW5jeV9tb2RlbFtvcHR5cGVdOyBcCglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbF9wYXJhbXMgKnBhcmFtczsgXAoJc3NpemVfdCBsZW4gPSAwOyBc"
    "Cgl1NjQgYmFzZSwgc2xvcGU7IFwKCXJjdV9yZWFkX2xvY2soKTsgXAoJcGFyYW1zID0gcmN1X2RlcmVmZXJlbmNlKG1vZGVsLT5wYXJhbXMpOyBcCgliYXNl"
    "ID0gcGFyYW1zLT5iYXNlOyBcCglzbG9wZSA9IHBhcmFtcy0+c2xvcGU7IFwKCXJjdV9yZWFkX3VubG9jaygpOyBcCglsZW4gKz0gc3ByaW50ZihwYWdlLCAg"
    "ICAgICAiYmFzZSA6ICVsbHUgbnNcbiIsIGJhc2UpOyBcCglsZW4gKz0gc3ByaW50ZihwYWdlICsgbGVuLCAic2xvcGU6ICVsbHUgbnMvS2lCXG4iLCBzbG9w"
    "ZSk7IFwKCXJldHVybiBsZW47IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zX2xhdF9tb2RlbF8jI25hbWUjI19zdG9yZSggXAoJCXN0cnVjdCBlbGV2YXRv"
    "cl9xdWV1ZSAqZSwgY29uc3QgY2hhciAqcGFnZSwgc2l6ZV90IGNvdW50KSB7IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7"
    "IFwKCXN0cnVjdCBsYXRlbmN5X21vZGVsICptb2RlbCA9ICZhZC0+bGF0ZW5jeV9tb2RlbFtvcHR5cGVdOyBcCgl1NjQgYmFzZSwgc2xvcGU7IFwKCWludCBy"
    "ZXQ7IFwKCXJldCA9IHNzY2FuZihwYWdlLCAiJWxsdSAlbGx1IiwgJmJhc2UsICZzbG9wZSk7IFwKCWlmIChyZXQgIT0gMikgXAoJCXJldHVybiAtRUlOVkFM"
    "OyBcCglzaWRlbG9hZF9sYXRlbmN5X21vZGVsKG1vZGVsLCBiYXNlLCBzbG9wZSk7IFwKCXJlc2V0X2J1Y2tldHMoYWQtPmFnZ3JfYnVja2V0cyk7IFwKCXJl"
    "dHVybiBjb3VudDsgXAp9IFwKc3RhdGljIHNzaXplX3QgYWRpb3NfbGF0X3RhcmdldF8jI25hbWUjI19zaG93KCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVl"
    "ICplLCBjaGFyICpwYWdlKSB7IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXJldHVybiBzcHJpbnRmKHBhZ2UsICIl"
    "bGx1XG4iLCBhZC0+bGF0ZW5jeV90YXJnZXRbb3B0eXBlXSk7IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zX2xhdF90YXJnZXRfIyNuYW1lIyNfc3RvcmUo"
    "IFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNvbnN0IGNoYXIgKnBhZ2UsIHNpemVfdCBjb3VudCkgeyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQg"
    "PSBlLT5lbGV2YXRvcl9kYXRhOyBcCgl1bnNpZ25lZCBsb25nIG5zZWM7IFwKCWludCByZXQ7IFwKCXJldCA9IGtzdHJ0b3VsKHBhZ2UsIDEwLCAmbnNlYyk7"
    "IFwKCWlmIChyZXQpIFwKCQlyZXR1cm4gcmV0OyBcCglzaWRlbG9hZF9sYXRlbmN5X21vZGVsKCZhZC0+bGF0ZW5jeV9tb2RlbFtvcHR5cGVdLCAwLCAwKTsg"
    "XAoJYWQtPmxhdGVuY3lfdGFyZ2V0W29wdHlwZV0gPSBuc2VjOyBcCglyZXR1cm4gY291bnQ7IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zX2JhdGNoX2xp"
    "bWl0XyMjbmFtZSMjX3Nob3coIFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNoYXIgKnBhZ2UpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0g"
    "ZS0+ZWxldmF0b3JfZGF0YTsgXAoJcmV0dXJuIHNwcmludGYocGFnZSwgIiV1XG4iLCBhZC0+YmF0Y2hfbGltaXRbb3B0eXBlXSk7IFwKfSBcCnN0YXRpYyBz"
    "c2l6ZV90IGFkaW9zX2JhdGNoX2xpbWl0XyMjbmFtZSMjX3N0b3JlKCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBz"
    "aXplX3QgY291bnQpIHsgXAoJdW5zaWduZWQgbG9uZyBtYXhfYmF0Y2g7IFwKCWludCByZXQ7IFwKCXJldCA9IGtzdHJ0b3VsKHBhZ2UsIDEwLCAmbWF4X2Jh"
    "dGNoKTsgXAoJaWYgKHJldCB8fCBtYXhfYmF0Y2ggPT0gMCkgXAoJCXJldHVybiAtRUlOVkFMOyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2"
    "YXRvcl9kYXRhOyBcCglhZC0+YmF0Y2hfbGltaXRbb3B0eXBlXSA9IG1heF9iYXRjaDsgXAoJcmV0dXJuIGNvdW50OyBcCn0KClNZU0ZTX09QVFlQRV9ERUNM"
    "KHJlYWQsIEFESU9TX1JFQUQpOwpTWVNGU19PUFRZUEVfREVDTCh3cml0ZSwgQURJT1NfV1JJVEUpOwpTWVNGU19PUFRZUEVfREVDTChkaXNjYXJkLCBBRElP"
    "U19ESVNDQVJEKTsKCi8vIFNob3cgdGhlIG1heGltdW0gYmF0Y2ggc2l6ZSBhY3R1YWxseSBhY2hpZXZlZCBmb3IgZWFjaCBvcGVyYXRpb24gdHlwZQpzdGF0"
    "aWMgc3NpemVfdCBhZGlvc19iYXRjaF9hY3R1YWxfbWF4X3Nob3coCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjaGFyICpwYWdlKSB7CglzdHJ1Y3Qg"
    "YWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOwoJdTMyIHRvdGFsX2NvdW50LCByZWFkX2NvdW50LCB3cml0ZV9jb3VudCwgZGlzY2FyZF9jb3Vu"
    "dDsKCgl0b3RhbF9jb3VudCA9IGFkLT5iYXRjaF9hY3R1YWxfbWF4X3RvdGFsOwoJcmVhZF9jb3VudCA9IGFkLT5iYXRjaF9hY3R1YWxfbWF4X3NpemVbQURJ"
    "T1NfUkVBRF07Cgl3cml0ZV9jb3VudCA9IGFkLT5iYXRjaF9hY3R1YWxfbWF4X3NpemVbQURJT1NfV1JJVEVdOwoJZGlzY2FyZF9jb3VudCA9IGFkLT5iYXRj"
    "aF9hY3R1YWxfbWF4X3NpemVbQURJT1NfRElTQ0FSRF07CgoJcmV0dXJuIHNwcmludGYocGFnZSwKCQkiVG90YWwgIDogJXVcbkRpc2NhcmQ6ICV1XG5SZWFk"
    "ICAgOiAldVxuV3JpdGUgIDogJXVcbiIsCgkJdG90YWxfY291bnQsIGRpc2NhcmRfY291bnQsIHJlYWRfY291bnQsIHdyaXRlX2NvdW50KTsKfQoKI2RlZmlu"
    "ZSBTWVNGU19VTExfREVDTChmaWVsZCwgbWluX3ZhbCwgbWF4X3ZhbCkgXApzdGF0aWMgc3NpemVfdCBhZGlvc18jI2ZpZWxkIyNfc2hvdyggXAoJCXN0cnVj"
    "dCBlbGV2YXRvcl9xdWV1ZSAqZSwgY2hhciAqcGFnZSkgeyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBcCglyZXR1cm4g"
    "c3ByaW50ZihwYWdlLCAiJWxsdVxuIiwgYWQtPmZpZWxkKTsgXAp9IFwKc3RhdGljIHNzaXplX3QgYWRpb3NfIyNmaWVsZCMjX3N0b3JlKCBcCgkJc3RydWN0"
    "IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3QgY291bnQpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0"
    "b3JfZGF0YTsgXAoJdW5zaWduZWQgbG9uZyB2YWw7IFwKCWludCByZXQ7IFwKCXJldCA9IGtzdHJ0b3VsKHBhZ2UsIDEwLCAmdmFsKTsgXAoJaWYgKHJldCB8"
    "fCB2YWwgPCAobWluX3ZhbCkgfHwgdmFsID4gKG1heF92YWwpKSBcCgkJcmV0dXJuIC1FSU5WQUw7IFwKCWFkLT5maWVsZCA9IHZhbDsgXAoJcmV0dXJuIGNv"
    "dW50OyBcCn0KClNZU0ZTX1VMTF9ERUNMKGdsb2JhbF9sYXRlbmN5X3dpbmRvdywgMCwgVUxMT05HX01BWCkKU1lTRlNfVUxMX0RFQ0woY29tcGxpYW5jZV9m"
    "bGFncywgMCwgVUxMT05HX01BWCkKCiNkZWZpbmUgU1lTRlNfSU5UX0RFQ0woZmllbGQsIG1pbl92YWwsIG1heF92YWwpIFwKc3RhdGljIHNzaXplX3QgYWRp"
    "b3NfIyNmaWVsZCMjX3Nob3coIFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNoYXIgKnBhZ2UpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0g"
    "ZS0+ZWxldmF0b3JfZGF0YTsgXAoJcmV0dXJuIHNwcmludGYocGFnZSwgIiVkXG4iLCBhZC0+ZmllbGQpOyBcCn0gXApzdGF0aWMgc3NpemVfdCBhZGlvc18j"
    "I2ZpZWxkIyNfc3RvcmUoIFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNvbnN0IGNoYXIgKnBhZ2UsIHNpemVfdCBjb3VudCkgeyBcCglzdHJ1Y3Qg"
    "YWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBcCglpbnQgdmFsOyBcCglpbnQgcmV0OyBcCglyZXQgPSBrc3RydG9pbnQocGFnZSwgMTAsICZ2"
    "YWwpOyBcCglpZiAocmV0IHx8IHZhbCA8IChtaW5fdmFsKSB8fCB2YWwgPiAobWF4X3ZhbCkpIFwKCQlyZXR1cm4gLUVJTlZBTDsgXAoJYWQtPmZpZWxkID0g"
    "dmFsOyBcCglyZXR1cm4gY291bnQ7IFwKfQoKU1lTRlNfSU5UX0RFQ0woYnFfcmVmaWxsX2JlbG93X3JhdGlvLCAwLCAxMDApClNZU0ZTX0lOVF9ERUNMKGxh"
    "dF9tb2RlbF9sYXRlbmN5X2xpbWl0LCAwLCAyKk5TRUNfUEVSX1NFQykKU1lTRlNfSU5UX0RFQ0woYmF0Y2hfb3JkZXIsIEFESU9TX0JPX09QVFlQRSwgISFh"
    "ZC0+aXNfcm90YXRpb25hbCkKCi8vIFNob3cgdGhlIHJlYWQgcHJpb3JpdHkKc3RhdGljIHNzaXplX3QgYWRpb3NfcmVhZF9wcmlvcml0eV9zaG93KAoJCXN0"
    "cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY2hhciAqcGFnZSkgewoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsKCXJldHVybiBz"
    "cHJpbnRmKHBhZ2UsICIlZFxuIiwgYWQtPmRsX3ByaW9bMF0pOwp9CgovLyBTZXQgdGhlIHJlYWQgcHJpb3JpdHkKc3RhdGljIHNzaXplX3QgYWRpb3NfcmVh"
    "ZF9wcmlvcml0eV9zdG9yZSgKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNvbnN0IGNoYXIgKnBhZ2UsIHNpemVfdCBjb3VudCkgewoJc3RydWN0IGFk"
    "aW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsKCWludCBwcmlvOwoJaW50IHJldDsKCglyZXQgPSBrc3RydG9pbnQocGFnZSwgMTAsICZwcmlvKTsK"
    "CWlmIChyZXQgfHwgcHJpbyA8IC0yMCB8fCBwcmlvID4gMTkpCgkJcmV0dXJuIC1FSU5WQUw7CgoJYWRpb3NfZ3VhcmQoc3BpbmxvY2tfaXJxc2F2ZSkoJmFk"
    "LT5sb2NrKTsKCWFkLT5kbF9wcmlvWzBdID0gcHJpbzsKCWFkLT5kbF9iaWFzID0gMDsKCglyZXR1cm4gY291bnQ7Cn0KCi8vIFJlc2V0IGJhdGNoIHF1ZXVl"
    "IHN0YXRpc3RpY3MKc3RhdGljIHNzaXplX3QgYWRpb3NfcmVzZXRfYnFfc3RhdHNfc3RvcmUoCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBj"
    "aGFyICpwYWdlLCBzaXplX3QgY291bnQpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7Cgl1bnNpZ25lZCBsb25nIHZhbDsK"
    "CWludCByZXQ7CgoJcmV0ID0ga3N0cnRvdWwocGFnZSwgMTAsICZ2YWwpOwoJaWYgKHJldCB8fCB2YWwgIT0gMSkKCQlyZXR1cm4gLUVJTlZBTDsKCglmb3Ig"
    "KHU4IGkgPSAwOyBpIDwgQURJT1NfT1BUWVBFUzsgaSsrKQoJCWFkLT5iYXRjaF9hY3R1YWxfbWF4X3NpemVbaV0gPSAwOwoKCWFkLT5iYXRjaF9hY3R1YWxf"
    "bWF4X3RvdGFsID0gMDsKCglyZXR1cm4gY291bnQ7Cn0KCi8vIFJlc2V0IHRoZSBsYXRlbmN5IG1vZGVsIHBhcmFtZXRlcnMgb3IgbG9hZCB0aGVtIGZyb20g"
    "dXNlciBpbnB1dApzdGF0aWMgc3NpemVfdCBhZGlvc19yZXNldF9sYXRfbW9kZWxfc3RvcmUoCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBj"
    "aGFyICpwYWdlLCBzaXplX3QgY291bnQpCnsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7CglzdHJ1Y3QgbGF0ZW5jeV9tb2Rl"
    "bCAqbW9kZWw7CglpbnQgcmV0OwoKCS8qCgkgKiBEaWZmZXJlbnRpYXRlIGJldHdlZW4gdHdvIG1vZGVzIGJhc2VkIG9uIGlucHV0IGZvcm1hdDoKCSAqIDEu"
    "ICIxIjogRnVsbHkgcmVzZXQgdGhlIG1vZGVsIChiYWNrd2FyZCBjb21wYXRpYmlsaXR5KS4KCSAqIDIuICJSX2Jhc2UgUl9zbG9wZSBXX2Jhc2UgV19zbG9w"
    "ZSBEX2Jhc2UgRF9zbG9wZSI6IExvYWQgdmFsdWVzLgoJICovCglpZiAoIXN0cmNocihwYWdlLCAnICcpKSB7CgkJLy8gTW9kZSAxOiBGdWxsIHJlc2V0LgoJ"
    "CXVuc2lnbmVkIGxvbmcgdmFsOwoKCQlyZXQgPSBrc3RydG91bChwYWdlLCAxMCwgJnZhbCk7CgkJaWYgKHJldCB8fCB2YWwgIT0gMSkKCQkJcmV0dXJuIC1F"
    "SU5WQUw7CgoJCWZvciAodTggaSA9IDA7IGkgPCBBRElPU19PUFRZUEVTOyBpKyspIHsKCQkJbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbaV07CgkJCXNp"
    "ZGVsb2FkX2xhdGVuY3lfbW9kZWwobW9kZWwsIDAsIDApOwoJCX0KCX0gZWxzZSB7CgkJLy8gTW9kZSAyOiBMb2FkIGluaXRpYWwgdmFsdWVzIGZvciBhbGwg"
    "bGF0ZW5jeSBtb2RlbHMuCgkJdTY0IHBhcmFtc1szXVsyXTsgLyogMDpiYXNlLCAxOnNsb3BlIGZvciBSLCBXLCBEICovCgoJCXJldCA9IHNzY2FuZihwYWdl"
    "LCAiJWxsdSAlbGx1ICVsbHUgJWxsdSAlbGx1ICVsbHUiLAoJCQkmcGFyYW1zW0FESU9TX1JFQUQgICBdWzBdLCAmcGFyYW1zW0FESU9TX1JFQUQgICBdWzFd"
    "LAoJCQkmcGFyYW1zW0FESU9TX1dSSVRFICBdWzBdLCAmcGFyYW1zW0FESU9TX1dSSVRFICBdWzFdLAoJCQkmcGFyYW1zW0FESU9TX0RJU0NBUkRdWzBdLCAm"
    "cGFyYW1zW0FESU9TX0RJU0NBUkRdWzFdKTsKCgkJaWYgKHJldCAhPSA2KQoJCQlyZXR1cm4gLUVJTlZBTDsKCgkJZm9yICh1OCBpID0gQURJT1NfUkVBRDsg"
    "aSA8PSBBRElPU19ESVNDQVJEOyBpKyspIHsKCQkJbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbaV07CgkJCXNpZGVsb2FkX2xhdGVuY3lfbW9kZWwobW9k"
    "ZWwsIHBhcmFtc1tpXVswXSwgcGFyYW1zW2ldWzFdKTsKCQl9Cgl9CglyZXNldF9idWNrZXRzKGFkLT5hZ2dyX2J1Y2tldHMpOwoKCXJldHVybiBjb3VudDsK"
    "fQoKLy8gU2hvdyB0aGUgQURJT1MgdmVyc2lvbgpzdGF0aWMgc3NpemVfdCBhZGlvc192ZXJzaW9uX3Nob3coc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBj"
    "aGFyICpwYWdlKSB7CglyZXR1cm4gc3ByaW50ZihwYWdlLCAiJXNcbiIsIEFESU9TX1ZFUlNJT04pOwp9CgovLyBEZWZpbmUgc3lzZnMgYXR0cmlidXRlcyBm"
    "b3IgZHluYW1pYyB0aHJlc2hvbGRzCiNkZWZpbmUgU0hSSU5LX1RIUkVTSE9MRF9BVFRSX1JXKG5hbWUsIG1vZGVsX2ZpZWxkLCBtaW5fdmFsdWUsIG1heF92"
    "YWx1ZSkgXApzdGF0aWMgc3NpemVfdCBhZGlvc19zaHJpbmtfIyNuYW1lIyNfc3RvcmUoIFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNvbnN0IGNo"
    "YXIgKnBhZ2UsIHNpemVfdCBjb3VudCkgeyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBcCgl1bnNpZ25lZCBsb25nIHZh"
    "bDsgXAoJaW50IHJldDsgXAoJcmV0ID0ga3N0cnRvdWwocGFnZSwgMTAsICZ2YWwpOyBcCglpZiAocmV0IHx8IHZhbCA8IG1pbl92YWx1ZSB8fCB2YWwgPiBt"
    "YXhfdmFsdWUpIFwKCQlyZXR1cm4gLUVJTlZBTDsgXAoJZm9yICh1OCBpID0gMDsgaSA8IEFESU9TX09QVFlQRVM7IGkrKykgeyBcCgkJc3RydWN0IGxhdGVu"
    "Y3lfbW9kZWwgKm1vZGVsID0gJmFkLT5sYXRlbmN5X21vZGVsW2ldOyBcCgkJdW5zaWduZWQgbG9uZyBmbGFnczsgXAoJCXNwaW5fbG9ja19pcnFzYXZlKCZt"
    "b2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsgXAoJCW1vZGVsLT5tb2RlbF9maWVsZCA9IHZhbDsgXAoJCXNwaW5fdW5sb2NrX2lycXJlc3RvcmUoJm1vZGVs"
    "LT51cGRhdGVfbG9jaywgZmxhZ3MpOyBcCgl9IFwKCXJldHVybiBjb3VudDsgXAp9IFwKc3RhdGljIHNzaXplX3QgYWRpb3Nfc2hyaW5rXyMjbmFtZSMjX3No"
    "b3coIFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNoYXIgKnBhZ2UpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0"
    "YTsgXAoJdTMyIHZhbCA9IDA7IFwKCXVuc2lnbmVkIGxvbmcgZmxhZ3M7IFwKCXN0cnVjdCBsYXRlbmN5X21vZGVsICptb2RlbCA9ICZhZC0+bGF0ZW5jeV9t"
    "b2RlbFswXTsgXAoJc3Bpbl9sb2NrX2lycXNhdmUoJm1vZGVsLT51cGRhdGVfbG9jaywgZmxhZ3MpOyBcCgl2YWwgPSBtb2RlbC0+bW9kZWxfZmllbGQ7IFwK"
    "CXNwaW5fdW5sb2NrX2lycXJlc3RvcmUoJm1vZGVsLT51cGRhdGVfbG9jaywgZmxhZ3MpOyBcCglyZXR1cm4gc3ByaW50ZihwYWdlLCAiJXVcbiIsIHZhbCk7"
    "IFwKfQoKU0hSSU5LX1RIUkVTSE9MRF9BVFRSX1JXKGF0X2tyZXFzLCAgbG1fc2hyaW5rX2F0X2tyZXFzLCAgMSwgMTAwMDAwKQpTSFJJTktfVEhSRVNIT0xE"
    "X0FUVFJfUlcoYXRfZ2J5dGVzLCBsbV9zaHJpbmtfYXRfZ2J5dGVzLCAxLCAgIDEwMDApClNIUklOS19USFJFU0hPTERfQVRUUl9SVyhyZXNpc3QsICAgIGxt"
    "X3Nocmlua19yZXNpc3QsICAgIDEsICAgICAgMykKCi8vIERlZmluZSBzeXNmcyBhdHRyaWJ1dGVzCiNkZWZpbmUgQURfQVRUUihuYW1lLCBzaG93X2Z1bmMs"
    "IHN0b3JlX2Z1bmMpIFwKCV9fQVRUUihuYW1lLCAwNjQ0LCBzaG93X2Z1bmMsIHN0b3JlX2Z1bmMpCiNkZWZpbmUgQURfQVRUUl9SVyhuYW1lKSBcCglfX0FU"
    "VFIobmFtZSwgMDY0NCwgYWRpb3NfIyNuYW1lIyNfc2hvdywgYWRpb3NfIyNuYW1lIyNfc3RvcmUpCiNkZWZpbmUgQURfQVRUUl9STyhuYW1lKSBcCglfX0FU"
    "VFIobmFtZSwgMDQ0NCwgYWRpb3NfIyNuYW1lIyNfc2hvdywgTlVMTCkKI2RlZmluZSBBRF9BVFRSX1dPKG5hbWUpIFwKCV9fQVRUUihuYW1lLCAwMjAwLCBO"
    "VUxMLCBhZGlvc18jI25hbWUjI19zdG9yZSkKCi8vIERlZmluZSBzeXNmcyBhdHRyaWJ1dGVzIGZvciBBRElPUyBzY2hlZHVsZXIKc3RhdGljIHN0cnVjdCBl"
    "bHZfZnNfZW50cnkgYWRpb3Nfc2NoZWRfYXR0cnNbXSA9IHsKCUFEX0FUVFJfUk8oYmF0Y2hfYWN0dWFsX21heCksCglBRF9BVFRSX1JXKGJxX3JlZmlsbF9i"
    "ZWxvd19yYXRpbyksCglBRF9BVFRSX1JXKGdsb2JhbF9sYXRlbmN5X3dpbmRvdyksCglBRF9BVFRSX1JXKGxhdF9tb2RlbF9sYXRlbmN5X2xpbWl0KSwKCUFE"
    "X0FUVFJfUlcoYmF0Y2hfb3JkZXIpLAoJQURfQVRUUl9SVyhjb21wbGlhbmNlX2ZsYWdzKSwKCglBRF9BVFRSX1JXKGJhdGNoX2xpbWl0X3JlYWQpLAoJQURf"
    "QVRUUl9SVyhiYXRjaF9saW1pdF93cml0ZSksCglBRF9BVFRSX1JXKGJhdGNoX2xpbWl0X2Rpc2NhcmQpLAoKCUFEX0FUVFJfUlcobGF0X21vZGVsX3JlYWQp"
    "LAoJQURfQVRUUl9SVyhsYXRfbW9kZWxfd3JpdGUpLAoJQURfQVRUUl9SVyhsYXRfbW9kZWxfZGlzY2FyZCksCgoJQURfQVRUUl9SVyhsYXRfdGFyZ2V0X3Jl"
    "YWQpLAoJQURfQVRUUl9SVyhsYXRfdGFyZ2V0X3dyaXRlKSwKCUFEX0FUVFJfUlcobGF0X3RhcmdldF9kaXNjYXJkKSwKCglBRF9BVFRSX1JXKHNocmlua19h"
    "dF9rcmVxcyksCglBRF9BVFRSX1JXKHNocmlua19hdF9nYnl0ZXMpLAoJQURfQVRUUl9SVyhzaHJpbmtfcmVzaXN0KSwKCglBRF9BVFRSX1JXKHJlYWRfcHJp"
    "b3JpdHkpLAoKCUFEX0FUVFJfV08ocmVzZXRfYnFfc3RhdHMpLAoJQURfQVRUUl9XTyhyZXNldF9sYXRfbW9kZWwpLAoJQURfQVRUUihhZGlvc192ZXJzaW9u"
    "LCBhZGlvc192ZXJzaW9uX3Nob3csIE5VTEwpLAoKCV9fQVRUUl9OVUxMCn07CgovLyBEZWZpbmUgdGhlIEFESU9TIHNjaGVkdWxlciB0eXBlCnN0YXRpYyBz"
    "dHJ1Y3QgZWxldmF0b3JfdHlwZSBtcV9hZGlvcyA9IHsKCS5vcHMgPSB7CgkJLm5leHRfcmVxdWVzdAkJPSBlbHZfcmJfbGF0dGVyX3JlcXVlc3QsCgkJLmZv"
    "cm1lcl9yZXF1ZXN0CQk9IGVsdl9yYl9mb3JtZXJfcmVxdWVzdCwKCQkubGltaXRfZGVwdGgJCT0gYWRpb3NfbGltaXRfZGVwdGgsCgkJLmRlcHRoX3VwZGF0"
    "ZWQJCT0gYWRpb3NfZGVwdGhfdXBkYXRlZCwKCQkucmVxdWVzdF9tZXJnZWQJCT0gYWRpb3NfcmVxdWVzdF9tZXJnZWQsCgkJLnJlcXVlc3RzX21lcmdlZAk9"
    "IGFkaW9zX21lcmdlZF9yZXF1ZXN0cywKCQkuYmlvX21lcmdlCQkJPSBhZGlvc19iaW9fbWVyZ2UsCgkJLmluc2VydF9yZXF1ZXN0cwk9IGFkaW9zX2luc2Vy"
    "dF9yZXF1ZXN0cywKCQkucHJlcGFyZV9yZXF1ZXN0CT0gYWRpb3NfcHJlcGFyZV9yZXF1ZXN0LAoJCS5kaXNwYXRjaF9yZXF1ZXN0CT0gYWRpb3NfZGlzcGF0"
    "Y2hfcmVxdWVzdCwKCQkuY29tcGxldGVkX3JlcXVlc3QJPSBhZGlvc19jb21wbGV0ZWRfcmVxdWVzdCwKCQkuZmluaXNoX3JlcXVlc3QJCT0gYWRpb3NfZmlu"
    "aXNoX3JlcXVlc3QsCgkJLmhhc193b3JrCQkJPSBhZGlvc19oYXNfd29yaywKCQkuaW5pdF9oY3R4CQkJPSBhZGlvc19pbml0X2hjdHgsCgkJLmluaXRfc2No"
    "ZWQJCQk9IGFkaW9zX2luaXRfc2NoZWQsCgkJLmV4aXRfc2NoZWQJCQk9IGFkaW9zX2V4aXRfc2NoZWQsCgl9LAoJLmVsZXZhdG9yX2F0dHJzID0gYWRpb3Nf"
    "c2NoZWRfYXR0cnMsCgkuZWxldmF0b3JfbmFtZSA9ICJhZGlvcyIsCgkuZWxldmF0b3Jfb3duZXIgPSBUSElTX01PRFVMRSwKfTsKTU9EVUxFX0FMSUFTKCJt"
    "cS1hZGlvcy1pb3NjaGVkIik7CgojZGVmaW5lIEFESU9TX1BST0dOQU1FICJBZGFwdGl2ZSBEZWFkbGluZSBJL08gU2NoZWR1bGVyIgojZGVmaW5lIEFESU9T"
    "X0FVVEhPUiAgICJNYXNhaGl0byBTdXp1a2kiCgovLyBJbml0aWFsaXplIHRoZSBBRElPUyBzY2hlZHVsZXIgbW9kdWxlCnN0YXRpYyBpbnQgX19pbml0IGFk"
    "aW9zX2luaXQodm9pZCkgewoJcHJpbnRrKEtFUk5fSU5GTyAiJXMgJXMgYnkgJXNcbiIsCgkJQURJT1NfUFJPR05BTUUsIEFESU9TX1ZFUlNJT04sIEFESU9T"
    "X0FVVEhPUik7CglyZXR1cm4gZWx2X3JlZ2lzdGVyKCZtcV9hZGlvcyk7Cn0KCi8vIEV4aXQgdGhlIEFESU9TIHNjaGVkdWxlciBtb2R1bGUKc3RhdGljIHZv"
    "aWQgX19leGl0IGFkaW9zX2V4aXQodm9pZCkgewoJZWx2X3VucmVnaXN0ZXIoJm1xX2FkaW9zKTsKfQoKbW9kdWxlX2luaXQoYWRpb3NfaW5pdCk7Cm1vZHVs"
    "ZV9leGl0KGFkaW9zX2V4aXQpOwoKTU9EVUxFX0FVVEhPUihBRElPU19BVVRIT1IpOwpNT0RVTEVfTElDRU5TRSgiR1BMIik7Ck1PRFVMRV9ERVNDUklQVElP"
    "TihBRElPU19QUk9HTkFNRSk7Cg=="
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
