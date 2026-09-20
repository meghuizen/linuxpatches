#!/usr/bin/env python3
# cascade.py -- leverage analysis over the static VFS graph.
#
# The question this answers is not "what is slow" -- the graph cannot know
# that. It is "where does a change pay off in more than one place", which is
# a structural property and which the graph does know.
#
# Three numbers per function:
#
#   breadth   how many of the VFS syscall entry points can reach it. A
#             function with breadth 40 sits on the shared spine: making it
#             cheaper makes forty syscalls cheaper. A function with breadth 1
#             is a leaf of one syscall and worth exactly that one syscall.
#   fanin     how many distinct functions call it. High fan-in with low
#             breadth means an internal helper of one subsystem; high fan-in
#             AND high breadth means a genuine chokepoint.
#   pressure  breadth x (atomic RMWs in the body). Atomics are the operations
#             that cost a cache line, so this ranks where the shared-line
#             traffic is concentrated across the whole syscall surface.
#
# None of this is a measurement. It is a map of where leverage exists, to be
# checked against execution counts before anything is believed.
#
# SPDX-License-Identifier: GPL-2.0

import argparse
import json
from collections import defaultdict

STOP = {
    'kmem_cache_alloc_noprof', 'kmem_cache_free', 'kfree', 'kmalloc_noprof',
    '_printk', 'printk', 'dump_stack', 'panic',
    '__rcu_read_lock', '__rcu_read_unlock', 'synchronize_rcu', 'call_rcu',
    '_raw_spin_lock', '_raw_spin_unlock', 'memcpy', 'memset',
    '__SCT__might_resched',
}


def reachable(graph, root, stop=STOP):
    seen, stack = set(), [root]
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        if n in stop:
            continue
        r = graph.get(n)
        if r:
            stack.extend(c for c in r['calls'] if c not in seen)
    return seen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('graph')
    ap.add_argument('--top', type=int, default=30)
    ap.add_argument('--min-breadth', type=int, default=2)
    ap.add_argument('--syscall-table', action='store_true',
                    help='per-syscall cost table instead of the rankings')
    args = ap.parse_args()

    g = json.load(open(args.graph))

    roots = sorted(n for n in g if n.startswith('__x64_sys_'))
    # fan-in over the whole graph
    fanin = defaultdict(set)
    for name, r in g.items():
        for c in r['calls']:
            fanin[c].add(name)

    breadth = defaultdict(int)
    per_root = {}
    for root in roots:
        s = reachable(g, root)
        per_root[root] = s
        for n in s:
            breadth[n] += 1

    def rec(n):
        return g.get(n, {'insns': 0, 'atomics': {}, 'indirect': 0, 'obj': '-'})

    if args.syscall_table:
        rows = []
        for root in roots:
            s = per_root[root]
            ins = sum(rec(n)['insns'] for n in s)
            at = sum(sum(rec(n)['atomics'].values()) for n in s)
            ind = sum(rec(n)['indirect'] for n in s)
            rows.append((ins, root[len('__x64_sys_'):], len(s), at, ind))
        rows.sort(reverse=True)
        print(f"{'syscall':24} {'funcs':>6} {'insns':>8} {'atomics':>8} {'indirect':>9}")
        for ins, name, nf, at, ind in rows[:args.top]:
            print(f'{name:24} {nf:6} {ins:8} {at:8} {ind:9}')
        return

    print(f'=== shared spine: reachable from the most syscalls ===')
    print(f"{'function':38} {'breadth':>7} {'fanin':>6} {'insns':>6} {'atom':>5} {'obj'}")
    ranked = sorted(breadth.items(), key=lambda kv: (-kv[1], -rec(kv[0])['insns']))
    for n, b in ranked[:args.top]:
        r = rec(n)
        print(f"{n:38} {b:7} {len(fanin[n]):6} {r['insns']:6} "
              f"{sum(r['atomics'].values()):5} {r['obj']}")

    print(f'\n=== atomic pressure: breadth x lock-prefixed ops ===')
    press = []
    for n, b in breadth.items():
        a = sum(rec(n)['atomics'].values())
        if a and b >= args.min_breadth:
            press.append((b * a, b, a, n))
    press.sort(reverse=True)
    print(f"{'function':38} {'press':>6} {'breadth':>7} {'atomics':>7} {'obj'}")
    for p, b, a, n in press[:args.top]:
        print(f'{n:38} {p:6} {b:7} {a:7} {rec(n)["obj"]}')

    print(f'\n=== indirect dispatch pressure: breadth x retpoline sites ===')
    ind = []
    for n, b in breadth.items():
        i = rec(n)['indirect']
        if i and b >= args.min_breadth:
            ind.append((b * i, b, i, n))
    ind.sort(reverse=True)
    for p, b, i, n in ind[:args.top]:
        print(f'{n:38} {p:6} {b:7} {i:7} {rec(n)["obj"]}')

    print(f'\n=== fan-in leaders (reuse already happening) ===')
    fl = sorted(((len(v), k) for k, v in fanin.items() if k in g), reverse=True)
    for c, n in fl[:args.top]:
        r = rec(n)
        print(f'{n:38} {c:6} callers  breadth={breadth.get(n,0):3} '
              f"insns={r['insns']:5} {r['obj']}")


if __name__ == '__main__':
    main()
