# Task 5 — Enable io_uring zero-copy receive on Intel NICs (`queue_mgmt_ops` for ice)

**What this task delivers, in one sentence:** implement the `netdev_queue_mgmt_ops` interface in Intel's `ice` driver (E810 series) so that io_uring zero-copy receive (zcrx) and devmem TCP — both already fully present in the 7.2 core kernel — stop being locked out on the most widely deployed server NICs.

| | |
|---|---|
| Target driver | `drivers/net/ethernet/intel/ice/` (E810, 25/100G) |
| Kernel | Linux 7.2, vanilla, `/mnt/data/linux-src/linux-7.2` |
| Nature | Feature implementation project — not a reorder patch like Tasks 1-4 |
| Realistic effort | Weeks, plus E810 hardware to test on |
| Risk | Medium — touches the RX buffer path of a production driver |
| Impact | Removes the per-byte receive copy for any application on this NIC that adopts zcrx; the win grows with throughput |

---

## 1. Background: what zero-copy receive actually removes

Normal receive path — every byte is copied once by the CPU:

```
NIC ── DMA ──> kernel buffer ── copy_to_user ──> application buffer
                                     ^
                            CPU burns cycles per byte
```

At 100 Gbit/s, that copy alone can consume multiple CPU cores. Zero-copy receive (zcrx) removes it:

```
NIC ── DMA ──────────────────────> application buffer (registered upfront)
        kernel only handles metadata; payload is never touched by the CPU
```

The application registers a buffer area with io_uring once; the kernel tells the NIC to DMA packet *payloads* directly into it, and completions tell the application where each chunk landed. Protocol headers still go through the normal stack — which is why **header/data split (HDS)** is a hardware prerequisite: the NIC must be able to put headers and payload in different buffers.

All of this shipped in the 7.2 core kernel (`io_uring/zcrx.c`, 1793 lines; `net/core/devmem.c` for the GPU-memory variant). What gates it per NIC is one thing: the driver must let the kernel **restart a single RX queue with new memory** while the rest of the device keeps running. That is what `queue_mgmt_ops` is.

---

## 2. The contract the driver must implement

`include/net/netdev_queues.h:164` — five mandatory pieces:

| Member | What it must do | Key rule |
|---|---|---|
| `ndo_queue_mem_size` | Size of one queue's memory descriptor | Just `sizeof(<driver rx ring struct>)` |
| `ndo_queue_mem_alloc` | Allocate everything a fresh queue needs (rings, buffers, page pool) into caller-provided memory | **Must not touch the hardware or the live queue** — it prepares a shadow copy that can fail safely |
| `ndo_queue_mem_free` | Free such a descriptor | Must handle both never-started and stopped queues |
| `ndo_queue_stop` | Stop queue `idx` on the hardware, save its state into the descriptor | Only this queue — the other queues keep processing packets |
| `ndo_queue_start` | Install a prepared descriptor into queue `idx` and start it | If it fails, the core restores the old memory — that is the whole safety model |

The core sequences these in `netdev_rx_queue_reconfig()` (`net/core/netdev_rx_queue.c`): *alloc new → stop old → start new → free old*, with rollback at every step. The driver never sees the zcrx-specific parts at all — when the new queue's page pool is created, the core notices the queue has a memory provider bound (`rxq->mp_params`) and wires user memory in behind the driver's back. **The driver just has to make single-queue restart real.**

There is also `ndo_queue_get_dma_dev` (which device DMA-maps the buffers — needed for the devmem/dma-buf variant) and two optional config hooks (`ndo_default_qcfg`, `ndo_validate_qcfg`).

## 3. What the core checks at attach time (all verified in source)

`__netif_mp_open_rxq()` (`net/core/netdev_rx_queue.c:187`) refuses zcrx unless:

1. `dev->queue_mgmt_ops != NULL` — **this is the Intel gap, everything else below already works**
2. `tcp-data-split` is `ETHTOOL_TCP_DATA_SPLIT_ENABLED` (`ethtool -G <if> tcp-data-split on`)
3. `hds-thresh == 0` (split *every* packet, not just large ones)
4. No XDP program attached
5. The target queue isn't already bound to another provider or used by AF_XDP

So the checklist for a driver is: queue_mgmt_ops + working HDS + netmem-aware buffer handling. Which leads to the readiness audit.

---

## 4. Why ice, and how ready it actually is (audited, not assumed)

Who has `queue_mgmt_ops` today: **bnxt (Broadcom), gve (Google), mlx5 (NVIDIA), fbnic (Meta)** — assignment sites in each driver's main file. No Intel driver. Yet the audit shows ice has already built most of the prerequisites for its own reasons:

| Prerequisite | State in ice | Evidence |
|---|---|---|
| page_pool-based RX | **Yes** — converted via Intel's `libeth` library | `grep -rl page_pool drivers/net/ethernet/intel/` → iavf, ice, idpf, libeth |
| Header/data split + ethtool knob | **Yes** — `hsplit` wired to `tcp_data_split` | `ice_ethtool.c:3187,3232` |
| Stop/start of a *single* queue pair on live hardware | **Yes** — exists for AF_XDP already | `ice_qp_dis` / `ice_qp_ena`, `ice_base.c:1436,1488` |
| Configure one RX queue in isolation | **Yes** | `ice_vsi_cfg_single_rxq`, `ice_base.c:754` |
| netmem-aware buffer path | **The real remaining work** — see section 6 |

The AF_XDP point is the big one: attaching an XSK pool to one ice queue *already* performs exactly the stop-reconfigure-start dance that `queue_mgmt_ops` formalizes. The project is largely refactoring proven code to fit the generic interface, not inventing a mechanism.

Alternative target: `idpf` (Intel's newest driver, cleanest libeth integration) — architecturally easier, but it drives IPU hardware with a much smaller installed base than E810. Pick by which hardware you can test.

## 5. How small this can be: the gve precedent

gve's complete implementation, measured in the tree (`drivers/net/ethernet/google/gve/gve_main.c`):

```
ndo_queue_mem_alloc   ->  gve_rx_queue_mem_alloc    21 lines
ndo_queue_mem_free    ->  gve_rx_queue_mem_free     13 lines
ndo_queue_stop        ->  gve_rx_queue_stop         37 lines
ndo_queue_start       ->  gve_rx_queue_start        50 lines
ops struct + hookup                                 ~15 lines
                                            total  ~136 lines
```

It is this small because every function delegates to per-queue alloc/stop/start helpers the driver already had. ice would follow the same shape around `ice_qp_dis`/`ice_qp_ena`/`ice_vsi_cfg_single_rxq` — with one structural change: today those helpers allocate and program hardware in one motion; the contract requires splitting "prepare memory (may fail, touches nothing)" from "commit to hardware".

---

## 6. The honest work breakdown

**Item A — netmem conversion of the RX buffer path (the bulk of the effort).**
zcrx buffers are not `struct page` — they are `net_iov`s handed out by the page pool as opaque `netmem_ref` handles, and the CPU may not even be able to touch them (devmem case). Every place the ice/libeth RX path holds a `struct page *`, computes a virtual address for payload, or recycles a buffer must be converted to the `netmem_ref` API. Headers stay in normal kernel pages (that is what HDS guarantees), so the header-processing code is unaffected. gve and bnxt both went through this conversion and their commits are the working reference. This is mechanical but it touches the hottest loop in the driver, so it needs careful review and benchmarking of the *normal* (non-zcrx) path for regressions.

**Item B — the ops themselves (~150-300 lines).**
The gve-shaped refactor described in section 5. Split alloc from commit, wire the five callbacks, provide `ndo_queue_get_dma_dev` (for ice: the PF's PCI device).

**Item C — HDS validation at `hds_thresh = 0` on real hardware.**
ice's split support was built for its own uses; zcrx demands every packet split with payload-only in the data buffer. This is a hardware-behavior validation task on an actual E810, including small-packet and jumbo edge cases. Firmware version dependencies are possible — document what you test on.

Order matters: A first (it is independently reviewable and mergeable as "convert ice to netmem" with no functional change), then B+C together.

## 7. How to test — the tooling already exists

```bash
# In-tree selftests, tools/testing/selftests/drivers/net/hw/:
#   iou-zcrx.py / iou-zcrx.c   - end-to-end io_uring zero-copy receive
#   devmem.py / ncdevmem.c     - devmem TCP variant

# Prerequisites on the device under test:
ethtool -G eth0 tcp-data-split on
ethtool -G eth0 hds-thresh 0          # if supported as a knob

# Regression coverage for what must NOT break:
#  - normal RX path throughput/CPU before vs after the netmem conversion (item A)
#  - AF_XDP on the same driver (shares the queue-restart machinery)
#  - ethtool -G ring resizing, ifdown/ifup, queue count changes
```

The acceptance proof for the cover letter: `iou-zcrx.py` passing on E810, plus a CPU-per-Gbit comparison of copy vs zcrx receive at line rate.

## 8. ABI and compatibility

| Concern | Answer |
|---|---|
| Userspace ABI | None — `queue_mgmt_ops` is invisible to userspace; zcrx itself is an existing, stable io_uring API |
| Behavior when unused | None — the ops are only invoked when a memory provider binds or a queue API user acts; the normal path is unchanged (item A's conversion is the only thing that needs perf proof) |
| Other in-tree users you enable for free | devmem TCP, and the netlink queue API — same gate |
| Hardware/firmware | HDS behavior is device+firmware dependent; state tested firmware in the commits |
| Distro backports | Driver-contained; no kABI-sensitive core changes |

## 9. Getting it merged

This goes through Intel's driver tree, not directly to netdev:

```bash
perl scripts/get_maintainer.pl -f drivers/net/ethernet/intel/ice/ice_main.c
# Intel wired LAN maintainers + intel-wired-lan@lists.osuosl.org, then netdev
```

Expect review from three directions: Intel maintainers (driver correctness), the queue-API/zcrx authors (contract semantics — the alloc-must-not-touch-hardware rule is what they will probe), and netdev performance reviewers (no normal-path regression from the netmem conversion). Series shape that survives this: **patch 1-N: netmem conversion, no functional change, with before/after perf numbers; patch N+1: queue_mgmt_ops; patch N+2: advertise HDS-at-zero support; cover letter: selftest results on named hardware/firmware.**

## 10. Realistic expectation

This is the highest-leverage networking item this whole audit found: the core feature is finished, the test suite is in-tree, four drivers prove the interface, and ice has already built the hard primitives for AF_XDP — what is missing is weeks of careful driver work and access to an E810. The payoff is categorical rather than incremental: applications on Intel-NIC fleets go from *cannot use zero-copy receive at all* to saving one CPU copy per received byte. Unlike Tasks 1-4, do not start this one without the hardware — every claim in the series needs numbers from a real card.

---

## 11. Effectiveness test — did the feature actually pay?

Two separate questions with separate gates: did the netmem conversion cost anything, and did zcrx deliver.

**Gate 1 — the conversion must be free (blocks the whole series):**

```bash
# Normal copy-path RX, before vs after the netmem patches ONLY (no zcrx in use):
# fixed-rate line-rate traffic from a load generator, 5 runs each:
sar -u 1 60 &  iperf3 -s        # or your standard RX benchmark
```
| Gate | Threshold |
|---|---|
| Throughput at fixed offered load | Within 1% of baseline |
| CPU% at fixed throughput | Within 1% of baseline |

Fail here = stop; upstream will not trade a hot-path regression on every ice user for a feature some will use.

**Gate 2 — zcrx delivers on E810:**

```bash
# Same traffic, copy path (epoll+recv) vs zcrx (iou-zcrx test app or your server):
perf record -ag -- <receiver> ; perf report --sort=symbol
mpstat -P ALL 1 60             # CPU per fixed Gbit
```
| Gate | Threshold |
|---|---|
| `rep_movs_alternative` / `copy_to_user` in the RX profile | Dominant before, absent from the payload path after |
| CPU per Gbit at fixed rate | Substantial drop — report the actual number; the copy was the top consumer, so expect tens of percent at high MTU-saturating rates |
| p99 latency at moderate load | Neutral or better |
| `tools/testing/selftests/drivers/net/hw/iou-zcrx.py` | Pass on the tested firmware, stated in the cover letter |

**The honest failure mode:** CPU/Gbit barely moves because the workload was never copy-bound (small packets, header-heavy). zcrx pays on payload bytes; if your traffic has few, the feature works but the motivation number must come from a payload-heavy load — use one, and say so.
