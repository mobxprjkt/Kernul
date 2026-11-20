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
  if patch -p1 --batch --dry-run --forward --fuzz=3 < "$patch_file" >"$tmp" 2>&1; then
    patch -p1 --batch --forward --fuzz=3 < "$patch_file"
    log "Applied $(basename "$patch_file")"
  elif patch -p1 --batch --dry-run --reverse --fuzz=3 < "$patch_file" >/dev/null 2>&1; then
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
  local payload="$src/kernel_patches"

  # SUSFS repositories keep the kernel support headers/sources in
  # kernel_patches/{fs,include/linux}; accept the old root layout as fallback.
  if [[ ! -d "$payload/fs" || ! -d "$payload/include/linux" ]]; then
    payload="$src"
  fi
  [[ -d "$payload/fs" && -d "$payload/include/linux" ]] || \
    fail "SUSFS support files missing under $src (checked kernel_patches/ and repository root)"

  mkdir -p fs include/linux
  cp -af "$payload/fs/." fs/
  cp -af "$payload/include/linux/." include/linux/

  # Compatibility fix for SUSFS revisions that call SUSFS_LOGI_RL() but
  # ship a logger block defining only SUSFS_LOGI()/SUSFS_LOGE().
  if [[ -f fs/susfs.c ]] && grep -q 'SUSFS_LOGI_RL[[:space:]]*(' fs/susfs.c && \
     ! grep -Eq '^[[:space:]]*#[[:space:]]*define[[:space:]]+SUSFS_LOGI_RL([[:space:]]|\()' fs/susfs.c; then
    python3 - fs/susfs.c <<'PYCODE'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
marker = 'bool susfs_starts_with'
if marker not in s:
    raise SystemExit(f'[ERROR] cannot locate SUSFS logger insertion point in {p}')
compat = r'''#ifndef SUSFS_LOGI_RL
#ifdef CONFIG_KSU_SUSFS_ENABLE_LOG
#define SUSFS_LOGI_RL(fmt, ...) \
    do { \
        if (susfs_is_log_enabled) \
            pr_info_ratelimited("susfs:[%u][%d][%s] " fmt, \
                current_uid().val, current->pid, __func__, ##__VA_ARGS__); \
    } while (0)
#else
#define SUSFS_LOGI_RL(fmt, ...) do { } while (0)
#endif
#endif

'''
s = s.replace(marker, compat + marker, 1)
p.write_text(s)
PYCODE
    log "Added missing SUSFS_LOGI_RL compatibility macro in fs/susfs.c"
  fi
  log "Copied SUSFS support files from $payload"
}

inject_susfs_init() {
  local cfile="$1"
  [[ -f "$cfile" ]] || fail "KSU init source missing: $cfile"

  # Current KernelSU-Next dev-susfs moved its init implementation to
  # kernel/core/init.c (kernelsu_init); older forks used kernel/ksu.c
  # (ksu_core_init). Do not inject a second call when upstream already has it.
  if grep -q 'susfs_init[[:space:]]*(' "$cfile"; then
    log "SUSFS initialization already integrated in $cfile"
    return
  fi

  python3 - "$cfile" <<'PYCODE'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()

include = '#include <linux/susfs.h>'
if include not in s:
    m = re.search(r'(?m)^#include <linux/[^>]+>\s*$', s)
    if not m:
        raise SystemExit(f'[ERROR] cannot find include insertion point in {p}')
    s = s[:m.end()] + '\n' + include + s[m.end():]

block = '\n#ifdef CONFIG_KSU_SUSFS\n\tsusfs_init();\n#endif\n'

# Older KSU/SukiSU layout.
if 'ksu_core_init();' in s:
    s = s.replace('ksu_core_init();', 'ksu_core_init();' + block, 1)
else:
    # Current KernelSU-Next dev-susfs layout: kernel/core/init.c.
    fn = re.search(r'int\s+__init\s+kernelsu_init\s*\([^)]*\)\s*\{', s)
    if not fn:
        raise SystemExit(f'[ERROR] no supported KSU init function found in {p}')
    tail = s[fn.end():]
    # Insert after the first local declaration to keep declarations before statements.
    decl = re.search(r'\n[ \t]*(?:int|bool|long|unsigned\s+\w+|struct\s+\w+\s*\*)\s+\w+[^;]*;', tail)
    if not decl:
        raise SystemExit(f'[ERROR] cannot find declaration in kernelsu_init() in {p}')
    pos = fn.end() + decl.end()
    s = s[:pos] + block + s[pos:]

p.write_text(s)
PYCODE
  log "Integrated SUSFS initialization in $cfile"
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
  KSU_C='KernelSU-Next/kernel/core/init.c'
  [[ -f "$KSU_C" ]] || KSU_C='KernelSU-Next/kernel/ksu.c'
else
  rm -rf KernelSU KernelSU-Next drivers/kernelsu
  curl --fail --location --silent --show-error \
    https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh \
    | bash -s main
  [[ -d KernelSU/kernel ]] || fail 'SukiSU setup did not produce KernelSU/kernel'
  record_version KernelSU suki_ksu_tag.txt suki_version.txt SUKI_TAG
  # The original ShirkNeko account/repository is currently unavailable.
  # Use the public mirror that retains the matching 5.15 branch.
  SUSFS_REPO='https://github.com/ndrancs/ShirkNeko_susfs4ksu.git'
  SUSFS_BRANCH='gki-android13-5.15'
  KSU_C='KernelSU/kernel/ksu.c'
  [[ -f "$KSU_C" ]] || KSU_C='KernelSU/kernel/core/init.c'
fi

GIT_TERMINAL_PROMPT=0 git clone --depth=1 --branch "$SUSFS_BRANCH" "$SUSFS_REPO" susfs4ksu
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
