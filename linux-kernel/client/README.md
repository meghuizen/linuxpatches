# Client patches — the outbound path

Three patches against **Linux 7.3-rc3**, for the side that calls `socket()`,
`connect()` and `recvmsg()`: a browser, a JS runtime, `curl`, `wget`. Not
the forwarding path — see [`../net/`](../net/README.md) for that — and not a
server accepting connections.

Generic kernel code only. Nothing device- or driver-specific.

## The workload

A client opens many connections and most of them are short. A browser opens
several per origin across many origins; each carries a small request and a
response that is often small too. A growing share of them are **UDP, not
TCP**, because HTTP/3 puts the transport in userspace and leaves the kernel
seeing only `sendmsg` and `recvmsg` per datagram — with no congestion
control or retransmit to amortise that cost across a large segment.

## The patches

| # | Subsystem | What it does |
|---|---|---|
| 1 | `udp` | Announce a queued batch in one wakeup instead of one per skb |
| 2 | `ipv4` | Skip the IP-ID atomic on connected DF datagrams |
| 3 | `eventpoll` | Put everything `ep_poll_callback()` touches on one cacheline |

**Patch 1 is the one worth reading.** Three separate analyses — of the DNS
resolver receive path, of the QUIC client receive path, and of the wakeup
and epoll machinery — arrived at the same loop independently:

```c
while (nb) {
        INDIRECT_CALL_1(READ_ONCE(sk->sk_data_ready), sock_def_readable, sk);
        nb--;
}
```

It exists because the wakeup wakes one exclusive waiter, so `nb` threads
each blocked in their own `recvmsg()` need `nb` calls. An epoll consumer is
not that: it registers a non-exclusive waiter, so all `nb` calls run in
full — the `smp_mb()` in `skwq_has_sleeper()`, the waitqueue lock, and
`ep_poll_callback()`, which observes the same receive queue every time and
has nothing new to say after the first.

That consumer is exactly what a QUIC client is. **TCP does not pay this**:
`tcp_data_ready()` is gated on `tcp_epollin_ready()`.

## Backwards compatibility

No UAPI is removed or changed. Patch 1 adds `sock_data_ready_nr()` and
falls back to the old loop whenever `sk_data_ready` has been replaced —
sockmap, TLS, BPF — because such a callback may count something other than
waiters. Exclusive waiters still get `nb` wakeups.

Patch 2 **is visible on the wire**: the IP ID of a connected DF datagram
goes from a counter to zero. RFC 6864 2.1 leaves the field to the sender for
an atomic datagram and requires receivers to ignore it, and the unconnected
path in the same function already sends zero — so this does not make such
traffic distinguishable from other Linux traffic. It is called out here
because "no observable change" is otherwise the rule in this repository, and
this one is an exception.

Patch 3 is a field reorder.

## Benchmarks

`kbench net <variant>` runs `scripts/guest/net-bench.sh`, which has a
section per patch:

| section | patch | what it reads |
|---|---|---|
| `client: UDP RX wakeup batching` | 1 | **`dgram/wait`** — datagrams collected per `epoll_wait` round-trip |
| `client: UDP TX small datagrams` | 2 | send rate sweeping processes that share one socket |
| `client: epoll readiness burst` | 3 | cost per ready socket, swept 1→128: the **slope** |

Patch 1 changes wakeups per batch, not throughput, so its section reports
`dgram/wait` explicitly rather than leaving it to be inferred from a rate.
Patch 3's effect grows with burst size, so a single point says nothing and
the section sweeps.

**The patch-1 section had to be rewritten after its first smoke test.** As
first written it used one sender, and one sender to one receiver measured
`dgram/wait = 1.1` on loopback -- every datagram getting its own wakeup, no
batch ever forming, and therefore a section structurally incapable of
observing the patch. Six concurrent senders against one socket gives
`dgram/wait = 87.3`, which is the condition `nb > 1` the patch addresses. The
section now sweeps sender concurrency and says in its own output that a row
with `dgram/wait` near 1 measured nothing, whatever its rate column says.

## Status

**Compile-tested only.** Every patch builds its objects cleanly and patch 3's
layout claim was checked with `pahole` against the built object — all five
fields `ep_poll_callback()` touches now sit in cacheline 0, and the struct
stays 200 bytes. Nothing has been booted or measured.

## Considered and declined

**Ephemeral port allocation.** Named as the primary suspect before the
analysis and cleared by it. The RFC 6056 double-hash terminates in about one
iteration, there is already a lockless RCU pre-scan that skips the
bind-hashbucket spinlock for occupied ports, and `inet_bhashfn` is linear in
port so the scan walks adjacent cachelines.

**epoll wakeup coalescing.** `ep_autoremove_wake_function()` already unlinks
unconditionally, so the first of N ready sockets consumes the waiter and the
rest find `waitqueue_active()` false. One `try_to_wake_up()` per
`epoll_wait()` round-trip regardless of N. Any added flag is pure overhead.

**`udp_prod_queue` per-socket allocation.** Real — every UDP socket
`kzalloc`s it even if it never receives a packet, which is why UDP has more
allocations than TCP despite being half the size. But the only clean fix
embeds a 64-byte cacheline-aligned member in `udp_sock`, growing every
socket on NUMA builds to save one allocation on non-NUMA ones. Marginal in
both directions.

**The third FIB lookup in `ip_route_newports()`.** Fires unconditionally for
an unbound client, so an unbound `connect()` does three trie walks. A guard
on `policy_count[XFRM_POLICY_OUT] == 0` would elide it, but ECMP multipath
hashing consumes the source port and `fib_rules` can match `sport_range`;
the analysis could not clear both, and said so rather than claiming it safe.

**`WF_SYNC` from softirq.** `sock_def_readable()` uses the sync variant, so
`wake_affine_idle()` is told the waker is about to sleep when it is a NIC-RX
softirq that is not. Worse, `record_wakee(current)` there mutates whichever
task was interrupted. The direction of a fix is clear; it would also regress
loopback TCP, which completes in softirq and currently benefits. Needs
measurement first.

**`tw_refcount` as a percpu counter.** Every teardown does three refcount
operations on one shared cacheline per netns, and the cap it guards is soft.
But the same counter gates netns dismantle, where knowing exactly when it
reaches zero is a correctness requirement, not an approximation.

## A structural finding, not a patch

**HTTP/3 clients consume globally-unique ephemeral ports; TCP clients do
not.** `inet_dgram_connect()` autobinds before `->connect`, so
`udp_lib_get_port()` runs with `rcv_saddr == 0` and the bitmap path is
address-agnostic: every QUIC socket takes a unique port out of ~28k. TCP
reuses ports freely across destinations through 4-tuple uniqueness. A
browser with many HTTP/3 origins therefore hits a far lower ceiling than the
same page over TCP.

Deferring the autobind until after `connect()` would fix it and would change
what `getsockname()` reports before the first send. Recorded as the real
scalability limit rather than proposed.
