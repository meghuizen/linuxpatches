#!/usr/bin/env python3
"""se-lines.py <before.o> <after.o> [line_bytes]

Count the distinct cachelines of task_struct that each sched_entity access
pattern touches, before and after a layout change. Offsets are absolute
(offsetof(task_struct, se) + offsetof(sched_entity, field)), so configs
where se is not 64-byte aligned inside task_struct (i386 M686, where it
is 32-byte aligned) are handled correctly.

The field sets below are hand-derived from the named functions in
kernel/sched/{fair,core,pelt}.c at 518e5b794c06. Fields absent in a config
(e.g. my_q/parent/cfs_rq without CONFIG_FAIR_GROUP_SCHED) are skipped.
Exit status 1 if any pattern touches more lines after than before.
"""
import re
import subprocess
import sys

FLD = re.compile(r'^\s+.*?([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[0-9]*\])?;\s*'
                 r'/\*\s*(\d+)\s+(\d+)\s*\*/')


def members(obj, struct):
    out = subprocess.run(["pahole", "-C", struct, obj], capture_output=True,
                         text=True, check=True).stdout
    res = {}
    for ln in out.splitlines():
        ln = re.sub(r'__attribute__.*?(?=;)', '', ln)
        m = FLD.match(ln)
        if m:
            res[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return res


PATHS = [
    ("pick_eevdf() heap search, per entity visited",
     "run_node vruntime min_vruntime"),
    ("rb insert walk (__entity_less), per entity visited",
     "run_node deadline"),
    ("augment propagate/rotate (min_vruntime_update), per entity",
     "run_node vruntime slice min_vruntime min_slice max_slice"),
    ("update_curr() on a task se (+update_se, update_deadline, "
     "protect_slice, update_curr_fair walk)",
     "exec_start sum_exec_runtime my_q vruntime h_load deadline "
     "custom_slice slice vprot on_rq parent cfs_rq"),
    ("update_curr() on a group se",
     "exec_start sum_exec_runtime my_q parent cfs_rq"),
    ("update_se() via update_curr_common() (rt, dl, scx, stop)",
     "exec_start sum_exec_runtime my_q"),
    ("PELT __update_load_avg_se() on a task se",
     "avg on_rq sched_delayed my_q load"),
    ("PELT __update_load_avg_se() on a group se",
     "avg on_rq sched_delayed my_q runnable_weight load"),
    ("enqueue of a waking task (place_entity, enqueue_entity, "
     "__enqueue_entity)",
     "custom_slice slice h_load vlag vruntime rel_deadline deadline avg "
     "on_rq sched_delayed my_q load group_node exec_start cfs_rq parent "
     "min_vruntime min_slice max_slice run_node"),
    ("dequeue of a sleeping task (update_entity_lag, dequeue_entity, "
     "__dequeue_entity)",
     "sched_delayed vlag vruntime h_load avg on_rq my_q load group_node "
     "run_node cfs_rq parent min_vruntime min_slice max_slice slice"),
    ("set_next_entity() + set_protect_slice()",
     "on_rq avg load my_q exec_start sum_exec_runtime prev_sum_exec_runtime "
     "run_node min_vruntime min_slice max_slice deadline slice vruntime "
     "h_load vprot"),
    ("detach_tasks() scan, per task (group_node walk, can_migrate_task, "
     "task_hot, task_h_load)",
     "group_node sched_delayed exec_start cfs_rq avg"),
    ("set_task_cpu() on migration (migrate_task_rq_fair, set_task_rq)",
     "avg nr_migrations cfs_rq parent depth"),
]


def lines(ts, se, names, lb):
    base = ts["se"][0]
    got, missing = set(), []
    for n in names.split():
        if n not in se:
            missing.append(n)
            continue
        off, sz = se[n]
        a = base + off
        got.update(range(a // lb, (a + max(sz, 1) - 1) // lb + 1))
    return got, missing


def main():
    before, after = sys.argv[1], sys.argv[2]
    lb = int(sys.argv[3]) if len(sys.argv) > 3 else 64
    tb, ta = members(before, "task_struct"), members(after, "task_struct")
    sb, sa = members(before, "sched_entity"), members(after, "sched_entity")
    print(f"se @{tb['se'][0]} -> @{ta['se'][0]} in task_struct, "
          f"{lb}-byte lines, task_struct lines are absolute")
    worse = 0
    for desc, names in PATHS:
        lb_, miss = lines(tb, sb, names, lb)
        la_, _ = lines(ta, sa, names, lb)
        mark = "WORSE" if len(la_) > len(lb_) else (
            "better" if len(la_) < len(lb_) else "same")
        worse += len(la_) > len(lb_)
        print(f"  {len(lb_)} -> {len(la_)}  {mark:6}  {desc}")
        print(f"         before {sorted(lb_)}  after {sorted(la_)}"
              + (f"  (absent: {' '.join(miss)})" if miss else ""))
    print(f"\nse members by absolute task_struct line ({lb}-byte), "
          "lines whose membership changed:")
    def amap(ts, se):
        m = {}
        for n, (off, sz) in se.items():
            a = ts["se"][0] + off
            for ln in range(a // lb, (a + max(sz, 1) - 1) // lb + 1):
                m.setdefault(ln, set()).add(n)
        return m
    mb, ma = amap(tb, sb), amap(ta, sa)
    for ln in sorted(set(mb) | set(ma)):
        b, a = mb.get(ln, set()), ma.get(ln, set())
        if a != b:
            print(f"  line {ln}: + {' '.join(sorted(a - b)) or '-'}")
            print(f"  {' ' * len(str(ln))}       - {' '.join(sorted(b - a)) or '-'}")
            print(f"  {' ' * len(str(ln))}       = {' '.join(sorted(a & b)) or '-'}")
    return 1 if worse else 0


if __name__ == "__main__":
    sys.exit(main())
