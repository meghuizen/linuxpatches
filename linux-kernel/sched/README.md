# Scheduler cacheline placement

Two patches against **Linux 7.3-rc3**. Both are field reorders: no logic
changes, no size changes, no behaviour change for any scheduling class.

| # | Change |
|---|---|
| 1 | Keep `wake_entry` off a cacheline boundary in `task_struct` |
| 2 | Group the EEVDF fields of `sched_entity` onto one cacheline |

## What they fix

**Patch 1.** On x86_64 the fields before `wake_entry` total 56 bytes, so
the 16-byte node straddles the line at 64. `ttwu_queue_wakelist()` writes
it from the *waker's* CPU, which therefore takes exclusive ownership of a
line that also holds `on_cpu`, `on_rq` and `__state` — fields the CPU
actually running the task writes on every context switch. One queued
wakeup invalidates the running CPU's state line.

`cpus_ptr` moves in front of it. It is read-mostly, written only on an
affinity change, and `select_task_rq()` already reads that line on the
same wakeup. `can_migrate_task()` reads `p->cpus_ptr` and
`task_on_cpu()`→`p->on_cpu` in the same call, so the load balancer reads
one line here where it read two.

**Patch 2.** The six fields `pick_eevdf()` compares — `run_node`,
`deadline`, `vruntime`, `min_vruntime`, `vlag`, `slice` — were spread over
three cachelines on x86_64 and two on i386. A tree descent is O(log n)
deep, so that was that many lines at every level. They total exactly 64
bytes on 64-bit, and `sched_entity` is already 64-byte aligned, so putting
them first gives them a line to themselves.

`h_load` was on the pick line on both architectures and is written by the
load balancer from whichever CPU is balancing; it moves to the third line.
`avg` keeps its alignment and its own line, because PELT updates it from
whichever CPU last ran the entity.

## Verified

`pahole` against built objects, both architectures:

| | x86_64 | i386 |
|---|---|---|
| `wake_entry` | lines 0–1 → line 1 | @44 → @48, no straddle either way |
| EEVDF pick set | 3 lines → 1 | 2 lines → 1 |
| `h_load` | line 0 → line 3 | @8 → @148 |
| `avg` | @256, sole occupant | unchanged |
| `task_struct` | 3840 bytes, unchanged | 2240 bytes, unchanged |
| `sched_entity` | 320 bytes, holes 3 → 1 | 224 bytes, unchanged |

**Blast radius: 2 of `task_struct`'s 60 cachelines change membership**,
both in patch 1. `sched_entity` keeps its size, so no offset after `se`
moves and patch 2 does not perturb `task_struct` at all.

`/usr/src/kbench/scripts/verify-sched-layout.py` takes two vmlinux or
object files and checks every claim above, including that no locally
written hot field shares `wake_entry`'s new line and that `avg` has no
line-sharers. `linemap-diff.py` prints every cacheline whose membership
changed, which is how the blast radius was measured rather than assumed.

## Not measured

There is no performance number here, and there should not be one until
someone runs `perf c2c` on hardware with a memory-event PMU. The proper
gate for a placement change is whether HITM traffic actually falls; WSL2
exposes no AMD IBS, so neither host nor guest can produce that data.
These are sent on the static evidence.

## A third patch that was dropped

Closing a 36-byte hole in front of `sched_statistics` looked worthwhile —
`sched_statistics` is 256 bytes that a default kernel never writes, since
`schedstat_enabled()` is a `DEFINE_STATIC_KEY_FALSE`. It was dropped after
measurement: it shifted every field after `stats` by 36 bytes,
re-partitioning **35 of 60 cachelines**, and `task_struct` did not get
smaller anyway because the 64-byte alignment rounds the total up either
way. Re-partitioning half the struct to reclaim holes that do not shrink
it is a bad trade when the requirement is not to disturb other workloads.

Also considered and rejected: unioning `sched_entity` with `sched_rt_entity`,
`sched_dl_entity` and `sched_ext_entity`, which would free 616 bytes per
task. It cannot be done. `p->se` is not CFS-private — `update_curr_common()`
operates on `&rq->donor->se` and is called from `rt.c`, `deadline.c` and
`stop_task.c`, and sched_ext reads `se.sum_exec_runtime` too. Unioning them
would silently corrupt runtime accounting for every non-CFS class.
