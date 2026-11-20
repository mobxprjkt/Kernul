#!/usr/bin/env bash
# Non-interactive patch helper. Source this file before calling apply_patch().
apply_patch() {
  local SRC="${1:?patch source required}" NAME="${2:-patch}" STRICT="${3:-0}"
  local TMP
  TMP=$(mktemp "/tmp/kernul_patch_${NAME//[^a-zA-Z0-9]/_}.XXXXXX") || return 1

  if [[ "$SRC" == http* ]]; then
    if ! curl --fail --location --silent --show-error "$SRC" -o "$TMP"; then
      echo "[SKIP] $NAME — download failed"
      rm -f "$TMP"
      [[ "$STRICT" == "1" ]] && return 1 || return 0
    fi
  else
    if [[ ! -f "$SRC" ]]; then
      echo "[SKIP] $NAME — not found: $SRC"
      rm -f "$TMP"
      [[ "$STRICT" == "1" ]] && return 1 || return 0
    fi
    cp -- "$SRC" "$TMP"
  fi

  if [[ ! -s "$TMP" ]]; then
    echo "[SKIP] $NAME — empty patch"
    rm -f "$TMP"
    [[ "$STRICT" == "1" ]] && return 1 || return 0
  fi

  # A reverse dry-run distinguishes an already-applied patch from a conflict.
  if patch -p1 --batch --dry-run --forward --quiet < "$TMP" >/dev/null 2>&1; then
    if patch -p1 --batch --forward < "$TMP"; then
      echo "[OK] $NAME"
      rm -f "$TMP"
      return 0
    fi
    echo "[FAIL] $NAME — patch command failed during apply"
    rm -f "$TMP"
    [[ "$STRICT" == "1" ]] && return 1 || return 0
  fi

  if patch -p1 --batch --dry-run --reverse --quiet < "$TMP" >/dev/null 2>&1; then
    echo "[SKIP] $NAME — already applied"
    rm -f "$TMP"
    return 0
  fi

  if [[ "$NAME" == "vm_swappiness" ]]; then
    # The tuning patch often drifts after earlier mm patches. Update only the
    # single canonical initializer and fail closed if it is absent/ambiguous.
    python3 - <<'PYVM'
from pathlib import Path
import re
p = Path('mm/vmscan.c')
if not p.is_file():
    raise SystemExit('[FAIL] vm_swappiness — mm/vmscan.c not found')
s = p.read_text()
pat = re.compile(r'(?m)^int\s+vm_swappiness\s*=\s*(\d+)\s*;')
matches = list(pat.finditer(s))
if len(matches) != 1:
    raise SystemExit(f'[FAIL] vm_swappiness — expected one initializer, found {len(matches)}')
old = matches[0].group(1)
if old == '100':
    print('[SKIP] vm_swappiness — already set to 100')
else:
    s = pat.sub('int vm_swappiness = 100;', s, count=1)
    p.write_text(s)
    print(f'[OK] vm_swappiness — {old} -> 100 (context-safe fallback)')
PYVM
    local RC=$?
    rm -f "$TMP"
    return "$RC"
  fi

  echo "[WARN] $NAME — context mismatch; skipped (no interactive prompt)"
  rm -f "$TMP"
  [[ "$STRICT" == "1" ]] && return 1 || return 0
}
