#!/usr/bin/env python3
"""Restore trace-hook include context expected by SUSFS's first patch hunks.

Some Qualcomm/GKI 5.15 source snapshots omit trace/hooks/blk.h, fs.h and
mm.h include lines that remain as context in simonpunk/susfs4ksu patches.
These are context-only for the affected hunks. Restore only the ordered
trace/hooks includes present in the patch; create an empty guarded header only
when the source tree no longer ships that header. Idempotent and deliberately
narrow: no unrelated includes or source statements are changed.
"""
import pathlib, re, sys
INCLUDE_RE = re.compile(r'^#include\s+(?P<inc><trace/hooks/[^>]+>)')
ANY_INCLUDE = re.compile(r'^#include\s+(?P<inc>[<\"][^>\"]+[>\"])')

def parse_patch(text):
    files, current, in_first, hunk = {}, None, False, []
    def flush():
        nonlocal hunk, in_first
        if current is not None and in_first:
            includes=[]
            for line in hunk:
                if line.startswith(' '):
                    m=ANY_INCLUDE.match(line[1:].strip())
                    if m: includes.append(m.group('inc'))
            if includes: files[current]=includes
        hunk=[]; in_first=False
    for line in text.splitlines():
        if line.startswith('diff --git '):
            flush(); m=re.match(r'diff --git a/(\S+) b/',line); current=m.group(1) if m else None
        elif line.startswith('@@'):
            if in_first: flush(); current=None
            else: in_first=True
        elif in_first: hunk.append(line)
    flush(); return files

def ensure_stub(tree, inc):
    rel=inc.strip('<>'); path=tree/'include'/rel
    if path.exists(): return False
    path.parent.mkdir(parents=True,exist_ok=True)
    guard='_SUSFS_CONTEXT_STUB_'+re.sub(r'\W','_',rel).upper()
    path.write_text('/* SUSFS patch context-only stub; no symbols are used. */\n#ifndef '+guard+'\n#define '+guard+'\n#endif\n')
    return True

def main():
    if len(sys.argv)<2: raise SystemExit('usage: susfs_restore_context.py <patch> [tree]')
    patch_path=pathlib.Path(sys.argv[1]); tree=pathlib.Path(sys.argv[2] if len(sys.argv)>2 else '.')
    added=[]; stubs=[]
    for rel, includes in parse_patch(patch_path.read_text(errors='replace')).items():
        if not any(INCLUDE_RE.match('#include '+x) for x in includes): continue
        target=tree/rel
        if not target.exists(): continue
        lines=target.read_text(errors='replace').splitlines(keepends=True); present=[x.strip() for x in lines]
        cursor=0; changed=False
        for inc in includes:
            wanted='#include '+inc
            try: idx=present.index(wanted,cursor)
            except ValueError: idx=None
            if idx is not None: cursor=idx+1; continue
            if not INCLUDE_RE.match(wanted): continue
            lines.insert(cursor,wanted+'\n'); present.insert(cursor,wanted)
            added.append(f'{rel}: {wanted}')
            if ensure_stub(tree,inc): stubs.append(inc)
            cursor+=1; changed=True
        if changed: target.write_text(''.join(lines))
    for x in added: print('[SUSFS] restored context '+x)
    for x in stubs: print('[SUSFS] created context-only header '+x)
    if not added: print('[SUSFS] context already complete')
if __name__=='__main__': main()
