# Task 8 — Adoption tracker: BBRv3 congestion control

**What this document is for, in one sentence:** track BBRv3's stalled upstreaming so we can adopt it when it merges — and document why (and for whom) it matters, since congestion control only pays on specific path types.

| | |
|---|---|
| Type | Tracking document — nothing to build; re-validate on every kernel bump |
| State in Linux 7.2 | **BBRv1 only** — verified: `net/ipv4/tcp_bbr.c` (~1200 lines) has no v2/v3 code |
| Who is driving it | Google (Neal Cardwell et al.); v3 published 2023, upstreaming stalled for years |
| Who it helps | Internet-facing egress over lossy/long-RTT paths. **Not** low-RTT datacenter traffic |

---

## 1. Background: what BBR is and what v3 fixes

Classic congestion control (CUBIC, the default) treats **packet loss** as the congestion signal: fill the pipe until a queue overflows, back off, repeat. On paths with big buffers this creates bufferbloat; on paths with random (non-congestion) loss — wireless, long international links — it collapses throughput for no reason.

BBR instead **models the path**: it estimates bottleneck bandwidth and round-trip time, and paces transmission to sit at the optimum rather than probing by hurting itself. v1 (in our tree) delivered big wins on lossy/long-fat paths but shipped with two known defects that v3 exists to fix:

1. **Unfairness:** v1 can starve CUBIC flows sharing a bottleneck — it doesn't back off on loss at all, so it takes bandwidth loss-based flows surrender.
2. **High retransmits in shallow buffers:** v1 overshoots on paths with small queues.

v3 adds proper loss and ECN response while keeping the model-based pacing — the version Google runs fleet-wide, published in their GitHub repo, presented at IETF, and still not merged.

## 2. Verified state in this tree (7.2, checked 2026-08)

```bash
cd /mnt/data/linux-src/linux-7.2
grep -in "v2\|v3\|bbr_version" net/ipv4/tcp_bbr.c   # -> nothing: v1
wc -l net/ipv4/tcp_bbr.c                            # ~1200 lines (v3 is ~3x larger)
```

Also verified relevant: `sch_fq` (BBR's pacing dependency) is in-tree and the default pairing; ECN support is present and increasingly negotiated.

## 3. What to watch, mechanically

```bash
# 1. Did it land? (run on each kernel bump)
grep -c "bbr" net/ipv4/tcp_bbr.c            # size jump to ~3000+ lines = v3
ls net/ipv4/tcp_bbr*.c                       # or a second file appears

# 2. Is it moving? Search the archives:
#    https://lore.kernel.org/netdev/?q=BBRv3
#    Out-of-tree source of truth: github.com/google/bbr (v3 branch)
#    Watch for: a fresh netdev posting from Google - the stall is on their
#    side, so a new series IS the signal; review usually moves fast after.
```

## 4. Decision framework — do we even want it?

Congestion control choice only matters where the *path* is the bottleneck. Be honest about which traffic qualifies:

| Traffic type | BBRv3 impact | Why |
|---|---|---|
| Internet egress to end users (CDN-less, mobile, intercontinental) | **High** | Lossy, variable-RTT paths are exactly BBR's case |
| Server behind a CDN/LB that terminates client TCP | **None for you** | The CDN's congestion control faces the users; yours faces the CDN over a clean path |
| Intra-datacenter, low-RTT | **None to negative** | CUBIC/DCTCP already fine; model-based probing buys nothing at 100us RTT |
| Cross-region replication over long fat pipes | **Moderate-high** | Long RTT x occasional loss is where CUBIC caps out |

If your fleet is the second or third row — most .NET services behind load balancers are — this tracker is low priority by design.

## 5. Interim options (today)

1. **BBRv1 is already in the tree** and selectable per route, not just globally:
   ```bash
   sysctl net.ipv4.tcp_congestion_control=bbr          # global, or:
   ip route change <egress-route> ... congctl bbr      # only where it helps
   ```
   Per-route scoping sidesteps most of v1's fairness concerns (don't run it on shared internal bottlenecks) while capturing the lossy-egress win.
2. **Out-of-tree v3 module:** TCP congestion control is pluggable (`tcp_congestion_ops`), and Google's repo builds as a module — technically viable, but it chases specific kernel versions, gets zero distro/stable backport support, and puts an unreviewed third-party module in the hottest path of the stack. Only for fleets with a dedicated kernel team and a measured v1-isn't-enough problem.
3. **Measure before believing:** trial v1-vs-cubic on real egress with retransmit rate + goodput per connection class. If v1 shows nothing, v3 will show nothing — the path types that don't reward the model don't reward a better model either.

## 6. Realistic expectation

Zero engineering to do; one archive search per quarter and one grep per kernel bump. The honest summary: this is high-value tracking for internet-egress-heavy fleets and near-worthless for LB-fronted datacenter services — classify your traffic with section 4 before spending any attention on it.

---

## 7. Effectiveness test — how to judge adoption when it lands

Congestion control A/Bs are notoriously easy to fool yourself with — pre-register these gates.

**The A/B:** per-route or per-host split (`congctl` on matched egress routes, or 50/50 host split behind the same VIP), production traffic, minimum one week per arm to capture path diversity.

| Gate | Threshold | Meaning |
|---|---|---|
| Goodput per connection, bucketed by client RTT and loss class | Up in the lossy/long-RTT buckets — the only place v3 claims wins | The model pays where predicted |
| Retransmit rate (`ss -ti` / `nstat TcpRetransSegs`) | Not up in shallow-buffer paths (v1's known defect — v3 must show the fix) | The v1→v3 delta is real |
| RTT inflation under load (bufferbloat) | Down or flat vs CUBIC | Pacing works |
| **Fairness drill** (lab, not production): one v3 flow + one CUBIC flow through a shared constrained link | CUBIC keeps a sane share — v1 fails this test; v3 must pass it | The starvation defect is fixed |
| Short-flow p99 (request/response under 100 KB) | Neutral | No small-object tax |

**The pre-test that gates everything (run today):** the same A/B with in-tree **BBRv1** on your real egress. If v1 shows nothing over CUBIC in your traffic buckets, your paths don't reward path-modeling and v3 will show nothing either — close the tracker for this fleet and save the week.

**The honest failure mode:** aggregate averages improve while a specific bucket (short flows, or one region's paths) regresses. Congestion control changes are fleet-wide blast radius — bucket everything, never ship on the mean.
