# 30 — Workload matrix: what real software does to the VFS, and the test set that covers it

Third of three constraint documents. `10-validation-rules.md` says what a change
must not break; `20-filesystems-and-vfs.md` says what each filesystem needs from
the VFS; this one says **what shapes of load actually arrive**, so that the
benchmark and test matrix covers reality rather than one microbenchmark repeated
under different names.

Written against the same tree and build as the rest of this directory:

    source   /usr/src/linux            518e5b794c06   (git status clean)
    version  7.3.0-rc3 + 824 commits
    rig      /usr/src/kbench

## Ground rules for this document

**Provenance is marked on every non-obvious claim.**

- **[V]** — verified here, in this session, against source at `/usr/src/linux` or
  by `strace` on this host. File:line references are to the tree above.
- **[R]** — corroborated by a sibling document in this repository
  (`/usr/src/linuxpatches/uutils-opt/…`), which was itself written against the
  named upstream source. Not re-verified against that upstream here.
- **[G]** — **general knowledge of the system's architecture. No source or
  documentation for it was available on this machine.** Treat as a hypothesis
  that shapes the test matrix, not as a fact. Every such claim is falsifiable by
  one `strace -c` run against the real thing, and where that run is cheap it is
  listed as a gap in Part 4.

**No measured numbers are invented.** Where a count appears it is either read out
of a trace taken here (and said to be), or cited from a document in this repo
(and said to be). Where a magnitude is unknown, it says so.

**What the rig can and cannot see** (`/usr/src/kbench/README.md`, read here):
the measurement host is a KVM guest on a WSL2 laptop. Its control benchmark — a
`getppid()` loop no kernel patch can touch — moved 69% between two runs fifteen
minutes apart. Wall clock cannot resolve effects below roughly 10–15%, and often
not below 25%. Instructions retired repeats to 0.03% within a boot and about
1.1% between boots. **The matrix below therefore leans on counts, not durations,
and every row names the counter that carries it.**

One environmental fact that constrains everything below, read out of the rig:
the guest root is mounted

    /dev/vda / ext4 defaults,noatime 0 1          (scripts/mkrootfs.sh:48)

so **every number kbench has ever produced is ext4 with `noatime`**, and the
benchmark trees all live under `/tmp` on that root — with no script recording
which filesystem `/tmp` actually resolved to at run time. Both facts matter and
both are gaps (Part 4, G3 and G9).

---

# PART 1 — VFS profiles of real software

Each profile states: dominant syscalls, dentry/inode cache temperature, whether
the same inode is opened concurrently (the contention case), file-size
distribution, directory-size distribution, and which VFS path the load lands on.

## 1.1 PostgreSQL

**[G] — no PostgreSQL source or documentation was available on this machine.**

- **Layout.** One file per relation (heap, each index), plus a free-space map and
  a visibility map fork per relation, segmented at 1 GB (`relfilenode`,
  `relfilenode.1`, …). Tablespace directories nest a few levels
  (`base/<dboid>/<relfilenode>`), so paths are short — 4 to 6 components.
- **Dominant syscalls.** `pread`/`pwrite` at 8 KiB block granularity dominate by
  count. `fsync`/`fdatasync` dominate by latency. `open`/`close` are comparatively
  rare **by design**: the backend keeps a per-process virtual file descriptor
  cache (`fd.c`'s VFD layer) precisely so that a relation opened once stays open,
  and re-opens only when the process exceeds its fd budget and the LRU evicts.
- **Why the fd cache matters to us.** PostgreSQL is the canonical example of a
  workload that has *already* removed the repeated path walk from its hot loop.
  It is therefore the right control case for the sequences in Part 1.5: if a VFS
  change only helps software that re-walks paths, PostgreSQL will not move, and
  that is the correct outcome, not a failure.
- **Cache temperature.** Dentry and inode cache are warm and stay warm: the same
  few thousand relation files, pinned by open fds, for the life of the cluster.
  Path walks are rare enough that the *walk* is not the cost; the *inode* is,
  because it is the object every `pread` and every `fsync` goes through.
- **Contention.** Heavy, and on **one inode with many openers**: every backend
  reads the same hot relation and the same index. But they hold separate fds on
  a shared `struct inode` and `struct address_space`, so the contention is on
  `i_rwsem`/`i_lock`/`i_count` and on `address_space`'s tree lock — **not** on the
  dentry, because nobody is re-walking the path. This is a different contention
  shape from the shared-inode open storm the rig currently measures.
- **WAL.** Append-only writes to 16 MB segments in `pg_wal/`, one writer at a
  time under `WALWriteLock`, followed by a durability call whose identity is set
  by `wal_sync_method` — `fdatasync` (typical Linux default), `fsync`,
  `open_datasync` (`O_DSYNC` on the fd, durability folded into the `write`), or
  `open_sync` (`O_SYNC`). The choice changes *which* VFS entry point carries the
  durability, not how many path walks happen. **[G]**
- **Checkpointer / `data_sync_retry`.** The checkpointer fsyncs a large set of
  relation files in a burst. `data_sync_retry=off` (the default) makes a failed
  `fsync` a PANIC rather than a retry, because Linux may clear the error and the
  dirty state on the first `fsync` that reports it. This is a *correctness*
  constraint on any change to writeback error reporting, not a performance one —
  it belongs in `10-validation-rules.md`'s territory, noted here because the
  workload depends on it. **[G]**
- **Temp files.** Sorts and hashes that exceed `work_mem` spill to
  `base/pgsql_tmp/`, creating and unlinking files at a rate that can be high and
  bursty. That *is* a path-walk and dentry-lifecycle load: create, write, read,
  unlink, in a directory that grows and shrinks.
- **`pg_stat_file`.** A SQL-level `stat`. Rare. Not a load shape.
- **Sizes.** Bimodal: 8 KiB blocks inside files of 0 to 1 GiB (segment cap), plus
  16 MB WAL segments. Directory sizes: hundreds to low thousands of entries in
  `base/<dboid>/`.
- **VFS path it lands on:** `read`/`write` through `address_space`, and `fsync`.
  Not path walk. Not `readdir`.

## 1.2 MySQL / InnoDB

**[G] — no MySQL source or documentation was available on this machine.**

- **Layout.** Two regimes. `innodb_file_per_table=ON` (default for many years)
  gives one `.ibd` per table in the schema directory, so fd count and dentry
  count scale with table count. `OFF` gives a small number of `ibdata` files
  shared by everything — a handful of inodes carrying the entire I/O load.
- **The regime matters more than anything else here.** file-per-table is an
  "N inodes, one opener each" shape; `ibdata` is "one inode, every thread" —
  the single-inode contention case, but again at the `inode`/`address_space`
  level rather than the dentry level, because the fds are long-lived.
- **`innodb_flush_method`.** `O_DIRECT` (common on Linux) opens data files with
  `O_DIRECT` and bypasses the page cache for data, still `fsync`ing for metadata;
  `O_DIRECT_NO_FSYNC` drops even that; `fsync` (the portable default) uses
  buffered I/O plus `fsync`. **This is the only workload in this list that makes
  `O_DIRECT` a first-class case rather than a curiosity**, which is why `O_DIRECT`
  earns a matrix row.
- **Redo log.** Circular `ib_logfile*` (or a ring of files in the modern layout),
  written sequentially by the log writer thread and flushed at commit. One inode,
  one writer, many waiters.
- **Doublewrite buffer.** Every page written to the tablespace is first written
  to the doublewrite area and flushed, then written in place. That is a fixed
  **2× amplification of the write+fsync path** for data pages. It means InnoDB's
  `fsync` rate is roughly twice what a naive model predicts, and any change to
  writeback or to `file->f_mapping` reference handling has twice the exposure.
- **Table-definition cache and fd churn.** `table_open_cache` bounds how many
  table handles are open. Exceeding it evicts, and eviction means the next access
  re-opens: a full path walk on a path that was walked before. A production
  server with more tables than cache slots therefore **does** generate repeated
  path walks on a fixed set of paths — the `stat`-warm / re-open shape, at a rate
  set by a configuration mismatch rather than by the query load. **[G]**
- **Cache temperature.** Warm, except at the eviction boundary above.
- **Sizes.** `.ibd` files from 96 KiB (empty table) to hundreds of GiB.
  Directory sizes: one per schema, entry count = table count × (1 or 2).
- **VFS path:** `read`/`write` (often `O_DIRECT`), `fsync`, and — only under
  cache pressure — `open` with a full walk.

## 1.3 GNU grep / fgrep

**[V] — verified by `strace` on this host against GNU grep 3.12.**

Single file, `grep hello t/f1`:

```
openat(AT_FDCWD, "t/f1", O_RDONLY|O_NOCTTY) = 3
fstat(3, {st_mode=S_IFREG|0644, st_size=6, ...}) = 0
read(3, "hello\n", 98304)               = 6
read(3, "", 98304)                      = 0
close(3)                                = 0
```

- **Dominant syscalls:** `openat`, `fstat(fd)`, a `read` loop, `close`. **Four
  syscalls plus one read per 96 KiB of file.**
- **It does `fstat` on the fd, not `stat` on the path.** [V] This is the *good*
  form of sequence S1 (Part 1.5) and grep is the reference for it.
- **No `mmap` of the input.** [V] A 300 KB file was read with three 98304-byte
  `read` calls and no `mmap`. Modern GNU grep does not mmap input; the `--mmap`
  option was removed. Any test matrix that assumes "grep mmaps large files"
  is testing a program that no longer exists.
- **Recursive mode** (`grep -r t`) — [V] traced here:
  ```
  openat(AT_FDCWD, "t", O_RDONLY|O_NOCTTY) = 3
  fstat(3, ...)  = 0          <- fstat on the fd
  close(3)
  newfstatat(AT_FDCWD, "t", ..., 0) = 0     <- SECOND full path walk
  openat(AT_FDCWD, "t", O_RDONLY|...|O_DIRECTORY) = 3   <- THIRD
  getdents64(3, /* 8 entries */, 32768) = 192
  getdents64(3, /* 0 entries */, 32768) = 0
  ```
  **Three full path resolutions of the same name, back to back, on an unchanged
  tree.** [V] That is the cleanest live specimen of the redundancy in Part 1.5
  found in this session.
- Within a directory, entries are opened **relative to the directory fd** with
  `O_NOFOLLOW`: `openat(4, "big", O_RDONLY|O_NOCTTY|O_NONBLOCK|O_NOFOLLOW)`, and a
  symlink correctly returns `ELOOP`. [V] So grep's *inner* loop is already in the
  cheap form (dirfd-relative, no per-entry `stat`) while its *argument handling*
  is in the expensive form.
- **Cache temperature:** cold on first traversal of a source tree, warm on
  re-runs. Recursive grep over a checkout is one of the few real workloads that
  is genuinely **cold-dentry** at scale.
- **Contention:** none. GNU grep is single-threaded.
- **Sizes:** source trees — median file a few KiB, tail to tens of MiB.
- **Directory sizes:** 10–200 typical, occasionally 10 000+ in generated trees.
- **VFS path:** path walk + open + `readdir`, then the read path.

## 1.4 GNU find (findutils)

**[V] — verified by `strace` on this host against GNU findutils 4.10.0.**

`find t -type f`, traced here:

```
newfstatat(AT_FDCWD, "t", {st_mode=S_IFDIR|0755, ...}, AT_SYMLINK_NOFOLLOW) = 0
openat(AT_FDCWD, "t", O_RDONLY|O_NOCTTY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC|O_DIRECTORY) = 4
getdents64(4, /* 8 entries */, 32768) = 192
getdents64(4, /* 0 entries */, 32768) = 0
newfstatat(5, "a", {st_mode=S_IFDIR|0755, ...}, AT_SYMLINK_NOFOLLOW) = 0
getdents64(6, /* 3 entries */, 72
...
```

- **`-type f` issues no `stat` for regular files.** [V] The only `newfstatat`
  calls in the whole traversal are on **directories**, and they are
  `dirfd`-relative with `AT_SYMLINK_NOFOLLOW`. The regular-file type decision is
  answered from `d_type` in the `getdents64` record. This is the `d_type`
  short-circuit working, and it is the reference case for matrix row S9.
- **Why directories still get statted:** fts needs `st_dev`/`st_ino` for cycle
  detection and `st_nlink` for the leaf-count optimisation; `d_type` alone cannot
  supply those. So the stat cost of a `find` walk is **proportional to the number
  of directories, not the number of files**. A matrix that varies file count and
  holds directory count fixed will not move `find`'s stat count at all.
- **When `d_type` cannot avoid the stat:** (a) the predicate needs more than
  type (`-newer`, `-size`, `-perm`, `-user`, `-mtime`); (b) the filesystem
  reports `DT_UNKNOWN`; (c) the entry is a directory, per the point above;
  (d) `-L` / `-follow`, where the type of the *target* is wanted and `d_type`
  describes the link. [R] — the `DT_UNKNOWN` fallback and the dereference
  exception are stated in `/usr/src/linuxpatches/uutils-opt/02-dtype-type-decisions.md`.
- **`-name` short-circuits before any stat at all**: the glob is matched against
  the `getdents64` name. A `find -name '*.c'` walk over a tree issues, per
  directory, one `newfstatat` + one `openat` + two `getdents64` and nothing else. [V]
- **fts is shared.** `du`, `rm`, `chmod`, `chown`, `chgrp` and `find` all walk
  through gnulib's `fts`, and `FTS_NOSTAT` is the opt-out that rides `d_type`.
  [R] — `/usr/src/linuxpatches/uutils-opt/ecosystem/06-gnulib-fts.md`. **GNU `ls`
  does not use fts**; its per-entry stat is in `src/ls.c`'s `gobble_file`, which
  already uses `statx` with field masks. [R]
- **The contrast that defines this row of the matrix** — measured here with
  `strace -c` on a 500-entry directory:

  | command | `statx` calls | `getdents64` calls |
  |---|---|---|
  | `ls big5000` | 6 | 2 |
  | `ls -l big5000` | **507** | 34 |

  [V] — `strace -c -f` on this host, syscall counts only, **no timing claimed**.
  This is the same N+1 shape reported as 5001 statx / 5000 entries in
  `/usr/src/linuxpatches/uutils-opt/ecosystem/05-rust-walk-crates.md` [R].
- **Cache temperature:** cold on a first walk of a large tree — this is the
  workload that *defines* cold-dentry load. Warm on repeat.
- **Contention:** none; single-threaded.
- **Directory sizes:** the whole distribution, 2 to 10⁶.
- **VFS path:** `readdir` and `stat`. Almost no `open` of regular files, and
  almost no reads. **`find` is the one major workload that never touches the
  file open path at all** and therefore the one that a change to `struct file`
  ownership cannot affect — which makes it a good negative control.

## 1.5 ripgrep

**[G] for the crate internals — the `ignore` crate source was not available on
this machine. [R] for the crate's architecture**, from
`/usr/src/linuxpatches/uutils-opt/ecosystem/05-rust-walk-crates.md`, which was
written against it.

- **Parallel walk.** The `ignore` crate's `WalkParallel` runs N worker threads,
  each pulling directories off a shared work queue and doing its own
  `read_dir` + per-entry classification. [R] So unlike `find`, ripgrep produces
  **concurrent `readdir` and concurrent path walk from many threads in one
  process** — sharing one fd table, one `mm`, and one set of parent-directory
  dentries. That is a sharing shape the rig does not currently test at all
  (`sweep-bench.sh` deliberately uses separate processes, and says so in its
  header comment: threads would put the contention on `files->file_lock` in
  `alloc_fd()` instead of on the dentry).
- **gitignore matching is itself VFS load.** For each directory descended into,
  the matcher must find and read `.gitignore`, `.ignore`, `.rgignore` — which
  means an `openat` attempt per candidate name per directory, most of which
  return `ENOENT`. **This generates negative dentries at a rate proportional to
  directory count × ignore-file-name count**, on paths that will be probed again
  on the next run. [G] on the exact filenames and order; the *shape* — repeated
  failing opens creating and re-hitting negative dentries — is the point, and it
  is why `ENOENT` earns two matrix rows rather than a footnote.
- **mmap vs read.** ripgrep uses a heuristic: memory-map when the file is large
  enough and the source is a real file on a real filesystem, read otherwise; it
  does not mmap when the input is a stream or when `--no-mmap` is set. [G] This
  matters to the matrix because mmap moves the read out of the `read` syscall
  path and into the fault path, so a change measured on `read` will not show on
  the mmap'd portion of ripgrep's load.
- **Cache temperature:** cold first run over a checkout, warm after. The parallel
  walk makes the cold case *concurrent* cold misses on the same parent dentries.
- **Contention:** N threads, one fd table, overlapping parent directories,
  distinct target inodes. The interesting case, and untested.
- **VFS path:** `readdir`, path walk, open, read/mmap — all four at once.

## 1.6 Apache Kafka

**[G] — no Kafka source or documentation was available on this machine.**

- **Layout.** Per topic-partition directory, containing a set of segment files:
  `<base-offset>.log` (the data), `.index` (offset→position), `.timeindex`,
  and on newer versions `.snapshot` / leader-epoch files. So roughly **3–5 files
  per segment, and several segments per partition retained.**
- **fd count.** A broker with thousands of partitions holds tens of thousands of
  open fds, because the active segment and the index files of retained segments
  are kept open and memory-mapped (the `.index` files are mmap'd). `ulimit -n`
  tuning is a standard Kafka operational step for exactly this reason. The
  consequence for us: **Kafka pins a very large number of inodes and dentries
  simultaneously**, which is a `dentry`/`inode` slab-footprint load, not a path-walk
  load.
- **Dominant syscalls.** Appending `write` to the active segment; `sendfile`
  (via `FileChannel.transferTo`) for consumer fetches, so the read side goes
  page-cache-to-socket without crossing into user space; `fsync` only on the
  configured flush interval, because Kafka deliberately relies on the page cache
  and on replication rather than per-write durability.
- **`sendfile` is a VFS path almost nothing else in this list uses**, and it is
  the one that reads through `file->f_mapping` with no `read` syscall and no user
  buffer. A change that touches `struct file` or `address_space` ownership has to
  be validated against it, and the rig has no `sendfile` case.
- **Log rolling and retention.** Segments roll on size/time; retention deletes
  whole segments. Deletion is typically rename-to-`.deleted` then unlink after a
  delay — so **rename and unlink of large files with possibly-open fds** is a
  periodic, bursty load. That is exactly the dentry-lifecycle case
  (`d_delete` vs `d_drop`, unlink with an open reference) and it is untested.
- **Cache temperature:** hot for the active segments, cold for cold consumers
  reading old segments off disk.
- **Contention:** many network threads, one process, one fd table — and for a hot
  partition, **many threads on one inode** via `sendfile`. Concurrent, shared fd
  table, shared inode. Another instance of the untested thread-sharing shape.
- **Sizes:** segments default to 1 GiB; index files a few MiB.
- **Directory sizes:** tens to low hundreds of files per partition directory;
  thousands of partition directories.
- **VFS path:** write/append, `sendfile`, `fsync` in bursts, and periodic
  `rename`+`unlink`. Very little path walk after startup.

## 1.7 MinIO

**[G] — no MinIO source or documentation was available on this machine.**

- **Layout.** Object-per-directory: an object at `bucket/a/b/c/obj` becomes a
  directory `…/a/b/c/obj/` containing an `xl.meta` sidecar plus the erasure-coded
  part files (`part.1`, …) for that object's shard on that disk. **Every object
  is at least one directory, one metadata file, and one or more part files.**
- **Consequences, and they are severe for the VFS:**
  - Path depth follows the object key, which is user-controlled and can be deep.
    An S3 key with 8 slashes is an 8-component path walk on every `HeadObject`.
  - `HeadObject` — the most common S3 operation after `GetObject` — is
    essentially "resolve the key path, read `xl.meta`": a full path walk plus an
    open plus a small read, with **no large I/O to amortise it**. MinIO is the
    workload in this list whose cost is most nearly *pure path walk*.
  - Listing (`ListObjectsV2`) walks the directory tree and stats entries, so it
    is `readdir` + `stat` at scale over directories whose entry counts follow the
    user's key distribution — which in practice means a heavy tail: most prefixes
    small, a few with hundreds of thousands of entries.
- **`statx` and `O_DIRECT`.** [G] MinIO uses `O_DIRECT` for large object
  reads/writes to avoid polluting the page cache with data that will not be
  re-read, and buffered I/O for small ones, with a size threshold. It reads
  metadata with `stat`-family calls in bulk during listing and healing.
- **Cache temperature:** the metadata working set is far larger than the dentry
  cache on any realistic deployment, so **MinIO runs permanently cold-ish on the
  dentry cache**. It is the counter-example to every warm-cache benchmark in the
  rig. A change that only helps the warm path will not help MinIO.
- **Contention:** many goroutines on many distinct inodes; healing and scanning
  walk the same trees concurrently with the request path, so **the same parent
  directory dentries are hit concurrently by unrelated work**.
- **Sizes:** `xl.meta` is small (single-digit KiB typically); part files follow
  the object-size distribution, which is the classic object-storage heavy tail —
  millions of small objects, a few very large ones.
- **Directory sizes:** 1–3 entries for an object directory (this is the dominant
  case by count), and arbitrarily large for a prefix directory.
- **VFS path:** path walk, `stat`, `readdir`, then open+read. `fsync` on write.
  **The single most path-walk-dominated workload in this list.**

## 1.8 A full Linux desktop session

Partly **[V]** (the `ld.so` trace below was taken here); the rest **[G]**.

- **`ld.so` is the per-process VFS load, and it is verified.** `strace /bin/true`
  on this host:
  ```
  openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3
  fstat(3, {st_mode=S_IFREG|0644, st_size=56071, ...}) = 0
  mmap(NULL, 56071, PROT_READ, MAP_PRIVATE, 3, 0) = 0x…
  close(3)
  openat(AT_FDCWD, "/usr/lib/x86_64-linux-gnu/libc.so.6", O_RDONLY|O_CLOEXEC) = 3
  fstat(3, {st_mode=S_IFREG|0755, st_size=2190608, ...}) = 0
  mmap(NULL, 2231696, PROT_READ, MAP_PRIVATE|MAP_DENYWRITE, 3, 0) = 0x…
  mmap(…, PROT_READ|PROT_EXEC, …|MAP_FIXED|MAP_DENYWRITE, 3, 0x28000) = 0x…
  mmap(…, PROT_READ,            …|MAP_FIXED|MAP_DENYWRITE, 3, 0x1c0000) = 0x…
  mmap(…, PROT_READ|PROT_WRITE, …|MAP_FIXED|MAP_DENYWRITE, 3, 0x20e000) = 0x…
  mmap(…, PROT_READ|PROT_WRITE, …|MAP_FIXED|MAP_ANONYMOUS, -1, 0) = 0x…
  close(3)
  ```
  **The pattern is exactly `openat` → `fstat(fd)` → 4–5 `mmap` → `close`, per
  shared library.** [V] Note: `fstat` on the fd, never `stat` on the path — the
  dynamic loader is in the good form of sequence S1. A desktop process links 20–60
  libraries; a browser or a GNOME application considerably more. The
  `/etc/ld.so.cache` hit means the search-path probing (which would be a storm of
  `ENOENT` opens across every `-L` directory) mostly does *not* happen — **when
  the cache is present and current.** When it is stale or a library is not in it,
  `ld.so` falls back to probing each search directory in turn, and that *is* an
  `ENOENT`/negative-dentry storm. [G]
- **Boot / systemd unit scanning.** systemd scans every unit directory
  (`/usr/lib/systemd/system`, `/etc/systemd/system`, `/run/systemd/system`, plus
  `.wants`/`.requires` subdirectories) — `readdir` over directories with hundreds
  of entries, followed by `open`+`read` of each unit file and `stat` for symlink
  resolution. Hundreds to low thousands of small files, **entirely cold at boot.**
  This is the single largest cold-dentry burst on a desktop. [G]
- **`/proc` and `/sys`.** Monitoring tools, `ps`, systemd itself, and desktop
  status widgets generate continuous `readdir` of `/proc` plus `open`+`read`+`close`
  of `/proc/<pid>/stat`, `/proc/<pid>/status`, `/sys/class/power_supply/…`. These
  are **synthetic filesystems where the dentry is cheap and the `->read` does all
  the work**, and where `d_revalidate`/`d_delete` behaviour differs from a disk
  filesystem. They are a validation case, not a performance case.
- **Font and icon caches.** `fontconfig` stats every font directory and its cache
  files at startup; the freedesktop icon-theme lookup probes
  `theme/size/category/name.{png,svg,xpm}` across a fallback chain, which is a
  **deliberate ENOENT cascade** — dozens of failing lookups per icon resolved. [G]
  Another negative-dentry generator.
- **dconf/gsettings.** dconf keeps a single mmap'd binary database
  (`~/.config/dconf/user`); reads are page faults, not syscalls, and writes go
  through a helper. Low VFS load, contrary to expectation. [G]
- **Browser profile directories.** Tens of thousands of small files (cache
  entries, IndexedDB, service-worker storage), created, read and unlinked
  continuously, in directories that can reach 10⁴–10⁵ entries. Sizes cluster
  under 64 KiB. This is the desktop's dominant *steady-state* VFS load. [G]
- **inotify.** A desktop session carries thousands of watches (file managers,
  IDEs, sync clients, `systemd --user`). Each watch pins an inode. The
  consequence for us: **inotify raises the floor on how many inodes are pinned
  and therefore unreclaimable**, and `fsnotify` hooks sit on the create/unlink/
  rename paths. `10-validation-rules.md` owns the correctness side; the matrix
  side is that a `drop_caches`-based "cold" test on a real desktop does not get
  as cold as it does in the rig.
- **Contention:** low. Many processes, mostly distinct inodes. The shared-inode
  case is `libc.so.6`, `ld.so.cache` and the locale archive — opened by every
  process that starts, which is a genuine many-opener-one-inode case but at
  process-start rate, not in a loop.
- **VFS path:** open + `fstat` at exec time; `readdir` at scan time; `stat` for
  cache validation; steady-state small reads and writes.

## 1.9 A Linux server

**[G] throughout.**

- **nginx / Apache static serving.** Per request: resolve the URI to a path,
  `open`, `fstat` (for size and mtime, to build `Content-Length` and
  `Last-Modified` and to answer conditional requests), `sendfile` (or `write`),
  `close`. nginx additionally has an **open-file cache**
  (`open_file_cache`) that, when enabled, caches the fd and the stat result for a
  configured time — turning the per-request path walk into nothing. When it is
  *not* enabled, which is the default, **every request is a full path walk plus
  an open plus an fstat.** So nginx spans both sides of the sequences question
  depending on one config line, which makes it the best real-world A/B for
  Part 1.5.
  - Cache temperature: warm for a small hot set, cold in the tail.
  - Contention: **many worker processes opening the same hot file concurrently** —
    this is precisely the shared-inode open storm `sweep-bench.sh` measures, and
    it is the one place in this whole document where the rig's existing
    headline benchmark maps one-to-one onto a real workload.
  - Sizes: whole distribution; media servers skew large, API/asset servers small.
  - Directory sizes: usually modest; asset directories can be large.
- **Log appends.** `write` (or `writev`) to an fd held open for the process
  lifetime, occasionally `rename`+reopen on rotation. Negligible path-walk load,
  but the rotation event is a rename-with-open-fd case.
- **Container image layers on overlayfs.** Every file access in a container is an
  overlayfs lookup: the upper dir is checked, then each lower dir in turn, until
  a hit or a whiteout. **A miss in the upper layer costs one lookup per lower
  layer**, and a 10-layer image is therefore up to 10 underlying lookups per
  component. Overlayfs also implements `d_revalidate` on entries backed by a
  lower filesystem that needs it, which is one of the two realistic ways to force
  the walk out of RCU mode. **This is the highest-leverage untested filesystem in
  the matrix**: it is what essentially all server workloads actually run on, the
  kernel config already enables it (`OVERLAY_FS`, `scripts/kconfig.sh:29` [V]),
  and the rig never uses it.
- **NFS / CIFS mounts.** Network filesystems set `d_revalidate` and attribute
  timeouts, so **path walk cannot stay in RCU mode across a revalidation**, and
  every `stat` may become a round trip. The N+1 stat pattern that is a syscall
  tax locally becomes N serial network round trips here — this is the point the
  sibling ecosystem documents make about where batching actually pays [R]. For
  the matrix, NFS is the archetype of "forced out of RCU-walk" and of
  "wall-clock *can* resolve the effect, because the effect is milliseconds."
  Neither NFS nor CIFS is in the guest kernel config [V — `scripts/kconfig.sh`
  enables `EXT4_FS`, `TMPFS`, `OVERLAY_FS`, `FUSE_FS`, `VIRTIO_FS`, `9P_FS` and
  no others], so covering them needs a config change.
- **Periodic backup walks.** `restic`/`borg`/`rsync`/`tar` walking the whole
  filesystem nightly: `readdir` + `stat` over millions of entries, cold, once.
  Identical in shape to `find`, at a scale that evicts everything else from the
  dentry cache. This is the workload that makes **cold-cache path walk** a
  first-class case rather than a curiosity.
- **VFS path:** open + `fstat` + `sendfile` per request; `readdir`+`stat` in
  bursts; overlayfs multiplying every lookup.

---

# PART 1.5 — SEQUENCES: the case ordinary benchmarks miss

Every benchmark in `/usr/src/kbench/scripts/guest/` measures **one operation
repeated**. Real software issues **pairs**, and the second member of the pair
usually operates on an object the kernel just finished resolving for the first.
That is where the redundancy lives, and no amount of repeating a single `open()`
will show it.

This section is a dimension of the truth table in its own right, not a row of
it: every case in Part 2 can be run in any of these sequences, and the sequence
changes what is being measured.

All file:line references below were read out of `/usr/src/linux` at
`518e5b794c06` in this session and the surrounding code was checked by eye.
**Note this tree is not identical to older mainline**: `do_filp_open` is named
`do_file_open` (`fs/namei.c:5019`), and `struct file` carries a `const struct
path f_path` with a writable alias `__f_path` (`include/linux/fs.h:1268-1269`).

## The costs a second resolution pays

Fixing vocabulary first, so each sequence can be scored against the same list.

| cost | where it happens | per what |
|---|---|---|
| path walk | `link_path_walk` `fs/namei.c:2578`; `filename_lookup` `fs/namei.c:2849` | per resolution |
| dentry/mount reference cycle | `path_get` `fs/namei.c:707` / `path_put` `fs/namei.c:720`; `legitimize_path` `fs/namei.c:881` on leaving RCU; `terminate_walk` `fs/namei.c:843`, `path_put` at `:849` | per resolution that leaves RCU mode |
| DAC permission | `may_lookup` `fs/namei.c:1955` (called at `:2604`, once per component) → `inode_permission` `fs/namei.c:628` → `generic_permission` `fs/namei.c:521`; terminal `may_open` `fs/namei.c:4231`, called from `do_open` at `fs/namei.c:4835` | per component, plus one terminal |
| LSM decision | `security_inode_permission` `fs/namei.c:661` and in the fast path `fs/namei.c:698`; `security_file_open` `fs/open.c:973`; `security_inode_getattr` `fs/stat.c:259` | per component + one terminal |
| audit record | `audit_inode` `fs/namei.c:2849` (lookup), `fs/namei.c:4804` (`do_open`), `fs/namei.c:4493` (`lookup_open`, parent), `fs/namei.c:4973` (`do_o_path`) | per resolution |
| file object | `alloc_empty_file`, `vfs_open` `fs/open.c:1096`, `do_dentry_open` `fs/open.c:934`, fd-table insert, `fput` | per open only |

Two facts that the rest of this section turns on:

1. **`fstat`/`statx(fd)` performs no path resolution at all.** `vfs_fstat`
   (`fs/stat.c:276`) is three lines: `CLASS(fd_raw, f)(fd)` at `:278`, then
   `return vfs_getattr(&fd_file(f)->f_path, stat, STATX_BASIC_STATS, 0)` at
   `:281`. It reuses the `struct path` the file already owns. `vfs_statx_fd`
   (`fs/stat.c:317`) is the same shape at `:320`/`:323`. `statx(2)` routes there
   directly at `fs/stat.c:812`, and `vfs_fstatat` short-circuits at
   `fs/stat.c:371`. **Zero walks, zero component permission checks, zero
   `audit_inode`.** [V]
2. **`stat(path)` performs a complete, independent resolution.** `vfs_statx`
   (`fs/stat.c:341`) calls `filename_lookup(dfd, filename, lookup_flags, &path,
   NULL)` at `:353` and `path_put(&path)` at `:357` — the reference it takes is
   taken and released inside the one syscall and nothing survives it. [V]

## S1 — `open(path)` → `fstat(fd)`

The minimal form, and the one the dynamic loader uses.

| | |
|---|---|
| path walks | **1** |
| dentry/mount ref cycles | 1 (the open's; the file keeps it via `path_get(&f->f_path)` at `fs/open.c:941`, stored by `vfs_open` at `fs/open.c:1100` as `file->__f_path = *path`) |
| DAC permission evaluations | components + 1 terminal `may_open` |
| LSM decisions | components + `security_file_open` + `security_inode_getattr` |
| `audit_inode` | 1 (`fs/namei.c:4804`) |
| provably redundant | **nothing** |

**Verified in the wild:** `ld.so` does exactly this, per shared library —
`openat` → `fstat(3, …)` → `mmap`×4–5 → `close` [V, traced here]. GNU grep 3.12
does it per input file [V, traced here].

**Nothing to skip. This is the target form for the others.**

## S2 — `open(path)` → `stat(path)`

The same object, resolved twice, with the fd already in hand.

| | |
|---|---|
| path walks | **2** |
| dentry/mount ref cycles | 2 — the open's (kept by the file) and the stat's (taken at `fs/stat.c:353`, dropped at `:357`). In the warm case the stat's walk stays in RCU mode to the last component, so its atomic cost is the one `legitimize_path` pair (`fs/namei.c:881`), not a pair per component. |
| DAC permission evaluations | **2 × (components + terminal)** |
| LSM decisions | 2 × components, plus `security_file_open` **and** `security_inode_getattr` |
| `audit_inode` | **2** — `fs/namei.c:4804` then `fs/namei.c:2849` |
| provably redundant **on an unchanged tree** | the entire second walk: every component lookup, every component permission check, every component LSM call, and the second audit record |

**But "on an unchanged tree" is not something the kernel may assume.** Between
the two syscalls the final component can be renamed or replaced by a symlink —
that is the TOCTOU race that makes S2 a *correctness* bug and not only a cost
[R, `/usr/src/linuxpatches/uutils-opt/01-fstat-after-open.md`]. Credentials and
LSM policy can also change; SELinux's AVC revocation sequence exists precisely
because a cached access decision has a validity window.

**What would have to be true for the second resolution to be skippable:**
userspace would have to say "the object I already hold" instead of repeating the
name. **That mechanism already exists** — `fstat(fd)`, or
`statx(fd, "", AT_EMPTY_PATH, …)`. So S2 is a userspace defect, not a missing
kernel facility, and no VFS change should be designed to rescue it.

**Verified in the wild, and it is not rare:** `grep -r t` on this host resolved
the same name three times in a row [V]:

```
openat(AT_FDCWD, "t", O_RDONLY|O_NOCTTY) = 3   fstat(3,…)   close(3)
newfstatat(AT_FDCWD, "t", …, 0) = 0                       <- walk 2
openat(AT_FDCWD, "t", O_RDONLY|…|O_DIRECTORY) = 3         <- walk 3
```

**Generated by:** `ls -l` [V: 507 `statx` for a 500-entry directory], the
uutils `fs::metadata` + `File::open` pattern [R], any tool that classifies a
file before opening it.

## S3 — `stat(path)` → `open(path)`

The same two walks in the other order, and the one the project owner named.

| | |
|---|---|
| path walks | **2**, of an identical string, back to back |
| dentry/mount ref cycles | 2. The stat's is dropped at `fs/stat.c:357` before the open begins. |
| DAC permission evaluations | 2 × components, + `may_open` on the second |
| LSM decisions | 2 × components, + `security_inode_getattr` then `security_file_open` |
| `audit_inode` | 2 — `fs/namei.c:2849` then `fs/namei.c:4804` |

**What the first call leaves behind, and what it does not:**

| carried over to the second walk? | what | why |
|---|---|---|
| ✅ dentry cache entries | the parent chain and the target are now hashed and live | the cache is global; this is the only thing that carries |
| ✅ inode cache entries | same | same |
| ✅ page-cache state for the directory blocks | same | same |
| ❌ **the dentry reference** | dropped at `fs/stat.c:357` | `path_put` is unconditional; nothing outlives the syscall |
| ❌ **the inode reference** | dropped with it | same |
| ❌ **the permission result** | recomputed per component by `may_lookup` → `generic_permission` | no per-(task, inode, mask) cache exists in the VFS |
| ❌ **the LSM decision** | `security_inode_permission` called again per component | SELinux caches it *internally* in the AVC with a revocation sequence; the VFS layer does not know that |
| ❌ **the `audit_inode` record** | emitted twice for the same inode | by design — two syscalls, two records |

**Provably redundant on an unchanged tree:** the second walk's *lookups*. **Not**
the permission or LSM decisions, which are only valid at the instant they are
taken against the object they are taken for — batching the mechanism is safe,
batching the decision is not, and kbench's README already reached that
conclusion for batched `open`.

**What would have to be true to skip the second walk:** the caller must hold a
kernel-side handle to the resolved object across both calls. That is `O_PATH` —
`build_open_flags` strips it to `O_PATH_FLAGS` (`fs/open.c:1183`, applied at
`:1193-1194`), sets `acc_mode = 0` (`fs/open.c:1277-1281`), sets no
`LOOKUP_OPEN` intent (`fs/open.c:1319`), and `path_openat` short-circuits the
entire open machinery into `do_o_path` (`fs/namei.c:4992-4993`, `do_o_path` at
`:4968`); `do_dentry_open` then returns early without calling `->open` or
`security_file_open` (`fs/open.c:947-951`). So `open(path, O_PATH)` →
`statx(fd,"",AT_EMPTY_PATH)` → `openat(fd,"",O_RDONLY|AT_EMPTY_PATH)` is two
cheap walks plus one real one instead of two real ones. [V]

**Better still: reorder into S1.** S3 is S2 written backwards and has the same
answer — the second resolution is avoidable in userspace today.

**Generated by:** MySQL/InnoDB when the table-definition cache evicts and the
next access re-opens a path it just statted [G]; nginx without
`open_file_cache` where a `try_files` probe precedes the open [G]; any
"check then act" file utility.

## S4 — `stat(path)` → `stat(path)` (the polling loop)

A build system asking "has this changed?" about 10 000 files, repeatedly.

| | |
|---|---|
| path walks | **N**, one per poll, all identical |
| dentry/mount ref cycles | N (each taken at `fs/stat.c:353`, dropped at `:357`) |
| DAC permission evaluations | N × components |
| LSM decisions | N × components + N × `security_inode_getattr` |
| `audit_inode` | N (`fs/namei.c:2849`) |
| provably redundant | **the walks. Not the `->getattr`.** |

This is the sequence where the redundancy is *most* clear-cut and *least*
fixable by reordering. The caller genuinely wants a fresh attribute read each
time — that is the whole point — but it does not want a fresh *path resolution*,
and the kernel gives it no way to separate the two through a path-based API.

**What would have to be true to skip the repeat walk:**

- The caller holds an `O_PATH` fd per watched file and uses
  `statx(fd, "", AT_EMPTY_PATH, …)`. Correct, walk-free, and costs one fd per
  file — a build system watching 50 000 files needs 50 000 fds. That is the real
  reason this is not already universal.
- Or it stops asking and gets told: `inotify`/`fanotify`. Correct, and the
  standard answer, at the cost of watch-descriptor pressure (Part 1.8).
- Or the syscall boundary is amortised with `IORING_OP_STATX`. This amortises
  **the boundary only** — each SQE carries its own path and resolves it
  independently, so the N walks remain N walks. Pairing each SQE with a `dirfd`
  amortises the prefix as well, which is the same composition `batch-open-bench.sh`
  already measured for `open` (its 1→2 and 3→4 gaps).

**The honest kernel-side conclusion:** there is no safe general mechanism to
carry a resolution across two path-based syscalls, because a path is a name and
names are not stable. Every real fix hands the caller a handle instead, and the
kernel already has three (`fd`, `O_PATH` fd, `dirfd`).

**Generated by:** `make`/`ninja`/`cargo`/`bazel` staleness checks; `ls -l` in a
watch loop; MinIO's scanner re-reading `xl.meta` paths [G].

## S5 — `openat(dirfd, name)` after `open(dir)`

The case where userspace already did the work.

| | |
|---|---|
| path walks | **1 short one** — `path_init` (`fs/namei.c:2683`) starts from the dirfd's path, so there are no intermediate components to walk |
| dentry/mount ref cycles | 1 (the terminal one) |
| DAC permission evaluations | **0 component checks** + 1 terminal `may_open` (`fs/namei.c:4835` → `:4231` → `inode_permission` at `:4269`) |
| LSM decisions | 1 (`security_file_open`, `fs/open.c:973`) — the per-component `security_inode_permission` calls are gone with the components |
| `audit_inode` | 1 (`fs/namei.c:4804`) |
| provably redundant | nothing; the prefix cost was already paid once, at `open(dir)` |

**What the rig already knows about this:** `batch-open-bench.sh` measures exactly
this against the full-path form at depth 5, and `/usr/src/kbench/README.md`
reports the prefix amortisation as **+32.1%** on the baseline kernel, composing
independently with io_uring's syscall-boundary amortisation (+33% on top of it).
Those are kbench's measured figures, cited from that file, not re-measured here.

**What remains per call, and cannot be batched away:** final component lookup,
terminal permission check, `alloc_empty_file`, fd-table insert, `fput`.

**Generated by:** gnulib `fts` — verified here, GNU find issues
`newfstatat(5, "a", …, AT_SYMLINK_NOFOLLOW)` and `openat(dirfd, …)`, never a full
path [V]; GNU grep's recursive inner loop, `openat(4, "big", O_RDONLY|…|O_NOFOLLOW)`
[V]; Kafka and MinIO [G].

## S6 / S7 — `readdir` → per-entry `stat`, versus `readdir` → `d_type`

The largest single lever in this document, because it is a **whole syscall per
directory entry** and directories are the one dimension that reaches 10⁶.

`getdents64` (`fs/readdir.c:384`) → `iterate_dir` (`fs/readdir.c:87`) →
`filldir64` (`fs/readdir.c:341`), which masks the type at `:352`
(`d_type &= S_DT_MASK`) and writes it to userspace at `:370`
(`unsafe_put_user(d_type, &dirent->d_type, efault)`). **The type byte has already
crossed the syscall boundary before any stat is issued.** [V]

| form | walks per entry | ref cycles | DAC evals | LSM evals | audit records |
|---|---|---|---|---|---|
| **S6a** `readdir` → `stat(full/path/entry)` | 1 full (all components) | 1 | components + 1 | components + 1 | 1 |
| **S6b** `readdir` → `fstatat(dirfd, name)` | 1 single-component | 1 | 1 | 1 | 1 |
| **S7** `readdir` → `d_type` from the buffer | **0** | **0** | **0** | **0** | **0** |

**Provably redundant on an unchanged tree:** if the only question is the type,
S6a and S6b are 100% redundant — the answer was already delivered. Verified
contrast, `strace -c` on this host over a 500-entry directory: `ls` issues 6
`statx`, `ls -l` issues **507** [V].

**When it is not redundant, and the matrix must say so:**

1. The predicate needs more than the type (size, mtime, mode, owner, nlink).
   `ls -l`, `du`, `find -newer` are in this class and no amount of `d_type` helps.
2. The filesystem returns `DT_UNKNOWN`. Then the stat is mandatory. [R]
3. The entry is a directory and the walker needs `st_dev`/`st_ino` for cycle
   detection or `st_nlink` for the leaf optimisation — which is why GNU find
   stats **directories** even under `-type f` [V].
4. Symlink dereference is requested (`-L`, `ls -L`): `d_type` describes the link,
   not the target. [R]

**What would have to be true to make case 1 cheaper:** nothing in the type
decision — it is already free. The lever is batching the attribute fetch, and the
honest ceiling is the syscall boundary plus, if the batch uses `dirfd`+name, the
prefix. **Not the per-entry lookup or the per-entry `->getattr`.**

**Generated by:** `find` [V], `ls -l` [V], `du`, `rm -r`, MinIO listing [G],
ripgrep's ignore-matching walk [R/G], every backup walker [G].

## Sequence coverage, stated bluntly

| sequence | covered by any kbench script today? |
|---|---|
| S1 `open`→`fstat(fd)` | **no** |
| S2 `open`→`stat(path)` | **no** |
| S3 `stat(path)`→`open(path)` | **no** |
| S4 `stat`→`stat` | **no** — `kbench-run.sh` fs-ops mode 0 is `stat` in a loop over 64 *rotating* paths, which is a different thing |
| S5 `openat(dirfd)` after `open(dir)` | **yes** — `batch-open-bench.sh` variant 2, `kbench-run.sh` fs-ops mode 3 |
| S6a/S6b `readdir`→`stat` | **no** — fs-ops mode 1 does `readdir` and then nothing |
| S7 `readdir`→`d_type` | **no** |

Six of seven sequences are uncovered, and they are the six that real software
generates most often.

---

# PART 2 — The truth table

## 2.0 Why this is a covering set and not a cross product

The dimensions named in the brief multiply out to roughly

    12 ops × 8 path shapes × 5 cache states × 4 sharing modes
       × 6 file sizes × 4 directory sizes × 9 flag sets
       × 8 filesystems × 5 mount-option sets   ≈ 1.7 × 10⁷ cells

At the rig's cost per point — `sweep-bench.sh` alone is minutes, a full
`tree-bench.sh` section costs nine minutes a boot — that is not a test matrix,
it is a thought experiment. **A matrix nobody can run is worthless.**

The covering set below is **66 cases**, organised in ten blocks. The
construction rule is:

> Each dimension is swept against a **fixed reference point** (ext4, warm,
> depth 8, single process, 4 KiB file, `O_RDONLY`, `relatime`), and combinations
> of two non-reference dimensions are included **only where a mechanism
> plausibly couples them**. Everything else is asserted redundant, with a reason.

The reference point is case **A2**. Every other case differs from it in one
dimension, except where a coupling is named.

### Redundant combinations, dropped, with reasons

| dropped | why |
|---|---|
| file size × everything | File size affects the **read** path (`address_space`, page cache) and nothing in the walk, the open, or the reference handling. It is swept once (Block Z) against the reference point, never crossed with path shape, sharing, or flags. Crossing it would test the page cache repeatedly under different names. |
| directory size × file size | Orthogonal by construction: directory size is dirent/htree cost, file size is page-cache cost. No shared mechanism. |
| path depth × flags | `O_TRUNC`, `O_TMPFILE`, `O_DIRECT`, `O_PATH` all act on or after the **final** component. Depth adds identical prefix work to all of them, so a depth sweep per flag re-measures the depth sweep. Flags are tested at depth 8 only. |
| path depth × file size | Same reason, from the other side. |
| cold cache × high iteration counts | Impossible, not redundant: `drop_caches` makes the *first* access cold and every subsequent one warm. Cold cases are single-shot and counter-only (see Part 3), and are therefore separate cases, not a cache-state multiplier on every row. |
| sharing × flags | The contention is on the dentry and inode cachelines; which `O_` bit was set does not change which cacheline is hit. Sharing is swept with `O_RDONLY` only. |
| mount options × filesystem | `noatime`/`ro`/`nosuid` are VFS-level (`MNT_*` flags, checked in `fs/inode.c:2286-2288` for atime [V]) and behave identically across filesystems. Swept on ext4 only. `idmapped` is the exception and is called out. |
| tmpfs × directory size 10⁶ | tmpfs dirents are in memory; a 10⁶-entry tmpfs directory measures the guest's RAM budget, not the VFS. |
| every op × every filesystem | Filesystems are swept with **one** op that maximally exposes their difference: `open`+`fstat` at depth 8, because that is where `d_revalidate`, stacking and the `->lookup` implementation all show. |
| `O_DIRECT` × file sizes below 4 KiB | Alignment constraints make it meaningless. |

### What that costs to run

Most cases are single-process counter runs of a few seconds (`insn-per-open.sh`
shape). The expensive ones are the sharing sweeps (Block C, minutes each), the
10⁶-entry directory build (Block D4, minutes to construct), and the 1 GiB file
(Block Z6, one-off). **A full pass is a single boot's work, not nine.**

---

## 2.1 Block S — Sequences (8 cases)

Reference: ext4, warm, depth 8, single process, 4 KiB file, `O_RDONLY`,
`relatime`. The variable is the *pair*, not the operation.

| ID | what it exercises | stands for | covered? | invariant — measure this; this must not change |
|---|---|---|---|---|
| **S1** | `open(path)` + `fstat(fd)`; one walk, one `vfs_getattr` off `f_path` | `ld.so` [V], GNU grep [V], PostgreSQL steady state [G] | **GAP** | Measure: syscalls/op = 3 (`openat`,`fstat`,`close`); `insn:k`/op. Must not change: `fstat` must contribute **zero** `filename_lookup` calls (ftrace hit count on `filename_lookup` == open count, not 2× it). |
| **S2** | `open(path)` + `stat(path)`; two independent walks of one name | `grep -r` argument handling [V], `ls -l`-style classify-then-open [V], uutils `fs::metadata`+`open` [R] | **GAP** | Measure: `filename_lookup` hit count == 2 × op count; `insn:k`/op vs S1 — **the delta is the price of one redundant walk, and it is the number this whole project is about.** Must not change: `audit_inode` count stays 2/op, permission-hook count stays 2×(components+1). |
| **S3** | `stat(path)` then `open(path)`; same two walks, reversed | MySQL table-cache eviction re-open [G], nginx `try_files` then open [G] | **GAP** | Measure: same counters as S2. Must not change: S3's counter totals must equal S2's — if they differ, ordering is doing something the model does not predict and the model is wrong. |
| **S4** | `statx(path)` × N on one unchanged path (polling) | `make`/`ninja`/`cargo` staleness checks [G], MinIO scanner [G] | **GAP** (`kbench-run.sh` fs-ops mode 0 rotates over 64 paths — different shape) | Measure: `insn:k`/statx; `filename_lookup` count == N. Must not change: the N-th call must cost the same as the 2nd (no hidden per-call state); a drift proves a cache is being built that is not supposed to exist. |
| **S5** | `openat(dirfd, name)` after one `open(dir)` | gnulib fts [V], `grep -r` inner loop [V], Kafka, MinIO [G] | **covered** — `batch-open-bench.sh` variant 2; `kbench-run.sh` fs-ops mode 3 | Measure: `insn:k`/open vs S1 at the same depth. Must not change: component permission-hook count must fall to 1 (`may_open` only); if per-component `security_inode_permission` still fires, the dirfd start is not being honoured. |
| **S6a** | `getdents64` then `stat("dir/entry")` per entry | `ls -l` [V], `du` [G], MinIO listing [G] | **GAP** | Measure: `statx` count == entries (+O(1)); `insn:k` per entry. Must not change: one `filename_lookup` per entry, full component count each. |
| **S6b** | `getdents64` then `fstatat(dirfd, name)` per entry | gnulib fts [V] | **GAP** | Measure: `insn:k` per entry vs S6a — the gap is the prefix cost at that depth. Must not change: `filename_lookup` count unchanged from S6a (still one per entry), only its length changes. |
| **S7** | `getdents64`, type taken from `d_type`, no stat | `find -type f` [V], `ls` without `-l` [V], `rm -r` fast path [R] | **GAP** | Measure: stat-family syscalls == 0; `insn:k` per entry. Must not change: **zero** `filename_lookup`, zero permission hooks, zero `audit_inode` for the entries. Any nonzero value means `d_type` was `DT_UNKNOWN` and the case silently became S6b. |

## 2.2 Block A — Path shape × cache state (12 cases)

Single process, ext4, `O_RDONLY`, 4 KiB target, `relatime`.

| ID | what it exercises | stands for | covered? | invariant |
|---|---|---|---|---|
| **A1** | depth 1 (`/f`), warm | `/etc/ld.so.cache` [V], flat data dirs | partial — `multifile-bench.sh` uses `/tmp/mfbench/fN` (depth 2) | Measure `insn:k`/open. Baseline for the per-component slope. |
| **A2** | **depth 8, warm — THE REFERENCE POINT** | PostgreSQL `base/<db>/<rel>` [G], MinIO object keys [G] | partial — `insn-per-open.sh` uses depth 5 (`/tmp/insnopen/d1..d5/f0`), `batch-open-bench.sh` depth 5 | `insn:k`/open, `lock`-prefixed count/open, `L1-dcache-load-misses`/open. The slope A1→A2→A3→A4 must be **linear in components**; a knee means something per-walk is being amortised that shouldn't be. |
| **A3** | depth 16, warm | deep MinIO keys [G], node_modules-class trees | **GAP** (`tree-bench.sh` sweeps depth but over its own tree shape) | as A2 |
| **A4** | depth 32, warm | pathological but legal; the stress point for `nd->stack` | **GAP** | as A2, plus: no change in error behaviour |
| **A5** | depth 8, **1 symlink component** | `/usr/lib` → `/lib` class symlinks, container layouts [G] | **GAP** | Measure `insn:k`/open vs A2. Must not change: exactly one extra `pick_link` (`fs/namei.c:2040` region) and one extra `audit_inode` at `fs/namei.c:1299` for a trailing link. |
| **A6** | depth 8, **4 symlink components** | symlink farms, Nix/Guix store paths [G] | **GAP** | The A5→A6 slope must be linear in link count; `nd->depth` must return to 0 (`terminate_walk`, `fs/namei.c:843`, drops `nd->stack[i]` at `:850`). |
| **A7** | depth 8, **crossing a mount point** at component 4 | container layer boundaries, `/proc` and `/sys` under a session, NFS mounts [G] | **GAP** | Measure: `insn:k`/open vs A2; mount-reference count. Must not change: the `mnt` refcount must return to its start value — the `dopen` design note says the mount reference is deliberately **not** transferred because `mnt_drop_write` still needs it, and this is the case that proves it. |
| **A8** | depth 8 written with `..` backtracking (`a/b/../b/c/...`) | shell-constructed paths, `realpath` inputs [G] | **GAP** | Must resolve to the identical inode as A2. Measure `insn:k` delta — `..` is a `d_parent` step, cheaper than a lookup; if it is not cheaper, the fast path is not being taken. |
| **A9** | depth 8, **final component ENOENT** (negative dentry, warm) | ripgrep's `.gitignore` probing [R/G], icon-theme fallback cascade [G], `ld.so` search-path probing [G] | **GAP** | Measure: `insn:k`/failed-open; negative dentry count in `/proc/sys/fs/dentry-state`. Must not change: **no `struct file` is allocated** and no reference leaks — repeat until the dentry cache stops growing, then assert it is stable. |
| **A10** | depth 8, **ENOENT at component 4** (walk aborts mid-path) | mistyped and stale paths, config search lists [G] | **GAP** | `insn:k` must be strictly less than A9 by roughly the 4 remaining components' worth. Must not change: `terminate_walk` releases everything; dentry count stable across repeats. |
| **A11** | depth 8, **cold** (`drop_caches`, single-shot, first touch) | `find`/backup walks [V/G], boot unit scan [G], MinIO's permanently-cold metadata set [G] | **GAP** — `insn-per-open.sh` drops caches and then *warms the path* deliberately, so nothing in the rig measures a cold open | Measure: **counters only, one op per drop** — `insn:k`, block reads. Wall clock here is I/O, not VFS. Must not change: the number of `->lookup` calls into the filesystem == number of uncached components. |
| **A12** | depth 8, **warm dentry, cold inode** (dentry hashed, inode evicted) | large working sets under memory pressure; MinIO [G] | **GAP**, and hard — needs deliberate inode eviction without dentry eviction | Measure: `->lookup` vs `iget` counts. This case exists to prove the two caches are separable; if it cannot be constructed, say so and drop it rather than faking it. |

## 2.3 Block R — RCU-walk eligibility (4 cases)

The dimension that decides whether the walk takes **any** atomics at all. This
is the single most important cache-state distinction for a reference-ownership
change and the rig tests exactly one point of it.

| ID | what it exercises | stands for | covered? | invariant |
|---|---|---|---|---|
| **R1** | full RCU walk, no `d_revalidate`, ext4 warm (== A2) | everything on a local disk filesystem | covered (implicitly, by every kbench script) | Measure: `lock`-prefixed instructions per open. In a clean RCU walk this should be a small constant — the terminal `legitimize_path` (`fs/namei.c:881`) plus the open's own — **not** proportional to depth. Verify against A1–A4: if the lock count grows with depth, RCU-walk is not being entered. |
| **R2** | overlayfs: lookup that misses upper and hits lower | **every containerised server workload** [G] | **GAP** — `OVERLAY_FS` is in the kernel config (`scripts/kconfig.sh:29` [V]) and no script mounts one | Measure: `->lookup` calls per component (expect ≥ 2 per component that misses upper); `insn:k`/open vs A2. Must not change: correct result; references balanced across the stack. |
| **R3** | FUSE with `entry_timeout=0`, forcing `d_revalidate` to return 0 every time | FUSE mounts, sshfs, s3fs, and by analogy NFS/CIFS [G] | **GAP** — `FUSE_FS` is in the config [V], unused | Measure: `try_to_unlazy_next` (`fs/namei.c:976`) / `unlazy` rate; `lock`-prefixed count per open. **This is the case where the atomic count per open is highest**, so it is where a reference-ownership change has the most to gain and the most to break. Must not change: no reference leak after the revalidate failure path (`fs/namei.c:1871`). |
| **R4** | `openat2` with `RESOLVE_CACHED` on a cold path — must fail with `EAGAIN` rather than block | io_uring fast-path opens; `batch-open-bench.sh` names this mechanism in its header but does not exercise it | **GAP** | Measure: return value, and that **zero** blocking work happened. Must not change: `LOOKUP_CACHED` is cleared on leaving RCU (`complete_walk`, `fs/namei.c:1063`) and the `try_to_unlazy` guard at `fs/namei.c:941` refuses rather than proceeding. This is a *correctness* case whose failure mode is a latency bug, not a wrong answer. |

## 2.4 Block C — Sharing (6 cases)

`O_RDONLY`, depth 8, ext4, warm, 4 KiB. N = `nproc` in the guest, swept
1/2/4/8/N as `sweep-bench.sh` already does — **the figure of merit is the
slope, not any single point** (`sweep-bench.sh` header says so, and the README's
+3.6/+20.1/+80.0/+76.9% table is the shape a contention fix has).

| ID | what it exercises | stands for | covered? | invariant |
|---|---|---|---|---|
| **C1** | 1 process (reference) | any single-threaded tool | covered — `insn-per-open.sh` | `insn:k`/open. The uncontended cost. |
| **C2** | N processes, **distinct inodes, distinct parents** | independent services on one host [G] | covered — `multifile-bench.sh` mode 0 (64 files, though all in one directory) | Throughput should scale near-linearly on real hardware. **In the guest it does not, and that is a documented artefact** — so read `insn:k`/open, not `ops/s`. |
| **C3** | N processes, **distinct inodes, ONE shared parent directory** | ripgrep's workers in one directory [R/G], MinIO listing + request path on one prefix [G], Kafka partition dir [G] | **GAP** — `multifile-bench.sh` happens to use one directory but never contrasts it against distinct parents, so the parent-dentry effect is invisible | Measure: `lock`-prefixed count/open, and the **slope** vs C2. A gap that widens with N is contention on the parent dentry's cacheline; a flat offset is not. |
| **C4** | N processes, **ONE shared inode** | nginx workers on one hot static file [G] — the one place a kbench headline maps 1:1 onto reality | covered — `sweep-bench.sh`, `tree-bench.sh` shared-inode section, `multifile-bench.sh` mode 1 | Slope vs C1. Must not change: `dentry-state` returns to baseline after `drop_caches` (both scripts already assert this). |
| **C5** | **N threads in ONE process**, one shared inode, one fd table | ripgrep [R/G], Kafka broker threads [G], MinIO goroutines on OS threads [G], any JVM or Go server | **GAP**, and explicitly so: `sweep-bench.sh`'s header says it uses processes *because* threads move the contention to `files->file_lock` in `alloc_fd()`. That is a reason to measure it separately, not a reason to never measure it. | Measure: `lock`-prefixed count/open, and where the misses land (`kbench-profile cache`). Must not change: the dentry-side counters must match C4 at the same N — if they do not, the fd-table contention is masking the dentry contention and C4's numbers are optimistic. |
| **C6** | N processes, **ONE shared inode, `stat` only** (no `struct file` allocated) | MinIO `HeadObject` storms [G], monitoring polling one path [G] | **GAP** | Measure: slope vs C4. **This isolates the dentry/inode contention from the `struct file` allocation and fd-table cost**, which C4 conflates. If C6's slope matches C4's, the contention is in the walk; if it is flatter, it is in the open. Nothing in the rig can currently tell these apart. |

## 2.5 Block F — Flags (11 cases)

Depth 8, ext4, warm, single process. Flags act on or after the final component,
so depth is held fixed (see the redundancy table).

| ID | flag set | stands for | covered? | invariant |
|---|---|---|---|---|
| **F1** | `O_RDONLY` (reference == A2) | everything read-only | covered | `insn:k`/open baseline |
| **F2** | `O_WRONLY\|O_CREAT` on an **existing** file | log reopen, Kafka segment reopen [G] | **GAP** | Must take the "found, no create" branch of `lookup_open` (`fs/namei.c` region around `:4493`); `audit_inode(…, AUDIT_INODE_PARENT)` fires once. `insn:k` above F1 by the `may_create`/write-access work only. |
| **F3** | `O_WRONLY\|O_CREAT\|O_EXCL` **creating** | PostgreSQL temp files [G], browser cache writes [G], `kbench-run.sh` fs-ops mode 2 does create+unlink | partial — fs-ops mode 2 covers create+unlink at depth 2 | Measure: `insn:k`/create; dentry count delta. Must not change: parent `i_rwsem` taken exactly once; negative dentry instantiated, not duplicated. |
| **F4** | `O_WRONLY\|O_TRUNC` | log truncation, rebuild-in-place [G] | **GAP** | `notify_change`/`->setattr` called exactly once; page cache for the inode invalidated. `insn:k` above F2 by the truncate only. |
| **F5** | `O_PATH` | the handle mechanism S3/S4 would need; container runtimes' `/proc/self/fd` re-open idiom [G] | **GAP** | Measure: `insn:k`/open vs F1. Must be **substantially cheaper**: `path_openat` short-circuits to `do_o_path` (`fs/namei.c:4992-4993`), `acc_mode` is 0 (`fs/open.c:1277-1281`), no `LOOKUP_OPEN` intent (`:1319`), and `do_dentry_open` returns before `->open` and before `security_file_open` (`fs/open.c:947-951`) [V]. Must not change: `security_file_open` hit count **stays zero** for this case. |
| **F6** | `O_NOFOLLOW` on a symlink → `ELOOP` | GNU grep's per-entry open [V — traced returning `ELOOP`], every security-conscious walker | **GAP** | Must return `ELOOP`, allocate no `struct file`, and leave the dentry count stable across repeats. |
| **F7** | `O_TMPFILE` | modern temp-file creation; PostgreSQL-class spill files if adopted [G] | **GAP** | `path_openat` takes the `__O_TMPFILE` branch (`fs/namei.c:4990`) and `do_tmpfile` audits at `fs/namei.c:4960` [V]. Must not change: the file has no name; linking it later via `linkat`/`AT_EMPTY_PATH` works. |
| **F8** | `O_DIRECT`, open + one aligned 4 KiB read | **MySQL/InnoDB `innodb_flush_method=O_DIRECT`** [G], MinIO large objects [G] | **GAP** | Measure: `insn:k`/op, and that the page cache is **not** populated for the inode. The open path is unchanged by `O_DIRECT`; this case exists to prove that, i.e. `insn:k` for the *open* must equal F1. |
| **F9** | `openat2` + `RESOLVE_NO_SYMLINKS` | container runtimes resolving inside an untrusted rootfs [G] | **GAP** | `LOOKUP_NO_SYMLINKS` set at `fs/open.c:1340-1341`, enforced in `pick_link` at `fs/namei.c:2040` [V]. Must return `ELOOP` on A5's path and succeed on A2's, with `insn:k` equal to F1 in the success case. |
| **F10** | `openat2` + `RESOLVE_BENEATH` | same | **GAP** | `LOOKUP_BENEATH` at `fs/open.c:1342-1343`, enforced at `fs/namei.c:1134`, `:2189`, `:2222` [V]. Must reject A8's `..` path and accept A2's. |
| **F11** | `openat2` + `RESOLVE_CACHED`, **warm** (must succeed) | io_uring open fast path [G] | **GAP** — pairs with R4, which is the cold/must-fail half | Must succeed with `insn:k` ≈ F1. `LOOKUP_CACHED` + non-`LOOKUP_RCU` must be rejected up front (`path_init`, `fs/namei.c:2683`) [V]. |

## 2.6 Block D — Directory size (4 cases)

Two ops per case: **(a)** `openat(dirfd, name)` for one named entry, **(b)** a
full `getdents64` drain. Counted as one case each because they share the fixture.

| ID | entries | stands for | covered? | invariant |
|---|---|---|---|---|
| **D1** | 10 | MinIO object directories (1–3 entries) [G], most source directories [V] | covered-ish — `kbench-run.sh` fs-ops uses 64 | (a) `insn:k`/lookup — the reference. (b) one or two `getdents64` calls total. |
| **D2** | 1 000 | systemd unit dirs [G], PostgreSQL `base/<db>` [G], font dirs [G] | **GAP** | (a) must be **O(1)** vs D1 — ext4 htree and the dcache hash are both hash lookups. A rise proves a linear scan somewhere. (b) `getdents64` call count scales with buffer size, not entry count × anything. |
| **D3** | 100 000 | browser cache dirs [G], large MinIO prefixes [G], Maildir [G] | **GAP** | (a) still O(1). (b) `insn:k` per entry returned must be flat — this is where `filldir64` (`fs/readdir.c:341`) and the ext4 htree readdir cursor are actually stressed. |
| **D4** | 1 000 000 | pathological but real (MinIO, mail spools) [G] | **GAP**, and expensive to build — tier 2 | (a) still O(1). (b) flat per-entry cost, and **memory does not grow without bound** during the drain. If D4 cannot be built inside the guest's 8 GB, record that and stop at D3 rather than reporting a smaller directory as if it were this one. |

## 2.7 Block Z — File size (6 cases)

`open` + read-to-EOF, single process, ext4, warm, depth 8. This block exists for
the `address_space` half of the patch series and for nothing else.

| ID | size | stands for | covered? | invariant |
|---|---|---|---|---|
| **Z1** | 0 | empty marker/lock files [G]; the pure-metadata case | **GAP** | `insn:k`/op must equal F1's open cost plus one `read` returning 0. Isolates metadata from data completely. |
| **Z2** | 4 KiB | PostgreSQL block [G], most config and source files [V] | covered — `tree-bench.sh` builds `small0` at 4096 | `insn:k`/op; one page fault or one `copy_to_user` |
| **Z3** | 64 KiB | browser cache entries [G]; GNU grep's read buffer is 98304 bytes [V], so this is under one buffer | **GAP** — `tree-bench.sh` has 16 KiB, then jumps to 1 MiB | `insn:k` per KiB must be flat from here up |
| **Z4** | 1 MiB | Kafka index files [G], media assets [G] | covered — `tree-bench.sh` builds `large` at 1048576 | flat `insn:k`/KiB |
| **Z5** | 64 MiB | large objects [G] | **GAP** | flat `insn:k`/KiB; readahead behaviour stable |
| **Z6** | 1 GiB | **PostgreSQL segment cap, Kafka default segment size** [G] | **GAP** | flat `insn:k`/KiB. Must not change: memory does not grow with file size in a streaming read. One-off; 8 GB guest. |

## 2.8 Block M — Filesystem (6 cases)

One op for all of them: `open` + `fstat(fd)` at depth 8, warm, single process —
chosen because it exposes `->lookup`, `d_revalidate` and stacking at once.

| ID | filesystem | stands for | covered? | invariant |
|---|---|---|---|---|
| **M1** | **ext4** (reference) | PostgreSQL, MySQL, Kafka, most servers [G] | covered — **every kbench script; the guest root is `/dev/vda / ext4 defaults,noatime`** (`scripts/mkrootfs.sh:48` [V]) | reference `insn:k`/open |
| **M2** | **tmpfs** | `/tmp`, `/run`, `/dev/shm`; container scratch [G] | **GAP as a *declared* case** — `TMPFS` is enabled (`scripts/kconfig.sh:26` [V]) and the benchmarks all write to `/tmp` **without recording what `/tmp` actually is**. That is worse than not testing it. | `insn:k`/open should be **below** ext4 (no block layer, simpler `->lookup`). If it is not, something is wrong with the measurement, not with tmpfs. |
| **M3** | **overlayfs**, hit in **upper** | container writes [G] | **GAP** — `OVERLAY_FS` enabled (`scripts/kconfig.sh:29` [V]), unused | `insn:k`/open vs M1; references balanced across both layers |
| **M4** | **overlayfs**, miss upper, hit **lower** | container reads — **the common case in every container** [G] | **GAP** | `->lookup` count ≥ 2 per component; the M3→M4 gap is the stacking cost. Must not change: correct result, no leaked references in either layer. |
| **M5** | **FUSE** (`entry_timeout=0`) | sshfs, s3fs, gvfs, `/proc`-like user filesystems [G] | **GAP** — `FUSE_FS` enabled (`scripts/kconfig.sh:23` [V]), unused | The `d_revalidate`-forced-out-of-RCU case; see R3. Highest atomic count per open of any case in the matrix. |
| **M6** | **virtiofs** | the rig's own `/mnt/results` is 9p, not virtiofs (`scripts/run-vm.sh:116`, `-virtfs local,…` [V]) | **GAP** | Included because `VIRTIO_FS` is enabled [V] and it is the cheapest available stand-in for a remote filesystem's revalidation behaviour. |
| — | **btrfs, xfs, NFS, CIFS** | PostgreSQL on xfs [G], enterprise NFS home dirs [G] | **NOT IN THE KERNEL CONFIG.** `scripts/kconfig.sh` enables `EXT4_FS`, `TMPFS`, `OVERLAY_FS`, `FUSE_FS`, `VIRTIO_FS`, `9P_FS` and no other filesystems [V]. Covering any of these requires a config change and, for NFS/CIFS, a server. **Declared out of the covering set, not silently omitted.** | — |

## 2.9 Block O — Mount options (5 cases)

ext4, depth 8, warm, single process, `O_RDONLY` + one read.

| ID | mount option | stands for | covered? | invariant |
|---|---|---|---|---|
| **O1** | `relatime` (the kernel default) | **every real desktop and most servers** [G] | **GAP — and this is a hole in every kbench number to date.** The guest root is mounted `noatime` (`scripts/mkrootfs.sh:48` [V]), so no kbench measurement has ever included an atime update. | Measure: inode dirty count, and `insn:k` per read. `atime_needs_update` (`fs/inode.c:2267`) → `relatime_need_update` (called at `:2293`) → `touch_atime` (`fs/inode.c:2303`) [V]. **This writes to the inode on a read**, which is exactly the read-hot/write-hot cacheline mixing the layout series is about. |
| **O2** | `noatime` | the rig today; tuned database and Kafka hosts [G] | covered by default, but **undeclared** | `touch_atime` must not fire: `MNT_NOATIME` is checked at `fs/inode.c:2286` [V]. The O1→O2 delta is the atime cost, and it must be zero here. |
| **O3** | `ro` | container image layers, read-only rootfs, `/usr` on immutable systems [G] | **GAP** | Write opens must fail with `EROFS` at `may_open` (`fs/namei.c:4231`) before any `struct file` work. Read opens must cost the same as O2. |
| **O4** | `nosuid,noexec` | `/tmp`, `/var/tmp`, container mounts [G] | **GAP** | Changes the permission computation, not the walk. `insn:k` for a read open must equal O2; an exec must fail. |
| **O5** | **idmapped mount** | rootless containers, user namespaces [G] | **GAP** | Every permission check goes through `mnt_idmap` — `inode_permission(idmap, …)` (`fs/namei.c:628`), `generic_permission(idmap, …)` (`:521`), `may_open(idmap, …)` (`:4231`) [V]. Measure `insn:k` delta vs O2: the mapping is a per-check translation, so the cost should scale with component count. Must not change: the resolved identity. |

## 2.10 Block U — Mutating operations (4 cases)

These touch the dentry lifecycle rather than the lookup, and a
reference-ownership change is at least as likely to break them as to help them.

| ID | operation | stands for | covered? | invariant |
|---|---|---|---|---|
| **U1** | `create` + `unlink`, no open fd held | PostgreSQL temp files [G], browser cache churn [G] | covered — `kbench-run.sh` fs-ops mode 2 (depth 2, 64-entry dir) | dentry count returns to baseline; `insn:k`/pair |
| **U2** | `unlink` of a file with an **open fd held** | log rotation [G], Kafka retention delete while a consumer reads [G], every "delete the temp file then keep writing" idiom [G] | **GAP** | The inode must survive until the last `fput`; the dentry must be unhashed but not freed. Measure: `dentry-state` and `inode-nr` before/after, and after `close`. Must not change: no use-after-free, no early free — this is the case a reference-ownership change breaks first. |
| **U3** | `rename` within one directory | atomic config replace (`write tmp; rename`) [G], log rotation [G] | **GAP** | One parent `i_rwsem`; `d_move` leaves both dentries consistent. Measure `insn:k`/rename. |
| **U4** | `rename` **across** directories | Kafka segment `.log`→`.log.deleted` [G], maildir `new`→`cur` [G], atomic publish idioms [G] | **GAP** | Two parents locked in the correct order (`lock_rename`); no deadlock; references balanced. This is the highest-risk uncovered correctness case in the matrix. |

## 2.11 Covering set — the count

| block | cases |
|---|---|
| S — sequences | 8 |
| A — path shape × cache | 12 |
| R — RCU-walk eligibility | 4 |
| C — sharing | 6 |
| F — flags | 11 |
| D — directory size | 4 |
| Z — file size | 6 |
| M — filesystem | 6 |
| O — mount options | 5 |
| U — mutating operations | 4 |
| **total** | **66** |

Of those 66: **7 are covered today** by an existing kbench script (S5, C1, C2,
C4, M1, Z2, Z4), **4 more are partially covered** at the wrong depth, directory
size, or without the contrast that would make them readable (A1, A2, F3, U1,
D1), and **the rest are gaps**. Four further filesystems (btrfs, xfs, NFS,
CIFS) are declared out of scope with a stated reason rather than counted.

---

# PART 3 — What to measure, per row class

The rig's own calibration decides this, not preference. From
`/usr/src/kbench/README.md`, read here:

- the control `getppid()` loop **moved 69% between two runs fifteen minutes
  apart** — so any wall-clock comparison across that boundary is void;
- `noisefloor` measured 17% on same-core sched pipe and 26% cross-core between
  two runs of the **same kernel**;
- `insn:k/open` repeats to **0.03% within a boot** and about **1.1% between
  boots** (the between-boot figure is dentry-hash-chain state, which is why
  `insn-per-open.sh` drops caches and warms one path first);
- the `dopen` result that the sweep established (+20.1% at 4 procs, +80.0% at 8,
  +76.9% at 16, control-normalised, six blocks) was only readable because the
  effect **grew with process count**. A flat effect of that size would have been
  indistinguishable from drift.

So: **wall clock is admissible only for slope, only control-normalised, and only
above roughly 15–25%.** Everything else is a counter.

## 3.1 The five signals and what each is for

| signal | what it is immune to | what it cannot see | how to get it here |
|---|---|---|---|
| **syscall count** | everything — it is a property of the program, not the machine | anything inside one syscall | `strace -c -f`, or the in-guest equivalent; also `ftrace` syscall events |
| **instructions per operation** (`insn:k`) | host contention, frequency scaling, nested-virt exit cost | cache effects, contention — it counts work, not stalls | `perf stat -e instructions:k` inside the guest; `insn-per-open.sh` is the pattern |
| **lock-prefixed instruction count** per op | same as above; it is a static/dynamic count | which cacheline, and whether it contended | statically from `tools/static-graph.py` (it records lock-prefixed instructions by mnemonic per function); dynamically via `perf probe` on the lockref entry points, as `scripts/count-atomics.sh` does |
| **control-normalised wall clock** (`norm=`) | slow host drift, if the drift is slower than the alternation | anything under ~15%; and it is void if the control itself moved | `tree-bench.sh` / `sweep-bench.sh` `norm=` column; `scripts/estimate.py` for the interval |
| **dentry/inode cache hit ratio** | nothing in particular; it is a state measure, not a performance one | cost | `/proc/sys/fs/dentry-state`, `/proc/slabinfo`, and `ftrace function_profile` hit counts on `__d_lookup_rcu` vs `__lookup_slow` |

One addition the rig already has and this matrix leans on hard:
**`function_profile` hit counts are reliable in the guest; the nanosecond column
is not** (kbench README, and `path_openat` reading 8.5 ns/call is how that was
noticed). Every "must not change" invariant in Part 2 that says "hook count" or
"`->lookup` count" is a hit count, and that is deliberate — it is the one
mechanism-level measurement this hardware can make honestly.

## 3.2 Primary signal per row class

| row class | primary signal | why, and where wall clock fails |
|---|---|---|
| **S1–S4, S6a/S6b/S7 (sequences)** | **syscall count first, then `insn:k`/op** | The whole claim is "one resolution instead of two". That is a *count*: `filename_lookup` hit count per operation, 1 vs 2. It cannot be faked by noise and it cannot be argued with. `insn:k` then prices the redundant walk. **Wall clock cannot resolve this at all** for a single file — one warm path walk is on the order of a microsecond [R, `01-fstat-after-open.md` says so explicitly and tells contributors not to claim throughput], which is far under the rig's floor. The uutils document's own gate is `strace -c`, for exactly this reason. |
| **A1–A4 (depth sweep)** | **`insn:k`/open, read as a slope** | The per-component cost is a few hundred instructions against ~6100 for a warm open (kbench's measured baseline figure). A one-component change is ~2%; the between-boot `insn:k` threshold is 1.1%. It is readable, but only as the slope across four depths, not as a single point. Wall clock: hopeless. |
| **A5–A8 (symlinks, mounts, `..`)** | **`insn:k`/open + hook hit counts** | These change *what happens*, not just how much. The hit count on `pick_link`, `audit_inode` and the mount-crossing path is the mechanism proof; `insn:k` is the price. |
| **A9, A10 (ENOENT)** | **`insn:k`/failed-op + dentry-state** | A negative dentry costs almost nothing to hit and something to create. The interesting invariant is that the count stabilises — a leak here is a slow memory exhaustion, not a slowdown, and only the state measure sees it. |
| **A11, A12 (cold)** | **`insn:k` and `->lookup` call count, single-shot** | Cold means I/O, and I/O in this guest is virtio to a WSL2 file. Wall clock measures the host's page cache. **Never quote a cold wall-clock number from this rig.** The counters still work because they are per-operation counts of kernel work. |
| **R1–R4 (RCU-walk)** | **lock-prefixed instruction count per op** | This is the definitional measure: an RCU walk takes almost no atomics, a ref-walk takes a pair per component. The whole `dopen` thesis — four atomic RMWs on the dentry cacheline per open/close, two of them a pure round trip — is a statement about this counter. `scripts/count-atomics.sh` already exists to measure it and says so in its header: "it either drops from 4 to 2 or it does not." |
| **C1–C6 (sharing)** | **control-normalised wall clock, read as a SLOPE, plus lock count/op** | This is the *one* class where wall clock earns its place, because contention produces effects far above the noise floor and because the signature is a widening gap, not an offset. `sweep-compare.py` and `estimate.py` exist for this. But the absolute throughput is worthless: the guest does not scale at all on a workload that scales 5× on the host, and that is a documented nested-virtualisation artefact. **Read `norm=` and read the slope.** |
| **F1–F11 (flags)** | **hook hit counts first, `insn:k` second** | Most flag cases are *behavioural*: does `security_file_open` fire for `O_PATH` (it must not), does `pick_link` fire under `RESOLVE_NO_SYMLINKS` (it must not), does `EROFS` come from `may_open` before any file allocation. These are pass/fail, measured by hit count and errno. `insn:k` is secondary and confirms magnitude. |
| **D1–D4 (directory size)** | **`insn:k` per entry, and its flatness** | The claim being tested is O(1) lookup and O(1)-per-entry readdir. Flatness across four orders of magnitude is visible in a counter and invisible in wall clock, where the 10⁶ case is dominated by I/O and memory pressure. |
| **Z1–Z6 (file size)** | **`insn:k` per KiB, and its flatness** | Same argument. The page-cache read path is the one place where large wall-clock differences *are* real, but they are dominated by readahead and the host's cache, not by the kernel under test. |
| **M1–M6 (filesystem)** | **`insn:k`/open and `->lookup` hit count** | Filesystems differ by hundreds to thousands of instructions per open (overlayfs stacking, FUSE's round trip to a user process). That is well above the counter threshold. FUSE's wall clock is dominated by the userspace daemon and says nothing about the VFS. |
| **O1–O5 (mount options)** | **hit counts (`touch_atime`, `may_open` errno) + `insn:k`** | The atime case is the important one and it is a *write* that either happens or does not. Count it; do not time it. |
| **U1–U4 (mutating)** | **correctness assertions first, `insn:k` second** | `dentry-state` and `inode-nr` before/during/after, plus `dmesg` for `refcount_t`, `use-after-free`, `slab corruption`, `WARNING: CPU.*at (fs|lib)/` — the grep `sweep-bench.sh` and `multifile-bench.sh` already run. For U2 and U4 the *result* is the measurement; performance is a footnote. |

## 3.3 Stated plainly: where wall clock cannot resolve the effect

- **Every sequence case (S1–S7).** One redundant path walk is ~1 µs warm. The
  rig's floor is 10–15% of a multi-second run. Use `filename_lookup` hit count
  and `insn:k`. The sibling uutils document reaches the same conclusion from the
  userspace side and instructs contributors not to claim throughput [R].
- **The `lockref` class of change.** kbench measured it: six ALU ops saved per
  cmpxchg iteration, two to four lockref operations per open, so 8–16
  instructions out of ~6100 — about 0.2%, against a 1.11% between-boot `insn:k`
  threshold. **Below the counter floor, let alone the clock floor.** The honest
  measurement for that class is the disassembly, not the machine.
- **Any single-point contention number.** The `dopen` +185% that was reported
  once and retracted was the control falling with the workload. Only the slope
  across a sweep, control-normalised, over multiple blocks, means anything.
- **Cold-cache anything.** The guest's "disk" is a file on WSL2. Cold wall clock
  measures the host.
- **Cache-line placement (the layout series).** Its own stated gate is HITM
  reduction under `perf c2c`, and WSL2 exposes no AMD IBS, so neither host nor
  guest can produce HITM data. `pahole` proves the layout; nothing available here
  proves the effect. The matrix cannot fix that and should not pretend to.

---

# PART 4 — Gaps, prioritised

Ordered by: (a) how much real software depends on it, × (b) whether the rig
covers it, × (c) whether a reference-ownership or cache-layout change to the VFS
could plausibly break or improve it.

Each sketch says what to create, what to run, and what to assert. All of them
are in-guest scripts in the shape of the existing `scripts/guest/*.sh` — same
header block (kernel, harness hash, selinux state, date), same `KBENCH_OUT`,
same correctness tail. Note `mkrootfs.sh` installs **every** `scripts/guest/*.sh`
rather than a list of names, so a new script needs no registration.

---

### G1 — The sequence harness (S1, S2, S3, S4). **Highest priority.**

*Depends on it:* `ld.so` on every process start [V], `grep -r` [V], `ls -l` [V],
MySQL under table-cache pressure [G], nginx without `open_file_cache` [G], every
build system [G]. *Rig coverage:* none. *Why a VFS change touches it:* it is the
premise of the whole project — the second resolution is the thing being
questioned.

**Create:** a depth-8 tree, one 4 KiB target file, warm.
**Run:** one binary, four modes back-to-back in one process so the gaps are
paired by construction (the `batch-open-bench.sh` design, which exists precisely
to make gaps paired):
1. `open(path)` + `fstat(fd)` + `close`
2. `open(path)` + `stat(path)` + `close`
3. `stat(path)` + `open(path)` + `close`
4. `statx(path)` × 2 on the same path

with `ftrace function_profile` armed on `filename_lookup`, `link_path_walk`,
`inode_permission`, `security_inode_permission`, `audit_inode`, `path_get`,
`dput`, around each mode.
**Assert:**
- mode 1: `filename_lookup` hits == iterations. Modes 2, 3, 4: == 2 × iterations.
  *If mode 1 is not exactly half, the model in Part 1.5 is wrong and the rest of
  this document needs revisiting.*
- `insn:k`/op for mode 2 minus mode 1 == **the cost of one redundant warm walk at
  depth 8**. That single number is the most useful thing this matrix can produce,
  and nothing in the rig currently produces it.
- modes 2 and 3 must agree within the within-boot `insn:k` spread (0.03%). A
  difference means ordering matters and something is being cached that is not
  accounted for.
- `dentry-state` returns to baseline after `drop_caches`.

---

### G2 — Contention attribution: stat-only sweep (C6) and thread sweep (C5).

*Depends on it:* nginx worker storms on a hot file [G] — the one workload that
maps 1:1 onto the rig's headline benchmark; MinIO `HeadObject` [G]; ripgrep and
every threaded server [R/G]. *Rig coverage:* `sweep-bench.sh` covers processes on
one inode with `open`, and nothing else. *Why:* the `dopen` result (+80% at 8
processes, control-normalised) is currently **unattributed** — it could be the
dentry reference round trip, or the `struct file` allocation, or the fd-table
insert, and the existing benchmark conflates all three.

**Create:** one file, as `sweep-bench.sh` does.
**Run:** the same 1/2/4/8/N sweep with the same per-run `getppid()` control, in
three variants:
- (a) `open`+`close`, separate processes — the existing case, as the anchor;
- (b) `stat(path)` only, separate processes — no `struct file`, no fd table;
- (c) `open`+`close`, N **threads in one process**.
**Assert:**
- (b)'s slope vs (a)'s: if they match, the contention is in the **walk**; if (b)
  is flatter, it is in the **open**. This is the experiment that tells the
  `dopen` patch what it actually fixed.
- (c) vs (a): the difference is `files->file_lock` in `alloc_fd()`, which
  `sweep-bench.sh`'s header already names as the reason it avoids threads.
  Measure it once instead of avoiding it forever.
- lock-prefixed instruction count per op for all three, via `count-atomics.sh`'s
  `perf probe` method.
- all three: `dentry-state` back to baseline after `drop_caches`; `dmesg` clean.

---

### G3 — `relatime` vs `noatime` (O1 vs O2). **Cheap, and it invalidates an assumption.**

*Depends on it:* every desktop and most servers run `relatime`, which is the
kernel default [G]. *Rig coverage:* **none, and worse than none** — the guest
root is `noatime` (`scripts/mkrootfs.sh:48` [V]), so every number kbench has
produced is from a configuration real systems mostly do not use. *Why:*
`touch_atime` **writes to the inode on a read**. The layout series is explicitly
about not mixing read-hot and write-hot fields on one cacheline. The rig has
been measuring the read path with the write removed.

**Create:** two ext4 mounts of the same image content, one `relatime`, one
`noatime` — or remount between phases and record which is active in the report
header.
**Run:** `open`+`read`+`close` on a file whose atime is older than a day (so
`relatime_need_update` returns true on the first touch) and on one just touched
(so it returns false); single process and then the C4 sweep.
**Assert:**
- `touch_atime` (`fs/inode.c:2303`) hit count: zero under `noatime`
  (`MNT_NOATIME` checked at `fs/inode.c:2286` [V]), nonzero under `relatime` in
  the stale-atime case, zero in the fresh case.
- `insn:k`/op delta between the two mounts.
- Under the shared-inode sweep: does the `relatime` inode write change the
  **slope**? If it does, every contention number in the rig's history is
  conditioned on `noatime` and should say so.

---

### G4 — overlayfs (M3, M4, and R2).

*Depends on it:* essentially every container, which is essentially every modern
server deployment [G]. *Rig coverage:* none, despite `OVERLAY_FS` being enabled
in the kernel config [V]. *Why:* overlayfs multiplies **every lookup** by the
layer count on an upper miss, and implements `d_revalidate` on stacked entries —
both of which multiply whatever a reference-ownership change does to a lookup.

**Create:** a lower dir with a depth-8 tree, an empty upper, a merged mount; then
a second fixture where the target has been copied up.
**Run:** `open`+`fstat` at depth 8 on (a) upper hit, (b) lower hit through 1
lower layer, (c) lower hit through 4 lower layers.
**Assert:**
- `->lookup` hit count scales with layer count on a miss and does not on a hit.
- `insn:k`/open for (c) minus (a) is the stacking cost; it must be roughly linear
  in layer count.
- references balanced: `dentry-state` and `inode-nr` return to baseline in both
  layers after `drop_caches`.
- `dmesg` clean — overlayfs is where a reference-ownership bug in the VFS shows
  up as a stacked-filesystem crash rather than a leak.

---

### G5 — FUSE with `entry_timeout=0`: the forced-out-of-RCU case (R3, M5).

*Depends on it:* sshfs, s3fs, gvfs on desktops, and by analogy NFS and CIFS,
which are not in the config [G]. *Rig coverage:* none, despite `FUSE_FS` being
enabled [V]. *Why:* **this is the case with the highest atomic count per open in
the whole matrix.** `d_revalidate` returning 0 forces `try_to_unlazy_next`
(`fs/namei.c:976`) and drops the walk to ref-walk, which takes a reference pair
per component instead of none. A reference-ownership change has its largest
effect and its largest blast radius here.

**Create:** a trivial passthrough FUSE filesystem (a `libfuse` example is
sufficient) mounted with `entry_timeout=0,attr_timeout=0`, containing a depth-8
tree.
**Run:** `open`+`fstat` at depth 8, single process, then the C4 sweep.
**Assert:**
- lock-prefixed instruction count per open is **much** higher than M1's and
  scales with depth (under ext4 it must not).
- `try_to_unlazy`/`try_to_unlazy_next` hit counts are nonzero and equal to the
  component count.
- no reference leak after the revalidate-failure path (`fs/namei.c:1871`):
  `dentry-state` back to baseline after unmount.
- `dmesg` clean.

---

### G6 — `readdir` → stat vs `readdir` → `d_type`, at directory scale (S6a/S6b/S7 × D2/D3).

*Depends on it:* `find` [V], `ls -l` [V], `du`, `rm -r`, MinIO listing [G],
every backup walker [G], the entire Rust and C walker ecosystem [R]. *Rig
coverage:* `kbench-run.sh` fs-ops mode 1 does `readdir` over a **64-entry**
directory and then nothing with the entries. *Why:* it is the largest syscall
multiplier in this document, and directory size is the one dimension that reaches
10⁶.

**Create:** directories of 10, 1 000, 100 000 entries (and 1 000 000 if the guest
can build it — if it cannot, record that and stop at 100 000).
**Run:** per directory, three drains: (a) `getdents64` + `stat("dir/name")` per
entry; (b) `getdents64` + `fstatat(dirfd, name)` per entry; (c) `getdents64` and
read `d_type` only.
**Assert:**
- (c): **zero** stat-family syscalls, zero `filename_lookup`, zero permission
  hooks. If nonzero, `d_type` came back `DT_UNKNOWN` and the case is invalid —
  fail loudly rather than reporting (c) as if it had worked.
- (a) − (b) per entry == the prefix-walk cost at that depth. Compare against the
  same gap measured by `batch-open-bench.sh` for `open` (its 1→2 gap); they are
  the same mechanism and should agree.
- `insn:k` per entry must be flat across 10 → 1 000 → 100 000. A rise is a linear
  scan.
- `openat(dirfd, oneName)` in a 100 000-entry directory must cost the same as in
  a 10-entry one.

---

### G7 — Dentry lifecycle under a held reference: `unlink` with an open fd (U2), cross-directory `rename` (U4).

*Depends on it:* log rotation [G], Kafka retention deletes [G], maildir delivery
[G], the "unlink the temp file and keep writing" idiom [G]. *Rig coverage:*
`kbench-run.sh` fs-ops mode 2 does create+unlink with **no fd held** — the easy
case. *Why:* **this is the first thing a reference-ownership change breaks.** The
`dopen` patch hands the walk's dentry reference to the `struct file`; U2 is
precisely the case where the file outlives the name.

**Create:** a directory with files; a second directory for the cross-dir rename.
**Run:**
- U2: open, unlink while the fd is open, read through the fd, close, repeat.
- U4: create, `rename` to a different directory, `stat` the new name, unlink.
Both single-process and then N-process concurrently on the same parent.
**Assert:**
- U2: the read after unlink succeeds and returns the right bytes. `inode-nr` does
  not drop until after `close`. Dentry unhashed but not freed early.
- U4: both parents' `i_rwsem` taken (hit count on `lock_rename`); no deadlock
  under the concurrent variant; the old name is gone and the new one resolves.
- Both: `dentry-state` and `inode-nr` return to baseline after `drop_caches`;
  `dmesg` grep for `refcount_t|use-after-free|slab corruption|BUG:|Oops|WARNING:
  CPU.*at (fs|lib)/` is empty. **For this gap the assertions are the result.**

---

### G8 — Negative dentries: ENOENT at the leaf and mid-path (A9, A10).

*Depends on it:* ripgrep's ignore-file probing [R/G], the freedesktop icon
fallback cascade [G], `ld.so` search-path probing when the cache misses [G],
config-file search lists [G]. *Rig coverage:* none — every kbench path resolves
successfully. *Why:* a negative dentry is a dentry; it is allocated, hashed,
reference-counted and reclaimed by the same machinery, and nothing in the rig has
ever exercised that half of it.

**Create:** a depth-8 tree; probe a name that does not exist at the leaf, and a
path whose 4th component does not exist.
**Run:** the failing open in a loop, single process, then N processes on the same
missing name (a shared **negative** dentry — the contention case nobody tests).
**Assert:** `ENOENT` every time; no `struct file` allocated; `insn:k` for A10 <
A9 by roughly four components' worth; `dentry-state` grows once and then is
stable across millions of iterations; back to baseline after `drop_caches`.

---

### G9 — Declare the filesystem under test. **Trivial, and it is a correctness bug in the rig.**

*Rig coverage:* every guest script builds its fixture under `/tmp` and **no
script records what `/tmp` resolved to.** `/etc/fstab` declares only
`/dev/vda / ext4 defaults,noatime` and the 9p results mount
(`scripts/mkrootfs.sh:48,50` [V]); whether systemd mounted a `tmpfs` over `/tmp`
in a given boot is not recorded anywhere in any report.

**Change:** every `scripts/guest/*.sh` header already prints kernel, harness
hash, selinux state and date. Add two lines: the output of
`findmnt -no FSTYPE,OPTIONS --target "$DIR"` for the fixture directory, and the
same for `$KBENCH_OUT`. **Assert:** a report that does not name the filesystem
and mount options its fixture lived on is not comparable against one that does —
which is the same argument the harness-hash line already makes in
`tree-bench.sh`'s header, applied to the other half of the environment.

---

### G10 — `O_PATH` and the handle forms (F5, and F9–F11).

*Depends on it:* container runtimes' `/proc/self/fd` re-open idiom [G]; and it
is the mechanism S3 and S4 would have to use if they were to be fixed in
userspace. *Rig coverage:* none. *Why:* `O_PATH` is the cheapest possible open —
`path_openat` short-circuits to `do_o_path` (`fs/namei.c:4992-4993`),
`do_dentry_open` returns before `->open` and before `security_file_open`
(`fs/open.c:947-951`) [V] — so it isolates "resolve a name and hold it" from
everything else the open path does. **It is the natural control for G1.**

**Create:** the G1 fixture.
**Run:** `open(O_PATH)`+`close`; then `open(O_PATH)` once + `statx(fd,"",
AT_EMPTY_PATH)` × N; then `openat2` with `RESOLVE_NO_SYMLINKS`,
`RESOLVE_BENEATH` and `RESOLVE_CACHED` (warm and cold).
**Assert:** `security_file_open` hit count **zero** for every `O_PATH` open;
`insn:k`/op well below F1's, and the difference is what the open machinery costs
on top of resolution; `RESOLVE_CACHED` succeeds warm and returns `EAGAIN` cold
without blocking; `RESOLVE_NO_SYMLINKS` returns `ELOOP` on A5's path;
`RESOLVE_BENEATH` rejects A8's `..` path.

---

### G11 — Deep paths and symlinks (A3–A6).

*Depends on it:* MinIO object keys [G], Nix/Guix store paths [G], container
layouts [G]. *Rig coverage:* `insn-per-open.sh` and `batch-open-bench.sh` fix
depth at 5; `tree-bench.sh` sweeps depth but over a tree whose shape changes with
it (its header records that the first attempt at this confounded depth with
working-set size, and was fixed by building a separate chain — the same
discipline applies here). No script resolves a symlink at all.
*Why:* per-component cost is the unit a walk change is measured in, and symlinks
add a nesting level with its own reference stack (`terminate_walk` drops
`nd->stack[i]` at `fs/namei.c:850` [V]).

**Create:** four chains of identical shape at depths 1, 8, 16, 32, each with the
same target file; plus depth-8 chains with 1 and 4 symlinked components.
**Run:** `open`+`close`, single process, counters armed.
**Assert:** `insn:k`/open linear in component count (fit it, report the slope and
the residual); symlink cases linear in link count on top; `nd->depth` returns to
0 (no leaked link references — `dentry-state` back to baseline).

---

### G12 — `sendfile` / `splice`. **A known omission from the covering set.**

Stated explicitly rather than quietly left out: the 66-case set contains no
`sendfile` row, because the project's changes are in reference ownership and
cache layout on the walk and open paths, and `sendfile` is a read-path
operation. But **Kafka's entire consumer path is `FileChannel.transferTo` and
nginx's entire static-serving path is `sendfile`** [G] — two of the nine
workloads in Part 1 — and it is the only case in this document where data moves
through `file->f_mapping` with no user buffer and no `read` syscall. Adding it
makes the covering set **67**.

**Create:** files at Z2/Z4/Z6 sizes; a socketpair or a `/dev/null` sink.
**Run:** `open`+`fstat`+`sendfile`-to-EOF+`close`, single process and N
processes on one shared inode (the nginx shape, C4 with `sendfile`).
**Assert:** `insn:k` per MiB transferred, flat across sizes; `file`/`inode`
references balanced; under the shared-inode sweep, the slope vs C4's `open` sweep
— if `sendfile` contends differently from `open` on the same inode, the
`address_space` half of the layout series has a case it does not currently have.

---

## Summary of priorities

| # | gap | why it is here | cost to build |
|---|---|---|---|
| G1 | sequence harness (S1–S4) | the project's premise, zero coverage | one script |
| G2 | contention attribution (C5, C6) | the one measured result is unattributed | one script, reuses `sweep-bench.sh` |
| G3 | `relatime` vs `noatime` | every existing number is `noatime` | one remount + one script |
| G4 | overlayfs | what servers actually run on; config already supports it | fixture + script |
| G5 | FUSE `entry_timeout=0` | highest atomic count per open in the matrix | needs a FUSE daemon in the rootfs |
| G6 | `readdir`→stat vs `d_type` at 10³–10⁶ entries | largest syscall multiplier; nothing above 64 entries exists | fixture build is the expensive part |
| G7 | unlink-with-open-fd, cross-dir rename | what a reference-ownership change breaks first | one script |
| G8 | negative dentries | the untested half of the dcache | one script |
| G9 | record the filesystem under test | a reporting bug in the existing rig | two lines per script |
| G10 | `O_PATH` and `openat2` resolve flags | the natural control for G1 | one script |
| G11 | depth 16/32 and symlinks | the unit a walk change is measured in | fixture + script |
| G12 | `sendfile` (declared omission → 67 cases) | Kafka and nginx; the only no-user-buffer read path | one script |

G1, G2, G3 and G9 are the four that cost least and change the most about what
the existing numbers mean.
