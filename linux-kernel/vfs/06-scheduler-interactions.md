# Where the VFS hands the CPU to the scheduler, and where it hands the disk to the I/O scheduler

Every point on the open, stat and close paths where the calling task can go
off-CPU, wake another task, or submit I/O. Each one is a place where a
throughput number stops being about the VFS and starts being about the
scheduler: a sleep is a context switch, a wakeup on another CPU is a
migration candidate for the wakee, and an I/O submission is a queue the I/O
scheduler now orders. Read out of the tree at `518e5b794c06`; kbench config
is `PREEMPT_DYNAMIC` + `PREEMPT_LAZY` + `PREEMPT_RCU`, `HZ=1000`.

The warm path — dcache hit, no create, no watchers, no leases — has **no
sleep point at all** except memory allocation, and the series takes two of
the three allocations off it. Everything below is what happens when one of
those conditions fails, ordered by how often real workloads hit it.

---

## 1. On every open, always

| where | primitive | what it does to the scheduler | protection |
|---|---|---|---|
| `alloc_empty_file()` `kmem_cache_alloc(GFP_KERNEL)` | slab | may enter direct reclaim: run shrinkers (including the dcache/inode shrinker, which can `evict()` an unrelated inode and do journal I/O), wait on writeback, swap | **series patch 3**: not called at all on a failed open; **patch 10**: the LSM blob no longer a second allocation. Success path keeps one. |
| `getname()` `names_cache`, `GFP_KERNEL` | slab | same | not in the series; §7 below |
| `d_alloc()` on a dcache miss, `GFP_KERNEL` | slab | same | inherent |
| `strncpy_from_user()` in `getname()`, `copy_to_user()` in `cp_statx()` | page fault | sleeps if the user page is not resident | inherent |
| `dput()`, `__fput()` | `might_sleep()` | on `PREEMPT_VOLUNTARY` builds (most distributions) this is a live `cond_resched()`: two voluntary preemption points per open/close. Not a source of migrations, but the point at which a pending one lands. On the kbench config (`PREEMPT_LAZY`) it is a no-op. | leave: moving it to the slow path loses the debug check for callers in atomic context |
| `fput()` at `close()` | `task_work_add(TWA_RESUME)` | runs `__fput()` at return to userspace on the **same** task: no switch, no wakeup. Only kernel threads take the `delayed_fput_work` path (kworker wakeup). | already right |
| `rcu_read_lock()` for the walk | with `PREEMPT_RCU` (this config) the walk is preemptible; on non-preempt kernels it disables preemption for the whole walk | a long walk (many components, long hash chains) delays scheduling on that CPU on non-preempt kernels | inherent; short walks |

## 2. Threads of one process opening many files

**`expand_fdtable()` calls `synchronize_rcu()`** — `fs/file.c:261`:

    spin_unlock(&files->file_lock);
    new_fdt = alloc_fdtable(nr + 1);
    if (atomic_read(&files->count) > 1)
            synchronize_rcu();
    spin_lock(&files->file_lock);

For any process with more than one thread (`files->count > 1`), every time
the fd table doubles the thread doing the `open()` **sleeps for a full RCU
grace period** — milliseconds on an idle system, tens of milliseconds under
load, with `rcupdate.rcu_normal` or `nohz_full` much longer — and every
*other* thread that tries to allocate an fd meanwhile blocks in
`expand_files()` on `resize_wait` (`fs/file.c:304`), and every `fd_install()`
takes the `fd_install_slowpath()` which also waits. The table starts at 64
embedded slots and grows by powers of two, so a server opening 100 000 fds
pays this **eleven times**, each time stalling all threads.

This is the largest scheduler stall on the open path and it is by design:
the grace period is what lets `fd_install()`'s fast path run under
`rcu_read_lock_sched()` without taking `file_lock`. It is not a bug and not
fixable in the VFS without redesigning fd installation.

**Protection**: size the table once, early, from the process that owns it —
`setrlimit(RLIMIT_NOFILE)` does *not* do it; the table grows on demand. The
kernel exposes no pre-size call. Two working options:

1. userspace: at startup, `dup2(0, N-1); close(N-1)` for the expected maximum
   `N`, before spawning threads (`files->count == 1`, so no
   `synchronize_rcu()` at all). One syscall pair, done once. Postgres and
   nginx effectively get this from their pre-fork model; kafka, minio and
   any JVM/Go server do not.
2. kernel, small and upstreamable: grow more aggressively once the table is
   past the embedded 64 — quadruple instead of double above 1024 — so a
   100 000-fd process pays 6 grace periods instead of 11. Memory cost is at
   most 3× the fd array for the last step (`sizeof(struct file *)` per slot:
   3 MB at 100 000 fds), which is nothing next to the `struct file`s
   themselves. Not written; it changes a policy Linus has opinions about.

The workload matrix (`30-workload-matrix.md`) has kafka and minio as the two
cases that open thousands of fds from many threads; this is the stall they
will show and the reason a thread-based benchmark of open() measures
`synchronize_rcu` and `file_lock`, not the VFS (H10).

## 3. Creating files in one directory from many CPUs

`lookup_open()` takes `inode_lock(dir_inode)` **exclusive** for `O_CREAT`
(`fs/namei.c:4458`) and `inode_lock_shared()` otherwise. Two consequences:

- creates in one directory are fully serialised: a `rw_semaphore` write
  lock, so the second creator sleeps (context switch, wakeup by the first
  when it unlocks — `rwsem` hands off to the next waiter, which the
  scheduler may run on a different CPU: migration).
- a create blocks every concurrent *miss* on that directory
  (`lookup_slow()` wants the shared lock), and `d_alloc_parallel()` makes
  concurrent lookups of the *same missing name* wait on each other
  (`d_wait_lookup()`, `fs/dcache.c:2750`).

Warm hits are unaffected: `lookup_fast()` never takes `i_rwsem`. This is why
"create N files in one directory from N threads" is a benchmark of `rwsem`
handoff. Filesystems could offer shared-lock create (btrfs and NFS have
discussed it; nothing in tree); the VFS side is `LOOKUP_*`-neutral and not
in this series.

**Protection**: spread creates over directories (what every object store
and database already does with hashed subdirectories); O_TMPFILE +
`linkat()` moves the exclusive section to `linkat`, which is shorter.

## 4. Things that wake another task on open or close

Each of these turns one syscall into a wakeup, and a wakeup is where
`select_task_rq()` decides whether the wakee moves.

| trigger | condition | wakee | where |
|---|---|---|---|
| inotify/fanotify watch on the file or its directory asking for `IN_OPEN` / `IN_CLOSE_*` | watchers exist | the watching daemon | `fsnotify_open()`, `fsnotify_close()` → `wake_up(&group->notification_waitq)` (`fs/notify/notification.c:127`) |
| fanotify **permission** event | `FAN_OPEN_PERM` mark | the daemon, and the opener **sleeps** until it answers (`fanotify_get_response()`, `wait_event_state(... TASK_KILLABLE)`) | `fsnotify_open_perm_and_set_mode()` in `do_dentry_open()` |
| lease on the inode | someone holds a lease conflicting with the open mode | the lease holder (SIGIO), and the opener **sleeps up to `lease_break_time` = 45 s** unless `O_NONBLOCK` | `break_lease()` in `do_dentry_open()`; `__break_lease()` `fs/locks.c:1712` |
| `relatime` atime update | first access in 24 h or atime older than mtime, mount not `noatime` | none immediately — `__mark_inode_dirty()` → `wb_wakeup_delayed()` queues the flusher **5 s** out (`dirty_writeback_interval`) | `touch_atime()` `fs/inode.c` |
| first open after mount on ext4 | once per mount | none, but a **journal transaction** in the opener (`ext4_sample_last_mounted()`: `d_path()` + `ext4_journal_start_sb()`) | `ext4_file_open()` |
| parallel lookup of the same missing name | two CPUs miss on one name | the second waits for the first's `->lookup()`, woken by `d_lookup_done()` | `d_alloc_parallel()` |

The first two are policy the administrator chose; the VFS already avoids
the calls when no watcher exists (`fsnotify_sb_has_watchers()` short-circuit
in `fsnotify_parent()`, `FMODE_NONOTIFY_PERM` set by default in `init_file()`).
The lease one only fires when leases exist (Samba, NFSv4 delegations). The
atime one is the measurement gap H8: nothing this project has run had
`relatime`.

## 5. Where the I/O scheduler gets involved

On a warm path, nowhere. On a cold one:

| path | I/O pattern | scheduler consequence |
|---|---|---|
| dcache miss → `ext4_lookup()` → `__ext4_find_entry()` | synchronous `REQ_META\|REQ_PRIO` reads of directory blocks; on an htree directory the leaf is found by hash so it is 1–2 blocks, but **one at a time, no readahead** | a cold `ls -l`/`find` on a large directory is n synchronous small reads serialised by the walker; the I/O scheduler sees a queue depth of 1 |
| `ext4_iget()` for a cold inode | inode table block read, **with** readahead (`inode_readahead_blks`, default 32 blocks) | good: one read brings the neighbours |
| cold `stat()` of n files in one directory | dir block (cached after the first) + inode block per file | ≈ n/16 inode-table reads thanks to readahead; the n+1 that hurts is on cold inode tables, not directories |
| `O_TRUNC` → `handle_truncate()` → `ext4_truncate()` | journal transaction, block frees | I/O in the opener, under `mnt_want_write()` |
| `close()` of an ext4 file that was truncated-and-rewritten | `ext4_release_file()`: `EXT4_STATE_DA_ALLOC_CLOSE` → `ext4_alloc_da_blocks()` → `filemap_flush()` | **writeback submitted from `close()`**, asynchronously, by the closing task: the `auto_da_alloc` heuristic that protects editors' replace-by-truncate against zero-length files after a crash. Real I/O cost on close, by design; `noauto_da_alloc` disables it. |
| `close()` of the last writer | `ext4_discard_preallocations()` under `i_data_sem` | no I/O, but a write-locked rwsem |
| symlink in the path on ext4 (slow symlink) | `->get_link` reads the symlink block through the page cache | one read, then cached in `i_link` |
| eviction under memory pressure | the shrinker called from *any* `GFP_KERNEL` allocation in *any* task's open can `evict()` inodes → `ext4_evict_inode()` → journal | a `stat()` can wait for the I/O of an inode it never touched |

The VFS-level lever on the cold directory case would be directory block
readahead on lookup, which ext4 does not do (it does for `readdir`). That is
a filesystem patch, not a VFS one, and it is not in the series.

## 6. What the series does about all this

Nothing in the series changes when the task sleeps, except by removing
allocations, which are the only sleep points on the warm path:

| patch | sleep points removed |
|---|---|
| 3 (lazy `struct file`) | the `GFP_KERNEL` allocation and the `put_cred()` on every failed open, `-ECHILD` retry and `-ESTALE` retry; the allocation on every dcache miss that `->lookup()` resolves without creating or `->atomic_open()` |
| 10 (LSM blob embedded) | one `GFP_KERNEL` allocation per successful open on every kernel with an LSM |
| 6 (rcu-walk stat) | the `rcu_read_unlock()`/`lock` pair and the `smp_mb()`; no sleep point was there, but on non-preempt kernels the whole stat is now one preemption-disabled section, which is *shorter* than before |

Fewer allocation sites means fewer places where an unrelated memory
situation turns a stat into a reclaim. That is the only kind of scheduler
protection the VFS can offer on the warm path; the rest (§2–§5) is either
policy the caller chose or the filesystem's.

## 7. Candidates, not in the series

- **`struct filename` on the stack for short names.** 192 bytes from
  `names_cache` per path syscall, the one remaining `GFP_KERNEL` allocation
  on a warm stat. `getname()` has 91 callers and `putname()` assumes the slab
  origin; `audit_getname()` keeps the pointer past the syscall when an audit
  context is live. Doable for the `statx`/`openat` entry points with a
  `struct filename` embedded in a caller-provided buffer and a flag bit in
  the 4 bytes of padding in `__filename_head`. About 1% of an open in
  instructions; its value is the removed allocation, not the instructions.
- **fd table growth policy** (§2). Six lines in `alloc_fdtable()`.
- **Directory readahead on lookup** (§5). ext4.
- **`might_sleep()` placement in `dput()`.** Not worth it: `cond_resched()`
  is what the scheduler wants there on voluntary kernels.

## 8. How to see it

The counters that separate scheduler effects from VFS effects, all
available in the guest and none of them timing:

    perf stat -e context-switches,cpu-migrations,instructions:k  <loop>

A single-process pinned loop should show `context-switches` ≈ the timer
tick count (1000/s at `HZ=1000`) and `cpu-migrations` = 0. Anything above
that is one of the sleep points in this document firing, and
`perf trace -s` or `perf sched timehist` on the loop names it.
`scripts/guest/vfs-verify.sh` (rewritten today, not yet run in this form)
prints both per loop next to the ftrace hit counts. The expected answer for
a single pinned process on a warm dcache is the floor for every loop: the
warm path does not schedule. The two runs done so far used the previous
version of the script, which recorded hit counts only.

For the threaded fd-table stall: `perf probe -a expand_fdtable` or
`trace-cmd record -e rcu:rcu_utilization` while the workload ramps up; each
`synchronize_rcu` shows as a gap of one grace period in the opener's
`sched:sched_switch` stream.
