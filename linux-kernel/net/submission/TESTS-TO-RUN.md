# Net series: tests for the coordinator to run

Run one boot at a time, in the order shown (interleaved).  All kernels
are built from branches in /usr/src/sub-net, all based on 518e5b794c06:

| branch | contents |
|---|---|
| (base) `518e5b794c06` | baseline |
| `test-cake-p1-asrun` | the old cake timer-slack patch **as it ran on 2026-09-22** (passes `next + slack` as the range) |
| `test-cake-p1` | fixed cake timer-slack patch (net-next 1/4) only |
| `test-cake-p2` | cake Weyl dither (net-next 2/4) only |
| `test-gro-p5` | gro reorder (net-next 3/4) only |
| `test-bridge-p6` | bridge ARP early return (net-next 4/4) only |
| `sub-net-nf` | the three nf-next patches |

Use perf counts (instructions, event counts) as the result.  Rates and
`ticks` are reported only for continuity with net-bench.  On this host
they move with the host clock, as the evidence rules say.

---

## T1 (decisive): where did the 63% CAKE reduction come from?

Why: the 2026-09-22 pairs show 1.30-1.54 ticks/kpkt on baseline against
0.40-0.57 on `everything`.  Two findings:

- The old patch 1 called
  `qdisc_watchdog_schedule_range_ns(wd, next, next + slack)`.  The third
  argument is a *delta*, so the watchdog got a slack equal to the
  current CLOCK_MONOTONIC value, i.e. seconds of uptime.  Two things
  follow.  The hrtimer fires at the next unrelated timer interrupt after
  `next`.  And `qdisc_watchdog_schedule_range_ns()` skips re-arming
  whenever a timer is already queued (`softexpires - expires <=
  delta_ns`).  Both remove most timer programming and expiries, and in
  a nested-KVM guest those are expensive.  So the patch was not inert
  with slack 0.  This is the most likely cause.
- Patch 2 alone cannot plausibly explain it.  With 2 flows from one
  host, host_load <= 2, and the quantum per refill is 1514/2 = 757 bytes
  against 170-byte packets.  That is about 0.22 get_random_u16() calls
  per packet, or at most 1 per packet if every enqueue re-activates the
  flow.  get_random_u16() is batched per CPU (one ChaCha20 refill per 48
  values, estimated a few tens of cycles per call).  At ~13 us of CPU
  per packet on baseline, that is well under 1%.

Kernels, 8 boots: base, test-cake-p1-asrun, test-cake-p2, test-cake-p1,
base, test-cake-p1-asrun, test-cake-p2, test-cake-p1.

Command in the guest (the same topology and load as the net-bench cake
section, plus hrtimer and softirq event counts per delivered packet):

    /usr/src/linuxpatches/linux-kernel/net/submission/tests/cake-slack/cake-run-in-guest.sh

Expected:
- test-cake-p1-asrun: ticks/kpkt near 0.4-0.57, and hrtimer_start/pkt
  and hrtimer_expire/pkt far below baseline.
- test-cake-p2 and test-cake-p1 (slack 0): within noise of base on
  every counter.  insn/pkt is expected to differ by under 1%.

What changes the recommendation:
- If test-cake-p2 reproduces the reduction, the attribution is wrong.
  Patch 2 then becomes the candidate with a measured effect.  Re-check
  the arithmetic above before believing it.
- If test-cake-p1 with slack 0 differs from base, the fixed patch 1 is
  not inert and must not be sent.
- If neither asrun nor p2 reproduces it, the effect is in another patch
  of the combined kernel (client or vfs series).  Tell those agents.

## T2: patch 2 in the regime it targets (many bulk flows behind one host)

Kernels, 4 boots: base, test-cake-p2, base, test-cake-p2.

    .../tests/cake-slack/cake-run-in-guest.sh "" 32

(32 senders, one host, so host_load = 32 and the quantum per refill is
about 47 bytes.)

Expected: insn/pkt lower on test-cake-p2, by at most a few percent.
If the difference is below run-to-run noise, DROP patch 2.  If it is
clearly above noise, add the number to its changelog and move it to
RFC.

## T3: patch 1 with slack actually set

Kernel: test-cake-p1, 1 boot (a count-based comparison within one boot
is acceptable).

    for s in 0 10000 50000 100000; do
      .../tests/cake-slack/cake-run-in-guest.sh $s
    done

Expected: hrtimer_expire/pkt and insn/pkt fall as the slack grows.
Also record latency under load: ping from csl to 10.99.2.2 while the
senders run, and report the p99.  Whatever the result, patch 1 stays
HOLD until an iproute2 patch exists.  The result decides whether to
write one.

## T4: bridge ARP early return (net-next 4/4)

Kernels, 4 boots: base, test-bridge-p6, base, test-bridge-p6.

    N=2000000 .../tests/arpflood/run-in-guest.sh

Expected: kernel instructions per ARP frame lower on test-bridge-p6.
The gap should be roughly the cost of neigh_lookup() + br_fdb_find_rcu()
+ header parsing, a few hundred instructions against a per-frame total
of several thousand.  If the gap is under 2% of the per-frame count,
DROP.  Otherwise SEND with the number in the changelog.

Also check the behaviour on test-bridge-p6 (1 boot):

    ip link set ap1 type bridge_slave proxy_arp on
    # re-run arpflood; ap1x should now receive proxy replies
    # for targets whose neighbour entry resolves to a port
    ip link set ap1 type bridge_slave proxy_arp off

Expected: identical replies to base.

## T5: gro reorder (net-next 3/4), low priority

Kernels, 2 boots: base, test-gro-p5.  In one netns pair, run
`ethtool -K vr gro on` on the receive side (veth NAPI GRO).  Run a UDP
stream with `rx-udp-gro-forwarding on` so packets are held.  At the
same time, send arpflood frames into the same veth and use perf stat
to count kernel instructions per ARP frame on the NAPI CPU.

Expected: a difference only when ARP frames land in a bucket with held
skbs; probably not measurable.  If not measurable, DROP.

## T6: conntrack instruction counts (nf-next 1/3 and 2/3)

Kernels, 4 boots: base, sub-net-nf, base, sub-net-nf.

    .../tests/conntrack/ct-run-in-guest.sh

Expected, on x86_64:
- stream insn/pkt: about 80 lower on sub-net-nf (one IPv4 hash per
  packet).
- new-flow insn/pkt: lower by about 80 per hash computed on the new-flow
  path (lookup, confirm reply hash, and NAT if loaded).
- flush insn/entry: about 330-400 lower (two hash_conntrack_raw() calls
  removed per deleted entry).

If a delta has the right sign and is within about 30% of these
figures, add it to the changelog and keep RFC -> PATCH.  If stream
insn/pkt does not drop, investigate before sending (e.g. hash not on
the path, or inlining changed).

## T7: nf_conntrack_max warning and ctnetlink insert path (nf-next 2/3, 3/3)

Kernel: sub-net-nf, 1 boot.  T6's script also prints the warning check.
In addition:

    conntrack -I -p udp -s 10.9.9.1 -d 10.9.9.2 --sport 1 --dport 2 -t 60
    conntrack -D -p udp -s 10.9.9.1 -d 10.9.9.2 --sport 1 --dport 2
    echo 131072 > /sys/module/nf_conntrack/parameters/hashsize  # during churn
    dmesg | grep -iE 'warn|bug|list_del'

Expected:
- A 9x ratio logs exactly one line, 8x logs nothing, and a write from a
  non-init netns is refused.
- No splats after ctnetlink insert/delete or after a resize during
  churn.  Ideally run this on a PROVE_LOCKING + DEBUG_LIST build.
  Entries inserted by ctnetlink are exactly the path the first version
  of nf-next 2/3 missed.

## T8 (optional): the chain-length claim behind nf-next 3/3

Kernel: sub-net-nf.  Set nf_conntrack_max to 1x and to 24x
nf_conntrack_buckets.  In each case fill the table with churn.  Then
read chaintoolong and insert_failed from /proc/net/stat/nf_conntrack
(hex, per CPU; sum them in the shell) and new-flow insn/pkt from T6's
churn line.  Expected: insn per new flow rises with the ratio, and
chaintoolong > 0 at 24x once chains pass 50.  A result would let the
changelog state an effect instead of only a configuration.
