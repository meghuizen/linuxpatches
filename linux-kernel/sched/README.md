# Scheduler cacheline placement

Two patches were written against Linux 7.3-rc3 (518e5b794c06). Both are
field reorders: no logic changes, no size changes, no behaviour change for
any scheduling class. Neither is being submitted.

## Status

No scheduler patch goes upstream. Details in
[`submission/REVIEW.md`](submission/REVIEW.md); overall status in
[`../SUBMISSION-STATUS.md`](../SUBMISSION-STATUS.md).

| # | patch | outcome | file |
|---|---|---|---|
| 2 | EEVDF `sched_entity` reorder | removed, no measurable difference: measured alone on v7.3-rc3 (2 boots interleaved with 8 base boots), L1D misses per switch inside the base spread at 128/256 tasks; at 512 tasks one boot gave 168.5 (base median 140.2) and the second 143.4, so the first is one outlier boot; kernel instructions per switch equal within 1.4% | [`submission/removed/`](submission/removed/) |
| 1 | `wake_entry` placement | dropped before measurement: standalone it changes 31 of 61 `task_struct` lines, and it adds one line to the waker's write set on a queued wakeup instead of removing one | [`submission/dropped/`](submission/dropped/) |

The old export in `patches/` is superseded
([`patches/README.md`](patches/README.md)). The analysis below is kept; the
statements the review found wrong are marked.

## The two patches

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
same wakeup. The earlier claim that `can_migrate_task()` then reads one
line where it read two was wrong: every reader dereferences `cpus_ptr` to
`p->cpus_mask`, which stays on the old line, so no line is saved.

The review also found the premise weaker than stated: the waker dirties
line 0 on every wakeup anyway (`__state`), and moving `wake_entry` puts
`llist.next` on line 1, adding a line to the waker's write set.

**Patch 2.** The six fields `pick_eevdf()` compares — `run_node`,
`deadline`, `vruntime`, `min_vruntime`, `vlag`, `slice` — were spread over
three cachelines on x86_64 and two on i386. A tree descent is O(log n)
deep, so that was that many lines at every level. They total exactly 64
bytes on 64-bit, and `sched_entity` is already 64-byte aligned, so putting
them first gives them a line to themselves.

`h_load` was on the pick line on both architectures and moves to the third
line. (The earlier reason given, that the load balancer writes it from
whichever CPU is balancing, is false in this tree; see
`submission/REVIEW.md`.)
`avg` keeps its alignment and its own line, because PELT updates it from
whichever CPU last ran the entity.

## Verified

`pahole` against built objects, both architectures:

| | x86_64 | i386 |
|---|---|---|
| `wake_entry` | lines 0–1 → line 1 | @44 → @48, no straddle either way |
| EEVDF pick set | 3 lines → 1 | 2 lines → 1 only with L1_CACHE_SHIFT=6; with M686 (i386 defconfig, `se` at @96) 3 → 2 |
| `h_load` | line 0 → line 3 | @8 → @148 |
| `avg` | @256, sole occupant | unchanged |
| `task_struct` | 3840 bytes, unchanged (a different config; 3904 with the prepared x86_64 config) | 2240 bytes, unchanged |
| `sched_entity` | 320 bytes, holes 3 → 1 | 224 bytes, unchanged |

Blast radius: 2 of `task_struct`'s 60 cachelines change membership, both
in patch 1, but that was measured on top of an older patch (95c81df);
standalone on the base it is 31 of 61. `sched_entity` keeps its size, so
no offset after `se` moves and patch 2 does not perturb `task_struct` at
all.

`/usr/src/kbench/scripts/verify-sched-layout.py` takes two vmlinux or
object files and checks every claim above, including that no locally
written hot field shares `wake_entry`'s new line and that `avg` has no
line-sharers. `linemap-diff.py` prints every cacheline whose membership
changed, which is how the blast radius was measured rather than assumed.

## Measurement

This section was written before the per-patch campaign. `perf c2c` on
hardware with a memory-event PMU is still not available (WSL2 exposes no
AMD IBS). The EEVDF patch was later measured with L1D misses per switch in
a nested KVM guest and showed no difference beyond the base spread (see
Status). Neither patch is sent.

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
