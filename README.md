# linuxpatches

A collection of Linux patches.

This repository holds patches for the Linux kernel, plus a written explanation
for each one. The write-up says what the problem is, shows the evidence in the
existing kernel source, gives the change, and explains how to test it. The idea
is that you can read a patch and understand *why* it exists, not only what it
touches.

The current patches are all about **data structure layout and CPU caches**:
putting fields that are used together on the same cache line, and keeping
write-hot fields away from read-hot ones.

## The patches

| # | Patch | What it does |
|---|---|---|
| 1 | [Keep the scheduler hot fields together in `task_struct`](01-task-struct-scheduler-entities.md) | Moves 504 bytes that a normal task never uses (`rt`, `dl`, `scx`) out from between `se` and `sched_class`, so a context switch touches about 5 cache lines instead of 12. |
| 2 | [Put the wakeup fields on the wakeup cache lines](02-task-struct-wakeup-fields.md) | Moves `nr_cpus_allowed` and `cpus_ptr` up next to the other wakeup fields, so waking a task pulls two remote cache lines instead of three. |
| 3 | [Fix false sharing in `struct inode`](03-inode-false-sharing.md) | Moves `i_fop` and `i_flctx` off the cache line shared with six constantly written atomic counters, so refcount traffic stops invalidating the `open()` path. |
| 4 | [Fix false sharing in `struct address_space`](04-address-space-false-sharing.md) | Regroups the page-cache fields so the ones written on every add or remove sit on one cache line, and the ones read on every fault or writeback sit on another. |

Read them in order. Patch 2 changes the same region of the same file as
patch 1, so apply patch 1 first.

Each write-up lists the kernel version it was made against, the files it
touches, the size of the change, and how risky it is.

## How to apply a patch

Each write-up contains the change itself. When a ready-made `.patch` file is
included, apply it like this.

Go to the root of the source code you want to change, then run:

```sh
patch -p1 < /path/to/0001-short-description.patch
```

If the patch was made with `git format-patch`, you can use git instead:

```sh
git apply /path/to/0001-short-description.patch
```

To undo a patch, add `-R`:

```sh
patch -p1 -R < /path/to/0001-short-description.patch
```

## Guides

- [How to send a patch to the Linux kernel for review](docs/sending-patches-to-linux.md)

## Notes

- Patches are made against a specific version. Applying them to a different
  version may fail or produce broken code.
- Always read a patch before you apply it. It is just text, so you can open
  it in any editor.
- These patches are shared as-is, with no guarantee that they work for you.

## Contributing

The repository is public to read. Only I can push to it directly. If you want
to suggest a change, fork the repository and open a pull request.
