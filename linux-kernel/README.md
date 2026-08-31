# Linux kernel patches

Kernel patches and patch proposals, each with a written explanation.

For the userspace half of this repository, see
[`../uutils-opt/`](../uutils-opt/README.md).

Every document says what the problem is, shows the evidence in the actual
kernel source, gives the change, explains how to test it, and states what
you should realistically expect to gain. The point is that you can read one
and understand *why* it exists, not only what it touches.

All of it is written against **Linux 7.2, vanilla**.

## Three kinds of documents in here

1. **Ready patches** (1-4) — small, concrete source changes. Reorder fields in
   a struct. Low risk, no behaviour change.
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

**Read them in order.** Patch 2 changes the same region of the same file as
patch 1, so patch 1 goes first. Patch 4 is the same fix as patch 3, one struct
further down.

### [1. Keep the scheduler hot fields together in `task_struct`](01-task-struct-scheduler-entities.md)

Moves 504 bytes that a normal task never uses (`rt`, `dl`, `scx`) out from
between `se` and `sched_class`, the two fields the scheduler reads on every
context switch.

**Expected impact:** a context switch touches about 5 cache lines instead of
12. That is low single-digit percent on switch-heavy benchmarks, and probably
nothing measurable on anything else. The argument for it is the price, not the
size of the win: ten reordered lines, no behaviour change, permanent.

### [2. Put the wakeup fields on the wakeup cache lines](02-task-struct-wakeup-fields.md)

Moves `nr_cpus_allowed` and `cpus_ptr` from cache line ~20 up next to the
other wakeup fields in the first two lines.

**Expected impact:** one fewer remote cache line per wakeup, which you can
prove with `perf c2c`. Wakeup misses are expensive because the waking CPU is
pulling the woken task's memory out of another CPU's cache. Visible on
wakeup-heavy cross-socket work, lost in the noise on a laptop.

### [3. Fix false sharing in `struct inode`](03-inode-false-sharing.md)

Moves `i_fop` and `i_flctx` off the cache line they share with six constantly
written atomic counters (`i_count`, `i_writecount`, `i_dio_count`, and
others). Adds build-time asserts so the layout cannot silently rot later.

**Expected impact:** the strongest of the four. This is not tidying, it is a
live conflict with a named reader (`open()`) and named writers
(`iget`/`iput`). Refcount traffic on one CPU currently invalidates the
`open()` path on every other CPU. `sock`, `tcp_sock`, `net_device`, and
`dentry` already got this exact fix; `inode` is the last big hot struct
without it. Real on a 64-core build server, invisible on a laptop.

### [4. Fix false sharing in `struct address_space`](04-address-space-false-sharing.md)

Regroups the page-cache fields: the ones written on every page-cache add or
remove (`i_pages`, `nrpages`, `writeback_index`) go on one line, the ones read
on every fault, read, and writeback (`host`, `a_ops`, `gfp_mask`, `flags`) go
on another. Today they are interleaved.

**Expected impact:** two separate effects. The false-sharing fix only pays
when several CPUs hammer one file — real for databases and shared logs, absent
for many-small-file workloads. The second effect is smaller but unconditional:
a page-cache add or remove now dirties one line instead of two. Weaker than
patch 3, so submit it after patch 3, framed as the same treatment for the next
struct down.

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

- Want something you can actually apply today: patch 3, then 1, 2, 4.
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

- Everything here is written against Linux 7.2. Applying it to a different
  version may fail or produce broken code.
- Every "expected impact" above is an estimate, not a measurement. Each
  document ends with an effectiveness test that tells you how to check whether
  the change actually did anything on your machine. Run it. Layout changes are
  easy to get wrong in a way that looks like an improvement.
- Always read a patch before you apply it. It is just text.
- Shared as-is, with no guarantee that any of it works for you.

## Contributing

See the [repository README](../README.md).
