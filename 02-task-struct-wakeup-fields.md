# Task 2 — Put the wakeup-path fields on the wakeup cache lines

**What the patch does, in one sentence:** it moves two fields that `select_task_rq()` reads on every wakeup (`nr_cpus_allowed`, 4 bytes, and `cpus_ptr`, 8 bytes) from cache line ~20 of `task_struct` up into the first two lines, next to the other wakeup fields — so waking a task pulls two remote cache lines instead of three.

| | |
|---|---|
| Target file | `include/linux/sched.h` |
| Kernel | Linux 7.2, vanilla, `/mnt/data/linux-src/linux-7.2` |
| Patch size | Move 2 declarations (12 bytes of data) |
| Risk | Low |
| Realistic gain | One fewer remote cache line transfer per wakeup |
| Depends on | Apply **after** Task 1 (same file, adjacent region) |

---

## 1. Background: why wakeup misses cost more than normal misses

When thread A wakes thread B — releasing a lock, writing a pipe, delivering a network packet — the kernel runs `try_to_wake_up()` **on A's CPU**, and that code reads **B's** `task_struct`.

That is the key detail. CPU 0 is reading memory that CPU 5 owns and has recently written. The cache-coherence protocol must ship that line from CPU 5's cache to CPU 0's. This is a **remote transfer**: hundreds of cycles, worse across NUMA sockets, and it is what `perf c2c` reports as **HITM** ("hit modified" — I needed a line another CPU had dirty).

So for the wakeup path the usual rule gets stronger:

> Every extra cache line the waker touches in the wakee's `task_struct` is a cross-CPU transfer, not a cheap local miss.

Goal: the waker should touch as few lines of the other task's struct as possible.

---

## 2. What 7.2 already does right — read this before patching

Someone has already worked on this path, and the patch must respect that work. The wakeup-hot fields are deliberately packed at the very top of `task_struct` (`include/linux/sched.h:846-878`):

```c
	unsigned int			__state;
	...
	u8				on_cpu;
	u8				on_rq;
	u8				is_blocked;
	u8				__pad;
	struct __call_single_node	wake_entry;
	unsigned int			wakee_flips;
	unsigned long			wakee_flip_decay_ts;
	struct task_struct		*last_wakee;
	int				recent_used_cpu;
	int				wake_cpu;
```

Note `on_cpu`, `on_rq`, `is_blocked` were shrunk from `int` to `u8` so all three plus padding fit in 4 bytes. That is deliberate packing. Everything above lands in roughly the first two cache lines.

---

## 3. The problem, with evidence

`try_to_wake_up()` calls `select_task_rq()` to choose a CPU for the woken task. Here is the actual function (`kernel/sched/core.c:3614-3625`):

```c
static inline
int select_task_rq(struct task_struct *p, int cpu, int *wake_flags)
{
	lockdep_assert_held(&p->pi_lock);

	if (p->nr_cpus_allowed > 1 && !is_migration_disabled(p)) {
		cpu = p->sched_class->select_task_rq(p, cpu, *wake_flags);
		*wake_flags |= WF_RQ_SELECTED;
	} else {
		cpu = cpumask_any(p->cpus_ptr);
	}
	...
```

So on **every wakeup** it reads `p->nr_cpus_allowed` and (on one branch or the other) `p->cpus_ptr`. And those two live nowhere near the wakeup block (`include/linux/sched.h:929-934`):

```c
	unsigned int			policy;
	unsigned long			max_allowed_capacity;
	int				nr_cpus_allowed;      /* <-- read every wakeup */
	const cpumask_t			*cpus_ptr;            /* <-- read every wakeup */
	cpumask_t			*user_cpus_ptr;
	cpumask_t			cpus_mask;
```

Between the wakeup block and these fields sit `se` (256 B), `rt` (48 B), `dl` (248 B), `scx` (208 B), the uclamp arrays, and `struct sched_statistics`. On the running kernel here (which has all of those on), `nr_cpus_allowed` lands at offset **1304** — cache line 20 — while its consumers' other data is in lines 0-1.

The wakeup therefore transfers:

```
line 0    __state, on_cpu, on_rq, wake_entry...   remote fetch
line 1    recent_used_cpu, wake_cpu, prio...      remote fetch
line 20   nr_cpus_allowed, cpus_ptr               remote fetch — for 12 useful bytes
```

Three remote transfers where two would do.

### Reproduce it yourself

```bash
cd /mnt/data/linux-src/linux-7.2
sed -n '3614,3625p' kernel/sched/core.c        # the reader
sed -n '929,934p' include/linux/sched.h        # the fields

pahole -C task_struct /sys/kernel/btf/vmlinux | \
  grep -E '\b(__state|on_cpu|wake_cpu|nr_cpus_allowed|cpus_ptr)\b'
```

---

## 4. The patch

Move the **count and the pointer only**. `cpus_mask` stays where it is (section 5 explains why).

```diff
--- a/include/linux/sched.h
+++ b/include/linux/sched.h
@@ -866,6 +866,15 @@ struct task_struct {
 	int				recent_used_cpu;
 	int				wake_cpu;
 
+	/*
+	 * Read by select_task_rq() on every wakeup, from the *waker's* CPU.
+	 * Keep them with the other wakeup fields above so a wakeup pulls
+	 * two cachelines of the wakee's task_struct instead of three.
+	 * cpus_mask itself stays below: it is NR_CPUS bits large and is
+	 * only reached through cpus_ptr on this path.
+	 */
+	int				nr_cpus_allowed;
+	const cpumask_t			*cpus_ptr;
+
 	int				prio;
 	int				static_prio;
 	int				normal_prio;
@@ -927,8 +936,6 @@ struct task_struct {
 
 	unsigned int			policy;
 	unsigned long			max_allowed_capacity;
-	int				nr_cpus_allowed;
-	const cpumask_t			*cpus_ptr;
 	cpumask_t			*user_cpus_ptr;
 	cpumask_t			cpus_mask;
```

### What each change does

1. The two declarations are deleted from offset ~1300 territory and re-declared right after `wake_cpu`, inside the existing wakeup block. Identical types, identical names.
2. **No call site changes anywhere.** All access is `p->nr_cpus_allowed` / `p->cpus_ptr` by name; the compiler recomputes offsets. The affinity code that repoints `cpus_ptr` (`kernel/sched/core.c:2777`, `kernel/fork.c:963-964`) compares and assigns pointers — field position is irrelevant to it.
3. The move may cost **zero bytes**: `se` begins the next region and is 64-byte aligned (via `struct sched_avg`, `sched.h:520`), so the compiler already inserts padding before it. The 12 moved bytes can land inside that existing padding. Check with `pahole` — if there was a hole of 12+ bytes before `se`, the struct did not grow.

---

## 5. Two fields deliberately NOT moved — and reviewers will ask

**`cpus_mask` stays.** It is a `cpumask_t`: with `CONFIG_NR_CPUS=8192` that is 1024 bytes. Moving it into the head would push every other hot field out of the first lines and destroy exactly the packing this patch builds. The fast path never reads it directly — only through `cpus_ptr`.

**`migration_disabled` stays — for now.** Honest finding from reading `select_task_rq()`: it also reads `p->migration_disabled` (via `is_migration_disabled()`, `kernel/sched/sched.h:1397`), which lives at offset ~2362 — a **fourth** scattered line. So why not move it too?

Because it has a different write pattern: `migrate_disable()`/`migrate_enable()` are called by the running task itself, frequently on some workloads (BPF, PREEMPT_RT). Moving a frequently-self-written field onto the line the waker reads deserves its own measurement — it could add line dirtying that outweighs the saved fetch. Upstream discipline: one measured change per patch. Note it in the commit message as a possible follow-up. If you move it anyway and the numbers regress, that is why.

---

## 6. Who benefits (use cases)

The wakeup path runs on every: pipe/socket write that unblocks a reader, mutex/futex release with waiters, condition-variable signal, network packet delivered to a blocked thread, timer expiry, io_uring completion delivered to a waiter.

- **High: cross-CPU producer/consumer systems.** Web servers, message brokers, thread-pool databases — waker and wakee are usually on different CPUs, so every one of these transfers is remote.
- **Higher still: multi-socket NUMA machines**, where a remote transfer crosses the interconnect.
- **Low: single-threaded or CPU-pinned workloads**, where waker and wakee share a cache hierarchy.

---

## 7. ABI and compatibility

| Consumer | Affected? | Why |
|---|---|---|
| Userspace ABI | **No** | `task_struct` layout never reaches userspace. `sched_getaffinity()` copies the mask's *contents*, not the struct. |
| Assembly | **No** | Only `thread.sp` and `stack_canary` offsets are exported to asm (`arch/x86/kernel/asm-offsets.c:45,47`). Untouched. |
| BPF CO-RE | **No** | Offsets relocated at load time from the running kernel's BTF. |
| In-tree C code | **No** | Field-name access only; recompiled. |
| Out-of-tree modules / distro kABI | Rebuild / kABI break if backported | Standard for any `task_struct` change; upstream does not care, distros handle it. |
| `CONFIG_RANDSTRUCT_FULL` | Patch becomes a no-op | Fields are inside the randomised region; layout is shuffled regardless. |

One more honesty point for the commit message: the measured offsets (1304/1312) depend on `SCHEDSTATS`, `UCLAMP_TASK`, and `SCHED_CLASS_EXT` all being enabled. With other configs the gap shrinks but does not close — the entities from Task 1 alone are 760+ bytes.

---

## 8. How to verify

```bash
# 1. Layout: both fields now below offset 128.
pahole -C task_struct vmlinux | \
  grep -E '\b(__state|on_cpu|wake_cpu|nr_cpus_allowed|cpus_ptr)\b'

# 2. Size: unchanged, or grown by at most 16 bytes (check the hole before se).
pahole -C task_struct vmlinux | tail -5

# 3. Benchmark the effect where it exists: waker and wakee on DIFFERENT cores.
taskset -c 0,12 perf bench sched pipe -l 500000     # patched vs unpatched, 10 runs

# 4. Prove the mechanism, not just the wall time:
perf c2c record -ag -- taskset -c 0,12 perf bench sched pipe -l 500000
perf c2c report --call-graph none -k vmlinux
#    Before: a HITM entry for task_struct at offset ~1304.
#    After:  that entry gone; line 0-1 entries unchanged.
```

`perf c2c` is the tool that answers "did I remove a remote transfer". This is the exact workflow the kernel documents in `Documentation/kernel-hacking/false-sharing.rst:94-128`.

---

## 9. Getting it merged

Same maintainers as Task 1 (`scripts/get_maintainer.pl -f include/linux/sched.h`: Molnar, Zijlstra, Lelli, Guittot). Send Task 1 Stage A and this as a **two-patch series** — same file, same theme, reviewed once.

What this specific patch needs to survive review:

1. **The `perf c2c` before/after in the commit message.** For a remote-transfer claim, HITM data is the proof; wall-clock alone will get you asked for it anyway.
2. **The pahole delta** (offset 1304 -> under 128) and total-size delta (ideally 0).
3. **The `migration_disabled` paragraph.** Showing you saw the fourth line and chose not to touch it — with the reason — is the difference between "ran pahole once" and "understands the path".
4. `./scripts/checkpatch.pl --strict` clean; config and hardware stated.

---

## 10. Realistic expectation

One remote line per wakeup, provable with `perf c2c`. Visible on wakeup-heavy cross-socket workloads; lost in noise on a laptop. It earns its place by being nearly free, mechanically verifiable, and by finishing the packing job the wakeup block started.
