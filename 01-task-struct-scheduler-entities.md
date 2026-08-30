# Task 1 — Keep the scheduler's hot fields together in `task_struct`

**What the patch does, in one sentence:** it moves 504 bytes of data that a normal task never uses (`rt`, `dl`, `scx`) out from between two fields the scheduler reads on every context switch (`se` and `sched_class`), so the scheduler touches ~5 cache lines instead of ~12.

| | |
|---|---|
| Target file | `include/linux/sched.h` (Stage A: this file only) |
| Kernel | Linux 7.2, vanilla, `/mnt/data/linux-src/linux-7.2` |
| Patch size | Stage A: reorder only, ~10 lines. Stage B: ~89 call sites + lifetime code |
| Risk | Stage A: low. Stage B: medium |
| Realistic gain | Low single-digit percent on context-switch-heavy workloads |

---

## 1. Background: why field order matters at all

A CPU cannot read one byte from RAM. It always reads a **cache line**: 64 bytes on x86-64. Need an 8-byte pointer? The CPU fetches the whole 64-byte line around it and keeps it in its cache.

So the cost of using a struct is not "how many bytes did I read". It is **"how many different 64-byte lines did I touch"**. Each line that is not already in cache costs roughly 100-300 CPU cycles to fetch from RAM.

That gives one rule you can apply everywhere:

> Fields used together should live together.
> Fields never used together should live apart.

`struct task_struct` is the kernel's "one per thread" object. The scheduler reads parts of it on **every context switch**, thousands to millions of times per second. Its layout matters more than almost any other struct in the kernel.

---

## 2. The problem, with evidence

Linux supports several scheduling classes. Each class stores its per-task state in its own "entity" struct, and `task_struct` embeds **all of them, always**, whether the task uses that class or not (`include/linux/sched.h:880-887`):

```c
	struct sched_entity		se;          /* fair (EEVDF) - the default    */
	struct sched_rt_entity		rt;          /* SCHED_FIFO / SCHED_RR only    */
	struct sched_dl_entity		dl;          /* SCHED_DEADLINE only           */
	struct sched_dl_entity		*dl_server;
#ifdef CONFIG_SCHED_CLASS_EXT
	struct sched_ext_entity		scx;         /* only if a BPF scheduler runs  */
#endif
	const struct sched_class	*sched_class;
```

Measured sizes (`pahole` against the running kernel's type info):

| Field | Size | Who actually uses it |
|---|---|---|
| `se` | 256 B | every normal task — **hot on every switch** |
| `rt` | 48 B | realtime tasks only |
| `dl` | 248 B | deadline tasks only |
| `dl_server` | 8 B | fair path (deadline-server mechanism) |
| `scx` | 208 B | only when a BPF scheduler is loaded |
| `sched_class` | 8 B | every task — **hot on every switch** |

Nearly every task on a normal system is a fair-class task. For those tasks, `rt` + `dl` + `scx` = **504 bytes that are allocated, zeroed, and then never read** — and they sit exactly between the two fields the scheduler needs.

As cache lines:

```
lines  2-5   se            read every switch
lines  6-13  rt, dl, scx   504 bytes a normal task never reads
line   14    sched_class   read every switch
```

`__schedule()` wants `p->se` and `p->sched_class`. To get both it spans 12 cache lines. Eight of them carry nothing it needs.

Whole struct for scale: **14016 bytes, 219 cache lines, 273 members, 165 bytes of padding holes** (measured with the running config; your config will differ — always re-measure).

### Reproduce it yourself

```bash
cd /mnt/data/linux-src/linux-7.2
sed -n '880,887p' include/linux/sched.h

pahole -C task_struct /sys/kernel/btf/vmlinux | \
  grep -E 'sched_entity|sched_rt_entity|sched_dl_entity|sched_ext_entity|sched_class'
```

---

## 3. Stage A — the patch (pure reorder)

This changes field **order** only. Not one line of C code elsewhere changes, no memory is saved, no behaviour changes. It is the smallest possible version of the fix, which is exactly what a first upstream patch should be.

```diff
--- a/include/linux/sched.h
+++ b/include/linux/sched.h
@@ -877,15 +877,22 @@ struct task_struct {
 	int				normal_prio;
 	unsigned int			rt_priority;
 
+	/*
+	 * Hot: read by __schedule() / enqueue_task() / dequeue_task() on
+	 * every context switch. Keep these adjacent so the common (fair)
+	 * path does not straddle the cold per-class entities below.
+	 */
 	struct sched_entity		se;
+	const struct sched_class	*sched_class;
+	struct sched_dl_entity		*dl_server;
+
+	/*
+	 * Cold for the common case: each entity below is only touched by
+	 * tasks that actually belong to that scheduling class. Placed after
+	 * the hot fields so ~500 bytes of unread data no longer separate
+	 * 'se' from 'sched_class'.
+	 */
 	struct sched_rt_entity		rt;
 	struct sched_dl_entity		dl;
-	struct sched_dl_entity		*dl_server;
 #ifdef CONFIG_SCHED_CLASS_EXT
 	struct sched_ext_entity		scx;
 #endif
-	const struct sched_class	*sched_class;
 
 #ifdef CONFIG_SCHED_CORE
 	struct rb_node			core_node;
```

### What each change does

1. **`se` stays put.** It is 64-byte aligned automatically, because its last member is `struct sched_avg avg`, and `struct sched_avg` is declared `____cacheline_aligned` (`include/linux/sched.h:520`). That alignment also makes `sizeof(se)` a multiple of 64, so whatever follows `se` starts exactly at a cache line boundary.
2. **`sched_class` moves up to follow `se`.** It now lands at the start of the line right after the data the scheduler just read. One prefetch-friendly, contiguous hot region.
3. **`dl_server` moves up too.** It is 8 bytes and is read on the fair path (the deadline-server mechanism), so it rides along on the same line for free.
4. **`rt`, `dl`, `scx` move down, unchanged.** A realtime or deadline task still finds its entity; it just lives after the hot region now.

Result:

```
lines 2-5   se
line  6     sched_class, dl_server     <- hot region ends here
lines 7+    rt, dl, scx                <- untouched by normal tasks
```

### Why this is safe (checked against the 7.2 tree, not assumed)

- **No code copies `se..dl` as one block.** `grep -rn 'memset(&p->se\|memcpy(&p->se' kernel/sched/` finds nothing. Each entity is initialised field by field.
- **No code depends on the entities being adjacent.** `container_of(rt_se, struct task_struct, rt)` style code uses `offsetof`, which the compiler recomputes.
- **`init_task` uses designated initialisers** (`.se = ...`), which do not care about order.

---

## 4. Stage B — get the 248 bytes back (separate, later patch series)

Stage A fixes the cache span but the dead bytes are still allocated per task. Stage B turns `dl` into a pointer, allocated only when a task actually becomes `SCHED_DEADLINE`.

Why `dl` first: best ratio of size to churn. Count the call sites yourself:

```bash
cd /mnt/data/linux-src/linux-7.2
grep -rEn '\->dl\.' --include=*.c --include=*.h . | wc -l    # 89  (248 bytes)
grep -rEn '\->scx\.' --include=*.c --include=*.h . | wc -l   # 478 (208 bytes)
```

The three things the embedded field gave you for free, which you now must handle:

1. **Allocation.** Allocate from a dedicated `kmem_cache` when `__setscheduler_params()` first switches the task to `SCHED_DEADLINE`.
2. **`init_task`.** `init/init_task.c` builds the first task statically. Point its `dl` at a static `sched_dl_entity`.
3. **Timer lifetime — the dangerous one.** `sched_dl_entity` contains two live hrtimers (`dl_timer`, `inactive_timer`). A pending timer holds a pointer into the entity. Safe rule: **allocate on first entry to the class, free only in `free_task()`, never on class change.** A task that leaves and re-enters SCHED_DEADLINE reuses its allocation.

Honest scope: ~89 mechanical edits plus ~60 lines of real logic in `kernel/sched/deadline.c` and `kernel/sched/core.c`. Do Stage A, measure, and only then decide whether Stage B earns its review cost.

---

## 5. Who benefits (use cases)

The win is per context switch, so it scales with switch rate:

- **High: message-passing and pipeline workloads.** Web servers behind a reverse proxy, databases with worker pools, anything measured well by `perf bench sched pipe`. Hundreds of thousands of switches per second.
- **High: oversubscribed hosts.** Kubernetes nodes and CI runners with far more runnable threads than cores.
- **Medium: fork/exec-heavy work** (shell-scripted builds) — every new task also zeroes 504 fewer hot-adjacent bytes into cache.
- **Near zero: compute-bound tasks** that run for full timeslices. Few switches, nothing to save.

Stage B additionally saves ~248 B x number of threads (25 MB per 100k threads) and improves slab packing of `task_struct`.

---

## 6. ABI and compatibility

The question to answer precisely, because reviewers will: *who, outside this header, knows these offsets?*

| Consumer | Affected? | Why |
|---|---|---|
| Userspace ABI (syscalls, /proc, /sys) | **No** | `task_struct` layout is never exposed to userspace. Kernel-internal layout is not ABI. |
| Assembly code | **No** | Only two `task_struct` offsets are exported to asm: `thread.sp` and `stack_canary` (`arch/x86/kernel/asm-offsets.c:45,47`). Neither moves. |
| BPF (CO-RE) | **No** | CO-RE relocates field offsets at program load time using the running kernel's BTF. The `offsetof(struct task_struct, scx.slice)` checks in `kernel/sched/ext/ext.c:7917-7925` are compile-time and recompute automatically. |
| BPF with hardcoded offsets | Breaks | Already unsupported; such programs break on any config change. Not your problem. |
| In-tree code | **No** | Recompiled with the new header; all access is by field name. |
| Out-of-tree modules | Rebuild needed | Same as for any header change. Upstream does not guarantee module ABI. |
| Distro kABI (RHEL/SUSE frozen layouts) | Yes, if backported | A distro backport would break their kABI checksum. That is the distro's concern, not upstream's. |
| `CONFIG_RANDSTRUCT_FULL` | Patch becomes a no-op | These fields are in the randomised region (`sched.h:843-1669`); the compiler shuffles them anyway. Not a correctness issue — just no benefit on hardened builds. |

---

## 7. How to verify

```bash
# 1. Layout: sched_class must now sit at (offsetof(se) + sizeof(se)).
pahole -C task_struct vmlinux | \
  grep -E 'sched_entity|sched_class|sched_rt_entity|sched_dl_entity|sched_ext_entity'

# 2. Total size unchanged (Stage A moves bytes, it does not remove them):
pahole -C task_struct vmlinux | tail -5

# 3. Behaviour: context-switch benchmarks, 10 runs each, compare medians.
perf bench sched pipe -l 200000
perf bench sched messaging -g 20 -l 1000

# 4. Mechanism: confirm misses actually dropped, not just wall time:
perf stat -e cycles,instructions,L1-dcache-load-misses,LLC-load-misses \
  -- perf bench sched pipe -l 200000

# 5. Regression check for the classes you did NOT optimise:
#    run an RT task (chrt -f 50) and a SCHED_DEADLINE task and confirm
#    no measurable loss - their entities moved by a few cache lines too.
```

If wall time improves but the miss counters do not move, the improvement is noise. Do not send it upstream.

---

## 8. Getting it merged

Who to send it to (from the tree itself):

```bash
perl scripts/get_maintainer.pl -f include/linux/sched.h
# Ingo Molnar, Peter Zijlstra, Juri Lelli, Vincent Guittot + sched reviewers
```

Non-negotiables for a layout patch to the scheduler:

1. **One logical change per patch.** Stage A is one patch. Stage B is its own series later. Never mix.
2. **Numbers in the commit message, or an instant NAK.** Peter Zijlstra will not take "should be faster". Include: the `pahole` before/after (hot-path span 12 lines -> 5), the `perf stat` miss deltas, the benchmark medians with run count, and the exact config (`SCHED_CLASS_EXT=y`? `RANDSTRUCT_NONE`?) and hardware.
3. **`./scripts/checkpatch.pl --strict` clean.**
4. **State what you checked for safety** (the asm-offsets, BPF CO-RE, and no-block-copy points from section 6 — doing the reviewers' worry-work for them is what gets a layout patch accepted).

Example commit message shape:

```
sched: keep sched_class adjacent to sched_entity in task_struct

A fair-class task never reads rt (48 bytes), dl (248 bytes) or scx
(208 bytes), yet these sit between se and sched_class, both read on
every context switch. The fair path therefore spans 12 cachelines of
task_struct to reach 5 cachelines of data.

Move sched_class and dl_server directly after se and place the
per-class entities behind them.

pahole (x86-64, defconfig + SCHED_CLASS_EXT):
  before: se @128..383, sched_class @896
  after:  se @128..383, sched_class @384

perf bench sched pipe -l 200000, median of 10, <machine>:
  before: X.XXs   after: X.XXs   (-N.N%)
L1-dcache-load-misses: -N.N%

No functional change. No asm-offsets or BPF CO-RE impact
(offsets are relocated at load time).

Signed-off-by: Your Name <you@example.com>
```

---

## 9. Realistic expectation

Low single-digit percent on switch-heavy benchmarks; possibly nothing on anything else. The honest case for the patch is cost, not drama: ten reordered lines, no behaviour change, verified safe against every offset consumer — for a permanent reduction of the scheduler's hot-path footprint.
