# Concurrency and scaling

What serialises in the VFS, what scales, and where the shared cache lines are.
Same tree and same build as the rest of this directory: Linux 7.3.0-rc3+824
(`518e5b794c06`), gcc 15.2.0 `-O2`, `/usr/src/kbench/builds/baseline`.
Graph: `graphs/vfs-full.json` (4378 functions). Layout: `pahole` on
`builds/baseline/vmlinux`.

This document owns the **performance and scaling** view. The **correctness**
view of the same locks — ordering, what may not sleep, what must be re-checked
— is `10-validation-rules.md` section 8 (rules 291-312), and is not repeated
here. Where a scaling argument depends on a rule, the rule is cited by number.

Nothing here is a timing. Every claim is either a property of the emitted code,
a property of the struct layout, or a statement about which lock a named
function takes, and each is cited to a line of source you can read.

---

## 0. Ground rules

**`L1_CACHE_BYTES` is 64 on this build.** `arch/x86/include/asm/cache.h:8-9`
defines it as `1 << CONFIG_X86_L1_CACHE_SHIFT`, and the baseline config has
`CONFIG_X86_L1_CACHE_SHIFT=6` (`builds/baseline/config:408`). Every line
assignment in section 2 is therefore a statement about a 64-byte line. On a
machine with a 128-byte line, or with adjacent-line prefetch treating pairs of
lines as a unit, the field-to-line mapping changes and so do the conclusions.
Nothing in section 2 survives a change to that constant unchanged.

Other config facts the rest of this document leans on, all from
`builds/baseline/config`:

    CONFIG_SMP=y                 (:373)   per-cpu variants are the ones compiled
    CONFIG_NR_CPUS=64            (:431)
    CONFIG_NUMA=y                (:467)   list_lru is per-node
    CONFIG_MEMCG=y               (:213)   list_lru is also per-memcg
    CONFIG_PREEMPT_RCU=y         (:170)
    CONFIG_MITIGATION_RETPOLINE=y (:548)  every indirect dispatch is a thunk
    CONFIG_RANDSTRUCT_NONE=y     (:4940)  layout is the source order
    CONFIG_DEBUG_VFS is not set  (:5380)  no lockdep_assert cost in the numbers
    CONFIG_SECURITY_SELINUX=y    (:4881)

`CONFIG_SMP=y` matters more than it looks. It selects the per-cpu forms of the
mount counters (`fs/mount.h:56-61`), it makes `USE_CMPXCHG_LOCKREF` possible
(`include/linux/lockref.h:21-23`), and it turns on the bit-spinlock in the
dcache hash heads (`include/linux/list_bl.h:21-25`). A UP kernel is a different
program on every axis in this document.

**Terminology.** *Per-object* means the state is one instance per dentry,
inode or file: spreading the workload over more objects spreads the contention.
*Per-superblock* means one instance per mounted filesystem. *Global* means one
instance in the kernel, and there is no workload shape that escapes it.

---

## 1. The shared-state inventory

Every piece of VFS state that two CPUs can touch on a hot path. "Hot path"
means: reached by `openat`, `statx`, `read`, `write`, `getdents64` or `close`
on a warm cache, not by mount, unmount, freeze or shrink.

| state | granularity | protected by | written per hot op? | bottleneck workload |
|---|---|---|---|---|
| `dentry->d_lockref` | per-dentry | itself (cmpxchg, spinlock fallback) | yes, 4x per open/close | C4, C3 |
| `dentry->d_lock` | per-dentry | spinlock inside `d_lockref` | no, on the warm path | U1-U4, shrink |
| `dentry->d_seq` | per-dentry | `d_lock` on write | no | U3, U4 |
| dcache hash bucket | global table, per-bucket bit-lock | `hlist_bl` bit 0 | no (RCU read) | U1, A9 (negative churn) |
| `rename_lock` | **global** seqlock | itself | no (seqcount read) | U3, U4 |
| `in_lookup_hashtable` | **global**, 1024 buckets | `hlist_bl` bit 0 | only on a dcache miss | A11, A12, C3 cold |
| `sb->s_dentry_lru` | per-sb x per-node x per-memcg | `list_lru_one.lock` | first dput to zero only | memory pressure |
| `nr_dentry*` | per-cpu longs | none | on alloc/free/LRU move | none |
| `inode->i_count` | per-inode | bare atomic | yes on `iget`/`iput` | C4, C6 |
| `inode->i_lock` | per-inode | spinlock | last `iput` only | U2, writeback |
| `inode_hash_lock` | **global** spinlock | itself | inode instantiation only | A11, A12, M5 |
| `sb->s_inode_lru` | per-sb x per-node x per-memcg | `list_lru_one.lock` | last `iput` of a cacheable inode | U1, memory pressure |
| `sb->s_inode_list_lock` | per-sb | spinlock | inode instantiation only | A11, U1 |
| `inode->i_rwsem` | per-inode | rwsem | shared on lookup/readdir, **exclusive on write and `O_CREAT` parent** | F3, D3, Z-block writes |
| `i_writecount` / `i_readcount` | per-inode | bare atomics | **yes, every open and every close** | C4, C6 |
| `inode->i_state` waits | **global** 256-entry table | `bit_wait_table` | only when `I_NEW` is contended | A12 |
| `inode->i_flctx` | per-inode | `i_opflags & IOP_FLCTX` gate | no (gate is a read) | none |
| `inode->i_data.i_pages` | per-inode | xarray `xa_lock` / RCU | read every page lookup, written on insert/evict | Z4-Z6, C4 |
| `file->f_ref` | per-file | biased atomic | **only when the file is shared** | C5 |
| `file->f_pos_lock` | per-file | mutex | only when `f_count > 1` | C5 |
| `files_struct->file_lock` | per-process (shared by threads) | spinlock | **yes, every open and every close** | C5 |
| `files_struct->fdt` | per-process | RCU | no | C5 at resize |
| `nr_files` | per-cpu counter, batch 32 | per-cpu, global on overflow | ~1 in 32 opens | none |
| `mount_lock` | **global** seqlock | itself | no (seqcount read on walk) | mount storms |
| `mount_hashtable` | global table | RCU | no | A7 |
| `mnt_pcp->mnt_count` | per-mount per-cpu | preemption | yes, per `path_get` | none |
| `mnt_pcp->mnt_writers` | per-mount per-cpu | preemption | yes, per `mnt_want_write` | none |
| `namespace_sem` | **global** rwsem | itself | never on a read path | mount storms |
| `sb->s_umount` | per-sb rwsem | itself | never on a hot path | sync, shrink |
| `sb->s_writers.rw_sem[3]` | per-sb percpu-rwsem | per-cpu counter | yes on every write, per-cpu | freeze only |
| `sb->s_active` | per-sb atomic | itself | never on a hot path | none |
| `fs_struct->seq` | per-process (shared by threads) | seqlock | no in RCU walk, **spinlock in ref-walk** | C5 |

The rest of this section takes them one at a time.

### 1.1 `dentry->d_lockref` — the one that actually matters

`struct lockref` is 8 bytes: a `spinlock_t` and an `int count` in a union with
an `aligned_u64 lock_count` (`include/linux/lockref.h:25-35`). The fast path is
`CMPXCHG_LOOP` (`lib/lockref.c:11-27`): it reads the 8-byte word, checks that
the embedded spinlock is *unlocked* (`lib/lockref.c:16`), and does a
`try_cmpxchg64_relaxed` on the pair (`lib/lockref.c:19-21`). The retry budget is
**100** (`lib/lockref.c:12`); on exhaustion it falls out to the spinlock
(`lib/lockref.c:24-25`). x86 always has this: `arch/x86/Kconfig:138` selects
`ARCH_USE_CMPXCHG_LOCKREF` unconditionally.

One exception worth knowing: `lockref_put_return` has **no** spinlock fallback
— it returns `-1` and makes the caller take the lock (`lib/lockref.c:88-99`).
That is the one `dput` uses.

Emitted cost, from `graphs/vfs-full.json`:

| | insns | atomics |
|---|---:|---|
| `lockref_get` | 44 | 1 cmpxchg |
| `lockref_get_not_dead` | 59 | 1 cmpxchg |
| `lockref_put_return` | 40 | 1 cmpxchg |

VFS users, and only these: `lockref_get` from `dget()`
(`include/linux/dcache.h:364`); `lockref_get_not_zero` from `dget_parent()`
(`fs/dcache.c:1108`); `lockref_get_not_dead` from `d_alloc_parallel()`
(`fs/dcache.c:2787`) and from the three RCU-to-ref transitions in `fs/namei.c`
(`:874`, `:995`, `:1005`); `lockref_put_return` from `fast_dput()`
(`fs/dcache.c:939`), which is its **only** VFS caller.

`lockref_put_or_lock` has no dcache caller at all in this tree — the remaining
users are erofs, xfs and gfs2.

**Granularity: per-dentry.** Two processes opening two different files in two
different directories share nothing here. Two processes opening *the same* file
do four RMWs each per open/close cycle on the same 8 bytes
(`01-open-path.md` section 3). Two processes opening two different files in the
*same* directory share the parent dentry's `d_lockref` in ref-walk, and share
nothing in RCU-walk, which is why C2 and C3 are different rows in the matrix.

**Workload: C4** (N processes, one shared inode) is the direct hit. **C3** (N
processes, distinct inodes, one shared parent) is the indirect one, and only
when the walk leaves RCU mode.

### 1.2 `dentry->d_lock`

The spinlock inside `d_lockref`, so the *same 8 bytes and the same cache line*.
What it protects is rule 292. On the warm open path it is not taken at all:
`fast_dput` reaches `retain_dentry(dentry, false)` (`fs/dcache.c:971`) and
returns without ever acquiring it, provided the dentry is hashed, connected,
has no `->d_delete`, is not `DCACHE_DONTCACHE`, and already carries both
`DCACHE_LRU_LIST` and `DCACHE_REFERENCED` (`fs/dcache.c:864-905`).

It *is* taken by: `__d_lookup` (the ref-walk lookup — once per candidate,
`fs/dcache.c:2622`), `dentry_kill`, `d_instantiate`, `d_move`, and the shrinker
via `spin_trylock` (`fs/dcache.c:1309-1310`).

The important consequence for scaling is that ref-walk's `__d_lookup` takes a
spinlock **per hash-chain candidate**, and RCU-walk's `__d_lookup_rcu` takes
none (`fs/dcache.c:2502-2540`, seqcount only). That is the single largest
mechanical difference between the two walk modes.

### 1.3 The dcache hash buckets

`dentry_hashtable` is an array of `struct hlist_bl_head`, one pointer each
(`fs/dcache.c:115`, `include/linux/list_bl.h:34-36`). The lock is **bit 0 of
the head pointer itself** (`include/linux/list_bl.h:21-25`, `:146-156`), so the
lock and the first list element live in the same word and the same line. There
is no separate lock array to false-share with.

Size is not a constant: `alloc_large_system_hash("Dentry cache", ...,
dhash_entries, 13, ...)` at `fs/dcache.c:3456-3465` / `:3488-3497`, scale 13,
meaning roughly one bucket per 8 KB of low memory, adapted upward above 64 GB
(`mm/mm_init.c:2296-2298`, `:2337-2346`) and capped at 1/16 of memory. On the
8 GB guest that is order-2^20 buckets. Chain length is therefore not the
problem; the bucket lock is only taken by `__d_drop`/`___d_drop`
(`fs/dcache.c:565-581`) and `__d_rehash` (`fs/dcache.c:2709-2716`), i.e. by
creation, unlink, rename and eviction — never by a lookup hit.

`__d_lookup_rcu` walks the chain with `hlist_bl_for_each_entry_rcu`
(`fs/dcache.c:2502`) and takes nothing.

**Granularity: global table, per-bucket lock, and lookups do not take it.**
This is not a scaling problem for any read workload. It becomes one for U1
(create/unlink churn) and A9 (negative-dentry churn) only if many CPUs hash to
the same bucket, which with 2^20 buckets requires them to be operating on the
same *name in the same parent*.

### 1.4 `rename_lock` — global, and read on more paths than you would expect

`__cacheline_aligned_in_smp DEFINE_SEQLOCK(rename_lock)` — `fs/dcache.c:85`.
One global seqlock, on its own line.

Write sides are exactly four, all rename or splice: `d_move`
(`fs/dcache.c:3151`), `d_exchange` (`:3164`), and `d_splice_alias_ops`
(`:3256`, with three unlock points `:3258`, `:3270`, `:3284`).

Read sides are the interesting part, because a seqcount read costs a load and a
barrier, not a bounce — *unless* a writer is active, in which case every reader
retries:

- `path_init` samples it once per walk: `nd->r_seq =
  __read_seqcount_begin(&rename_lock.seqcount)` (`fs/namei.c:2697`), and it is
  re-checked **only for scoped lookups**, in `handle_dots`
  (`fs/namei.c:2258`). An ordinary walk samples it and never looks again.
- `d_lookup` wraps `__d_lookup` in a `read_seqbegin`/`read_seqretry` loop
  (`fs/dcache.c:2563-2567`) so that a false negative caused by a concurrent
  rename is retried.
- `prepend_path` (`fs/d_path.c:171`) and `__dentry_path` (`:343`) use
  `read_seqbegin_or_lock` — optimistic first, then the real spinlock.
- `d_walk` (`fs/dcache.c:1449`), `d_alloc_parallel` (`:2783`), `is_subdir`
  (`:3350`).
- `d_set_mounted` takes the **exclusive** read side, `read_seqlock_excl`
  (`fs/dcache.c:1591`) — that is a real spinlock acquisition.

`lookup_fast` deliberately does *not* take it, and says so
(`fs/namei.c:1848-1852`): a false negative from a racing rename just falls back
to the slow lookup.

**Granularity: global.** A rename storm on one filesystem makes every
`/proc/*/maps` read, every `d_path`, every `getcwd` and every scoped `openat2`
in the system retry. There is no per-object escape. In practice renames are
rare enough that this has not been a reported bottleneck, and the design is
deliberate — rule 301.

### 1.5 The in-lookup hash

`in_lookup_hashtable[1 << 10]` — **1024 buckets, global, statically allocated**
(`fs/dcache.c:123-124`). This is where a dentry lives between "I am about to
call `->lookup`" and "the filesystem answered". `d_alloc_parallel`
(`fs/dcache.c:2760-2866`) is the whole mechanism: it takes the bucket bit-lock
(`:2806`), scans for another CPU already looking up the same name in the same
parent, and if it finds one, waits on it with `d_wait_lookup`
(`fs/dcache.c:2750-2758`, a `wait_var_event_spinlock` on `d_flags`).

The hash function folds the parent pointer divided by `L1_CACHE_BYTES`
(`fs/dcache.c:126-131`).

**This only executes on a dcache miss.** On a warm workload it is never
reached. It is the reason a thundering herd of N processes all missing on the
same path issues **one** `->lookup` and not N — a genuine anti-cascade, and
the right design.

**Granularity: global table with 1024 buckets.** At high CPU counts with a cold
cache and many distinct names, bucket collisions are possible but the lock is
held only for a list scan. Workload: A11/A12 and M5 (FUSE), not C-block.

### 1.6 The dentry LRU

`sb->s_dentry_lru` is a `struct list_lru` (`super_block` offset 1112), which is
a pointer to a per-NUMA-node array (`mm/list_lru.c:678`), each node holding a
`struct list_lru_one` with **its own spinlock**
(`include/linux/list_lru.h:31-37`), and each node further split per-memcg
(`include/linux/list_lru.h:39-43`). `struct list_lru_node` is
`____cacheline_aligned_in_smp` and is exactly 64 bytes with 24 bytes of padding
— one line per (superblock, node).

There is **no `s_dentry_lru_lock` field** in this tree; the name survives only
in stale comments at `fs/dcache.c:48` and `:63`. Anyone writing a patch against
that comment is writing against a kernel that no longer exists.

Which node a dentry lands on is decided by the dentry's own memory:
`page_to_nid(virt_to_page(item))` (`mm/list_lru.c:250`), and dentries are
allocated with `kmem_cache_alloc_lru(dentry_cache, &sb->s_dentry_lru, ...)`
(`fs/dcache.c:1907-1908`) so that allocation and LRU node agree.

**When is it touched on a hot path?** `d_lru_add` is called from
`retain_dentry` (`fs/dcache.c:898`) — that is, from `dput` when the refcount
reaches zero **and** `DCACHE_LRU_LIST` is not yet set. In an open/close loop on
one file that happens once, on the first close; thereafter the flag is set and
`retain_dentry` returns true without touching the LRU. So the LRU is *not* a
per-operation cost on a steady-state workload. It is a per-operation cost on a
workload that creates and destroys dentries — U1, A9.

**Granularity: per-superblock x per-node x per-memcg.** Good. This is one of
the better-scaling structures in the VFS.

### 1.7 The dentry counters

`nr_dentry`, `nr_dentry_unused`, `nr_dentry_negative` are plain
`DEFINE_PER_CPU(long, ...)` (`fs/dcache.c:142-144`), deliberately not
`percpu_counter` (the rationale is at `fs/dcache.c:153-164`). They are summed
`for_each_possible_cpu` only when `/proc/sys/fs/dentry-state` is read
(`fs/dcache.c:165-200`). `this_cpu_inc` on a local line costs nothing shared.

Not a bottleneck, and useful: they are the state measure the workload matrix
leans on for leak detection.

### 1.8 `inode->i_count`

This tree's refcount path is **not** the historical one and a spec written from
an older kernel will be wrong about it.

- `__iget()` is a bare `atomic_inc` with `lockdep_assert_held(&inode->i_lock)`
  (`include/linux/fs.h:3032-3036`).
- `ihold()` is lockless: `atomic_inc_return` (`fs/inode.c:1578-1582`).
- `igrab_from_hash()` is fully lockless: `atomic_add_unless(&inode->i_count, 1, 0)`
  (`fs/inode.c:1642`), with the rationale at `fs/inode.c:1607-1634`.
- **`iput()` is not `atomic_dec_and_lock`.** The fast path is
  `if (atomic_add_unless(&inode->i_count, -1, 1)) return;`
  (`fs/inode.c:2043`) — one atomic, no lock, when this is not the last
  reference. Only the last reference takes `i_lock` (`fs/inode.c:2049`) and
  re-tests with `atomic_dec_and_test` (`:2055`).

`iput` is 156 instructions with `{cmpxchg: 1, decl: 1}` in the graph.

**Granularity: per-inode.** Workload C4 and C6. Note that C6 (`stat` only, no
`struct file`) still pays this: `filename_lookup` takes and drops the dentry
reference, and the dentry pins the inode, so `i_count` moves only if the dentry
itself is created or destroyed — on a warm stat of a cached path it does not
move at all. That is a real and useful distinction, and it is why C6 exists as
a separate row.

### 1.9 `inode->i_lock`

One spinlock per inode, at offset 128 — the first four bytes of inode cache
line 2. What it protects is documented at `fs/inode.c:33-57`: `i_state`,
`i_hash`, `__iget()`, `i_io_list`. Lock ordering is rule 293.

On the warm read path it is **not taken**: `iget_locked`'s hit path goes
through `find_inode_fast(sb, head, ino, false, &isnew)` with `hash_locked=false`
(`fs/inode.c:1461`), which walks the hash under RCU (`:1081`) and grabs the
reference with `igrab_from_hash`'s `atomic_add_unless` — no `inode_hash_lock`,
no `i_lock`.

It *is* taken by: the last `iput` (`fs/inode.c:2049`), hash insert/remove
(`:678`, `:694`, both nested inside `inode_hash_lock`), `d_instantiate`
(`fs/dcache.c:2177`), `dentry_unlink_inode` (`fs/dcache.c:457-473`), and
`__mark_inode_dirty` — but the last one has a **lockless early-out**:
`if ((inode_state_read_once(inode) & flags) == flags) return;`
(`fs/fs-writeback.c:2754-2755`), preceded by an `smp_mb()` at `:2752`. An inode
that is already dirty in the requested way costs a barrier and a load, not a
lock. That early-out is what keeps a write-heavy workload off `i_lock`.

### 1.10 `inode_hash_lock` — one global spinlock

`static __cacheline_aligned_in_smp DEFINE_SPINLOCK(inode_hash_lock)` —
`fs/inode.c:62`. **One lock for the entire inode hash table, no sharding.**
The table is sized with scale 14 (`fs/inode.c:2641-2650`), so it has plenty of
buckets, but they all share one lock.

Who takes it:

| function | takes it | source |
|---|---|---|
| `iget_locked` | only on the **miss** branch | `fs/inode.c:1477`, `:1486`, `:1500` |
| `iget5_locked` | **always**, even on a hit (via `ilookup5` -> `ilookup5_nowait`) | `fs/inode.c:1374-1390`, `:1674-1676` |
| `iget5_locked_rcu` | no — RCU lookup | `fs/inode.c:1414` |
| `ilookup` | no — RCU lookup | `fs/inode.c:1738` |
| `insert_inode_locked` | **always**, and with a non-RCU list walk | `fs/inode.c:1893-1924`, walk at `:1895` |
| `__insert_inode_hash` / `__remove_inode_hash` | always | `fs/inode.c:677-681`, `:693-697` |
| `find_inode_nowait` | always | `fs/inode.c:1787`, `:1799` |

The split is the whole story. Filesystems whose inode identity is the inode
number (ext4, and `iget_locked` generally) get a lock-free hit. Filesystems
using `iget5_locked` with a `->test` callback — which is the norm for network
and stacking filesystems, see `20-filesystems-and-vfs.md` — take a **global
spinlock on every inode lookup hit**. That is a genuine global ceiling and it
is filesystem-dependent.

**Granularity: global.** Workloads: A11, A12 (cold inode), M3/M4 (overlayfs),
M5 (FUSE). Not a factor for warm ext4.

### 1.11 The inode LRU and `sb->s_inode_list_lock`

`sb->s_inode_lru` is the same `list_lru` structure as the dentry LRU — per-sb,
per-node, per-memcg, one spinlock per (sb, node, memcg)
(`include/linux/fs/super_types.h:255-261`, whose own comment says the two
`list_lru`s need not be on separate cache lines because each is only a pointer
to a per-node table).

Hot-path touch: `iput_final` calls `__inode_lru_list_add(inode, true)`
(`fs/inode.c:1988`) for every last-reference drop of a clean, cacheable inode,
which takes a `list_lru_one.lock` and does `this_cpu_inc(nr_unused)`
(`fs/inode.c:564-565`). The `rotate=true` argument is what sets `I_REFERENCED`
on an inode already on the list. The removal side has a lockless early-out:
`inode_lru_list_del` tests `list_empty(&inode->i_lru)` before taking anything
(`fs/inode.c:580`).

`sb->s_inode_list_lock` is a **per-superblock** spinlock on its own cache line
(`include/linux/fs/super_types.h:272-274`, `____cacheline_aligned_in_smp`,
offset 1344). It is taken by `inode_sb_list_add` (`fs/inode.c:634-641`) from
`new_inode()` (`:1173`), `inode_insert5()` (`:1348`) and `iget_locked()`
(`:1487`) — that is, **per inode instantiation, not per open**. `list_add` puts
every new inode at the head of one list, so at instantiation rates it is a
single contended line per filesystem.

**Granularity: LRU per-sb-per-node-per-memcg (good), `s_inode_list_lock`
per-sb (not sharded).** Workload: U1 and A11 — a create-heavy or cold-walk
workload on one filesystem. A warm read workload never touches either.

### 1.12 `inode->i_rwsem`

The rwsem is 32 bytes at inode offset 152, spanning the back half of inode
cache line 2. Its `count` word is at offset 152 and is an atomic that **every**
`down_read` writes.

Where it is taken on hot paths:

| path | mode | source |
|---|---|---|
| buffered read | **not taken at all** | `mm/filemap.c:2975-3017`, no `inode_lock*` |
| buffered write | **exclusive**, for the whole write | `mm/filemap.c:4514-4518` |
| `lookup_slow` (dcache miss on a component) | shared, on the **parent** | `fs/namei.c:1935` |
| `lookup_open` without `O_CREAT` | shared, on the parent | `fs/namei.c:4460` |
| `lookup_open` with `O_CREAT` | **exclusive**, on the parent | `fs/namei.c:4458` |
| `getdents64` | shared, on the directory | `fs/readdir.c:103` |
| create / unlink / rename | exclusive, on the parent(s) | `fs/namei.c:2912`, `:3560`, `:5704`, `:6160-6166` |

Two facts fall out of this table and they are the most important scaling facts
about `i_rwsem`:

1. **Buffered read does not take it.** A thousand threads reading one file
   serialise on nothing at this level. (They serialise on `f_pos_lock` if they
   share an fd — section 3.3 — but not here.)
2. **Buffered write takes it exclusively.** `generic_file_write_iter` holds the
   inode exclusively across the entire copy. N threads writing to one file are
   fully serialised, and no layout change touches that. Rule 297 is the
   correctness statement; this is the cost statement.

The third fact is `O_CREAT`: an open that may create takes the *parent
directory's* `i_rwsem` exclusively (`fs/namei.c:4458`). N processes creating
files in one directory are serialised on one rwsem. That is workload F3 x C3
and it is the single most common real-world VFS serialisation that is not about
refcounts.

`iterate_dir` is shared, but `wrap_directory_iterator`
(`fs/readdir.c:55-69`) upgrades to exclusive for filesystems that never
converted to `->iterate_shared` — `up_read` then `down_write` then
`downgrade_write`. Which filesystems those are is `20-filesystems-and-vfs.md`'s
question.

### 1.13 `i_writecount` and `i_readcount`

Both are bare atomics with no lock at all
(`include/linux/fs.h:2833-2892`): `get_write_access` is
`atomic_inc_unless_negative`, `deny_write_access` is
`atomic_dec_unless_positive`, `i_readcount_inc` is `atomic_inc`.

`do_dentry_open` bumps exactly one of them per open
(`fs/open.c:954-960`): `i_readcount_inc(inode)` for a read-only open
(`:955`), `file_get_write_access(f)` otherwise (`:957`). `__fput` reverses it.

**This is the irreducible per-open shared write on the inode.** Every process
opening the same file for reading does a `lock incl` on `inode+340` and a
matching decrement on close. There is no fast path, no per-cpu form, and no
way to elide it while the semantics of `deny_write_access` (ETXTBSY) survive.

Note `i_readcount` only exists under `CONFIG_IMA || CONFIG_FILE_LOCKING`
(`include/linux/fs.h:843-845`); with both off, `i_readcount_inc` is a no-op
(`:2894-2901`). The baseline config has file locking on, so it is real here.

**Granularity: per-inode. Workload: C4 and C6.** This and `d_lockref` are the
two shared lines that a shared-inode open storm actually bounces.

### 1.14 `i_state` and the global wait table

`i_state` is a `struct inode_state_flags` at offset 144
(`include/linux/fs.h:814`), read and written only under `i_lock`, through
`inode_state_read()`/`_set()` accessors that assert it
(`include/linux/fs.h:883-945`).

The sleeping wait is the part with a global component.
`inode_state_wait_address(inode, bit)` is `(char *)&inode->i_state + bit`
(`include/linux/fs.h:960`), fed to `__var_waitqueue`, which is
`bit_wait_table + hash_ptr(p, WAIT_TABLE_BITS)`
(`kernel/sched/wait_bit.c:164-167`) with `WAIT_TABLE_BITS 8` — **256 waitqueue
heads shared by the entire kernel** (`kernel/sched/wait_bit.c:10-13`). Inode
`I_NEW` waiters collide with every other `wait_var_event` user in the system.

`wait_on_inode()` does not exist in this tree. The functions are
`wait_on_new_inode()` (`fs/inode.c:525-548`) and `__wait_on_freeing_inode()`
(`fs/inode.c:2592-2621`), the latter dropping `i_lock`, RCU and
`inode_hash_lock` before scheduling (`:2611-2616`).

**This only matters when two CPUs instantiate the same inode simultaneously.**
Workload A12, M5. On a warm path it is never reached.

### 1.15 `file->f_ref` — free when unshared

`file_ref_t` is a biased 64-bit counter: one reference is stored as **zero**
(`FILE_REF_ONEREF 0`, `include/linux/file_ref.h:31-36`), so the last put is the
0 -> -1 transition. `file_ref_get` is
`!atomic_long_add_negative(1, &ref->refcnt)` (`include/linux/file_ref.h:108`) —
a single `LOCK addq` plus a sign test, no cmpxchg loop. `file_ref_put` is one
`LOCK xaddq`; the *last* put costs a second atomic, a
`atomic_long_try_cmpxchg_release(..., FILE_REF_DEAD)` at `fs/file.c:81`.

`file_ref_put_close` exists to spend one atomic instead of two on the last
reference, at the cost of a pre-read — and the header says plainly that the
pre-read "decreases scalability" and that it is for `close()`
(`include/linux/file_ref.h:171-187`).

**The `struct file` slab is `SLAB_TYPESAFE_BY_RCU`**
(`fs/file_table.c:639-641`), which is why `__fget_files_rcu` must re-validate
the pointer after taking the reference (`fs/file.c:1070-1071`).

The scaling fact is section 3.3's: when the fd table is not shared, `fdget`
does not touch `f_ref` at all.

### 1.16 `files_struct->file_lock` and the fdtable

`spinlock_t file_lock ____cacheline_aligned_in_smp` — deliberately put on its
own line, away from the read-mostly `count`/`fdt`, and the header says so
(`include/linux/fdtable.h:47-52`).

- **`alloc_fd` holds it across everything**: acquired at `fs/file.c:576`,
  released at `:610`, covering the `next_fd` read (`:580-581`), the two-level
  bitmap scan `find_next_fd` (`:584`, implementation `:544-564`), any
  `expand_files`, the `next_fd` update (`:602-603`) and `__set_open_fd`
  (`:605`).
- **`fd_install` normally takes no lock at all** (`fs/file.c:679-699`): it uses
  `rcu_read_lock_sched()` and `rcu_assign_pointer(fdt->fd[fd], file)`,
  falling back to `fd_install_slowpath` (`:659-669`) only while a resize is in
  flight.
- **`put_unused_fd` takes it and rewinds `next_fd`**
  (`fs/file.c:625-639`): `if (fd < files->next_fd) files->next_fd = fd;`. Every
  close moves the allocation cursor back, so allocation always restarts low.
  That is what makes `next_fd` a hot contended word rather than a monotonic one.
- `close_fd` holds it only across `file_close_fd_locked` (`fs/file.c:738-740`);
  `filp_close` runs unlocked.

`expand_fdtable` is worth noting for a different reason: it **drops the lock to
allocate** (`fs/file.c:258-259`) and then, if the table is shared,
`synchronize_rcu()` — a full grace period, inline, at `fs/file.c:264-265`. That
is not a hot path but it is a latency cliff at the doubling boundaries, and it
only happens when `atomic_read(&files->count) > 1`.

**Granularity: per-`files_struct`, which means per-process for a normal
program and shared by all threads of a threaded one.** Workload C5, explicitly.

### 1.17 `file->f_pos_lock`

A mutex in a union with `f_pipe` (`include/linux/fs.h:1271-1276`), taken by
`fdget_pos` (`fs/file.c:1252-1262`) only when `file_needs_f_pos_lock` says so
(`fs/file.c:1227-1236`):

    if (!(file->f_mode & FMODE_ATOMIC_POS))                 return false;
    if (__file_ref_read_raw(&file->f_ref) != FILE_REF_ONEREF) return true;
    if (file->f_op->iterate_shared)                          return true;
    return false;

`FMODE_ATOMIC_POS` is set at open only for regular files and directories
(`fs/open.c:963-965`). The middle test is the single-reference fast path: with
exactly one reference, nobody else can reach this `struct file`, so the mutex
is skipped. Directories always lock, for the reason given at
`fs/file.c:1221-1225`.

**This is the mechanism that makes threads and processes behave differently on
`read()`, and it is documented in the source** (`fs/file.c:1269-1273`).

### 1.18 `nr_files`

`static struct percpu_counter nr_files __cacheline_aligned_in_smp`
(`fs/file_table.c:48`), incremented in `alloc_empty_file` (`:272`) and
decremented in `file_free` (`:98-99`). `percpu_counter_batch` is **32**
(`lib/percpu_counter.c:255`), and `percpu_counter_add_batch` escalates to
`raw_spin_lock_irqsave(&fbc->lock)` only when the local accumulation reaches the
batch (`lib/percpu_counter.c:93-113`). So roughly one open in 32 per CPU touches
a global lock.

The limit check reads the *approximate* value first and only does the exact
`percpu_counter_sum_positive` — which walks every CPU — once the approximation
already trips (`fs/file_table.c:252-260`). A system at its `max_files` limit
therefore does a full per-cpu sum on **every** open attempt. That is a cliff,
not a slope, and it is the correct design.

### 1.19 `i_flctx` and `file_lock_context`

`01-open-path.md` lists `i_flctx` as read on every open. That is too strong,
and the refinement matters for section 2.

`locks_inode_context()` is:

    if (likely(!(smp_load_acquire(&inode->i_opflags) & IOP_FLCTX)))
            return NULL;
    return READ_ONCE(inode->i_flctx);

(`include/linux/filelock.h:249-260`). `i_opflags` is at inode offset **2** —
cache line 0, already hot from `i_mode`. The context is allocated lazily on the
first flock/POSIX lock/lease (`fs/locks.c:176-216`) and published under `i_lock`
with `smp_store_release` on `i_opflags` (`:201`, `:205`).

So on a file that has never been locked, `break_lease`
(`include/linux/filelock.h:476-493`) reads `i_opflags` from line 0, returns 0,
and **never touches `i_flctx` at offset 352 at all**. When a context does
exist but holds no lease, it costs an `smp_mb()` and a `list_empty_careful()` —
still no lock. Only `__break_lease` (`fs/locks.c:1676+`, 484 instructions)
takes `percpu_down_read(&file_rwsem)` (`:1703`) and `spin_lock(&ctx->flc_lock)`
(`:1704`).

The correct statement is: **`i_flctx` is read on every open of a file that has
a lock context, and on no other open.** That weakens the `i_flctx` half of the
inode-line-5 argument and does not weaken the `i_fop` half at all — see 2.2.

### 1.20 `mount_lock` and the mount hash

`__cacheline_aligned_in_smp DEFINE_SEQLOCK(mount_lock)` — `fs/namespace.c:127`.
Global, on its own line.

The path walk reads it as a **seqcount only**. `path_init` samples
`nd->m_seq = __read_seqcount_begin(&mount_lock.seqcount)`
(`fs/namei.c:2696`), and `__follow_mount_rcu` re-checks with `read_seqretry`
(`fs/namei.c:1717`, `:1721`). Ref-walk's `lookup_mnt` does
`read_seqbegin(&mount_lock)` (`fs/namespace.c:816`). `__legitimize_mnt`
brackets its per-cpu count bump with two `read_seqretry`s
(`fs/namespace.c:744`, `:751`).

`lock_mount_hash()` is `write_seqlock(&mount_lock)` (`fs/namespace.c:188-196`)
and is a real spinlock — but it is only taken by mount, umount, and
`mntput_no_expire`'s slow path. `read_seqlock_excl(&mount_lock)` — used by
`follow_up` (`fs/namei.c:1471`) and a handful of namespace functions — also
takes the spinlock; those are not path-walk paths.

**The mount lookup structure is still a hash table**, not an rbtree:
`mount_hashtable` (`fs/namespace.c:80`), `m_hash()` folding
`mnt / L1_CACHE_BYTES + dentry / L1_CACHE_BYTES`
(`fs/namespace.c:198-204`), and `__lookup_mnt` walking it with
`hlist_for_each_entry_rcu` and no lock (`fs/namespace.c:790-799`). The
`mnt_node` rb_node in `struct mount` (`fs/mount.h:52`) is an **ID-ordered index
for `listmount()`/`statmount()`**, keyed on `mnt_id_unique`
(`fs/namespace.c:1076-1100`), and the `overmount` field (`fs/mount.h:103`) is a
mount/umount helper — grep finds **zero references to either in
`fs/namei.c`**.

And the common case does not reach any of it. `traverse_mounts` reads the
dentry's own `d_flags` and returns immediately if `DCACHE_MANAGED_DENTRY` is
clear (`fs/namei.c:1635-1647`). A path with no mount points in it never touches
the mount hash.

**Granularity: global seqlock, read-only on the walk.** A mount or umount
storm invalidates every in-flight path walk's `m_seq`; nothing else does.

### 1.21 `mnt_pcp` — the per-cpu mount counters

`struct mnt_pcp { int mnt_count; int mnt_writers; }` (`fs/mount.h:35-38`), one
per cpu per mount (`fs/namespace.c:305`). On SMP there is no non-per-cpu
variant of either counter (`fs/mount.h:56-61`).

- `mntget` is unconditionally `mnt_add_count(mnt, 1)` =
  `this_cpu_add(mnt->mnt_pcp->mnt_count, 1)`
  (`fs/namespace.c:1426-1431`, `:255-264`). **Never an atomic.** There is no
  longterm/internal distinction in the counting.
- `mntput_no_expire`'s fast path, under `rcu_read_lock()`, is
  `if (likely(READ_ONCE(mnt->mnt_ns))) { mnt_add_count(mnt, -1); return; }`
  (`fs/namespace.c:1394-1412`).
- `mnt_get_write_access` is a per-cpu increment, an `smp_mb()`, a spin on the
  `WRITE_HOLD` bit stolen from `mnt_pprev_for_sb`, and a read-only check
  (`fs/namespace.c:432-478`). The graph agrees: `mnt_want_write` is 68
  instructions with **zero** lock-prefixed instructions.
- The per-cpu counters are summed only by `mnt_get_count`
  (`fs/namespace.c:269-282`) and `mnt_get_writers` (`:384-398`), both
  `for_each_possible_cpu`, both reached only from `mntput`'s slow path and from
  `sb_prepare_remount_readonly` (`fs/namespace.c:695-723`).

**This is the best-scaling reference count in the VFS and it is the model for
what the others are not.** The cost is memory: `NR_CPUS` x 8 bytes per mount.
It is also why Guzik's v5 transferring the mount reference as well as the
dentry is a smaller win than the dentry half — `01-open-path.md` section 6 says
this and it is correct: two per-cpu RMWs on a private line, not two shared-line
RMWs.

### 1.22 `namespace_sem` and mount propagation

`static DECLARE_RWSEM(namespace_sem)` (`fs/namespace.c:83`). Global. Taken
exclusively by every mount, umount, move_mount, pivot_root and mount-attr
operation, and shared by `/proc/mounts`, `statmount` and `listmount`.
`namespace_unlock()` does `synchronize_rcu_expedited()` when there are
unmounted mounts pending (`fs/namespace.c:1715`).

**`grep namespace_sem fs/namei.c` returns nothing.** No read-only path
operation takes it. Propagation (`propagate_mnt`, `fs/pnode.c:311+`;
`propagate_umount`, `:658+`) is reached only from `attach_recursive_mnt`
(`fs/namespace.c:2603`) and `umount_tree` (`:1799`), both under
`namespace_sem` held for write.

So mount propagation is a **per-mount-operation** cost, never a per-open one.
The reachability of `propagate_umount` from `do_sys_openat2` noted in
`01-open-path.md` section 2 is a real edge — `mntput` can drop the last
reference to a lazily-unmounted tree — but it is not a cost the open path pays
in the normal case.

### 1.23 `sb->s_umount` and `s_active`

`s_umount` is an rwsem at superblock offset 128.
`grep s_umount fs/namei.c fs/open.c fs/read_write.c fs/file_table.c` returns
**nothing** — no hot path touches it. Cold users: `sync`
(`fs/sync.c:158-160`), remount (`fs/namespace.c:3407-3417`),
`deactivate_super` on the last reference (`fs/super.c:614-620`), and the
shrinker via `super_trylock_shared` (`fs/super.c:181-201`, `:672-682`) which
returns `SHRINK_STOP` rather than blocking. `super_cache_count` deliberately
does not take it, and the comment says the reason is scalability
(`fs/super.c:247-256`).

`s_active`/`s_passive` (offsets 164 and 160) are likewise absent from every hot
path; `s_active` moves once per mount (`fs/namespace.c:1157`) and once per
unmount.

### 1.24 `sb_writers` — three percpu-rwsems per superblock

`struct sb_writers` holds `percpu_rw_semaphore rw_sem[3]`, one per freeze level
(`include/linux/fs/super_types.h:54-60`), 312 bytes at superblock offset 568.
Every `write()` goes through `file_start_write` -> `sb_start_write` ->
`__sb_start_write(sb, SB_FREEZE_WRITE)` ->
`percpu_down_read_freezable(...)` (`include/linux/fs/super.h:17-20`).

The uncontended read-side cost is:

    preempt_disable();
    if (likely(rcu_sync_is_idle(&sem->rss)))
            this_cpu_inc(*sem->read_count);
    else
            __percpu_down_read(...);
    preempt_enable();

(`include/linux/percpu-rwsem.h:48-72`). `rcu_sync_is_idle` is a plain
`READ_ONCE` (`include/linux/rcu_sync.h:32-37`). **No atomic, no barrier, no
shared line** — the `smp_mb()` and the `atomic_read_acquire(&sem->block)` live
in `__percpu_down_read_trylock` (`kernel/locking/percpu-rwsem.c:66`, `:72`),
reachable only once a freezer has entered.

When a freeze *does* start, `percpu_down_write` calls `rcu_sync_enter`, which
forces a grace period and pushes every subsequent reader onto the slow path
(`kernel/locking/percpu-rwsem.c:227-260`). That is the intended cliff: cheap
until someone freezes, then expensive for everyone.

Documented lock order: `sb_start_write -> i_rwsem -> s_umount`
(`include/linux/fs/super.h:119-122`).

### 1.25 `fs_struct->seq` — shared by threads, and a spinlock in ref-walk

`struct fs_struct { int users; seqlock_t seq; int umask; int in_exec;
struct path root, pwd; }` (`include/linux/fs_struct.h:11-17`). There is no
separate `fs->lock` in this tree; the seqlock's own spinlock is it.

Every relative path walk starts here. In RCU mode it is a pure seqcount retry
loop:

    do {
            seq = read_seqbegin(&fs->seq);
            nd->path = fs->pwd;
            ...
    } while (read_seqretry(&fs->seq, seq));

(`fs/namei.c:2727-2738` for `AT_FDCWD`, `fs/namei.c:1118-1124` for
`set_root`). In ref-walk mode it is `get_fs_pwd`/`get_fs_root`, which do
`read_seqlock_excl(&fs->seq)` — **a real spinlock acquisition** — plus a
`path_get` (`include/linux/fs_struct.h:29-43`).

Threads share it: `copy_fs` under `CLONE_FS` just does `fs->users++` under the
seqlock (`kernel/fork.c:1642-1652`). So every thread of a process that falls
out of RCU-walk contends on one spinlock at the *start* of every relative path
resolution, before it has looked at a single component. That is a
threads-specific serialisation that no dcache change can touch.

### 1.26 The page cache: `i_data.i_pages`

Not usually counted as VFS shared state, but it is on the same cache line as
the inode refcounts (section 2.2) so it belongs in the inventory.

`struct address_space` is embedded in `struct inode` at offset 360, and
`i_pages` — a `struct xarray`, 16 bytes: `xa_lock`, `xa_flags`, `xa_head` — is
at `address_space+8`, i.e. **inode offset 368-383**. Every page-cache lookup
reads `xa_head`: `filemap_get_read_batch` builds an `XA_STATE` on
`&mapping->i_pages` (`mm/filemap.c:2472`) and `xas_load` reaches
`xa_head(xas->xa)` (`lib/xarray.c:191`). Every folio insertion or eviction takes `xa_lock` at
inode offset 368.

`03-vfs-structure.md` section 2 notes that `mm/filemap.o` carries 178
lock-prefixed instructions against `fs/dcache.o`'s 15, and warns against
conflating the two problems. That warning stands. The point here is narrower
and geometric: the page cache's root pointer and the inode's refcounts are on
**one 64-byte line**.

### 1.27 The SELinux AVC, noted and not pursued

`CONFIG_SECURITY_SELINUX=y` in the baseline, and `03-vfs-structure.md` section 2
establishes that `security/selinux/hooks.o` plus `security.o` is 31 175
instructions against `fs/namei.o`'s 15 204. The AVC is a global hash with
per-slot spinlocks: `struct avc_cache { struct hlist_head slots[AVC_CACHE_SLOTS];
spinlock_t slots_lock[AVC_CACHE_SLOTS]; ... }`
(`security/selinux/avc.c:72-74`), sized by
`CONFIG_SECURITY_SELINUX_AVC_HASH_BITS` (`:38`), plus two global atomics
`active_nodes` and `lru_hint` (`:106-107`).

Lookups are RCU; the spinlocks are for insertion. That makes it structurally the
same shape as the dcache hash and probably not a ceiling. **This document does
not establish that from source** — it is a whole subsystem and it is out of
scope here. It is flagged because any statement of the form "the path walk is
where the contention is" has to survive it first, and on an enforcing system it
may not.

---

## 2. Cache lines that are actually shared

All offsets from `pahole -C <struct> /usr/src/kbench/builds/baseline/vmlinux`.
`L1_CACHE_BYTES` is 64 (section 0), so line *n* is bytes `64n .. 64n+63`.
Classification is per path:

- **R** read on that path
- **W** written on that path
- blank: not touched

"open" is a warm `openat(O_RDONLY)`, "stat" a warm `statx` by path, "read" a
buffered `read()` hitting the page cache, "write" a buffered `write()`,
"readdir" a `getdents64`.

### 2.1 `struct dentry` — 192 bytes, 3 lines: confirmed, with two refinements

| line | bytes | fields | open | stat | read | write | readdir |
|---|---|---|---|---|---|---|---|
| 0 | 0-63 | `d_flags` 0, `d_seq` 4, `d_hash` 8, `d_parent` 24, `d_name` 32, `d_inode` 48, `d_shortname[0..7]` 56 | R | R | | | R |
| 1 | 64-127 | `d_shortname[8..39]` 64, `d_op` 96, `d_sb` 104, `d_time` 112, `d_fsdata` 120 | R | R | | | R |
| 2 | 128-191 | **`d_lockref` 128**, `d_lru` 136, `d_sib` 152, `d_children` 168, `d_alias`/`d_rcu` 176 | **W x4** | **W x2** | | | W |

`01-open-path.md` section 4 says dentry is already well separated and there is
no false sharing to fix. **That is confirmed.** The four atomic RMWs per
open/close land on line 2, and line 2 carries nothing the lookup reads.

Two refinements the original statement does not carry:

**Line 0 is not write-free.** Three writers touch it:
`retain_dentry` sets `DCACHE_REFERENCED` on the first `dput` that finds a
dentry on the LRU without it (`fs/dcache.c:902`); `d_set_mounted` sets
`DCACHE_MOUNTED` under `d_lock` (`fs/dcache.c:1604-1605`); and — the one that
matters — **the shrinker clears `DCACHE_REFERENCED` on every dentry it rotates**
(`fs/dcache.c:1323-1324`). So a machine under dcache pressure has a background
thread dirtying line 0 of dentries that other CPUs are looking up in RCU mode.
That is a cascade (section 5), not a steady-state cost: in an open/close loop
on a warm dentry both flags are already set and `retain_dentry` reads line 0
and returns without writing (`fs/dcache.c:864-905`).

**`d_shortname` straddles the boundary.** `DNAME_INLINE_LEN` is 40
(`include/linux/dcache.h:73`, `:82`: 5 words), so `d_shortname` occupies 56-95
— the last 8 bytes of line 0 and the first 32 of line 1. A name of 8 bytes or
fewer is compared entirely within line 0. **A name of 9 to 39 bytes pulls line
1 into the working set of every lookup**, which is why the table above marks
line 1 as R: `d_op` and `d_sb` would be read anyway, but the name comparison
is the reason the line is hot for typical filenames. That is a property of the
layout worth knowing before anyone proposes moving fields across that boundary.

`dput` therefore touches **two** dentry lines, not one: a read of line 0 in
`retain_dentry` and a write of line 2 in `lockref_put_return`.

### 2.2 `struct inode` — 560 bytes, 9 lines: line 5 is worse than reported, and line 2 is a second one

| line | bytes | fields | open | stat | read | write | readdir |
|---|---|---|---|---|---|---|---|
| 0 | 0-63 | `i_mode` 0, `i_opflags` 2, `i_flags` 4, `i_acl` 8, `i_default_acl` 16, `i_uid` 24, `i_gid` 28, `i_op` 32, `i_sb` 40, `i_mapping` 48, `i_security` 56 | R | R | R | R | R |
| 1 | 64-127 | `i_ino` 64, `i_nlink` 72, `i_rdev` 76, `i_size` 80, `i_atime_sec` 88, `i_mtime_sec` 96, `i_ctime_sec` 104, `*_nsec` 112, `i_generation` 124 | R | R | R, **W** (relatime) | **W** | **W** (atime) |
| 2 | 128-191 | `i_lock` 128, `i_bytes` 132, **`i_blkbits` 134**, `i_blocks` 136, `i_state` 144, **`i_rwsem` 152-183**, `dirtied_when` 184 | | **R** | | **W** | **W** |
| 3 | 192-255 | `dirtied_time_when` 192, `i_hash` 200, `i_io_list` 216, `i_wb` 232, `i_wb_frn_*` 240, `i_lru` 248 | | | | W | |
| 4 | 256-319 | `i_lru` 256, `i_sb_list` 264, `i_wb_list` 280, `i_dentry`/`i_rcu` 296, `i_version` 312 | | R* | | W* | |
| 5 | 320-383 | `i_sequence` 320, **`i_count` 328**, `i_dio_count` 332, **`i_writecount` 336**, **`i_readcount` 340**, **`i_fop` 344**, `i_flctx` 352, `i_data.host` 360, **`i_data.i_pages` 368** | **R+W** | | **R+W** | **R+W** | R |
| 6 | 384-447 | `i_data.invalidate_lock` 384, `gfp_mask` 416, `i_mmap_writable` 420, `i_mmap` 424, `i_data.nrpages` 440 | | | R | **W** | |
| 7 | 448-511 | `writeback_index` 448, `i_data.a_ops` 456, `i_data.flags` 464, `wb_err` 472, `i_private_lock` 476, `i_mmap_rwsem` 480 | | | R | R+W | |
| 8 | 512-559 | `i_devices` 512, `i_link`/`i_cdev`/`i_pipe` 528, `i_fsnotify_mask` 536, `i_fsnotify_marks` 544, `i_private` 552 | R | R | R | R | R |

`*` `i_version` only when `STATX_CHANGE_COOKIE` is requested and `IS_I_VERSION`
(`fs/stat.c:107-110`).

**Line 5, restated.** `01-open-path.md` section 4 identifies line 5 as mixing
`i_fop`/`i_flctx` (read) with `i_count`/`i_writecount`/`i_readcount` (write).
That is right, and it is an understatement, in two directions.

*It is worse than described* because `struct address_space i_data` starts at
inode offset 360, which puts `i_data.i_pages` — the page cache's `xarray`, that
is `xa_lock` at 368, `xa_flags` at 372, `xa_head` at 376 — **on line 5**. Every
page-cache lookup reads `xa_head` (`mm/filemap.c:2472` -> `lib/xarray.c:191`);
every folio insertion or eviction takes `xa_lock` at inode+368. So line 5 is
simultaneously:

    the inode reference count          written by every iget/iput
    the open-mode counters             written by every open and every close
    the file_operations pointer        read by every open
    the page cache root pointer        read by every page-cache lookup
    the page cache lock                written by every folio add/evict

Five distinct subsystems, one 64-byte line. A workload of N readers on a hot
shared file plus M openers of the same file bounces that line for reasons that
have nothing to do with each other.

*It is milder than described in one respect*: `i_flctx` at 352 is **not** read
on every open. `break_lease` first tests `inode->i_opflags & IOP_FLCTX`
(`include/linux/filelock.h:249-260`), and `i_opflags` is at offset 2 — line 0,
already hot. On a file that has never been locked, offset 352 is never
dereferenced. So the "read-hot field on line 5" that matters is `i_fop` at 344,
read by `do_dentry_open` at `fs/open.c:967` — twelve bytes after the
`i_readcount_inc` it did at `fs/open.c:955`, in the same function.

**Line 2 is a second mixed line and nobody has flagged it.** `i_blkbits` at 134
and `i_blocks` at 136 are read by `generic_fillattr` on every `stat`
(`fs/stat.c:105-106`, via `i_blocksize`). `i_rwsem`'s count word is at 152 and
is atomically modified by **every** `down_read` — which means every
`getdents64` (`fs/readdir.c:103`) and every `lookup_slow`
(`fs/namei.c:1935`) — and exclusively by every buffered write
(`mm/filemap.c:4514`). `i_state` at 144 is written by every dirty transition
and `i_lock` at 128 by the last `iput`.

So: **N processes calling `stat` on a file that one process is writing bounce
inode line 2**, because the stat reads `i_blkbits` and the write holds
`i_rwsem` and dirties `i_state`. That is workload C6 crossed with a writer,
and it is not addressed by any patch in this project.

**Line 0 is clean and should stay that way.** Every permission check, every LSM
hook and every `i_op` dispatch reads from it, and nothing on any of the five
paths writes it. The only writers are `chmod`/`setattr` (`i_mode`) and ACL
cache invalidation (`i_acl`). This is the best line in the structure and the
most valuable thing to preserve in any relayout.

**Line 1 is the atime line**, as `02-stat-path.md` section 5 says: read
entirely by `generic_fillattr`, written by `touch_atime` under `relatime` and
by `file_update_time` on every write. That document's point stands unchanged —
the rig is mounted `noatime` (`scripts/mkrootfs.sh:48`), so nothing measured
here has ever exercised the write side.

### 2.3 `struct file` — 176 bytes, 3 lines

| line | bytes | fields | open | stat(fd) | read | write |
|---|---|---|---|---|---|---|
| 0 | 0-63 | `f_lock` 0, `f_mode` 4, `f_op` 8, `f_mapping` 16, `private_data` 24, `f_inode` 32, `f_flags` 40, `f_iocb_flags` 44, `f_cred` 48, `f_owner` 56 | W (init) | R | R | R |
| 1 | 64-127 | **`f_path` 64**, `f_pos_lock` 80, **`f_pos` 104**, `f_security` 112, `f_wb_err` 120, `f_sb_err` 124 | W (init) | R | R + **W** | R + **W** |
| 2 | 128-191 | `f_ep` 128, **`f_ra` 136-167**, **`f_ref` 168** | W (init) | | **W** | W |

Line 0 is read-only after `init_file` and holds everything the syscall
dispatch needs. Good.

**Line 1 mixes `f_path` (read) with `f_pos` (written on every read and write).**
`f_path` is read by `fstat` (`fs/stat.c:323`), by `fsnotify_file`
(`include/linux/fsnotify.h:116-129`), and by `__fput` to do the `dput` and
`mntput`. `f_pos` is written by every positional `read`/`write`.
`f_security` at 112 is read by `security_file_permission` on every one of them.

**Line 2 carries two independent write-hot fields**: `f_ra`, the readahead
state, written by `filemap_read` on every buffered read
(`mm/filemap.c:2791`, `:2897`), and `f_ref`, written by every
`fget`/`fput` when the file is shared. They are both writes, so this is not
read/write false sharing — but it does mean that two threads reading through
one shared fd bounce one line for two unrelated reasons, on top of serialising
on `f_pos_lock`.

None of this matters for an unshared `struct file`: the whole structure is
private to one CPU's cache, and `fdget` does not even touch `f_ref`
(section 3.3). **`struct file` layout is only a scaling question for shared
descriptors.**

### 2.4 `struct files_struct` — 704 bytes: the deliberate separation is one field short

`include/linux/fdtable.h:38-57` splits the structure by hand, with comments:
"read mostly part" (`count`, `resize_in_progress`, `resize_wait`, `fdt`,
`fdtab`) and "written part on a separate cache line in SMP"
(`file_lock ____cacheline_aligned_in_smp`, `next_fd`, the three embedded
bitmaps, `fd_array[64]`).

`pahole` shows what that produces:

| line | bytes | fields | who touches it |
|---|---|---|---|
| 0 | 0-63 | `count` 0, `resize_in_progress` 4, `resize_wait` 8, `fdt` 32, `fdtab` 40-63 | **R** by every `fdget` (`count` at `fs/file.c:1194`, `fdt` via `files_fdtable`) and every `fd_install` (`resize_in_progress` at `fs/file.c:688`) |
| 1 | 64-127 | `fdtab` tail (`rcu`), 32 bytes of padding | |
| 2 | 128-191 | **`file_lock` 128**, **`next_fd` 132**, `close_on_exec_init` 136, `open_fds_init` 144, `full_fds_bits_init` 152, **`fd_array[0..3]` 160-191** | `file_lock`/`next_fd`/bitmaps **W** by every `alloc_fd` and every `put_unused_fd`; `fd_array[0..3]` **R** by every `fdget` of fd 0-3 and **W** by `fd_install` |
| 3-10 | 192-671 | `fd_array[4..63]` | R by `fdget`, W by `fd_install` |

The separation achieved what it says: `count` and `fdt`, the two words every
`fdget` reads, are on line 0 and no open or close writes them.

But **`fd_array[0..3]` shares line 2 with `file_lock` and `next_fd`**. Those
four descriptors are, on essentially every process, stdin/stdout/stderr and the
first file the program opened. In a multi-threaded process, one thread doing
`read(1, ...)` or `write(2, ...)` in a loop is reading line 2 while any other
thread's `open` or `close` is writing `file_lock`, `next_fd` and the `open_fds`
bitmap on the same line.

This is a genuine read-hot/write-hot mix and it is the only one in this
document that looks fixable by pure padding: 32 bytes of padding between
`full_fds_bits_init` and `fd_array` would put the array on its own line at the
cost of growing a 704-byte structure to 736. Whether it is worth doing is
section 6's question. Note that `fd_install` writes `fdt->fd[fd]` — which *is*
`fd_array[fd]` for a small table — so for fds 0-3 the write and the lock are on
the same line regardless; the padding would help the reader, not the installer.

### 2.5 `struct super_block` — 1408 bytes, 22 lines, `__aligned__(64)`

The hot half is small and clean:

| line | bytes | fields | hot-path use |
|---|---|---|---|
| 0 | 0-63 | `s_list` 0, `s_dev` 16, `s_super_dev` 24, `s_blocksize_bits` 32, `s_blocksize` 40, `s_maxbytes` 48, `s_type` 56 | R: `s_dev` on stat, `s_maxbytes` on read/write bounds |
| 1 | 64-127 | `s_op` 64, `dq_op` 72, `s_qcop` 80, `s_export_op` 88, `s_flags` 96, `s_iflags` 104, `s_magic` 112, `s_root` 120 | **R only.** `s_flags` (`SB_RDONLY`, `SB_NOATIME`) on every open and every atime decision; `s_op` on every inode operation |
| 2 | 128-191 | `s_umount` 128-159, `s_passive` 160, `s_active` 164, `s_security` 168, `s_xattr` 176, `s_roots` 184 | none on a hot path; `s_security` R by LSM |
| 8-13 | 568-879 | `s_writers` — three `percpu_rw_semaphore` | R: `rss.gp_state` and `read_count` on every `write()`; the counter itself is per-cpu memory elsewhere |
| 21 | 1344-1407 | **`s_inode_list_lock` 1344**, `s_inodes` 1352, `s_inode_wblist_lock` 1368, `s_inodes_wb` 1376, `s_min_writeback_pages` 1392 | all-write, on its own line by `____cacheline_aligned_in_smp` |

Line 1 is the one the hot paths read and it is read-only. That is correct and
deliberate. Line 21 costs 60 bytes of padding (`pahole` shows the hole at
1284-1343) to keep `s_inode_list_lock` off line 20, which is the right trade.

**There is no hot read-hot/write-hot mix in `super_block`.** The structure is
big and full of holes — 97 bytes across 10 holes — but none of that is a
concurrency problem. It is a memory-footprint question and belongs in a
different document.

### 2.6 `struct mount` — 368 bytes, 6 lines

| line | bytes | fields | path walk |
|---|---|---|---|
| 0 | 0-63 | `mnt_hash` 0, `mnt_parent` 16, `mnt_mountpoint` 24, `mnt` 32 (= `mnt_root` 32, `mnt_sb` 40, `mnt_flags` 48, `mnt_idmap` 56) | **R only** — and this is exactly the walk's working set |
| 1 | 64-127 | `mnt_node`/`mnt_rcu`/`mnt_llist` 64, `mnt_pcp` 88, `mnt_mounts` 96, `mnt_child` 112 | R: `mnt_pcp` (the per-cpu base) on every `mntget`/`mntput` |
| 2 | 128-191 | `mnt_next_for_sb` 128, `mnt_pprev_for_sb` 136, `mnt_devname` 144, `mnt_list` 152, `mnt_expire` 168, `mnt_share` 184 | R: `mnt_pprev_for_sb` on every `mnt_get_write_access` (the `WRITE_HOLD` bit) |
| 4 | 256-319 | `mnt_fsnotify_marks` 264, `mnt_fsnotify_mask` 272, ... | R on every `fsnotify_file` |

**`struct mount` is the best-laid-out structure in this set.** Line 0 holds
`mnt_root`, `mnt_sb`, `mnt_flags` and `mnt_idmap` — every field the path walk
reads per component — plus the hash link and the parent pointer, and nothing on
it is written on any hot path, because the reference count is per-cpu and lives
somewhere else entirely (`mnt_pcp`, section 1.21).

That is the existence proof for the rest of this document: a per-object
reference count *can* be taken off the object's hot line, and the VFS already
did it once.

### 2.7 Summary: the lines that carry both a read-hot and a write-hot field

| struct | line | read-hot field | write-hot field | who collides |
|---|---|---|---|---|
| `inode` | 5 | `i_fop` 344, `i_data.i_pages.xa_head` 376 | `i_count` 328, `i_writecount` 336, `i_readcount` 340, `xa_lock` 368 | openers vs readers vs page-cache churn on one file |
| `inode` | 2 | `i_blkbits` 134, `i_blocks` 136 | `i_lock` 128, `i_state` 144, `i_rwsem` 152 | `stat` vs writer, `stat` vs `getdents64` |
| `inode` | 1 | all of it, on `stat` | `i_atime` 88, `i_mtime` 96, `i_ctime` 104 | `stat` vs writer; `stat` vs `stat` under `relatime` |
| `file` | 1 | `f_path` 64, `f_security` 112 | `f_pos` 104, `f_pos_lock` 80 | two threads on one shared fd |
| `files_struct` | 2 | `fd_array[0..3]` 160 | `file_lock` 128, `next_fd` 132, `open_fds_init` 144 | one thread reading fd 0-3 vs another thread opening |
| `dentry` | 0 | everything the RCU walk reads | `d_flags` 0, by the **shrinker** only | background reclaim vs lookups |

And the lines that are clean and should be defended:

| struct | line | what it is |
|---|---|---|
| `inode` | 0 | permission, LSM, `i_op`, `i_sb`, `i_mapping` — read-only on all five paths |
| `dentry` | 0-1 | the whole RCU lookup working set; written only on identity change |
| `mount` | 0 | the whole per-component mount working set; read-only |
| `super_block` | 1 | `s_op`, `s_flags`, `s_root` — read-only |
| `file` | 0 | `f_mode`, `f_op`, `f_inode`, `f_cred` — read-only after init |

---

## 3. Single-thread versus multi-thread

### 3.1 What one thread already pays

These costs are present at N=1, on an otherwise idle machine, and no amount of
cache-line work removes them. They are the subject of `01-open-path.md`,
`02-stat-path.md` and `03-vfs-structure.md`; they are listed here because the
distinction from section 3.2 is the whole point of this document.

**Instructions.** `path_openat` is 592 instructions in one 96-byte frame;
`link_path_walk` is 401; `do_dentry_open` is 304; the whole reachable set under
`do_sys_openat2` is 25 177 instructions (`03-vfs-structure.md` section 4).
kbench's measured warm baseline is about 6100 retired kernel instructions per
open. That number does not change with thread count.

**Atomic RMWs.** The four `d_lockref` operations and the `i_readcount` pair per
open/close cycle (`01-open-path.md` section 3) execute at N=1 too. On one CPU
with the line in M state, a `lock cmpxchg` is roughly the cost of the
instruction plus a store-buffer drain — tens of cycles, not hundreds. **At N=1
an atomic is an instruction-count problem. At N>1 on a shared object it is a
coherence problem.** Those are different orders of magnitude and conflating
them has already cost this project one wrong conclusion (kbench README, "Things
that looked like optimisations and were not").

**Cache misses.** A cold dentry or inode is a miss whether or not anyone else is
running. `struct inode` is 560 bytes over 9 lines and a warm `stat` touches
lines 0, 1, 2 and 8 of it — four lines, plus the dentry's 0 and 1, plus the
mount's 0. That is the single-thread memory footprint of a path component and
it is why the layout work matters even without contention.

**Indirect dispatch.** 40 retpoline thunk calls are reachable under
`do_sys_openat2` (`01-open-path.md` section 5), 433 in the whole layer
(`03-vfs-structure.md` section 6). Every one is a `call
__x86_indirect_thunk_<reg>` under `MITIGATION_RETPOLINE=y`. This is
thread-count-independent and is the price of the abstraction.

### 3.2 What only appears under sharing

**Atomic RMW contention.** The same `lock cmpxchg` that cost tens of cycles
uncontended costs a cache-line transfer when another CPU holds the line
modified. On the same socket that is an L3 round trip; across sockets it is an
interconnect transaction. The *instruction count does not change* — which is
precisely why `insn:k`, the rig's most reliable counter, is blind to it.

**`lockref` retry loops.** `CMPXCHG_LOOP` retries up to 100 times
(`lib/lockref.c:12`) and each failed iteration is a `pause`
(`graphs/vfs-full.json` records `pause` counts per function for this reason).
Under contention the retry count rises and the loop can exhaust and fall back
to the real spinlock (`lib/lockref.c:24-25`). That transition — from lockless
to spinlock — is a step function, not a slope, and it is the shape a lockref
bottleneck actually has.

**Lock hold time.** `alloc_fd` holds `files->file_lock` across a two-level
bitmap scan and possibly an `expand_files` (`fs/file.c:576-610`). At N=1 the
hold time is irrelevant. At N threads it is the serial fraction.

**Cache-line ping-pong without any lock.** Two CPUs reading `i_fop` at inode+344
while a third writes `i_readcount` at inode+340 transfer line 5 on every
alternation, and no lock is involved anywhere. This is the class of problem that
`perf c2c` exists to find and that this rig cannot see at all (section 7).

**Waiting.** `f_pos_lock` is a mutex: contention means sleeping, a context
switch, and a wakeup. `i_rwsem` exclusive on a buffered write is the same. These
show up as scheduling events, not as instructions, and they are the one class of
contention the guest can observe honestly (`kbench-profile sched`).

### 3.3 Threads versus processes

This is the axis the rig's own harness is built around, and the source says why.
`sweep-bench.sh:8-9`:

    Separate processes, not threads: threads share an fd table and the
    contention lands on files->file_lock in alloc_fd() instead of on the dentry.

That is correct, and it is only half the picture. The full picture is four
distinct sharing relationships, each established from a different place in the
source.

**(a) Threads share `files_struct`; processes do not.**
`copy_files` under `CLONE_FILES` is `atomic_inc(&oldf->count); return 0;`
(`kernel/fork.c:1677-1680`), leaving `tsk->files` pointing at the caller's
structure. Without `CLONE_FILES` it is `dup_fd(oldf, NULL)`
(`kernel/fork.c:1682-1686`), which allocates a fresh `files_struct` with
`atomic_set(&newf->count, 1)` (`fs/file.c:394`) and its own `file_lock`
(`:396`). `pthread_create` uses `CLONE_FILES` (`kernel/fork.c:2696`).

Consequence: **every `open` and every `close` in a threaded process takes one
process-wide spinlock** (`fs/file.c:576`, `:738`) and thrashes one `next_fd`
word (written up at `:602-603`, rewound down at `:629-630`). N processes each
take their own private, uncontended lock. `fd_install` is the exception and
stays lock-free either way (`fs/file.c:687-698`).

**(b) The `files->count == 1` fast path removes the `f_ref` atomic entirely —
for processes only.**
`__fget_light` is:

    if (likely(atomic_read_acquire(&files->count) == 1)) {
            file = files_lookup_fd_raw(files, fd);
            ...
            return BORROWED_FD(file);
    } else {
            file = __fget_files(files, fd, mask);
            ...
            return CLONED_FD(file);
    }

(`fs/file.c:1194-1204`). The borrowed path takes **no reference at all**, and
`fdput` skips `fput` for it because the `FDPUT_FPUT` tag bit is clear
(`include/linux/file.h:60-64`). The cloned path does `file_ref_get`
(`fs/file.c:1053`) plus a re-validation (`:1070-1071`) and pays a matching
`fput`.

So in a single-threaded process, `read(fd)` costs **zero** atomic RMWs on
`f_ref`. The instant a second thread exists, every `read`, `write`, `lseek`,
`ioctl` and `fstat` on any fd costs a `LOCK addq` on `file->f_ref` (line 2 of
`struct file`) and a `LOCK xaddq` on the way out. That is a step change caused
by `pthread_create`, not by any access pattern.

**(c) Threads serialise on `f_pos_lock`; processes do not.**
`file_needs_f_pos_lock` returns true when
`__file_ref_read_raw(&file->f_ref) != FILE_REF_ONEREF`, i.e. when more than one
reference exists (`fs/file.c:1231-1232`). In a threaded process, `__fget_light`
took the `CLONED_FD` branch and *raised the count before `fdget_pos` looks at
it* — so two threads reading one fd both take `mutex_lock(&file->f_pos_lock)`
(`fs/file.c:1259`) and are fully serialised for the duration of the read. The
source says so at `fs/file.c:1269-1273`.

Note what this means for `fork()`: `dup_fd` does `get_file(f)` per descriptor
(`fs/file.c:458`), so a file inherited across `fork` has `f_count >= 2`
**permanently**, and both the parent and the child take `f_pos_lock` on every
read of it forever after. Two independent `open()`s of the same path produce two
`struct file`s and share nothing here.

**(d) Threads share `fs_struct`; processes do not.**
`copy_fs` under `CLONE_FS` does `fs->users++` under the seqlock
(`kernel/fork.c:1642-1652`). In RCU-walk that costs a seqcount read
(`fs/namei.c:2727-2738`) — shared line, read-only, no bouncing. **In ref-walk
it costs `read_seqlock_excl(&fs->seq)`, a real spinlock**
(`include/linux/fs_struct.h:29-43`), taken by every thread at the *start* of
every relative path resolution. A threaded process whose walks fall out of RCU
mode serialises before it has looked at a single path component.

**What processes contend on instead.** They do not escape sharing; they move it:

| | threads | processes |
|---|---|---|
| fd allocation | `files->file_lock`, `next_fd` | private |
| `f_ref` on `fdget` | one atomic each way | none (borrowed fd) |
| `f_pos` | `f_pos_lock` mutex, serialised | private |
| walk start | `fs->seq` spinlock in ref-walk | private |
| same file's dentry | `d_lockref`, 4 RMWs/open | `d_lockref`, 4 RMWs/open |
| same file's inode | `i_readcount`, `i_count` | `i_readcount`, `i_count` |
| same parent directory | parent `d_lockref` in ref-walk | same |
| `O_CREAT` in one dir | parent `i_rwsem` exclusive | same |

**The bottom two thirds of that table are identical.** Processes sharing an
inode contend on exactly the same dentry and inode state as threads do. What
they avoid is the fd-table layer. That is why C4 (processes, shared inode) and
C5 (threads, shared inode) are separate rows in the matrix and why C5's stated
invariant is that *the dentry-side counters must match C4 at the same N* — if
they do not, the fd-table contention is masking the dentry contention and C4's
numbers are optimistic (`30-workload-matrix.md` section 2.4).

### 3.4 What RCU-walk buys, and every place it is lost

RCU-walk (`LOOKUP_RCU`) is the reason a warm path resolution takes almost no
atomics. In RCU mode the walk:

- takes **no** dentry reference — `__d_lookup_rcu` validates with
  `raw_seqcount_begin`/`read_seqcount_retry` on `d_seq`
  (`fs/dcache.c:2522`, `fs/namei.c:1866`) and never touches `d_lockref`;
- takes **no** `d_lock` — unlike `__d_lookup`, which takes one per hash-chain
  candidate (`fs/dcache.c:2622`);
- takes **no** mount reference — `mount_lock` is read as a seqcount
  (`fs/namei.c:2696`, `:1717`);
- reads `fs->pwd` / `fs->root` without the `fs->seq` spinlock
  (`fs/namei.c:2727-2738`, `:1118-1124`);
- skips the mount hash entirely when `DCACHE_MANAGED_DENTRY` is clear
  (`fs/namei.c:1635-1647`).

So a fully-RCU walk of a depth-8 path writes **nothing shared at all**. Every
atomic in `01-open-path.md`'s open/close accounting is paid at the *transition*
out of RCU mode or at the end of the walk, not per component. That is the single
most important scaling property the VFS has, and it is why R1-R4 is a block in
the workload matrix.

**Where it is lost.** There are exactly ten call sites in `fs/namei.c`:

| site | function | what forces it |
|---|---|---|
| `:1064` | `complete_walk` | **the normal end of every walk that needs a real reference.** Not a failure — this is where the walk cashes in |
| `:1746` | `handle_mounts` | `__follow_mount_rcu` could not cross the mount point |
| `:1856` | `lookup_fast` | `__d_lookup_rcu` returned NULL — the dentry is not cached |
| `:1871` | `lookup_fast` | `d_revalidate` returned <= 0 or `-ECHILD` |
| `:1970` | `may_lookup` | the permission check failed or returned `-ECHILD` under `MAY_NOT_BLOCK` |
| `:1996` | `reserve_stack` | more than `EMBEDDED_LEVELS` (2) nested symlinks — the stack must be allocated |
| `:2046` | `pick_link` | **`atime_needs_update` on a symlink** — i.e. `relatime` |
| `:2065` | `pick_link` | `->get_link` returned `-ECHILD` (the symlink target is not a plain `i_link`) |
| `:2668` | `link_path_walk` | a non-directory component mid-path (`-ENOTDIR`) |
| `:4762` | `open_last_lookups` | **`O_CREAT`** |

Eight are `try_to_unlazy` and two (`:1746`, `:1871`) are `try_to_unlazy_next`,
which additionally legitimises the child dentry
(`fs/namei.c:976-1010`) — two `lockref_get_not_dead` calls instead of one.

Five of those ten are ordinary, common events rather than errors:

1. **`complete_walk` at `:1064`** happens on every successful walk. RCU-walk
   does not avoid the reference; it defers it to the end and takes it once
   instead of per component. That is the actual win, and it is an O(depth)
   saving, not an O(1) one.
2. **`O_CREAT` at `:4762`** drops out unconditionally. Every `open(..., O_CREAT)`
   — including `O_CREAT` on a file that already exists, workload F2 — walks the
   last component in ref-walk and takes the parent's `i_rwsem` exclusively
   (`fs/namei.c:4458`).
3. **A dcache miss at `:1856`** — workload A11, A12.
4. **`d_revalidate` at `:1871`** — this is the whole of FUSE with
   `entry_timeout=0`, NFS, CIFS and overlayfs's upper/lower logic. Workloads
   R2, R3, M3-M5. On those filesystems RCU-walk is effectively off, and every
   component costs a `lockref_get_not_dead` plus a `lockref_put` — **the walk
   becomes O(depth) in shared-line atomics.**
5. **`relatime` on a symlink at `:2046`.** The kbench guest is `noatime`
   (`scripts/mkrootfs.sh:48`), so no measurement this project has made has ever
   taken this exit. Real systems default to `relatime`. This is the same
   measurement gap `02-stat-path.md` section 5 identifies, seen from the
   concurrency side: under `relatime`, a symlinked path resolution not only
   *writes* inode line 1, it also **leaves RCU-walk to do it**, which converts
   the remainder of the walk to ref-walk atomics.

Two further ways to lose it that are not `try_to_unlazy` calls:

- **`LOOKUP_CACHED` never unlazies.** Both `try_to_unlazy` and
  `try_to_unlazy_next` check `nd->flags & LOOKUP_CACHED` first and go straight
  to the failure path (`fs/namei.c:941-945`, `:982-986`). That is the
  `RESOLVE_CACHED` contract — return `-EAGAIN` rather than block — and it is
  workload R4. `path_init` enforces the other half: `LOOKUP_CACHED` without
  `LOOKUP_RCU` returns `-EAGAIN` immediately (`fs/namei.c:2682-2684`).
- **An empty path string starts out of RCU mode**: `if (unlikely(!*s)) flags
  &= ~LOOKUP_RCU;` (`fs/namei.c:2686-2687`) — the `AT_EMPTY_PATH` forms,
  workload F5 and the `statx`-by-fd path of `02-stat-path.md` section 3.

**The scaling statement.** On ext4 with a warm cache and no `O_CREAT`, the walk
is RCU and takes one dentry reference at the end. On a revalidating filesystem,
or with `O_CREAT`, or on a cache miss, the walk takes a reference per component
and the contention on a shared parent directory goes from zero to one contended
cache line per component per operation. That is the difference between C3
scaling and C3 not scaling, and it is decided by the filesystem and the flags,
not by the dcache.

---

## 4. Scalability ceilings

For each shared item from section 1: what shape does the cost take as threads
are added, can the workload escape it by spreading, and which row of
`30-workload-matrix.md` hits it.

Three ceiling shapes recur and it is worth naming them:

- **Slope.** Cost per operation grows roughly linearly with the number of CPUs
  touching the object, because each operation's cache-line transfer gets more
  expensive as more CPUs hold a copy. Throughput flattens; it does not fall.
- **Collapse.** Throughput *decreases* past some point. Produced by spinning
  (a `lockref` retry loop that exhausts, `mnt_get_write_access` spinning on
  `WRITE_HOLD`) or by convoying (a mutex or rwsem with a sleep/wake cycle per
  handoff).
- **Serial fraction.** A section that is simply not concurrent. Throughput is
  capped at `1/T_serial` regardless of CPU count. Exclusive `i_rwsem` on a
  buffered write is the clearest example.

### Per-object: escapable by spreading the workload

| state | shape | why | workload |
|---|---|---|---|
| `dentry->d_lockref` | **slope, then collapse** | uncontended it is one `cmpxchg`; contended the `CMPXCHG_LOOP` retries (up to 100, `lib/lockref.c:12`) and on exhaustion falls to the spinlock (`:24-25`). That fallback is a step, and past it the cost is a spinlock convoy | **C4** directly; **C3** once the walk leaves RCU |
| `inode->i_readcount` / `i_writecount` | **slope** | bare `atomic_inc`/`atomic_inc_unless_negative`, no retry loop, so it degrades smoothly to one line transfer per operation | **C4**, **C6** |
| `inode->i_count` | **slope** | `atomic_add_unless` on the non-final put (`fs/inode.c:2043`); the final put's `i_lock` is not reached on a warm path | **C4** |
| `inode->i_rwsem` shared | **slope** | every `down_read` is an atomic on the same word at inode+152 | **D2-D4** (`getdents64`), **C3** once out of RCU |
| `inode->i_rwsem` exclusive | **serial fraction** | `generic_file_write_iter` holds it across the whole copy (`mm/filemap.c:4514-4518`); `lookup_open` holds it across `->lookup`/`->atomic_open` for `O_CREAT` (`fs/namei.c:4458-4578`) | **Z2-Z6** writes, **F3 x C3** (N creators, one directory) |
| `file->f_ref` | **slope**, and only when shared | one `LOCK addq` each way, and zero when the fd table is not shared (`fs/file.c:1194`) | **C5** only |
| `file->f_pos_lock` | **collapse** | a mutex with one holder; N threads on one fd is a sleep/wake convoy | **C5** |
| `files_struct->file_lock` | **collapse** | one spinlock held across a bitmap scan, per open and per close, for all threads of a process (`fs/file.c:576-610`) | **C5** |
| `fs_struct->seq` in ref-walk | **collapse** | `read_seqlock_excl` is a spinlock, taken once per walk by every thread (`include/linux/fs_struct.h:29-43`) | **C5** crossed with **R2/R3** |
| `inode->i_data.i_pages` `xa_lock` | **slope, then collapse** | only taken on folio insert/evict, but held over a tree modification | **Z5-Z6** (streaming reads faulting pages in), **A11** |
| `sb->s_dentry_lru` / `s_inode_lru` | **slope, bounded** | per (sb, node, memcg) spinlock; the divisor is the node count, not the CPU count, so within a NUMA node it is a single lock | **U1**, memory pressure |
| dcache hash bucket | **effectively flat** | ~2^20 buckets on the 8 GB guest, and lookups do not take the lock at all | **U1** only if the same name in the same parent |

### Per-superblock: escapable only by using more filesystems

| state | shape | why | workload |
|---|---|---|---|
| `sb->s_inode_list_lock` | **collapse** | one spinlock, `list_add` to one head, per inode instantiation (`fs/inode.c:634-641`) | **A11** (cold walk creating inodes), **U1** |
| `sb->s_writers.rw_sem[0]` | **flat until frozen, then collapse** | read side is `this_cpu_inc` with no atomic (`include/linux/percpu-rwsem.h:48-72`); a freeze calls `rcu_sync_enter` and pushes every reader onto the slow path | freeze/thaw only |
| `sb->s_umount` | **not on a hot path** | absent from `fs/namei.c`, `fs/open.c`, `fs/read_write.c`, `fs/file_table.c` | `sync`, remount, shrink |
| `sb->s_active` | **not on a hot path** | moves once per mount | none |

### Global: no escape

| state | shape | why | workload |
|---|---|---|---|
| **`inode_hash_lock`** | **collapse**, for filesystems using `iget5_locked` | one global spinlock (`fs/inode.c:62`) taken on **every inode lookup hit** by `iget5_locked` (`fs/inode.c:1374-1390` -> `:1674-1676`) and by `insert_inode_locked` (`:1893-1924`). `iget_locked` and `iget5_locked_rcu` avoid it on the hit path | **M3/M4** (overlayfs), **M5** (FUSE), **A11/A12** on any filesystem |
| **`rename_lock`** | **collapse under a rename storm** | global seqlock (`fs/dcache.c:85`); four writers (`:3151`, `:3164`, `:3256`) make every `d_lookup`, `d_path`, `getcwd`, `d_walk` and scoped `openat2` in the system retry | **U3**, **U4** |
| **`mount_lock`** | **collapse under a mount storm** | global seqlock (`fs/namespace.c:127`); a write invalidates every in-flight walk's `m_seq` | container churn; no matrix row covers it |
| **`namespace_sem`** | **serial fraction** for mount operations | one global rwsem, exclusive for every mount/umount, and `namespace_unlock` can `synchronize_rcu_expedited` (`fs/namespace.c:1715`) | container churn; no matrix row |
| `in_lookup_hashtable` | **flat** | 1024 global buckets (`fs/dcache.c:123-124`), reached only on a dcache miss, and its *purpose* is to collapse N concurrent misses into one `->lookup` | **A11**, **M5** |
| `bit_wait_table` | **flat** | 256 global waitqueue heads (`kernel/sched/wait_bit.c:10-13`); only reached when `I_NEW` is actually contended | **A12** |
| `nr_files` | **flat, with a cliff** | per-cpu, batch 32 (`lib/percpu_counter.c:255`); but at `max_files` every open does a full per-cpu sum (`fs/file_table.c:252-260`) | no matrix row; it is a capacity limit, not a scaling one |

### The four that decide real workloads

Ranked by how many real workloads in `30-workload-matrix.md` Part 1 hit them:

1. **`files_struct->file_lock`** (C5). Every threaded server — ripgrep, the
   Kafka broker, MinIO's goroutines on OS threads, any JVM — takes one
   process-wide spinlock per `open` and per `close`. This is the ceiling most
   real software actually hits, and it is the one kbench's own harness
   deliberately avoids measuring.
2. **`i_rwsem` exclusive on the `O_CREAT` parent** (F3 x C3). N workers creating
   files in one directory is PostgreSQL's temp-file path, the browser cache
   pattern, Kafka segment creation, and MinIO's write path. One rwsem, held
   across `->lookup` or `->atomic_open`.
3. **`d_lockref` + `i_readcount` on a shared inode** (C4). N processes opening
   one hot file. This is nginx workers on one static file, and it is the one
   place where a kbench headline maps 1:1 onto a real deployment
   (`30-workload-matrix.md` section 2.4).
4. **`inode_hash_lock` on a revalidating filesystem** (M3-M5). Every
   containerised workload runs on overlayfs. If the underlying `->lookup` path
   goes through `iget5_locked`, every inode lookup hit takes a global spinlock.
   Whether it does is a per-filesystem question and belongs in
   `20-filesystems-and-vfs.md`.

**None of these four is the thing this project has been working on.** The
reference-transfer patch addresses half of item 3. That is worth stating
plainly.

---

## 5. Cascades and N+1 — the concurrency half

`03-vfs-structure.md` section 7 covers the four cascade patterns structurally.
This section asks a narrower question: **where does one CPU's operation force
work onto another CPU**, and is that per-operation or amortised.

### 5.1 Per-operation, on the same CPU, deferred in time

**`fput` -> task work.** `__fput_deferred`'s first branch is
`if (likely(!in_interrupt() && !(task->flags & PF_KTHREAD)))` -> `task_work_add`
(`fs/file_table.c:571-574`). For a userspace task the real `__fput` — which
does `eventpoll_release`, `locks_remove_file`, `f_op->release`, `dput`,
`mntput` and `file_free` (`fs/file_table.c:486-526`) — runs on the way back to
userspace, on the same CPU, still in the same syscall's task context. The cost
is real and per-operation, but it is not cross-CPU and it is not deferred past
the syscall boundary.

`close(2)` does not even defer: it uses `fput_close_sync`
(`fs/open.c:1556-1558`, "We're returning to user space. Don't bother with any
delayed fput() cases"), which calls `__fput` directly.

**This is the well-behaved case and it is worth noticing.** A benchmark that
opens and closes in a loop measures all of it.

### 5.2 Per-operation, potentially on another CPU

**`call_rcu` on dentry free.** `dentry_free` ends in
`call_rcu(&dentry->d_rcu, __d_free)` (`fs/dcache.c:450`), or
`__d_free_external` for out-of-line names (`:442`). The callback runs on
whatever CPU's RCU callback list it lands on, at whatever point the grace
period ends. On a create/unlink workload (U1) that is one deferred `kmem_cache_free`
per operation, batched by RCU into callback runs.

`dput` itself defers nothing else: `fs/dcache.c` contains **no**
`schedule_work`, `queue_work`, `smp_call_function`, `work_struct` or `llist`
at all. The "deferred free" in `dput` is exactly and only the RCU grace period.

**`fput` -> global workqueue, for kernel threads.** When `task_work_add` cannot
be used — an interrupt context, a `PF_KTHREAD`, or a task past
`exit_task_work` — `__fput_deferred` falls through to
`llist_add(&file->f_llist, &delayed_fput_list)` plus
`schedule_delayed_work(&delayed_fput_work, 1)` (`fs/file_table.c:582-583`).
`delayed_fput_list` is **one global `llist` head** (`fs/file_table.c:528`), and
`llist_add` is a cmpxchg loop on a single system-wide cache line. The drain
(`fs/file_table.c:529-536`) is one worker processing a batch.

This does not fire for ordinary userspace `close()`. It fires for kernel
threads dropping file references — loop devices, nfsd, io_uring worker threads.
A workload that generates those at rate contends every CPU on one line. Not a
matrix row today.

### 5.3 Amortised, triggered by pressure rather than by operations

**Dentry shrinking.** `super_cache_scan` (`fs/super.c:181-225`) ->
`prune_dcache_sb` (`fs/dcache.c:1367-1376`) -> `list_lru_shrink_walk` with
`dentry_lru_isolate` -> `shrink_dentry_list`. The concurrency-relevant parts:

- `dentry_lru_isolate` inverts the lock order and therefore uses
  `spin_trylock(&dentry->d_lock)`, returning `LRU_SKIP` on failure
  (`fs/dcache.c:1309-1310`). A dentry that another CPU is actively using is
  skipped, not waited for. Good design; it also means the shrinker's progress
  degrades under contention rather than blocking it.
- It **writes `d_flags`** to clear `DCACHE_REFERENCED` (`fs/dcache.c:1324`) —
  dentry cache line 0, the line every RCU lookup reads (section 2.1). So
  reclaim dirties the lookup line of every dentry it rotates. This is the one
  place where background memory pressure directly costs foreground path walks a
  cache-line transfer.
- `super_cache_scan` takes `super_trylock_shared` and returns `SHRINK_STOP`
  rather than blocking (`fs/super.c:181-201`); `super_cache_count` does not take
  it at all, and the comment says the reason is scalability
  (`fs/super.c:247-256`).

**Inode shrinking.** `prune_icache_sb` (`fs/inode.c:1004-1013`) ->
`inode_lru_isolate` (`:933-993`), same trylock shape (`:941`), same
second-chance `I_REFERENCED` rotation (`:962-966`). It writes `i_state` — inode
line 2 — under `i_lock`.

**Writeback.** `__mark_inode_dirty` (`fs/fs-writeback.c:2694`) is the entry
point, and its lockless early-out at `:2754-2755` means an already-dirty inode
costs an `smp_mb()` and a load. When it does proceed, it takes `i_lock`
(`:2757`), then `locked_inode_to_wb_and_lock_list`, then the bdi writeback
list lock — and `03-vfs-structure.md` section 5 puts the cgroup-writeback
attachment functions (`__inode_attach_wb` pressure 292,
`locked_inode_to_wb_and_lock_list` 219, `inode_switch_wbs` 360) at the top of
the whole layer's atomic-pressure table. **Whether any of that executes on a
warm read-only path is still not established** — the same open question
`03-vfs-structure.md` raises — and it needs execution counts, not the graph.

The structurally relevant fact for this document is that writeback moves work
from the writing CPU to a per-bdi flusher thread, so a write-heavy workload's
cost shows up on a CPU the benchmark is not looking at. That is the best
argument in this directory for the workload matrix over microbenchmarks, and
it is `03-vfs-structure.md` section 7's argument restated with a mechanism.

### 5.4 fsnotify: gated to near-zero, and the gate is on a hot line

`fsnotify` is 1011 instructions — the largest body reachable from the open path
(`01-open-path.md` section 2), sixth largest in the layer overall — but it has
**zero** lock-prefixed instructions and it exits early three times before doing
anything:

1. `fsnotify_file` returns 0 immediately for `FMODE_NONOTIFY` and `O_PATH` fds
   (`include/linux/fsnotify.h:116-129`).
2. `fsnotify_name` and friends return 0 if
   `fsnotify_sb_has_watchers(dir->i_sb)` is false — an
   `atomic_long_read(&sbinfo->watched_objects[0])`, or a NULL `sbinfo`
   (`include/linux/fsnotify.h:19-37`).
3. `fsnotify()` itself returns 0 before `srcu_read_lock` if none of the sb,
   mount, inode, parent-inode or namespace has any marks
   (`fs/notify/fsnotify.c:534-545`), and the comment says why: "srcu_read_lock()
   has a memory barrier which can be expensive".

So on a machine with no inotify/fanotify watchers, the per-operation cost is a
handful of reads: `inode->i_fsnotify_marks` at inode+544 (line 8),
`mnt->mnt_fsnotify_marks` at mount+264 (line 4), and the superblock's
`s_fsnotify_info` at sb+920. All read-only, all on lines that are otherwise
cold.

**When a watcher does exist**, every operation on the watched subtree takes
`srcu_read_lock(&fsnotify_mark_srcu)` (`fs/notify/fsnotify.c:568`) and walks
the mark lists. `watched_objects[prio]` is a global-per-superblock
`atomic_long_t`, read (not written) per event. The cost of *having* a watcher
is therefore paid by every CPU touching that filesystem, which is the shape a
`fanotify` mount mark on `/` produces. No matrix row covers it and it is a real
production pattern (antivirus, audit daemons, container runtimes).

### 5.5 Mount propagation and `d_alloc_parallel`: cascades that do not fire

Two things that look like per-operation cascades and are not:

**Mount propagation is per-mount-operation.** `propagate_mnt` and
`propagate_umount` are reachable only from `attach_recursive_mnt`
(`fs/namespace.c:2603`) and `umount_tree` (`:1799`), both under
`namespace_sem` held for write. `grep` finds no reference to `propagate_mnt`,
`propagate_umount`, `mnt_share` or `mnt_slave_list` in `fs/namei.c` or
`fs/open.c`. The edge from `do_sys_openat2` to `propagate_umount` that
`01-open-path.md` section 2 notes is real (via `mntput` on a lazily-unmounted
tree) and is not taken in the normal case.

**`d_alloc_parallel` is an anti-cascade.** N CPUs missing on the same name in
the same parent do not issue N `->lookup` calls; N-1 of them find the
in-lookup dentry in the 1024-bucket global hash (`fs/dcache.c:2806-2824`) and
wait on `d_wait_lookup` (`:2750-2758`). One `->lookup` is issued. This is the
correct design and it is the reason a cold thundering herd on one path does not
melt the filesystem.

### 5.6 The cascade that is not the kernel's

The n+1 that costs the most is still `readdir` -> `stat` per entry:
`ls -l` on 5000 files issues 5001 `statx` calls, each a full path walk
(`02-stat-path.md` section 4, `30-workload-matrix.md` S6/S7). From the
concurrency side this is worse than it looks in the single-thread accounting,
because each of those 5001 walks takes and drops a dentry reference on **every
component of the shared prefix** if the walk is not RCU — and a `readdir`-then-
`stat` loop on a deep tree is exactly the shape that keeps the parent dentries
hot and contended when several such processes run at once.

The fix is `d_type` from `getdents64`, it is entirely userspace-side, and it is
covered in `../../uutils-opt/02-dtype-type-decisions.md`. Nothing in the kernel
can elide it.

---

## 6. What can and cannot be fixed

Four categories. The test for "worth doing" applied here is: does the change
have a named mechanism, a bounded cost, and a way to be believed — and if the
answer to the last is no on this hardware, that is said rather than hidden.

### (a) Fixable by layout

**The binding constraint is that `struct inode` has no free space.** `pahole`
reports 552 bytes of members in 560, with **2 holes totalling 8 bytes**. Nine
cache lines is 576, so there are 16 bytes of tail slack plus 8 bytes of holes —
24 bytes of room before the structure becomes ten lines. Every ext4, xfs, btrfs
and tmpfs inode embeds this structure, so a tenth line is paid per inode on
every mounted filesystem.

That reframes the existing layout patch. Separating `i_fop` (8 bytes at 344)
from `i_count`/`i_writecount`/`i_readcount` is possible inside the 24-byte
budget. Separating `i_data.i_pages` — the finding in section 2.2 — is not:
`i_data` starts at 360 and the next line boundary is 384, so moving it costs
24 bytes of padding and takes the structure to 584, i.e. **ten cache lines per
inode**. On a machine holding ten million inodes that is 240 MB of extra
footprint traded for a coherence improvement that nobody has measured.

The honest position: **the `i_fop` half is a cheap, provable relayout; the
`i_pages` half is a memory-for-coherence trade that must be priced before it is
proposed.** `kbench/patches/0003-fs-move-i_fop-and-i_flctx-off-the-refcount-cacheline`
addresses the cheap half, and its stated pass/fail gate is HITM reduction under
`perf c2c`, which this hardware cannot produce (section 7). Note also that
section 1.19 weakens the `i_flctx` part of that patch's rationale: `i_flctx` is
read only when `i_opflags & IOP_FLCTX`, which is false for any file that has
never been locked.

**`struct files_struct` line 2 is the cheapest layout fix in this document and
the smallest one.** 32 bytes of padding between `full_fds_bits_init` and
`fd_array` puts the fd array on its own line; the structure grows 704 -> 736,
one per process, so the cost is tens of kilobytes on a busy system. The benefit
is confined to multi-threaded processes doing concurrent I/O on fds 0-3 while
other threads open and close. That is a real pattern and a narrow one.
**Defensible, cheap, and low expected value.** It is also unmeasurable here for
the same reason everything else in this category is.

**`struct file` line 1 is not worth fixing.** `f_path` (read) shares a line with
`f_pos` (written on every read and write), and the structure has 16 bytes of
tail slack, so moving `f_pos` out is free. But in the only case where line 1 is
shared between CPUs — a `struct file` with more than one reference —
`file_needs_f_pos_lock` returns true (`fs/file.c:1231-1232`) and
`mutex_lock(&file->f_pos_lock)` writes offsets 80-103 on the same line anyway.
**Moving `f_pos` would relocate the write, not remove it.** Write that down
rather than doing it.

**`struct dentry`, `struct mount` and `struct super_block` need nothing.**
Section 2 establishes all three are already separated correctly. `struct mount`
in particular is the existence proof: line 0 is the entire per-component walk
working set and it is read-only, because the reference count lives in per-cpu
memory.

### (b) Fixable by removing an operation

**The reference transfer.** Two of the four `d_lockref` RMWs per open/close
cancel within microseconds (`01-open-path.md` section 3). Removing them is
already written (`patches-dopen/0001`), already machine-checked (`proofs/`, 13
theorems including negative controls), and Guzik's v5 has a better shape than
ours — moving `path_get()` out of `do_dentry_open()` into its two callers
rather than adding a `bool` parameter. **This is the one item in this document
with a mechanism, a proof, and a written patch.** It halves the contended-line
traffic on the dentry for workload C4.

**The mount half of the same transfer is worth much less.** `mntget`/`mntput`
are `this_cpu_add` on `mnt_pcp` (`fs/namespace.c:255-264`, `:1426-1431`) — a
private line. Two per-cpu RMWs saved, not two shared-line RMWs.
`01-open-path.md` section 6 says this and it is confirmed here from
`fs/mount.h:56-61`: on SMP there is no non-per-cpu variant.

**`file_ref_put_close` already exists** and already spends one atomic instead
of two on the last reference (`include/linux/file_ref.h:171-187`), used by
`close(2)` via `fput_close_sync`. There is nothing left to remove there.

**What cannot be removed: `i_readcount` / `i_writecount`.** One bare atomic per
open and one per close, on a shared inode line (`fs/open.c:954-960`). The
obvious idea — make them per-cpu, like `mnt_writers` — **does not work, and the
reason is worth writing down so it is not proposed again.** `mnt_pcp` is
affordable because a system has dozens of mounts; `NR_CPUS` x 8 bytes per
*inode* is not affordable when a system holds millions of them. The per-cpu
trick scales with object count, not with CPU count, and inodes are on the wrong
side of that line. This is a hard floor on workload C4 and C6.

### (c) Fixable only by changing the locking design

**`inode_hash_lock` is one global spinlock** (`fs/inode.c:62`) and it is taken
on every inode lookup hit by `iget5_locked` and `insert_inode_locked`. The
obvious fix — shard it per bucket, exactly as the dcache does with
`hlist_bl` — has a precedent in the same subsystem and would turn a global
ceiling into a per-bucket one. The obstacles are real but bounded:
`insert_inode_locked` walks a chain while holding it (`fs/inode.c:1893-1924`),
and `__wait_on_freeing_inode` drops and retakes it around `schedule()`
(`fs/inode.c:2611-2620`).

This is a plausible, upstream-shaped change with a clear mechanism. **It is not
a cache-layout change and it is out of scope for this project**, and it is
recorded here because it is very likely a bigger win for containerised
workloads (M3-M5) than anything in category (a).

**`files_struct->file_lock`** is the ceiling most real threaded software
actually hits (section 4). Fixing it means per-cpu fd allocation or a lock-free
descriptor bitmap. That has been attempted upstream repeatedly and has not
landed, for reasons that are about POSIX fd-allocation semantics — "lowest
available descriptor" is a global property of the table. **Not this project,
and probably not any project that is not specifically about fd allocation.**

**`rename_lock` is global** and every `d_lookup`, `d_path`, `getcwd` and `d_walk`
retries when a rename is in flight. A per-superblock rename lock is conceivable
for the dcache half but not for `d_path`, which walks up across mounts and needs
global topology stability. **Renames are rare enough that this is not worth
doing**, and rule 301 documents the four roles the single lock plays. Leave it.

### (d) Not fixable without changing semantics

| thing | the semantic that pins it |
|---|---|
| `i_rwsem` exclusive on buffered write (`mm/filemap.c:4514`) | POSIX write atomicity within a file. Filesystems that want concurrent writes implement their own scheme (XFS for direct I/O); it is not the VFS's to change |
| `i_rwsem` exclusive on the `O_CREAT` parent (`fs/namei.c:4458`) | create must be atomic with respect to lookup in the same directory. Rule 297 |
| `i_readcount` / `i_writecount` | `ETXTBSY` and `deny_write_access`. Rule set 5.7 |
| `f_pos_lock` (`fs/file.c:1259`) | POSIX requires the file position to advance atomically across a shared descriptor |
| the dentry reference taken at `complete_walk` (`fs/namei.c:1064`) | something must pin the result of the walk across the operation. Rule 229 and `proofs/` |
| per-component `inode_permission` and `security_inode_permission` | credentials, mode and LSM policy can change between components and between syscalls. `02-stat-path.md` section 4 rejects cross-syscall caching for exactly this reason |
| the `->lookup` / `->d_revalidate` / `->permission` indirect dispatches | this is what makes the VFS a VFS. `03-vfs-structure.md` section 6 |

**And one that looks like (d) and is actually (a):** the `relatime` write to
inode line 1. It is a semantic requirement that atime be updated, but *where
`i_atime_sec` sits* is not. `02-stat-path.md` section 5 identifies the mix;
this document adds that under `relatime` a symlinked path also **leaves
RCU-walk** to do it (`fs/namei.c:2046`), converting the rest of the walk to
ref-walk atomics. Both halves of that are unmeasured because the rig is
`noatime` (`scripts/mkrootfs.sh:48`). **Mounting the rig `relatime` is the
cheapest thing on this list and it is gap G3 in the workload matrix.**

### Ranked, with confidence

1. **Reference transfer.** Mechanism named, proof written, patch written,
   effect measured but unattributed. Finish attributing it. Confidence: high.
2. **A `relatime` mount in the rig.** Not a fix — a measurement gap that
   invalidates an assumption in every number produced so far. Cost: one line in
   `mkrootfs.sh`. Confidence: certain, and it is gap G3.
3. **`inode_hash_lock` sharding.** Biggest likely win for container workloads,
   clear precedent, out of scope here. Confidence: medium, unmeasured.
4. **`i_fop` off the inode refcount line.** Provable by `pahole`, fits the
   24-byte budget, benefit unprovable on this hardware. Confidence: layout
   certain, effect unknown.
5. **`fd_array` off the `file_lock` line.** Cheap, narrow, unmeasurable here.
   Confidence: layout certain, effect probably small.
6. **`i_pages` off the inode refcount line.** New finding, real geometry, and
   it costs a tenth cache line per inode. **Do not propose it until the
   footprint side is priced.** Confidence: geometry certain, trade unpriced.

And explicitly not worth doing: moving `f_pos` in `struct file`; sharding
`rename_lock`; any attempt at per-cpu inode open counters.

---

## 7. How to measure each of these on the available rig

Read `/usr/src/kbench/README.md` first; this section only says what follows
from it for the ceilings in section 4.

The rig is a 12-vCPU KVM guest on a WSL2 laptop (AMD Ryzen 9 8940HX, 16C/32T).
Three facts from its own calibration govern everything below:

1. **The guest does not scale on a workload that scales on the host.** The same
   open/close workload scales 5x across 6x the processes on the host (84%
   efficiency) and does not scale at all in the guest. Nested virtualisation
   manufactures cross-CPU cacheline traffic that is not there on real hardware.
   Every "bottleneck" chased through the guest — dentry, inode, hidden
   serialiser — was that artefact.
2. **`perf c2c` and `perf mem` do not run at all**, on host or guest: WSL2
   exposes no AMD IBS, so there is no memory-event PMU and no HITM data. This
   is the stated pass/fail gate for three of the six layout patches.
3. **The control moves.** A `getppid()` loop moved 69% between two runs fifteen
   minutes apart. Only `norm=` is admissible, only as a slope, and only above
   roughly 15-25%.

Against that, the counters that *are* reliable: `insn:k` per operation (0.03%
within a boot, 1.1% between boots), `ftrace function_profile` **hit counts**
(reliable; the nanosecond column is not), syscall counts from `strace -c`, and
`/proc/sys/fs/dentry-state` as a state measure. `LLC-load-misses` counts in the
guest even though it reports `<not supported>` on the host —
`kbench-profile cache` probes availability before using anything
(`scripts/guest/kbench-profile.sh:135-170`).

### 7.1 Per ceiling

| ceiling | measurable here | not measurable here | counter-based substitute |
|---|---|---|---|
| `d_lockref` contention (C4) | **the count**: lock-prefixed RMWs per open/close, statically from `graphs/vfs-full.json` and dynamically via `scripts/count-atomics.sh`. Its header states the gate: "it either drops from 4 to 2 or it does not" | the *cost* of contention. The guest's non-scaling is an artefact, so a sweep slope means nothing here | the RMW count per operation, plus `insn:k` for the instruction half. Note `lockref_*` **cannot be traced at runtime at all** — `lib/Makefile` removes ftrace flags from `lib/`, and `perf probe` refuses because lock primitives are kprobe-blacklisted. The proof is the disassembly |
| `i_readcount` / `i_writecount` (C4, C6) | the count, same way: one `lock incl` at `inode+340` per read-only open, one `lock xadd` per close (`01-open-path.md` section 3) | the line transfer | RMW count per operation. **C6 vs C4 is the useful contrast** and both are `insn:k` and RMW-count comparisons, not timings |
| inode line 5 sharing | **nothing.** This is a coherence effect and the only instrument for it is `perf c2c` | all of it | `pahole` proves the layout changed (`scripts/verify-layout.sh`, two minutes, no full build). The *effect* has to be measured on other hardware or not claimed. The workload matrix says this plainly and should not pretend otherwise |
| inode line 2 sharing (`stat` vs writer) | nothing, same reason | all of it | same: layout only |
| `i_rwsem` exclusive on write (Z-block) | **yes, honestly** — this is a *sleeping* serialisation, so it shows up as context switches and wakeups. `kbench-profile sched` gives switch/wakeup rates and latency histograms | the absolute throughput | wakeup rate per operation, and `function_profile` hit counts on `down_write`/`rwsem_down_write_slowpath`. A serial fraction produces a flat total throughput across N, which is visible even in a noisy guest because it is a *shape*, not a magnitude |
| `i_rwsem` exclusive on `O_CREAT` parent (F3 x C3) | **yes**, same mechanism | absolute numbers | `function_profile` hit count on `lookup_open` and on `rwsem_down_write_slowpath`, per operation. The invariant is "parent `i_rwsem` taken exactly once per create" — a count, per `30-workload-matrix.md` F3 |
| `files_struct->file_lock` (C5) | **yes, better than most** — spinlock contention with N threads produces a large effect, and the threads-vs-processes contrast is a *ratio between two harnesses on the same kernel*, which cancels most of the guest's artefact | which cache line, and the absolute cost | run C5 (threads) and C4 (processes) at the same N and compare. `30-workload-matrix.md` already states the invariant: the dentry-side RMW counts must match. If they do not, fd-table contention is masking dentry contention. Also `function_profile` on `alloc_fd` and `expand_files` |
| `f_pos_lock` (C5) | **yes** — a mutex convoy is context switches, and `kbench-profile sched` sees those | the cost per handoff | `function_profile` hit count on `mutex_lock`/`__mutex_lock_slowpath`, and the pass/fail invariant is binary: two threads reading one fd must take it (`fs/file.c:1231`), two processes with separate `open()`s must not |
| `fs_struct->seq` in ref-walk (C5 x R2/R3) | **partially** — spinlock, so it is a real serialisation | attribution | `function_profile` on `get_fs_pwd`/`get_fs_root`. Better: measure the *RCU-walk ratio* first (below); if the walk stays lazy, this never fires |
| `inode_hash_lock` (M3-M5) | **yes as a count, no as a cost** | the cost | `function_profile` hit counts on `iget5_locked` vs `iget_locked` vs `find_inode_fast` per operation, per filesystem. That answers the question that actually matters — *does this filesystem take the global lock on a hit* — and it is a mechanism fact, not a timing |
| `sb->s_inode_list_lock` (A11, U1) | as a count | as a cost | `function_profile` on `inode_sb_list_add` per operation; and `inodes_stat` before/after |
| `rename_lock`, `mount_lock`, `namespace_sem` | **no.** No workload-matrix row generates the storms that make them matter | all of it | static only: the write-site enumeration in sections 1.4 and 1.22 |
| dentry/inode LRU and the shrinker | **state, not cost** | cost | `/proc/sys/fs/dentry-state` and `/proc/slabinfo` before/during/after; `function_profile` on `prune_dcache_sb` and `dentry_lru_isolate`. The useful invariant is that counts return to baseline after `drop_caches` — which `sweep-bench.sh` and `multifile-bench.sh` already assert |
| delayed `fput` global llist | **not reachable** from any current harness — it fires for kernel threads, not for `close(2)` | all of it | `function_profile` hit count on `delayed_fput` should be **zero** for every workload in the matrix. That is a useful negative check and it is free |
| fsnotify with a watcher | **as a count** | cost | `function_profile` on `fsnotify` and `__fsnotify_parent` with and without an inotify watch on the tree. The gate is binary (`fs/notify/fsnotify.c:540-545`) so the hit count answers it. No matrix row covers this today |
| RCU-walk retention (R1-R4) | **yes, and this is the most valuable measurement available here** | nothing important | lock-prefixed count per operation is definitional: a clean RCU walk takes a small constant, a ref-walk takes a pair per component. Plus `function_profile` hit counts on `try_to_unlazy` and `try_to_unlazy_next` (`fs/namei.c:935`, `:976` — both are real out-of-line symbols, unlike `lockref_*`). **The ratio of unlazy calls to walks is the single number that predicts whether a workload will scale**, and the guest can measure it honestly |

### 7.2 The three things worth building, in order

**One: an unlazy counter.** `function_profile` hit counts on `try_to_unlazy`
and `try_to_unlazy_next`, divided by hit counts on `path_openat` and
`filename_lookup`, per workload. That single ratio tells you whether a workload
is paying per-component atomics or not, which decides every per-object ceiling
in section 4. It needs no new benchmark — it can be collected alongside every
existing kbench run — and it directly fills gaps R2, R3 and M3-M5.

**The symbols exist and are traceable, which is not obvious and was checked.**
Both functions are `static` and both survive out of line — `try_to_unlazy` at
101 instructions, `try_to_unlazy_next` at 118 (`graphs/vfs-full.json`) — and
`builds/baseline/System.map` carries `t try_to_unlazy`, `t try_to_unlazy_next`
and, crucially, the matching `__pfx_` entries, which is the patchable-entry
prologue `function_profile` hooks. This is the opposite of the `lockref_*`
situation, where `lib/Makefile` strips the ftrace flags and nothing can be
counted at runtime at all.

**Two: the C5-versus-C4 contrast.** Run the same shared-inode open storm with
threads and with processes at the same N, on the same kernel, and compare the
RMW counts and the `function_profile` hit counts on `alloc_fd`. This is a
ratio between two measurements on one kernel, so it cancels the guest artefact
that invalidates cross-kernel wall-clock comparison. It fills gap G2 and it
answers the question section 4 says matters most.

**Three: a `relatime` mount.** One line in `scripts/mkrootfs.sh:48`. It turns on
a write to inode line 1 and an RCU-walk exit (`fs/namei.c:2046`) that no number
this project has produced has ever included. Gap G3.

### 7.3 What to stop trying to measure here

- **Any cache-line placement effect.** No IBS, no `perf c2c`, no HITM. `pahole`
  proves the layout; nothing available proves the benefit. Section 6 category
  (a) is entirely in this bucket and saying so is more useful than a number.
- **Any single-point contention figure.** The retracted +185% was the control
  falling with the workload.
- **The `lockref` instruction-count class of change.** kbench already priced it:
  8-16 instructions out of ~6100, about 0.2%, against a 1.11% between-boot
  `insn:k` threshold. Below the counter floor, let alone the clock floor.
- **Absolute scaling of anything.** The guest does not scale. Read slopes and
  ratios, never magnitudes.

---

## Reproducing

    pahole -C inode        /usr/src/kbench/builds/baseline/vmlinux
    pahole -C dentry       /usr/src/kbench/builds/baseline/vmlinux
    pahole -C file         /usr/src/kbench/builds/baseline/vmlinux
    pahole -C files_struct /usr/src/kbench/builds/baseline/vmlinux
    pahole -C super_block  /usr/src/kbench/builds/baseline/vmlinux
    pahole -C mount        /usr/src/kbench/builds/baseline/vmlinux
    pahole -C address_space /usr/src/kbench/builds/baseline/vmlinux   # for i_data
    pahole -C list_lru_node /usr/src/kbench/builds/baseline/vmlinux   # 64 B, aligned

    grep CONFIG_X86_L1_CACHE_SHIFT /usr/src/kbench/builds/baseline/config

    tools/path-report.py graphs/vfs-full.json dput --depth 2
    tools/path-report.py graphs/vfs-full.json do_dentry_open --depth 2
    tools/cascade.py graphs/vfs-full.json                  # breadth / pressure

    grep -n 'try_to_unlazy(nd)\|try_to_unlazy_next(nd' /usr/src/linux/fs/namei.c
    grep -E 'unlazy|legitimize' /usr/src/kbench/builds/baseline/System.map

`fast_dput`, `retain_dentry`, `walk_component`, `handle_mounts` and
`inode_lru_list_del` do **not** exist as symbols in this build — they are
inlined, and `path-report.py` will report them as external. That is the same
point `01-open-path.md` section 1 makes about `do_open()`: reasoning about
them as functions is reasoning about source the compiler folded away.

Every `file:line` in this document is against `/usr/src/linux` at
`518e5b794c06`. A tree at a different commit will have different line numbers
and, in several of the places cited here, different code: this tree's
`iput`, `find_inode`, `i_state`, `fd_install`, `mnt_want_write` and
`super_block` header layout all differ from historical mainline, and a spec
written against an older kernel will be wrong about each of them.
