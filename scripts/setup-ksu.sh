#!/usr/bin/env bash
# Integrate KSU-Next or SukiSU-Ultra and the matching SUSFS kernel patches.
# Required: KSU_TYPE={ksun|suki}, KERNEL_DIR, WORK_DIR
set -Eeuo pipefail

: "${KSU_TYPE:?KSU_TYPE is required (ksun|suki)}"
: "${KERNEL_DIR:?KERNEL_DIR is required}"
: "${WORK_DIR:?WORK_DIR is required}"

case "$KSU_TYPE" in ksun|suki) ;; *) echo "[ERROR] Unsupported KSU_TYPE: $KSU_TYPE" >&2; exit 2;; esac
[[ -d "$KERNEL_DIR/drivers" && -f "$KERNEL_DIR/drivers/Makefile" && -f "$KERNEL_DIR/drivers/Kconfig" ]] || {
  echo "[ERROR] KERNEL_DIR is not a kernel source root: $KERNEL_DIR" >&2; exit 2;
}
mkdir -p "$WORK_DIR"
cd "$KERNEL_DIR"

log() { printf '[KSU] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

link_driver() {
  local repo_dir="$1" target
  [[ -d "$repo_dir/kernel" ]] || fail "$repo_dir/kernel is missing"
  target="../$repo_dir/kernel"
  rm -f drivers/kernelsu
  ln -s "$target" drivers/kernelsu
  grep -Fq 'obj-$(CONFIG_KSU) += kernelsu/' drivers/Makefile || \
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
  grep -Fq 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig || \
    printf '\nsource "drivers/kernelsu/Kconfig"\n' >> drivers/Kconfig
}

record_version() {
  local repo_dir="$1" tag_file="$2" version_file="$3" env_key="$4" tag version
  tag=$(git -C "$repo_dir" describe --tags --abbrev=0 2>/dev/null || git -C "$repo_dir" rev-parse --short HEAD)
  version=$(grep -RhsE '^#define KSU_VERSION[[:space:]]+' "$repo_dir/kernel" 2>/dev/null | head -n1 | awk '{print $NF}' | tr -d '[:space:]' || true)
  printf '%s\n' "$tag" > "$WORK_DIR/$tag_file"
  printf '%s\n' "$version" > "$WORK_DIR/$version_file"
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "$env_key" "$tag" >> "$GITHUB_ENV"
  fi
  log "$repo_dir version tag=$tag code=${version:-unknown}"
}

apply_susfs_patch() {
  local patch_file="$1" tmp
  [[ -s "$patch_file" ]] || fail "SUSFS patch not found: $patch_file"
  tmp=$(mktemp)
  if patch -p1 --dry-run --forward --fuzz=3 < "$patch_file" >"$tmp" 2>&1; then
    patch -p1 --forward --fuzz=3 < "$patch_file"
    log "Applied $(basename "$patch_file")"
  elif patch -p1 --dry-run --reverse --fuzz=3 < "$patch_file" >/dev/null 2>&1; then
    log "SUSFS patch already applied"
  else
    cat "$tmp" >&2
    rm -f "$tmp"
    fail "SUSFS patch conflicts with this kernel source; refusing to continue"
  fi
  rm -f "$tmp"
}

copy_susfs_files() {
  local src="$1"
  [[ -d "$src/fs" && -d "$src/include/linux" ]] || fail "SUSFS support files missing under $src"
  cp -af "$src/fs/." fs/
  cp -af "$src/include/linux/." include/linux/
}

inject_susfs_init() {
  local cfile="$1"
  [[ -f "$cfile" ]] || fail "KSU init source missing: $cfile"
  if grep -q 'susfs_init[[:space:]]*(' "$cfile"; then
    log "susfs_init already present"
    return
  fi
  python3 - "$cfile" <<'PYCODE'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
if '#include <linux/susfs.h>' not in s:
    m = re.search(r'(?m)^#include <linux/[^>]+>\s*$', s)
    if not m:
        raise SystemExit(f'[ERROR] cannot find include insertion point in {p}')
    s = s[:m.end()] + '\n#include <linux/susfs.h>' + s[m.end():]
needle = 'ksu_core_init();'
if needle not in s:
    raise SystemExit(f'[ERROR] {needle!r} not found in {p}; SUSFS init needs manual integration')
s = s.replace(needle, needle + '\n\tsusfs_init();', 1)
p.write_text(s)
PYCODE
  log "Injected SUSFS initialization in $cfile"
}

if [[ "$KSU_TYPE" == "ksun" ]]; then
  rm -rf KernelSU KernelSU-Next drivers/kernelsu
  curl --fail --location --silent --show-error \
    https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh \
    | bash -s dev-susfs
  [[ -d KernelSU-Next/kernel ]] || fail 'KernelSU-Next checkout did not produce KernelSU-Next/kernel'
  record_version KernelSU-Next ksun_tag.txt ksun_version.txt KSUN_TAG
  SUSFS_REPO='https://gitlab.com/simonpunk/susfs4ksu.git'
  SUSFS_BRANCH='gki-android13-5.15'
  KSU_C='KernelSU-Next/kernel/ksu.c'
else
  rm -rf KernelSU KernelSU-Next drivers/kernelsu
  curl --fail --location --silent --show-error \
    https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh \
    | bash -s main
  [[ -d KernelSU/kernel ]] || fail 'SukiSU setup did not produce KernelSU/kernel'
  record_version KernelSU suki_ksu_tag.txt suki_version.txt SUKI_TAG
  SUSFS_REPO='https://github.com/ShirkNeko/susfs4ksu.git'
  SUSFS_BRANCH='gki-android13-5.15'
  KSU_C='KernelSU/kernel/ksu.c'
fi

git clone --depth=1 --branch "$SUSFS_BRANCH" "$SUSFS_REPO" susfs4ksu
SUSFS_COMMIT=$(git -C susfs4ksu rev-parse --short HEAD)
log "SUSFS commit: $SUSFS_COMMIT"
if [[ -n "${GITHUB_ENV:-}" ]]; then printf 'SUSFS_COMMIT=%s\n' "$SUSFS_COMMIT" >> "$GITHUB_ENV"; fi

SUSFS_PATCH="susfs4ksu/kernel_patches/50_add_susfs_in_gki-android13-5.15.patch"
# GKI/CLO 5.15 trees may omit trace-hook include lines retained as patch context.
# Restore only those known context lines before the strict dry-run/apply.
python3 "$WORK_DIR/scripts/susfs_restore_context.py" "$SUSFS_PATCH" "$KERNEL_DIR"
apply_susfs_patch "$SUSFS_PATCH"
copy_susfs_files susfs4ksu
inject_susfs_init "$KSU_C"
link_driver "$([[ "$KSU_TYPE" == "ksun" ]] && echo KernelSU-Next || echo KernelSU)"
rm -rf susfs4ksu
log "Setup complete: $KSU_TYPE"
