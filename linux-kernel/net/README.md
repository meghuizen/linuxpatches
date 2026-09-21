# Networking patches — the router forwarding path

Eight patches against **Linux 7.3-rc3**, aimed at a home router: a
four-core ARM Cortex-A53 at 2 GHz, 1 GB of RAM, forwarding 1–2.5 Gbit/s.

Nothing here is device- or driver-specific. Every patch is in generic
`net/` code and is equally valid on x86_64.

## Why this hardware changes the answer

Cortex-A53 is **in-order** and **ARMv8.0**, which has no LSE atomics. Two
consequences that do not apply to an out-of-order x86 server:

- Instruction count matters much more, because there is no out-of-order
  window to hide latency in.
- Every atomic is an `ldxr`/`stxr` retry loop, not a single `lock xadd`.

With only four cores, per-operation cost and memory footprint matter more
than cross-CPU contention.

## The traffic that actually arrives

The working assumption is a modern household: TCP for HTTP, HTTPS and
HTTP/2; **UDP for HTTP/3 and QUIC**; DNS, NTP, unicast and multicast, ARP.

The QUIC shift is what makes this list look different from a 2015 one.
QUIC is UDP, it is encrypted, and it has **no teardown the router can
see** — no FIN, no RST. A conntrack entry therefore survives until its
idle timeout, 120 s for a replied UDP flow. Where HTTP/2 had one TCP
connection with an observable close, HTTP/3 leaves many UDP tuples
lingering.

The second-order effect is that short UDP exchanges never live long
enough to be offloaded. A DNS query or a QUIC handshake is a flow of two
packets: it pays the full conntrack setup and teardown, pays the
flowtable hash and miss on every packet, and then falls through to the
software path anyway. **The dominant cost of modern router traffic is
per-flow, not per-packet.** Five of the eight patches attack that.

## The patches

| # | Subsystem | What it does |
|---|---|---|
| 1 | `sch_cake` | `TCA_CAKE_TIMER_SLACK`, so the shaper's hrtimer expiries can coalesce |
| 2 | `sch_cake` | Weyl sequence instead of `get_random_u16()` in the deficit refill loop |
| 3 | `nf_flow_table` | Hash 42 key bytes instead of 88 when the flow is neither encapsulated nor tunnelled |
| 4 | `nf_conntrack` | Pack the IPv4 tuple into two words: 8 SIPROUNDs instead of 14 |
| 5 | `net/core/gro` | Look up the offload before walking the GRO list, not after |
| 6 | `bridge` | Skip the proxy-ARP path when no port has asked for it |
| 7 | `nf_conntrack` | Size the extension prealloc from the types compiled in, not a flat 128 |
| 8 | `nf_conntrack` | Save the raw tuple hashes at confirm; teardown rescales instead of rehashing |

Patch 1 is the largest single win and the least interesting technically:
CAKE arms a timer after nearly every shaped packet with **zero slack**, so
the hrtimer layer can coalesce nothing and each packet costs an arm, an
interrupt and a softirq round trip. `sch_fq` has had the same knob for
years. Default is 0, so existing setups are bit-identical.

Patches 3 and 4 are the same observation in two subsystems: **the hot
hashes are computed over keys sized for the general case while the common
case leaves most of the key zero.** IPv6-sized address unions holding four
useful bytes; tunnel and encapsulation fields that are zero on a plain
router. Both fixes keep the hash function and its key, shorten only the
message, and still compare the full key on a hit — so a collision costs a
comparison and can never produce a wrong match.

## Why patch 8 is safe when sharing hashes generally is not

Each subsystem hashes under its own secret -- `hashrnd` in the flow
dissector, `nf_conntrack_hash_rnd`, `nf_nat_hash_rnd`, `inet_ehash_secret`,
a per-table `hash_rnd` in every rhashtable. That separation is deliberate:
an attacker who recovers one key gains nothing against the others. Feeding
one computed hash to several subsystems would collapse that into a single
point of failure, so **do not** "optimise" the repeated hashing across
subsystem boundaries.

Patch 8 is not that. It caches one subsystem's own value, under its own
key, for reuse a few microseconds later in the same subsystem, where the
recomputation produces a provably identical result. It also caches the
*raw* hash rather than the scaled one, because scaling depends on the
table size and a resize must still be picked up.

## Backwards compatibility

No UAPI is removed or changed. Patch 1 adds one optional netlink
attribute; old userspace does not send it and ignores it on dump, and its
default reproduces today's behaviour exactly. Everything else is internal.

All eight compile on x86_64. Struct offsets quoted in the commit messages
were taken from a built object, not from reading the header.

## Cross-ISA instruction counts

`hashbench.c` carries the kernel's siphash and jhash primitives copied
verbatim, so the generated code can be compared across targets without
building a kernel for each. Straight-line instruction counts, padding and
`endbr64` excluded, GCC 15.2 at `-O2`:

| hash call | x86_64 | i386 | A53 | rv64gc | rv64gc_zbb |
|---|---|---|---|---|---|
| conntrack 39 B, 14 SIPROUNDs | 229 | 733 | 177 | 411 | 245 |
| conntrack 16 B, 10 SIPROUNDs (patch 4) | 164 | 514 | 128 | 297 | 179 |
| flowtable 88 B, 7 mixes (today) | 274 | 280 | 184 | 334 | 236 |
| flowtable 42 B, 3 mixes (patch 3) | 134 | 139 | 94 | 166 | 116 |

siphash is **2-4**: two rounds per eight-byte block and four at the end.
39 bytes is four blocks plus a tail, so 14 rounds; 16 bytes is two
blocks, so 10.

Two things fall out of the table.

**i386 pays four times what x86_64 pays for siphash, and jhash barely
differs.** siphash is 64-bit add/xor/`rol64`; a 64-bit rotate on a 32-bit
ISA is several instructions, and there are six per round. jhash is 32-bit
throughout, so it costs the same either way. This is exactly why
`lib/siphash.c` compiles a true 32-bit HalfSipHash on 32-bit targets.

**RISC-V without Zbb has no rotate instruction at all.** Every `rol64`
becomes shift, shift, or. `rv64gc` is 359 instructions against the A53's
157 for the same hash; `rv64gc_zbb` brings it to 217. Anyone building this
kernel for a RISC-V router wants `CONFIG_RISCV_ISA_ZBB`.

## What was measured, and what was not

The instruction counts above are real, taken from disassembly. What is
**not** measured is how they translate into time on the target: no
profile, no packet rate, no cycle counts.

The gate that would settle them is `perf stat` on the real device under
real traffic. On the machine this was written on, the guest cannot resolve
it: nested virtualisation amplifies cross-CPU cacheline traffic enough to
manufacture contention that does not exist on hardware.

## Rejected, with reasons

Worth recording, because several are things that look obviously right.

**Memoizing CAKE's two host siphashes.** The biggest per-packet win on
paper, around 450 instructions. Dropped on security grounds: the cache
would be indexed by attacker-controllable address bits, so an adversary
varying source addresses forces a 100 % miss rate and every packet then
pays probe plus siphash plus insert. It improves the average case by
making the adversarial case worse, on the side of the box that faces the
internet. Wrong trade for a shaper that is already the CPU bottleneck.

**Skipping the first UDP hash2 probe for a wildcard-bound resolver.** The
hash has to be computed anyway to locate the slot whose count you would
test, so the only saving is walking an empty hlist — about three
instructions, not the 3–6 % it first looked like.

**Anything touching dst or skb refcounts on the forwarding path.** Already
free. `skb_unref()` and `skb_data_unref()` both short-circuit,
`__mkroute_input()` uses `skb_dst_set_noref()`, and `IFF_XMIT_DST_RELEASE`
is the default. A forwarded packet does approximately zero atomics.

**Making CAKE lockless.** Infeasible — its shaper state is global by
construction — and unnecessary: since 7.3, `__dev_xmit_skb()` batches
through a lock-free llist, so a CPU that loses the race pays one
`try_cmpxchg`, not a contended spin.

**Anything in the FIB or LC-trie.** `fib_lookup()` already short-circuits
rules when there are no custom ones, and a sub-twenty-prefix trie is three
to five L1-resident loads.

**Replacing siphash with jhash in conntrack.** The single biggest
instruction-count win available, and the reason it is there is
hash-flooding resistance on a box facing the internet. No.

**Precomputing `SIPHASH_CONST_i ^ key` into the key structure.** The
preamble rebuilds four 64-bit constants on every call: 16 instructions on
the A53 (`mov` plus three `movk` each), 15 % of `siphash_2u64`. Storing
them pre-XORed makes the preamble four loads. `sipvalidate.c` confirms it
is bit-exact — it reproduces the reference vector from
`lib/tests/siphash_kunit.c` and matches the current form across 40 M
random key/input pairs — and it saves 19 instructions on the A53 and 26
on RISC-V. But it saves only **2** on x86_64, where `movabs` is one
instruction, and the wall-clock benchmark there is **13.6 % slower**: four
dependent loads cost more than four independent immediates. A change that
measurably regresses the architecture most maintainers test on, in
exchange for an instruction count on one that was not timed, is not
worth proposing. Revisit only with wall-clock numbers from real A53
hardware.

**Lowering the UDP conntrack timeouts for QUIC.** Already sysctl-tunable.
A code change would be a behaviour change; this is a tuning note, not a
patch.

## Tuning notes that are not patches

These plausibly matter more than several of the patches above.

- **`nf_conntrack_max` is 8192 on a 1 GB router**, derived from RAM at
  init. QUIC's 120 s idle timeout makes that ceiling reachable, and
  `early_drop` then preferentially evicts non-ASSURED entries — the fresh
  DNS and QUIC handshakes. Raising it costs about 400 bytes per flow.
- **Check whether the NIC sets `skb->hash` on ingress.** GRO's bucket
  index and its per-entry fast reject are both `skb_get_hash_raw()`, a
  bare read of that field. If it is zero, every packet lands in bucket 0
  and no comparison can be skipped. This dominates every GRO-related item
  here.
- **Align XPS so `alloc_cpu` matches the TX-completion CPU**, or set
  `net.core.skb_defer_max=0`. When they differ, each packet pays two
  remote LL/SC operations and possibly an IPI.
