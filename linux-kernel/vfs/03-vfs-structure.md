# The VFS as a whole

The structural document. `01-open-path.md` and `02-stat-path.md` take two
syscalls apart; this one takes the whole layer apart and says where the
leverage is. Same tree, same build, same method: Linux 7.3.0-rc3+824
(`518e5b794c06`), gcc 15.2.0 `-O2`, read out of the compiled objects.

Graph: `graphs/vfs-full.json`, **4378 functions, 267 258 instructions,
778 261 bytes, 997 lock-prefixed instructions, 433 indirect dispatches**,
covering all of `fs/`, `fs/notify/`, the page-cache half of `mm/`, the LSM
layer, `lib/lockref.c`, `lib/iov_iter.c` and audit.

    tools/cascade.py graphs/vfs-full.json                  # leverage rankings
    tools/cascade.py graphs/vfs-full.json --syscall-table  # per-syscall cost

## 1. The object model

Six structures carry the whole layer, and every optimisation is ultimately
about one of them or about the references between them.

    super_block ──┬── inode ──── address_space ──── folios
       1408 B     │    560 B         152 B
                  │
                  └── dentry ─── dentry (parent/children)
                       192 B
                        ▲
    mount ─── vfsmount ─┼─ path{mnt,dentry} ─── file ─── files_struct
    368 B      32 B     │        16 B          176 B      (fdtable)
                        │
                   nameidata (240 B, on the stack, never heap)

Ownership, which is the part that actually constrains refactoring:

* a `path` is a *pair* of independent references, `mnt` and `dentry`, and
  they are acquired, transferred and released separately — this is the whole
  subject of `proofs/`
* `file` owns exactly one `path` for its lifetime (`f_path`, `const` since the
  `__f_path` rework, `include/linux/fs.h:1267`)
* `dentry` pins its `inode`; `inode` does not pin its `dentry`
* `nameidata` is stack-allocated and owns references only outside RCU-walk

## 2. The layer map

Code volume by translation unit, which is not the same as cost but does say
where the complexity lives:

| object | funcs | insns | atomics | indirect |
|---|---:|---:|---:|---:|
| `security/selinux/hooks.o` | 251 | 16 988 | 2 | 0 |
| `fs/namei.o` | 156 | 15 204 | 27 | 47 |
| `fs/fs-writeback.o` | 232 | 14 436 | 62 | 53 |
| `security/security.o` | 999 | 14 187 | 0 | 8 |
| `fs/namespace.o` | 151 | 13 989 | 21 | 5 |
| `mm/filemap.o` | 136 | 12 874 | 178 | 16 |
| `fs/locks.o` | 139 | 8 894 | 1 | 33 |
| `lib/iov_iter.o` | 41 | 7 251 | 3 | 0 |
| `fs/inode.o` | 117 | 6 849 | 27 | 14 |
| `fs/dcache.o` | 93 | 6 565 | 15 | 13 |
| `fs/read_write.o` | 84 | 6 045 | 0 | 19 |
| `fs/xattr.o` | 82 | 5 835 | 38 | 4 |
| `fs/buffer.o` | 75 | 5 765 | 146 | 10 |
| `fs/super.o` | 72 | 5 498 | 43 | 18 |
| `fs/open.o` | 88 | 5 191 | 12 | 1 |

Two things fall out of that table immediately.

**The security layer is twice the size of the path walk.** SELinux's hooks
plus the LSM dispatch shims are 31 175 instructions against `namei.o`'s
15 204. `security.o` is 999 functions averaging 14 instructions each — those
are the `static_call` shims, one per hook per module. Nothing in this project
proposes touching it, but any statement of the form "the path walk is where
the time goes" has to survive that number first, and on a system with SELinux
enforcing it may well not.

**`mm/filemap.o` and `fs/buffer.o` carry the atomics.** 178 and 146
lock-prefixed instructions against `dcache.o`'s 15. Reference counting in the
dcache is contended-line traffic on a *few* lines; the page cache is far more
atomic operations spread over far more lines. They are different problems and
conflating them has already cost this project one wrong conclusion.

## 3. The shared spine

`breadth` = how many of the 164 `__x64_sys_*` entry points can reach a
function. It is the leverage number: a change to something with breadth 78
is a change to 78 syscalls.

| function | breadth | callers | insns | atomics | indirect |
|---|---:|---:|---:|---:|---:|
| `fput` | 98 | 150 | 53 | 1 | 0 |
| `__file_ref_put` | 100 | 4 | 30 | 1 | 0 |
| `dput` | 78 | 70 | 203 | 0 | **2** |
| `d_lru_add` | 78 | 4 | 48 | 0 | 0 |
| `lockref_put_return` | 78 | — | 40 | 1 | 0 |
| `__mark_inode_dirty` | 73 | — | — | 1 | 2 |
| `fsnotify` | 69 | 47 | 1011 | 0 | 0 |
| `touch_atime` | 60 | — | — | 0 | 1 |
| `inode_permission` | 58 | — | 128 | 0 | 1 |
| `putname` | 55 | 91 | 50 | 0 | 0 |
| `path_put` | 47 | 71 | 26 | 0 | 0 |
| `iput` | 45 | 42 | 156 | 2 | 0 |

**`dput` is the single highest-leverage function in the VFS.** Breadth 78,
70 distinct callers, 203 instructions, and — the part worth stopping on —
**two indirect dispatches**. One of them is `d_op->d_delete` at
`dentry_operations` offset 0x20, reached on every `dput` that takes the
slow path. With `MITIGATION_RETPOLINE=y` that is a thunk call, on 78 of the
164 syscalls.

`fput` is the same story on the file side: breadth 98, fan-in 150, and a
`lock xadd` on `f_ref`. Nearly every fd-based syscall pays it.

## 4. Per-syscall cost

Reachable code under each entry point. Upper bound, not hot path — the same
caveat as `01-open-path.md` section 2, and for the same reason.

| syscall | funcs | insns | atomics | indirect |
|---|---:|---:|---:|---:|
| `execveat` / `execve` | 517 | 26 598 | 118 | 62 |
| `openat2` | 466 | 25 246 | 105 | 61 |
| `openat` / `open` / `creat` | 463 | 25 177 | 105 | 61 |
| `utimensat` | 409 | 21 953 | 93 | 54 |
| `chown` / `fchownat` / `lchown` | 409 | 21 815 | 92 | 54 |
| `chmod` / `fchmodat` | 408 | 21 738 | 92 | 54 |
| `rename` / `renameat2` | 375 | 21 393 | 76 | 54 |
| `open_tree` | 408 | 21 351 | 77 | 60 |
| `removexattr` | 380 | 20 461 | 70 | 53 |
| `link` / `linkat` | 361 | 19 973 | 65 | 56 |

The shape to notice: **every path-based syscall is within 20% of every
other.** `chmod` reaches 21 738 instructions and `openat` 25 177, because
both are `filename_lookup` plus a small operation. This is the same result
`02-stat-path.md` found for `statx` (96.5% walk) generalised to the whole
surface — *the path walk is the VFS's common cost, and it is shared by
roughly forty syscalls, not two.*

That is the argument for working on the walk rather than on any individual
operation, and it is a structural argument that does not depend on a
measurement this machine cannot make.

## 5. Where the atomics concentrate

`pressure` = breadth × lock-prefixed instructions in the body.

| function | pressure | breadth | atomics |
|---|---:|---:|---:|
| `inode_switch_wbs` | 360 | 45 | 8 |
| `__inode_attach_wb` | 292 | 73 | 4 |
| `__filemap_get_folio_mpol` | 252 | 21 | 12 |
| `locked_inode_to_wb_and_lock_list` | 219 | 73 | 3 |
| `inode_prepare_wbs_switch` | 180 | 45 | 4 |
| `audit_log_start` | 165 | 55 | 3 |
| `wb_io_lists_depopulated` | 146 | 73 | 2 |
| `mntput_no_expire_slowpath` | 110 | 55 | 2 |
| `__d_lookup_unhash` | 110 | 55 | 2 |
| `__file_ref_put` | 100 | 100 | 1 |
| `fput` | 98 | 98 | 1 |
| `iput` | 90 | 45 | 2 |
| `lockref_put_return` | 78 | 78 | 1 |

**cgroup writeback attachment dominates this table and nobody in this project
has looked at it.** `__inode_attach_wb`, `locked_inode_to_wb_and_lock_list`,
`wb_io_lists_depopulated` and `inode_switch_wbs` are all `fs-writeback.o`,
all breadth 45–73. Whether they execute on a warm read-only path is a
question the graph cannot answer — `__mark_inode_dirty` gates most of it —
and it is the first thing to check with execution counts rather than
reachability.

## 6. Indirect dispatch

433 retpoline sites in the layer. By pressure:

| function | pressure | breadth | sites |
|---|---:|---:|---:|
| `pick_link` | 220 | 55 | 4 |
| `lookup_fast` | 165 | 55 | 3 |
| `link_path_walk` | 165 | 55 | 3 |
| `dput` | 156 | 78 | 2 |
| `dentry_kill` | 110 | 55 | 2 |
| `__traverse_mounts` | 110 | 55 | 2 |
| `__lookup_slow` | 110 | 55 | 2 |
| `inode_permission` | 58 | 58 | 1 |
| `touch_atime` | 60 | 60 | 1 |
| `get_cached_acl_rcu` | 58 | 58 | 1 |

These are `->d_revalidate`, `->d_delete`, `->lookup`, `->permission`,
`->get_link`, `->get_acl`. They are the filesystem boundary, they cannot be
devirtualised without changing the design, and on a retpoline kernel each one
is a thunk. Worth stating plainly: **a large part of what the path walk costs
is the indirection that makes the VFS a VFS.** That is not a bug to fix, it
is the price of the abstraction, and any proposal that claims to remove it is
proposing a different kernel.

## 7. Cascades and n+1

Four patterns where one operation drags in more work than it looks like.

**n+1 across the syscall boundary.** `readdir` returns names; the caller then
issues one `stat` per name, each a full path walk. `ls -l` on 5000 files:
5001 `statx`. This is the largest single avoidable cost in the area and it is
entirely userspace-side — `getdents` already carries `d_type`. See
`30-workload-matrix.md` and `../../uutils-opt/`.

**n+1 inside the walk.** Every path component costs a `lookup_fast`, an
`inode_permission` and a `security_inode_permission`. A 16-component path
pays sixteen of each. `link_path_walk` is 401 instructions *per call*, not
per path. Nothing here is redundant — each component genuinely needs its own
permission check — so this is a cost to understand, not to remove.

**Deferred work.** `dput` can lead to `dentry_kill` → `__dentry_kill` → RCU
free; `fput` defers to task-work or a workqueue (`fs/file_table.c`); the
inode LRU and writeback lists are touched per operation and processed later.
The cost is real but it is paid on a different CPU at a different time, which
is exactly the shape that a benchmark measuring one syscall in a loop will
miss and a real workload will feel. This is the best argument for the
workload matrix over microbenchmarks.

**Reference round trips.** The one this project already found: two `get`s and
two `put`s on the dentry per open/close, where two of the four cancel within
microseconds. `01-open-path.md` section 3.

## 8. Reuse: what is already shared, and what could be

Fan-in leaders — `fput` 150 callers, `putname` 91, `path_put` 71, `dput` 70,
`fdget` 62, `fsnotify` 47, `iput` 42 — say the VFS is already well factored
at the bottom. There is no obvious duplicated helper to consolidate.

Where reuse is *possible* but not taken, in descending order of plausibility:

1. **The walk result.** Forty syscalls do `filename_lookup` → small operation
   → `path_put`. Nothing is carried between consecutive syscalls. Discussed
   and rejected in `02-stat-path.md` §4: the dcache already *is* the
   carry-over, and what remains repeated (per-component permission, LSM) is
   not cacheable across syscalls without changing semantics.
2. **The reference.** Carried *within* one syscall, from walk to file. This
   is the one that works and it is already written.
3. **`struct kstat` / `struct nameidata` stack traffic.** 192 and 240 bytes
   of stack, initialised per call. Cheap but not free; measurable only as
   instruction count.

## 9. The axes, and where each is answered

| axis | document |
|---|---|
| correctness rules a change must preserve | `10-validation-rules.md` (312 rules) |
| filesystem compatibility | `20-filesystems-and-vfs.md` (25 filesystems) |
| real workloads and the test matrix | `30-workload-matrix.md` (66-case covering set) |
| 32-bit / 64-bit / ABI compatibility | `40-abi-and-wordsize.md` |
| single-thread vs multi-thread, cache lines, ceilings | `50-concurrency-and-scaling.md` |
| open/stat dynamics | `01-`, `02-` |
| reference ownership, machine-checked | `proofs/` |

## 10. What the structure says to work on

Eight hypotheses, each with its mechanism, its prediction and — the part that
matters — what would show it false. They live in `04-hypotheses.md` rather
than here, because they are claims about the world and this document is a
description of the code.

Summary, ranked by leverage x confidence:

| | claim | status |
|---|---|---|
| H1 | the path walk is 40 syscalls' common cost, not open's | structural |
| H2 | `dput` is the highest-leverage unexamined function | open |
| H3 | the reference round trip is what produced the measured +80% | **unattributed** |
| H4 | `inode` line 5 mixes read-hot `i_fop` with write-hot refcounts | untestable here |
| H5 | cgroup writeback is the largest atomic concentration | open |
| H6 | indirect dispatch is the price of the abstraction, not a defect | structural |
| H7 | the security layer may dominate the path walk | open |
| H8 | `relatime` makes inode line 1 write-hot and we have never measured it | open |

Rejected, with reasons, in `04-hypotheses.md`: per-operation stat work,
cross-syscall walk caching, `lockref` codegen, helper consolidation.

**H3 is the one that matters most.** A number is already being carried —
+80% at 8 processes — whose mechanism is not established, and the test that
would attribute it (a stat-only sweep on a shared inode, no `struct file`
involved) does not exist.
