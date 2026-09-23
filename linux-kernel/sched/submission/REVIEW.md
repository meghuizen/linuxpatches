# sched submission review

## Runtime result, 2026-09-23: REMOVED (no measurable difference)

pt-eevdf, 2 boots interleaved with 8 base boots (patchtest campaign,
/usr/src/kbench/results/patchtest-*pt-eevdf*), sched_yield loop, L1D
misses per switch:

| tasks | base median (spread) | pt-eevdf boots |
|---|---|---|
| 128 | 131.3 (22.5%) | 122.1, 128.6 |
| 256 | 134.3 (9.6%) | 128.3, 132.9 |
| 512 | 140.2 (8.1%) | 168.5, 143.4 |

Kernel instructions per switch equal within 1.4% at every N, as expected
for a layout-only patch.  The 512-task 168.5 is one boot; the second
boot is mid-range of the 23 boots of kernels that do not touch the
scheduler (136.6-151.4).  So no regression, but no improvement beyond
the spread either, which by the patch's own rule (TESTS-TO-RUN: no
difference at N=512 -> DROP) means removal.  The cover letter and patch
are in removed/.  The static analysis below (fewer lines touched on the
pick walk) stands; the effect is below what this host can resolve.


Base `518e5b794c06`, worktree `/usr/src/sub-sched`, branch `sub-sched`.

The repo publishes two patches (`e27f20d21912` wake_entry, `254fca877d53`
EEVDF grouping). After making them standalone and checking them, the series
is **one patch, posted as RFC**:

| # | subject | recommendation | impact | evidence |
|---|---------|----------------|--------|----------|
| 1/1 | sched/fair: Reorder struct sched_entity for the EEVDF tree walk (reworked from `254fca877d53`) | **RFC** (HOLD as a non-RFC until TESTS-TO-RUN Test 2 runs) | low -- CFS pick/enqueue with many runnable tasks per CPU; not demonstrated | static analysis only (pahole + access lists), 5 configs; never booted |
| -- | sched: keep wake_entry off a cacheline boundary in task_struct (`e27f20d21912`) | **DROP** | none shown; likely a small regression on queued wakeups | static analysis; standalone form in `dropped/` |

Nothing here has been booted or measured. Every scheduler measurement in
`/usr/src/kbench/results` (the `scheduler: switch and wakeup`,
`eevdf pick depth` and `cross-cpu wakeup storm` sections of the `full` and
`everything` reports) was taken on kernels carrying the OLD sched pair
(`sched: keep sched_class adjacent to sched_entity` + `sched: put
nr_cpus_allowed and cpus_ptr on the wakeup cachelines`; commits
`f38b6e5429c7/29488dcc6e44`, `849b67a89c4e/74647f88907c`,
`7d5060a31430/5d2889a8030b` in the measured trees). None of it is cited for
either patch here.

---

## 1/1 sched/fair: Reorder struct sched_entity for the EEVDF tree walk

**Recommendation: RFC.** The layout reduces lines touched on the pick walk
and touches no more lines on any other path checked, in any config
checked, but that is a static count. It goes out as RFC, or is held, until
the Test 2 in TESTS-TO-RUN.md shows L1 misses per switch falling with N.

**Impact:** low -- CFS `pick_eevdf()`/enqueue cost when many tasks are
runnable on one CPU; benefit not demonstrated.

**What kind of patch:** improves something by itself (fewer lines on the
tree walk); not a preparatory patch. It does not depend on the dropped
wake_entry patch or on the old sched pair.

**Evidence status:** static analysis only.
- `tests/results/pahole-sched_entity-<cfg>.txt`: sizes and offsets, five
  configs (x86_64 FGS; x86_64 no-FGS; i386 M686 FGS, se 32-byte aligned
  at @96; i386 L1_CACHE_SHIFT=6 FGS; i386 M686 no-FGS).
  `sizeof(struct sched_entity)` and `sizeof(struct task_struct)`
  unchanged in all five; se offset unchanged.
- `tests/results/linemap-diff-<cfg>.txt`: task_struct 0 lines change
  membership in every config; sched_entity lines reviewed below.
- `tests/results/se-lines-<cfg>.txt`: per access pattern, lines touched
  before/after at absolute task_struct offsets. Exit 0 (nothing worse) in
  all five configs at 64-byte lines, M686 also at 32-byte lines.
- No runtime data exists for this patch.

x86_64, FAIR_GROUP_SCHED=y (lines touched, before -> after):

| pattern | lines |
|---|---|
| pick_eevdf() heap search, per entity | 3 -> 1 |
| min_vruntime_update() augment, per entity | 3 -> 2 |
| rbtree insert walk, per entity | 1 -> 1 |
| update_curr() on a task | 4 -> 3 |
| update_curr() on a group se | 3 -> 1 |
| update_se() via update_curr_common() (rt, dl, scx, stop) | 2 -> 1 |
| PELT, task se / group se | 4 -> 3 / 4 -> 4 |
| enqueue, dequeue, set_next_entity | 5 -> 4 each |
| detach_tasks() scan, per task | 3 -> 2 |
| set_task_cpu() on migration | 3 -> 3 |

32-bit: pick 2 -> 1 (L1_SHIFT=6) and 3 -> 2 (M686); everything else same or
better. x86_64 no-FGS: pick 3 -> 1, augment 3 -> 2, rest same.

### Who writes each changed line (x86_64 FGS, se-relative lines; se @128)

All writes to a queued entity happen under its rq lock (local CPU, a remote
waker doing a non-wakelist enqueue, or the load balancer), so there is no
lockless false sharing inside sched_entity to create or remove; the cost is
the number of lines a lock holder fetches. The exceptions are
`set_task_cpu()` (waker holding pi_lock, task not queued: writes avg,
nr_migrations, cfs_rq, parent, depth) and lockless remote reads
(`select_task_rq_fair()` reading avg and cfs_rq of the wakee;
`ttwu_runnable()` reading sched_delayed).

- line 0: now run_node, deadline, vruntime, min_vruntime, vlag, slice
  (lost load, h_load). Written by tree ops (run_node, min_vruntime) of the
  rq-lock holder, and for curr (which is not in the tree) by update_curr()
  on its own CPU. h_load/load moved off: they are read by update_curr()
  (calc_delta_fair) and PELT, not by the walk.
- line 1: min_slice, max_slice (kept), + h_load, vprot,
  prev_sum_exec_runtime, load. min/max_slice written by augment under rq
  lock; h_load/load written only by reweight_entity() under rq lock;
  vprot/prev_sum by set_next_entity()/update_curr() locally.
- line 2: + on_rq/sched_delayed/rel_deadline/custom_slice, exec_start,
  sum_exec_runtime, group_node, my_q, parent, cfs_rq. exec_start/sum are
  written by the running CPU on every update_curr(); at base they were also
  on the line holding group_node and the flags (line 1), so the detach_tasks
  reader sees the same writer mix as before. my_q/parent/cfs_rq are
  read-mostly (set_task_rq on migration); lockless remote reader
  (select_task_rq_fair -> sync_entity_load_avg reads cfs_rq) runs only
  after the wakee is off-CPU (smp_cond_load_acquire(&p->on_cpu, !VAL)),
  so it does not race with that task's own update_curr().
- line 3: depth, runnable_weight, nr_migrations (lost cfs_rq, my_q).
  nr_migrations/depth written by set_task_cpu(); runnable_weight only for
  group entities by se_update_runnable() under rq lock.
- line 4: avg, alone, unchanged.

Uncontended single-threaded case: one task on one CPU never walks a tree
(`h_nr_queued == 1` early return in pick_eevdf()); its paths are
update_curr (4 -> 3 lines), PELT (4 -> 3), set_next/put_prev (5 -> 4),
update_curr_common for non-fair classes (2 -> 1). None touches more lines.
Code: bloat-o-meter fair.o -97 bytes, core.o +3 bytes on x86_64 (shorter
or longer displacements; no logic change).

All scheduling classes: rt, deadline, stop and sched_ext only use
exec_start, sum_exec_runtime, prev_sum_exec_runtime and my_q (via
update_se()/entity_is_task()) of se; these are now on one line
(2 -> 1 on x86_64 FGS; 1 -> 1 elsewhere). sched_ext BPF schedulers access
se fields through CO-RE relocations, so order does not matter to them.

### Differences from the published 254fca877d53 (and why)

The published version, checked with the same tooling, regressed three
patterns and rests on a wrong premise:
- detach_tasks() scan 2 -> 3 lines on x86_64 no-FGS and i386 no-FGS: it
  moved group_node away from exec_start/sched_delayed.
- min_vruntime_update() 2 -> 3 and set_task_cpu() 2 -> 3 on i386
  L1_SHIFT=6 (max_slice straddles; nr_migrations off the cfs_rq line).
- Its changelog/comment says h_load "is written by the load balancer from
  a remote CPU". In this tree `se->h_load` is the EEVDF weight used by
  calc_delta_fair(), avg_vruntime(), vruntime_eligible() and
  sum_w_vruntime_add/sub(), and is written only in reweight_eevdf()
  (`update_load_set(&se->h_load, weight)`) under the rq lock. It put h_load
  alone on line 3 on x86_64.
The first 64 bytes (the six pick fields) are kept as published; the rest was
reordered with a layout model (`tests/layout-model.py`, validated against
pahole on all five builds) so that no pattern gets worse in any config,
using a single `#ifdef CONFIG_FAIR_GROUP_SCHED` block.

### What a maintainer is likely to object to

- "No numbers." Not answered; that is why it is RFC. TESTS-TO-RUN Test 2
  is the answer.
- "The access lists are yours; you may have missed a reader." Partly
  answered: lists are in the cover letter, taken from the named functions,
  and the count script is reproducible. A missed hot reader of a moved
  field is the main correctness-of-claim risk.
- "Churn in a core struct / conflicts with in-flight EEVDF work." Not
  answerable by us; applies to any reorder.
- "On M686 the pick fields still span two lines." True (3 -> 2); stated in
  the changelog notes.
- Commit subject/prefix style: tip uses `sched/fair: Capitalised verb`,
  followed here.

### Correctness risks checked

- No code depends on sched_entity member order: no `offsetof()` on
  sched_entity or on `task_struct.se` members, no subrange memset/memcpy,
  no asm-offsets entries; `init_task` uses designated initialisers;
  `__sched_fork()` assigns by name; the rbtree uses rb_entry/container_of.
- `avg` keeps `____cacheline_aligned` and its offset (hence sizeof).
- Compiles without new warnings: kernel/sched/{core,fair,build_policy,
  build_utility}.o, kernel/fork.o, init/init_task.o for x86_64, i386 and
  x86_64 no-FGS.
- checkpatch --strict: 1 error, "Missing Signed-off-by" -- intentional,
  the submitter adds it. 0 warnings, 0 checks.
- Not checked: 128-byte-line architectures with their own build (only a
  128-byte proxy count on the x86_64 layout, which shows no regression),
  other 32-bit architectures, RANDSTRUCT (fields are shuffled anyway).

---

## DROPPED: sched: keep wake_entry off a cacheline boundary in task_struct

**Recommendation: DROP.** It cannot be made standalone without either
re-partitioning half of task_struct or moving a hot field onto a worse
line, and the problem it describes does not exist in the form described.

**Why the published patch does not apply:** it moves `cpus_ptr` from the
8-byte hole before `se`, where `95c81df7d1ee` had put it. At base
`cpus_ptr` is at @1496 (line 23).

**Standalone versions measured** (`tests/results/p1-*`):
- cpus_ptr moved from @1496 to before wake_entry
  (`dropped/wake_entry-standalone-DROPPED.diff`): wake_entry 56 -> 64, but
  removing cpus_ptr from line 23 shifts the tail by 8 bytes: **31 of 61
  task_struct lines change membership** (thread_struct 3712 -> 3704).
- Also folding 95c81df's nr_cpus_allowed move: 35 of 61.
- The old commits are not required: nothing in the wake_entry change needs
  the sched_class move (798c5fc) at all, and the cpus_ptr move only
  supplied 8 bytes of filler.

**Is the cpus_ptr move useful by itself?** No. Every reader dereferences
it: `cpumask_test_cpu(cpu, p->cpus_ptr)` in ttwu_queue_cond(),
is_cpu_allowed() and can_migrate_task() reads `p->cpus_mask` @1512, which
stays on line 23 together with nr_cpus_allowed @1488 and
migration_disabled @1528 (both also read by select_task_rq()). Moving the
pointer saves no line on any of these paths. The README's "can_migrate_task
reads one line here where it read two" ignores the dereference.

**Is the straddle a problem?** At base on x86_64, wake_entry is @56..71:
`llist.next` (the only word written on a wakeup, by llist_add() on the
waker) is @56..63 on line 0; `u_flags` @64 on line 1 is written once at
fork (`__sched_fork`) and only read afterwards (CSD_TYPE() in
`__flush_smp_call_function_queue()` on the target); src/dst are not used
for TTWU. On a queued wakeup:
- waker CPU writes `p->__state = TASK_WAKING` (line 0) in try_to_wake_up()
  *before* ttwu_queue_wakelist(), then `llist.next` (line 0); on the
  post-select path set_task_cpu() writes thread_info.cpu (line 0) and
  wake_cpu (line 1), and select_idle_sibling() may write recent_used_cpu
  (line 1).
- target CPU (for WF_ON_CPU also the CPU still switching p out, which
  writes on_cpu = 0 in finish_task(), line 0) reads llist/u_flags and
  writes on_rq and __state (line 0).
So line 0 is dirtied by the waker on every wakeup regardless of wake_entry
(the README's "one queued wakeup invalidates the running CPU's state line"
is true with or without the patch). Moving wake_entry to 64..79 puts
`llist.next` on line 1, which the waker then dirties on every queued
wakeup, where at base it did so only when wake_cpu/recent_used_cpu
changed; line 1 is otherwise written by the task itself (record_wakee():
wakee_flips, last_wakee, wakee_flip_decay_ts). Net: no line removed from
the waker's write set, one added in the common case. Likely neutral to
slightly negative; not measured.

**Other reorders considered, all rejected:**
- wakee_flips before wake_entry (only lines 0/1 change): puts a field that
  record_wakee() writes on every flip onto line 0, which mutex/rwsem
  optimistic spinners poll remotely (owner->on_cpu); also shrinks
  task_struct by 64 bytes under MEM_ALLOC_PROFILING, a separate change.
- `stack` after wake_entry (wake_entry fully on line 0): x86_64
  __switch_to() reads `next_p->stack` (task_top_of_stack()) every context
  switch -> +1 line on the switch path.
- `usage`+`ptrace` after wake_entry: wake_q_add()/wake_up_q() get/put the
  refcount from the waker -> +1 remotely dirtied line on wake_q wakeups.

Configs where it does nothing: i386 (wake_entry @44..51, no straddle, both
cache-shift settings) and x86_64 with MEM_ALLOC_PROFILING (wake_entry @72,
already on the same line as on_cpu; the patch leaves it there).

---

## Existing data and documents found wrong or misattributed

- All scheduler runtime data in `/usr/src/kbench/results` is for the OLD
  pair (see top). `tree-bench.sh` labels its section
  `### scheduler: switch and wakeup (patches 1, 2)` with comments naming
  the sched_class and nr_cpus_allowed/cpus_ptr patches -- that is the old
  pair, not the published one.
- `linux-kernel/sched/README.md`:
  - "h_load ... is written by the load balancer from whichever CPU is
    balancing" -- false in this tree (see 1/1 above).
  - "Blast radius: 2 of task_struct's 60 cachelines" for the wake_entry
    patch -- measured on top of 95c81df, not on the base; standalone it is
    31 of 61.
  - "task_struct 3840 bytes" -- a different config; 3904 with the prepared
    x86_64 config.
  - "EEVDF pick set 2 lines -> 1 on i386" -- only where se is 64-byte
    aligned (L1_CACHE_SHIFT=6); with M686 (the i386 defconfig) se is at @96
    and it is 3 -> 2 counted at absolute offsets.
  - can_migrate_task / cpus_ptr line saving -- see DROPPED section.
- `/usr/src/kbench/scripts/verify-sched-layout.py` encodes the h_load
  premise, and computes sched_entity lines se-relative, which is wrong for
  M686 where se is not 64-byte aligned. Its "PATCH A" checks fail against
  this series by design (patch dropped).
- The published 254fca877d53 regressed three access patterns (see 1/1).

## Checkpatch and identity

- `checkpatch.pl --strict` on `0001-*.patch`: only "Missing
  Signed-off-by" (intentional). Cover letter not checkpatched (not a patch).
- Author/committer on the worktree commit and in the exported files:
  `Michiel <367462+meghuizen@users.noreply.github.com>`.
- Identity grep (the two forbidden address patterns from the brief) over submission/: no matches.
