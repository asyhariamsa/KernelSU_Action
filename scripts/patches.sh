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



# ---------------------------------------------------------- SUSFS (manual) ---
# SUSFS 1.5.5 kernel-side only. The upstream KSU-side patch targets the old
# flat KernelSU layout and cannot apply to xxKSU's modular tree, so we define
# the Kconfig symbols ourselves and skip that patch. Only experimental.
susfs_manual_apply() {
	group "Applying SUSFS 1.5.5 kernel-side (5.4 fuzz port)"
	local pf="${WORKSPACE}/susfs-kernel-5.4.patch"

	python3 - "$pf" <<'PY'
import sys, base64
pf = sys.argv[1]
b64 = (
    "ZGlmZiAtLWdpdCBhL2ZzL01ha2VmaWxlIGIvZnMvTWFrZWZpbGUKaW5kZXggM2Q3MTdhNjdkNDM1Li4xZTFhNDk4MGEyZjQgMTAwNjQ0Ci0tLSBhL2ZzL01h"
    "a2VmaWxlCisrKyBiL2ZzL01ha2VmaWxlCkBAIC0xNSw2ICsxNSw4IEBAIG9iai15IDo9CW9wZW4ubyByZWFkX3dyaXRlLm8gZmlsZV90YWJsZS5vIHN1cGVy"
    "Lm8gXAogCQlzdGFjay5vIGZzX3N0cnVjdC5vIHN0YXRmcy5vIGZzX3Bpbi5vIG5zZnMubyBcCiAJCWZzX3R5cGVzLm8gZnNfY29udGV4dC5vIGZzX3BhcnNl"
    "ci5vIGZzb3Blbi5vCiAKK29iai0kKENPTkZJR19LU1VfU1VTRlMpICs9IHN1c2ZzLm8KKwogaWZlcSAoJChDT05GSUdfQkxPQ0spLHkpCiBvYmoteSArPQli"
    "dWZmZXIubyBibG9ja19kZXYubyBkaXJlY3QtaW8ubyBtcGFnZS5vCiBlbHNlCmRpZmYgLS1naXQgYS9mcy9kY2FjaGUuYyBiL2ZzL2RjYWNoZS5jCmluZGV4"
    "IDc4MDgxYmRjNDkzMS4uZjllN2ZlNjE4ZjFlIDEwMDY0NAotLS0gYS9mcy9kY2FjaGUuYworKysgYi9mcy9kY2FjaGUuYwpAQCAtMzIsNiArMzIsOSBAQAog"
    "I2luY2x1ZGUgPGxpbnV4L2JpdF9zcGlubG9jay5oPgogI2luY2x1ZGUgPGxpbnV4L3JjdWxpc3RfYmwuaD4KICNpbmNsdWRlIDxsaW51eC9saXN0X2xydS5o"
    "PgorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX1BBVEgKKyNpbmNsdWRlIDxsaW51eC9zdXNmc19kZWYuaD4KKyNlbmRpZgogI2luY2x1ZGUgImludGVy"
    "bmFsLmgiCiAjaW5jbHVkZSAibW91bnQuaCIKIApAQCAtMjI5NSw2ICsyMjk4LDExIEBAIHN0cnVjdCBkZW50cnkgKl9fZF9sb29rdXBfcmN1KGNvbnN0IHN0"
    "cnVjdCBkZW50cnkgKnBhcmVudCwKIAkJCQljb250aW51ZTsKIAkJCWlmIChkZW50cnlfY21wKGRlbnRyeSwgc3RyLCBoYXNobGVuX2xlbihoYXNobGVuKSkg"
    "IT0gMCkKIAkJCQljb250aW51ZTsKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19QQVRICisJCQlpZiAoZGVudHJ5LT5kX2lub2RlICYmIHVubGlrZWx5"
    "KGRlbnRyeS0+ZF9pbm9kZS0+aV9zdGF0ZSAmIElOT0RFX1NUQVRFX1NVU19QQVRIKSAmJiBsaWtlbHkoY3VycmVudC0+c3VzZnNfdGFza19zdGF0ZSAmIFRB"
    "U0tfU1RSVUNUX05PTl9ST09UX1VTRVJfQVBQX1BST0MpKSB7CisJCQkJY29udGludWU7CisJCQl9CisjZW5kaWYKIAkJfQogCQkqc2VxcCA9IHNlcTsKIAkJ"
    "cmV0dXJuIGRlbnRyeTsKQEAgLTIzNzgsNiArMjM4NiwxMiBAQCBzdHJ1Y3QgZGVudHJ5ICpfX2RfbG9va3VwKGNvbnN0IHN0cnVjdCBkZW50cnkgKnBhcmVu"
    "dCwgY29uc3Qgc3RydWN0IHFzdHIgKm5hbWUpCiAJCWlmIChkZW50cnktPmRfbmFtZS5oYXNoICE9IGhhc2gpCiAJCQljb250aW51ZTsKIAorI2lmZGVmIENP"
    "TkZJR19LU1VfU1VTRlNfU1VTX1BBVEgKKwkJaWYgKGRlbnRyeS0+ZF9pbm9kZSAmJiB1bmxpa2VseShkZW50cnktPmRfaW5vZGUtPmlfc3RhdGUgJiBJTk9E"
    "RV9TVEFURV9TVVNfUEFUSCkgJiYgbGlrZWx5KGN1cnJlbnQtPnN1c2ZzX3Rhc2tfc3RhdGUgJiBUQVNLX1NUUlVDVF9OT05fUk9PVF9VU0VSX0FQUF9QUk9D"
    "KSkgeworCQkJY29udGludWU7CisJCX0KKyNlbmRpZgorCiAJCXNwaW5fbG9jaygmZGVudHJ5LT5kX2xvY2spOwogCQlpZiAoZGVudHJ5LT5kX3BhcmVudCAh"
    "PSBwYXJlbnQpCiAJCQlnb3RvIG5leHQ7CmRpZmYgLS1naXQgYS9mcy9kZXZwdHMvaW5vZGUuYyBiL2ZzL2RldnB0cy9pbm9kZS5jCmluZGV4IDRmMjUwMTVh"
    "YTUzNC4uMjkzOGFhMmE4MDhlIDEwMDY0NAotLS0gYS9mcy9kZXZwdHMvaW5vZGUuYworKysgYi9mcy9kZXZwdHMvaW5vZGUuYwpAQCAtNTk2LDYgKzU5Niwx"
    "MSBAQCBzdHJ1Y3QgZGVudHJ5ICpkZXZwdHNfcHR5X25ldyhzdHJ1Y3QgcHRzX2ZzX2luZm8gKmZzaSwgaW50IGluZGV4LCB2b2lkICpwcml2KQogCXJldHVy"
    "biBkZW50cnk7CiB9CiAKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19TVQorZXh0ZXJuIGJvb2wga3N1X2RldnB0c19ob29rOworZXh0ZXJuIGludCBr"
    "c3VfaGFuZGxlX2RldnB0cyhzdHJ1Y3QgaW5vZGUqKTsKKyNlbmRpZgorCiAvKioKICAqIGRldnB0c19nZXRfcHJpdiAtLSBnZXQgcHJpdmF0ZSBkYXRhIGZv"
    "ciBhIHNsYXZlCiAgKiBAcHRzX2lub2RlOiBpbm9kZSBvZiB0aGUgc2xhdmUKQEAgLTYwNCw2ICs2MDksMTIgQEAgc3RydWN0IGRlbnRyeSAqZGV2cHRzX3B0"
    "eV9uZXcoc3RydWN0IHB0c19mc19pbmZvICpmc2ksIGludCBpbmRleCwgdm9pZCAqcHJpdikKICAqLwogdm9pZCAqZGV2cHRzX2dldF9wcml2KHN0cnVjdCBk"
    "ZW50cnkgKmRlbnRyeSkKIHsKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19TVQorCWlmIChsaWtlbHkoa3N1X2RldnB0c19ob29rKSkgeworCQlrc3Vf"
    "aGFuZGxlX2RldnB0cyhkZW50cnktPmRfaW5vZGUpOworCX0KKyNlbmRpZgorCiAJaWYgKGRlbnRyeS0+ZF9zYi0+c19tYWdpYyAhPSBERVZQVFNfU1VQRVJf"
    "TUFHSUMpCiAJCXJldHVybiBOVUxMOwogCXJldHVybiBkZW50cnktPmRfZnNkYXRhOwpkaWZmIC0tZ2l0IGEvZnMvZXhlYy5jIGIvZnMvZXhlYy5jCmluZGV4"
    "IDRmZDljZWZiNTZiNS4uOTViODkzMzdlNTYyIDEwMDY0NAotLS0gYS9mcy9leGVjLmMKKysrIGIvZnMvZXhlYy5jCkBAIC0xOTE5LDExICsxOTE5LDIxIEBA"
    "IHN0YXRpYyBpbnQgX19kb19leGVjdmVfZmlsZShpbnQgZmQsIHN0cnVjdCBmaWxlbmFtZSAqZmlsZW5hbWUsCiAJcmV0dXJuIHJldHZhbDsKIH0KIAorI2lm"
    "ZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX1NVCitleHRlcm4gYm9vbCBzdXNmc19pc19zdXNfc3VfaG9va3NfZW5hYmxlZCBfX3JlYWRfbW9zdGx5OworZXh0"
    "ZXJuIGludCBrc3VfaGFuZGxlX2V4ZWN2ZWF0X3N1Y29tcGF0KGludCAqZmQsIHN0cnVjdCBmaWxlbmFtZSAqKmZpbGVuYW1lX3B0ciwgdm9pZCAqYXJndiwK"
    "KwkJCQl2b2lkICplbnZwLCBpbnQgKmZsYWdzKTsKKyNlbmRpZgorCiBzdGF0aWMgaW50IGRvX2V4ZWN2ZWF0X2NvbW1vbihpbnQgZmQsIHN0cnVjdCBmaWxl"
    "bmFtZSAqZmlsZW5hbWUsCiAJCQkgICAgICBzdHJ1Y3QgdXNlcl9hcmdfcHRyIGFyZ3YsCiAJCQkgICAgICBzdHJ1Y3QgdXNlcl9hcmdfcHRyIGVudnAsCiAJ"
    "CQkgICAgICBpbnQgZmxhZ3MpCiB7CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfU1UKKwlpZiAoc3VzZnNfaXNfc3VzX3N1X2hvb2tzX2VuYWJsZWQp"
    "CisJCWtzdV9oYW5kbGVfZXhlY3ZlYXRfc3Vjb21wYXQoJmZkLCAmZmlsZW5hbWUsICZhcmd2LCAmZW52cCwgJmZsYWdzKTsKKyNlbmRpZgogCXJldHVybiBf"
    "X2RvX2V4ZWN2ZV9maWxlKGZkLCBmaWxlbmFtZSwgYXJndiwgZW52cCwgZmxhZ3MsIE5VTEwpOwogfQogCmRpZmYgLS1naXQgYS9mcy9uYW1laS5jIGIvZnMv"
    "bmFtZWkuYwppbmRleCA0OGM1N2JmMjU1OTEuLmMzNmY0MDJhMTgxNyAxMDA2NDQKLS0tIGEvZnMvbmFtZWkuYworKysgYi9mcy9uYW1laS5jCkBAIC0zOSw2"
    "ICszOSwxMCBAQAogI2luY2x1ZGUgPGxpbnV4L2JpdG9wcy5oPgogI2luY2x1ZGUgPGxpbnV4L2luaXRfdGFzay5oPgogI2luY2x1ZGUgPGxpbnV4L3VhY2Nl"
    "c3MuaD4KKyNpZiBkZWZpbmVkKENPTkZJR19LU1VfU1VTRlNfU1VTX1BBVEgpIHx8IGRlZmluZWQoQ09ORklHX0tTVV9TVVNGU19PUEVOX1JFRElSRUNUKQor"
    "I2luY2x1ZGUgPGxpbnV4L3N1c2ZzX2RlZi5oPgorI2VuZGlmCisKIAogI2luY2x1ZGUgImludGVybmFsLmgiCiAjaW5jbHVkZSAibW91bnQuaCIKQEAgLTk4"
    "Nyw2ICs5OTEsMTIgQEAgc3RhdGljIGlubGluZSBpbnQgbWF5X2ZvbGxvd19saW5rKHN0cnVjdCBuYW1laWRhdGEgKm5kKQogCWNvbnN0IHN0cnVjdCBpbm9k"
    "ZSAqcGFyZW50OwogCWt1aWRfdCBwdWlkOwogCisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfUEFUSAorCWlmIChuZC0+aW5vZGUgJiYgdW5saWtlbHko"
    "bmQtPmlub2RlLT5pX3N0YXRlICYgSU5PREVfU1RBVEVfU1VTX1BBVEgpICYmIGxpa2VseShjdXJyZW50LT5zdXNmc190YXNrX3N0YXRlICYgVEFTS19TVFJV"
    "Q1RfTk9OX1JPT1RfVVNFUl9BUFBfUFJPQykpIHsKKwkJcmV0dXJuIC1FTk9FTlQ7CisJfQorI2VuZGlmCisKIAlpZiAoIXN5c2N0bF9wcm90ZWN0ZWRfc3lt"
    "bGlua3MpCiAJCXJldHVybiAwOwogCkBAIC0xMDY0LDYgKzEwNzQsMTIgQEAgc3RhdGljIGludCBtYXlfbGlua2F0KHN0cnVjdCBwYXRoICpsaW5rKQogewog"
    "CXN0cnVjdCBpbm9kZSAqaW5vZGUgPSBsaW5rLT5kZW50cnktPmRfaW5vZGU7CiAKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19QQVRICisJaWYgKGlu"
    "b2RlICYmIHVubGlrZWx5KGlub2RlLT5pX3N0YXRlICYgSU5PREVfU1RBVEVfU1VTX1BBVEgpICYmIGxpa2VseShjdXJyZW50LT5zdXNmc190YXNrX3N0YXRl"
    "ICYgVEFTS19TVFJVQ1RfTk9OX1JPT1RfVVNFUl9BUFBfUFJPQykpIHsKKwkJcmV0dXJuIC1FTk9FTlQ7CisJfQorI2VuZGlmCisKIAkvKiBJbm9kZSB3cml0"
    "ZWJhY2sgaXMgbm90IHNhZmUgd2hlbiB0aGUgdWlkIG9yIGdpZCBhcmUgaW52YWxpZC4gKi8KIAlpZiAoIXVpZF92YWxpZChpbm9kZS0+aV91aWQpIHx8ICFn"
    "aWRfdmFsaWQoaW5vZGUtPmlfZ2lkKSkKIAkJcmV0dXJuIC1FT1ZFUkZMT1c7CkBAIC0xMTA1LDYgKzExMjEsMTIgQEAgc3RhdGljIGludCBtYXlfbGlua2F0"
    "KHN0cnVjdCBwYXRoICpsaW5rKQogc3RhdGljIGludCBtYXlfY3JlYXRlX2luX3N0aWNreSh1bW9kZV90IGRpcl9tb2RlLCBrdWlkX3QgZGlyX3VpZCwKIAkJ"
    "CQlzdHJ1Y3QgaW5vZGUgKiBjb25zdCBpbm9kZSkKIHsKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19QQVRICisJaWYgKHVubGlrZWx5KGlub2RlLT5p"
    "X3N0YXRlICYgSU5PREVfU1RBVEVfU1VTX1BBVEgpICYmIGxpa2VseShjdXJyZW50LT5zdXNmc190YXNrX3N0YXRlICYgVEFTS19TVFJVQ1RfTk9OX1JPT1Rf"
    "VVNFUl9BUFBfUFJPQykpIHsKKwkJcmV0dXJuIC1FTk9FTlQ7CisJfQorI2VuZGlmCisKIAlpZiAoKCFzeXNjdGxfcHJvdGVjdGVkX2ZpZm9zICYmIFNfSVNG"
    "SUZPKGlub2RlLT5pX21vZGUpKSB8fAogCSAgICAoIXN5c2N0bF9wcm90ZWN0ZWRfcmVndWxhciAmJiBTX0lTUkVHKGlub2RlLT5pX21vZGUpKSB8fAogCSAg"
    "ICBsaWtlbHkoIShkaXJfbW9kZSAmIFNfSVNWVFgpKSB8fApAQCAtMTYyNSw2ICsxNjQ3LDEyIEBAIHN0YXRpYyBzdHJ1Y3QgZGVudHJ5ICpfX2xvb2t1cF9o"
    "YXNoKGNvbnN0IHN0cnVjdCBxc3RyICpuYW1lLAogCQlkcHV0KGRlbnRyeSk7CiAJCWRlbnRyeSA9IG9sZDsKIAl9CisjaWZkZWYgQ09ORklHX0tTVV9TVVNG"
    "U19TVVNfUEFUSAorCWlmICghSVNfRVJSKGRlbnRyeSkgJiYgZGVudHJ5LT5kX2lub2RlICYmIHVubGlrZWx5KGRlbnRyeS0+ZF9pbm9kZS0+aV9zdGF0ZSAm"
    "IElOT0RFX1NUQVRFX1NVU19QQVRIKSAmJiBsaWtlbHkoY3VycmVudC0+c3VzZnNfdGFza19zdGF0ZSAmIFRBU0tfU1RSVUNUX05PTl9ST09UX1VTRVJfQVBQ"
    "X1BST0MpKSB7CisJCWRwdXQoZGVudHJ5KTsKKwkJcmV0dXJuIEVSUl9QVFIoLUVOT0VOVCk7CisJfQorI2VuZGlmCiAJcmV0dXJuIGRlbnRyeTsKIH0KIApA"
    "QCAtMTc1Miw2ICsxNzgwLDEyIEBAIHN0YXRpYyBzdHJ1Y3QgZGVudHJ5ICpfX2xvb2t1cF9zbG93KGNvbnN0IHN0cnVjdCBxc3RyICpuYW1lLAogCQkJZGVu"
    "dHJ5ID0gb2xkOwogCQl9CiAJfQorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX1BBVEgKKwlpZiAoIUlTX0VSUihkZW50cnkpICYmIGRlbnRyeS0+ZF9p"
    "bm9kZSAmJiB1bmxpa2VseShkZW50cnktPmRfaW5vZGUtPmlfc3RhdGUgJiBJTk9ERV9TVEFURV9TVVNfUEFUSCkgJiYgbGlrZWx5KGN1cnJlbnQtPnN1c2Zz"
    "X3Rhc2tfc3RhdGUgJiBUQVNLX1NUUlVDVF9OT05fUk9PVF9VU0VSX0FQUF9QUk9DKSkgeworCQlkcHV0KGRlbnRyeSk7CisJCXJldHVybiBFUlJfUFRSKC1F"
    "Tk9FTlQpOworCX0KKyNlbmRpZgogCXJldHVybiBkZW50cnk7CiB9CiAKQEAgLTIyNDAsNiArMjI3NCwxMiBAQCBzdGF0aWMgaW50IGxpbmtfcGF0aF93YWxr"
    "KGNvbnN0IGNoYXIgKm5hbWUsIHN0cnVjdCBuYW1laWRhdGEgKm5kKQogCQkJfQogCQkJcmV0dXJuIC1FTk9URElSOwogCQl9CisjaWZkZWYgQ09ORklHX0tT"
    "VV9TVVNGU19TVVNfUEFUSAorCQkvLyB3ZSBkZWFsIHdpdGggc3VzIHN1YiBwYXRoIGhlcmUKKwkJaWYgKG5kLT5pbm9kZSAmJiB1bmxpa2VseShuZC0+aW5v"
    "ZGUtPmlfc3RhdGUgJiBJTk9ERV9TVEFURV9TVVNfUEFUSCkgJiYgbGlrZWx5KGN1cnJlbnQtPnN1c2ZzX3Rhc2tfc3RhdGUgJiBUQVNLX1NUUlVDVF9OT05f"
    "Uk9PVF9VU0VSX0FQUF9QUk9DKSkgeworCQkJcmV0dXJuIDA7CisJCX0KKyNlbmRpZgogCX0KIH0KIApAQCAtMjQyOSw2ICsyNDY5LDEyIEBAIGludCBmaWxl"
    "bmFtZV9sb29rdXAoaW50IGRmZCwgc3RydWN0IGZpbGVuYW1lICpuYW1lLCB1bnNpZ25lZCBmbGFncywKIAlpZiAobGlrZWx5KCFyZXR2YWwpKQogCQlhdWRp"
    "dF9pbm9kZShuYW1lLCBwYXRoLT5kZW50cnksIDApOwogCXJlc3RvcmVfbmFtZWlkYXRhKCk7CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfUEFUSAor"
    "CWlmICghcmV0dmFsICYmIHBhdGgtPmRlbnRyeS0+ZF9pbm9kZSAmJiB1bmxpa2VseShwYXRoLT5kZW50cnktPmRfaW5vZGUtPmlfc3RhdGUgJiBJTk9ERV9T"
    "VEFURV9TVVNfUEFUSCkgJiYgbGlrZWx5KGN1cnJlbnQtPnN1c2ZzX3Rhc2tfc3RhdGUgJiBUQVNLX1NUUlVDVF9OT05fUk9PVF9VU0VSX0FQUF9QUk9DKSkg"
    "eworCQlwdXRuYW1lKG5hbWUpOworCQlyZXR1cm4gLUVOT0VOVDsKKwl9CisjZW5kaWYKIAlwdXRuYW1lKG5hbWUpOwogCXJldHVybiByZXR2YWw7CiB9CkBA"
    "IC0yOTA1LDYgKzI5NTEsMTIgQEAgc3RhdGljIGludCBtYXlfZGVsZXRlKHN0cnVjdCBpbm9kZSAqZGlyLCBzdHJ1Y3QgZGVudHJ5ICp2aWN0aW0sIGJvb2wg"
    "aXNkaXIpCiAJaWYgKElTX0FQUEVORChkaXIpKQogCQlyZXR1cm4gLUVQRVJNOwogCisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfUEFUSAorCWlmICh1"
    "bmxpa2VseShpbm9kZS0+aV9zdGF0ZSAmIElOT0RFX1NUQVRFX1NVU19QQVRIKSAmJiBsaWtlbHkoY3VycmVudC0+c3VzZnNfdGFza19zdGF0ZSAmIFRBU0tf"
    "U1RSVUNUX05PTl9ST09UX1VTRVJfQVBQX1BST0MpKSB7CisJCXJldHVybiAtRU5PRU5UOworCX0KKyNlbmRpZgorCiAJaWYgKGNoZWNrX3N0aWNreShkaXIs"
    "IGlub2RlKSB8fCBJU19BUFBFTkQoaW5vZGUpIHx8CiAJICAgIElTX0lNTVVUQUJMRShpbm9kZSkgfHwgSVNfU1dBUEZJTEUoaW5vZGUpIHx8IEhBU19VTk1B"
    "UFBFRF9JRChpbm9kZSkpCiAJCXJldHVybiAtRVBFUk07CkBAIC0yOTMzLDggKzI5ODUsMjAgQEAgc3RhdGljIGludCBtYXlfZGVsZXRlKHN0cnVjdCBpbm9k"
    "ZSAqZGlyLCBzdHJ1Y3QgZGVudHJ5ICp2aWN0aW0sIGJvb2wgaXNkaXIpCiAgKi8KIHN0YXRpYyBpbmxpbmUgaW50IG1heV9jcmVhdGUoc3RydWN0IGlub2Rl"
    "ICpkaXIsIHN0cnVjdCBkZW50cnkgKmNoaWxkKQogeworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX1BBVEgKKwlpbnQgZXJyb3I7CisjZW5kaWYKIAlz"
    "dHJ1Y3QgdXNlcl9uYW1lc3BhY2UgKnNfdXNlcl9uczsKIAlhdWRpdF9pbm9kZV9jaGlsZChkaXIsIGNoaWxkLCBBVURJVF9UWVBFX0NISUxEX0NSRUFURSk7"
    "CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfUEFUSAorCWlmIChjaGlsZC0+ZF9pbm9kZSAmJiB1bmxpa2VseShjaGlsZC0+ZF9pbm9kZS0+aV9zdGF0"
    "ZSAmIElOT0RFX1NUQVRFX1NVU19QQVRIKSAmJiBsaWtlbHkoY3VycmVudC0+c3VzZnNfdGFza19zdGF0ZSAmIFRBU0tfU1RSVUNUX05PTl9ST09UX1VTRVJf"
    "QVBQX1BST0MpKSB7CisJCWVycm9yID0gaW5vZGVfcGVybWlzc2lvbihkaXIsIE1BWV9XUklURSB8IE1BWV9FWEVDKTsKKwkJaWYgKGVycm9yKSB7CisJCQly"
    "ZXR1cm4gZXJyb3I7CisJCX0KKwkJcmV0dXJuIC1FTk9FTlQ7CisJfQorI2VuZGlmCiAJaWYgKGNoaWxkLT5kX2lub2RlKQogCQlyZXR1cm4gLUVFWElTVDsK"
    "IAlpZiAoSVNfREVBRERJUihkaXIpKQpAQCAtMzA5OCw2ICszMTYyLDEyIEBAIHN0YXRpYyBpbnQgbWF5X29wZW4oY29uc3Qgc3RydWN0IHBhdGggKnBhdGgs"
    "IGludCBhY2NfbW9kZSwgaW50IGZsYWcpCiAJaWYgKCFpbm9kZSkKIAkJcmV0dXJuIC1FTk9FTlQ7CiAKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19Q"
    "QVRICisJaWYgKHVubGlrZWx5KGlub2RlLT5pX3N0YXRlICYgSU5PREVfU1RBVEVfU1VTX1BBVEgpICYmIGxpa2VseShjdXJyZW50LT5zdXNmc190YXNrX3N0"
    "YXRlICYgVEFTS19TVFJVQ1RfTk9OX1JPT1RfVVNFUl9BUFBfUFJPQykpIHsKKwkJcmV0dXJuIC1FTk9FTlQ7CisJfQorI2VuZGlmCisKIAlzd2l0Y2ggKGlu"
    "b2RlLT5pX21vZGUgJiBTX0lGTVQpIHsKIAljYXNlIFNfSUZMTks6CiAJCXJldHVybiAtRUxPT1A7CkBAIC0zMTY5LDcgKzMyMzksMjAgQEAgc3RhdGljIGlu"
    "bGluZSBpbnQgb3Blbl90b19uYW1laV9mbGFncyhpbnQgZmxhZykKIHN0YXRpYyBpbnQgbWF5X29fY3JlYXRlKGNvbnN0IHN0cnVjdCBwYXRoICpkaXIsIHN0"
    "cnVjdCBkZW50cnkgKmRlbnRyeSwgdW1vZGVfdCBtb2RlKQogewogCXN0cnVjdCB1c2VyX25hbWVzcGFjZSAqc191c2VyX25zOworI2lmZGVmIENPTkZJR19L"
    "U1VfU1VTRlNfU1VTX1BBVEgKKwlpbnQgZXJyb3I7CisKKwlpZiAoZGVudHJ5LT5kX2lub2RlICYmIHVubGlrZWx5KGRlbnRyeS0+ZF9pbm9kZS0+aV9zdGF0"
    "ZSAmIElOT0RFX1NUQVRFX1NVU19QQVRIKSAmJiBsaWtlbHkoY3VycmVudC0+c3VzZnNfdGFza19zdGF0ZSAmIFRBU0tfU1RSVUNUX05PTl9ST09UX1VTRVJf"
    "QVBQX1BST0MpKSB7CisJCWVycm9yID0gaW5vZGVfcGVybWlzc2lvbihkaXItPmRlbnRyeS0+ZF9pbm9kZSwgTUFZX1dSSVRFIHwgTUFZX0VYRUMpOworCQlp"
    "ZiAoZXJyb3IpIHsKKwkJCXJldHVybiBlcnJvcjsKKwkJfQorCQlyZXR1cm4gLUVOT0VOVDsKKwl9CisJZXJyb3IgPSBzZWN1cml0eV9wYXRoX21rbm9kKGRp"
    "ciwgZGVudHJ5LCBtb2RlLCAwKTsKKyNlbHNlCiAJaW50IGVycm9yID0gc2VjdXJpdHlfcGF0aF9ta25vZChkaXIsIGRlbnRyeSwgbW9kZSwgMCk7CisjZW5k"
    "aWYKIAlpZiAoZXJyb3IpCiAJCXJldHVybiBlcnJvcjsKIApAQCAtMzMwOCw2ICszMzkxLDEyIEBAIHN0YXRpYyBpbnQgbG9va3VwX29wZW4oc3RydWN0IG5h"
    "bWVpZGF0YSAqbmQsIHN0cnVjdCBwYXRoICpwYXRoLAogCX0KIAlpZiAoZGVudHJ5LT5kX2lub2RlKSB7CiAJCS8qIENhY2hlZCBwb3NpdGl2ZSBkZW50cnk6"
    "IHdpbGwgb3BlbiBpbiBmX29wLT5vcGVuICovCisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfUEFUSAorCQlpZiAodW5saWtlbHkoZGVudHJ5LT5kX2lu"
    "b2RlLT5pX3N0YXRlICYgSU5PREVfU1RBVEVfU1VTX1BBVEgpICYmIGxpa2VseShjdXJyZW50LT5zdXNmc190YXNrX3N0YXRlICYgVEFTS19TVFJVQ1RfTk9O"
    "X1JPT1RfVVNFUl9BUFBfUFJPQykpIHsKKwkJCWRwdXQoZGVudHJ5KTsKKwkJCXJldHVybiAtRU5PRU5UOworCQl9CisjZW5kaWYKIAkJZ290byBvdXRfbm9f"
    "b3BlbjsKIAl9CiAKQEAgLTMzNTAsNiArMzQzOSwxNiBAQCBzdGF0aWMgaW50IGxvb2t1cF9vcGVuKHN0cnVjdCBuYW1laWRhdGEgKm5kLCBzdHJ1Y3QgcGF0"
    "aCAqcGF0aCwKIAkJCQkgICAgbW9kZSk7CiAJCWlmICh1bmxpa2VseShlcnJvciA9PSAtRU5PRU5UKSAmJiBjcmVhdGVfZXJyb3IpCiAJCQllcnJvciA9IGNy"
    "ZWF0ZV9lcnJvcjsKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19QQVRICisJCWlmICghSVNfRVJSKGRlbnRyeSkgJiYgZGVudHJ5LT5kX2lub2RlICYm"
    "IHVubGlrZWx5KGRlbnRyeS0+ZF9pbm9kZS0+aV9zdGF0ZSAmIElOT0RFX1NUQVRFX1NVU19QQVRIKSAmJiBsaWtlbHkoY3VycmVudC0+c3VzZnNfdGFza19z"
    "dGF0ZSAmIFRBU0tfU1RSVUNUX05PTl9ST09UX1VTRVJfQVBQX1BST0MpKSB7CisJCQlpZiAoY3JlYXRlX2Vycm9yKSB7CisJCQkJZHB1dChkZW50cnkpOwor"
    "CQkJCXJldHVybiBjcmVhdGVfZXJyb3I7CisJCQl9CisJCQlkcHV0KGRlbnRyeSk7CisJCQlyZXR1cm4gLUVOT0VOVDsKKwkJfQorI2VuZGlmCiAJCXJldHVy"
    "biBlcnJvcjsKIAl9CiAKQEAgLTMzNjUsNiArMzQ2NCwxMiBAQCBzdGF0aWMgaW50IGxvb2t1cF9vcGVuKHN0cnVjdCBuYW1laWRhdGEgKm5kLCBzdHJ1Y3Qg"
    "cGF0aCAqcGF0aCwKIAkJCX0KIAkJCWRwdXQoZGVudHJ5KTsKIAkJCWRlbnRyeSA9IHJlczsKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19QQVRICisJ"
    "CQlpZiAoZGVudHJ5LT5kX2lub2RlICYmIHVubGlrZWx5KGRlbnRyeS0+ZF9pbm9kZS0+aV9zdGF0ZSAmIElOT0RFX1NUQVRFX1NVU19QQVRIKSAmJiBsaWtl"
    "bHkoY3VycmVudC0+c3VzZnNfdGFza19zdGF0ZSAmIFRBU0tfU1RSVUNUX05PTl9ST09UX1VTRVJfQVBQX1BST0MpKSB7CisJCQkJZHB1dChkZW50cnkpOwor"
    "CQkJCXJldHVybiAtRU5PRU5UOworCQkJfQorI2VuZGlmCiAJCX0KIAl9CiAKQEAgLTM3MDIsMTIgKzM4MDcsMTkgQEAgc3RhdGljIHN0cnVjdCBmaWxlICpw"
    "YXRoX29wZW5hdChzdHJ1Y3QgbmFtZWlkYXRhICpuZCwKIAlyZXR1cm4gRVJSX1BUUihlcnJvcik7CiB9CiAKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX09Q"
    "RU5fUkVESVJFQ1QKK2V4dGVybiBzdHJ1Y3QgZmlsZW5hbWUqIHN1c2ZzX2dldF9yZWRpcmVjdGVkX3BhdGgodW5zaWduZWQgbG9uZyBpbm8pOworI2VuZGlm"
    "CisKIHN0cnVjdCBmaWxlICpkb19maWxwX29wZW4oaW50IGRmZCwgc3RydWN0IGZpbGVuYW1lICpwYXRobmFtZSwKIAkJY29uc3Qgc3RydWN0IG9wZW5fZmxh"
    "Z3MgKm9wKQogewogCXN0cnVjdCBuYW1laWRhdGEgbmQ7CiAJaW50IGZsYWdzID0gb3AtPmxvb2t1cF9mbGFnczsKIAlzdHJ1Y3QgZmlsZSAqZmlscDsKKyNp"
    "ZmRlZiBDT05GSUdfS1NVX1NVU0ZTX09QRU5fUkVESVJFQ1QKKwlzdHJ1Y3QgZmlsZW5hbWUgKmZha2VfcGF0aG5hbWU7CisjZW5kaWYKIAogCXNldF9uYW1l"
    "aWRhdGEoJm5kLCBkZmQsIHBhdGhuYW1lKTsKIAlmaWxwID0gcGF0aF9vcGVuYXQoJm5kLCBvcCwgZmxhZ3MgfCBMT09LVVBfUkNVKTsKQEAgLTM3MTUsNiAr"
    "MzgyNywyNSBAQCBzdHJ1Y3QgZmlsZSAqZG9fZmlscF9vcGVuKGludCBkZmQsIHN0cnVjdCBmaWxlbmFtZSAqcGF0aG5hbWUsCiAJCWZpbHAgPSBwYXRoX29w"
    "ZW5hdCgmbmQsIG9wLCBmbGFncyk7CiAJaWYgKHVubGlrZWx5KGZpbHAgPT0gRVJSX1BUUigtRVNUQUxFKSkpCiAJCWZpbHAgPSBwYXRoX29wZW5hdCgmbmQs"
    "IG9wLCBmbGFncyB8IExPT0tVUF9SRVZBTCk7CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19PUEVOX1JFRElSRUNUCisJaWYgKCFJU19FUlIoZmlscCkgJiYg"
    "dW5saWtlbHkoZmlscC0+Zl9pbm9kZS0+aV9zdGF0ZSAmIElOT0RFX1NUQVRFX09QRU5fUkVESVJFQ1QpICYmIGN1cnJlbnRfdWlkKCkudmFsIDwgMjAwMCkg"
    "eworCQlmYWtlX3BhdGhuYW1lID0gc3VzZnNfZ2V0X3JlZGlyZWN0ZWRfcGF0aChmaWxwLT5mX2lub2RlLT5pX2lubyk7CisJCWlmICghSVNfRVJSKGZha2Vf"
    "cGF0aG5hbWUpKSB7CisJCQlyZXN0b3JlX25hbWVpZGF0YSgpOworCQkJZmlscF9jbG9zZShmaWxwLCBOVUxMKTsKKwkJCS8vIG5vIG5lZWQgdG8gZG8gYHB1"
    "dG5hbWUocGF0aG5hbWUpO2AgaGVyZSBhcyBpdCB3aWxsIGJlIGRvbmUgYnkgY2FsbGluZyBwcm9jZXNzCisJCQlzZXRfbmFtZWlkYXRhKCZuZCwgZGZkLCBm"
    "YWtlX3BhdGhuYW1lKTsKKwkJCWZpbHAgPSBwYXRoX29wZW5hdCgmbmQsIG9wLCBmbGFncyB8IExPT0tVUF9SQ1UpOworCQkJaWYgKHVubGlrZWx5KGZpbHAg"
    "PT0gRVJSX1BUUigtRUNISUxEKSkpCisJCQkJZmlscCA9IHBhdGhfb3BlbmF0KCZuZCwgb3AsIGZsYWdzKTsKKwkJCWlmICh1bmxpa2VseShmaWxwID09IEVS"
    "Ul9QVFIoLUVTVEFMRSkpKQorCQkJCWZpbHAgPSBwYXRoX29wZW5hdCgmbmQsIG9wLCBmbGFncyB8IExPT0tVUF9SRVZBTCk7CisJCQlyZXN0b3JlX25hbWVp"
    "ZGF0YSgpOworCQkJcHV0bmFtZShmYWtlX3BhdGhuYW1lKTsKKwkJCXJldHVybiBmaWxwOworCQl9CisJfQorI2VuZGlmCiAJcmVzdG9yZV9uYW1laWRhdGEo"
    "KTsKIAlyZXR1cm4gZmlscDsKIH0KZGlmZiAtLWdpdCBhL2ZzL25hbWVzcGFjZS5jIGIvZnMvbmFtZXNwYWNlLmMKaW5kZXggNTc4MmNkNTVkZmRiLi45NjQ1"
    "ZjA3ZjVjODggMTAwNjQ0Ci0tLSBhL2ZzL25hbWVzcGFjZS5jCisrKyBiL2ZzL25hbWVzcGFjZS5jCkBAIC0zMCwxMCArMzAsMzcgQEAKICNpbmNsdWRlIDx1"
    "YXBpL2xpbnV4L21vdW50Lmg+CiAjaW5jbHVkZSA8bGludXgvZnNfY29udGV4dC5oPgogI2luY2x1ZGUgPGxpbnV4L3NobWVtX2ZzLmg+CisjaWYgZGVmaW5l"
    "ZChDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVCkgfHwgZGVmaW5lZChDT05GSUdfS1NVX1NVU0ZTX1RSWV9VTU9VTlQpCisjaW5jbHVkZSA8bGludXgvc3Vz"
    "ZnNfZGVmLmg+CisjZW5kaWYKIAogI2luY2x1ZGUgInBub2RlLmgiCiAjaW5jbHVkZSAiaW50ZXJuYWwuaCIKIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNf"
    "U1VTX01PVU5UCitleHRlcm4gYm9vbCBzdXNmc19pc19jdXJyZW50X2tzdV9kb21haW4odm9pZCk7CitleHRlcm4gYm9vbCBzdXNmc19pc19jdXJyZW50X3p5"
    "Z290ZV9kb21haW4odm9pZCk7CisKK3N0YXRpYyBERUZJTkVfSURBKHN1c2ZzX21udF9pZF9pZGEpOworc3RhdGljIERFRklORV9JREEoc3VzZnNfbW50X2dy"
    "b3VwX2lkYSk7CisKKyNkZWZpbmUgQ0xfWllHT1RFX0NPUFlfTU5UX05TIEJJVCgyNCkgLyogdXNlZCBieSBjb3B5X21udF9ucygpICovCisjZGVmaW5lIENM"
    "X0NPUFlfTU5UX05TIEJJVCgyNSkgLyogdXNlZCBieSBjb3B5X21udF9ucygpICovCisjZW5kaWYKKworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfQVVUT19B"
    "RERfU1VTX0tTVV9ERUZBVUxUX01PVU5UCitleHRlcm4gdm9pZCBzdXNmc19hdXRvX2FkZF9zdXNfa3N1X2RlZmF1bHRfbW91bnQoY29uc3QgY2hhciBfX3Vz"
    "ZXIgKnRvX3BhdGhuYW1lKTsKK2Jvb2wgc3VzZnNfaXNfYXV0b19hZGRfc3VzX2tzdV9kZWZhdWx0X21vdW50X2VuYWJsZWQgPSB0cnVlOworI2VuZGlmCisj"
    "aWZkZWYgQ09ORklHX0tTVV9TVVNGU19BVVRPX0FERF9TVVNfQklORF9NT1VOVAorZXh0ZXJuIGludCBzdXNmc19hdXRvX2FkZF9zdXNfYmluZF9tb3VudChj"
    "b25zdCBjaGFyICpwYXRobmFtZSwgc3RydWN0IHBhdGggKnBhdGhfdGFyZ2V0KTsKK2Jvb2wgc3VzZnNfaXNfYXV0b19hZGRfc3VzX2JpbmRfbW91bnRfZW5h"
    "YmxlZCA9IHRydWU7CisjZW5kaWYKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX0FVVE9fQUREX1RSWV9VTU9VTlRfRk9SX0JJTkRfTU9VTlQKK2V4dGVybiB2"
    "b2lkIHN1c2ZzX2F1dG9fYWRkX3RyeV91bW91bnRfZm9yX2JpbmRfbW91bnQoc3RydWN0IHBhdGggKnBhdGgpOworYm9vbCBzdXNmc19pc19hdXRvX2FkZF90"
    "cnlfdW1vdW50X2Zvcl9iaW5kX21vdW50X2VuYWJsZWQgPSB0cnVlOworI2VuZGlmCisKIC8qIE1heGltdW0gbnVtYmVyIG9mIG1vdW50cyBpbiBhIG1vdW50"
    "IG5hbWVzcGFjZSAqLwogdW5zaWduZWQgaW50IHN5c2N0bF9tb3VudF9tYXggX19yZWFkX21vc3RseSA9IDEwMDAwMDsKIApAQCAtMTAyLDYgKzEyOSwxOCBA"
    "QCBzdGF0aWMgaW5saW5lIHN0cnVjdCBobGlzdF9oZWFkICptcF9oYXNoKHN0cnVjdCBkZW50cnkgKmRlbnRyeSkKIAlyZXR1cm4gJm1vdW50cG9pbnRfaGFz"
    "aHRhYmxlW3RtcCAmIG1wX2hhc2hfbWFza107CiB9CiAKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVAorLy8gT3VyIG93biBtbnRfYWxsb2Nf"
    "aWQoKSB0aGF0IGFzc2lnbnMgbW50X2lkIHN0YXJ0aW5nIGZyb20gREVGQVVMVF9TVVNfTU5UX0lECitzdGF0aWMgaW50IHN1c2ZzX21udF9hbGxvY19pZChz"
    "dHJ1Y3QgbW91bnQgKm1udCkKK3sKKwlpbnQgcmVzID0gaWRhX2FsbG9jX21pbigmc3VzZnNfbW50X2lkX2lkYSwgREVGQVVMVF9TVVNfTU5UX0lELCBHRlBf"
    "S0VSTkVMKTsKKworCWlmIChyZXMgPCAwKQorCQlyZXR1cm4gcmVzOworCW1udC0+bW50X2lkID0gcmVzOworCXJldHVybiAwOworfQorI2VuZGlmCiBzdGF0"
    "aWMgaW50IG1udF9hbGxvY19pZChzdHJ1Y3QgbW91bnQgKm1udCkKIHsKIAlpbnQgcmVzID0gaWRhX2FsbG9jKCZtbnRfaWRfaWRhLCBHRlBfS0VSTkVMKTsK"
    "QEAgLTExNCw2ICsxNTMsMjYgQEAgc3RhdGljIGludCBtbnRfYWxsb2NfaWQoc3RydWN0IG1vdW50ICptbnQpCiAKIHN0YXRpYyB2b2lkIG1udF9mcmVlX2lk"
    "KHN0cnVjdCBtb3VudCAqbW50KQogeworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UCisJLy8gV2Ugc2hvdWxkIGZpcnN0IGNoZWNrIHRoZSAn"
    "bW50LT5tbnQuc3VzZnNfbW50X2lkX2JhY2t1cCcsIHNlZSBpZiBpdCBpcyBERUZBVUxUX1NVU19NTlRfSURfRk9SX0tTVV9QUk9DX1VOU0hBUkUKKwkvLyBp"
    "ZiBzbywgdGhlc2UgbW50X2lkIHdlcmUgbm90IGFzc2lnbmVkIGJ5IG1udF9hbGxvY19pZCgpIHNvIHdlIGRvbid0IG5lZWQgdG8gZnJlZSBpdC4KKwlpZiAo"
    "dW5saWtlbHkobW50LT5tbnQuc3VzZnNfbW50X2lkX2JhY2t1cCA9PSBERUZBVUxUX1NVU19NTlRfSURfRk9SX0tTVV9QUk9DX1VOU0hBUkUpKSB7CisJCXJl"
    "dHVybjsKKwl9CisJLy8gTm93IHdlIGNhbiBjaGVjayBpZiBpdHMgbW50X2lkIGlzIHN1cworCWlmICh1bmxpa2VseShtbnQtPm1udF9pZCA+PSBERUZBVUxU"
    "X1NVU19NTlRfSUQpKSB7CisJCWlkYV9mcmVlKCZzdXNmc19tbnRfaWRfaWRhLCBtbnQtPm1udF9pZCk7CisJCXJldHVybjsKKwl9CisJLy8gTGFzdGx5IGlm"
    "ICdtbnQtPm1udC5zdXNmc19tbnRfaWRfYmFja3VwJyBpcyBub3QgMCwgdGhlbiBpdCBjb250YWlucyBhIGJhY2t1cCBvcmlnaW4gbW50X2lkCisJLy8gc28g"
    "d2UgZnJlZSBpdCBpbiB0aGUgb3JpZ2luYWwgd2F5CisJaWYgKGxpa2VseShtbnQtPm1udC5zdXNmc19tbnRfaWRfYmFja3VwKSkgeworCQkvLyBJZiBtbnQt"
    "Pm1udC5zdXNmc19tbnRfaWRfYmFja3VwIGlzIG5vdCB6ZXJvLCBpdCBtZWFucyBtbnQtPm1udF9pZCBpcyBzcG9vZmVkLAorCQkvLyBzbyBoZXJlIHdlIHJl"
    "dHVybiB0aGUgb3JpZ2luYWwgbW50X2lkIGZvciBiZWluZyBmcmVlZC4KKwkJaWRhX2ZyZWUoJm1udF9pZF9pZGEsIG1udC0+bW50LnN1c2ZzX21udF9pZF9i"
    "YWNrdXApOworCQlyZXR1cm47CisJfQorI2VuZGlmCiAJaWRhX2ZyZWUoJm1udF9pZF9pZGEsIG1udC0+bW50X2lkKTsKIH0KIApAQCAtMTIyLDcgKzE4MSwy"
    "MCBAQCBzdGF0aWMgdm9pZCBtbnRfZnJlZV9pZChzdHJ1Y3QgbW91bnQgKm1udCkKICAqLwogc3RhdGljIGludCBtbnRfYWxsb2NfZ3JvdXBfaWQoc3RydWN0"
    "IG1vdW50ICptbnQpCiB7CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQKKwlpbnQgcmVzOworCisJLy8gQ2hlY2sgaWYgbW50IGhhcyBzdXMg"
    "bW50X2lkCisJaWYgKG1udC0+bW50X2lkID49IERFRkFVTFRfU1VTX01OVF9JRCkgeworCQkvLyBJZiBzbywgYXNzaWduIGEgc3VzIG1udF9ncm91cCBpZCBE"
    "RUZBVUxUX1NVU19NTlRfR1JPVVBfSUQgZnJvbSBzdXNmc19tbnRfZ3JvdXBfaWRhCisJCXJlcyA9IGlkYV9hbGxvY19taW4oJnN1c2ZzX21udF9ncm91cF9p"
    "ZGEsIERFRkFVTFRfU1VTX01OVF9HUk9VUF9JRCwgR0ZQX0tFUk5FTCk7CisJCWdvdG8gYnlwYXNzX29yaWdfZmxvdzsKKwl9CisJcmVzID0gaWRhX2FsbG9j"
    "X21pbigmbW50X2dyb3VwX2lkYSwgMSwgR0ZQX0tFUk5FTCk7CitieXBhc3Nfb3JpZ19mbG93OgorI2Vsc2UKIAlpbnQgcmVzID0gaWRhX2FsbG9jX21pbigm"
    "bW50X2dyb3VwX2lkYSwgMSwgR0ZQX0tFUk5FTCk7CisjZW5kaWYKIAogCWlmIChyZXMgPCAwKQogCQlyZXR1cm4gcmVzOwpAQCAtMTM1LDYgKzIwNywxNSBA"
    "QCBzdGF0aWMgaW50IG1udF9hbGxvY19ncm91cF9pZChzdHJ1Y3QgbW91bnQgKm1udCkKICAqLwogdm9pZCBtbnRfcmVsZWFzZV9ncm91cF9pZChzdHJ1Y3Qg"
    "bW91bnQgKm1udCkKIHsKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVAorCS8vIElmIG1udC0+bW50X2dyb3VwX2lkID49IERFRkFVTFRfU1VT"
    "X01OVF9HUk9VUF9JRCwgaXQgbWVhbnMgJ21udCcgaXMgYWxzbyBzdXMgbW91bnQsCisJLy8gdGhlbiB3ZSBmcmVlIHRoZSBtbnQtPm1udF9ncm91cF9pZCBm"
    "cm9tIHN1c2ZzX21udF9ncm91cF9pZGEKKwlpZiAobW50LT5tbnRfZ3JvdXBfaWQgPj0gREVGQVVMVF9TVVNfTU5UX0dST1VQX0lEKSB7CisJCWlkYV9mcmVl"
    "KCZzdXNmc19tbnRfZ3JvdXBfaWRhLCBtbnQtPm1udF9ncm91cF9pZCk7CisJCW1udC0+bW50X2dyb3VwX2lkID0gMDsKKwkJcmV0dXJuOworCX0KKyNlbmRp"
    "ZgogCWlkYV9mcmVlKCZtbnRfZ3JvdXBfaWRhLCBtbnQtPm1udF9ncm91cF9pZCk7CiAJbW50LT5tbnRfZ3JvdXBfaWQgPSAwOwogfQpAQCAtMTcyLDEzICsy"
    "NTMsMzEgQEAgaW50IG1udF9nZXRfY291bnQoc3RydWN0IG1vdW50ICptbnQpCiAjZW5kaWYKIH0KIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01P"
    "VU5UCitzdGF0aWMgc3RydWN0IG1vdW50ICphbGxvY192ZnNtbnQoY29uc3QgY2hhciAqbmFtZSwgYm9vbCBzaG91bGRfc3Bvb2YsIGludCBjdXN0b21fbW50"
    "X2lkKQorI2Vsc2UKIHN0YXRpYyBzdHJ1Y3QgbW91bnQgKmFsbG9jX3Zmc21udChjb25zdCBjaGFyICpuYW1lKQorI2VuZGlmCiB7CiAJc3RydWN0IG1vdW50"
    "ICptbnQgPSBrbWVtX2NhY2hlX3phbGxvYyhtbnRfY2FjaGUsIEdGUF9LRVJORUwpOwogCWlmIChtbnQpIHsKIAkJaW50IGVycjsKIAorI2lmZGVmIENPTkZJ"
    "R19LU1VfU1VTRlNfU1VTX01PVU5UCisJCWlmIChzaG91bGRfc3Bvb2YpIHsKKwkJCWlmICghY3VzdG9tX21udF9pZCkgeworCQkJCWVyciA9IHN1c2ZzX21u"
    "dF9hbGxvY19pZChtbnQpOworCQkJfSBlbHNlIHsKKwkJCQltbnQtPm1udF9pZCA9IGN1c3RvbV9tbnRfaWQ7CisJCQkJZXJyID0gMDsKKwkJCX0KKwkJCWdv"
    "dG8gYnlwYXNzX29yaWdfZmxvdzsKKwkJfQorI2VuZGlmCiAJCWVyciA9IG1udF9hbGxvY19pZChtbnQpOworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VT"
    "X01PVU5UCitieXBhc3Nfb3JpZ19mbG93OgorI2VuZGlmCiAJCWlmIChlcnIpCiAJCQlnb3RvIG91dF9mcmVlX2NhY2hlOwogCkBAIC05MzcsNyArMTAzNiwx"
    "NyBAQCBzdHJ1Y3QgdmZzbW91bnQgKnZmc19jcmVhdGVfbW91bnQoc3RydWN0IGZzX2NvbnRleHQgKmZjKQogCWlmICghZmMtPnJvb3QpCiAJCXJldHVybiBF"
    "UlJfUFRSKC1FSU5WQUwpOwogCisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQKKwkvLyBGb3IgbmV3bHkgY3JlYXRlZCBtb3VudHMsIHRoZSBv"
    "bmx5IGNhbGxlciBwcm9jZXNzIHdlIGNhcmUgaXMgS1NVCisJaWYgKHVubGlrZWx5KHN1c2ZzX2lzX2N1cnJlbnRfa3N1X2RvbWFpbigpKSkgeworCQltbnQg"
    "PSBhbGxvY192ZnNtbnQoZmMtPnNvdXJjZSA/OiAibm9uZSIsIHRydWUsIDApOworCQlnb3RvIGJ5cGFzc19vcmlnX2Zsb3c7CisJfQorCW1udCA9IGFsbG9j"
    "X3Zmc21udChmYy0+c291cmNlID86ICJub25lIiwgZmFsc2UsIDApOworYnlwYXNzX29yaWdfZmxvdzoKKyNlbHNlCiAJbW50ID0gYWxsb2NfdmZzbW50KGZj"
    "LT5zb3VyY2UgPzogIm5vbmUiKTsKKyNlbmRpZgogCWlmICghbW50KQogCQlyZXR1cm4gRVJSX1BUUigtRU5PTUVNKTsKIApAQCAtOTUwLDYgKzEwNTksMTQg"
    "QEAgc3RydWN0IHZmc21vdW50ICp2ZnNfY3JlYXRlX21vdW50KHN0cnVjdCBmc19jb250ZXh0ICpmYykKIAltbnQtPm1udF9tb3VudHBvaW50CT0gbW50LT5t"
    "bnQubW50X3Jvb3Q7CiAJbW50LT5tbnRfcGFyZW50CQk9IG1udDsKIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UCisJLy8gSWYgY2FsbGVy"
    "IHByb2Nlc3MgaXMgenlnb3RlLCB0aGVuIGl0IGlzIGEgbm9ybWFsIG1vdW50LCBzbyB3ZSBqdXN0IHJlb3JkZXIgdGhlIG1udF9pZAorCWlmIChzdXNmc19p"
    "c19jdXJyZW50X3p5Z290ZV9kb21haW4oKSkgeworCQltbnQtPm1udC5zdXNmc19tbnRfaWRfYmFja3VwID0gbW50LT5tbnRfaWQ7CisJCW1udC0+bW50X2lk"
    "ID0gY3VycmVudC0+c3VzZnNfbGFzdF9mYWtlX21udF9pZCsrOworCX0KKyNlbmRpZgorCiAJbG9ja19tb3VudF9oYXNoKCk7CiAJbGlzdF9hZGRfdGFpbCgm"
    "bW50LT5tbnRfaW5zdGFuY2UsICZtbnQtPm1udC5tbnRfc2ItPnNfbW91bnRzKTsKIAl1bmxvY2tfbW91bnRfaGFzaCgpOwpAQCAtMTAyMCw3ICsxMTM3LDUy"
    "IEBAIHN0YXRpYyBzdHJ1Y3QgbW91bnQgKmNsb25lX21udChzdHJ1Y3QgbW91bnQgKm9sZCwgc3RydWN0IGRlbnRyeSAqcm9vdCwKIAlzdHJ1Y3QgbW91bnQg"
    "Km1udDsKIAlpbnQgZXJyOwogCisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQKKwlib29sIGlzX2N1cnJlbnRfa3N1X2RvbWFpbiA9IHN1c2Zz"
    "X2lzX2N1cnJlbnRfa3N1X2RvbWFpbigpOworCWJvb2wgaXNfY3VycmVudF96eWdvdGVfZG9tYWluID0gc3VzZnNfaXNfY3VycmVudF96eWdvdGVfZG9tYWlu"
    "KCk7CisKKwkvKiAtIEl0IGlzIHZlcnkgaW1wb3J0YW50IHRoYXQgd2UgbmVlZCB0byB1c2UgQ0xfQ09QWV9NTlRfTlMgdG8gaWRlbnRpZnkgd2hldGhlciAK"
    "KwkgKiAgIHRoZSBjbG9uZSBpcyBhIGNvcHlfdHJlZSgpIG9yIHNpbmdsZSBtb3VudCBsaWtlIGNhbGxlZCBieSBfX2RvX2xvb3BiYWNrKCkKKwkgKiAtIGlm"
    "IGNhbGxlciBwcm9jZXNzIGlzIEtTVSwgY29uc2lkZXIgdGhlIGZvbGxvd2luZyBzaXR1YXRpb246CisJICogICAgIDEuIGl0IGlzIE5PVCBkb2luZyB1bnNo"
    "YXJlID0+IGNhbGwgYWxsb2NfdmZzbW50KCkgdG8gYXNzaWduIGEgbmV3IHN1cyBtbnRfaWQKKwkgKiAgICAgMi4gaXQgaXMgZG9pbmcgdW5zaGFyZSA9PiBz"
    "cG9vZiB0aGUgbmV3IG1udF9pZCB3aXRoIHRoZSBvbGQgbW50X2lkCisJICogLSBJZiBjYWxsZXIgcHJvY2VzcyBpcyB6eWdvdGUgYW5kIG9sZCBtbnRfaWQg"
    "aXMgc3VzID0+IGNhbGwgYWxsb2NfdmZzbW50KCkgdG8gYXNzaWduIGEgbmV3IHN1cyBtbnRfaWQKKwkgKiAtIEZvciB0aGUgcmVzdCBvZiBjYWxsZXIgcHJv"
    "Y2VzcyB0aGF0IGRvaW5nIHVuc2hhcmUgPT4gY2FsbCBhbGxvY192ZnNtbnQoKSB0byBhc3NpZ24gYSBuZXcgc3VzIG1udF9pZCBvbmx5IGZvciBvbGQgc3Vz"
    "IG1vdW50CisJICovCisJLy8gRmlyc3RseSwgY2hlY2sgaWYgaXQgaXMgS1NVIHByb2Nlc3MKKwlpZiAodW5saWtlbHkoaXNfY3VycmVudF9rc3VfZG9tYWlu"
    "KSkgeworCQkvLyBpZiBpdCBpcyBkb2luZyBzaW5nbGUgY2xvbmUKKwkJaWYgKCEoZmxhZyAmIENMX0NPUFlfTU5UX05TKSkgeworCQkJbW50ID0gYWxsb2Nf"
    "dmZzbW50KG9sZC0+bW50X2Rldm5hbWUsIHRydWUsIDApOworCQkJZ290byBieXBhc3Nfb3JpZ19mbG93OworCQl9CisJCS8vIGlmIGl0IGlzIGRvaW5nIHVu"
    "c2hhcmUKKwkJbW50ID0gYWxsb2NfdmZzbW50KG9sZC0+bW50X2Rldm5hbWUsIHRydWUsIG9sZC0+bW50X2lkKTsKKwkJaWYgKG1udCkgeworCQkJbW50LT5t"
    "bnQuc3VzZnNfbW50X2lkX2JhY2t1cCA9IERFRkFVTFRfU1VTX01OVF9JRF9GT1JfS1NVX1BST0NfVU5TSEFSRTsKKwkJfQorCQlnb3RvIGJ5cGFzc19vcmln"
    "X2Zsb3c7CisJfQorCS8vIFNlY29uZGx5LCBjaGVjayBpZiBpdCBpcyB6eWdvdGUgcHJvY2VzcyBhbmQgbm8gbWF0dGVyIGl0IGlzIGRvaW5nIHVuc2hhcmUg"
    "b3Igbm90CisJaWYgKGxpa2VseShpc19jdXJyZW50X3p5Z290ZV9kb21haW4pICYmIChvbGQtPm1udF9pZCA+PSBERUZBVUxUX1NVU19NTlRfSUQpKSB7CisJ"
    "CS8qIEltcG9ydGFudCBOb3RlOiAKKwkJICogIC0gSGVyZSB3ZSBjYW4ndCBkZXRlcm1pbmUgd2hldGhlciB0aGUgdW5zaGFyZSBpcyBjYWxsZWQgenlnaXNr"
    "IG9yIG5vdCwKKwkJICogICAgc28gd2UgY2FuIG9ubHkgcGF0Y2ggb3V0IHRoZSB1bnNoYXJlIGNvZGUgaW4genlnaXNrIHNvdXJjZSBjb2RlIGZvciBub3cK"
    "KwkJICogIC0gQnV0IGF0IGxlYXN0IHdlIGNhbiBkZWFsIHdpdGggb2xkIHN1cyBtb3VudHMgdXNpbmcgYWxsb2NfdmZzbW50KCkKKwkJICovCisJCW1udCA9"
    "IGFsbG9jX3Zmc21udChvbGQtPm1udF9kZXZuYW1lLCB0cnVlLCAwKTsKKwkJZ290byBieXBhc3Nfb3JpZ19mbG93OworCX0KKwkvLyBMYXN0bHksIGZvciBv"
    "dGhlciBwcm9jZXNzIHRoYXQgaXMgZG9pbmcgdW5zaGFyZSBvcGVyYXRpb24sIGJ1dCBvbmx5IGRlYWwgd2l0aCBvbGQgc3VzIG1vdW50CisJaWYgKChmbGFn"
    "ICYgQ0xfQ09QWV9NTlRfTlMpICYmIChvbGQtPm1udF9pZCA+PSBERUZBVUxUX1NVU19NTlRfSUQpKSB7CisJCW1udCA9IGFsbG9jX3Zmc21udChvbGQtPm1u"
    "dF9kZXZuYW1lLCB0cnVlLCAwKTsKKwkJZ290byBieXBhc3Nfb3JpZ19mbG93OworCX0KKwltbnQgPSBhbGxvY192ZnNtbnQob2xkLT5tbnRfZGV2bmFtZSwg"
    "ZmFsc2UsIDApOworYnlwYXNzX29yaWdfZmxvdzoKKyNlbHNlCiAJbW50ID0gYWxsb2NfdmZzbW50KG9sZC0+bW50X2Rldm5hbWUpOworI2VuZGlmCiAJaWYg"
    "KCFtbnQpCiAJCXJldHVybiBFUlJfUFRSKC1FTk9NRU0pOwogCkBAIC0xMDQzLDYgKzEyMDUsMTUgQEAgc3RhdGljIHN0cnVjdCBtb3VudCAqY2xvbmVfbW50"
    "KHN0cnVjdCBtb3VudCAqb2xkLCBzdHJ1Y3QgZGVudHJ5ICpyb290LAogCW1udC0+bW50Lm1udF9yb290ID0gZGdldChyb290KTsKIAltbnQtPm1udF9tb3Vu"
    "dHBvaW50ID0gbW50LT5tbnQubW50X3Jvb3Q7CiAJbW50LT5tbnRfcGFyZW50ID0gbW50OworCisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQK"
    "KwkvLyBJZiBjYWxsZXIgcHJvY2VzcyBpcyB6eWdvdGUgYW5kIG5vdCBkb2luZyB1bnNoYXJlLCBzbyB3ZSBqdXN0IHJlb3JkZXIgdGhlIG1udF9pZAorCWlm"
    "IChsaWtlbHkoaXNfY3VycmVudF96eWdvdGVfZG9tYWluKSAmJiAhKGZsYWcgJiBDTF9aWUdPVEVfQ09QWV9NTlRfTlMpKSB7CisJCW1udC0+bW50LnN1c2Zz"
    "X21udF9pZF9iYWNrdXAgPSBtbnQtPm1udF9pZDsKKwkJbW50LT5tbnRfaWQgPSBjdXJyZW50LT5zdXNmc19sYXN0X2Zha2VfbW50X2lkKys7CisJfQorI2Vu"
    "ZGlmCisKIAlsb2NrX21vdW50X2hhc2goKTsKIAlsaXN0X2FkZF90YWlsKCZtbnQtPm1udF9pbnN0YW5jZSwgJnNiLT5zX21vdW50cyk7CiAJdW5sb2NrX21v"
    "dW50X2hhc2goKTsKQEAgLTIzMzEsNiArMjUwMiwyNyBAQCBzdGF0aWMgaW50IGRvX2xvb3BiYWNrKHN0cnVjdCBwYXRoICpwYXRoLCBjb25zdCBjaGFyICpv"
    "bGRfbmFtZSwKIAkJdW1vdW50X3RyZWUobW50LCBVTU9VTlRfU1lOQyk7CiAJCXVubG9ja19tb3VudF9oYXNoKCk7CiAJfQorI2lmIGRlZmluZWQoQ09ORklH"
    "X0tTVV9TVVNGU19BVVRPX0FERF9TVVNfQklORF9NT1VOVCkgfHwgZGVmaW5lZChDT05GSUdfS1NVX1NVU0ZTX0FVVE9fQUREX1RSWV9VTU9VTlRfRk9SX0JJ"
    "TkRfTU9VTlQpCisJLy8gQ2hlY2sgaWYgYmluZCBtb3VudGVkIHBhdGggc2hvdWxkIGJlIGhpZGRlbiBhbmQgdW1vdW50ZWQgYXV0b21hdGljYWxseS4KKwkv"
    "LyBBbmQgd2UgdGFyZ2V0IG9ubHkgcHJvY2VzcyB3aXRoIGtzdSBkb21haW4uCisJaWYgKHN1c2ZzX2lzX2N1cnJlbnRfa3N1X2RvbWFpbigpKSB7CisjaWYg"
    "ZGVmaW5lZChDT05GSUdfS1NVX1NVU0ZTX0FVVE9fQUREX1NVU19CSU5EX01PVU5UKQorCQlpZiAoc3VzZnNfaXNfYXV0b19hZGRfc3VzX2JpbmRfbW91bnRf"
    "ZW5hYmxlZCAmJgorCQkJCXN1c2ZzX2F1dG9fYWRkX3N1c19iaW5kX21vdW50KG9sZF9uYW1lLCAmb2xkX3BhdGgpKSB7CisJCQlnb3RvIG9yaWdfZmxvdzsK"
    "KwkJfQorI2VuZGlmCisjaWYgZGVmaW5lZChDT05GSUdfS1NVX1NVU0ZTX0FVVE9fQUREX1RSWV9VTU9VTlRfRk9SX0JJTkRfTU9VTlQpCisJCWlmIChzdXNm"
    "c19pc19hdXRvX2FkZF90cnlfdW1vdW50X2Zvcl9iaW5kX21vdW50X2VuYWJsZWQpIHsKKwkJCXN1c2ZzX2F1dG9fYWRkX3RyeV91bW91bnRfZm9yX2JpbmRf"
    "bW91bnQocGF0aCk7CisJCX0KKyNlbmRpZgorCX0KKyNpZiBkZWZpbmVkKENPTkZJR19LU1VfU1VTRlNfQVVUT19BRERfU1VTX0JJTkRfTU9VTlQpCitvcmln"
    "X2Zsb3c6CisjZW5kaWYKKyNlbmRpZiAvLyAjaWYgZGVmaW5lZChDT05GSUdfS1NVX1NVU0ZTX0FVVE9fQUREX1NVU19CSU5EX01PVU5UKSB8fCBkZWZpbmVk"
    "KENPTkZJR19LU1VfU1VTRlNfQVVUT19BRERfVFJZX1VNT1VOVF9GT1JfQklORF9NT1VOVCkKKwogb3V0MjoKIAl1bmxvY2tfbW91bnQobXApOwogb3V0OgpA"
    "QCAtMzE2Myw2ICszMzU1LDEyIEBAIGxvbmcgZG9fbW91bnQoY29uc3QgY2hhciAqZGV2X25hbWUsIGNvbnN0IGNoYXIgX191c2VyICpkaXJfbmFtZSwKIAkJ"
    "cmV0dmFsID0gZG9fbmV3X21vdW50KCZwYXRoLCB0eXBlX3BhZ2UsIHNiX2ZsYWdzLCBtbnRfZmxhZ3MsCiAJCQkJICAgICAgZGV2X25hbWUsIGRhdGFfcGFn"
    "ZSk7CiBkcHV0X291dDoKKyNpZiBkZWZpbmVkKENPTkZJR19LU1VfU1VTRlNfQVVUT19BRERfU1VTX0tTVV9ERUZBVUxUX01PVU5UKSAmJiBkZWZpbmVkKENP"
    "TkZJR19LU1VfU1VTRlNfSEFTX01BR0lDX01PVU5UKQorCS8vIEp1c3QgZm9yIHRoZSBjb21wYXRpYmlsaXR5IG9mIE1hZ2ljIE1vdW50IEtlcm5lbFNVCisJ"
    "aWYgKCFyZXR2YWwgJiYgc3VzZnNfaXNfYXV0b19hZGRfc3VzX2tzdV9kZWZhdWx0X21vdW50X2VuYWJsZWQgJiYgc3VzZnNfaXNfY3VycmVudF9rc3VfZG9t"
    "YWluKCkpIHsKKwkJc3VzZnNfYXV0b19hZGRfc3VzX2tzdV9kZWZhdWx0X21vdW50KGRpcl9uYW1lKTsKKwl9CisjZW5kaWYKIAlwYXRoX3B1dCgmcGF0aCk7"
    "CiAJcmV0dXJuIHJldHZhbDsKIH0KQEAgLTMyMzksNiArMzQzNywxMCBAQCBzdHJ1Y3QgbW50X25hbWVzcGFjZSAqY29weV9tbnRfbnModW5zaWduZWQgbG9u"
    "ZyBmbGFncywgc3RydWN0IG1udF9uYW1lc3BhY2UgKm5zLAogCXN0cnVjdCBtb3VudCAqb2xkOwogCXN0cnVjdCBtb3VudCAqbmV3OwogCWludCBjb3B5X2Zs"
    "YWdzOworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UCisJYm9vbCBpc196eWdvdGVfcGlkID0gc3VzZnNfaXNfY3VycmVudF96eWdvdGVfZG9t"
    "YWluKCk7CisJaW50IGxhc3RfZW50cnlfbW50X2lkID0gMDsKKyNlbmRpZgogCiAJQlVHX09OKCFucyk7CiAKQEAgLTMyNTgsNiArMzQ2MCwxNSBAQCBzdHJ1"
    "Y3QgbW50X25hbWVzcGFjZSAqY29weV9tbnRfbnModW5zaWduZWQgbG9uZyBmbGFncywgc3RydWN0IG1udF9uYW1lc3BhY2UgKm5zLAogCWNvcHlfZmxhZ3Mg"
    "PSBDTF9DT1BZX1VOQklOREFCTEUgfCBDTF9FWFBJUkU7CiAJaWYgKHVzZXJfbnMgIT0gbnMtPnVzZXJfbnMpCiAJCWNvcHlfZmxhZ3MgfD0gQ0xfU0hBUkVE"
    "X1RPX1NMQVZFOworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UCisJLy8gQWx3YXlzIGxldCBjbG9uZV9tbnQoKSBpbiBjb3B5X3RyZWUoKSBr"
    "bm93IGl0IGlzIGZyb20gY29weV9tbnRfbnMoKQorCWNvcHlfZmxhZ3MgfD0gQ0xfQ09QWV9NTlRfTlM7CisJaWYgKGlzX3p5Z290ZV9waWQpIHsKKwkJLy8g"
    "TGV0IGNsb25lX21udCgpIGluIGNvcHlfdHJlZSgpIGtub3cgY29weV9tbnRfbnMoKSBpcyBydW4gYnkgenlnb3RlIHByb2Nlc3MKKwkJY29weV9mbGFncyB8"
    "PSBDTF9aWUdPVEVfQ09QWV9NTlRfTlM7CisJfQorI2VuZGlmCisKIAluZXcgPSBjb3B5X3RyZWUob2xkLCBvbGQtPm1udC5tbnRfcm9vdCwgY29weV9mbGFn"
    "cyk7CiAJaWYgKElTX0VSUihuZXcpKSB7CiAJCW5hbWVzcGFjZV91bmxvY2soKTsKQEAgLTMyOTksNiArMzUxMCwyOSBAQCBzdHJ1Y3QgbW50X25hbWVzcGFj"
    "ZSAqY29weV9tbnRfbnModW5zaWduZWQgbG9uZyBmbGFncywgc3RydWN0IG1udF9uYW1lc3BhY2UgKm5zLAogCQl3aGlsZSAocC0+bW50Lm1udF9yb290ICE9"
    "IHEtPm1udC5tbnRfcm9vdCkKIAkJCXAgPSBuZXh0X21udChwLCBvbGQpOwogCX0KKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVAorCS8vIGN1"
    "cnJlbnQtPnN1c2ZzX2xhc3RfZmFrZV9tbnRfaWQgLT4gdG8gcmVjb3JkIGxhc3QgdmFsaWQgZmFrZSBtbnRfaWQgdG8genlnb3RlIHBpZAorCS8vIHEtPm1u"
    "dC5zdXNmc19tbnRfaWRfYmFja3VwIC0+IG9yaWdpbmFsIG1udF9pZAorCS8vIHEtPm1udF9pZCAtPiB3aWxsIGJlIG1vZGlmaWVkIHRvIHRoZSBmYWtlIG1u"
    "dF9pZAorCisJLy8gSGVyZSBXZSBhcmUgb25seSBpbnRlcmVzdGVkIGluIHByb2Nlc3NlcyBvZiB3aGljaCBvcmlnaW5hbCBtbnQgbmFtZXNwYWNlIGJlbG9u"
    "Z3MgdG8genlnb3RlIAorCS8vIEFsc28gd2UganVzdCBtYWtlIHVzZSBvZiBleGlzdGluZyAncScgbW91bnQgcG9pbnRlciwgbm8gbmVlZCB0byBkZWxjYXJl"
    "IGV4dHJhIG1vdW50IHBvaW50ZXIKKwlpZiAoaXNfenlnb3RlX3BpZCkgeworCQlsYXN0X2VudHJ5X21udF9pZCA9IGxpc3RfZmlyc3RfZW50cnkoJm5ld19u"
    "cy0+bGlzdCwgc3RydWN0IG1vdW50LCBtbnRfbGlzdCktPm1udF9pZDsKKwkJbGlzdF9mb3JfZWFjaF9lbnRyeShxLCAmbmV3X25zLT5saXN0LCBtbnRfbGlz"
    "dCkgeworCQkJaWYgKHVubGlrZWx5KHEtPm1udF9pZCA+PSBERUZBVUxUX1NVU19NTlRfSUQpKSB7CisJCQkJY29udGludWU7CisJCQl9CisJCQlxLT5tbnQu"
    "c3VzZnNfbW50X2lkX2JhY2t1cCA9IHEtPm1udF9pZDsKKwkJCXEtPm1udF9pZCA9IGxhc3RfZW50cnlfbW50X2lkKys7CisJCX0KKwl9CisJLy8gQXNzaWdu"
    "IHRoZSAnbGFzdF9lbnRyeV9tbnRfaWQnIHRvICdjdXJyZW50LT5zdXNmc19sYXN0X2Zha2VfbW50X2lkJyBmb3IgbGF0ZXIgdXNlLgorCS8vIHNob3VsZCBi"
    "ZSBmaW5lIGhlcmUgYXNzdW1pbmcgenlnb3RlIGlzIGZvcmtpbmcvdW5zaGFyaW5nIGFwcCBpbiBvbmUgc2luZ2xlIHRocmVhZC4KKwkvLyBPciBzaG91bGQg"
    "d2UgcHV0IGEgbG9jayBoZXJlPworCWN1cnJlbnQtPnN1c2ZzX2xhc3RfZmFrZV9tbnRfaWQgPSBsYXN0X2VudHJ5X21udF9pZDsKKyNlbmRpZgorCiAJbmFt"
    "ZXNwYWNlX3VubG9jaygpOwogCiAJaWYgKHJvb3RtbnQpCkBAIC0zNTgxLDYgKzM4MTUsMTMgQEAgU1lTQ0FMTF9ERUZJTkU1KG1vdmVfbW91bnQsCiAJcGF0"
    "aF9wdXQoJnRvX3BhdGgpOwogb3V0X2Zyb206CiAJcGF0aF9wdXQoJmZyb21fcGF0aCk7CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19BVVRPX0FERF9TVVNf"
    "S1NVX0RFRkFVTFRfTU9VTlQKKwkvLyBGb3IgTGVnYWN5IEtTVSBtb3VudCBzY2hlbWUKKwlpZiAoIXJldCAmJiBzdXNmc19pc19hdXRvX2FkZF9zdXNfa3N1"
    "X2RlZmF1bHRfbW91bnRfZW5hYmxlZCAmJiBzdXNmc19pc19jdXJyZW50X2tzdV9kb21haW4oKSkgeworCQlzdXNmc19hdXRvX2FkZF9zdXNfa3N1X2RlZmF1"
    "bHRfbW91bnQodG9fcGF0aG5hbWUpOworCX0KKyNlbmRpZgorCiAJcmV0dXJuIHJldDsKIH0KIApAQCAtNDAzNywzICs0Mjc4LDM3IEBAIGNvbnN0IHN0cnVj"
    "dCBwcm9jX25zX29wZXJhdGlvbnMgbW50bnNfb3BlcmF0aW9ucyA9IHsKIAkuaW5zdGFsbAk9IG1udG5zX2luc3RhbGwsCiAJLm93bmVyCQk9IG1udG5zX293"
    "bmVyLAogfTsKKworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfVFJZX1VNT1VOVAorZXh0ZXJuIHZvaWQgc3VzZnNfdHJ5X3Vtb3VudF9hbGwodWlkX3QgdWlk"
    "KTsKK3ZvaWQgc3VzZnNfcnVuX3RyeV91bW91bnRfZm9yX2N1cnJlbnRfbW50X25zKHZvaWQpIHsKKwlzdHJ1Y3QgbW91bnQgKm1udDsKKwlzdHJ1Y3QgbW50"
    "X25hbWVzcGFjZSAqbW50X25zOworCisJbW50X25zID0gY3VycmVudC0+bnNwcm94eS0+bW50X25zOworCS8vIExvY2sgdGhlIG5hbWVzcGFjZQorCW5hbWVz"
    "cGFjZV9sb2NrKCk7CisJbGlzdF9mb3JfZWFjaF9lbnRyeShtbnQsICZtbnRfbnMtPmxpc3QsIG1udF9saXN0KSB7CisJCS8vIENoYW5nZSB0aGUgc3VzIG1v"
    "dW50IHRvIGJlIHByaXZhdGUKKwkJaWYgKG1udC0+bW50X2lkID49IERFRkFVTFRfU1VTX01OVF9JRCkgeworCQkJY2hhbmdlX21udF9wcm9wYWdhdGlvbiht"
    "bnQsIE1TX1BSSVZBVEUpOworCQl9CisJfQorCS8vIFVubG9jayB0aGUgbmFtZXNwYWNlCisJbmFtZXNwYWNlX3VubG9jaygpOworCXN1c2ZzX3RyeV91bW91"
    "bnRfYWxsKGN1cnJlbnRfdWlkKCkudmFsKTsKK30KKyNlbmRpZgorI2lmZGVmIENPTkZJR19LU1VfU1VTRlMKK2Jvb2wgc3VzZnNfaXNfbW50X2Rldm5hbWVf"
    "a3N1KHN0cnVjdCBwYXRoICpwYXRoKSB7CisJc3RydWN0IG1vdW50ICptbnQ7CisKKwlpZiAocGF0aCAmJiBwYXRoLT5tbnQpIHsKKwkJbW50ID0gcmVhbF9t"
    "b3VudChwYXRoLT5tbnQpOworCQlpZiAobW50ICYmIG1udC0+bW50X2Rldm5hbWUgJiYgIXN0cmNtcChtbnQtPm1udF9kZXZuYW1lLCAiS1NVIikpIHsKKwkJ"
    "CXJldHVybiB0cnVlOworCQl9CisJfQorCXJldHVybiBmYWxzZTsKK30KKyNlbmRpZgpkaWZmIC0tZ2l0IGEvZnMvbm90aWZ5L2ZkaW5mby5jIGIvZnMvbm90"
    "aWZ5L2ZkaW5mby5jCmluZGV4IDdkZjlhZDRkODQzMy4uNGRmNTM4MTg3ZTVhIDEwMDY0NAotLS0gYS9mcy9ub3RpZnkvZmRpbmZvLmMKKysrIGIvZnMvbm90"
    "aWZ5L2ZkaW5mby5jCkBAIC0xMyw2ICsxMyw5IEBACiAjaW5jbHVkZSA8bGludXgvc2VxX2ZpbGUuaD4KICNpbmNsdWRlIDxsaW51eC9wcm9jX2ZzLmg+CiAj"
    "aW5jbHVkZSA8bGludXgvZXhwb3J0ZnMuaD4KKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVAorI2luY2x1ZGUgPGxpbnV4L3N1c2ZzX2RlZi5o"
    "PgorI2VuZGlmCiAKICNpbmNsdWRlICJpbm90aWZ5L2lub3RpZnkuaCIKICNpbmNsdWRlICJmZGluZm8uaCIKQEAgLTIyLDE2ICsyNSwyNyBAQAogCiAjaWYg"
    "ZGVmaW5lZChDT05GSUdfSU5PVElGWV9VU0VSKSB8fCBkZWZpbmVkKENPTkZJR19GQU5PVElGWSkKIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01P"
    "VU5UCitzdGF0aWMgdm9pZCBzaG93X2ZkaW5mbyhzdHJ1Y3Qgc2VxX2ZpbGUgKm0sIHN0cnVjdCBmaWxlICpmLAorCQkJdm9pZCAoKnNob3cpKHN0cnVjdCBz"
    "ZXFfZmlsZSAqbSwKKwkJCQkgICAgIHN0cnVjdCBmc25vdGlmeV9tYXJrICptYXJrLAorCQkJCQkgc3RydWN0IGZpbGUgKmZpbGUpKQorI2Vsc2UKIHN0YXRp"
    "YyB2b2lkIHNob3dfZmRpbmZvKHN0cnVjdCBzZXFfZmlsZSAqbSwgc3RydWN0IGZpbGUgKmYsCiAJCQl2b2lkICgqc2hvdykoc3RydWN0IHNlcV9maWxlICpt"
    "LAogCQkJCSAgICAgc3RydWN0IGZzbm90aWZ5X21hcmsgKm1hcmspKQorI2VuZGlmCiB7CiAJc3RydWN0IGZzbm90aWZ5X2dyb3VwICpncm91cCA9IGYtPnBy"
    "aXZhdGVfZGF0YTsKIAlzdHJ1Y3QgZnNub3RpZnlfbWFyayAqbWFyazsKIAogCW11dGV4X2xvY2soJmdyb3VwLT5tYXJrX211dGV4KTsKIAlsaXN0X2Zvcl9l"
    "YWNoX2VudHJ5KG1hcmssICZncm91cC0+bWFya3NfbGlzdCwgZ19saXN0KSB7CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQKKwkJc2hvdyht"
    "LCBtYXJrLCBmKTsKKyNlbHNlCiAJCXNob3cobSwgbWFyayk7CisjZW5kaWYKIAkJaWYgKHNlcV9oYXNfb3ZlcmZsb3dlZChtKSkKIAkJCWJyZWFrOwogCX0K"
    "QEAgLTczLDcgKzg3LDExIEBAIHN0YXRpYyB2b2lkIHNob3dfbWFya19maGFuZGxlKHN0cnVjdCBzZXFfZmlsZSAqbSwgc3RydWN0IGlub2RlICppbm9kZSkK"
    "IAogI2lmZGVmIENPTkZJR19JTk9USUZZX1VTRVIKIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UCitzdGF0aWMgdm9pZCBpbm90aWZ5X2Zk"
    "aW5mbyhzdHJ1Y3Qgc2VxX2ZpbGUgKm0sIHN0cnVjdCBmc25vdGlmeV9tYXJrICptYXJrLCBzdHJ1Y3QgZmlsZSAqZmlsZSkKKyNlbHNlCiBzdGF0aWMgdm9p"
    "ZCBpbm90aWZ5X2ZkaW5mbyhzdHJ1Y3Qgc2VxX2ZpbGUgKm0sIHN0cnVjdCBmc25vdGlmeV9tYXJrICptYXJrKQorI2VuZGlmCiB7CiAJc3RydWN0IGlub3Rp"
    "ZnlfaW5vZGVfbWFyayAqaW5vZGVfbWFyazsKIAlzdHJ1Y3QgaW5vZGUgKmlub2RlOwpAQCAtODQsNiArMTAyLDM2IEBAIHN0YXRpYyB2b2lkIGlub3RpZnlf"
    "ZmRpbmZvKHN0cnVjdCBzZXFfZmlsZSAqbSwgc3RydWN0IGZzbm90aWZ5X21hcmsgKm1hcmspCiAJaW5vZGVfbWFyayA9IGNvbnRhaW5lcl9vZihtYXJrLCBz"
    "dHJ1Y3QgaW5vdGlmeV9pbm9kZV9tYXJrLCBmc25fbWFyayk7CiAJaW5vZGUgPSBpZ3JhYihmc25vdGlmeV9jb25uX2lub2RlKG1hcmstPmNvbm5lY3Rvcikp"
    "OwogCWlmIChpbm9kZSkgeworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UCisJCWlmIChsaWtlbHkoY3VycmVudC0+c3VzZnNfdGFza19zdGF0"
    "ZSAmIFRBU0tfU1RSVUNUX05PTl9ST09UX1VTRVJfQVBQX1BST0MpICYmCisJCQkJdW5saWtlbHkoaW5vZGUtPmlfc3RhdGUgJiBJTk9ERV9TVEFURV9TVVNf"
    "S1NUQVQpKSB7CisJCQlzdHJ1Y3QgcGF0aCBwYXRoOworCQkJY2hhciAqcGF0aG5hbWUgPSBrbWFsbG9jKFBBR0VfU0laRSwgR0ZQX0tFUk5FTCk7CisJCQlj"
    "aGFyICpkcGF0aDsKKwkJCWlmICghcGF0aG5hbWUpIHsKKwkJCQlnb3RvIG91dF9zZXFfcHJpbnRmOworCQkJfQorCQkJZHBhdGggPSBkX3BhdGgoJmZpbGUt"
    "PmZfcGF0aCwgcGF0aG5hbWUsIFBBR0VfU0laRSk7CisJCQlpZiAoIWRwYXRoKSB7CisJCQkJZ290byBvdXRfZnJlZV9wYXRobmFtZTsKKwkJCX0KKwkJCWlm"
    "IChrZXJuX3BhdGgoZHBhdGgsIDAsICZwYXRoKSkgeworCQkJCWdvdG8gb3V0X2ZyZWVfcGF0aG5hbWU7CisJCQl9CisJCQlzZXFfcHJpbnRmKG0sICJpbm90"
    "aWZ5IHdkOiV4IGlubzolbHggc2RldjoleCBtYXNrOiV4IGlnbm9yZWRfbWFzazowICIsCisJCQkJCWlub2RlX21hcmstPndkLCBwYXRoLmRlbnRyeS0+ZF9p"
    "bm9kZS0+aV9pbm8sIHBhdGguZGVudHJ5LT5kX2lub2RlLT5pX3NiLT5zX2RldiwKKwkJCQkJaW5vdGlmeV9tYXJrX3VzZXJfbWFzayhtYXJrKSk7CisJCQlz"
    "aG93X21hcmtfZmhhbmRsZShtLCBwYXRoLmRlbnRyeS0+ZF9pbm9kZSk7CisJCQlzZXFfcHV0YyhtLCAnXG4nKTsKKwkJCWlwdXQoaW5vZGUpOworCQkJcGF0"
    "aF9wdXQoJnBhdGgpOworCQkJa2ZyZWUocGF0aG5hbWUpOworCQkJcmV0dXJuOworb3V0X2ZyZWVfcGF0aG5hbWU6CisJCQlrZnJlZShwYXRobmFtZSk7CisJ"
    "CX0KK291dF9zZXFfcHJpbnRmOgorI2VuZGlmCiAJCXNlcV9wcmludGYobSwgImlub3RpZnkgd2Q6JXggaW5vOiVseCBzZGV2OiV4IG1hc2s6JXggaWdub3Jl"
    "ZF9tYXNrOjAgIiwKIAkJCSAgIGlub2RlX21hcmstPndkLCBpbm9kZS0+aV9pbm8sIGlub2RlLT5pX3NiLT5zX2RldiwKIAkJCSAgIGlub3RpZnlfbWFya191"
    "c2VyX21hc2sobWFyaykpOwpkaWZmIC0tZ2l0IGEvZnMvb3Blbi5jIGIvZnMvb3Blbi5jCmluZGV4IGM2NjQ2OTI2YTYxYS4uMTFkZmUyODQzMTdiIDEwMDY0"
    "NAotLS0gYS9mcy9vcGVuLmMKKysrIGIvZnMvb3Blbi5jCkBAIC0zNDUsNiArMzQ1LDEzIEBAIFNZU0NBTExfREVGSU5FNChmYWxsb2NhdGUsIGludCwgZmQs"
    "IGludCwgbW9kZSwgbG9mZl90LCBvZmZzZXQsIGxvZmZfdCwgbGVuKQogICogV2UgZG8gdGhpcyBieSB0ZW1wb3JhcmlseSBjbGVhcmluZyBhbGwgRlMtcmVs"
    "YXRlZCBjYXBhYmlsaXRpZXMgYW5kCiAgKiBzd2l0Y2hpbmcgdGhlIGZzdWlkL2ZzZ2lkIGFyb3VuZCB0byB0aGUgcmVhbCBvbmVzLgogICovCisKKyNpZmRl"
    "ZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19TVQorZXh0ZXJuIGJvb2wgc3VzZnNfaXNfc3VzX3N1X2hvb2tzX2VuYWJsZWQgX19yZWFkX21vc3RseTsKK2V4dGVy"
    "biBpbnQga3N1X2hhbmRsZV9mYWNjZXNzYXQoaW50ICpkZmQsIGNvbnN0IGNoYXIgX191c2VyICoqZmlsZW5hbWVfdXNlciwgaW50ICptb2RlLAorCQkJaW50"
    "ICpmbGFncyk7CisjZW5kaWYKKwogbG9uZyBkb19mYWNjZXNzYXQoaW50IGRmZCwgY29uc3QgY2hhciBfX3VzZXIgKmZpbGVuYW1lLCBpbnQgbW9kZSkKIHsK"
    "IAljb25zdCBzdHJ1Y3QgY3JlZCAqb2xkX2NyZWQ7CkBAIC0zNTQsNiArMzYxLDEyIEBAIGxvbmcgZG9fZmFjY2Vzc2F0KGludCBkZmQsIGNvbnN0IGNoYXIg"
    "X191c2VyICpmaWxlbmFtZSwgaW50IG1vZGUpCiAJaW50IHJlczsKIAl1bnNpZ25lZCBpbnQgbG9va3VwX2ZsYWdzID0gTE9PS1VQX0ZPTExPVzsKIAorI2lm"
    "ZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX1NVCisJaWYgKHN1c2ZzX2lzX3N1c19zdV9ob29rc19lbmFibGVkKSB7CisJCWtzdV9oYW5kbGVfZmFjY2Vzc2F0"
    "KCZkZmQsICZmaWxlbmFtZSwgJm1vZGUsIE5VTEwpOworCX0KKyNlbmRpZgorCiAJaWYgKG1vZGUgJiB+U19JUldYTykJLyogd2hlcmUncyBGX09LLCBYX09L"
    "LCBXX09LLCBSX09LPyAqLwogCQlyZXR1cm4gLUVJTlZBTDsKIApkaWZmIC0tZ2l0IGEvZnMvb3ZlcmxheWZzL2lub2RlLmMgYi9mcy9vdmVybGF5ZnMvaW5v"
    "ZGUuYwppbmRleCBiNWRkMDQ5NjExMzAuLmU0NDBiYWQzN2JjYyAxMDA2NDQKLS0tIGEvZnMvb3ZlcmxheWZzL2lub2RlLmMKKysrIGIvZnMvb3ZlcmxheWZz"
    "L2lub2RlLmMKQEAgLTE1Myw2ICsxNTMsMTUgQEAgaW50IG92bF9nZXRhdHRyKGNvbnN0IHN0cnVjdCBwYXRoICpwYXRoLCBzdHJ1Y3Qga3N0YXQgKnN0YXQs"
    "CiAKIAltZXRhY29weV9ibG9ja3MgPSBvdmxfaXNfbWV0YWNvcHlfZGVudHJ5KGRlbnRyeSk7CiAKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19PVkVS"
    "TEFZRlMKKwlvdmxfcGF0aF9sb3dlcmRhdGEoZGVudHJ5LCAmcmVhbHBhdGgpOworCWlmIChsaWtlbHkocmVhbHBhdGgubW50ICYmIHJlYWxwYXRoLmRlbnRy"
    "eSkpIHsKKwkJb2xkX2NyZWQgPSBvdmxfb3ZlcnJpZGVfY3JlZHMoZGVudHJ5LT5kX3NiKTsKKwkJZXJyID0gdmZzX2dldGF0dHIoJnJlYWxwYXRoLCBzdGF0"
    "LCByZXF1ZXN0X21hc2ssIGZsYWdzKTsKKwkJZ290byBvdXQ7CisJfQorI2VuZGlmCisKIAl0eXBlID0gb3ZsX3BhdGhfcmVhbChkZW50cnksICZyZWFscGF0"
    "aCk7CiAJb2xkX2NyZWQgPSBvdmxfb3ZlcnJpZGVfY3JlZHMoZGVudHJ5LT5kX3NiKTsKIAllcnIgPSB2ZnNfZ2V0YXR0cigmcmVhbHBhdGgsIHN0YXQsIHJl"
    "cXVlc3RfbWFzaywgZmxhZ3MpOwpkaWZmIC0tZ2l0IGEvZnMvb3ZlcmxheWZzL3JlYWRkaXIuYyBiL2ZzL292ZXJsYXlmcy9yZWFkZGlyLmMKaW5kZXggYTMy"
    "Mzk5ZDBlNzQyLi42YTQ2MTMzODM4MzEgMTAwNjQ0Ci0tLSBhL2ZzL292ZXJsYXlmcy9yZWFkZGlyLmMKKysrIGIvZnMvb3ZlcmxheWZzL3JlYWRkaXIuYwpA"
    "QCAtODkyLDcgKzg5MiwxOSBAQCBzdGF0aWMgaW50IG92bF9kaXJfb3BlbihzdHJ1Y3QgaW5vZGUgKmlub2RlLCBzdHJ1Y3QgZmlsZSAqZmlsZSkKIAlpZiAo"
    "IW9kKQogCQlyZXR1cm4gLUVOT01FTTsKIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX09WRVJMQVlGUworCW92bF9wYXRoX2xvd2VyZGF0YShmaWxl"
    "LT5mX3BhdGguZGVudHJ5LCAmcmVhbHBhdGgpOworCWlmIChsaWtlbHkocmVhbHBhdGgubW50ICYmIHJlYWxwYXRoLmRlbnRyeSkpIHsKKwkJLy8gV2Ugc3Rp"
    "bGwgdXNlICdfX09WTF9QQVRIX1VQUEVSJyBoZXJlIHdoaWNoIHNob3VsZCBiZSBmaW5lLiAgCisJCXR5cGUgPSBfX09WTF9QQVRIX1VQUEVSOworCQlnb3Rv"
    "IGJ5cGFzc19vcmlnX2Zsb3c7CisJfQorI2VuZGlmCisKIAl0eXBlID0gb3ZsX3BhdGhfcmVhbChmaWxlLT5mX3BhdGguZGVudHJ5LCAmcmVhbHBhdGgpOwor"
    "I2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX09WRVJMQVlGUworYnlwYXNzX29yaWdfZmxvdzoKKyNlbmRpZgogCXJlYWxmaWxlID0gb3ZsX3BhdGhfb3Bl"
    "bigmcmVhbHBhdGgsIGZpbGUtPmZfZmxhZ3MpOwogCWlmIChJU19FUlIocmVhbGZpbGUpKSB7CiAJCWtmcmVlKG9kKTsKZGlmZiAtLWdpdCBhL2ZzL292ZXJs"
    "YXlmcy9zdXBlci5jIGIvZnMvb3ZlcmxheWZzL3N1cGVyLmMKaW5kZXggMDkzYWYxZGNiZGQ2Li5hOGExYzUyZmYxMmYgMTAwNjQ0Ci0tLSBhL2ZzL292ZXJs"
    "YXlmcy9zdXBlci5jCisrKyBiL2ZzL292ZXJsYXlmcy9zdXBlci5jCkBAIC0zMDIsNiArMzAyLDE4IEBAIHN0YXRpYyBpbnQgb3ZsX3N0YXRmcyhzdHJ1Y3Qg"
    "ZGVudHJ5ICpkZW50cnksIHN0cnVjdCBrc3RhdGZzICpidWYpCiAJc3RydWN0IHBhdGggcGF0aDsKIAlpbnQgZXJyOwogCisjaWZkZWYgQ09ORklHX0tTVV9T"
    "VVNGU19TVVNfT1ZFUkxBWUZTCisJb3ZsX3BhdGhfbG93ZXJkYXRhKHJvb3RfZGVudHJ5LCAmcGF0aCk7CisJaWYgKGxpa2VseShwYXRoLm1udCAmJiBwYXRo"
    "LmRlbnRyeSkpIHsKKwkJZXJyID0gdmZzX3N0YXRmcygmcGF0aCwgYnVmKTsKKwkJaWYgKCFlcnIpIHsKKwkJCWJ1Zi0+Zl9uYW1lbGVuID0gMjU1OyAvLyAy"
    "NTUgZm9yIGVyb2ZzLCBleHQyLzQsIGYyZnMKKwkJCWJ1Zi0+Zl90eXBlID0gcGF0aC5kZW50cnktPmRfc2ItPnNfbWFnaWM7CisJCX0KKwkJcmV0dXJuIGVy"
    "cjsKKwl9CisjZW5kaWYKKwogCW92bF9wYXRoX3JlYWwocm9vdF9kZW50cnksICZwYXRoKTsKIAogCWVyciA9IHZmc19zdGF0ZnMoJnBhdGgsIGJ1Zik7CmRp"
    "ZmYgLS1naXQgYS9mcy9wcm9jL2ZkLmMgYi9mcy9wcm9jL2ZkLmMKaW5kZXggNmI2MzRjMGE5YjZlLi4xYmY2Y2E1NjQyNDggMTAwNjQ0Ci0tLSBhL2ZzL3By"
    "b2MvZmQuYworKysgYi9mcy9wcm9jL2ZkLmMKQEAgLTEzLDYgKzEzLDkgQEAKICNpbmNsdWRlIDxsaW51eC9mcy5oPgogCiAjaW5jbHVkZSA8bGludXgvcHJv"
    "Y19mcy5oPgorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UCisjaW5jbHVkZSA8bGludXgvc3VzZnNfZGVmLmg+CisjZW5kaWYKIAogI2luY2x1"
    "ZGUgIi4uL21vdW50LmgiCiAjaW5jbHVkZSAiaW50ZXJuYWwuaCIKQEAgLTI0LDYgKzI3LDkgQEAgc3RhdGljIGludCBzZXFfc2hvdyhzdHJ1Y3Qgc2VxX2Zp"
    "bGUgKm0sIHZvaWQgKnYpCiAJaW50IGZfZmxhZ3MgPSAwLCByZXQgPSAtRU5PRU5UOwogCXN0cnVjdCBmaWxlICpmaWxlID0gTlVMTDsKIAlzdHJ1Y3QgdGFz"
    "a19zdHJ1Y3QgKnRhc2s7CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQKKwlzdHJ1Y3QgbW91bnQgKm1udCA9IE5VTEw7CisjZW5kaWYKIAog"
    "CXRhc2sgPSBnZXRfcHJvY190YXNrKG0tPnByaXZhdGUpOwogCWlmICghdGFzaykKQEAgLTU0LDEwICs2MCw0OCBAQCBzdGF0aWMgaW50IHNlcV9zaG93KHN0"
    "cnVjdCBzZXFfZmlsZSAqbSwgdm9pZCAqdikKIAlpZiAocmV0KQogCQlyZXR1cm4gcmV0OwogCisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQK"
    "KwltbnQgPSByZWFsX21vdW50KGZpbGUtPmZfcGF0aC5tbnQpOworCWlmIChsaWtlbHkoY3VycmVudC0+c3VzZnNfdGFza19zdGF0ZSAmIFRBU0tfU1RSVUNU"
    "X05PTl9ST09UX1VTRVJfQVBQX1BST0MpICYmCisJCQltbnQtPm1udF9pZCA+PSBERUZBVUxUX1NVU19NTlRfSUQpIHsKKwkJc3RydWN0IHBhdGggcGF0aDsK"
    "KwkJY2hhciAqcGF0aG5hbWUgPSBrbWFsbG9jKFBBR0VfU0laRSwgR0ZQX0tFUk5FTCk7CisJCWNoYXIgKmRwYXRoOworCisJCWZvciAoOyBtbnQtPm1udF9p"
    "ZCA+PSBERUZBVUxUX1NVU19NTlRfSUQ7IG1udCA9IG1udC0+bW50X3BhcmVudCkgeyB9CisKKwkJaWYgKCFwYXRobmFtZSkgeworCQkJZ290byBvdXRfc2Vx"
    "X3ByaW50ZjsKKwkJfQorCQlkcGF0aCA9IGRfcGF0aCgmZmlsZS0+Zl9wYXRoLCBwYXRobmFtZSwgUEFHRV9TSVpFKTsKKwkJaWYgKCFkcGF0aCkgeworCQkJ"
    "Z290byBvdXRfZnJlZV9wYXRobmFtZTsKKwkJfQorCQlpZiAoa2Vybl9wYXRoKGRwYXRoLCAwLCAmcGF0aCkpIHsKKwkJCWdvdG8gb3V0X2ZyZWVfcGF0aG5h"
    "bWU7CisJCX0KKwkJc2VxX3ByaW50ZihtLCAicG9zOlx0JWxsaVxuZmxhZ3M6XHQwJW9cbm1udF9pZDpcdCVpXG5pbm86XHQlbHVcbiIsCisJCQkJKGxvbmcg"
    "bG9uZylmaWxlLT5mX3BvcywgZl9mbGFncywKKwkJCQltbnQtPm1udF9pZCwKKwkJCQlwYXRoLmRlbnRyeS0+ZF9pbm9kZS0+aV9pbm8pOworCQlwYXRoX3B1"
    "dCgmcGF0aCk7CisJCWtmcmVlKHBhdGhuYW1lKTsKKwkJZ290byBieXBhc3Nfb3JpZ19mbG93Oworb3V0X2ZyZWVfcGF0aG5hbWU6CisJCWtmcmVlKHBhdGhu"
    "YW1lKTsKKwl9CitvdXRfc2VxX3ByaW50ZjoKKwlzZXFfcHJpbnRmKG0sICJwb3M6XHQlbGxpXG5mbGFnczpcdDAlb1xubW50X2lkOlx0JWlcbmlubzpcdCVs"
    "dVxuIiwKKwkJICAgKGxvbmcgbG9uZylmaWxlLT5mX3BvcywgZl9mbGFncywKKwkJICAgbW50LT5tbnRfaWQsCisJCSAgIGZpbGVfaW5vZGUoZmlsZSktPmlf"
    "aW5vKTsKK2J5cGFzc19vcmlnX2Zsb3c6CisjZWxzZQogCXNlcV9wcmludGYobSwgInBvczpcdCVsbGlcbmZsYWdzOlx0MCVvXG5tbnRfaWQ6XHQlaVxuaW5v"
    "Olx0JWx1XG4iLAogCQkgICAobG9uZyBsb25nKWZpbGUtPmZfcG9zLCBmX2ZsYWdzLAogCQkgICByZWFsX21vdW50KGZpbGUtPmZfcGF0aC5tbnQpLT5tbnRf"
    "aWQsCiAJCSAgIGZpbGVfaW5vZGUoZmlsZSktPmlfaW5vKTsKKyNlbmRpZgogCiAJc2hvd19mZF9sb2NrcyhtLCBmaWxlLCBmaWxlcyk7CiAJaWYgKHNlcV9o"
    "YXNfb3ZlcmZsb3dlZChtKSkKZGlmZiAtLWdpdCBhL2ZzL3Byb2MvdGFza19tbXUuYyBiL2ZzL3Byb2MvdGFza19tbXUuYwppbmRleCA5MDAzY2Q4MWU0MzMu"
    "LmQyMDUzOWY2ODAzMiAxMDA2NDQKLS0tIGEvZnMvcHJvYy90YXNrX21tdS5jCisrKyBiL2ZzL3Byb2MvdGFza19tbXUuYwpAQCAtMjAsNiArMjAsOSBAQAog"
    "I2luY2x1ZGUgPGxpbnV4L3NobWVtX2ZzLmg+CiAjaW5jbHVkZSA8bGludXgvdWFjY2Vzcy5oPgogI2luY2x1ZGUgPGxpbnV4L3BrZXlzLmg+CisjaWZkZWYg"
    "Q09ORklHX0tTVV9TVVNGU19TVVNfS1NUQVQKKyNpbmNsdWRlIDxsaW51eC9zdXNmc19kZWYuaD4KKyNlbmRpZgogCiAjaW5jbHVkZSA8YXNtL2VsZi5oPgog"
    "I2luY2x1ZGUgPGFzbS90bGIuaD4KQEAgLTM0Nyw2ICszNTAsMTAgQEAgc3RhdGljIHZvaWQgc2hvd192bWFfaGVhZGVyX3ByZWZpeChzdHJ1Y3Qgc2VxX2Zp"
    "bGUgKm0sCiAJc2VxX3B1dGMobSwgJyAnKTsKIH0KIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX0tTVEFUCitleHRlcm4gdm9pZCBzdXNmc19zdXNf"
    "aW5vX2Zvcl9zaG93X21hcF92bWEodW5zaWduZWQgbG9uZyBpbm8sIGRldl90ICpvdXRfZGV2LCB1bnNpZ25lZCBsb25nICpvdXRfaW5vKTsKKyNlbmRpZgor"
    "CiBzdGF0aWMgdm9pZAogc2hvd19tYXBfdm1hKHN0cnVjdCBzZXFfZmlsZSAqbSwgc3RydWN0IHZtX2FyZWFfc3RydWN0ICp2bWEpCiB7CkBAIC0zNjEsOCAr"
    "MzY4LDE3IEBAIHNob3dfbWFwX3ZtYShzdHJ1Y3Qgc2VxX2ZpbGUgKm0sIHN0cnVjdCB2bV9hcmVhX3N0cnVjdCAqdm1hKQogCiAJaWYgKGZpbGUpIHsKIAkJ"
    "c3RydWN0IGlub2RlICppbm9kZSA9IGZpbGVfaW5vZGUodm1hLT52bV9maWxlKTsKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19LU1RBVAorCQlpZiAo"
    "dW5saWtlbHkoaW5vZGUtPmlfc3RhdGUgJiBJTk9ERV9TVEFURV9TVVNfS1NUQVQpKSB7CisJCQlzdXNmc19zdXNfaW5vX2Zvcl9zaG93X21hcF92bWEoaW5v"
    "ZGUtPmlfaW5vLCAmZGV2LCAmaW5vKTsKKwkJCWdvdG8gYnlwYXNzX29yaWdfZmxvdzsKKwkJfQorI2VuZGlmCiAJCWRldiA9IGlub2RlLT5pX3NiLT5zX2Rl"
    "djsKIAkJaW5vID0gaW5vZGUtPmlfaW5vOworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX0tTVEFUCitieXBhc3Nfb3JpZ19mbG93OgorI2VuZGlmCiAJ"
    "CXBnb2ZmID0gKChsb2ZmX3Qpdm1hLT52bV9wZ29mZikgPDwgUEFHRV9TSElGVDsKIAl9CiAKZGlmZiAtLWdpdCBhL2ZzL3Byb2NfbmFtZXNwYWNlLmMgYi9m"
    "cy9wcm9jX25hbWVzcGFjZS5jCmluZGV4IDI3M2VlODJkOGFhOS4uODZiZDZkMTQwOTYyIDEwMDY0NAotLS0gYS9mcy9wcm9jX25hbWVzcGFjZS5jCisrKyBi"
    "L2ZzL3Byb2NfbmFtZXNwYWNlLmMKQEAgLTEyLDYgKzEyLDkgQEAKICNpbmNsdWRlIDxsaW51eC9zZWN1cml0eS5oPgogI2luY2x1ZGUgPGxpbnV4L2ZzX3N0"
    "cnVjdC5oPgogI2luY2x1ZGUgPGxpbnV4L3NjaGVkL3Rhc2suaD4KKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVAorI2luY2x1ZGUgPGxpbnV4"
    "L3N1c2ZzX2RlZi5oPgorI2VuZGlmCiAKICNpbmNsdWRlICJwcm9jL2ludGVybmFsLmgiIC8qIG9ubHkgZm9yIGdldF9wcm9jX3Rhc2soKSBpbiAtPm9wZW4o"
    "KSAqLwogCkBAIC0xMDIsNiArMTA1LDExIEBAIHN0YXRpYyBpbnQgc2hvd192ZnNtbnQoc3RydWN0IHNlcV9maWxlICptLCBzdHJ1Y3QgdmZzbW91bnQgKm1u"
    "dCkKIAlzdHJ1Y3Qgc3VwZXJfYmxvY2sgKnNiID0gbW50X3BhdGguZGVudHJ5LT5kX3NiOwogCWludCBlcnI7CiAKKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZT"
    "X1NVU19NT1VOVAorCWlmICh1bmxpa2VseShyLT5tbnRfaWQgPj0gREVGQVVMVF9TVVNfTU5UX0lEKSkKKwkJcmV0dXJuIDA7CisjZW5kaWYKKwogCWlmIChz"
    "Yi0+c19vcC0+c2hvd19kZXZuYW1lKSB7CiAJCWVyciA9IHNiLT5zX29wLT5zaG93X2Rldm5hbWUobSwgbW50X3BhdGguZGVudHJ5KTsKIAkJaWYgKGVycikK"
    "QEAgLTEzNiw2ICsxNDQsMTEgQEAgc3RhdGljIGludCBzaG93X21vdW50aW5mbyhzdHJ1Y3Qgc2VxX2ZpbGUgKm0sIHN0cnVjdCB2ZnNtb3VudCAqbW50KQog"
    "CXN0cnVjdCBwYXRoIG1udF9wYXRoID0geyAuZGVudHJ5ID0gbW50LT5tbnRfcm9vdCwgLm1udCA9IG1udCB9OwogCWludCBlcnI7CiAKKyNpZmRlZiBDT05G"
    "SUdfS1NVX1NVU0ZTX1NVU19NT1VOVAorCWlmICh1bmxpa2VseShyLT5tbnRfaWQgPj0gREVGQVVMVF9TVVNfTU5UX0lEKSkKKwkJcmV0dXJuIDA7CisjZW5k"
    "aWYKKwogCXNlcV9wcmludGYobSwgIiVpICVpICV1OiV1ICIsIHItPm1udF9pZCwgci0+bW50X3BhcmVudC0+bW50X2lkLAogCQkgICBNQUpPUihzYi0+c19k"
    "ZXYpLCBNSU5PUihzYi0+c19kZXYpKTsKIAlpZiAoc2ItPnNfb3AtPnNob3dfcGF0aCkgewpAQCAtMTk4LDYgKzIxMSwxMSBAQCBzdGF0aWMgaW50IHNob3df"
    "dmZzc3RhdChzdHJ1Y3Qgc2VxX2ZpbGUgKm0sIHN0cnVjdCB2ZnNtb3VudCAqbW50KQogCXN0cnVjdCBzdXBlcl9ibG9jayAqc2IgPSBtbnRfcGF0aC5kZW50"
    "cnktPmRfc2I7CiAJaW50IGVycjsKIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX01PVU5UCisJaWYgKHVubGlrZWx5KHItPm1udF9pZCA+PSBERUZB"
    "VUxUX1NVU19NTlRfSUQpKQorCQlyZXR1cm4gMDsKKyNlbmRpZgorCiAJLyogZGV2aWNlICovCiAJaWYgKHNiLT5zX29wLT5zaG93X2Rldm5hbWUpIHsKIAkJ"
    "c2VxX3B1dHMobSwgImRldmljZSAiKTsKZGlmZiAtLWdpdCBhL2ZzL3JlYWRkaXIuYyBiL2ZzL3JlYWRkaXIuYwppbmRleCAwN2EzYjViYWE0MDQuLjI5Yjhl"
    "ODg2ODE5YyAxMDA2NDQKLS0tIGEvZnMvcmVhZGRpci5jCisrKyBiL2ZzL3JlYWRkaXIuYwpAQCAtMjEsNiArMjEsOSBAQAogI2luY2x1ZGUgPGxpbnV4L3Vu"
    "aXN0ZC5oPgogI2luY2x1ZGUgPGxpbnV4L2NvbXBhdC5oPgogI2luY2x1ZGUgPGxpbnV4L3VhY2Nlc3MuaD4KKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NV"
    "U19QQVRICisjaW5jbHVkZSA8bGludXgvc3VzZnNfZGVmLmg+CisjZW5kaWYKIAogI2luY2x1ZGUgPGFzbS91bmFsaWduZWQuaD4KIApAQCAtMzYsNiArMzks"
    "OSBAQAogCXVuc2FmZV9jb3B5X3RvX3VzZXIoZHN0LCBzcmMsIGxlbiwgbGFiZWwpOwkJXAogfSB3aGlsZSAoMCkKIAorI2lmZGVmIENPTkZJR19LU1VfU1VT"
    "RlNfU1VTX1BBVEgKK2V4dGVybiBpbnQgc3VzZnNfc3VzX2lub19mb3JfZmlsbGRpcjY0KHVuc2lnbmVkIGxvbmcgaW5vKTsKKyNlbmRpZgogCiBpbnQgaXRl"
    "cmF0ZV9kaXIoc3RydWN0IGZpbGUgKmZpbGUsIHN0cnVjdCBkaXJfY29udGV4dCAqY3R4KQogewpAQCAtMjI5LDYgKzIzNSwxMSBAQCBzdGF0aWMgaW50IGZp"
    "bGxkaXIoc3RydWN0IGRpcl9jb250ZXh0ICpjdHgsIGNvbnN0IGNoYXIgKm5hbWUsIGludCBuYW1sZW4sCiAJCXNpemVvZihsb25nKSk7CiAJaW50IHByZXZf"
    "cmVjbGVuOwogCisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfUEFUSAorCWlmIChsaWtlbHkoY3VycmVudC0+c3VzZnNfdGFza19zdGF0ZSAmIFRBU0tf"
    "U1RSVUNUX05PTl9ST09UX1VTRVJfQVBQX1BST0MpICYmIHN1c2ZzX3N1c19pbm9fZm9yX2ZpbGxkaXI2NChpbm8pKSB7CisJCXJldHVybiAwOworCX0KKyNl"
    "bmRpZgogCWJ1Zi0+ZXJyb3IgPSB2ZXJpZnlfZGlyZW50X25hbWUobmFtZSwgbmFtbGVuKTsKIAlpZiAodW5saWtlbHkoYnVmLT5lcnJvcikpCiAJCXJldHVy"
    "biBidWYtPmVycm9yOwpAQCAtMzE5LDYgKzMzMCwxMSBAQCBzdGF0aWMgaW50IGZpbGxkaXI2NChzdHJ1Y3QgZGlyX2NvbnRleHQgKmN0eCwgY29uc3QgY2hh"
    "ciAqbmFtZSwgaW50IG5hbWxlbiwKIAkJc2l6ZW9mKHU2NCkpOwogCWludCBwcmV2X3JlY2xlbjsKIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX1BB"
    "VEgKKwlpZiAobGlrZWx5KGN1cnJlbnQtPnN1c2ZzX3Rhc2tfc3RhdGUgJiBUQVNLX1NUUlVDVF9OT05fUk9PVF9VU0VSX0FQUF9QUk9DKSAmJiBzdXNmc19z"
    "dXNfaW5vX2Zvcl9maWxsZGlyNjQoaW5vKSkgeworCQlyZXR1cm4gMDsKKwl9CisjZW5kaWYKIAlidWYtPmVycm9yID0gdmVyaWZ5X2RpcmVudF9uYW1lKG5h"
    "bWUsIG5hbWxlbik7CiAJaWYgKHVubGlrZWx5KGJ1Zi0+ZXJyb3IpKQogCQlyZXR1cm4gYnVmLT5lcnJvcjsKQEAgLTQyMCw2ICs0MzYsMTEgQEAgc3RhdGlj"
    "IGludCBjb21wYXRfZmlsbG9uZWRpcihzdHJ1Y3QgZGlyX2NvbnRleHQgKmN0eCwgY29uc3QgY2hhciAqbmFtZSwKIAogCWlmIChidWYtPnJlc3VsdCkKIAkJ"
    "cmV0dXJuIC1FSU5WQUw7CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfUEFUSAorCWlmIChsaWtlbHkoY3VycmVudC0+c3VzZnNfdGFza19zdGF0ZSAm"
    "IFRBU0tfU1RSVUNUX05PTl9ST09UX1VTRVJfQVBQX1BST0MpICYmIHN1c2ZzX3N1c19pbm9fZm9yX2ZpbGxkaXI2NChpbm8pKSB7CisJCXJldHVybiAwOwor"
    "CX0KKyNlbmRpZgogCWJ1Zi0+cmVzdWx0ID0gdmVyaWZ5X2RpcmVudF9uYW1lKG5hbWUsIG5hbWxlbik7CiAJaWYgKGJ1Zi0+cmVzdWx0IDwgMCkKIAkJcmV0"
    "dXJuIGJ1Zi0+cmVzdWx0OwpAQCAtNDk1LDYgKzUxNiwxMSBAQCBzdGF0aWMgaW50IGNvbXBhdF9maWxsZGlyKHN0cnVjdCBkaXJfY29udGV4dCAqY3R4LCBj"
    "b25zdCBjaGFyICpuYW1lLCBpbnQgbmFtbGVuLAogCWJ1Zi0+ZXJyb3IgPSAtRUlOVkFMOwkvKiBvbmx5IHVzZWQgaWYgd2UgZmFpbC4uICovCiAJaWYgKHJl"
    "Y2xlbiA+IGJ1Zi0+Y291bnQpCiAJCXJldHVybiAtRUlOVkFMOworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX1BBVEgKKwlpZiAobGlrZWx5KGN1cnJl"
    "bnQtPnN1c2ZzX3Rhc2tfc3RhdGUgJiBUQVNLX1NUUlVDVF9OT05fUk9PVF9VU0VSX0FQUF9QUk9DKSAmJiBzdXNmc19zdXNfaW5vX2Zvcl9maWxsZGlyNjQo"
    "aW5vKSkgeworCQlyZXR1cm4gMDsKKwl9CisjZW5kaWYKIAlkX2lubyA9IGlubzsKIAlpZiAoc2l6ZW9mKGRfaW5vKSA8IHNpemVvZihpbm8pICYmIGRfaW5v"
    "ICE9IGlubykgewogCQlidWYtPmVycm9yID0gLUVPVkVSRkxPVzsKZGlmZiAtLWdpdCBhL2ZzL3N0YXQuYyBiL2ZzL3N0YXQuYwppbmRleCAyNjhjOWViODk2"
    "NTYuLmE2MGYyMmRlYWUxNSAxMDA2NDQKLS0tIGEvZnMvc3RhdC5jCisrKyBiL2ZzL3N0YXQuYwpAQCAtMTcsMTAgKzE3LDE3IEBACiAjaW5jbHVkZSA8bGlu"
    "dXgvc3lzY2FsbHMuaD4KICNpbmNsdWRlIDxsaW51eC9wYWdlbWFwLmg+CiAjaW5jbHVkZSA8bGludXgvY29tcGF0Lmg+CisjaWYgZGVmaW5lZChDT05GSUdf"
    "S1NVX1NVU0ZTX1NVU19LU1RBVCkgfHwgZGVmaW5lZChDT05GSUdfS1NVX1NVU0ZTX1NVU19NT1VOVCkKKyNpbmNsdWRlIDxsaW51eC9zdXNmc19kZWYuaD4K"
    "KyNlbmRpZgogCiAjaW5jbHVkZSA8bGludXgvdWFjY2Vzcy5oPgogI2luY2x1ZGUgPGFzbS91bmlzdGQuaD4KIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNf"
    "U1VTX0tTVEFUCitleHRlcm4gdm9pZCBzdXNmc19zdXNfaW5vX2Zvcl9nZW5lcmljX2ZpbGxhdHRyKHVuc2lnbmVkIGxvbmcgaW5vLCBzdHJ1Y3Qga3N0YXQg"
    "KnN0YXQpOworI2VuZGlmCisKIC8qKgogICogZ2VuZXJpY19maWxsYXR0ciAtIEZpbGwgaW4gdGhlIGJhc2ljIGF0dHJpYnV0ZXMgZnJvbSB0aGUgaW5vZGUg"
    "c3RydWN0CiAgKiBAaW5vZGU6IElub2RlIHRvIHVzZSBhcyB0aGUgc291cmNlCkBAIC0zMiw2ICszOSwxNyBAQAogICovCiB2b2lkIGdlbmVyaWNfZmlsbGF0"
    "dHIoc3RydWN0IGlub2RlICppbm9kZSwgc3RydWN0IGtzdGF0ICpzdGF0KQogeworI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX0tTVEFUCisJaWYgKGxp"
    "a2VseShjdXJyZW50LT5zdXNmc190YXNrX3N0YXRlICYgVEFTS19TVFJVQ1RfTk9OX1JPT1RfVVNFUl9BUFBfUFJPQykgJiYKKwkJCXVubGlrZWx5KGlub2Rl"
    "LT5pX3N0YXRlICYgSU5PREVfU1RBVEVfU1VTX0tTVEFUKSkgeworCQlzdXNmc19zdXNfaW5vX2Zvcl9nZW5lcmljX2ZpbGxhdHRyKGlub2RlLT5pX2lubywg"
    "c3RhdCk7CisJCXN0YXQtPm1vZGUgPSBpbm9kZS0+aV9tb2RlOworCQlzdGF0LT5yZGV2ID0gaW5vZGUtPmlfcmRldjsKKwkJc3RhdC0+dWlkID0gaW5vZGUt"
    "PmlfdWlkOworCQlzdGF0LT5naWQgPSBpbm9kZS0+aV9naWQ7CisJCXJldHVybjsKKwl9CisjZW5kaWYKIAlzdGF0LT5kZXYgPSBpbm9kZS0+aV9zYi0+c19k"
    "ZXY7CiAJc3RhdC0+aW5vID0gaW5vZGUtPmlfaW5vOwogCXN0YXQtPm1vZGUgPSBpbm9kZS0+aV9tb2RlOwpAQCAtMTY1LDYgKzE4MywxMiBAQCBFWFBPUlRf"
    "U1lNQk9MKHZmc19zdGF0eF9mZCk7CiAgKgogICogMCB3aWxsIGJlIHJldHVybmVkIG9uIHN1Y2Nlc3MsIGFuZCBhIC12ZSBlcnJvciBjb2RlIGlmIHVuc3Vj"
    "Y2Vzc2Z1bC4KICAqLworCisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfU1UKK2V4dGVybiBib29sIHN1c2ZzX2lzX3N1c19zdV9ob29rc19lbmFibGVk"
    "IF9fcmVhZF9tb3N0bHk7CitleHRlcm4gaW50IGtzdV9oYW5kbGVfc3RhdChpbnQgKmRmZCwgY29uc3QgY2hhciBfX3VzZXIgKipmaWxlbmFtZV91c2VyLCBp"
    "bnQgKmZsYWdzKTsKKyNlbmRpZgorCiBpbnQgdmZzX3N0YXR4KGludCBkZmQsIGNvbnN0IGNoYXIgX191c2VyICpmaWxlbmFtZSwgaW50IGZsYWdzLAogCSAg"
    "ICAgIHN0cnVjdCBrc3RhdCAqc3RhdCwgdTMyIHJlcXVlc3RfbWFzaykKIHsKQEAgLTE3Miw2ICsxOTYsMTIgQEAgaW50IHZmc19zdGF0eChpbnQgZGZkLCBj"
    "b25zdCBjaGFyIF9fdXNlciAqZmlsZW5hbWUsIGludCBmbGFncywKIAlpbnQgZXJyb3IgPSAtRUlOVkFMOwogCXVuc2lnbmVkIGludCBsb29rdXBfZmxhZ3Mg"
    "PSBMT09LVVBfRk9MTE9XIHwgTE9PS1VQX0FVVE9NT1VOVDsKIAorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VTX1NVCisJaWYgKHN1c2ZzX2lzX3N1c19z"
    "dV9ob29rc19lbmFibGVkKSB7CisJCWtzdV9oYW5kbGVfc3RhdCgmZGZkLCAmZmlsZW5hbWUsICZmbGFncyk7CisJfQorI2VuZGlmCisKIAlpZiAoKGZsYWdz"
    "ICYgfihBVF9TWU1MSU5LX05PRk9MTE9XIHwgQVRfTk9fQVVUT01PVU5UIHwKIAkJICAgICAgIEFUX0VNUFRZX1BBVEggfCBLU1RBVF9RVUVSWV9GTEFHUykp"
    "ICE9IDApCiAJCXJldHVybiAtRUlOVkFMOwpkaWZmIC0tZ2l0IGEvZnMvc3RhdGZzLmMgYi9mcy9zdGF0ZnMuYwppbmRleCA0OTYwYzY5Y2M0N2MuLjFlOGM4"
    "Mjg0ZWU4NiAxMDA2NDQKLS0tIGEvZnMvc3RhdGZzLmMKKysrIGIvZnMvc3RhdGZzLmMKQEAgLTksNiArOSwxMCBAQAogI2luY2x1ZGUgPGxpbnV4L3NlY3Vy"
    "aXR5Lmg+CiAjaW5jbHVkZSA8bGludXgvdWFjY2Vzcy5oPgogI2luY2x1ZGUgPGxpbnV4L2NvbXBhdC5oPgorI2lmZGVmIENPTkZJR19LU1VfU1VTRlNfU1VT"
    "X01PVU5UCisjaW5jbHVkZSA8bGludXgvc3VzZnNfZGVmLmg+CisjaW5jbHVkZSAibW91bnQuaCIKKyNlbmRpZgogI2luY2x1ZGUgImludGVybmFsLmgiCiAK"
    "IHN0YXRpYyBpbnQgZmxhZ3NfYnlfbW50KGludCBtbnRfZmxhZ3MpCkBAIC04NCwxMSArODgsMjMgQEAgRVhQT1JUX1NZTUJPTCh2ZnNfZ2V0X2ZzaWQpOwog"
    "aW50IHZmc19zdGF0ZnMoY29uc3Qgc3RydWN0IHBhdGggKnBhdGgsIHN0cnVjdCBrc3RhdGZzICpidWYpCiB7CiAJaW50IGVycm9yOworI2lmZGVmIENPTkZJ"
    "R19LU1VfU1VTRlNfU1VTX01PVU5UCisJc3RydWN0IG1vdW50ICptbnQ7CiAKKwltbnQgPSByZWFsX21vdW50KHBhdGgtPm1udCk7CisJaWYgKGxpa2VseShj"
    "dXJyZW50LT5zdXNmc190YXNrX3N0YXRlICYgVEFTS19TVFJVQ1RfTk9OX1JPT1RfVVNFUl9BUFBfUFJPQykpIHsKKwkJZm9yICg7IG1udC0+bW50X2lkID49"
    "IERFRkFVTFRfU1VTX01OVF9JRDsgbW50ID0gbW50LT5tbnRfcGFyZW50KSB7fQorCX0KKwllcnJvciA9IHN0YXRmc19ieV9kZW50cnkobW50LT5tbnQubW50"
    "X3Jvb3QsIGJ1Zik7CisJaWYgKCFlcnJvcikKKwkJYnVmLT5mX2ZsYWdzID0gY2FsY3VsYXRlX2ZfZmxhZ3MoJm1udC0+bW50KTsKKwlyZXR1cm4gZXJyb3I7"
    "CisjZWxzZQogCWVycm9yID0gc3RhdGZzX2J5X2RlbnRyeShwYXRoLT5kZW50cnksIGJ1Zik7CiAJaWYgKCFlcnJvcikKIAkJYnVmLT5mX2ZsYWdzID0gY2Fs"
    "Y3VsYXRlX2ZfZmxhZ3MocGF0aC0+bW50KTsKIAlyZXR1cm4gZXJyb3I7CisjZW5kaWYKIH0KIEVYUE9SVF9TWU1CT0wodmZzX3N0YXRmcyk7CiAKQEAgLTEw"
    "Nyw2ICsxMjMsMjIgQEAgaW50IHVzZXJfc3RhdGZzKGNvbnN0IGNoYXIgX191c2VyICpwYXRobmFtZSwgc3RydWN0IGtzdGF0ZnMgKnN0KQogCQkJZ290byBy"
    "ZXRyeTsKIAkJfQogCX0KKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19PVkVSTEFZRlMKKwkvKiAtIFdoZW4gbW91bnRpbmcgb3ZlcmxheSwgdGhlIGZf"
    "ZmxhZ3MgYXJlIHNldCB3aXRoICdybycgYW5kICdyZWxhdGltZScsCisJICogICBidXQgdGhpcyBpcyBhbiBhYm5vcm1hbCBzdGF0dXMsIGFzIHdoZW4gd2Ug"
    "aW5zcGVjdCB0aGUgb3V0cHV0IGZyb20gbW91bnRpbmZvLAorCSAqICAgd2Ugd2lsbCBmaW5kIHRoYXQgYWxsIHBhcnRpdGlvbnMgc2V0IHdpdGggJ3JvJyB3"
    "aWxsIGhhdmUgJ25vYXRpbWUnIHNldCBhcyB3ZWxsLgorCSAqIC0gQnV0IHdoYXQgaXMgc3RyYW5nZSBoZXJlIGlzIHRoYXQgdGhlIHZmc21udCBmX2ZsYWdz"
    "IG9mIHRoZSBsb3dlc3QgbGF5ZXIgaGFzIGNvcnJlbnQgZl9mbGFncyBzZXQsCisJICogICBhbmQgc3RpbGwgaXQgaXMgYWx3YXlzIGNoYW5nZWQgdG8gJ3Jl"
    "bGF0aW1lJyBpbnN0ZWFkIG9mICdub2F0aW1lJyBmb3IgdGhlIGZpbmFsIHJlc3VsdCwKKwkgKiAgIEkgY2FuJ3QgdGhpbmsgb2YgYW55IG90aGVyIHJlYXNv"
    "biB0byBleHBsYWluIGFib3V0IHRoaXMsIG1heWJlIHRoZSBmX2ZsYWdzIGlzIHNldCBieSBpdHMgb3duCisJICogICBmaWxlc3lzdGVtIGltcGxlbWVudGF0"
    "aW9uIGJ1dCBub3QgdGhlIG9uZSBmcm9tIG92ZXJsYXlmcy4KKwkgKiAtIEFueXdheSB3ZSBqdXN0IGNhbm5vdCB1c2UgdGhlIHJldHJpZXZlZCBmX2ZsYWdz"
    "IGZyb20gb3ZsX2dldGF0dHIoKSBvZiBvdmVybGF5ZnMsCisJICogICB3ZSBuZWVkIHRvIHJ1biBvbmUgbW9yZSBjaGVjayBmb3IgdXNlcl9zdGF0ZnMoKSBh"
    "bmQgZmRfc3RhdGZzKCkgYnkgb3Vyc2VsdmVzLgorCSAqLworCWlmICh1bmxpa2VseSgoc3QtPmZfZmxhZ3MgJiBTVF9SRE9OTFkpICYmIChzdC0+Zl9mbGFn"
    "cyAmIFNUX1JFTEFUSU1FKSkpIHsKKwkJc3QtPmZfZmxhZ3MgJj0gflNUX1JFTEFUSU1FOworCQlzdC0+Zl9mbGFncyB8PSBTVF9OT0FUSU1FOworCX0KKyNl"
    "bmRpZgogCXJldHVybiBlcnJvcjsKIH0KIApAQCAtMTE4LDYgKzE1MCwxMiBAQCBpbnQgZmRfc3RhdGZzKGludCBmZCwgc3RydWN0IGtzdGF0ZnMgKnN0KQog"
    "CQllcnJvciA9IHZmc19zdGF0ZnMoJmYuZmlsZS0+Zl9wYXRoLCBzdCk7CiAJCWZkcHV0KGYpOwogCX0KKyNpZmRlZiBDT05GSUdfS1NVX1NVU0ZTX1NVU19P"
    "VkVSTEFZRlMKKwlpZiAodW5saWtlbHkoKHN0LT5mX2ZsYWdzICYgU1RfUkRPTkxZKSAmJiAoc3QtPmZfZmxhZ3MgJiBTVF9SRUxBVElNRSkpKSB7CisJCXN0"
    "LT5mX2ZsYWdzICY9IH5TVF9SRUxBVElNRTsKKwkJc3QtPmZfZmxhZ3MgfD0gU1RfTk9BVElNRTsKKwl9CisjZW5kaWYKIAlyZXR1cm4gZXJyb3I7CiB9CiAK"
    "QEAgLTIzOCw2ICsyNzYsMTEgQEAgc3RhdGljIGludCB2ZnNfdXN0YXQoZGV2X3QgZGV2LCBzdHJ1Y3Qga3N0YXRmcyAqc2J1ZikKIAlpZiAoIXMpCiAJCXJl"
    "dHVybiAtRUlOVkFMOwogCisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19TVVNfTU9VTlQKKwlpZiAodW5saWtlbHkocy0+c19yb290LT5kX2lub2RlLT5pX3N0"
    "YXRlICYgSU5PREVfU1RBVEVfU1VTX01PVU5UKSkgeworCQlyZXR1cm4gLUVJTlZBTDsKKwl9CisjZW5kaWYKIAllcnIgPSBzdGF0ZnNfYnlfZGVudHJ5KHMt"
    "PnNfcm9vdCwgc2J1Zik7CiAJZHJvcF9zdXBlcihzKTsKIAlyZXR1cm4gZXJyOwpkaWZmIC0tZ2l0IGEvaW5jbHVkZS9saW51eC9tb3VudC5oIGIvaW5jbHVk"
    "ZS9saW51eC9tb3VudC5oCmluZGV4IGNhMzg4Y2M0NDY4Ni4uNjZmMTkwNjdjZjkzIDEwMDY0NAotLS0gYS9pbmNsdWRlL2xpbnV4L21vdW50LmgKKysrIGIv"
    "aW5jbHVkZS9saW51eC9tb3VudC5oCkBAIC03Myw3ICs3MywxMSBAQCBzdHJ1Y3QgdmZzbW91bnQgewogCUFORFJPSURfS0FCSV9SRVNFUlZFKDEpOwogCUFO"
    "RFJPSURfS0FCSV9SRVNFUlZFKDIpOwogCUFORFJPSURfS0FCSV9SRVNFUlZFKDMpOworI2lmZGVmIENPTkZJR19LU1VfU1VTRlMKKwlBTkRST0lEX0tBQklf"
    "VVNFKDQsIHU2NCBzdXNmc19tbnRfaWRfYmFja3VwKTsKKyNlbHNlCiAJQU5EUk9JRF9LQUJJX1JFU0VSVkUoNCk7CisjZW5kaWYKIH0gX19yYW5kb21pemVf"
    "bGF5b3V0OwogCiBzdHJ1Y3QgZmlsZTsgLyogZm9yd2FyZCBkZWMgKi8KZGlmZiAtLWdpdCBhL2luY2x1ZGUvbGludXgvc2NoZWQuaCBiL2luY2x1ZGUvbGlu"
    "dXgvc2NoZWQuaAppbmRleCAzYjZjZDMxMjk4NmIuLjFlNTMyMGRjNjAxYyAxMDA2NDQKLS0tIGEvaW5jbHVkZS9saW51eC9zY2hlZC5oCisrKyBiL2luY2x1"
    "ZGUvbGludXgvc2NoZWQuaApAQCAtMTMwNyw4ICsxMzA3LDE2IEBAIHN0cnVjdCB0YXNrX3N0cnVjdCB7CiAJQU5EUk9JRF9LQUJJX1JFU0VSVkUoNCk7CiAJ"
    "QU5EUk9JRF9LQUJJX1JFU0VSVkUoNSk7CiAJQU5EUk9JRF9LQUJJX1JFU0VSVkUoNik7CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGUworCUFORFJPSURfS0FC"
    "SV9VU0UoNywgdTY0IHN1c2ZzX3Rhc2tfc3RhdGUpOworI2Vsc2UKIAlBTkRST0lEX0tBQklfUkVTRVJWRSg3KTsKKyNlbmRpZgorI2lmZGVmIENPTkZJR19L"
    "U1VfU1VTRlMKKwlBTkRST0lEX0tBQklfVVNFKDgsIHU2NCBzdXNmc19sYXN0X2Zha2VfbW50X2lkKTsKKyNlbHNlCiAJQU5EUk9JRF9LQUJJX1JFU0VSVkUo"
    "OCk7CisjZW5kaWYKIAogCS8qCiAJICogTmV3IGZpZWxkcyBmb3IgdGFza19zdHJ1Y3Qgc2hvdWxkIGJlIGFkZGVkIGFib3ZlIGhlcmUsIHNvIHRoYXQKZGlm"
    "ZiAtLWdpdCBhL2tlcm5lbC9rYWxsc3ltcy5jIGIva2VybmVsL2thbGxzeW1zLmMKaW5kZXggMTRkZTBjN2JmNzU2Li5hNGM1NjM5ODBhZjQgMTAwNjQ0Ci0t"
    "LSBhL2tlcm5lbC9rYWxsc3ltcy5jCisrKyBiL2tlcm5lbC9rYWxsc3ltcy5jCkBAIC02NTcsOCArNjU3LDE4IEBAIHN0YXRpYyBpbnQgc19zaG93KHN0cnVj"
    "dCBzZXFfZmlsZSAqbSwgdm9pZCAqcCkKIAkJc2VxX3ByaW50ZihtLCAiJXB4ICVjICVzXHRbJXNdXG4iLCB2YWx1ZSwKIAkJCSAgIHR5cGUsIGl0ZXItPm5h"
    "bWUsIGl0ZXItPm1vZHVsZV9uYW1lKTsKIAl9IGVsc2UKKyNpZm5kZWYgQ09ORklHX0tTVV9TVVNGU19ISURFX0tTVV9TVVNGU19TWU1CT0xTCiAJCXNlcV9w"
    "cmludGYobSwgIiVweCAlYyAlc1xuIiwgdmFsdWUsCiAJCQkgICBpdGVyLT50eXBlLCBpdGVyLT5uYW1lKTsKKyNlbHNlCisJeworCQlpZiAoc3Ryc3RyKGl0"
    "ZXItPm5hbWUsICJrc3VfIikgfHwgIXN0cm5jbXAoaXRlci0+bmFtZSwgInN1c2ZzXyIsIDYpIHx8ICFzdHJuY21wKGl0ZXItPm5hbWUsICJrc3VkIiwgNCkp"
    "IHsKKwkJCXJldHVybiAwOworCQl9CisJCXNlcV9wcmludGYobSwgIiVweCAlYyAlc1xuIiwgdmFsdWUsCisJCQkgICBpdGVyLT50eXBlLCBpdGVyLT5uYW1l"
    "KTsKKwl9CisjZW5kaWYKIAlyZXR1cm4gMDsKIH0KIApkaWZmIC0tZ2l0IGEva2VybmVsL3N5cy5jIGIva2VybmVsL3N5cy5jCmluZGV4IGZhM2Y0OGE1MWFh"
    "OS4uNmY3ZjUyMzY3MzFiIDEwMDY0NAotLS0gYS9rZXJuZWwvc3lzLmMKKysrIGIva2VybmVsL3N5cy5jCkBAIC0xMjQwLDEyICsxMjQwLDE4IEBAIHN0YXRp"
    "YyBpbnQgb3ZlcnJpZGVfcmVsZWFzZShjaGFyIF9fdXNlciAqcmVsZWFzZSwgc2l6ZV90IGxlbikKIAlyZXR1cm4gcmV0OwogfQogCisjaWZkZWYgQ09ORklH"
    "X0tTVV9TVVNGU19TUE9PRl9VTkFNRQorZXh0ZXJuIHZvaWQgc3VzZnNfc3Bvb2ZfdW5hbWUoc3RydWN0IG5ld191dHNuYW1lKiB0bXApOworI2VuZGlmCiBT"
    "WVNDQUxMX0RFRklORTEobmV3dW5hbWUsIHN0cnVjdCBuZXdfdXRzbmFtZSBfX3VzZXIgKiwgbmFtZSkKIHsKIAlzdHJ1Y3QgbmV3X3V0c25hbWUgdG1wOwog"
    "CiAJZG93bl9yZWFkKCZ1dHNfc2VtKTsKIAltZW1jcHkoJnRtcCwgdXRzbmFtZSgpLCBzaXplb2YodG1wKSk7CisjaWZkZWYgQ09ORklHX0tTVV9TVVNGU19T"
    "UE9PRl9VTkFNRQorCXN1c2ZzX3Nwb29mX3VuYW1lKCZ0bXApOworI2VuZGlmCiAJdXBfcmVhZCgmdXRzX3NlbSk7CiAJaWYgKGNvcHlfdG9fdXNlcihuYW1l"
    "LCAmdG1wLCBzaXplb2YodG1wKSkpCiAJCXJldHVybiAtRUZBVUxUOwo="
)
open(pf, "wb").write(base64.b64decode("".join(b64.split())))

fs_kc = "fs/Kconfig"
s = open(fs_kc).read()
if "config KSU_SUSFS" not in s:
    s += """
config KSU_SUSFS
\tbool "KernelSU SUSFS (kernel-side experimental)"
\tdefault y
\thelp
\t  Experimental kernel-side SUSFS 1.5.5 patch for non-GKI kernels.
\t  The KSU-side integration patch is NOT applied; only kernel-side
\t  hiding hooks are compiled in.

config KSU_SUSFS_SUS_PATH
\tbool "SUSFS: sus_path"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_SUS_MOUNT
\tbool "SUSFS: sus_mount"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_SUS_KSTAT
\tbool "SUSFS: sus_kstat"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_TRY_UMOUNT
\tbool "SUSFS: try_umount"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
\tbool "SUSFS: auto add sus bind mount"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
\tbool "SUSFS: auto add sus KSU default mount"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT
\tbool "SUSFS: auto add try_umount for bind mount"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_HAS_MAGIC_MOUNT
\tbool "SUSFS: magic mount support"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
\tbool "SUSFS: hide symbols"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_SPOOF_UNAME
\tbool "SUSFS: spoof uname"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_OPEN_REDIRECT
\tbool "SUSFS: open redirect"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_SUS_OVERLAYFS
\tbool "SUSFS: sus overlayfs"
\tdepends on KSU_SUSFS
\tdefault y

config KSU_SUSFS_ENABLE_LOG
\tbool "SUSFS: logging"
\tdepends on KSU_SUSFS
\tdefault n

config KSU_SUSFS_SUS_SU
\tbool "SUSFS: sus_su (disabled: branch-link hooks)"
\tdepends on KSU_SUSFS
\tdefault n

config KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
\tbool "SUSFS: spoof cmdline/bootconfig (no file in this tree)"
\tdepends on KSU_SUSFS
\tdefault n

"""
    open(fs_kc, "w").write(s)
PY
	patch -p1 --force --fuzz=10 --no-backup-if-mismatch <"$pf" \
		|| die "SUSFS kernel patch failed"
	info "SUSFS kernel-side applied (fuzz=10; bootconfig hunk skipped; KSU-side skipped)"
	endgroup
}

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
    "LiB9ICovCiNkZWZpbmUgYWRpb3Nfc2NvcGVkX2d1YXJkKHR5cGUsIGxja18pIFwKCWZvciAoc3RydWN0IGFkaW9zX2d1YXJkX3NwaW5sb2NrX2lycXNhdmUg"
    "YWRvc19zZ3VhcmRfXyA9IFwKCQkJYWRpb3NfZ3VhcmRfc3BpbmxvY2tfaXJxc2F2ZV9pbml0KGxja18pOyBcCgkgICAgIGFkb3Nfc2d1YXJkX18ubG9jazsg"
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
    "KTsKCXVuaW9uIGFkaW9zX2luX2ZsaWdodF9ycXMgaWZyID0geyAuc2NhbGFyID0gMCB9OwoKCS8qIDUuNCBwb3J0OiByZXF1ZXN0cyB0aGF0IGJ5cGFzc2Vk"
    "IEFESU9TIChmbHVzaC9yZXF1ZXVlL3N0dWJiZWQgbWVyZ2UpCgkgKiByZWFjaCBjb21wbGV0aW9uIHdpdGggcHJpdlswXSA9PSBOVUxMLiBTa2lwIHRoZW0g"
    "aW5zdGVhZCBvZiBwYW5pY2tpbmcuICovCglpZiAodW5saWtlbHkoIXJkKSkKCQlyZXR1cm47CgoJaWYgKHJkLT5tYW5hZ2VkKSB7CgkJdW5pb24gYWRpb3Nf"
    "aW5fZmxpZ2h0X3JxcyBpZnJfdG9fc3ViID0gewoJCQkuY291bnQgICAgICAgICAgPSAxLAoJCQkudG90YWxfcHJlZF9sYXQgPSByZC0+cHJlZF9sYXQsCgkJ"
    "fTsKCQlpZnIuc2NhbGFyID0gYXRvbWljNjRfc3ViX3JldHVybigKCQkJaWZyX3RvX3N1Yi5zY2FsYXIsICZhZC0+aW5fZmxpZ2h0X3Jxcy5hdG9taWMpOwoJ"
    "fQoJdTggb3B0eXBlID0gYWRpb3Nfb3B0eXBlKHJxKTsKCgl1bnNpZ25lZCBsb25nIGZsYWdzOwoJc3RydWN0IGFkaW9zX3BjcHVfY29tcGxldGlvbiAqcGM7"
    "CgoJbG9jYWxfaXJxX3NhdmUoZmxhZ3MpOwoJcGMgPSB0aGlzX2NwdV9wdHIoYWQtPnBjcHVfY29tcGxldGlvbik7CgoJaWYgKG9wdHlwZSA9PSBBRElPU19P"
    "VEhFUikgewoJCS8vIE5vbi1wb3NpdGlvbmFsIGNvbW1hbmRzIG1ha2UgdGhlIGhlYWQgcG9zaXRpb24gdW5wcmVkaWN0YWJsZS4KCQkvLyBJbnZhbGlkYXRl"
    "IG91ciBrbm93bGVkZ2Ugb2YgdGhlIGxhc3QgY29tcGxldGVkIHBvc2l0aW9uLgoJCWlmIChhZC0+aXNfcm90YXRpb25hbCkKCQkJcGMtPmxhc3RfY29tcGxl"
    "dGVkX3BvcyA9IDA7CgkJbG9jYWxfaXJxX3Jlc3RvcmUoZmxhZ3MpOwoJCXJldHVybjsKCX0KCgl1NjQgbGN0ID0gcGMtPmxhc3RfY29tcGxldGVkX3RpbWUg"
    "PzogcnEtPmlvX3N0YXJ0X3RpbWVfbnM7CglwYy0+bGFzdF9jb21wbGV0ZWRfdGltZSA9IChpZnIuY291bnQpID8gbm93IDogMDsKCglpZiAoIXJxLT5pb19z"
    "dGFydF90aW1lX25zIHx8ICFyZC0+YmxvY2tfc2l6ZSB8fCB1bmxpa2VseShub3cgPCBsY3QpKSB7CgkJbG9jYWxfaXJxX3Jlc3RvcmUoZmxhZ3MpOwoJCXJl"
    "dHVybjsKCX0KCgl1NjQgbGF0ZW5jeSA9IG5vdyAtIGxjdDsKCgl1MzIgd2VpZ2h0ID0gMTsKCWlmIChhZC0+aXNfcm90YXRpb25hbCkgewoJCXNlY3Rvcl90"
    "IGN1cnJlbnRfcG9zID0gYmxrX3JxX3BvcyhycSk7CgkJLy8gT25seSBjYWxjdWxhdGUgc2VlayBkaXN0YW5jZSBpZiB3ZSBoYXZlIGEgdmFsaWQgbGFzdCBw"
    "b3NpdGlvbi4KCQlpZiAocGMtPmxhc3RfY29tcGxldGVkX3BvcyA+IDApIHsKCQkJdTY0IHNlZWtfZGlzdGFuY2UgPSBhYnMoCgkJCQkoczY0KWN1cnJlbnRf"
    "cG9zIC0gKHM2NClwYy0+bGFzdF9jb21wbGV0ZWRfcG9zKTsKCQkJaWYgKHNlZWtfZGlzdGFuY2UpCgkJCQl3ZWlnaHQgPSA2NSAtIF9fYnVpbHRpbl9jbHps"
    "bChzZWVrX2Rpc3RhbmNlKTsKCQl9CgkJLy8gVXBkYXRlIChvciByZS1zeW5jaHJvbml6ZSkgb3VyIGtub3dsZWRnZSBvZiB0aGUgaGVhZCBwb3NpdGlvbi4K"
    "CQlwYy0+bGFzdF9jb21wbGV0ZWRfcG9zID0gY3VycmVudF9wb3MgKyBibGtfcnFfc2VjdG9ycyhycSk7Cgl9CgoJbG9jYWxfaXJxX3Jlc3RvcmUoZmxhZ3Mp"
    "OwoKCWlmIChsYXRlbmN5ID4gYWQtPmxhdF9tb2RlbF9sYXRlbmN5X2xpbWl0KQoJCXJldHVybjsKCglsYXRlbmN5X21vZGVsX2lucHV0KGFkLCAmYWQtPmxh"
    "dGVuY3lfbW9kZWxbb3B0eXBlXSwKCQlyZC0+YmxvY2tfc2l6ZSwgbGF0ZW5jeSwgcmQtPnByZWRfbGF0LCB3ZWlnaHQpOwoJdGltZXJfcmVkdWNlKCZhZC0+"
    "dXBkYXRlX3RpbWVyLCBqaWZmaWVzICsgbXNlY3NfdG9famlmZmllcygxMDApKTsKfQoKLy8gQ2xlYW4gdXAgYWZ0ZXIgYSByZXF1ZXN0IGlzIGZpbmlzaGVk"
    "CnN0YXRpYyB2b2lkIGFkaW9zX2ZpbmlzaF9yZXF1ZXN0KHN0cnVjdCByZXF1ZXN0ICpycSkgewoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gcnEtPnEtPmVs"
    "ZXZhdG9yLT5lbGV2YXRvcl9kYXRhOwoKCWlmIChycS0+ZWx2LnByaXZbMF0pIHsKCQkvLyBGcmVlIGFkaW9zX3JxX2RhdGEgYmFjayB0byB0aGUgbWVtb3J5"
    "IHBvb2wKCQltZW1wb29sX2ZyZWUoZ2V0X3JxX2RhdGEocnEpLCBhZC0+cnFfZGF0YV9wb29sKTsKCQlycS0+ZWx2LnByaXZbMF0gPSBOVUxMOwoJfQp9Cgov"
    "LyBDaGVjayBpZiB0aGVyZSBhcmUgYW55IHJlcXVlc3RzIGF2YWlsYWJsZSBmb3IgZGlzcGF0Y2gKc3RhdGljIGJvb2wgYWRpb3NfaGFzX3dvcmsoc3RydWN0"
    "IGJsa19tcV9od19jdHggKmhjdHgpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGhjdHgtPnF1ZXVlLT5lbGV2YXRvci0+ZWxldmF0b3JfZGF0YTsKCgly"
    "ZXR1cm4gYXRvbWljX3JlYWQoJmFkLT5zdGF0ZSkgIT0gMDsKfQoKLy8gSW5pdGlhbGl6ZSB0aGUgc2NoZWR1bGVyLXNwZWNpZmljIGRhdGEgZm9yIGEgaGFy"
    "ZHdhcmUgcXVldWUKc3RhdGljIGludCBhZGlvc19pbml0X2hjdHgoc3RydWN0IGJsa19tcV9od19jdHggKmhjdHgsIHVuc2lnbmVkIGludCBoY3R4X2lkeCkg"
    "ewoJYWRpb3NfZGVwdGhfdXBkYXRlZChoY3R4KTsKCXJldHVybiAwOwp9CgovLyBJbml0aWFsaXplIHRoZSBzY2hlZHVsZXItc3BlY2lmaWMgZGF0YSB3aGVu"
    "IGluaXRpYWxpemluZyB0aGUgcmVxdWVzdCBxdWV1ZQpzdGF0aWMgaW50IGFkaW9zX2luaXRfc2NoZWQoc3RydWN0IHJlcXVlc3RfcXVldWUgKnEsIHN0cnVj"
    "dCBlbGV2YXRvcl90eXBlICplKSB7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQ7CglzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmVxOwoJaW50IHJldCA9IC1FTk9N"
    "RU07Cgl1OCBvcHR5cGUgPSAwOwoKCWVxID0gZWxldmF0b3JfYWxsb2MocSwgZSk7CglpZiAoIWVxKSB7CgkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGFs"
    "bG9jYXRlIHRoZSBlbGV2YXRvclxuIik7CgkJcmV0dXJuIHJldDsKCX0KCglhZCA9IGt6YWxsb2Nfbm9kZShzaXplb2YoKmFkKSwgR0ZQX0tFUk5FTCwgcS0+"
    "bm9kZSk7CglpZiAoIWFkKSB7CgkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGNyZWF0ZSBhZGlvc19kYXRhXG4iKTsKCQlnb3RvIHB1dF9lcTsKCX0KCgkv"
    "LyBDcmVhdGUgYSBtZW1vcnkgcG9vbCBmb3IgYWRpb3NfcnFfZGF0YQoJYWQtPnJxX2RhdGFfY2FjaGUgPSBrbWVtX2NhY2hlX2NyZWF0ZSgiYWRpb3NfcnFf"
    "ZGF0YSIsCgkJCQkJCXNpemVvZihzdHJ1Y3QgYWRpb3NfcnFfZGF0YSksCgkJCQkJCTAsIFNMQUJfSFdDQUNIRV9BTElHTiwgTlVMTCk7CglpZiAoIWFkLT5y"
    "cV9kYXRhX2NhY2hlKSB7CgkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGNyZWF0ZSBycV9kYXRhX2NhY2hlXG4iKTsKCQlnb3RvIGZyZWVfYWQ7Cgl9CgoJ"
    "YWQtPnJxX2RhdGFfcG9vbCA9IG1lbXBvb2xfY3JlYXRlX3NsYWJfcG9vbCgKCQkJCQkJcS0+bnJfcmVxdWVzdHMsIGFkLT5ycV9kYXRhX2NhY2hlKTsKCWlm"
    "ICghYWQtPnJxX2RhdGFfcG9vbCkgewoJCXByX2VycigiYWRpb3M6IEZhaWxlZCB0byBjcmVhdGUgcnFfZGF0YV9wb29sXG4iKTsKCQlnb3RvIGRlc3Ryb3lf"
    "cnFfZGF0YV9jYWNoZTsKCX0KCgkvKiBDcmVhdGUgYSBtZW1vcnkgcG9vbCBmb3IgZGxfZ3JvdXAgKi8KCWFkLT5kbF9ncm91cF9wb29sID0ga21lbV9jYWNo"
    "ZV9jcmVhdGUoImRsX2dyb3VwX3Bvb2wiLAoJCQkJCQlzaXplb2Yoc3RydWN0IGRsX2dyb3VwKSwKCQkJCQkJMCwgU0xBQl9IV0NBQ0hFX0FMSUdOLCBOVUxM"
    "KTsKCWlmICghYWQtPmRsX2dyb3VwX3Bvb2wpIHsKCQlwcl9lcnIoImFkaW9zOiBGYWlsZWQgdG8gY3JlYXRlIGRsX2dyb3VwX3Bvb2xcbiIpOwoJCWdvdG8g"
    "ZGVzdHJveV9ycV9kYXRhX3Bvb2w7Cgl9CgoJZm9yIChpbnQgaSA9IDA7IGkgPCBBRElPU19QUV9MRVZFTFM7IGkrKykKCQlJTklUX0xJU1RfSEVBRCgmYWQt"
    "PnByaW9fcXVldWVbaV0pOwoKCWZvciAodTggaiA9IDA7IGogPCBBRElPU19ETF9UWVBFUzsgaisrKSB7CgkJYWQtPmRsX3RyZWVbal0gPSBSQl9ST09UX0NB"
    "Q0hFRDsKCQlhZC0+ZGxfcHJpb1tqXSA9IGRlZmF1bHRfZGxfcHJpb1tqXTsKCX0KCWFkLT5kbF9iaWFzID0gMDsKCglmb3IgKHU4IHBhZ2UgPSAwOyBwYWdl"
    "IDwgQURJT1NfQlFfUEFHRVM7IHBhZ2UrKykKCQlmb3IgKG9wdHlwZSA9IDA7IG9wdHlwZSA8IEFESU9TX09QVFlQRVM7IG9wdHlwZSsrKQoJCQlJTklUX0xJ"
    "U1RfSEVBRCgmYWQtPmJhdGNoX3F1ZXVlW3BhZ2VdW29wdHlwZV0pOwoKCWFkLT5hZ2dyX2J1Y2tldHMgPSBremFsbG9jKHNpemVvZigqYWQtPmFnZ3JfYnVj"
    "a2V0cyksIEdGUF9LRVJORUwpOwoJaWYgKCFhZC0+YWdncl9idWNrZXRzKSB7CgkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGFsbG9jYXRlIGFnZ3JlZ2F0"
    "aW9uIGJ1Y2tldHNcbiIpOwoJCWdvdG8gZGVzdHJveV9kbF9ncm91cF9wb29sOwoJfQoKCWFkLT5wY3B1X2NvbXBsZXRpb24gPSBhbGxvY19wZXJjcHUoc3Ry"
    "dWN0IGFkaW9zX3BjcHVfY29tcGxldGlvbik7CglpZiAoIWFkLT5wY3B1X2NvbXBsZXRpb24pIHsKCQlwcl9lcnIoImFkaW9zOiBGYWlsZWQgdG8gYWxsb2Nh"
    "dGUgcGVyLUNQVSBjb21wbGV0aW9uIGRhdGFcbiIpOwoJCWdvdG8gZnJlZV9hZ2dyX2J1Y2tldHM7Cgl9CgoJZm9yIChvcHR5cGUgPSAwOyBvcHR5cGUgPCBB"
    "RElPU19PUFRZUEVTOyBvcHR5cGUrKykgewoJCXN0cnVjdCBsYXRlbmN5X21vZGVsICptb2RlbCA9ICZhZC0+bGF0ZW5jeV9tb2RlbFtvcHR5cGVdOwoJCXN0"
    "cnVjdCBsYXRlbmN5X21vZGVsX3BhcmFtcyAqcGFyYW1zOwoKCQlzcGluX2xvY2tfaW5pdCgmbW9kZWwtPnVwZGF0ZV9sb2NrKTsKCQlwYXJhbXMgPSBremFs"
    "bG9jKHNpemVvZigqcGFyYW1zKSwgR0ZQX0tFUk5FTCk7CgkJaWYgKCFwYXJhbXMpIHsKCQkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGFsbG9jYXRlIGxh"
    "dGVuY3lfbW9kZWxfcGFyYW1zXG4iKTsKCQkJZ290byBmcmVlX2J1Y2tldHM7CgkJfQoJCXBhcmFtcy0+bGFzdF91cGRhdGVfamlmZmllcyA9IGppZmZpZXM7"
    "CgkJUkNVX0lOSVRfUE9JTlRFUihtb2RlbC0+cGFyYW1zLCBwYXJhbXMpOwoKCQltb2RlbC0+cGNwdV9idWNrZXRzID0gYWxsb2NfcGVyY3B1KHN0cnVjdCBs"
    "bV9idWNrZXRzKTsKCQlpZiAoIW1vZGVsLT5wY3B1X2J1Y2tldHMpIHsKCQkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGFsbG9jYXRlIHBlci1DUFUgYnVj"
    "a2V0c1xuIik7CgkJCWtmcmVlKHBhcmFtcyk7CgkJCWdvdG8gZnJlZV9idWNrZXRzOwoJCX0KCgkJbW9kZWwtPnBjcHVfc25hcHNob3QgPSBhbGxvY19wZXJj"
    "cHUoc3RydWN0IGxtX2J1Y2tldHMpOwoJCWlmICghbW9kZWwtPnBjcHVfc25hcHNob3QpIHsKCQkJcHJfZXJyKCJhZGlvczogRmFpbGVkIHRvIGFsbG9jYXRl"
    "IHBlci1DUFUgc25hcHNob3RcbiIpOwoJCQlmcmVlX3BlcmNwdShtb2RlbC0+cGNwdV9idWNrZXRzKTsKCQkJa2ZyZWUocGFyYW1zKTsKCQkJZ290byBmcmVl"
    "X2J1Y2tldHM7CgkJfQoKCQltb2RlbC0+bG1fc2hyaW5rX2F0X2tyZXFzICA9IGRlZmF1bHRfbG1fc2hyaW5rX2F0X2tyZXFzOwoJCW1vZGVsLT5sbV9zaHJp"
    "bmtfYXRfZ2J5dGVzID0gZGVmYXVsdF9sbV9zaHJpbmtfYXRfZ2J5dGVzOwoJCW1vZGVsLT5sbV9zaHJpbmtfcmVzaXN0ICAgID0gZGVmYXVsdF9sbV9zaHJp"
    "bmtfcmVzaXN0OwoJfQoKCWZvciAob3B0eXBlID0gMDsgb3B0eXBlIDwgQURJT1NfT1BUWVBFUzsgb3B0eXBlKyspIHsKCQlhZC0+bGF0ZW5jeV90YXJnZXRb"
    "b3B0eXBlXSA9IGRlZmF1bHRfbGF0ZW5jeV90YXJnZXRbb3B0eXBlXTsKCQlhZC0+YmF0Y2hfbGltaXRbb3B0eXBlXSA9IGRlZmF1bHRfYmF0Y2hfbGltaXRb"
    "b3B0eXBlXTsKCX0KCgllcS0+ZWxldmF0b3JfZGF0YSA9IGFkOwoKCWFkLT5pc19yb3RhdGlvbmFsID0gIWJsa19xdWV1ZV9ub25yb3QocSk7CglhZC0+Z2xv"
    "YmFsX2xhdGVuY3lfd2luZG93ID0gKGFkLT5pc19yb3RhdGlvbmFsKT8KCQlkZWZhdWx0X2dsb2JhbF9sYXRlbmN5X3dpbmRvd19yb3RhdGlvbmFsOgoJCWRl"
    "ZmF1bHRfZ2xvYmFsX2xhdGVuY3lfd2luZG93OwoJYWQtPmJxX3JlZmlsbF9iZWxvd19yYXRpbyA9IGRlZmF1bHRfYnFfcmVmaWxsX2JlbG93X3JhdGlvOwoJ"
    "YWQtPmxhdF9tb2RlbF9sYXRlbmN5X2xpbWl0ID0gZGVmYXVsdF9sYXRfbW9kZWxfbGF0ZW5jeV9saW1pdDsKCWFkLT5iYXRjaF9vcmRlciA9IGRlZmF1bHRf"
    "YmF0Y2hfb3JkZXI7CglhZC0+Y29tcGxpYW5jZV9mbGFncyA9IGRlZmF1bHRfY29tcGxpYW5jZV9mbGFnczsKCglhZC0+bW9kZWxzX3N0YWJsZSA9IGZhbHNl"
    "OwoKCWF0b21pY19zZXQoJmFkLT5zdGF0ZSwgMCk7CgoJc3Bpbl9sb2NrX2luaXQoJmFkLT5sb2NrKTsKCXNwaW5fbG9ja19pbml0KCZhZC0+cHFfbG9jayk7"
    "CglzcGluX2xvY2tfaW5pdCgmYWQtPmJxX2xvY2spOwoKCXRpbWVyX3NldHVwKCZhZC0+dXBkYXRlX3RpbWVyLCB1cGRhdGVfdGltZXJfY2FsbGJhY2ssIDAp"
    "OwoKCS8qIFdlIGRpc3BhdGNoIGZyb20gcmVxdWVzdCBxdWV1ZSB3aWRlIGluc3RlYWQgb2YgaHcgcXVldWUgKi8KCglhZC0+cXVldWUgPSBxOwoJYmxrX3N0"
    "YXRfZW5hYmxlX2FjY291bnRpbmcocSk7CgoJcS0+ZWxldmF0b3IgPSBlcTsKCXJldHVybiAwOwoKZnJlZV9idWNrZXRzOgoJcHJfZXJyKCJhZGlvczogRmFp"
    "bGVkIHRvIGFsbG9jYXRlIHBlci1jcHUgYnVja2V0c1xuIik7Cgl3aGlsZSAob3B0eXBlLS0gPiAwKSB7CgkJc3RydWN0IGxhdGVuY3lfbW9kZWwgKnByZXZf"
    "bW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBlXTsKCQlrZnJlZShyY3VfYWNjZXNzX3BvaW50ZXIocHJldl9tb2RlbC0+cGFyYW1zKSk7CgkJZnJl"
    "ZV9wZXJjcHUocHJldl9tb2RlbC0+cGNwdV9zbmFwc2hvdCk7CgkJZnJlZV9wZXJjcHUocHJldl9tb2RlbC0+cGNwdV9idWNrZXRzKTsKCX0KCWZyZWVfcGVy"
    "Y3B1KGFkLT5wY3B1X2NvbXBsZXRpb24pOwpmcmVlX2FnZ3JfYnVja2V0czoKCWtmcmVlKGFkLT5hZ2dyX2J1Y2tldHMpOwpkZXN0cm95X2RsX2dyb3VwX3Bv"
    "b2w6CglrbWVtX2NhY2hlX2Rlc3Ryb3koYWQtPmRsX2dyb3VwX3Bvb2wpOwpkZXN0cm95X3JxX2RhdGFfcG9vbDoKCW1lbXBvb2xfZGVzdHJveShhZC0+cnFf"
    "ZGF0YV9wb29sKTsKZGVzdHJveV9ycV9kYXRhX2NhY2hlOgoJa21lbV9jYWNoZV9kZXN0cm95KGFkLT5ycV9kYXRhX2NhY2hlKTsKZnJlZV9hZDoKCWtmcmVl"
    "KGFkKTsKcHV0X2VxOgoJa29iamVjdF9wdXQoJmVxLT5rb2JqKTsKCXJldHVybiByZXQ7Cn0KCi8vIENsZWFuIHVwIGFuZCBmcmVlIHJlc291cmNlcyB3aGVu"
    "IGV4aXRpbmcgdGhlIHNjaGVkdWxlcgpzdGF0aWMgdm9pZCBhZGlvc19leGl0X3NjaGVkKHN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSkgewoJc3RydWN0IGFk"
    "aW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsKCglkZWxfdGltZXJfc3luYygmYWQtPnVwZGF0ZV90aW1lcik7CgoJZm9yIChpbnQgaSA9IDA7IGkg"
    "PCAyOyBpKyspCgkJV0FSTl9PTl9PTkNFKCFsaXN0X2VtcHR5KCZhZC0+cHJpb19xdWV1ZVtpXSkpOwoKCWZvciAodTggaiA9IDA7IGogPCBBRElPU19PUFRZ"
    "UEVTOyBqKyspIHsKCQlzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbal07CgkJc3RydWN0IGxhdGVuY3lfbW9kZWxf"
    "cGFyYW1zICpwYXJhbXMgPSByY3VfYWNjZXNzX3BvaW50ZXIobW9kZWwtPnBhcmFtcyk7CgoJCVJDVV9JTklUX1BPSU5URVIobW9kZWwtPnBhcmFtcywgTlVM"
    "TCk7CgkJa2ZyZWVfcmN1KHBhcmFtcywgcmN1KTsKCgkJZnJlZV9wZXJjcHUobW9kZWwtPnBjcHVfc25hcHNob3QpOwoJCWZyZWVfcGVyY3B1KG1vZGVsLT5w"
    "Y3B1X2J1Y2tldHMpOwoJfQoKCXN5bmNocm9uaXplX3JjdSgpOwoKCWZyZWVfcGVyY3B1KGFkLT5wY3B1X2NvbXBsZXRpb24pOwoJa2ZyZWUoYWQtPmFnZ3Jf"
    "YnVja2V0cyk7CgoJbWVtcG9vbF9kZXN0cm95KGFkLT5ycV9kYXRhX3Bvb2wpOwoJa21lbV9jYWNoZV9kZXN0cm95KGFkLT5ycV9kYXRhX2NhY2hlKTsKCglp"
    "ZiAoYWQtPmRsX2dyb3VwX3Bvb2wpCgkJa21lbV9jYWNoZV9kZXN0cm95KGFkLT5kbF9ncm91cF9wb29sKTsKCgoJa2ZyZWUoYWQpOwp9CgpzdGF0aWMgdm9p"
    "ZCBzaWRlbG9hZF9sYXRlbmN5X21vZGVsKAoJCXN0cnVjdCBsYXRlbmN5X21vZGVsICptb2RlbCwgdTY0IGJhc2UsIHU2NCBzbG9wZSkgewoJc3RydWN0IGxh"
    "dGVuY3lfbW9kZWxfcGFyYW1zICpvbGRfcGFyYW1zLCAqbmV3X3BhcmFtczsKCXVuc2lnbmVkIGxvbmcgZmxhZ3M7CgoJbmV3X3BhcmFtcyA9IGt6YWxsb2Mo"
    "c2l6ZW9mKCpuZXdfcGFyYW1zKSwgR0ZQX0tFUk5FTCk7CglpZiAoIW5ld19wYXJhbXMpCgkJcmV0dXJuOwoKCXNwaW5fbG9ja19pcnFzYXZlKCZtb2RlbC0+"
    "dXBkYXRlX2xvY2ssIGZsYWdzKTsKCglvbGRfcGFyYW1zID0gcmN1X2RlcmVmZXJlbmNlX3Byb3RlY3RlZChtb2RlbC0+cGFyYW1zLAoJCQlsb2NrZGVwX2lz"
    "X2hlbGQoJm1vZGVsLT51cGRhdGVfbG9jaykpOwoKCW5ld19wYXJhbXMtPmxhc3RfdXBkYXRlX2ppZmZpZXMgPSBqaWZmaWVzOwoKCS8vIEluaXRpYWxpemUg"
    "YmFzZSBhbmQgaXRzIHN0YXRpc3RpY3MgYXMgYSBzaW5nbGUgc2FtcGxlLgoJbmV3X3BhcmFtcy0+YmFzZSA9IGJhc2U7CgluZXdfcGFyYW1zLT5zbWFsbF9z"
    "dW1fZGVsYXkgPSBiYXNlOwoJbmV3X3BhcmFtcy0+c21hbGxfY291bnQgPSAxOwoKCS8vIEluaXRpYWxpemUgc2xvcGUgYW5kIGl0cyBzdGF0aXN0aWNzIGFz"
    "IGEgc2luZ2xlIHNhbXBsZS4KCW5ld19wYXJhbXMtPnNsb3BlID0gc2xvcGU7CgluZXdfcGFyYW1zLT5sYXJnZV9zdW1fZGVsYXkgPSBzbG9wZTsKCW5ld19w"
    "YXJhbXMtPmxhcmdlX3N1bV9ic2l6ZSA9IDEwMjQ7IC8qIENvcnJlc3BvbmRzIHRvIDEgS2lCICovCgoJbG1fcmVzZXRfcGNwdV9idWNrZXRzKG1vZGVsKTsK"
    "CglyY3VfYXNzaWduX3BvaW50ZXIobW9kZWwtPnBhcmFtcywgbmV3X3BhcmFtcyk7CglzcGluX3VubG9ja19pcnFyZXN0b3JlKCZtb2RlbC0+dXBkYXRlX2xv"
    "Y2ssIGZsYWdzKTsKCglrZnJlZV9yY3Uob2xkX3BhcmFtcywgcmN1KTsKfQoKLy8gRGVmaW5lIHN5c2ZzIGF0dHJpYnV0ZXMgZm9yIG9wZXJhdGlvbiB0eXBl"
    "cwojZGVmaW5lIFNZU0ZTX09QVFlQRV9ERUNMKG5hbWUsIG9wdHlwZSkgXApzdGF0aWMgc3NpemVfdCBhZGlvc19sYXRfbW9kZWxfIyNuYW1lIyNfc2hvdygg"
    "XAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY2hhciAqcGFnZSkgeyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBc"
    "CglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBlXTsgXAoJc3RydWN0IGxhdGVuY3lfbW9kZWxfcGFyYW1z"
    "ICpwYXJhbXM7IFwKCXNzaXplX3QgbGVuID0gMDsgXAoJdTY0IGJhc2UsIHNsb3BlOyBcCglyY3VfcmVhZF9sb2NrKCk7IFwKCXBhcmFtcyA9IHJjdV9kZXJl"
    "ZmVyZW5jZShtb2RlbC0+cGFyYW1zKTsgXAoJYmFzZSA9IHBhcmFtcy0+YmFzZTsgXAoJc2xvcGUgPSBwYXJhbXMtPnNsb3BlOyBcCglyY3VfcmVhZF91bmxv"
    "Y2soKTsgXAoJbGVuICs9IHNwcmludGYocGFnZSwgICAgICAgImJhc2UgOiAlbGx1IG5zXG4iLCBiYXNlKTsgXAoJbGVuICs9IHNwcmludGYocGFnZSArIGxl"
    "biwgInNsb3BlOiAlbGx1IG5zL0tpQlxuIiwgc2xvcGUpOyBcCglyZXR1cm4gbGVuOyBcCn0gXApzdGF0aWMgc3NpemVfdCBhZGlvc19sYXRfbW9kZWxfIyNu"
    "YW1lIyNfc3RvcmUoIFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNvbnN0IGNoYXIgKnBhZ2UsIHNpemVfdCBjb3VudCkgeyBcCglzdHJ1Y3QgYWRp"
    "b3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9kYXRhOyBcCglzdHJ1Y3QgbGF0ZW5jeV9tb2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbb3B0eXBl"
    "XTsgXAoJdTY0IGJhc2UsIHNsb3BlOyBcCglpbnQgcmV0OyBcCglyZXQgPSBzc2NhbmYocGFnZSwgIiVsbHUgJWxsdSIsICZiYXNlLCAmc2xvcGUpOyBcCglp"
    "ZiAocmV0ICE9IDIpIFwKCQlyZXR1cm4gLUVJTlZBTDsgXAoJc2lkZWxvYWRfbGF0ZW5jeV9tb2RlbChtb2RlbCwgYmFzZSwgc2xvcGUpOyBcCglyZXNldF9i"
    "dWNrZXRzKGFkLT5hZ2dyX2J1Y2tldHMpOyBcCglyZXR1cm4gY291bnQ7IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zX2xhdF90YXJnZXRfIyNuYW1lIyNf"
    "c2hvdyggXAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY2hhciAqcGFnZSkgeyBcCglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2YXRvcl9k"
    "YXRhOyBcCglyZXR1cm4gc3ByaW50ZihwYWdlLCAiJWxsdVxuIiwgYWQtPmxhdGVuY3lfdGFyZ2V0W29wdHlwZV0pOyBcCn0gXApzdGF0aWMgc3NpemVfdCBh"
    "ZGlvc19sYXRfdGFyZ2V0XyMjbmFtZSMjX3N0b3JlKCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3QgY291"
    "bnQpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsgXAoJdW5zaWduZWQgbG9uZyBuc2VjOyBcCglpbnQgcmV0OyBcCgly"
    "ZXQgPSBrc3RydG91bChwYWdlLCAxMCwgJm5zZWMpOyBcCglpZiAocmV0KSBcCgkJcmV0dXJuIHJldDsgXAoJc2lkZWxvYWRfbGF0ZW5jeV9tb2RlbCgmYWQt"
    "PmxhdGVuY3lfbW9kZWxbb3B0eXBlXSwgMCwgMCk7IFwKCWFkLT5sYXRlbmN5X3RhcmdldFtvcHR5cGVdID0gbnNlYzsgXAoJcmV0dXJuIGNvdW50OyBcCn0g"
    "XApzdGF0aWMgc3NpemVfdCBhZGlvc19iYXRjaF9saW1pdF8jI25hbWUjI19zaG93KCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjaGFyICpwYWdl"
    "KSB7IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXJldHVybiBzcHJpbnRmKHBhZ2UsICIldVxuIiwgYWQtPmJhdGNo"
    "X2xpbWl0W29wdHlwZV0pOyBcCn0gXApzdGF0aWMgc3NpemVfdCBhZGlvc19iYXRjaF9saW1pdF8jI25hbWUjI19zdG9yZSggXAoJCXN0cnVjdCBlbGV2YXRv"
    "cl9xdWV1ZSAqZSwgY29uc3QgY2hhciAqcGFnZSwgc2l6ZV90IGNvdW50KSB7IFwKCXVuc2lnbmVkIGxvbmcgbWF4X2JhdGNoOyBcCglpbnQgcmV0OyBcCgly"
    "ZXQgPSBrc3RydG91bChwYWdlLCAxMCwgJm1heF9iYXRjaCk7IFwKCWlmIChyZXQgfHwgbWF4X2JhdGNoID09IDApIFwKCQlyZXR1cm4gLUVJTlZBTDsgXAoJ"
    "c3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsgXAoJYWQtPmJhdGNoX2xpbWl0W29wdHlwZV0gPSBtYXhfYmF0Y2g7IFwKCXJldHVy"
    "biBjb3VudDsgXAp9CgpTWVNGU19PUFRZUEVfREVDTChyZWFkLCBBRElPU19SRUFEKTsKU1lTRlNfT1BUWVBFX0RFQ0wod3JpdGUsIEFESU9TX1dSSVRFKTsK"
    "U1lTRlNfT1BUWVBFX0RFQ0woZGlzY2FyZCwgQURJT1NfRElTQ0FSRCk7CgovLyBTaG93IHRoZSBtYXhpbXVtIGJhdGNoIHNpemUgYWN0dWFsbHkgYWNoaWV2"
    "ZWQgZm9yIGVhY2ggb3BlcmF0aW9uIHR5cGUKc3RhdGljIHNzaXplX3QgYWRpb3NfYmF0Y2hfYWN0dWFsX21heF9zaG93KAoJCXN0cnVjdCBlbGV2YXRvcl9x"
    "dWV1ZSAqZSwgY2hhciAqcGFnZSkgewoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsKCXUzMiB0b3RhbF9jb3VudCwgcmVhZF9j"
    "b3VudCwgd3JpdGVfY291bnQsIGRpc2NhcmRfY291bnQ7CgoJdG90YWxfY291bnQgPSBhZC0+YmF0Y2hfYWN0dWFsX21heF90b3RhbDsKCXJlYWRfY291bnQg"
    "PSBhZC0+YmF0Y2hfYWN0dWFsX21heF9zaXplW0FESU9TX1JFQURdOwoJd3JpdGVfY291bnQgPSBhZC0+YmF0Y2hfYWN0dWFsX21heF9zaXplW0FESU9TX1dS"
    "SVRFXTsKCWRpc2NhcmRfY291bnQgPSBhZC0+YmF0Y2hfYWN0dWFsX21heF9zaXplW0FESU9TX0RJU0NBUkRdOwoKCXJldHVybiBzcHJpbnRmKHBhZ2UsCgkJ"
    "IlRvdGFsICA6ICV1XG5EaXNjYXJkOiAldVxuUmVhZCAgIDogJXVcbldyaXRlICA6ICV1XG4iLAoJCXRvdGFsX2NvdW50LCBkaXNjYXJkX2NvdW50LCByZWFk"
    "X2NvdW50LCB3cml0ZV9jb3VudCk7Cn0KCiNkZWZpbmUgU1lTRlNfVUxMX0RFQ0woZmllbGQsIG1pbl92YWwsIG1heF92YWwpIFwKc3RhdGljIHNzaXplX3Qg"
    "YWRpb3NfIyNmaWVsZCMjX3Nob3coIFwKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNoYXIgKnBhZ2UpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFk"
    "ID0gZS0+ZWxldmF0b3JfZGF0YTsgXAoJcmV0dXJuIHNwcmludGYocGFnZSwgIiVsbHVcbiIsIGFkLT5maWVsZCk7IFwKfSBcCnN0YXRpYyBzc2l6ZV90IGFk"
    "aW9zXyMjZmllbGQjI19zdG9yZSggXAoJCXN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY29uc3QgY2hhciAqcGFnZSwgc2l6ZV90IGNvdW50KSB7IFwKCXN0"
    "cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXVuc2lnbmVkIGxvbmcgdmFsOyBcCglpbnQgcmV0OyBcCglyZXQgPSBrc3RydG91"
    "bChwYWdlLCAxMCwgJnZhbCk7IFwKCWlmIChyZXQgfHwgdmFsIDwgKG1pbl92YWwpIHx8IHZhbCA+IChtYXhfdmFsKSkgXAoJCXJldHVybiAtRUlOVkFMOyBc"
    "CglhZC0+ZmllbGQgPSB2YWw7IFwKCXJldHVybiBjb3VudDsgXAp9CgpTWVNGU19VTExfREVDTChnbG9iYWxfbGF0ZW5jeV93aW5kb3csIDAsIFVMTE9OR19N"
    "QVgpClNZU0ZTX1VMTF9ERUNMKGNvbXBsaWFuY2VfZmxhZ3MsIDAsIFVMTE9OR19NQVgpCgojZGVmaW5lIFNZU0ZTX0lOVF9ERUNMKGZpZWxkLCBtaW5fdmFs"
    "LCBtYXhfdmFsKSBcCnN0YXRpYyBzc2l6ZV90IGFkaW9zXyMjZmllbGQjI19zaG93KCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjaGFyICpwYWdl"
    "KSB7IFwKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXJldHVybiBzcHJpbnRmKHBhZ2UsICIlZFxuIiwgYWQtPmZpZWxk"
    "KTsgXAp9IFwKc3RhdGljIHNzaXplX3QgYWRpb3NfIyNmaWVsZCMjX3N0b3JlKCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpw"
    "YWdlLCBzaXplX3QgY291bnQpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxldmF0b3JfZGF0YTsgXAoJaW50IHZhbDsgXAoJaW50IHJldDsg"
    "XAoJcmV0ID0ga3N0cnRvaW50KHBhZ2UsIDEwLCAmdmFsKTsgXAoJaWYgKHJldCB8fCB2YWwgPCAobWluX3ZhbCkgfHwgdmFsID4gKG1heF92YWwpKSBcCgkJ"
    "cmV0dXJuIC1FSU5WQUw7IFwKCWFkLT5maWVsZCA9IHZhbDsgXAoJcmV0dXJuIGNvdW50OyBcCn0KClNZU0ZTX0lOVF9ERUNMKGJxX3JlZmlsbF9iZWxvd19y"
    "YXRpbywgMCwgMTAwKQpTWVNGU19JTlRfREVDTChsYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCwgMCwgMipOU0VDX1BFUl9TRUMpClNZU0ZTX0lOVF9ERUNMKGJh"
    "dGNoX29yZGVyLCBBRElPU19CT19PUFRZUEUsICEhYWQtPmlzX3JvdGF0aW9uYWwpCgovLyBTaG93IHRoZSByZWFkIHByaW9yaXR5CnN0YXRpYyBzc2l6ZV90"
    "IGFkaW9zX3JlYWRfcHJpb3JpdHlfc2hvdygKCQlzdHJ1Y3QgZWxldmF0b3JfcXVldWUgKmUsIGNoYXIgKnBhZ2UpIHsKCXN0cnVjdCBhZGlvc19kYXRhICph"
    "ZCA9IGUtPmVsZXZhdG9yX2RhdGE7CglyZXR1cm4gc3ByaW50ZihwYWdlLCAiJWRcbiIsIGFkLT5kbF9wcmlvWzBdKTsKfQoKLy8gU2V0IHRoZSByZWFkIHBy"
    "aW9yaXR5CnN0YXRpYyBzc2l6ZV90IGFkaW9zX3JlYWRfcHJpb3JpdHlfc3RvcmUoCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpw"
    "YWdlLCBzaXplX3QgY291bnQpIHsKCXN0cnVjdCBhZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7CglpbnQgcHJpbzsKCWludCByZXQ7CgoJcmV0"
    "ID0ga3N0cnRvaW50KHBhZ2UsIDEwLCAmcHJpbyk7CglpZiAocmV0IHx8IHByaW8gPCAtMjAgfHwgcHJpbyA+IDE5KQoJCXJldHVybiAtRUlOVkFMOwoKCWFk"
    "aW9zX2d1YXJkKHNwaW5sb2NrX2lycXNhdmUpKCZhZC0+bG9jayk7CglhZC0+ZGxfcHJpb1swXSA9IHByaW87CglhZC0+ZGxfYmlhcyA9IDA7CgoJcmV0dXJu"
    "IGNvdW50Owp9CgovLyBSZXNldCBiYXRjaCBxdWV1ZSBzdGF0aXN0aWNzCnN0YXRpYyBzc2l6ZV90IGFkaW9zX3Jlc2V0X2JxX3N0YXRzX3N0b3JlKAoJCXN0"
    "cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY29uc3QgY2hhciAqcGFnZSwgc2l6ZV90IGNvdW50KSB7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2"
    "YXRvcl9kYXRhOwoJdW5zaWduZWQgbG9uZyB2YWw7CglpbnQgcmV0OwoKCXJldCA9IGtzdHJ0b3VsKHBhZ2UsIDEwLCAmdmFsKTsKCWlmIChyZXQgfHwgdmFs"
    "ICE9IDEpCgkJcmV0dXJuIC1FSU5WQUw7CgoJZm9yICh1OCBpID0gMDsgaSA8IEFESU9TX09QVFlQRVM7IGkrKykKCQlhZC0+YmF0Y2hfYWN0dWFsX21heF9z"
    "aXplW2ldID0gMDsKCglhZC0+YmF0Y2hfYWN0dWFsX21heF90b3RhbCA9IDA7CgoJcmV0dXJuIGNvdW50Owp9CgovLyBSZXNldCB0aGUgbGF0ZW5jeSBtb2Rl"
    "bCBwYXJhbWV0ZXJzIG9yIGxvYWQgdGhlbSBmcm9tIHVzZXIgaW5wdXQKc3RhdGljIHNzaXplX3QgYWRpb3NfcmVzZXRfbGF0X21vZGVsX3N0b3JlKAoJCXN0"
    "cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY29uc3QgY2hhciAqcGFnZSwgc2l6ZV90IGNvdW50KQp7CglzdHJ1Y3QgYWRpb3NfZGF0YSAqYWQgPSBlLT5lbGV2"
    "YXRvcl9kYXRhOwoJc3RydWN0IGxhdGVuY3lfbW9kZWwgKm1vZGVsOwoJaW50IHJldDsKCgkvKgoJICogRGlmZmVyZW50aWF0ZSBiZXR3ZWVuIHR3byBtb2Rl"
    "cyBiYXNlZCBvbiBpbnB1dCBmb3JtYXQ6CgkgKiAxLiAiMSI6IEZ1bGx5IHJlc2V0IHRoZSBtb2RlbCAoYmFja3dhcmQgY29tcGF0aWJpbGl0eSkuCgkgKiAy"
    "LiAiUl9iYXNlIFJfc2xvcGUgV19iYXNlIFdfc2xvcGUgRF9iYXNlIERfc2xvcGUiOiBMb2FkIHZhbHVlcy4KCSAqLwoJaWYgKCFzdHJjaHIocGFnZSwgJyAn"
    "KSkgewoJCS8vIE1vZGUgMTogRnVsbCByZXNldC4KCQl1bnNpZ25lZCBsb25nIHZhbDsKCgkJcmV0ID0ga3N0cnRvdWwocGFnZSwgMTAsICZ2YWwpOwoJCWlm"
    "IChyZXQgfHwgdmFsICE9IDEpCgkJCXJldHVybiAtRUlOVkFMOwoKCQlmb3IgKHU4IGkgPSAwOyBpIDwgQURJT1NfT1BUWVBFUzsgaSsrKSB7CgkJCW1vZGVs"
    "ID0gJmFkLT5sYXRlbmN5X21vZGVsW2ldOwoJCQlzaWRlbG9hZF9sYXRlbmN5X21vZGVsKG1vZGVsLCAwLCAwKTsKCQl9Cgl9IGVsc2UgewoJCS8vIE1vZGUg"
    "MjogTG9hZCBpbml0aWFsIHZhbHVlcyBmb3IgYWxsIGxhdGVuY3kgbW9kZWxzLgoJCXU2NCBwYXJhbXNbM11bMl07IC8qIDA6YmFzZSwgMTpzbG9wZSBmb3Ig"
    "UiwgVywgRCAqLwoKCQlyZXQgPSBzc2NhbmYocGFnZSwgIiVsbHUgJWxsdSAlbGx1ICVsbHUgJWxsdSAlbGx1IiwKCQkJJnBhcmFtc1tBRElPU19SRUFEICAg"
    "XVswXSwgJnBhcmFtc1tBRElPU19SRUFEICAgXVsxXSwKCQkJJnBhcmFtc1tBRElPU19XUklURSAgXVswXSwgJnBhcmFtc1tBRElPU19XUklURSAgXVsxXSwK"
    "CQkJJnBhcmFtc1tBRElPU19ESVNDQVJEXVswXSwgJnBhcmFtc1tBRElPU19ESVNDQVJEXVsxXSk7CgoJCWlmIChyZXQgIT0gNikKCQkJcmV0dXJuIC1FSU5W"
    "QUw7CgoJCWZvciAodTggaSA9IEFESU9TX1JFQUQ7IGkgPD0gQURJT1NfRElTQ0FSRDsgaSsrKSB7CgkJCW1vZGVsID0gJmFkLT5sYXRlbmN5X21vZGVsW2ld"
    "OwoJCQlzaWRlbG9hZF9sYXRlbmN5X21vZGVsKG1vZGVsLCBwYXJhbXNbaV1bMF0sIHBhcmFtc1tpXVsxXSk7CgkJfQoJfQoJcmVzZXRfYnVja2V0cyhhZC0+"
    "YWdncl9idWNrZXRzKTsKCglyZXR1cm4gY291bnQ7Cn0KCi8vIFNob3cgdGhlIEFESU9TIHZlcnNpb24Kc3RhdGljIHNzaXplX3QgYWRpb3NfdmVyc2lvbl9z"
    "aG93KHN0cnVjdCBlbGV2YXRvcl9xdWV1ZSAqZSwgY2hhciAqcGFnZSkgewoJcmV0dXJuIHNwcmludGYocGFnZSwgIiVzXG4iLCBBRElPU19WRVJTSU9OKTsK"
    "fQoKLy8gRGVmaW5lIHN5c2ZzIGF0dHJpYnV0ZXMgZm9yIGR5bmFtaWMgdGhyZXNob2xkcwojZGVmaW5lIFNIUklOS19USFJFU0hPTERfQVRUUl9SVyhuYW1l"
    "LCBtb2RlbF9maWVsZCwgbWluX3ZhbHVlLCBtYXhfdmFsdWUpIFwKc3RhdGljIHNzaXplX3QgYWRpb3Nfc2hyaW5rXyMjbmFtZSMjX3N0b3JlKCBcCgkJc3Ry"
    "dWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjb25zdCBjaGFyICpwYWdlLCBzaXplX3QgY291bnQpIHsgXAoJc3RydWN0IGFkaW9zX2RhdGEgKmFkID0gZS0+ZWxl"
    "dmF0b3JfZGF0YTsgXAoJdW5zaWduZWQgbG9uZyB2YWw7IFwKCWludCByZXQ7IFwKCXJldCA9IGtzdHJ0b3VsKHBhZ2UsIDEwLCAmdmFsKTsgXAoJaWYgKHJl"
    "dCB8fCB2YWwgPCBtaW5fdmFsdWUgfHwgdmFsID4gbWF4X3ZhbHVlKSBcCgkJcmV0dXJuIC1FSU5WQUw7IFwKCWZvciAodTggaSA9IDA7IGkgPCBBRElPU19P"
    "UFRZUEVTOyBpKyspIHsgXAoJCXN0cnVjdCBsYXRlbmN5X21vZGVsICptb2RlbCA9ICZhZC0+bGF0ZW5jeV9tb2RlbFtpXTsgXAoJCXVuc2lnbmVkIGxvbmcg"
    "ZmxhZ3M7IFwKCQlzcGluX2xvY2tfaXJxc2F2ZSgmbW9kZWwtPnVwZGF0ZV9sb2NrLCBmbGFncyk7IFwKCQltb2RlbC0+bW9kZWxfZmllbGQgPSB2YWw7IFwK"
    "CQlzcGluX3VubG9ja19pcnFyZXN0b3JlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsgXAoJfSBcCglyZXR1cm4gY291bnQ7IFwKfSBcCnN0YXRpYyBz"
    "c2l6ZV90IGFkaW9zX3Nocmlua18jI25hbWUjI19zaG93KCBcCgkJc3RydWN0IGVsZXZhdG9yX3F1ZXVlICplLCBjaGFyICpwYWdlKSB7IFwKCXN0cnVjdCBh"
    "ZGlvc19kYXRhICphZCA9IGUtPmVsZXZhdG9yX2RhdGE7IFwKCXUzMiB2YWwgPSAwOyBcCgl1bnNpZ25lZCBsb25nIGZsYWdzOyBcCglzdHJ1Y3QgbGF0ZW5j"
    "eV9tb2RlbCAqbW9kZWwgPSAmYWQtPmxhdGVuY3lfbW9kZWxbMF07IFwKCXNwaW5fbG9ja19pcnFzYXZlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsg"
    "XAoJdmFsID0gbW9kZWwtPm1vZGVsX2ZpZWxkOyBcCglzcGluX3VubG9ja19pcnFyZXN0b3JlKCZtb2RlbC0+dXBkYXRlX2xvY2ssIGZsYWdzKTsgXAoJcmV0"
    "dXJuIHNwcmludGYocGFnZSwgIiV1XG4iLCB2YWwpOyBcCn0KClNIUklOS19USFJFU0hPTERfQVRUUl9SVyhhdF9rcmVxcywgIGxtX3Nocmlua19hdF9rcmVx"
    "cywgIDEsIDEwMDAwMCkKU0hSSU5LX1RIUkVTSE9MRF9BVFRSX1JXKGF0X2dieXRlcywgbG1fc2hyaW5rX2F0X2dieXRlcywgMSwgICAxMDAwKQpTSFJJTktf"
    "VEhSRVNIT0xEX0FUVFJfUlcocmVzaXN0LCAgICBsbV9zaHJpbmtfcmVzaXN0LCAgICAxLCAgICAgIDMpCgovLyBEZWZpbmUgc3lzZnMgYXR0cmlidXRlcwoj"
    "ZGVmaW5lIEFEX0FUVFIobmFtZSwgc2hvd19mdW5jLCBzdG9yZV9mdW5jKSBcCglfX0FUVFIobmFtZSwgMDY0NCwgc2hvd19mdW5jLCBzdG9yZV9mdW5jKQoj"
    "ZGVmaW5lIEFEX0FUVFJfUlcobmFtZSkgXAoJX19BVFRSKG5hbWUsIDA2NDQsIGFkaW9zXyMjbmFtZSMjX3Nob3csIGFkaW9zXyMjbmFtZSMjX3N0b3JlKQoj"
    "ZGVmaW5lIEFEX0FUVFJfUk8obmFtZSkgXAoJX19BVFRSKG5hbWUsIDA0NDQsIGFkaW9zXyMjbmFtZSMjX3Nob3csIE5VTEwpCiNkZWZpbmUgQURfQVRUUl9X"
    "TyhuYW1lKSBcCglfX0FUVFIobmFtZSwgMDIwMCwgTlVMTCwgYWRpb3NfIyNuYW1lIyNfc3RvcmUpCgovLyBEZWZpbmUgc3lzZnMgYXR0cmlidXRlcyBmb3Ig"
    "QURJT1Mgc2NoZWR1bGVyCnN0YXRpYyBzdHJ1Y3QgZWx2X2ZzX2VudHJ5IGFkaW9zX3NjaGVkX2F0dHJzW10gPSB7CglBRF9BVFRSX1JPKGJhdGNoX2FjdHVh"
    "bF9tYXgpLAoJQURfQVRUUl9SVyhicV9yZWZpbGxfYmVsb3dfcmF0aW8pLAoJQURfQVRUUl9SVyhnbG9iYWxfbGF0ZW5jeV93aW5kb3cpLAoJQURfQVRUUl9S"
    "VyhsYXRfbW9kZWxfbGF0ZW5jeV9saW1pdCksCglBRF9BVFRSX1JXKGJhdGNoX29yZGVyKSwKCUFEX0FUVFJfUlcoY29tcGxpYW5jZV9mbGFncyksCgoJQURf"
    "QVRUUl9SVyhiYXRjaF9saW1pdF9yZWFkKSwKCUFEX0FUVFJfUlcoYmF0Y2hfbGltaXRfd3JpdGUpLAoJQURfQVRUUl9SVyhiYXRjaF9saW1pdF9kaXNjYXJk"
    "KSwKCglBRF9BVFRSX1JXKGxhdF9tb2RlbF9yZWFkKSwKCUFEX0FUVFJfUlcobGF0X21vZGVsX3dyaXRlKSwKCUFEX0FUVFJfUlcobGF0X21vZGVsX2Rpc2Nh"
    "cmQpLAoKCUFEX0FUVFJfUlcobGF0X3RhcmdldF9yZWFkKSwKCUFEX0FUVFJfUlcobGF0X3RhcmdldF93cml0ZSksCglBRF9BVFRSX1JXKGxhdF90YXJnZXRf"
    "ZGlzY2FyZCksCgoJQURfQVRUUl9SVyhzaHJpbmtfYXRfa3JlcXMpLAoJQURfQVRUUl9SVyhzaHJpbmtfYXRfZ2J5dGVzKSwKCUFEX0FUVFJfUlcoc2hyaW5r"
    "X3Jlc2lzdCksCgoJQURfQVRUUl9SVyhyZWFkX3ByaW9yaXR5KSwKCglBRF9BVFRSX1dPKHJlc2V0X2JxX3N0YXRzKSwKCUFEX0FUVFJfV08ocmVzZXRfbGF0"
    "X21vZGVsKSwKCUFEX0FUVFIoYWRpb3NfdmVyc2lvbiwgYWRpb3NfdmVyc2lvbl9zaG93LCBOVUxMKSwKCglfX0FUVFJfTlVMTAp9OwoKLy8gRGVmaW5lIHRo"
    "ZSBBRElPUyBzY2hlZHVsZXIgdHlwZQpzdGF0aWMgc3RydWN0IGVsZXZhdG9yX3R5cGUgbXFfYWRpb3MgPSB7Cgkub3BzID0gewoJCS5uZXh0X3JlcXVlc3QJ"
    "CT0gZWx2X3JiX2xhdHRlcl9yZXF1ZXN0LAoJCS5mb3JtZXJfcmVxdWVzdAkJPSBlbHZfcmJfZm9ybWVyX3JlcXVlc3QsCgkJLmxpbWl0X2RlcHRoCQk9IGFk"
    "aW9zX2xpbWl0X2RlcHRoLAoJCS5kZXB0aF91cGRhdGVkCQk9IGFkaW9zX2RlcHRoX3VwZGF0ZWQsCgkJLnJlcXVlc3RfbWVyZ2VkCQk9IGFkaW9zX3JlcXVl"
    "c3RfbWVyZ2VkLAoJCS5yZXF1ZXN0c19tZXJnZWQJPSBhZGlvc19tZXJnZWRfcmVxdWVzdHMsCgkJLmJpb19tZXJnZQkJCT0gYWRpb3NfYmlvX21lcmdlLAoJ"
    "CS5pbnNlcnRfcmVxdWVzdHMJPSBhZGlvc19pbnNlcnRfcmVxdWVzdHMsCgkJLnByZXBhcmVfcmVxdWVzdAk9IGFkaW9zX3ByZXBhcmVfcmVxdWVzdCwKCQku"
    "ZGlzcGF0Y2hfcmVxdWVzdAk9IGFkaW9zX2Rpc3BhdGNoX3JlcXVlc3QsCgkJLmNvbXBsZXRlZF9yZXF1ZXN0CT0gYWRpb3NfY29tcGxldGVkX3JlcXVlc3Qs"
    "CgkJLmZpbmlzaF9yZXF1ZXN0CQk9IGFkaW9zX2ZpbmlzaF9yZXF1ZXN0LAoJCS5oYXNfd29yawkJCT0gYWRpb3NfaGFzX3dvcmssCgkJLmluaXRfaGN0eAkJ"
    "CT0gYWRpb3NfaW5pdF9oY3R4LAoJCS5pbml0X3NjaGVkCQkJPSBhZGlvc19pbml0X3NjaGVkLAoJCS5leGl0X3NjaGVkCQkJPSBhZGlvc19leGl0X3NjaGVk"
    "LAoJfSwKCS5lbGV2YXRvcl9hdHRycyA9IGFkaW9zX3NjaGVkX2F0dHJzLAoJLmVsZXZhdG9yX25hbWUgPSAiYWRpb3MiLAoJLmVsZXZhdG9yX293bmVyID0g"
    "VEhJU19NT0RVTEUsCn07Ck1PRFVMRV9BTElBUygibXEtYWRpb3MtaW9zY2hlZCIpOwoKI2RlZmluZSBBRElPU19QUk9HTkFNRSAiQWRhcHRpdmUgRGVhZGxp"
    "bmUgSS9PIFNjaGVkdWxlciIKI2RlZmluZSBBRElPU19BVVRIT1IgICAiTWFzYWhpdG8gU3V6dWtpIgoKLy8gSW5pdGlhbGl6ZSB0aGUgQURJT1Mgc2NoZWR1"
    "bGVyIG1vZHVsZQpzdGF0aWMgaW50IF9faW5pdCBhZGlvc19pbml0KHZvaWQpIHsKCXByaW50ayhLRVJOX0lORk8gIiVzICVzIGJ5ICVzXG4iLAoJCUFESU9T"
    "X1BST0dOQU1FLCBBRElPU19WRVJTSU9OLCBBRElPU19BVVRIT1IpOwoJcmV0dXJuIGVsdl9yZWdpc3RlcigmbXFfYWRpb3MpOwp9CgovLyBFeGl0IHRoZSBB"
    "RElPUyBzY2hlZHVsZXIgbW9kdWxlCnN0YXRpYyB2b2lkIF9fZXhpdCBhZGlvc19leGl0KHZvaWQpIHsKCWVsdl91bnJlZ2lzdGVyKCZtcV9hZGlvcyk7Cn0K"
    "Cm1vZHVsZV9pbml0KGFkaW9zX2luaXQpOwptb2R1bGVfZXhpdChhZGlvc19leGl0KTsKCk1PRFVMRV9BVVRIT1IoQURJT1NfQVVUSE9SKTsKTU9EVUxFX0xJ"
    "Q0VOU0UoIkdQTCIpOwpNT0RVTEVfREVTQ1JJUFRJT04oQURJT1NfUFJPR05BTUUpOwo="
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
			susfs_manual_apply

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
