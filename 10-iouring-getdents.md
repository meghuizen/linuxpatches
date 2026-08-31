# Task 10 — Reference: `getdents` support for io_uring

**What this document is for, in one sentence:** point at existing out-of-tree
work that adds `getdents` to io_uring, because the kernel still has no way to
read directory entries asynchronously, and directory traversal is exactly the
workload that syscall overhead hurts most.

| | |
|---|---|
| Type | Reference — the work exists, it is just not upstream. Nothing to write from scratch |
| State in Linux 7.2 | **Absent** — io_uring has no `getdents` opcode |
| Reference implementation | <https://github.com/tdanecker/iouring-getdents> (2023) |
| Original upstream attempt | Stefan Roesch, Dec 2021 — [lore thread](https://lore.kernel.org/io-uring/20211221164004.119663-1-shr@fb.com/) |
| Why it stalled | Review objections from Al Viro, never resolved |
| Effort to revive | Weeks, and you must answer the original objections first |

---

## 1. Background: why this gap matters

io_uring exists to remove syscall overhead. You put requests in a ring buffer,
the kernel takes them out, and you get results back in a second ring. One
system call can carry hundreds of operations.

It covers a lot now: read, write, accept, connect, openat, statx, and more.
It does not cover `getdents`.

`getdents` is the syscall behind `readdir()`. You give it a directory file
descriptor and a buffer, and it fills the buffer with directory entries. It is
a cheap operation — often the data is already in the dentry cache — which is
exactly why the syscall overhead around it is a large share of the total cost.

That leaves a hole in every async runtime. Tokio, libuv, and the rest have
good io_uring paths for network and file I/O, but directory reads still go to
a blocking thread pool. So any program that walks a directory tree — a build
system, a backup tool, an indexer, `du` — pays full syscall cost per
directory and cannot overlap the walk with anything else.

## 2. What already exists

Two pieces of prior art, and you should read both before writing any code.

**Stefan Roesch's patches (December 2021).** Posted to the io-uring list, this
is the original attempt at an `IORING_OP_GETDENTS`. Read the whole thread,
including the replies — the objections are the important part, not the diff.

**Tobias Danecker's repository (2023).** <https://github.com/tdanecker/iouring-getdents>

It contains, as git submodules:

- a patched Linux kernel, based on Roesch's work plus the review feedback
- patches for the Rust `io-uring` crate (the raw binding layer)
- patches for `tokio-uring`, adding a `tokio_uring::fs::Dir` type
- a QEMU microvm test harness built from a Dockerfile, so you can boot the
  patched kernel without touching your machine

The Rust API it exposes looks like this:

```rust
use tokio_uring::fs::Dir;

let mut dir = Dir::open(".").await?;
while let Some(result) = dir.next().await {
    println!("entry: {}", result?.file_name());
}
dir.close().await?;
```

The repository has not been touched since January 2023 and has no licence
file. Treat it as a reference and a starting point, not as something to
deploy.

## 3. Why it never landed

This is the part that matters, and the reason you should not assume this is a
weekend job. Three real problems:

**The file position is shared state.** A directory read advances `f_pos` on
the `struct file`. Two concurrent `getdents` calls on the same fd must be
serialised or they return garbage. io_uring's whole point is running many
requests in parallel, so the two models fight each other.

**The fill callback runs in the caller's context.** `getdents` does not return
a buffer; the filesystem calls a `filldir` callback that copies each entry
straight into the user's buffer. That copy needs the right task and the right
address space. Moving the work to an io_uring worker thread means being very
careful about where that copy actually happens.

**It may not be genuinely async.** If the dentry cache is cold, the filesystem
has to hit the disk, and there is no non-blocking path to fall back on. The
request then goes to io_uring's worker thread pool — which is what a runtime's
own thread pool was already doing. The win in that case comes from batching
and fewer syscalls, not from true asynchrony. That is still a win, but it is a
smaller and more conditional one than "async readdir" suggests.

Any revived series has to answer all three in the cover letter. Al Viro raised
them; they were never resolved; posting the same patches again without
addressing them will get the same result.

## 4. The reported numbers, and how to read them

From the reference repository, walking the Linux source tree (83,796 files)
and summing file sizes:

| Method | Time |
|---|---|
| Rust + tokio, no io_uring | 1.201 s |
| `du -bs` | 0.635 s |
| Rust + io_uring `getdents` | 0.366 s |

So roughly 3.3x faster than a thread-pool runtime, and 1.7x faster than `du`.

Now the caveats, because the test setup shapes the result:

- It ran in a QEMU microvm on an ext2 image with host caching disabled. That
  is not a normal machine.
- Caches were dropped before every run (`echo 3 > drop_caches`), so every run
  is a cold-cache run.
- The comparison against tokio measures io_uring against a thread pool, which
  is a fair comparison of the two designs, but part of the gap is tokio's
  thread-pool overhead rather than the syscall saving.
- The `du` comparison is against a single-threaded C program. Concurrency
  accounts for some of that difference on its own.

The direction is believable and the mechanism is sound. Treat the exact
multipliers as specific to that setup, and measure your own workload on real
storage before planning around them.

## 5. Who benefits

Programs that walk many directories and are limited by per-directory
overhead rather than by reading file contents:

- build systems and file watchers scanning a source tree
- backup and sync tools enumerating what changed
- search indexers
- container image tooling walking layer contents
- anything that currently shells out to `find` or `du` on a large tree

Programs that read a handful of directories, or that spend most of their time
reading file data, will see nothing.

## 6. What to do about it

**Today, no kernel change:** nothing. There is no userspace workaround. If you
need parallel directory traversal, a thread pool doing blocking `getdents` is
still the correct answer, and it is what every runtime does.

**If you want to revive it:**

1. Read the lore thread end to end, including every reply.
2. Read the kernel submodule in the reference repository and work out which
   objections it answers and which it sidesteps.
3. Write the cover letter *first*. If you cannot explain how you handle
   `f_pos` serialisation, the `filldir` context, and the cold-cache fallback,
   you are not ready to post.
4. Ask on the io-uring list before writing code. Jens Axboe and Al Viro are
   the people whose opinions decide this, and asking costs nothing.
5. Follow [the submission guide](docs/sending-patches-to-linux.md).

**If you just want to watch:** check whether an opcode has appeared.

```sh
# Did it land?
grep -rn "GETDENTS" include/uapi/linux/io_uring.h io_uring/

# Is it moving?
# https://lore.kernel.org/io-uring/?q=getdents
```

## 7. Realistic expectation

The gap is real and the fix is wanted, but this has been stuck since 2021 for
technical reasons that nobody has cleared, not because nobody noticed. Two
serious attempts exist and both stopped at the same wall.

Do not treat the reference repository as "almost merged". Treat it as a good
prototype and a well-built test harness that saves you a week of setup, and
assume the hard part — satisfying VFS review — is still entirely in front of
you. If you are not prepared to argue VFS locking with Al Viro, this is a
tracking item, not a project.

## 8. Effectiveness test — if you do build it

```sh
# Cold cache, real storage, not a microvm. Repeat 10 runs.
sync; echo 3 > /proc/sys/vm/drop_caches

# 1. Baseline: your own workload on a stock kernel, thread pool version.
# 2. Same workload, patched kernel, io_uring version.
# 3. Also measure warm cache - that is the common case in real use and
#    it is where the syscall saving matters most, since there is no disk
#    wait to hide behind.

# Count the syscalls, which is the mechanism you are actually testing:
strace -c -f ./your-workload
#   Expect io_uring_enter to replace a large number of getdents64 calls.
#   If the getdents64 count did not drop, the io_uring path is not
#   being taken and the timing difference is measuring something else.

# Check where the time went:
perf stat -e syscalls:sys_enter_getdents64,syscalls:sys_enter_io_uring_enter \
    ./your-workload
```

Report both cold and warm numbers. A series that only shows cold-cache results
invites the reviewer to ask what it looks like warm, and you want that answer
ready.
