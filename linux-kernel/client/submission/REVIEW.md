# Client series -- review before submission

## Runtime results, 2026-09-23 (patchtest campaign, interleaved boots)

| patch | result | decision |
|---|---|---|
| eventpoll layout (pt-epoll, 2 boots vs 7 base) | 4-writer callback: cycles -0.8% (spread 41%), L1 misses -7.8% (spread 30%); uncontended loop instructions +0.7% (spread 3%) | REMOVED (no measurable difference), moved to removed/ |
| UDP batch wake (pt-udp, 2 boots) | epoll callbacks per datagram 1.00 -> 0.91/0.87 (6 senders), 0.47/0.45 (12), 1.00 (1); blocked-recv check clean. Unpaced senders run ~2x faster on the patched kernel and overflow the receive buffer at 12 senders. Fixed-rate follow-up (udp_rate_wake, 12 senders, 50k-200k dgram/s, 3+3 interleaved boots, results patchtest-*-20260923-182[3-8]*): patched dropped 30 of 13.5M, base 61k (all in host-stall runs); receiver ns/dgram equal | KEEP, RFC dropped: `[PATCH net-next]` |


Worktree `/usr/src/sub-client`, base 518e5b794c06 (v7.3-rc3).

| # | commit (sub-client) | subject | recommendation | impact | evidence |
|---|---|---|---|---|---|
| 1 | f6c6f3cb5ee9 | udp: wake a drained batch of datagrams with one sk_data_ready call | HOLD, then RFC net-next after T1 | low -- UDP socket fed by several CPUs at once | static analysis + call counts on an unpatched kernel; not run patched |
| 2 | 67b6f48fa0e8 (standalone: sub-client-vfs d110c676df57) | eventpoll: keep the fields ep_poll_callback() writes in one cacheline | HOLD; RFC to VFS only if T2b shows a gain, else DROP | low -- benefit not demonstrated | static analysis (pahole) only |
| 3 | 923f4a95f320 (standalone: sub-client-ipid-dropped 0bc9a8b0570d) | ipv4: send IP ID 0 for connected non-TCP atomic datagrams | DROP | low | not measured; harness could not reach it |

The branch order was changed from the original (udp, ipv4, eventpoll) so
that the dropped patch is last. All three commits were rewritten: author
set to `Michiel <367462+meghuizen@users.noreply.github.com>`, the
`Co-Authored-By`/`Claude-Session` trailers replaced by `Assisted-by:`, no
`Signed-off-by:`. The original branch tip was 60b983f2c42c.

Output layout (deviates from the single-directory export in the brief,
because the patches go to different trees and one is dropped):

- `netdev/` -- cover letter + patch 1, `[RFC PATCH net-next]`
- `vfs/` -- patch 2 (eventpoll) alone, `[RFC PATCH]`, To/Cc for VFS
- `dropped/` -- patch 3, for the record, marked DO NOT SEND
- `tests/`, `TESTS-TO-RUN.md`

Each was exported with `git format-patch --base=518e5b794c06` from a branch
where the patch sits directly on the base.

---

## Patch 1 -- udp: one sk_data_ready call per drained batch

**Recommendation: HOLD until T1 (TESTS-TO-RUN.md) has run on the patched
kernel; then post as RFC net-next.** The change is correct as far as static
review goes and cheap at nb = 1, but its effect has only been counted on an
unpatched kernel, and it is small outside a multi-producer flood.

**Stand-alone:** improves something by itself (fewer sk_data_ready calls
when nb > 1); does not depend on the other patches.

**Impact: low** -- a UDP socket receiving from several CPUs at the same time
(one unconnected server socket behind RSS/RPS, or a flood). A connected
single-flow socket, which is what a QUIC or DNS client has, is normally fed
from one RX CPU and sees nb = 1: no change.

**Evidence:**
- Mechanism count on the host kernel (6.18.40 WSL2, has b650bf0977d3, not
  this patch): `tests/udp_batch_wake.c` + `tests/udp_batch_wake.bt`,
  results `tests/host-results.txt`, `tests/host-results-12-24.txt`,
  summary `tests/nb-summary.txt`. Calls the patch would remove: 0 (1
  sender), 0.8% (2), 5.8% (6), 15.9% (12), 18.1% (24). One run each, with
  kprobe overhead, which may enlarge batches.
- Exclusive waiters on the host: 4 threads blocked in recv(), 2 and 6
  senders, 0 late wakeups, 0 datagrams unaccounted (validates the test).
- Code generation: `tests/sock_def_readable-disasm.txt` -- sock_def_readable()
  is the same code as before plus one `mov $1,%edx`, calling
  `__wake_up_sync_key_nr` instead of `__wake_up_sync_key`.
  `__sock_def_readable()` is `__always_inline` for that reason (without it
  gcc emitted a tail-jump wrapper on every TCP/unix data_ready).
- Existing kbench data (section "client: UDP RX wakeup batching", the four
  2026-09-22 dirs): unusable for this patch, see "Existing data" below.

**Changes made to the patch:**
- Fixed a bug: when every skb of a batch is dropped by udp_rmem_schedule(),
  nb is 0. The original code then called `__wake_up_common(nr_exclusive=0)`,
  which wakes every waiter, exclusive ones included, plus the epoll callback
  and SIGIO, for a batch that queued nothing. The old loop made no call.
  `sock_data_ready_nr()` now returns for nr <= 0.
- O_ASYNC sockets keep the loop: with F_SETSIG set to a realtime signal,
  each kill_fasync() queues one signal, so one call per batch would change
  the number of signals delivered.
- Fallback loop re-reads `sk->sk_data_ready` each iteration, exactly as the
  old code.
- Removed both `EXPORT_SYMBOL_GPL`s: the only caller (net/ipv4/udp.c) and
  the helpers (net/core/sock.c, kernel/sched/wait.c) are built in.
- Comments cut to what the code needs; the "QUIC client" text and cost
  narrative removed from the code.
- Changelog rewritten. The original said the batch was "up to a NAPI batch
  of datagrams"; it is not -- nb > 1 only when other CPUs llist_add() to the
  same socket's per-NUMA queue while one CPU drains it. The "that consumer
  is what a QUIC client is" framing was dropped because a client socket
  rarely has concurrent producers.

**Likely objections and whether answered:**
- "Is this worth a new wait API?" -- open; this is the question the RFC
  asks. Numbers above are the answer so far.
- "Eric wrote the loop deliberately" -- the loop's comment only covers
  exclusive waiters; the patch keeps that behaviour. Answered in the notes.
- "kernel/sched/wait.c change needs sched maintainers" -- they are on Cc.
- "Tracepoint semantics" -- `trace_sk_data_ready` now fires once per batch
  for the default callback. Stated below `---`. Not answered beyond that.
- "Not tested on net-next" -- true, stated.

**Correctness risks checked:**
- Every `sk_data_ready` override in the tree (grep of net/, drivers/, fs/):
  UDP-reachable ones are skmsg `sk_psock_verdict_data_ready`, sunrpc
  `xs_data_ready` (UDP xprt) and `svc_data_ready` (svc_udp_init). All take
  the unchanged loop. tls, espintcp, kcm, strparser psock, ovpn TCP,
  nvme/iscsi/ceph/dlm/ocfs2/rds/smc/mptcp/siw/erdma override TCP sockets
  and never reach `__udp_enqueue_schedule_skb()`. rxrpc, l2tp, wireguard,
  vxlan, ovpn UDP use encap_rcv, not this queue. qmi is AF_QIPCRTR.
- Exclusive waiters: read `__wake_up_common()`; one pass with
  nr_exclusive = nb wakes the same entries nb single passes would (entries
  returning 0 are skipped either way; non-exclusive entries precede
  exclusive ones). recvmsg waiters use `receiver_wake_function()` ->
  `autoremove_wake_function()`. EPOLLEXCLUSIVE epitems return 1 only when
  their ep had a waiter; same in both schemes.
- `sock_wake_async()` for SOCK_WAKE_WAITD does not dedupe for UDP, hence the
  O_ASYNC fallback.
- TCP and all other `sock_def_readable()` users: same semantics, one extra
  register load.
- Build at this commit with W=1: sock.o, udp.o, ipv6/udp.o,
  sched/build_utility.o, skmsg.o, sunrpc/xprtsock.o, ping.o, raw.o,
  tcp_ipv4.o, ip_output.o, eventpoll.o -- clean (`tests/bisect-build.txt`).
- Not checked: sparse/smatch (not installed); runtime on patched kernel.

**checkpatch --strict:** 1 error, "Missing Signed-off-by" -- intended; the
submitter adds it. No warnings, no checks.

---

## Patch 2 -- eventpoll: keep the fields ep_poll_callback() writes in one cacheline

**Recommendation: HOLD.** Post as RFC to VFS (Brauner/Viro, fsdevel) only if
T2b shows a gain beyond run-to-run spread in both interleaved rounds;
otherwise DROP. It goes through the VFS tree, not netdev, and is
independent of patch 1, so it is exported alone in `vfs/`.

**Stand-alone:** pure field reorder; builds and has no functional change at
its position and on the base alone. Claimed to improve by itself; not
demonstrated.

**Impact: low** -- epoll sets whose files are made ready on other CPUs while
a task waits in epoll_wait(). Benefit not shown.

**Evidence:** static only. `tests/pahole-eventpoll.txt` (pahole on the built
fs/eventpoll.o before and after). Line analysis, with every `ep->` field
access in ep_poll_callback(), ep_poll(), ep_send_events(), ep_start_scan(),
ep_done_scan(), ep_events_available(), ep_busy_loop() enumerated:

| path | lines read before -> after | lines written before -> after |
|---|---|---|
| ep_poll_callback() | 0,1,2,3 -> 0,1,2,3 | 1 (+0 with a waiter) -> 0 |
| epoll_wait() (ep_poll + ep_send_events) | 0,1,2,3 -> 0,1,2,3 | 0,1 -> 0 |

Uncontended single-threaded case: no extra line read; one fewer line
written. That is the argument for "no regression", and T2a is there to
catch a gross one (it cannot resolve a single line; host cycle/L1 noise is
~5%).

**Changes made to the changelog/comment:** the original said the callback
"never touches" ->poll_wait; it reads ->poll_wait.head on every call
(`waitqueue_active(&ep->poll_wait)`), and it also reads ->busy_poll_usecs /
->prefer_busy_poll (lines 2 and 3) via `ep_busy_loop_on()` with
CONFIG_NET_RX_BUSY_POLL=y. So "everything the callback touches on one
cacheline" was false: it still reads 4 lines. The claim is now "the fields
it writes". The "one page load makes hundreds of sockets ready" rhetoric and
the in-code narrative were removed.

**Likely objections:** "no numbers" -- not answered; hence HOLD. "Why not
also move poll_wait/busy-poll fields" -- 4+4+16+8+24 bytes leave no room for
a second wait_queue_head in line 0; not attempted.

**Correctness risks checked:** struct is private to fs/eventpoll.c; no
offsetof users; allocated with `kzalloc_obj()` (kmalloc-256, naturally
aligned, so the line numbers are real). BTF consumers use CO-RE relocations.
With lock debugging the analysis does not hold (bigger spinlocks); nothing
depends on it.

**checkpatch --strict:** only "Missing Signed-off-by" (intended).

---

## Patch 3 -- ipv4: send IP ID 0 for connected non-TCP atomic datagrams

**Recommendation: DROP.** Wire-visible change for a saving that was never
measured, with a receive-side GRO interaction for UDP GSO senders.

**Impact: low.** Only sockets with IP_PMTUDISC_DO/PROBE (the default
IP_PMTUDISC_WANT sets skb->ignore_df, so the new branch is not taken), and
only when several threads send on one connected socket does the atomic
contend.

**History (git log -L on ip_select_ident_segs(), follow the second parent
of 518e5b794c06, the local clone is shallow on the first):**
- pre-git (1da177e4c3f4): connected DF -> `inet->id++` "only to work around
  buggy Windows95/2000 VJ compression implementations"; unconnected DF -> 0.
  TCP-specific justification applied to every connected socket.
- 703133de331a (2013, Ansis Atteka) adds `!skb->ignore_df` so DF packets
  that may still be fragmented locally get unique IDs.
- 73f156a6e8c1 (2014, Eric Dumazet) per-destination hashed generator.
- 431280eebed9 (2018) and 970a5a3ea86d (2022, Eric Dumazet): TCP RST/ACK and
  SYNACK sent with ID 0 to close off-path side channels ("Off-Path TCP
  Exploits of the Mixed IPID Assignment").
- 23f57406b82d (2022, Eric Dumazet) "ipv4: avoid using shared IP generator
  for connected sockets": all connected packets, DF or not, use the private
  per-socket counter -- for security, and for pmtudisc=DONT performance.
- f866fbc842de (2023) makes inet_id atomic for lockless UDP senders.

Conclusion: upstream did not move away from 0 for connected DF datagrams;
it has moved toward 0 for DF control packets. The patch does not reverse a
recorded decision. It is dropped on cost/benefit:
1. The saving (one `lock xadd` on a per-socket line) is unmeasured, and the
   kbench section meant to measure it could not reach the code (see below).
2. UDP GSO with DF+!ignore_df: base ID 0 gives segments 0..n-1 and the next
   send restarts at 0. `inet_gro_flush()` merges only incrementing or fixed
   IDs, so receiver UDP GRO can no longer merge across two GSO sends; today
   the shared counter keeps the sequence continuous. Mixed single/GSO sends
   break too (0 vs counter).
3. It also changes SCTP (sctp sets inet_daddr), raw and ping sockets, which
   the original changelog did not mention.

Revisit only with a measurement of threads sharing one DO socket, and a
design that keeps IDs continuous for GSO.

---

## Existing data -- what the four 2026-09-22 net runs show for this area

Dirs: `net-7.3.0-rc3-kbench-{everything,baseline}-...-20260922-{045108,045345,045618,045834}`.
Harness sha 2357d3e692cf; its client sections are identical to the current
net-bench.sh (96836f3c0c83). `everything` here lacks net patch 9 (bzImage
2026-09-21 15:57).

**None of the three client sections can support a claim for its patch.**

1. "client: UDP RX wakeup batching" (patch 1): rates are raw, no control;
   `dgram/wait` 2.0 / 3.4-4.0 / 42-76 for 1/2/6 senders on both kernels.
   `dgram/wait` does not show batches forming: on the host at 6 senders
   dgram/wait was 36.7 while only 4.6% of drains had nb > 1. It measures how
   far the consumer is behind, not nb. Rates, 6 senders: everything
   74847/77545 vs baseline 77369/75267 -- no consistent direction.
   everything round 1 at 2 senders (69377 vs ~230-260k elsewhere) is an
   outlier. Output rows are also printed without newlines (printf of
   `$(cat file)` drops the trailing newline).
2. "client: UDP TX small datagrams on a connected socket" (patch 2): the
   section says processes share one socket; they do not -- `nb stream`
   creates a socket in each forked child. And the sockets use the default
   IP_PMTUDISC_WANT, so skb->ignore_df is set and the patched branch is
   never taken. Usable (spread <= 15%) pairs: procs=4 only; round 1
   everything 0.01579 vs baseline 0.01824 (-13%), round 2 0.02181 vs
   0.02152 (+1.3%): directions disagree, and the patch was not exercised.
3. "client: epoll readiness burst" (patch 3): rows 32 and 128 sockets are
   dominated by a 2-second epoll_wait timeout -- the sink waits for
   ITERS/8 = 50000 datagrams but the sender sends 50000/N*N (49984, 49920),
   so the loop only ends on the 2 s timeout (0.57 s of work + 2 s = the
   2.57 s shown). The "slope" is that artefact. Rows 1 and 8 are
   sender-bound with dgram/wait 1.2-2.1, i.e. no burst forms. Everything
   is 1.8-2.9% below baseline at 1 and 8 sockets in both rounds, without
   control normalisation and on a combined kernel; not attributable.

Also: the README claim "Six concurrent senders against one socket gives
dgram/wait = 87.3, which is the condition nb > 1 the patch addresses" is
wrong for the reason in item 1.

## Identity / trailer checks

- grep of `submission/` for the two identity strings the brief forbids
  (the webmail domain and the harness author address) -- no matches.
- checkpatch on the cover letter reports one error for the placeholder
  `Signed-off-by: <submitter adds before sending>` line, which the brief
  requires; it goes away when the submitter fills it in.
- Every exported patch: author `Michiel <367462+meghuizen@users.noreply.github.com>`,
  `Assisted-by:` present, no `Signed-off-by:`, no `Co-Authored-By:`.
