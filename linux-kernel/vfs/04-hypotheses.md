# Hypotheses

Everything this project believes about where VFS cost is, written as claims
that can be shown false. Nothing here is a result. Each entry states what it
would take to kill it, because a hypothesis you cannot kill is not worth
carrying.

Tree: `/usr/src/linux` `518e5b794c06` (7.3.0-rc3 + 824). Build:
`/usr/src/kbench/builds/baseline`. The graph evidence comes from
`graphs/vfs-full.json` via `tools/cascade.py`; the layout evidence from
`pahole` on the built `vmlinux`.

**Status vocabulary.** *Structural* — established from the compiled code, no
machine needed. *Measured* — a number exists from the rig, with its
control. *Unattributed* — an effect was measured but its mechanism is not
established. *Open* — neither.

Read `../../linuxpatches/linux-kernel/vfs/README.md` §"Why static first"
before treating any wall-clock number here as evidence. The rig is a KVM
guest on a WSL2 laptop and it cannot resolve wall-clock effects below roughly
10–15%; counters can do better, and where a hypothesis rests on a counter
that is said explicitly.

---

## H1 — The path walk is the VFS's common cost, not open's

**Claim.** Optimising `filename_lookup` pays across roughly forty syscalls;
optimising any individual operation pays across one.

**Mechanism.** Every path-based syscall is `filename_lookup` followed by a
small operation followed by `path_put`. The operation is the minority of the
work.

**Evidence — structural.** Reachable instructions per entry point:
`openat` 25 177, `utimensat` 21 953, `chown` 21 815, `chmod` 21 738,
`rename` 21 393, `link` 19 973. Every path-based syscall within 20% of every
other. Separately, `filename_lookup` alone is 13 003 of the 13 476
instructions reachable under `vfs_statx` — **96.5%** (`02-stat-path.md` §2).

**Prediction.** ftrace `function_profile` hit counts on a mixed workload will
show `link_path_walk` and `lookup_fast` entered once per path component per
path-based syscall, and the per-syscall tail functions entered once each.
The walk's share of `insn:k` per syscall will be the majority for every
path-based syscall, not just open and stat.

**Falsified if.** Execution counts show the reachable-set similarity is an
artefact of shared error paths — i.e. the syscalls converge only on code that
does not run. This is a live possibility: the reachable set is an upper bound
and `01-open-path.md` §2 already shows it includes `propagate_umount` and
`fsnotify`, neither of which runs on a warm success path.

**Status.** Structural. The falsification test has not been run.

---

## H2 — `dput` is the highest-leverage unexamined function in the VFS

**Claim.** `dput` costs more, on more syscalls, than anything this project has
looked at, and it has never been looked at.

**Mechanism.** Breadth 78 of 164 syscall entry points, 70 distinct callers,
203 instructions, and **two indirect dispatches** — one is `d_op->d_delete`
at `dentry_operations` offset 0x20 (verified in the disassembly of
`fs/dcache.o`). Under `MITIGATION_RETPOLINE=y` each is a thunk call.

**Prediction.** `dput` will appear in the top five of a
`function_profile` hit count for any path-heavy workload, and its
instructions-per-call will be dominated by the slow path rather than the
`lockref_put_return` fast path.

**Falsified if.** The `d_delete` dispatch is only reached on the
last-reference slow path, and that path is rare on warm workloads — in which
case the two retpolines cost nothing in practice and `dput` is 203
instructions of which only a handful execute. **This is the likely outcome**
and the hypothesis is stated so that finding it out is cheap.

**Status.** Open. Costs one guest boot with `function_profile` armed.

---

## H3 — The reference round trip is real, and removing it is what produced the measured effect

**Claim.** Opening a file takes two references on one dentry and drops one
immediately; removing that pair is why `dopen` measured +80% at 8 processes
on a shared inode.

**Mechanism.** Four atomic RMWs on `dentry->d_lockref` per open/close cycle —
`__legitimize_path` get, `do_dentry_open` get, `terminate_walk` put, `__fput`
put — of which two cancel within microseconds. On a shared inode all four land
on one cache line.

**Evidence — structural.** Confirmed in the emitted code of the current
baseline, `01-open-path.md` §3. The four RMWs are still four.

**Evidence — measured, unattributed.** Shared-inode sweep, control-normalised,
six blocks per variant: 1 proc +3.6% (spans zero), 4 procs +20.1%
[+3.4, +31.9], 8 procs +80.0% [+53.6, +123.0], 16 procs +76.9%
[+41.3, +110.1]. The gap widens with process count, which is the shape a
contention fix has and a flat offset does not. `lockref` alone does nothing
and `combined` tracks `dopen`.

**Evidence — proved.** `proofs/` shows the transfer is reference-equivalent to
mainline on all three exits of `do_dentry_open` × `O_TRUNC`, and rejects both
of the wrong variants that were actually written by people who knew this code.

**Falsified if.** A stat-only sweep on a shared inode — no `struct file`
involved — shows the same curve. That would mean the contention is on the
dentry regardless of the open, and the `path_get`/`dput` pair is not what
moved. **This test does not exist**; `sweep-bench.sh` measures only
open/close, deliberately with processes rather than threads.

**Status.** Measured but unattributed. Gap G2 in `30-workload-matrix.md`.
This is the single most important open question in the project, because a
number is already being carried that may belong to a different mechanism.
Note that with H12 the falsification test changes shape: a stat-only sweep on
the *series* kernel performs no dentry RMW at all, so it can no longer show
"the same curve"; run it on the baseline kernel, where stat still takes the
two references.

---

## H4 — `struct inode` cacheline 5 mixes read-hot and write-hot fields

**Claim.** `i_fop` and `i_flctx` are read on every open from the same cache
line that `i_count`, `i_writecount` and `i_readcount` are atomically written
on, so two CPUs opening one file invalidate the line they both need to read.

**Mechanism.** `pahole` on the built `vmlinux`, offsets 320–383:
`i_sequence` 320, `i_count` 328, `i_dio_count` 332, `i_writecount` 336,
`i_readcount` 340, **`i_fop` 344**, `i_flctx` 352, and then `i_data` starts at
360 so **`i_pages.xa_lock` is at 368 and `xa_head` at 376**. Five subsystems
on one 64-byte line: inode lifetime, write-access accounting, file-operations
dispatch, lock contexts, and the page cache's own lock. `do_dentry_open` reads
`i_fop` and writes `i_readcount` with a `lock incl`; `break_lease` loads the
`i_flctx` pointer unconditionally (`include/linux/filelock.h:486`) though it
only dereferences it when a lease context exists.

**Price, which was missing.** `struct inode` is 560 bytes with **8 bytes of
holes in total** (`pahole`: `sum members: 552, holes: 2, sum holes: 8`). There
is nowhere to move anything to. Every separation is growth — moving `i_pages`
off line 5 costs a tenth cache line per inode, on every inode in the system.
That has to be priced before it is proposed, and the existing layout series
did not price it.

**Prediction.** Moving `i_fop` and `i_flctx` off that line reduces HITM events
on a multi-process shared-inode open workload, with no change to struct size.

**Falsified if.** — and this is the problem — **it cannot be falsified on this
machine.** The patch's own stated gate is HITM reduction under `perf c2c`, and
WSL2 exposes no AMD IBS, so neither host nor guest can produce memory-event
data. `pahole` can confirm the layout changed and that it is size-neutral;
nothing available can confirm the benefit. The one signal that exists points
the wrong way: L1 misses per context switch +1.96% [+0.70, +3.11].

**Refined after `50-concurrency-and-scaling.md`.** The original claim was
right about `i_fop` and *understated* — it missed `i_pages` entirely — and
slightly too strong about `i_flctx`, which is loaded but not dereferenced on
an unlocked file.

**Status.** Structural for the layout, untestable here for the effect. Should
be sent upstream as a layout argument with the evidence problem stated, or not
sent at all — not carried as if it were measured.

---

## H5 — cgroup writeback attachment is the largest atomic concentration in the layer

**Claim.** More lock-prefixed instruction *pressure* (breadth × atomics) sits
in `fs-writeback.o` than anywhere else reachable from the VFS syscall surface.

**Mechanism.** `inode_switch_wbs` pressure 360 (breadth 45, 8 atomics),
`__inode_attach_wb` 292 (breadth 73, 4), `locked_inode_to_wb_and_lock_list`
219 (breadth 73, 3), `wb_io_lists_depopulated` 146 (breadth 73, 2),
`__mark_inode_dirty` breadth 73.

**Prediction.** On a write-heavy or `relatime` workload these appear in the
`function_profile` top twenty.

**Falsified if.** They do not execute on a warm read-only path at all —
`__mark_inode_dirty` gates most of the chain, so a read-only open/close loop
may never enter any of them. **This is the likely outcome** and it is why the
hypothesis exists rather than a patch.

**Status.** Open, and cheap to settle. Check before investing anything.

---

## H6 — The indirect dispatch is the price of the abstraction, not a defect

**Claim.** The retpoline thunks on the path walk cannot be removed without
changing what the VFS is, and any proposal to remove them should be rejected
on those grounds rather than evaluated on performance.

**Mechanism.** 433 indirect dispatch sites in the layer. The highest-pressure
ones — `pick_link` (4 sites, breadth 55), `lookup_fast` (3, 55),
`link_path_walk` (3, 55), `dput` (2, 78) — are `->d_revalidate`, `->lookup`,
`->permission`, `->get_link`, `->d_delete`. These are the filesystem boundary.

**Falsified if.** A devirtualisation scheme exists that preserves the
per-filesystem contract in `20-filesystems-and-vfs.md` — 25 filesystems, 11
implementing `->atomic_open`, 24 calling `finish_open()`, three of which can
legally return a *different* dentry than the one passed in, and one
(`bad_inode`) which returns `-EIO` having called neither helper.

**Status.** Structural. Recorded so it does not get re-proposed.

---

## H7 — The security layer is larger than the path walk and may dominate it

**Claim.** On a system with SELinux enforcing, LSM work may exceed path-walk
work, which would make every conclusion in H1 a statement about the wrong half
of the syscall.

**Mechanism.** `security/selinux/hooks.o` is 16 988 instructions;
`security/security.o` is 14 187 across 999 functions — the per-hook
`static_call` shims, averaging 14 instructions each. Together 31 175 against
`fs/namei.o`'s 15 204.

**Prediction.** `insn:k` per `openat` will differ substantially between
`selinux=0` and enforcing, on the same kernel.

**Falsified if.** The difference is small — the hooks are large in *code* but
most of it is policy-lookup paths that a warm workload with a cached AVC does
not enter.

**Status.** Open. Trivially testable: the guest already reports
`/sys/fs/selinux/enforce` in every report header, and a boot with `selinux=0`
costs nothing extra.

---

## H8 — `relatime` makes `struct inode` cacheline 1 write-hot, and nothing measured here has ever included it

**Claim.** Every number this project has produced omits `touch_atime`'s inode
write, because the guest root is mounted `noatime`, while real systems default
to `relatime`.

**Mechanism.** `scripts/mkrootfs.sh:48` writes
`/dev/vda / ext4 defaults,noatime 0 1`. `pahole` puts `i_size` at 80,
`i_atime_sec` 88, `i_mtime_sec` 96, `i_ctime_sec` 104 and the `_nsec` fields
at 112–123 — all cacheline 1 (64–127). `generic_fillattr` reads every one of
them on every `stat`; under `relatime`, `touch_atime` writes `i_atime` on the
same line. `touch_atime` has breadth 60.

Note this is a *different* line from H4's: the layout series targets
`i_fop`/`i_flctx` on line 5.

**Prediction.** Re-running any read-path benchmark with `relatime` will show
higher atomic and cache-miss counts than the `noatime` numbers on record.

**Falsified if.** `relatime`'s 24-hour update heuristic means `touch_atime`
almost never writes on a benchmark that runs for minutes — in which case the
gap is real but empty.

**Status.** Open. A measurement gap, not a finding about the kernel. Needs a
`relatime` mount in the rig before anything is claimed either way.

---

## H9 — `inode_hash_lock` is a single global spinlock on a hot path

**Claim.** Every filesystem that looks an inode up by number takes one
process-wide-global spinlock, on a *hit* as well as a miss, and container
workloads on overlayfs and FUSE do this constantly.

**Mechanism.** `fs/inode.c:61` —
`static __cacheline_aligned_in_smp DEFINE_SPINLOCK(inode_hash_lock);` — one
lock for the whole machine, not per-bucket and not per-superblock.
`iget5_locked` and `insert_inode_locked` take it unconditionally. The dcache
solved the identical problem years ago with per-bucket `hlist_bl` bit locks;
the inode hash never followed.

**Prediction.** A workload with many containers or FUSE mounts doing cold
lookups will show `inode_hash_lock` contention that does not fall with more
CPUs, and the ceiling will be global rather than per-object.

**Falsified if.** Warm workloads never reach it — the dcache answers before
the inode hash is consulted, so on a warm path this lock may be entirely
absent. That would make it a cold-path problem, which is real but different.

**Status.** Open, and out of scope for this project as currently framed. Noted
because it is the most upstream-shaped finding in the whole set: the fix is
structural, has a precedent in `fs/dcache.c`, and nothing here depends on it.

---

## H10 — `files_struct->file_lock` is the ceiling for threaded workloads, and it is not fixable

**Claim.** Every `open` and every `close` in a process takes one process-wide
spinlock shared by all its threads, and POSIX prevents fixing it.

**Mechanism.** `alloc_fd()` takes `spin_lock(&files->file_lock)`
(`fs/file.c:576`). POSIX requires `open` to return the *lowest available* file
descriptor, which is a global property of the fd table — it cannot be
computed per-CPU or per-thread without either breaking that guarantee or
reconciling under a lock anyway.

**Consequence for measurement.** This is why `sweep-bench.sh` uses processes
rather than threads, and says so at line 9. A thread sweep would measure
`file_lock`, not the dentry — and the dentry is what the reference-transfer
patch touches. Any future thread-based benchmark has to account for this or it
will attribute `file_lock` contention to the VFS change under test.

**Falsified if.** Someone produces a lowest-available-fd allocator that scales.
Recorded as a standing challenge rather than a task.

**Status.** Structural, and deliberately in the "not addressable" column. The
reason is written down so it is not re-proposed.

---

## H11 — `fops_get()` is a machine-wide contended word on every open on a modular filesystem

**Claim.** On a filesystem built as a module, every `open()` and every
`close()` on every CPU performs a cmpxchg on the same `module->refcnt`, and
the reference it takes is redundant with the one the superblock holds.

**Mechanism.** `do_dentry_open()`: `f->f_op = fops_get(inode->i_fop)` →
`try_module_get()` → `atomic_inc_not_zero(&module->refcnt)`
(`kernel/module/main.c`); `__fput()`: `fops_put()` → `module_put()` →
`atomic_dec_if_positive()`. One `atomic_t` per module, since 2014 when the
per-cpu module refcount was removed as "not called frequently". `sget_fc()`
already does `get_filesystem(s->s_type)` (`fs/super.c:903`), released in
`deactivate_locked_super()`, so the mount the file holds pins the module for
the file's whole life.

**Why unseen.** Every microbenchmark this project and Guzik's ran used tmpfs
or built-in ext4, where `owner` is NULL and `fops_get()` is free. On xfs,
btrfs, nfs, cifs, overlayfs or fuse as modules it is the most widely shared
written word on the open path — wider than the dentry, which only the openers
of one object share.

**Prediction.** `function_profile` on an open/close loop on a loop-mounted xfs
shows `try_module_get` hits = N on the baseline and 0 with patch 2; on ext4
built-in both are 0.

**Falsified if.** Some in-tree `->open` or `->release` relies on the file's
own module reference being distinct from the superblock's — i.e. a file whose
`f_path.mnt` can be dropped before its `f_op` is last used. `__fput()` puts
fops before `mntput()`, and `proofs/Vfsproof/FopsBorrow.lean` covers the
`replace_fops()` shapes; a counterexample would have to be a direct `f_op`
assignment to another module's operations, and none was found.

**Status.** Structural; patch 2. Counter test in `scripts/guest/vfs-verify.sh`.

---

## H12 — `stat` needs no reference at all

**Claim.** Every shared write a warm `stat()` performs exists to hand a pinned
`struct path` to `->getattr` and the LSM, and RCU plus `d_seq` already
protect what those references protect.

**Mechanism.** `complete_walk()` → `try_to_unlazy()` → `__legitimize_mnt()`
(`smp_mb`) + `lockref_get_not_dead()`; `vfs_getattr()`; `path_put()` →
`lockref_put_return()`. Inodes and mounts are freed through `call_rcu`; every
binding change on a dentry goes through a `d_seq` write section; the walk
already reads every earlier component this way.

**What blocked it.** `->getattr` may sleep (network filesystems, block devices,
encrypted symlinks), and `security_inode_getattr()` may sleep (label
initialisation) or, for AppArmor, allocate. Hence an opt-in per inode
(`IOP_GETATTR_RCU`), an internal `AT_GETATTR_RCU` flag so an opted-in
implementation can still decline, and a new LSM hook with a capability key
and a BPF gate (`05-proposal.md` §2.2).

**Prediction.** On the series, `function_profile` over N `statx()` of an ext4
file: `try_to_unlazy` 0, `lockref_get_not_dead` 0, `dput` 0,
`security_inode_getattr_rcu` N, `filename_lookup_op` N; baseline: N, N, N, —,
and `filename_lookup` N.

**Falsified if.** An opted-in `->getattr` (`ext4_getattr`, `ext4_file_getattr`,
`xfs_vn_getattr`, `btrfs_getattr`) sleeps or writes shared state on some path
not read here. Each was read in full; tmpfs was excluded for exactly that
reason (`shmem_recalc_inode()` side effect).

**Status.** Structural; patches 4–9; proved sound in
`proofs/Vfsproof/RcuStat.lean`. This is the kernel-side stat optimisation
`02-stat-path.md` §4 said did not exist.

---

## H13 — failed opens pay for a `struct file` they never use

**Claim.** `path_openat()` allocates the file before the walk, so every
ENOENT/EACCES/ENOTDIR/EISDIR/ELOOP/EEXIST pays `alloc_empty_file()` +
`fput_close()`: two slab operations (with an LSM blob), a `get_cred`/`put_cred`
pair on the process-wide cred, `nr_files` twice, `security_file_alloc/free`.
So does every `-ECHILD` and `-ESTALE` retry.

**Mechanism.** `fs/namei.c` `path_openat()`; `file` is not read by the walk;
`lookup_open()` and `vfs_open()` are the first consumers.

**Prediction.** `alloc_empty_file` hits per failed open: 1 on baseline, 0 on
the series; per successful open: 1 on both.

**Falsified if.** Something between `path_init()` and `do_open()`'s
`may_open()` reads the file. `proofs/Vfsproof/LazyAlloc.lean` proves the
NULL-file handling sound given that `lookup_open()` is the only setter of
`FMODE_CREATED`/`FMODE_OPENED` before `do_open()`, which is asserted from the
source.

**Status.** Structural; patch 3.

---

## Rejected

Kept because the reasons are the useful part.

**Per-operation stat work.** `vfs_getattr_nosec` and `generic_fillattr` are
287 instructions against `vfs_statx`'s 13 476 — about 2%. Making them cheaper
cannot matter. (`02-stat-path.md` §2.)

**Carrying the walk result between syscalls** — the `stat`-then-`open`
sequence. The dcache already *is* the carry-over. What remains repeated is
per-component `inode_permission` and `security_inode_permission`, and neither
is cacheable across syscalls without changing semantics: credentials and mode
can change in between, and LSM state is not ours to cache. (`02-stat-path.md`
§4.)

**`lockref` single-addition codegen.** Six ALU ops become two per cmpxchg
iteration, which is real and unconditional, but an open runs two to four
lockref operations — eight to sixteen instructions out of 6100, about 0.2%.
Measured `insn:k/open` +0.87% against a 1.11% between-boot threshold: too
small to see, exactly as the arithmetic predicts. Worth sending for shorter
generated code, not for a number. (`/usr/src/kbench/README.md`.)

**Making `i_readcount` per-cpu.** The trick that makes `mnt_writers` cheap
does not transfer: per-cpu counters cost memory proportional to object count,
and there are dozens of mounts but millions of inodes. (`50-concurrency-and-scaling.md`.)

**Consolidating VFS helpers.** Fan-in says the layer is already well factored
at the bottom — `fput` 150 callers, `putname` 91, `path_put` 71, `dput` 70,
`fdget` 62. There is no duplicated helper to merge.

---

## What would move the most hypotheses at once

One guest boot with `function_profile` armed over a mixed workload settles
H1, H2, H5, H7 and H9, and gives H3 its falsification test if a stat-only
sweep is added (on the baseline kernel, see H3). H11–H13 have their counter
tests in `scripts/guest/vfs-verify.sh`; the predictions are exact hit counts,
not timings, and are listed in `05-proposal.md` §8.

One further measurement is worth building and is not in the rig: the **unlazy
ratio** — `try_to_unlazy` / `try_to_unlazy_next` hit counts per walk, i.e. how
often RCU-walk is lost. Both survive out of line with `__pfx_` entries in
`System.map`, so unlike `lockref_*` they can actually be traced.
