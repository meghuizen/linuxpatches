# The stat path, as compiled

Static anatomy of `statx(2)` in Linux 7.3.0-rc3+824 (`518e5b794c06`), same
build and method as `01-open-path.md`.

## 1. The shape of it

`fs/stat.c` has two entry shapes and the compiler keeps only one of them as a
function. `vfs_statx_path()` and `vfs_statx_fd()` are both `static` and both
inlined; `vfs_statx()` survives at 109 instructions with an 80-byte frame, and
its callees are exactly:

    filename_lookup   path_put   security_inode_getattr   vfs_getattr_nosec

## 2. Almost all of stat is not stat

Reachable sets, same method and same caveat as before — an upper bound that
includes cold edges, useful for the ratio rather than the absolute:

| root | functions | instructions | atomics | indirect |
|---|---:|---:|---:|---:|
| `vfs_statx` (by path) | 254 | 13 476 | 28 | 32 |
| `filename_lookup` alone | 243 | 13 003 | 25 | 31 |
| `vfs_getattr_nosec` (the actual attribute fetch) | 8 | 287 | 3 | 1 |

**`filename_lookup` is 96.5% of the code reachable under `vfs_statx`.** The
part that actually fetches attributes — `vfs_getattr_nosec` →
`i_op->getattr` or `generic_fillattr` — is 287 instructions, about 2%.

`statx` by path is a path walk with a small attribute copy stapled to the end.
That single ratio is the reason the sequences below matter, and it is why
"make `generic_fillattr` cheaper" is not a useful direction.

## 3. The fd path already exists

`statx(fd, NULL, AT_EMPTY_PATH, ...)` goes `do_statx_fd()` →
`vfs_statx_fd()` → `vfs_statx_path(&fd_file(f)->f_path, ...)`
(`fs/stat.c:768`, `:317`, `:323`). No `filename_lookup`, no dentry reference
cycle, no permission walk — the path was already resolved when the fd was
opened, and the kernel keeps the resolved `struct path` in `file->f_path`.

So the kernel side of "don't stat a path you already have open" is present and
has been for years. What is missing is on the other side of the syscall
boundary: userspace keeps calling `statx` by path anyway. That is the whole
premise of `../../uutils-opt/01-fstat-after-open.md` in this repository — `ls -l`
on 5000 files issues 5001 `statx` calls, every one of them a full path walk
that the process had already paid for.

## 4. The sequences

### open → fstat

Cheap and already correct: one path walk, then `vfs_statx_path` on the
`struct path` the file already owns. Nothing to fix in the kernel.

### open → stat(path)

Two full path walks for one file. The second one re-resolves a path whose
dentry and inode are guaranteed hot, re-runs `inode_permission` at every
component, re-runs `security_inode_permission`, and re-takes and re-drops a
dentry reference. All of it duplicated work, and none of it is something the
kernel can elide — it cannot know the two calls refer to the same file
without doing the walk that tells it so.

This one is a userspace fix, not a kernel fix. Saying so is more useful than
proposing a kernel cache that would have to be invalidated correctly on every
rename, unlink and mount in the system.

### stat(path) → open(path)

The interesting one, and the only place a kernel-side change is even
conceivable. The `stat` walks the path and leaves the dentry and inode hot in
the caches; the `open` walks the identical path again. What is genuinely
repeated:

| repeated | can it be carried over? |
|---|---|
| dentry lookup per component | already is — the dcache is the carry-over |
| `inode_permission` per component | no: credentials and mode can change between the two calls |
| `security_inode_permission` | no: LSM state is not ours to cache |
| dentry reference cycle | no: the `stat` dropped its reference in `path_put` |
| `audit_inode` record | no: separate syscall, separate record |

So the dcache already provides the only carry-over that is safe. The second
walk is cheap *because* of the first, and what remains is the per-component
permission and LSM evaluation, which cannot be cached without changing
semantics. This is a dead end and the honest thing to do is write that down
rather than keep circling it.

### readdir → stat per entry

`find`, `ls -l` and MinIO's listing all do this, and it is the largest
avoidable cost in the whole area — but again on the userspace side, via
`d_type` from `getdents` where the decision only needs the type. Covered in
`30-workload-matrix.md` and in `../../uutils-opt/02-dtype-type-decisions.md`.

## 5. What is actually left for the kernel

Only two things in this document are kernel-side:

1. **`struct kstat` is 192 bytes** and lives on the stack of `do_statx`, whose
   frame is 216 bytes. `vfs_statx`'s own frame is 80 and `filename_lookup`'s is
   320. Nothing here is a problem; it is recorded so that a proposal that
   grows `kstat` knows what it is growing.
2. **`generic_fillattr` is 100 instructions and reads `i_uid`/`i_gid` through
   `make_vfsuid`/`make_vfsgid`** for idmapped mounts, plus `fill_mg_cmtime` and
   `inode_query_iversion`. Three atomics under `vfs_getattr_nosec`. This is
   already small relative to the walk.

3. **`relatime` makes `struct inode` cacheline 1 write-hot, and nothing we
   have measured has ever exercised it.** `pahole` puts `i_size` at 80,
   `i_atime_sec` at 88, `i_mtime_sec` at 96, `i_ctime_sec` at 104 and the
   three `_nsec` fields at 112-123 — all of cacheline 1 (64-127).
   `generic_fillattr` reads every one of them on every `stat`, and under
   `relatime` `touch_atime()` *writes* `i_atime` on the same line. That is a
   read-hot/write-hot mix of exactly the kind the layout series is about, on a
   different line from the one it targets (`i_fop`/`i_flctx` are on line 5).

   The kbench guest root is mounted `noatime` — `scripts/mkrootfs.sh:48`,
   `/dev/vda / ext4 defaults,noatime 0 1` — so no number this project has
   produced includes `touch_atime`'s inode write at all. Real systems default
   to `relatime`. This is a measurement gap, not a finding about the kernel,
   and it needs a `relatime` mount in the rig before anything can be claimed
   about it either way.

The conclusion the data supports: **there is no worthwhile kernel-side stat
optimisation that is independent of the path walk.** Whatever we do for
`openat` we get for `statx` as well, because they share `filename_lookup`, and
that is where 96.5% of it is.

## Reproducing

    tools/path-report.py graphs/static-graph.json vfs_statx --depth 3
    tools/path-report.py graphs/static-graph.json filename_lookup --depth 0
    tools/path-report.py graphs/static-graph.json vfs_getattr_nosec --depth 2

---

## 6. Correction (after the series was written)

Section 4 above concludes that there is no worthwhile kernel-side stat
optimisation independent of the path walk. That conclusion was drawn from
instruction counts, and it is wrong about the thing that matters. The 3.5% of
`vfs_statx` that is not the walk contains **every write to shared memory the
syscall makes**: `lockref_get_not_dead()` in `complete_walk()`, the
`smp_mb()` in `__legitimize_mnt()`, and `lockref_put_return()` in `path_put()`.
They exist only to hand a pinned `struct path` to `->getattr` and the LSM, and
RCU plus the dentry seqcount already protect everything they protect.

Patch 6 of the series (`05-proposal.md` §2.2) applies the getattr before
leaving rcu-walk and re-checks `d_seq` afterwards, so on ext4, xfs and btrfs a
warm stat performs no shared write at all. The walk-percentage argument was
right about instructions and blind to contention; the two are different axes
and this document conflated them.
