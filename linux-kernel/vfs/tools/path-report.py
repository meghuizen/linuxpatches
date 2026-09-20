#!/usr/bin/env python3
# path-report.py -- walk the static graph from a syscall entry point and
# report the shape of the path: who calls whom, how much code sits under
# each node, where the atomics are, and where the indirect dispatches are.
#
# There are no dynamic weights here on purpose. Profiling this workload in
# a nested VM produced numbers that were an artefact of the VM (see
# /usr/src/kbench/README.md), so the static structure is the part that can
# be trusted without a machine to measure on. Instruction counts are the
# code gcc emitted, not a prediction of time.
#
# SPDX-License-Identifier: GPL-2.0

import argparse
import json
import sys
from collections import defaultdict

# Leaves we do not descend into: allocator, printk, RCU bookkeeping, locking
# primitives. They are real cost but they are not VFS structure, and
# expanding them buries the shape we are looking at.
STOP = {
    'kmem_cache_alloc_noprof', 'kmem_cache_free', 'kfree', 'kmalloc_noprof',
    '_printk', 'printk', 'dump_stack', 'panic', 'warn_slowpath_fmt',
    '__rcu_read_lock', '__rcu_read_unlock', 'synchronize_rcu', 'call_rcu',
    '_raw_spin_lock', '_raw_spin_unlock', '_raw_spin_lock_irqsave',
    '_raw_spin_unlock_irqrestore', '_raw_read_lock', '_raw_write_lock',
    '__SCT__might_resched', '__might_sleep', 'might_resched',
    'percpu_counter_add_batch', '__percpu_counter_sum',
    'memcpy', 'memset', 'strlen', 'strncpy_from_user', '__memcpy',
    'capable', 'ns_capable',
}


def subtree(graph, root, stop=STOP, maxdepth=64):
    """Every function reachable from root, and the depth it was first seen."""
    seen = {}
    order = []
    stack = [(root, 0)]
    while stack:
        name, d = stack.pop()
        if name in seen or d > maxdepth:
            continue
        seen[name] = d
        order.append(name)
        if name in stop:
            continue
        rec = graph.get(name)
        if not rec:
            continue
        for callee in sorted(rec['calls'], reverse=True):
            if callee not in seen:
                stack.append((callee, d + 1))
    return seen, order


def totals(graph, names):
    t = dict(insns=0, bytes=0, atomics=0, indirect=0, pause=0,
             known=0, unknown=0, maxstack=0)
    atom_by_kind = defaultdict(int)
    for n in names:
        r = graph.get(n)
        if not r:
            t['unknown'] += 1
            continue
        t['known'] += 1
        t['insns'] += r['insns']
        t['bytes'] += r['bytes']
        t['indirect'] += r['indirect']
        t['pause'] += r['pause']
        t['maxstack'] = max(t['maxstack'], r['stack'])
        for k, v in r['atomics'].items():
            t['atomics'] += v
            atom_by_kind[k] += v
    return t, dict(atom_by_kind)


def tree(graph, root, depth, stop=STOP, prefix='', seen=None, out=sys.stdout):
    if seen is None:
        seen = set()
    rec = graph.get(root)
    if rec is None:
        out.write(f'{prefix}{root}  [external]\n')
        return
    flags = []
    if rec['atomics']:
        flags.append('atomic:' + ','.join(
            f'{k}x{v}' for k, v in sorted(rec['atomics'].items())))
    if rec['indirect']:
        flags.append(f"indirect:{rec['indirect']}")
    if rec['pause']:
        flags.append(f"pause:{rec['pause']}")
    tag = ('  ' + ' '.join(flags)) if flags else ''
    out.write(f"{prefix}{root}  insn={rec['insns']} stack={rec['stack']}{tag}\n")
    if depth <= 0 or root in stop or root in seen:
        return
    seen.add(root)
    kids = sorted(rec['calls'])
    for i, k in enumerate(kids):
        last = (i == len(kids) - 1)
        branch = '`- ' if last else '|- '
        cont = '   ' if last else '|  '
        out.write(prefix + branch[:0])
        tree(graph, k, depth - 1, stop,
             prefix + ('   ' if last else '|  '), seen, out)


def dot(graph, names, root, out):
    out.write('digraph vfs {\n')
    out.write('  rankdir=LR; node [shape=box, fontname="monospace", fontsize=9];\n')
    for n in sorted(names):
        r = graph.get(n)
        if r is None:
            out.write(f'  "{n}" [style=dashed, label="{n}\\n(external)"];\n')
            continue
        a = sum(r['atomics'].values())
        label = f"{n}\\ninsn={r['insns']} stk={r['stack']}"
        if a:
            label += f"\\natomics={a}"
        if r['indirect']:
            label += f"\\nindirect={r['indirect']}"
        colour = 'red' if a else ('orange' if r['indirect'] else 'black')
        pen = '2' if n == root else '1'
        out.write(f'  "{n}" [label="{label}", color={colour}, penwidth={pen}];\n')
    for n in sorted(names):
        r = graph.get(n)
        if not r or n in STOP:
            continue
        for c in sorted(r['calls']):
            if c in names:
                out.write(f'  "{n}" -> "{c}";\n')
    out.write('}\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('graph')
    ap.add_argument('root')
    ap.add_argument('--depth', type=int, default=4)
    ap.add_argument('--dot')
    ap.add_argument('--top', type=int, default=25)
    args = ap.parse_args()

    graph = json.load(open(args.graph))
    seen, order = subtree(graph, args.root)
    t, kinds = totals(graph, order)

    print(f'=== {args.root} ===')
    print(f"reachable: {len(order)} functions "
          f"({t['known']} in graph, {t['unknown']} external)")
    print(f"code under it: {t['insns']} instructions, {t['bytes']} bytes")
    print(f"atomics: {t['atomics']}  {kinds}")
    print(f"indirect dispatches: {t['indirect']}   cmpxchg retry loops: {t['pause']}")
    print(f"largest single frame: {t['maxstack']} bytes")
    print()

    print(f'--- {args.top} largest bodies under {args.root} ---')
    ranked = sorted((graph[n] ['insns'], n) for n in order if n in graph)
    for insns, n in ranked[::-1][:args.top]:
        r = graph[n]
        a = sum(r['atomics'].values())
        print(f'  {insns:5}  {n:42} stack={r["stack"]:4} '
              f'atomics={a} indirect={r["indirect"]} depth={seen[n]}')
    print()

    print(f'--- call tree, depth {args.depth} ---')
    tree(graph, args.root, args.depth)

    if args.dot:
        with open(args.dot, 'w') as f:
            dot(graph, set(order), args.root, f)
        print(f'\ndot -> {args.dot}')


if __name__ == '__main__':
    main()
