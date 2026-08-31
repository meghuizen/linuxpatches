# Task 6 — Enable io_uring zero-copy receive inside VMs (`queue_mgmt_ops` + header split for virtio-net)

**What this task delivers, in one sentence:** make io_uring zero-copy receive (zcrx) work for guests using paravirtual networking, by adding a header/data-split feature to the virtio spec, implementing it in the device backend, and wiring `queue_mgmt_ops` plus netmem support into the guest `virtio-net` driver.

| | |
|---|---|
| Target | virtio spec + device backend (QEMU/vhost or vDPA hardware) + `drivers/net/virtio_net.c` |
| Kernel | Linux 7.2, vanilla, `/mnt/data/linux-src/linux-7.2` |
| Nature | Three-layer project: spec extension gates backend, backend gates guest driver |
| Realistic effort | Longest-horizon item in this series — a virtio TC spec cycle plus two implementations |
| Risk | Medium per layer; the spec layer is process risk, not code risk |
| Impact | Categorical: every paravirt guest goes from "zcrx impossible" to "one CPU copy per received byte removed" — and VMs are where most server workloads actually run |

---

## 1. Background: why the VM case is its own task

Task 5 unlocks zcrx on bare-metal Intel NICs. But most fleets run guests on paravirtual `virtio-net`, and the zcrx gate (`__netif_mp_open_rxq()`, `net/core/netdev_rx_queue.c:187`) evaluates the **guest's** netdev:

```
guest app ── io_uring zcrx ──> guest virtio-net  <── THE GATE IS HERE
                                     |
                              vhost/QEMU/vDPA backend
                                     |
                              host NIC (Task 5 territory)
```

A perfect host NIC changes nothing for the guest: the guest driver must itself support single-queue restart (`queue_mgmt_ops`) and header/data split (HDS). Checked in 7.2:

```bash
grep queue_mgmt_ops drivers/net/virtio_net.c      # empty
grep -i 'tcp_data_split\|hds' drivers/net/virtio_net.c   # empty
```

Two gaps, and they are not the same size.

## 2. Readiness audit (validated in the tree)

| Requirement | State in virtio-net | Evidence |
|---|---|---|
| Per-queue stop/restart primitive | **Yes** — `virtqueue_reset()` is already used to rebind a single RX queue for AF_XDP, and `virtqueue_resize()` backs per-ring ethtool resize | `drivers/net/virtio_net.c:5842,5871` (reset), `:3444,3510` (resize); spec side: `VIRTIO_F_RING_RESET` |
| page_pool RX | **Yes** | 70 references in `virtio_net.c` |
| netmem-aware buffer handling | **No** — same conversion work as ice (Task 5, item A) | — |
| `queue_mgmt_ops` | **No** — the mechanical gap | — |
| Header/data split | **No — and no virtio spec feature exists for it.** The only header-related bit is `VIRTIO_NET_F_GUEST_HDRLEN` (`include/uapi/linux/virtio_net.h:66`), which is about the virtio-net header length, not payload splitting | — |

The same pattern as ice — restart primitives already proven by AF_XDP, page_pool present — **except** HDS. On ice, HDS was a hardware capability with an existing ethtool knob; on virtio-net, the *device* (QEMU, vhost-net, or a vDPA DPU) has no negotiated way to promise "headers in buffer set A, payload in buffer set B". zcrx cannot work without that promise: payload must land in user-registered memory the kernel never reads, headers must land in kernel memory the stack can parse.

## 3. The work, layer by layer

**Layer 1 — virtio spec extension (gates everything).**
A new feature bit (working name: header/data split for receive) defined through the virtio Technical Committee: when negotiated, the device places the virtio-net header + protocol headers into one buffer and the payload at a defined boundary into separate buffers, with an `hds_thresh = 0` equivalent (every packet split, no size cutoff). The design must answer where the split point is (L4 payload start), how it interacts with mergeable buffers and GRO-in-device (`VIRTIO_NET_F_MRG_RXBUF`, guest GSO features), and what happens on malformed packets. Process: proposal on the virtio-comment list, TC ballot. This is the long pole — measured in months, not weeks.

**Layer 2 — a device implementation.**
At least one backend must exist to test against: QEMU/vhost-net in software (correctness reference, no perf claim), and realistically a vDPA/DPU vendor implementation for the performance story — hardware virtio devices are where guest zcrx pays off most, since with vhost-net the host still touches payload. A software-only backend still has value: it unlocks the guest-side merge and CI.

**Layer 3 — the guest driver (the familiar part).**
Same shape as Task 5: (a) netmem conversion of the RX buffer path; (b) `queue_mgmt_ops` implemented around the existing `virtqueue_reset`/`virtqueue_resize` machinery — the gve precedent (~136 lines total) applies, since virtio-net's per-queue helpers already exist for AF_XDP; (c) the ethtool `tcp-data-split` knob wired to the negotiated feature. This layer is genuinely small once layers 1-2 exist.

## 4. What already works in VMs today — check before building

The gap is specific to the *paravirtual* path. Guests whose netdev is a real driver with `queue_mgmt_ops` can run zcrx **now**:

- **SR-IOV / passthrough of a ConnectX VF** — mlx5 sets `queue_mgmt_ops` in the shared en driver (`drivers/net/ethernet/mellanox/mlx5/core/en_main.c:5839`), VFs included.
- **bnxt VFs** where the device qualifies (`bnxt.c:17254-17256` picks supported vs unsupported ops at probe).
- **GCP guests** — the guest driver there is gve, which has full support (`gve_main.c:2737`).

So the practical decision tree: if you control the platform and can afford passthrough (losing easy live migration), zcrx in VMs is available today. This task exists for the fleets that need paravirt semantics — migration, overcommit, vendor-neutral guests — which is most of them.

## 5. How to test

```bash
# Guest side: same in-tree selftests as Task 5
#   tools/testing/selftests/drivers/net/hw/iou-zcrx.py  (run inside the guest)
ethtool -G eth0 tcp-data-split on        # once the knob exists

# Regression coverage for what must NOT break in virtio-net:
#  - normal RX path perf before/after netmem conversion (layer 3a)
#  - AF_XDP in the guest (shares virtqueue_reset)
#  - ethtool ring resize, feature renegotiation, live migration with the
#    feature active (device must fail negotiation cleanly on a target
#    host without support - this WILL be asked in spec review)
```

## 6. ABI and compatibility

| Concern | Answer |
|---|---|
| Guest/host compatibility | Feature-bit negotiated like every virtio capability: old device + new guest, or new device + old guest, both fall back cleanly to copy-path RX |
| Userspace ABI | None new — zcrx is an existing io_uring API; the ethtool knob is the existing `tcp-data-split` field |
| Behavior when unused | None — ops invoked only on provider bind; feature not negotiated means nothing changes |
| Live migration | The spec proposal must define feature handling across migration — this is the compatibility question that dominates virtio reviews |

## 7. Getting it merged

Three venues, in dependency order:

1. **Spec:** virtio-comment / virtio-dev lists, virtio TC ballot. Study how `VIRTIO_F_RING_RESET` was proposed — same shape of per-queue capability.
2. **Backend:** QEMU list for the software reference; vDPA vendor trees for hardware.
3. **Guest driver:** netdev + virtualization lists; maintainers via `scripts/get_maintainer.pl -f drivers/net/virtio_net.c` (Michael S. Tsirkin, Jason Wang — both also sit at the spec layer, so early alignment with them effectively is the spec proposal).

Series shape for the kernel part mirrors Task 5: netmem conversion first (no functional change, perf numbers), then ops, then the feature/ethtool wiring.

## 8. Realistic expectation

This is the widest-impact and slowest item in the series: the kernel work is small and precedented, but it sits behind a spec cycle and a device implementation, so treat it as a multi-quarter effort with committee risk. The payoff justifies it — Task 5 covers bare metal, this covers where the workloads actually live — but sequence accordingly: build Task 5 first (same skills, no spec dependency, hardware exists), use its netmem/ops experience as the credibility basis for the virtio proposal, and check section 4's passthrough options before committing at all — if your fleet can take SR-IOV, you may not need this task, just a ConnectX/bnxt VF and patience for live-migration tooling to catch up.

---

## 9. Effectiveness test — did the feature actually pay?

Layered like the project itself: prove each layer before claiming the next.

**Layer gate A — guest driver conversion is free** (same as Task 5 gate 1, run *inside* the guest): normal virtio-net RX within 1% before/after the netmem patches, no zcrx bound.

**Layer gate B — software backend correctness, no perf claims:**
`iou-zcrx.py` passes in-guest against the QEMU/vhost reference backend. Software backends still copy on the host — do not publish throughput numbers from this setup as "zero-copy performance"; they aren't.

**Layer gate C — the real claim, hardware virtio (vDPA/DPU) only:**

```bash
# Inside guest, fixed offered load, copy path vs zcrx:
mpstat -P ALL 1 60                      # guest CPU per Gbit
perf kvm stat live                       # on the HOST: exit rate
```
| Gate | Threshold |
|---|---|
| Guest RX profile | Payload `copy_to_user` gone |
| Guest CPU per Gbit | Substantial drop; report actual |
| Host VM-exit rate at fixed load | Not increased — a feature that buys guest CPU by exit-storming the host is a net loss; this is the VM-specific gate that doesn't exist on bare metal |
| Live migration with feature negotiated | Clean fallback or clean block, per the spec's answer — tested, not assumed |

**The honest failure mode:** on vhost-net (software) the end-to-end CPU total (guest+host) barely improves because the host still touches every byte. That is expected and must be stated — the categorical win exists only where the device is hardware. Publishing software-backend numbers as the headline would sink the spec proposal's credibility.
