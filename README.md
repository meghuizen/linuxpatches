# linuxpatches

Patches, patch proposals, and adoption notes for Linux — kernel side and
userspace side.

Every document follows the same shape: what the problem is, the evidence for
it in real source code, the change, how to test it, and what you should
honestly expect to gain. The point is that you can read one and understand
*why* it exists, not only what it touches.

Nothing here is marketing. Where a change does nothing on a laptop, the
document says so.

## The two halves

### [`linux-kernel/`](linux-kernel/README.md) — kernel patches

Ten documents, written against **Linux 7.2, vanilla**. Four kinds:

- **Ready patches (1-4)** — cache layout fixes. Reorder fields in `task_struct`,
  `inode`, and `address_space` so hot fields share a cache line and write-hot
  fields stop invalidating read-hot ones. Small, low risk, no behaviour change.
- **Projects (5, 6, 9)** — features needing weeks of work and specific
  hardware: io_uring zero-copy receive for Intel NICs and for virtio-net, and
  offloading bulk page copies to Intel DSA.
- **Trackers (7, 8)** — nothing to build. In-kernel QUIC and BBRv3, both
  upstream work we want but do not control.
- **Reference (10)** — `getdents` for io_uring. Two people already built it;
  neither landed it. The document says why.

Also holds [how to send a patch to the kernel for
review](linux-kernel/docs/sending-patches-to-linux.md).

### [`uutils-opt/`](uutils-opt/README.md) — userspace stat and syscall work

Six documents targeting the Rust coreutils (`uutils/coreutils`), the Rust
directory-walking crates, and GNU gnulib.

The baseline that motivates all of it: `ls -l` on 5000 files issues 5001
`statx` syscalls. That is 33% of syscall time on a warm cache, and on NFS it
is 5001 serial round trips over the wire.

The strategy is *eliminate, then trim, then batch* — the cheapest syscall is
the one you never make:

- **Eliminate (1-3)** — `fstat` the file handle you already opened instead of
  stat-ing the path again; use the `d_type` the kernel already gave you during
  `getdents`; skip per-entry stats in `ls --color` when the palette does not
  need them.
- **Trim (4)** — for the stats you genuinely cannot avoid, ask `statx` for only
  the fields you print, and on network filesystems accept cached attributes.
- **Batch (5, 6)** — add per-directory metadata prefetch to the walkers
  everyone shares: `walkdir`, `ignore` (ripgrep, fd, tokei), `jwalk` on the
  Rust side, and gnulib's `fts` on the C side, which covers GNU `du`, `rm`,
  `chmod`, `chown`, and `find` at once.

No kernel ABI changes anywhere in that series.

## How the two halves relate

They attack the same cost from opposite ends. The kernel documents make each
operation cheaper. The userspace documents make fewer operations happen. The
userspace work needs no kernel changes at all, so it is the half you can
actually ship this month.

If you only read two documents, read
[`linux-kernel/03-inode-false-sharing.md`](linux-kernel/03-inode-false-sharing.md)
and [`uutils-opt/01-fstat-after-open.md`](uutils-opt/01-fstat-after-open.md).
They are the clearest examples of each style.

## Notes

- Kernel documents are written against Linux 7.2. Applying them to another
  version may fail or produce broken code.
- Userspace line references are from a shallow clone of master on
  2026-08-31. Re-grep before patching.
- Every stated impact is an estimate, not a measurement. Each document ends
  with a test that tells you how to check whether the change did anything on
  your machine. Run it — layout and syscall changes are easy to get wrong in
  a way that looks like an improvement.
- Shared as-is, with no guarantee that any of it works for you.

## Contributing

The repository is public to read. Only I can push to it directly. If you want
to suggest a change, fork the repository and open a pull request.
