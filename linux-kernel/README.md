# Linux kernel patches

Kernel patches and patch proposals, each with a written explanation.

For the userspace half of this repository, see
[`../uutils-opt/`](../uutils-opt/README.md).

Every document says what the problem is, shows the evidence in the actual
kernel source, gives the change, explains how to test it, and states what
you should realistically expect to gain. The point is that you can read one
and understand *why* it exists, not only what it touches.

The numbered documents are written against Linux 7.2, vanilla. The patches
in the area directories are against v7.3-rc3 (518e5b794c06), which is also
the base of the patches prepared for submission.

Per-patch status (what goes upstream, what was removed and why, measured
results): [`SUBMISSION-STATUS.md`](SUBMISSION-STATUS.md). Each patch was
measured alone on v7.3-rc3 in a nested KVM guest; see the "How it was
measured" section there.

## Areas

| Area | Contents | For submission |
|---|---|---|
| [`vfs/`](vfs/README.md) | The open and stat paths: analysis, Lean proofs | 2 patches on vfs-7.4.lookup ([`vfs/submission/`](vfs/submission/)) |
| [`net/`](net/README.md) | The router forwarding path, generic `net/` code only | 3 nf-next patches; CAKE timer slack as RFC ([`net/submission/`](net/submission/)) |
| [`client/`](client/README.md) | The outbound path: what a browser or curl does | 1 UDP patch ([`client/submission/netdev/`](client/submission/netdev/)) |
| [`sched/`](sched/README.md) | Scheduler cacheline placement | none: the EEVDF reorder was removed, no measurable difference ([`sched/submission/`](sched/submission/)) |

The `patches/` directory in each area held an older export and is now empty
apart from a note; the old versions of CAKE timer slack, conntrack raw hashes
and UDP batch wake had bugs that are fixed in the `submission/` versions.

The numbered documents below predate that split and stand on their own.

## Three kinds of documents in here

1. **Layout patches** (1-4) — small, concrete source changes. Reorder fields
   in a struct. None of the four is being submitted; see the status note under
   each heading below.
2. **Projects** (5, 6, 9) — features that need weeks of work and specific
   hardware. The document is a plan and a readiness audit, not a diff.
3. **Trackers** (7, 8) — nothing to build. Upstream work we want but do not
   control. The document says what to watch and when to adopt.
4. **References** (10) — someone else already built it and it never merged.
   The document points at their work and explains why it stalled.

## 1-4: Cache layout patches

These four all fix the same class of problem. A CPU never reads one byte, it
reads a 64-byte cache line. So the cost of a struct is not how many bytes you
read, it is how many different lines you touch. Fields used together should
sit together. Fields written often should not sit next to fields read often,
because writes on one CPU throw away the line for every other CPU.

Read them in order. Patch 2 changes the same region of the same file as
patch 1, so patch 1 goes first. Patch 4 is the same fix as patch 3, one struct
further down.

### [1. Keep the scheduler hot fields together in `task_struct`](01-task-struct-scheduler-entities.md)

Status (measured 2026-09-23): not submitted. Its successor, the EEVDF `sched_entity`
reorder, measured alone: no difference beyond the base spread; removed. See
[`sched/submission/REVIEW.md`](sched/submission/REVIEW.md).

Moves 504 bytes that a normal task never uses (`rt`, `dl`, `scx`) out from
between `se` and `sched_class`, the two fields the scheduler reads on every
context switch.

Estimate made before measurement: a context switch touches about 5 cache lines
instead of 12 (static count). No runtime gain has been shown.

### [2. Put the wakeup fields on the wakeup cache lines](02-task-struct-wakeup-fields.md)

Status (2026-09-23): not submitted, not measured. Its successor (wake_entry
placement) was dropped on analysis: the `cpus_ptr` move saves no line, since readers
dereference it to `cpus_mask`. See [`sched/submission/REVIEW.md`](sched/submission/REVIEW.md).

Moves `nr_cpus_allowed` and `cpus_ptr` from cache line ~20 up next to the
other wakeup fields in the first two lines.

Estimate made before measurement: one fewer remote cache line per wakeup. The
review above found no line saved on the paths that read `cpus_ptr`.

### [3. Fix false sharing in `struct inode`](03-inode-false-sharing.md)

Status (2026-09-23): removed. Layout model over all 8 inode start offsets:
+1 line on stat (2 of 8 offsets) and on open (2 of 8); no placement fixes it. See
[`vfs/submission/REVIEW.md`](vfs/submission/REVIEW.md) ("Why orig 12 was removed").

Moves `i_fop` and `i_flctx` off the cache line they share with six constantly
written atomic counters (`i_count`, `i_writecount`, `i_dio_count`, and
others). Adds build-time asserts so the layout cannot silently rot later.

Estimate made before measurement: removes a false-sharing conflict between
`open()` and the refcount writers. The layout model above contradicts this:
the patch lengthens the stat and open paths at some offsets.

### [4. Fix false sharing in `struct address_space`](04-address-space-false-sharing.md)

Status (2026-09-23): removed. An earlier run showed no difference on its target workload
(10.21M vs 10.18M iops). See [`vfs/submission/REVIEW.md`](vfs/submission/REVIEW.md).

Regroups the page-cache fields: the ones written on every page-cache add or
remove (`i_pages`, `nrpages`, `writeback_index`) go on one line, the ones read
on every fault, read, and writeback (`host`, `a_ops`, `gfp_mask`, `flags`) go
on another. Today they are interleaved.

Estimate made before measurement: less false sharing when several CPUs use one
file, and one dirtied line instead of two per page-cache add or remove. The
measurement above showed no difference.

## 5, 6, 9: Feature projects

These are not diffs. They are plans, each with an audit of what already exists
upstream so you know how much is genuinely left to build.

### [5. io_uring zero-copy receive on Intel NICs](05-zcrx-intel-queue-mgmt.md)

Implement `netdev_queue_mgmt_ops` in Intel's `ice` driver (E810) so io_uring
zero-copy receive and devmem TCP work there. Both features are already
finished in the 7.2 core kernel; they are simply locked out on these cards.

**Expected impact:** categorical, not incremental. Applications on Intel NIC
fleets go from *cannot use zero-copy receive at all* to removing one CPU copy
per received byte. The win grows with throughput.

**Cost:** weeks of careful work in the RX buffer path of a production driver,
medium risk. Four other drivers already prove the interface and the test suite
is in-tree, so the path is known. **Do not start this without an E810** —
every claim in the series needs numbers from a real card.

### [6. io_uring zero-copy receive inside VMs](06-zcrx-virtio-net.md)

The same feature for paravirtual networking: add header/data split to the
virtio spec, implement it in the device backend, then wire `queue_mgmt_ops`
and netmem into the guest `virtio-net` driver.

**Expected impact:** the widest reach of anything here, because most server
workloads run in VMs. Same categorical win as patch 5.

**Cost:** the slowest item in the set. The kernel code is small and has
precedent, but it sits behind a virtio spec cycle and a device implementation.
Treat it as multi-quarter work with committee risk. Do patch 5 first — same
skills, no spec dependency, hardware exists — and use it as credibility for
the virtio proposal. Also check whether SR-IOV passthrough solves your problem
first; if your fleet can take it, you may not need this at all.

### [9. Offload bulk page copying to DSA](09-dsa-mm-offload.md)

Teach memory management to hand its bulk page copies — migration for CXL and
NUMA tiering, compaction, khugepaged collapse — to the DSA DMA engine that
sits idle in every Xeon since Sapphire Rapids, instead of burning CPU on
`memcpy`.

**Expected impact:** this is not a latency win and never will be. It is a
CPU-liberation win. On fleets with real background memory churn, whole cores
currently spent on `memcpy` come back for actual work. On a laptop it does
nothing at all.

**Cost:** weeks, needs a DSA-capable Xeon to measure on. Both halves already
exist — the driver is done, the dmaengine API is the precedent — and the gap
is one integration layer. Several people have tried this and none finished, so
reading why those attempts died is the most important task in the whole item.

## 7, 8: Adoption trackers

Nothing to build. These exist so we notice the moment upstream work lands.

### [7. In-kernel QUIC](07-quic-adoption-tracking.md)

QUIC is the one major protocol the kernel accelerates nothing for. There is no
`net/quic` in 7.2 — verified. The upstream series exists and has been in review
a long time.

**Expected impact:** when it lands, TCP-class acceleration for the protocol the
internet is moving to. Until then, turning on UDP GSO in userspace recovers a
useful slice of the gap for about one line of config.

### [8. BBRv3 congestion control](08-bbrv3-adoption-tracking.md)

7.2 ships BBRv1 only — verified, no v2 or v3 code in `net/ipv4/tcp_bbr.c`.
Google published v3 in 2023 and upstreaming has stalled for years.

**Expected impact:** depends entirely on your traffic. Worth real attention for
internet-facing egress over lossy or long-RTT paths. Near-worthless for
datacenter traffic behind a load balancer. Classify your traffic before
spending any attention on it.

**Cost:** one archive search per quarter, one grep per kernel bump.

## 10: Reference

### [10. `getdents` support for io_uring](10-iouring-getdents.md)

io_uring still has no way to read directory entries. `getdents` is the syscall
behind `readdir()`, and it is missing in 7.2, so every async runtime falls back
to a blocking thread pool for directory work.

Two people have already built this and neither landed it: Stefan Roesch posted
patches in December 2021, and Tobias Danecker revived and extended them in 2023
at <https://github.com/tdanecker/iouring-getdents> — a patched kernel, patched
Rust `io-uring` and `tokio-uring` crates, and a QEMU test harness.

**Expected impact:** the author reports directory traversal roughly 3.3x faster
than a thread-pool runtime and 1.7x faster than `du`, walking the kernel source
tree. Those numbers come from a QEMU microvm on ext2 with caches dropped, so
treat the direction as sound and the exact multipliers as setup-specific.
Programs that walk large trees gain; programs that read a few directories, or
that spend their time on file contents, gain nothing.

**Cost:** this is stuck for real technical reasons, not neglect. Directory
reads keep shared position state on the file, the entry-copy callback has to
run in the right context, and on a cold cache the request falls back to a
worker thread anyway — so part of the "async" claim is really just batching.
Al Viro raised these in 2021 and nobody has answered them. Do not start unless
you are ready to argue VFS locking upstream.

## Where to start

- Want patches that are being submitted: see
  [`SUBMISSION-STATUS.md`](SUBMISSION-STATUS.md). Documents 1-4 are kept as
  analyses; none of them is being submitted.
- Have server hardware and time: patch 5.
- Run large memory-tiering fleets: patch 9.
- Just want to stay informed: 7, 8, and 10.

## How to apply a patch

Each write-up contains the change itself. When a ready-made `.patch` file is
included, apply it from the root of the kernel source tree:

```sh
patch -p1 < /path/to/0001-short-description.patch
```

If the patch was made with `git format-patch`, use git instead:

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

- The numbered documents are written against Linux 7.2; the area patches
  against v7.3-rc3 (518e5b794c06). Applying them to a different version may
  fail or produce broken code.
- Every "expected impact" above is an estimate, not a measurement, except
  where a "Status (2026-09-23)" note gives the outcome. Each
  document ends with an effectiveness test that tells you how to check whether
  the change actually did anything on your machine. Run it. Layout changes are
  easy to get wrong in a way that looks like an improvement.
- Always read a patch before you apply it. It is just text.
- Shared as-is, with no guarantee that any of it works for you.

## Contributing

See the [repository README](../README.md).
