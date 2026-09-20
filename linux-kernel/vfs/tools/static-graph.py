#!/usr/bin/env python3
# static-graph.py -- build a static call graph of the VFS out of the compiled
# objects, not out of the source.
#
# The source says what was written; the object says what gcc produced after
# inlining, and inlining is most of the story on this path. A function that
# reads as five calls in fs/namei.c can be one straight-line block in
# namei.o, and a helper that looks trivial can be a real call with a real
# frame. Everything here is therefore read out of `objdump -dr` on the .o
# files from the kernel build, with relocations so that cross-TU calls keep
# their symbol names instead of showing up as `call 0`.
#
# What is extracted per function:
#
#   insns        instruction count -- the size of the body gcc actually emitted
#   bytes        byte size from the ELF symbol table
#   frame        stack frame in bytes, from the `sub $N,%rsp` in the prologue.
#                Not the whole stack cost (pushes are counted separately) but
#                the part that scales with the function's own locals.
#   pushes       callee-saved registers pushed; 8 bytes each on top of `frame`
#   calls        direct call targets, by symbol, from the relocation
#   indirect     `call *...` sites -- these are the ->i_op/->f_op dispatches
#                and they are where the filesystem-specific code starts, so
#                they bound what static analysis can see
#   atomics      lock-prefixed instructions, by mnemonic. These are the
#                operations that cost a cacheline, and on a shared inode they
#                are the whole cost.
#   pause        `pause` -- a cmpxchg retry loop, i.e. lockref
#
# Indirect calls are deliberately NOT resolved. Resolving them needs the
# ops-struct initialisers per filesystem, which is a different document.
#
# SPDX-License-Identifier: GPL-2.0

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

# `objdump -d` function header:  "0000000000000abc <symbol>:"
RE_FUNC = re.compile(r'^([0-9a-f]+) <([^>]+)>:$')
# instruction line: "     abc:\tmnemonic operands"  (--no-show-raw-insn)
RE_INSN = re.compile(r'^\s+([0-9a-f]+):\t(.*)$')
# relocation line emitted by -r, immediately after the instruction it patches
RE_RELOC = re.compile(r'^\s+([0-9a-f]+):\s+(R_\S+)\s+(\S+)')
# relocation targets carry an addend: `__fentry__-0x4`, `foo+0x10`
RE_ADDEND = re.compile(r'[-+]0x[0-9a-f]+$')
RE_SUBRSP = re.compile(r'^sub\s+\$0x([0-9a-f]+),%rsp')

# Symbols that are not really calls: instrumentation the build inserts.
NOISE = {
    '__sanitizer_cov_trace_pc', '__stack_chk_fail', '__fentry__',
    'mcount', '__asan_report_load8_noabort',
}


def strip_suffix(sym):
    """gcc clones: foo.constprop.0, foo.isra.0, foo.part.0, foo.cold"""
    for suf in ('.constprop', '.isra', '.part', '.cold', '.localalias'):
        i = sym.find(suf)
        if i > 0:
            return sym[:i]
    return sym


def parse_object(path, keep_clones=False):
    """Disassemble one .o and return {symbol: record}.

    Two kinds of direct call have to be told apart, because objdump prints
    them identically apart from one detail:

      cross-TU / global target
          `call ab5 <do_dentry_open+0x5>` followed by a relocation line
          `R_X86_64_PLT32 path_get-0x4`. The inline annotation is the
          *unrelocated* placeholder -- it points just past the call site --
          and is meaningless. The relocation carries the real callee.

      file-local static target
          `call 9bb0 <path_openat>` with NO relocation: the assembler
          already resolved it. Here the inline annotation is the truth.

    So a call is held pending until we know whether a relocation follows.
    """
    out = subprocess.run(
        ['objdump', '-dr', '--no-show-raw-insn', path],
        capture_output=True, text=True, check=True).stdout

    funcs = {}
    cur = None
    pending = None      # inline symbol of a call whose reloc we are awaiting

    def commit(sym):
        if sym is None or cur is None:
            return
        sym = strip_suffix(RE_ADDEND.sub('', sym))
        if sym.startswith('__x86_indirect_thunk_'):
            # retpoline: an indirect call through a register, i.e. an
            # ->i_op/->f_op/->d_op dispatch. The thunk is the calling
            # convention, not the callee.
            cur['indirect'] += 1
        elif sym not in NOISE:
            cur['calls'][sym] = cur['calls'].get(sym, 0) + 1

    for line in out.splitlines():
        m = RE_FUNC.match(line)
        if m:
            commit(pending); pending = None
            name = m.group(2)
            key = name if keep_clones else strip_suffix(name)
            cur = funcs.setdefault(key, {
                'obj': os.path.basename(path),
                'clones': [],
                'insns': 0, 'frame': 0, 'pushes': 0,
                'calls': {},
                'indirect': 0,
                'atomics': defaultdict(int),
                'pause': 0,
                'in_prologue': True,
            })
            if name not in cur['clones']:
                cur['clones'].append(name)
            cur['in_prologue'] = True
            continue

        if cur is None:
            continue

        m = RE_RELOC.match(line)
        if m:
            if pending is not None:
                commit(m.group(3))      # reloc wins over the placeholder
                pending = None
            continue

        m = RE_INSN.match(line)
        if not m:
            continue

        commit(pending); pending = None   # no reloc followed: placeholder was real

        text = re.sub(r'\s+<[^>]*>$', '', m.group(2).strip()).strip()
        if not text:
            continue
        cur['insns'] += 1

        if text.startswith('lock '):
            cur['atomics'][text.split()[1].split()[0]] += 1
            cur['in_prologue'] = False
            continue

        mn = text.split()[0]
        if mn == 'pause':
            cur['pause'] += 1
        elif mn == 'push' and cur['in_prologue']:
            cur['pushes'] += 1
        elif mn == 'sub' and cur['in_prologue']:
            mm = RE_SUBRSP.match(text)
            if mm:
                cur['frame'] = int(mm.group(1), 16)
                cur['in_prologue'] = False
        elif mn == 'call':
            if '*' in text:
                cur['indirect'] += 1
            else:
                mm = re.search(r'<([^>]+)>', m.group(2))
                pending = mm.group(1) if mm else None
        elif mn.startswith('j') or mn == 'ret':
            # first branch ends the prologue. `call __fentry__` does not:
            # with CONFIG_FUNCTION_TRACER it precedes the pushes.
            cur['in_prologue'] = False

    commit(pending)

    for r in funcs.values():
        r['atomics'] = dict(r['atomics'])
        r.pop('in_prologue', None)
        r['stack'] = r['frame'] + 8 * r['pushes']
    return funcs


def sizes_from_symtab(path):
    """Byte size per FUNC symbol, from the ELF symbol table."""
    out = subprocess.run(['objdump', '-t', path],
                         capture_output=True, text=True, check=True).stdout
    sizes = {}
    for line in out.splitlines():
        if ' F .text' not in line:
            continue
        parts = line.split()
        try:
            size = int(parts[-2], 16)
        except (ValueError, IndexError):
            continue
        sizes[strip_suffix(parts[-1])] = size
    return sizes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('objects', nargs='+')
    ap.add_argument('-o', '--out', required=True, help='JSON output path')
    ap.add_argument('--keep-clones', action='store_true')
    args = ap.parse_args()

    graph = {}
    for obj in args.objects:
        if not os.path.exists(obj):
            print(f'missing: {obj}', file=sys.stderr)
            continue
        funcs = parse_object(obj, args.keep_clones)
        sizes = sizes_from_symtab(obj)
        for name, rec in funcs.items():
            rec['bytes'] = sizes.get(name, 0)
            if name in graph:
                # same symbol in two objects: keep the larger body
                if rec['insns'] <= graph[name]['insns']:
                    continue
            graph[name] = rec

    with open(args.out, 'w') as f:
        json.dump(graph, f, indent=1, sort_keys=True)
    print(f'{len(graph)} functions -> {args.out}')


if __name__ == '__main__':
    main()
