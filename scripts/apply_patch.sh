#!/usr/bin/env bash
# patch helper — source this before calling apply_patch()
apply_patch() {
  local SRC="$1" NAME="$2" STRICT="${3:-0}"
  local TMP="/tmp/p_${NAME//[^a-zA-Z0-9]/_}"

  if [[ "$SRC" == http* ]]; then
    curl -LSs --fail "$SRC" -o "$TMP" 2>/dev/null || { echo "[SKIP] $NAME — download failed"; return 0; }
  else
    [ -f "$SRC" ] || { echo "[SKIP] $NAME — not found: $SRC"; return 0; }
    cp "$SRC" "$TMP"
  fi

  local missing=""
  while IFS= read -r line; do
    [[ "$line" =~ ^---\ a/(.+)$ ]] || continue
    local t="${BASH_REMATCH[1]}"
    [[ "$t" == "/dev/null" ]] && continue
    [ -f "$t" ] || missing="$missing $t"
  done < "$TMP"
  [ -n "$missing" ] && { echo "[SKIP] $NAME — missing:$missing"; rm -f "$TMP"; return 0; }

  if ! patch -p1 --dry-run --forward --quiet < "$TMP" 2>/dev/null; then
    if patch -p1 --dry-run --reverse --quiet < "$TMP" 2>/dev/null; then
      echo "[SKIP] $NAME — already applied"
    elif [[ "$NAME" == "vm_swappiness" ]]; then
      # Earlier 5.15 optimization patches can shift/change the hunk context.
      # Change only the unique upstream vm_swappiness initializer; fail closed
      # if it is absent or ambiguous instead of silently skipping the tuning.
      python3 - <<'PYVM'
from pathlib import Path
import re
p=Path('mm/vmscan.c')
s=p.read_text()
pat=re.compile(r'(?m)^int\s+vm_swappiness\s*=\s*(\d+)\s*;')
m=list(pat.finditer(s))
if len(m)!=1:
    raise SystemExit(f'[ERROR] expected exactly one vm_swappiness initializer, found {len(m)}')
if m[0].group(1)=='100':
    print('[SKIP] vm_swappiness — already set to 100')
else:
    s=pat.sub('int vm_swappiness = 100;',s,count=1)
    p.write_text(s)
    print(f'[OK] vm_swappiness — {m[0].group(1)} -> 100 (context-safe fallback)')
PYVM
      local rc=$?
      rm -f "$TMP"
      return "$rc"
    else
      echo "[FAIL] $NAME — context mismatch, needs manual review"
      [ "$STRICT" = "1" ] && { rm -f "$TMP"; return 1; }
    fi
    rm -f "$TMP"
    return 0
  fi

  if patch -p1 --forward < "$TMP"; then
    echo "[OK]  $NAME"
  else
    [ "$STRICT" = "1" ] && { echo "[FAIL] $NAME"; rm -f "$TMP"; return 1; }
    echo "[WARN] $NAME — skipped"
  fi
  rm -f "$TMP"
}
