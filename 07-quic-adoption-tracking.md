# Task 7 — Adoption tracker: in-kernel QUIC

**What this document is for, in one sentence:** track the upstream in-kernel QUIC implementation so we adopt it the release it lands — because QUIC is the one major protocol our kernel accelerates *nothing* for today, and the CPU gap versus TCP is large.

| | |
|---|---|
| Type | Tracking document — nothing to build; re-validate on every kernel bump |
| State in Linux 7.2 | **Absent** — verified: no `net/quic` in the tree |
| Who is driving it | Upstream netdev series ("in-kernel QUIC"), long-running review |
| Why we care | QUIC is HTTP/3's transport; .NET's QUIC stack (MsQuic via `System.Net.Quic`) runs it entirely in userspace today |

---

## 1. Background: why QUIC is expensive without kernel help

TCP earned three decades of kernel acceleration. QUIC gets none of it, because QUIC lives in userspace on top of plain UDP sockets:

| Cost per unit of traffic | TCP today | QUIC today |
|---|---|---|
| Segmentation | GSO/TSO — one large buffer in, NIC splits | Userspace builds each packet (unless the app opts into UDP GSO) |
| Receive coalescing | GRO — many packets merged before the stack | Per-datagram delivery, per-datagram wakeups |
| Crypto | kTLS, possibly NIC offload | Userspace crypto per packet, no offload path |
| Syscalls | One `send()` moves megabytes | `sendmsg`/`recvmsg` per datagram batch |
| ACK/loss handling | In-kernel, softirq | Userspace round-trips through the scheduler |

Commonly reported result: **2-3x the CPU of TCP for the same throughput**. As HTTP/3 share grows, that multiplier lands on every internet-facing service. An in-kernel QUIC implementation (socket family, kernel packet processing, kTLS-style split where the TLS handshake stays in userspace and the kernel takes over the data path) is the structural fix — the same playbook as kTLS.

## 2. Verified state in this tree (7.2, checked 2026-08)

```bash
cd /mnt/data/linux-src/linux-7.2
ls -d net/quic          # -> does not exist
```

What 7.2 DOES have — the interim mitigations (all verified present earlier in this audit or long-stable):

- **UDP GSO** (`UDP_SEGMENT`) and **UDP GRO** — the single biggest userspace-QUIC lever; MsQuic supports it on Linux
- **io_uring** with multishot receive and `SEND_ZC` — batch the datagram syscalls away
- **sch_fq pacing** — QUIC libraries can rely on kernel pacing rather than userspace timers

## 3. What to watch, mechanically

Re-run on every kernel version bump (put it in the upgrade checklist):

```bash
# 1. Did it land?
ls -d net/quic 2>/dev/null && echo "QUIC LANDED - begin adoption review"
grep -rn "IPPROTO_QUIC\|AF_QUIC\|SOL_QUIC" include/uapi/linux/ | head

# 2. Is it coming? Search the list archives:
#    https://lore.kernel.org/netdev/?q=%22net%3A+quic%22
#    Watch for: series version number climbing, maintainer (netdev) acks,
#    and a MAINTAINERS entry in the diffstat - that is the "one or two
#    releases away" signal.
```

## 4. Adoption checklist for when it lands

Do not enable it fleet-wide on day one. Work through:

1. **Design check:** does the merged version keep the handshake in userspace (kTLS model)? That determines whether existing TLS libraries keep working.
2. **Library support:** MsQuic (and therefore .NET) needs a kernel-QUIC backend before we see any benefit — track the msquic repo for Linux kernel-offload work. Kernel support without library adoption does nothing for us.
3. **Benchmark the claim:** same HTTP/3 load, userspace vs kernel path, measure CPU-per-Gbit — the entire justification is that multiplier from section 1.
4. **Maturity gates:** first release = expect sharp edges. Check for follow-up fixes in the next -stable series before production.
5. **Fallback story:** confirm the userspace path still works with the feature compiled in but unused.

## 5. What to do meanwhile (today, no kernel change)

1. Ensure the QUIC library actually uses **UDP GSO/GRO** — in MsQuic this is the difference between competitive and terrible; verify with `strace -c` (datagram-sized writes = misconfigured).
2. Batch UDP I/O through **io_uring** where the library supports it.
3. Keep internet-facing QUIC on dedicated frontends so the userspace CPU tax has a bounded blast radius, with TCP/kTLS inside.

## 6. Realistic expectation

This is the largest open networking item in the audit, and completely outside our control except for tracking and early testing. When it lands, the win is TCP-class acceleration for the protocol the internet is migrating to; until then, UDP GSO adoption in the library recovers a meaningful slice of the gap for one config line's worth of effort.

---

## 7. Effectiveness test — how to judge adoption when it lands

Pre-register the decision criteria now, so the day-one evaluation is mechanical rather than motivated reasoning.

**The A/B:** identical HTTP/3 workload (same TLS config, same object mix, same client fleet), userspace MsQuic vs kernel-QUIC backend, 5 runs each side.

| Gate | Threshold | Meaning |
|---|---|---|
| CPU per Gbit served | The whole justification — demand a double-digit % drop; section 1's table predicts large | Adopt if met |
| Syscalls per MB (`perf trace -s` on the server) | Collapse vs userspace path | The mechanism is real |
| p99 handshake and request latency | Neutral or better | No latency regression hiding under the CPU win |
| Soak: 24h under production-shaped load | No stability deltas, no memory growth | First-release maturity check |
| Fallback drill: feature compiled in, library pinned to userspace path | Identical to old baseline | Safe rollback exists |

**Interim effectiveness (run today, no kernel change):** the UDP GSO check. `strace -c -p <server>` — if `sendmsg` count ≈ packet count, GSO is off; enable it in MsQuic and re-measure. Expected: sendmsg count drops by the batch factor and CPU/Gbit follows. This measurement doubles as your baseline for the eventual kernel-QUIC A/B.

**The honest failure mode:** kernel QUIC lands but MsQuic has no backend for it yet — then there is nothing to test for .NET services, and the tracker stays open regardless of how good the kernel numbers look elsewhere.
