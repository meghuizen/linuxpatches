# Net series: review

## Runtime results, 2026-09-23 (patchtest campaign, interleaved boots)

Per-patch kernels booted in a nested KVM guest, interleaved with base
boots; results in /usr/src/kbench/results/patchtest-* (UTC stamps
20260923-1427 onwards).  Kernel instructions per operation (perf stat).

| patch | result | decision |
|---|---|---|
| nf-next 1-3 (pt-nf, 2 boots vs 7 base) | new flow 16845 -> 16686/pkt (-155, below all 21 other boots); stream 14422 -> 14311 (inside spread); flush 1908 -> 1311/entry (-597); all FUNC checks pass (ctnetlink across resize, resize during churn, 8x silent, 9x warns once, non-init netns refused, dmesg clean) | KEEP, RFC dropped: now `[PATCH nf-next]` |
| net-next bridge (pt-bridge, 2 boots) | ARP flood 20321 -> 20159 insn/frame, -0.8%, inside the 1.7% base spread; its own keep rule needed -2% | REMOVED (no measurable difference), moved to removed/ |
| net-next Weyl dither, gro offload lookup | not in the campaign. Weyl: ~0.2-1 get_random_u16() per packet vs ~13 us CPU per packet, cannot be measured; gro: only frames without a GRO offload benefit, not reached by any test | REMOVED earlier (no measurable difference possible / not demonstrated), in removed/ |
| net-next CAKE slack (pt-cake, 2 boots) | slack 0 inert (inside base spread). Boot 1: timer expiries per packet -65% at 50 us, -67% at 100 us; boot 2: no change at any slack, because the 1 Gbit shaper was not the bottleneck in that boot | PENDING: 4 boots at 100 Mbit (shaper always limiting) queued after the campaign |


The nine original patches were reworked into two series plus two drops.
All files are under this directory:

- `nf-next/`: `[RFC PATCH nf-next 0/3]`, the three conntrack patches.
  They go to netfilter-devel, not straight to net-next.  Branch
  `sub-net-nf`.
- `net-next/`: `[RFC PATCH net-next 0/4]`, cake x2, gro, bridge.
  **HOLD, do not post** until TESTS-TO-RUN.md T1-T4 have run.  Branch
  `sub-net-netnext`.
- `dropped/`: the flowtable patch, kept with a note.  The ext-prealloc
  patch is dropped with no file.
- Branch `sub-net` = nf-next 1-3 followed by net-next 1-4 (7 commits).
  Every commit builds its touched objects with W=1 and no warnings.  The
  original 9 commits are preserved in `sub-net-orig-backup`.

| old # | new | subject | rec. | impact | evidence |
|---|---|---|---|---|---|
| 4 | nf-next 1/3 | netfilter: conntrack: hash IPv4 tuples as two words | SEND as RFC | medium: IPv4 conntrack lookup, per packet | instruction counts (perf on the kernel's compiled siphash, x86_64 + i386); static counts A53/RISC-V |
| 8 | nf-next 2/3 | netfilter: conntrack: keep the unscaled tuple hashes for teardown | SEND as RFC (after T7) | low: per deleted entry | objdump (2 calls removed), perf counts of the removed calls, pahole |
| 9 | nf-next 3/3 | netfilter: conntrack: warn when nf_conntrack_max outgrows the hash table | RFC | low: diagnostic | not tested; the old rate numbers are unusable |
| 1 | net-next 1/4 | net/sched: sch_cake: add a timer slack attribute | HOLD | low: only when set | not tested; the old version had a bug |
| 2 | net-next 2/4 | net/sched: sch_cake: use a Weyl sequence for the quantum dither | HOLD | low: not demonstrated | not tested |
| 5 | net-next 3/4 | net: gro: find the offload before preparing the gro list | HOLD | low | not tested |
| 6 | net-next 4/4 | net: bridge: skip the ARP proxy path when no port uses it | HOLD | low | not tested; T4 would settle it |
| 3 | dropped/ | netfilter: nf_flow_table: hash only the key head... | DROP | - | measured: +32 insn/lookup for VLAN/PPPoE flows |
| 7 | - | netfilter: conntrack: size the extension prealloc... | DROP | - | analysis: extra krealloc per flow in common configs |

checkpatch.pl --strict on all seven exported patches: 0 warnings,
0 checks.  The only error on each is "Missing Signed-off-by", which is
intended: the submitter adds it.

---

## nf-next 1/3: hash IPv4 tuples as two words (old 4)

- **Recommendation: SEND as part of the RFC nf-next series.**  The
  change is small.  The saving shows up in the kernel's own compiled
  code on both architectures measured, and no architecture gets slower:
  siphash() is the 64-bit SipHash everywhere, so i386 gains most (-359
  instructions per hash).
- **Impact: medium.**  IPv4 conntrack lookup, once per packet, plus
  confirm and NAT on new flows, on routers and hosts with conntrack
  loaded.  Not measured as wall-clock.
- **Evidence:** `tests/insn-count/results-x86_64.txt` and
  `results-i386.txt`.  Per call, the siphash functions from
  lib/siphash.o of this tree cost:
  - x86_64: 267 -> 175 per loop iteration (256 -> 164 once the 11
    loop instructions are subtracted).
  - i386: 986 -> 627.

  objdump of hash_conntrack_raw() (`tests/objdump-pahole.txt`) shows the
  packing adds 12 instructions against 2 on x86_64, and about 24 against
  3 on i386.  IPv6 gets a cmp+je.  The hashbench.c static counts
  reproduce the README's siphash rows (x86_64 228, README said 229).
  No usable runtime data: the flowtable/churn sections ran a combined
  kernel and their two pairs contradict each other.
- **Likely objections:**
  - "Show a packet rate": answered only by T6 (instruction counts per
    packet in the guest).
  - "IPv6 pays a branch": 2 instructions, stated in the changelog.
  - Packing l3num is redundant on the AF_INET branch.  The compiler
    folds it to a constant (`or $0x200`), and it is kept so the packed
    message stays self-describing.
- **Correctness checked:**
  - The hash is only used via scale_hash()/reciprocal_scale() as a
    bucket index, and every user goes through hash_conntrack_raw(), so
    insertion and lookup always agree.  grep confirms there is no other
    computation of the conntrack tuple hash.
  - The packing is injective over (src ip, dst ip, sport, dport,
    protonum).  The key is unchanged, including zone and net_hash_mix.
  - Endianness does not matter because the value never leaves the host.
  - nf_conntrack_hash_resize() rehashes through the same function.

## nf-next 2/3: keep the unscaled tuple hashes for teardown (old 8)

- **Recommendation: SEND as RFC, after T7** (functional check of
  ctnetlink insert/delete and resize under churn).
- **Impact: low.**  It saves two hash_conntrack_raw() calls per deleted
  entry.  Per removed call that is about 164+ instructions for IPv4 on
  x86_64 with 1/3 applied, or 256+ for IPv6.  No wall-clock data.
- **Evidence:** objdump call-site count (`tests/objdump-pahole.txt`):
  `__nf_ct_delete_from_lists` goes from 2 calls to 0.  pahole: struct
  nf_conn grows 248 -> 256 on x86_64 (all conntrack options) and
  196 -> 204 on i386.  The slab object is unchanged at 256 / 224 bytes
  because of SLAB_HWCACHE_ALIGN; the i386 defconfig has 32-byte lines.
- **Bug found and fixed:** the original patch set hash_raw[] only in
  __nf_conntrack_confirm().  nf_conntrack_hash_check_insert() (ctnetlink
  `conntrack -I`, bpf_ct_insert_entry) also puts entries on the lists.
  For those, hash_raw[] was never written.  It sits before
  `__nfct_init_offset`, so it is not zeroed, and with
  SLAB_TYPESAFE_BY_RCU it held stale data.  Deleting such an entry would
  take the wrong bucket locks while unlinking: a list-corruption race.
  The combined `everything` kernel measured on 2026-09-22 contained the
  buggy version.  The net-bench workload never inserts via ctnetlink,
  so it could not have hit it.  The fix computes both unscaled hashes in
  nf_conntrack_hash_check_insert() too.  That also let the now-unused
  hash_conntrack() helper be removed; W=1 caught it.
- Also removed the WARN_ON_ONCE(!confirmed) on the teardown path.
  clean_from_lists() already depends on that invariant, and a WARN on
  every delete adds nothing a maintainer would want.
- **Uncontended layout check:**
  - Before: tuplehash[0] 16-72, tuplehash[1] 72-128, status/ct_net
    128-144.
  - After: tuplehash[0] 24-80, tuplehash[1] 80-136.
  - A lookup reads the tuple, zone (line 0), ct_net and status (line
    2).  That is lines {0,1,2} before and after, in both directions.
  - The refcount and timeout stay on line 0.
- **Likely objections:**
  - "8 more bytes in nf_conn for a teardown saving."  Answered for the
    two configs checked.  A config where sizeof(nf_conn) is already a
    multiple of the cache line would grow a line; none was found, but
    not every config was enumerated.
  - "Stored hash could go stale."  The tuples never change after
    insertion (NAT alters the reply tuple before confirm only), and
    zone, netns and hash_rnd are fixed.
- **Correctness checked:**
  - Every path that inserts into nf_conntrack_hash: confirm, clash
    resolution (runs inside confirm after the store),
    nf_conntrack_hash_check_insert (fixed), and resize (moves nodes;
    the unscaled value is unchanged).
  - Delete paths: all go through __nf_ct_delete_from_lists.
  - The nf_conntrack_generation retry still covers a racing resize.

## nf-next 3/3: warn when nf_conntrack_max outgrows the hash table (old 9)

- **Recommendation: RFC.**  It is a policy question for Florian/Pablo:
  warning plus docs, or docs only.  Either hunk stands alone.
- **Impact: low**, diagnostic.
- **Evidence: none usable.**  The old changelog quoted ~964k vs ~604k
  new flows/s ("-60%" at a max/buckets ratio of 24).
  - Those are the means of the `over` (320000/262144 = 1.22) and
    `under` (6400000/262144 = 24.4) rows of the 04:51:08
    everything boot.
  - All four of those rows carry "!! control moved" (spread 100%, 43%,
    68%, 22%).
  - The next everything boot (04:56:18) shows the opposite direction:
    under 1.73M/1.92M against over 1.22M/1.83M.
  - The `over` regime also includes early_drop eviction, so the two
    regimes differ in more than chain length.
  - The number is dropped.  The changelog now states only the mechanism
    and that the configuration is reachable.  T8 would produce a real
    number.
- **Changes from the original:**
  - The measurement narrative moved out of the code comment.
  - The comparison uses u64, so `8 * hsize` cannot overflow.
  - The message is shorter.
  - Documentation/networking/nf_conntrack-sysctl.rst is updated in the
    same patch.
- **Checked:**
  - nf_conntrack_max is global, and non-init netns get the sysctl 0444,
    so only init_net can trigger the warning.
  - The threshold 8 is the max_factor nf_conntrack_init_start() uses
    when hashsize is given.
  - Both sysctl tables (net.netfilter.* and net.nf_conntrack_max) use
    the handler.
  - The warning is rate-limited.  A boot script that sets a large value
    every boot will log once per boot, which a maintainer may still
    dislike.

## net-next 1/4: sch_cake timer slack attribute (old 1): HOLD

- **Recommendation: HOLD.**
  - There is no runtime evidence for the fixed version.
  - It is a new UAPI attribute with no userspace user: iproute2 has no
    keyword for it, and netdev will ask for the iproute2 patch.
  - The earlier version had a bug that invalidates every CAKE number
    attributed to "patch 1" so far.
- **Bug found and fixed:** `qdisc_watchdog_schedule_range_ns(wd,
  expires, delta_ns)` takes a delta.  The old code passed
  `next + slack`, an absolute CLOCK_MONOTONIC time, so the effective
  slack was the uptime in ns.
  - With the default slack 0 the patch was therefore not inert.  The
    watchdog fired only at the next unrelated hrtimer interrupt after
    `next`, and re-arms were skipped whenever a timer was queued.
  - On an idle NOHZ CPU that could hold packets far longer than the
    shaper intends.
  - Fixed to pass `slack`.
- **Impact: low**; nothing changes unless the attribute is set.
- **Evidence:** none for the fixed version.  T1 checks that slack 0 is
  inert; T3 measures the effect with slack set.
- **Likely objections:**
  - Needs iproute2.
  - Should cake_policy get `strict_start_type` for new attributes?
    Raised below the `---`.
  - Toke will want numbers showing that coalescing matters outside a
    nested VM.
- struct cake_sched_config grows 56 -> 64 bytes; it is a per-qdisc
  config, not on the per-packet path's hot lines.

## net-next 2/4: sch_cake Weyl dither (old 2): HOLD

- **Recommendation: HOLD** until T2.  DROP if T2 shows nothing.
- **Impact: low**, not demonstrated.
- **Attribution of the 63%:** this patch was the natural suspect once
  patch 1 was thought inert.  By arithmetic it cannot account for more
  than a fraction of a percent at the net-bench load: about 0.22 to 1
  get_random_u16() call per packet, a few tens of cycles each, against
  about 13 us of CPU per packet.  See TESTS-TO-RUN.md T1.  The cake
  section has no control normalisation at all.  With two senders
  saturating two CPUs, ticks/kpkt is roughly the inverse of sender
  throughput (baseline ~150k pkt/s, everything 380-540k pkt/s), so it
  reacts to anything on the send/forward path.
- **Changed:** the u16 now sits in the hole after flow_quantum, so
  cake_tin_data does not grow (pahole).  The original placement grew it
  by 8 bytes.
- **Likely objection:** determinism across flows (see the note below
  its `---`).  The bias is bounded by n/65536 byte per refill.
- **Correctness:** tin data is zeroed at allocation.  The field is only
  touched under the qdisc lock (enqueue and dequeue).  The step 0x9e37
  is odd, so the period is the full 65536.

## net-next 3/4: gro offload lookup first (old 5): HOLD

- **Recommendation: HOLD**, probably DROP after T5.
- **Impact: low.**  It saves one walk of the bucket's held skbs for
  frames without a GRO offload (ARP, PPPoE session), and nothing when
  the bucket is empty.
- **Evidence:** none.  The net-bench GRO section did run in all four
  2026-09-22 reports (gro=on vs gro=off, UDP stream).  But UDP has a
  ->gro_receive, so the section never reaches the path this patch
  changes.  Its rows are also mostly "control moved": on/off 2.59M/2.18M,
  1.42M/1.89M, 1.29M/3.04M, 3.07M/2.91M.  It says nothing about this
  patch.
- The old changelog's paragraph about skb->hash == 0 was removed: the
  patch does not change that case for protocols with an offload.
- **Correctness:**
  - Every reader of NAPI_GRO_CB(p)->same_flow was checked (grep over
    net/).  They are all ->gro_receive callbacks, which still run after
    gro_list_prepare().
  - gro_list_prepare() takes a const skb.
  - It now runs under rcu_read_lock(), which it does not care about.

## net-next 4/4: bridge ARP early return (old 6): HOLD

- **Recommendation: HOLD**, pending T4: SEND if the per-frame delta is
  at least 2%, otherwise DROP.
- **Impact: low**: ARP frames on bridges with no proxy_arp or
  neigh_suppress port.
- **Evidence:** none.  The generator (tests/arpflood) is written,
  compiled, not run.
- **Correctness checked:**
  - Every place proxyarp_replied or grat_arp is set needs one of:
    BROPT_NEIGH_SUPPRESS_ENABLED, BR_PROXYARP (ingress port),
    BR_PROXYARP_WIFI (dst port), or br_is_neigh_suppress_enabled(dst),
    which needs BR_NEIGH_SUPPRESS or BR_NEIGH_VLAN_SUPPRESS on a port
    and so implies BROPT_NEIGH_SUPPRESS_ENABLED.
  - The early return comes after both fields are reset.
  - Flag changes reach br_port_flags_change() from netlink (changed
    mask) and sysfs (BIT(bitnr)), and both now recalculate on the
    proxy ARP bits.
  - Port removal does not recalculate; that was already true for neigh
    suppression, and it only leaves the early return disabled.
  - br_dev_xmit()'s call is already gated.
  - Skipping pskb_may_pull() is safe: later consumers pull for
    themselves.

## Dropped: flowtable key head (old 3)

Measured on the in-kernel code: flow_offload_hash() goes from 321 to
276 instructions per call for plain flows, but from 321 to 353 for a
flow with one VLAN/PPPoE encap (`tests/insn-count`).  PPPoE WAN with
software flow offload is a common home-router configuration, so this
slows a common path.  The old changelog's 274 -> 134 counted only the
jhash rounds.  It left out the memchr_inv() call the patch adds, and
hashbench.c's "unrolled" jhash functions are not unrolled by GCC 15.2
at -O2.  A reworked predicate made of inline loads would shrink the
cost but not remove it.

## Dropped: conntrack extension prealloc from compiled-in types (old 7)

The changelog's two claims are wrong:
- "A kernel with events compiled in reserves what it reserved before."
  The new value is ALIGN(16 + 4 + 32, 8) = 56 bytes, i.e. kmalloc-64,
  not 128 (pahole sizes: nf_ct_ext header 16, nf_conn_nat 4,
  nf_conntrack_ecache 32, acct 32, helper 56, tstamp 16, labels 16).
- "every new flow does a kmalloc-128 and the matching kfree ... that
  buys nothing."  The alloc/free pair remains; only the size changes.

The reserve exists so that later extensions fit without krealloc().
With a 64-byte capacity, several ordinary configurations need an extra
krealloc (allocate, copy, free) per flow where 128 bytes needed none:
- events listener + acct + NAT (84 bytes);
- any helper + NAT (76);
- acct + tstamp + NAT (68).

That is a per-flow regression in working configurations, traded for
64 bytes per flow in minimal ones.

---

## Problems found in the existing data and notes

1. **CAKE 63% is misattributed.**  The old patch 1 was not inert: it
   passed an absolute time as the hrtimer slack (see net-next 1/4).
   That is the most likely cause.  Patch 2 cannot account for it by
   arithmetic.  Neither is established until T1 runs.  The cake section
   also has no control, and its ticks/kpkt tracks sender throughput.
   The README line "Patch 1 is the largest single win" is unsupported.
2. **Patch 9's -60%** comes from one boot whose four rows are all
   flagged "control moved", and the next interleaved pair shows the
   opposite direction.  It is unusable.
3. **The conntrack churn workload is not "every datagram a new
   5-tuple."**  The destination port cycles over 60000 values and there
   are 16 sockets, so 3.2M sends produce only 960000 distinct tuples
   (the reports' `ct=960000` matches).  About 70% of the datagrams are
   lookups of existing entries.
4. **The flowtable section never offloads a flow.**  The sink never
   replies, so the UDP entry never becomes established and
   `flow add @ft` never fires.  Every packet is a flowtable lookup miss
   followed by a conntrack lookup, so it exercises old patches 3 and 4
   together.  That is fine for "per-packet hash", but it is not
   "established forwarding through the flowtable".
5. **The GRO section cannot exercise patch 5** (UDP has a GRO offload).
6. **The old patch 8 had a real bug** on the ctnetlink/bpf insert path,
   present in the measured combined kernel.
7. **The old patch 3 figures left out the predicate's cost**, and the
   hashbench.c jhash rows do not reproduce.
8. **The old patch 7 changelog claims are false** (see above).
