# The proposal

Fifteen patches against Linux 7.3.0-rc3+824 (`518e5b794c06`), in `patches/`,
built as commits on the `vfs-series` branch of the worktree `/usr/src/linux-vfs`.
This document is the argument for them as a whole: what each one removes from
the warm path, why that is the thing to remove, what each costs, and what was
looked at and deliberately not touched.

Read `03-vfs-structure.md` first for the object model and `04-hypotheses.md`
for what was believed before the code was re-read. This document supersedes
one conclusion in `02-stat-path.md` (§4 there says there is no worthwhile
kernel-side stat optimisation; there is, and it is patch 6).

The series was designed by reading the compiled and source code of the open
and stat paths from the syscall entry to the last `mntput()`, writing down
every instruction that writes to memory another CPU can see, and asking of
each one whether the object it protects is really unprotected without it.
Three of them were not. Those three are the new patches. The rest of the
series is the earlier work, re-examined and kept where it survived.

---

## 1. The ledger

Every write to shared memory on the warm path — lock-prefixed instruction or
full barrier — for one `open(O_RDONLY)` + `close()` of a regular file and for
one `stat()`, on an ext4-like filesystem with the dcache warm and the walk
staying in rcu-walk. "Shared with" says who else writes that cacheline; that
is what decides whether the operation scales.

### open + close, before

| # | operation | instruction | line | shared with | needed? |
|--:|---|---|---|---|---|
| 1 | `__legitimize_mnt` | `lock addl` (smp_mb) | stack | nobody | yes (mount seq protocol) |
| 2 | `lockref_get_not_dead` (complete_walk) | `lock cmpxchg` | dentry L2 | every opener/stat-er of this dentry | yes — the file's reference |
| 3 | `lockref_get` (do_dentry_open path_get) | `lock cmpxchg` | dentry L2 | same | **no** — duplicates 2 |
| 4 | `i_readcount_inc` | `lock incl` | inode L5 | every opener of this inode | yes (leases, IMA) |
| 5 | `try_module_get` (fops_get) | `lock cmpxchg` loop | `module->refcnt` | **every open on the filesystem, machine-wide** | **no** — the mount pins the module |
| 6 | `get_cred` (alloc_empty_file) | `lock inc` | cred | every thread of the process | yes (f_cred outlives the task) |
| 7 | `spin_lock(files->file_lock)` (alloc_fd) | `lock` | files_struct | every thread of the process | yes (POSIX lowest fd) |
| 8 | `lockref_put_return` (terminate_walk) | `lock cmpxchg` | dentry L2 | as 2 | **no** — undoes 3 |
| 9 | `spin_lock(files->file_lock)` (close_fd) | `lock` | files_struct | as 7 | yes |
| 10 | `file_ref_put` | `lock xadd` | file L2 | nobody (private file) | yes |
| 11 | `module_put` (fops_put) | `lock cmpxchg` loop | `module->refcnt` | as 5 | **no** |
| 12 | `i_readcount_dec` | `lock decl` | inode L5 | as 4 | yes |
| 13 | `lockref_put_return` (__fput dput) | `lock cmpxchg` | dentry L2 | as 2 | yes — releases 2 |
| 14 | `put_cred` | `lock dec` | cred | as 6 | yes |

Plus, on every kernel with an LSM keeping per-file state, two slab
allocations and two frees (struct file and the LSM blob) where one of each
would do, and on every failed open all of the above from alloc_empty_file
onwards for a file that is thrown away.

### open + close, after (patches 1, 2, 9)

| # | operation | before | after |
|--:|---|---|---|
| 3, 8 | second dentry get, its put | 2 RMW on dentry L2 | gone (patch 1) |
| 5, 11 | module refcount | 2 RMW on a machine-wide word | **unchanged** — the patch that removed it was withdrawn, see 2.1 |
| — | LSM blob alloc/free | 2 slab ops | gone (patch 9) |
| — | failed open | full file alloc/free + cred pair | gone (patch 2) |

Dentry L2 traffic per cycle: 4 → 2. Machine-wide contended words: 1 → 1
(the module refcount stays; see 2.1).
Remaining shared writes are the ones that carry semantics: the file's own
dentry reference, the inode's reader count, the process's fd table and cred.

### stat, before

| # | operation | instruction | line | shared with |
|--:|---|---|---|---|
| 1 | `__legitimize_mnt` | `lock addl` (smp_mb) | stack | nobody |
| 2 | `lockref_get_not_dead` (complete_walk) | `lock cmpxchg` | dentry L2 | every opener/stat-er |
| 3 | `lockref_put_return` (path_put) | `lock cmpxchg` | dentry L2 | same |

### stat, after (patch 6, on ext4/xfs/btrfs, SELinux or no LSM)

None. The syscall performs no write to memory another CPU reads. That is the
result the whole stat side of this project was looking for and had concluded
did not exist.

The mount count (`mnt_add_count`, per-cpu) and `rcu_read_lock/unlock`
(per-task or per-cpu counter) are not in the tables because they are not
shared writes.

---

## 2. The three things found by reading

### 2.1 The module reference nobody needed — WITHDRAWN

**This patch was in the series and has been removed. It is kept here because
the analysis is still correct and someone will rediscover the idea.**

`do_dentry_open()` does `f->f_op = fops_get(inode->i_fop)` and `__fput()`
does `fops_put(file->f_op)`. `fops_get` is `try_module_get(owner)`, a cmpxchg
loop on one `atomic_t` per module -- a single word for the whole machine.
Every open and every close on a filesystem built as a module lands two
contended RMWs on it, regardless of which file, directory or CPU. xfs, btrfs,
nfs, cifs, overlayfs and fuse are modules on every distribution.

The reference is redundant: `sget_fc()` already does
`get_filesystem(s->s_type)` and `deactivate_locked_super()` releases it after
`kill_sb`. The file holds `f_path.mnt`; the mount holds the superblock active;
the superblock holds the module.

That reasoning still holds. Two things killed the patch anyway.

**It costs 17 instructions in `do_dentry_open()` on every open, whether or not
the filesystem is a module.** Measured by building `fs/open.o` with and
without the change: 330 instructions against 313. The check
`f_op->owner == i_sb->s_type->owner` is a three-deep dependent load
(`inode -> i_sb -> s_type -> owner`) and cannot be made cheaper by
restructuring -- a version that tested `owner` first, to leave early on a
built-in filesystem, recovered exactly one instruction because GCC had
already common-subexpression-eliminated the repeat.

So on a kernel with the filesystem built in -- which is what this project
benchmarks, `CONFIG_EXT4_FS=y` -- the patch is pure cost with no possible
benefit. It was one of the contributors to a reproducible +2% cycles-per-open
regression in the series.

**And the correctness argument has to hold for every filesystem, not the
common ones.** The invariant is that `f_op` always lives in the module the
superblock pins. That is true for a plain filesystem and needs rechecking for
every stacked, synthetic or `replace_fops()`-using path -- `FopsBorrow.lean`
proved it for the three owner cases, but a proof of the model is not a proof
that every caller in the tree matches the model. That is a large and permanent
review burden for two atomics.

Removed on those two grounds together: it cannot pay for itself in the
configuration we can measure, and it asks reviewers to accept a subtle
invariant across every filesystem in the tree. If it is revisited, it needs
wall-clock numbers from a kernel with the filesystem built as a module, where
the contention it removes is real.

### 2.2 stat does not need a reference (patches 3–8)

`stat` is the one path-based syscall whose operation reads and does nothing
else. Yet `filename_lookup()` ends with `complete_walk()` → `try_to_unlazy()`
→ one atomic on the dentry, a full barrier for the mount, `rcu_read_unlock()`;
`vfs_getattr()` reads a few dozen bytes; `path_put()` does the second atomic.
The references exist to give `->getattr` and the LSM a pinned `struct path`.
They protect nothing the RCU section does not already protect: `destroy_inode()`
frees through `call_rcu`, mounts through `call_rcu`, and the dentry's `d_seq`
already tells every earlier component of the walk whether the dentry it read
is still bound to the inode it read.

So: apply the operation *before* leaving rcu-walk, then re-check `d_seq` and
`mount_lock`. That is what `filename_lookup_op()` does, with a `struct path_op`
of two callbacks — `->rcu`, called with nothing pinned, and `->ref`, called the
old way. `vfs_statx()` becomes one call to it.

Six decisions in the design, each with the alternative that was rejected:

1. **Opt-in per inode, not per filesystem type.** `IOP_GETATTR_RCU` in
   `i_opflags` (bit 9; the field is a `u16` with nine bits used), set where
   the filesystem installs `i_op`. A per-`file_system_type` flag like
   `FS_MGTIME` was rejected because ext4's encrypted-symlink `->getattr` reads
   a block while its other five do not; the flag has to follow the operations
   table, and `i_opflags` already caches properties of `i_op` (`IOP_LOOKUP`,
   `IOP_NOFOLLOW`, `IOP_FASTPERM_MAY_EXEC`).

2. **The filesystem is told.** `AT_GETATTR_RCU` (kernel-internal, `0x80000000`,
   passed in `query_flags`) lets an opted-in `->getattr` return `-ECHILD` for
   the cases it cannot do — ext4's encrypted symlink with no cached target. An
   unaware filesystem never sees the flag because it never set the opt-in.

3. **The contract is stated as side effects, not as sleeping.** The inode
   handed over may be mid-eviction (any filesystem) or mid-reuse (xfs, which
   recycles inode memory without a grace period). Reading garbage is fine; the
   result is discarded. *Writing* is not fine: `shmem_getattr()` reconciles
   block accounting as a side effect, and running that against an inode being
   evicted is a bug. tmpfs is therefore **not** opted in, and the porting note
   says why. ext4, xfs and btrfs were read function by function
   (`ext4_getattr`, `ext4_file_getattr`, `xfs_vn_getattr` and its five
   helpers, `btrfs_getattr`): reads, one spinlock, one tracepoint.

4. **The seqcount is checked on every result, not only on success.**
   A hard error — the LSM denying, `-EIO` from a shut-down xfs — computed on
   an inode the dentry no longer points at is as wrong as a wrong kstat.
   `path_lookupat_op()` rechecks before looking at the return value.
   `proofs/Vfsproof/RcuStat.lean` proves the patched check never returns
   anything ref-walk would not, and shows the check-on-success-only variant
   denying a stat of the wrong inode.

5. **`-ECHILD` from `->rcu` does not restart the walk.** It falls into
   `complete_walk()` where it stands and calls `->ref`. A filesystem that has
   not opted in pays one walk, exactly as today; the double-walk regression
   for NFS/FUSE/cifs that a naive "try RCU, else retry" design would have had
   is proved absent (`never_more_walks_than_today`).

6. **The LSM gets a new hook rather than a flag on the old one.** The precedent
   is `inode_follow_link(dentry, inode, bool rcu)`, but `inode_getattr` is on
   the BPF LSM's sleepable list and existing sleepable programs must keep
   working, so the RCU variant is a new hook, `inode_getattr_rcu`, default 0,
   with three safety nets:
   - `security_add_hooks()` disables it system-wide (static key) when any LSM
     registers `inode_getattr` without it. AppArmor, Smack and TOMOYO do; on
     kernels running them, stat is unchanged until they implement it.
   - SELinux implements it exactly as it implements `inode_permission` under
     `MAY_NOT_BLOCK`: `inode_security_rcu(inode, true)` returns `-ECHILD` if
     the label is not initialised, otherwise the same AVC decision; auditing
     under RCU is already what `selinux_inode_follow_link(rcu=true)` does,
     with `GFP_ATOMIC` in `common_lsm_audit()`.
   - The BPF LSM registers a stub for every hook, so it would silently
     "implement" the new one and bypass programs attached to the old one. Its
     entry for `inode_getattr_rcu` is a gate that returns `-ECHILD` while any
     program is attached to `inode_getattr`; the trampoline code counts
     attachments, incrementing before the text is patched and decrementing
     after it is restored. With nothing attached — the normal state — the gate
     is a load and a compare.

What it saves: everything in the stat ledger, on every stat that stays in
rcu-walk on ext4/xfs/btrfs. What it does to the n+1 pattern behind `ls -l`,
`find`, `rg`, every build system: `readdir` then one `statx(dirfd, name)` per
entry becomes a sequence of read-only operations on the directory's dentries.
`02-stat-path.md` was right that the walk is 96.5% of stat's instructions; it
was wrong to conclude from that that nothing on the stat side was worth doing.
The 3.5% that remained was where all the shared writes were.

`filename_lookup_op()` is written for more than stat. `faccessat()` (walk +
`inode_permission`, which already has `MAY_NOT_BLOCK`), `readlinkat()` on a
cached link, and `getxattr()` of `security.selinux` are the next users; they
are not in this series because each needs its own reading of the side-effect
question.

### 2.3 A struct file for an open that fails (patch 3)

`path_openat()` allocated the file before the walk and freed it after the
walk failed. The walk is where opens fail — ENOENT, EACCES, ENOTDIR, EISDIR,
ELOOP, EEXIST — and none of those needed a file. Each failure paid
`alloc_empty_file()` and `fput_close()`: two slab allocations (with an LSM),
`get_cred`/`put_cred` on the process-wide cred, `nr_files` twice,
`security_file_alloc/free`, the memsets in `init_file()`. Roughly three
hundred instructions and two shared RMWs per failure. Compilers probing
include paths, the loader probing library paths, shells and interpreters
probing configuration locations do this by design; a build's opens fail on
purpose a visible fraction of the time.

The same allocation was also thrown away on every `-ECHILD` fall-back to
ref-walk and every `-ESTALE` retry, because `do_file_open()` calls
`path_openat()` up to three times.

The patch allocates in the two places that first need a file: before
`lookup_open()` (create, `->atomic_open`) and in `do_open()` right before
`vfs_open()`, after `may_open()`. `do_open()` reads `f_mode` once at entry,
treating a NULL file as neither `FMODE_OPENED` nor `FMODE_CREATED` — which is
sound only because a NULL file at that point means `lookup_open()` never ran,
a control-flow property that `proofs/Vfsproof/LazyAlloc.lean` proves
(`null_file_means_lookup_open_did_not_run`) along with ownership on all nine
exits and the allocation counts before and after.

One ordering change is visible: an open that would fail in the walk on a
system at `file-max` now returns the walk's error, not `ENFILE`. Both are
correct answers to a request that cannot succeed.

---

## 3. The earlier work, re-examined

**Patch 1 — the dentry reference transfer.** Unchanged from
`kbench/patches-dopen`; 13 theorems in `Open.lean` cover all three exits of
`do_dentry_open()` × `O_TRUNC` and reject Guzik's withdrawn v4 and the
naive conditional clear. Ours keeps `vfs_open()` for its other callers and
consumes only the dentry, because `do_open()` still uses `nd->path.mnt` for
`mnt_drop_write()`. It halves dentry-line traffic per open/close. The +80% at
8 processes measured for it is still unattributed (H3); the design argument
does not depend on the number.

**Patch 10 — the LSM blob in the file.** New, but it belongs with the
allocation work. `filp_cache` is `SLAB_HWCACHE_ALIGN`, so a 176-byte
`struct file` already occupies 192 bytes; SELinux's 16-byte blob fits in the
padding and its separate 16-byte allocation disappears. Larger blobs (AppArmor
24, Landlock ~32) round to 256, which is what the two objects took together.
One `kmem_cache_zalloc`/`kmem_cache_free` pair fewer per open/close, and the
blob on the file's own lines instead of a pointer chase. `security_init()` runs
before `files_init()` so the size is final when the cache is created.

**Patch 12 — lockref single addition.** Codegen only, ~0.2% of an open;
kept because shorter code is unconditional. Not a performance claim.

**Patches 13–15 — the inode and address_space layout.** Kept, with the price
that `04-hypotheses.md` H4 says was missing: `struct inode` has 8 bytes of
holes, so every separation is growth — except that patch 14 pays for
`i_data`'s alignment with the cold `i_devices`/`i_pipe` unions rather than
padding, and `sizeof(struct inode)` stays 560. Verified with `pahole` on the
built `fs/inode.o`: `i_fop` 64, `i_flctx` 72, `i_count` 344, `i_readcount`
356, `i_data` 384 — a cacheline boundary — so the `i_pages` false sharing that
`50-concurrency-and-scaling.md` found on line 5 is resolved by the same move
that the series already made for `i_fop`. The benefit remains unmeasurable on
this machine (no IBS, no `perf c2c`); the layout is a structural argument and
is presented as one.

**Patch 11 — the openat2 selftest.** A one-line fix for the orphaned
`TARGETS += openat2`; the four RESOLVE_* binaries are never built today. Sent
first so that the openat2 surface is actually tested when patch 6 lands.

---

## 4. Order and dependencies

    1  fs: hand the path walk's dentry reference to the opened file
    2  fs: allocate the struct file only once an open can no longer fail cheaply
    3  lsm: add inode_getattr_rcu, the rcu-walk counterpart of inode_getattr
    4  selinux: implement inode_getattr_rcu
    5  fs: answer statx() without leaving rcu-walk when the filesystem allows it
    6  ext4: let stat() run ->getattr in rcu-walk
    7  btrfs: let stat() run ->getattr in rcu-walk
    8  xfs: let stat() run ->getattr in rcu-walk
    9  fs: embed the LSM's per-file blob in the struct file allocation
    10 selftests: point the openat2 target at where the tests actually live
    11 lockref: adjust the count with a single addition
    12 fs: move i_fop and i_flctx off the refcount cacheline in struct inode
    13 fs: place inode->i_data on a cacheline boundary
    14 fs: regroup struct address_space by read-hot vs write-hot fields

"fs: don't pin the filesystem module per open when the mount already does"
was patch 2 and has been withdrawn; see 2.1. Everything after it moved up one.

Patch 2 touches `do_open()` after patch 1 and is written on top of it.
Patches 3–8 are one series; 5 is useless without 3, 6–8 are no-ops without 5,
and 5 is what makes 6 do anything on an SELinux system. Everything else is
independent and separately revertable. 11 and 12 could go first or last.

---

## 5. The axes the work was asked to cover

| axis | what the series does |
|---|---|
| **backwards compatibility** | No UAPI change. No struct layout visible to userspace changes. `statx` results are bit-identical: the RCU path fills the same `kstat` through the same `->getattr` and the same mount fields. `ENFILE` vs walk error ordering on a full file table is the one observable difference, documented in patch 3. |
| **32-bit and 64-bit** | Nothing in the series is word-size dependent. `IOP_GETATTR_RCU` is bit 9 of a `u16`; `FMODE_FOPS_BORROWED` bit 8 of a 32-bit `fmode_t`; `AT_GETATTR_RCU` is `0x80000000` in a `u32`. The layout patches were checked for size neutrality on x86-64 only; `40-abi-and-wordsize.md` §5.3 gives the procedure for arm32/ppc32 and it has not been run — that is the one open item on this axis. `i_size_read()` under the RCU getattr is the seqcount loop on 32-bit SMP, which is fine under `rcu_read_lock()`. |
| **single thread** | Patches 3 and 10 are pure instruction-count wins (no allocation on failure; one allocation instead of two). Patch 6 removes ~120 instructions and a full barrier from every stat. Patch 12 shortens the lockref loop. |
| **multi thread / multi process** | Patches 1, 2 and 6 remove contended RMWs: dentry line (1, 6), machine-wide module word (2). `files->file_lock` and `cred->usage` remain for threads of one process, by design (§7). Processes, not threads, are where the removed contention was the ceiling — see H10 for why the rig measures processes. |
| **cache lines** | Patches 13–15 separate read-hot from write-hot in `inode` and `address_space` with no growth; patch 10 puts the LSM blob on the file's lines; patch 6 makes stat touch no shared line for writing. |
| **memory structure** | Patch 10: one object per file instead of two, memory-neutral (SELinux: 16 bytes saved per file). Patch 3: no transient file object for failed opens. `sizeof(struct inode)` unchanged at 560. |
| **instructions** | Removed per open/close on ext4: ~80 (blob), 2 lockref loops (~30 each incl. retpoline-free), module ops on modular fs (~40 + contention). Per stat: ~120 + `mfence`. Per failed open: ~300. The static graph in `graphs/` can be regenerated on the new objects to count exactly; see §8. |
| **cascades and n+1** | The `readdir` + `stat`×n pattern is now n read-only operations (patch 6). The failed-open cascade (walk fails → allocate → free → retry → allocate again) is gone (patch 3). Deferred work from `fput` is unchanged. |
| **reuse** | The one reuse the code permits — carrying the walk's reference into the file — is patch 1. Cross-syscall reuse remains rejected (`02-stat-path.md` §4). `filename_lookup_op()` is itself a reusable primitive for the other read-only path syscalls. |
| **open / stat dynamics** | `stat` then `open` on the same path: before, 3 + 4 = 7 dentry RMWs; after, 0 + 2 = 2. `open` then `fstat`: `fstat` was already reference-free (fd path); open halves. |

---

## 6. What was checked before writing each patch

For each patch, the sections of `10-validation-rules.md` that constrain it and
what was verified against them:

- **Patch 1**: §5.1 (`FMODE_OPENED` contract) and §5.2 (path ownership through
  `path_openat`) — proved in `Open.lean`, including the `LateErr` exit the
  rules document as rule 189.
- **Patch 2**: §5.4 (`f_path` lifetime: the mount reference is what pins the
  module, and `file_put_fops()` runs before `mntput()` in `__fput()`), §3.3
  (`vfsmount` reference lifetime). `20-filesystems-and-vfs.md` §14.1 (cifs
  rewrites `f_op`) — same module, bit stays valid.
- **Patch 3**: §1.7 (order of checks in `do_open()`, unchanged: the allocation
  slots in after `may_open()`), §5.1 (`FMODE_CREATED`/`OPENED` only from
  `lookup_open()`), §4.2 (allocation must not happen in rcu-walk: both sites
  are after unlazy).
- **Patch 6**: §4.1–4.3 (the two modes, leaving RCU, `terminate_walk`),
  §7.1–7.6 (stat call chain, request/result masks, sync flags, `AT_*`,
  `STATX_ATTR_*`, torn reads — unchanged), §2.3 (LSM RCU and sleeping — the
  new hook's contract), §6.5/§2.5 (audit: the RCU path is taken only with a
  dummy audit context), §8.3 (what can change between lookup and operation:
  answered by the seqcount check).
- **Patches 7–9**: `20-filesystems-and-vfs.md` §2, §4, §5 for what each
  `->getattr` touches; each commit message lists the functions read.
- **Patch 10**: §5.1 nothing; init order `security_init()` → `files_init()`
  verified in `init/main.c`.
- **Patches 13–15**: `40-abi-and-wordsize.md` §3.1 (internal layout is
  reorderable), §4.3 (`RANDSTRUCT` makes them no-ops, asserted at build time
  only under `!RANDSTRUCT`).

---

## 7. Looked at and left alone

Each with the reason, so it is not re-proposed without a new argument.

**`cred->usage`** (2 RMWs per open/close, shared by all threads of a
process). The file's cred must outlive the task; a per-cpu reference would
need a designated "kill" event and cred has no single owner. In threaded
processes the fd table lock already serialises open/close, so this is a
second-order effect behind a first-order one that POSIX forbids fixing.

**`files->file_lock`** — H10. Lowest-available-fd is a global property of
the table. Not fixable; the reason is recorded so it stays unproposed.

**`i_readcount`** (2 RMWs on inode L5). Read by `check_conflicting_open()`
when a write lease is requested and by IMA. Cannot be computed lazily (no
per-inode file list) and per-cpu costs memory proportional to inode count.

**tmpfs opt-in for RCU stat.** `shmem_getattr()` calls
`shmem_recalc_inode()` as a side effect. Under RCU that would run against an
inode being evicted. The fix is in tmpfs (do the reconciliation at truncate
completion, not in getattr), not in the VFS, and is for its maintainers.

**AppArmor `inode_getattr_rcu`.** `common_perm_cond()` builds a path name
into a buffer from `aa_get_buffer()`, which may sleep; the `in_atomic` variant
exists and returning `-ECHILD` when it yields nothing would be a correct
implementation. Not written here because AppArmor's mediation rules on
getattr were not studied; the framework handles its absence safely.

**`struct filename` on the stack.** 192 bytes from `names_cache` per
path-based syscall, ~60–80 instructions of slab fast path. The `__filename_head`
has 4 bytes of padding for an on-stack flag and audit contexts can be detected
at `getname()` time. Deferred: it touches 91 `putname()` callers' assumptions
and the gain is ~1% of an open. A candidate for the next series, done for
`openat`/`statx` only.

**`struct file` line 2 (`f_ra`, `f_ref`).** Both written on every buffered
read of a shared fd. Moving `f_ra` next to `f_pos` would put all per-read
writes on one line, but Brauner reorganised this struct recently with
measurements this project cannot reproduce. Not touched.

**`inode_hash_lock`** — H9. A global spinlock on a cold path. Upstream-shaped,
with the dcache's per-bucket bit locks as precedent. Out of scope.

**Kernel-side readdir+stat batching.** Rejected for the reasons upstream has
rejected it repeatedly; patch 6 makes the per-entry stat cheap instead.

**Devirtualising `->d_revalidate`/`->permission`/`->getattr`** — H6. The
filesystem boundary. Not a defect.

---

## 8. Validation: what is known, what the VM must show, what needs hardware

**Proved** (`proofs/`, 27 theorems, `lake build` silent): reference balance
on every exit for patch 1; file ownership on every exit and the NULL-file
soundness argument for patch 2; seqcount soundness and the no-double-walk
property for patch 5. (`FopsBorrow.lean`, 6 theorems, went with the withdrawn
module-pin patch.)

**Compiled**: every touched object in the kbench configuration, plus xfs,
btrfs and fscrypt enabled for the opt-in patches; a full `bzImage + modules`
build of the series.

**To show in the guest** (`scripts/guest/vfs-verify.sh`, function_profile
hit counts — exact, not timing):

| loop (N iterations) | function | baseline | series |
|---|---|--:|--:|
| `stat()` of an ext4 file | `filename_lookup` | N | 0 |
| | `filename_lookup_op` | — | N |
| | `try_to_unlazy` | N | 0 |
| | `security_inode_getattr_rcu` | — | N |
| | `security_inode_getattr` | N | 0 |
| | `dput` | N | 0 |
| `open()` of a missing file | `alloc_empty_file` | N | 0 |
| `open()`+`close()` of an ext4 file | `alloc_empty_file` | N | N |
| | `try_module_get` | 0 | 0 |
| `open()`+`close()` on xfs (module) | `try_module_get` | N | 0 |
| any | `filp` slab object size | 192 | 192 (SELinux) |

**Static comparison of the compiled objects** (`tools/static-graph.py` on the
same object set from both build trees; reachable sets are upper bounds, not
hot paths — see `01-open-path.md` §2):

| root | baseline funcs / insns / lock-prefixed | series funcs / insns / lock-prefixed |
|---|---|---|
| `__x64_sys_openat` | 356 / 20 610 / 77 | 345 / 19 898 / 69 |
| `do_statx` | 212 / 12 592 / 34 | 199 / 11 811 / 31 |
| `__x64_sys_statx` | 221 / 13 022 / 34 | 217 / 12 579 / 34 |

Eight lock-prefixed instructions leave the reachable set of `openat` (the
module get/put and the LSM blob's slab operations), three leave `do_statx`'s.
Per function, `path_openat` grows from 592 to 700 instructions and
`do_dentry_open` from 304 to 330: the lazy allocation adds a second call site
and its error handling, and the borrow adds the owner comparison. Those are
static sizes; on the warm success path the same instructions execute as
before minus the removed atomics, and on the failure path far fewer. The
`lockref` loops shrink as patch 12 predicts (`lockref_get` 44 → 36).

**Only on real hardware**: whether removing the RMWs changes wall-clock
throughput at N processes (the rig's guest cannot resolve it — `kbench/README.md`),
and whether the layout patches reduce HITM (`perf c2c`, needs IBS/PEBS).
The `will-it-scale` `open1`/`stat` variants on a modular filesystem with
many processes are the experiments; the predictions are in the ledger.

---

## 9. Sending it

Patches 11 and 12 first, alone: trivial, no dependencies, and 11 makes the
openat2 tests run for the rest.

Patch 1 next, to linux-fsdevel with Guzik and Viro on copy: it is the
conservative version of a patch both have written, with the case analysis
mechanised.

Patch 2 to linux-fsdevel and the module maintainers: the argument is
`sget_fc()`'s `get_filesystem()`; expect the question "why not make
`module->refcnt` per-cpu again" — the answer is that this removes the
operation rather than making it cheaper, and it is VFS-local.

Patch 3 to linux-fsdevel: expect scrutiny of `do_open()`'s NULL handling;
point at the proof and the `ENFILE` ordering note.

Patches 4–9 as one series to linux-fsdevel, linux-security-module, selinux,
bpf, and the three filesystem lists: the LSM hook design (§2.2 item 6) is
where the discussion will be. The BPF gate should be reviewed by KP Singh;
the SELinux hook by Paul Moore; the contract wording in `porting.rst` by
Viro and Brauner.

Patch 10 to linux-fsdevel and linux-security-module: memory-neutral, one
allocation fewer; expect a request to measure `filp` slab occupancy on
AppArmor and Landlock kernels.

Patches 13–15 last, or not at all until `perf c2c` numbers exist: the layout
argument is sound but the evidence problem is real and should be stated in
the cover letter rather than discovered in review.

`git format-patch -s` adds the Signed-off-by; none is in the files here.
