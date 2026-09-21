#!/bin/bash
# net-bench.sh -- benchmarks for the networking patch series.
#
# Runs entirely inside this guest. Two network namespaces are joined through
# the root namespace, which does the forwarding, so the kernel under test is
# router, sender and receiver at once. No external hardware, no second
# machine, and the whole path is the code being patched.
#
# Coverage. Each patch names a mechanism, and a section only counts if it can
# actually reach that mechanism:
#
#   section                 patches  what it can show
#   conntrack flow churn    4, 7, 8  per-NEW-flow cost: tuple hash, ext
#                                    alloc, teardown hash. Short UDP flows
#                                    are the DNS and QUIC shape.
#   established forwarding  3        per-PACKET cost of the flowtable hash
#   cake shaped egress      1, 2     timer arms and the DRR refill loop
#   bridge arp flood        6        the proxy-ARP path, once per ARP frame
#   gro receive             5        the gro list walk for traffic that
#                                    cannot coalesce
#
# And for the client-path series, which is a different set of patches on a
# different path -- we are the side calling socket(), connect() and recvmsg(),
# not the side forwarding:
#
#   client udp rx batch     c1       wakeups per datagram on a batched queue
#   client udp tx small     c2       the IP-ID atomic on a connected DF send
#   client epoll burst      c3       ep_poll_callback cost per ready socket
#
# The distinction that matters for reading the output: patches 4, 7 and 8 are
# per-flow and patch 3 is per-packet. A workload that reuses one flow cannot
# see the first group, and a workload that never repeats a flow cannot see
# the second. That is why the first two sections exist separately.
#
# Every measurement is divided by a control taken in the same processes at
# the same moment -- a getppid() loop, which no patch here can touch. Compare
# norm=, never the raw rate: this host drifts by more than the effects being
# measured.
set -uo pipefail

ITERS="${1:-400000}"
PROCS="${2:-0}"
[ "$PROCS" = 0 ] && PROCS=$(nproc)
OUT="${KBENCH_OUT:-/mnt/results}"
REPORT="$OUT/net-$(uname -r)-$(date +%Y%m%d-%H%M%S).txt"

mkdir -p "$OUT"
exec > >(tee "$REPORT") 2>&1

echo "kernel:  $(uname -r)"
echo "date:    $(date -Is)"
echo "harness: $(sha1sum "$0" 2>/dev/null | cut -c1-12)  ($(basename "$0"))"
echo "procs:   $PROCS   iters: $ITERS"
echo "cmdline: $(tr -d '\0' < /proc/cmdline)"
echo

need() {
	command -v "$1" >/dev/null || { echo "  MISSING: $1 -- section skipped"; return 1; }
}

########################## topology ##########################
# left --veth-- [root netns: the router] --veth-- right
#
# 10.99.1.0/24 on the left, 10.99.2.0/24 on the right. The root namespace
# forwards between them, which is where conntrack, the flowtable and the
# qdisc all sit.
NS_L=nbleft
NS_R=nbright

teardown() {
	ip netns del $NS_L 2>/dev/null
	ip netns del $NS_R 2>/dev/null
	nft delete table ip nbench 2>/dev/null
	nft delete table netdev nbench 2>/dev/null
	ip link del nbbr0 2>/dev/null
}
trap teardown EXIT

setup_topology() {
	teardown
	ip netns add $NS_L || return 1
	ip netns add $NS_R || return 1
	ip link add vl type veth peer name vl-r || return 1
	ip link add vr type veth peer name vr-r || return 1
	ip link set vl netns $NS_L
	ip link set vr netns $NS_R

	ip netns exec $NS_L ip addr add 10.99.1.2/24 dev vl
	ip netns exec $NS_L ip link set vl up
	ip netns exec $NS_L ip link set lo up
	ip netns exec $NS_L ip route add default via 10.99.1.1

	ip netns exec $NS_R ip addr add 10.99.2.2/24 dev vr
	ip netns exec $NS_R ip link set vr up
	ip netns exec $NS_R ip link set lo up
	ip netns exec $NS_R ip route add default via 10.99.2.1

	ip addr add 10.99.1.1/24 dev vl-r
	ip addr add 10.99.2.1/24 dev vr-r
	ip link set vl-r up
	ip link set vr-r up
	sysctl -qw net.ipv4.ip_forward=1
	return 0
}

########################## traffic generator ##########################
cat > /tmp/nb.c <<'EOF'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sched.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/epoll.h>

/* modes:
 *   churn  -- every datagram is a new 5-tuple, so every one creates and
 *             eventually tears down a conntrack entry. This is the DNS and
 *             QUIC-handshake shape: a flow that carries one or two packets.
 *   stream -- one 5-tuple for the whole run, so conntrack is touched once
 *             and every packet after that is pure forwarding path.
 *   sink   -- receive only.
 *   ctl    -- the control: getppid(), which touches no networking at all.
 */
static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	const char *mode = argv[1];
	int np = atoi(argv[2]);
	long it = atol(argv[3]);
	const char *dst = argc > 4 ? argv[4] : "10.99.2.2";
	char buf[128];
	double t0, t1;

	memset(buf, 0x5a, sizeof buf);

	if (!strcmp(mode, "epollsink")) {
		/* np sockets in one epoll set, drained by one thread: the
		 * shape a QUIC client has. Reports datagrams received and
		 * epoll_wait round-trips, so a change in wakeups per datagram
		 * is visible directly rather than inferred from throughput. */
		int ep = epoll_create1(0);
		int *fds = calloc(np, sizeof(int));
		struct epoll_event evs[64];
		long got = 0, waits = 0;

		for (int i = 0; i < np; i++) {
			struct sockaddr_in a = { .sin_family = AF_INET,
						 .sin_addr.s_addr = INADDR_ANY,
						 .sin_port = htons(9000 + i) };
			struct epoll_event e = { .events = EPOLLIN };
			fds[i] = socket(AF_INET, SOCK_DGRAM, 0);
			if (bind(fds[i], (struct sockaddr *)&a, sizeof a) < 0) return 1;
			e.data.fd = fds[i];
			epoll_ctl(ep, EPOLL_CTL_ADD, fds[i], &e);
		}
		t0 = now();
		while (got < it) {
			int n = epoll_wait(ep, evs, 64, 2000);
			if (n <= 0) break;
			waits++;
			for (int i = 0; i < n; i++)
				while (recv(evs[i].data.fd, buf, sizeof buf,
					    MSG_DONTWAIT) > 0)
					got++;
		}
		t1 = now();
		printf("%10.0f dgram/s  %7.3f s  dgrams=%ld  epoll_waits=%ld  dgram/wait=%.1f\n",
		       got / (t1 - t0), t1 - t0, got, waits,
		       waits ? (double)got / waits : 0.0);
		return 0;
	}

	if (!strcmp(mode, "burst")) {
		/* One datagram to each of np sockets, as close to simultaneous
		 * as a single thread manages: the readiness burst a page load
		 * produces. */
		int fd = socket(AF_INET, SOCK_DGRAM, 0);
		struct sockaddr_in d = { .sin_family = AF_INET };
		inet_pton(AF_INET, dst, &d.sin_addr);
		t0 = now();
		for (long j = 0; j < it; j++)
			for (int i = 0; i < np; i++) {
				d.sin_port = htons(9000 + i);
				sendto(fd, buf, sizeof buf, MSG_DONTWAIT,
				       (struct sockaddr *)&d, sizeof d);
			}
		t1 = now();
		printf("%10.0f dgram/s  %7.3f s\n", np * it / (t1 - t0), t1 - t0);
		return 0;
	}

	if (!strcmp(mode, "sink")) {
		int fd = socket(AF_INET, SOCK_DGRAM, 0);
		struct sockaddr_in a = { .sin_family = AF_INET,
					 .sin_addr.s_addr = INADDR_ANY };
		/* One socket bound to every port we will target would need
		 * 65535 binds; instead bind one port and let the rest be
		 * forwarded and dropped. The conntrack entry is created by the
		 * forward hook either way, which is what is being measured. */
		a.sin_port = htons(9000);
		if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) return 1;
		for (;;) { recv(fd, buf, sizeof buf, 0); }
	}

	t0 = now();
	for (int p = 0; p < np; p++) {
		if (fork() == 0) {
			cpu_set_t s;
			CPU_ZERO(&s);
			CPU_SET(p % sysconf(_SC_NPROCESSORS_ONLN), &s);
			sched_setaffinity(0, sizeof s, &s);

			if (!strcmp(mode, "ctl")) {
				for (long j = 0; j < it; j++)
					syscall(SYS_getppid);
				_exit(0);
			}

			int fd = socket(AF_INET, SOCK_DGRAM, 0);
			struct sockaddr_in d = { .sin_family = AF_INET };
			inet_pton(AF_INET, dst, &d.sin_addr);

			if (!strcmp(mode, "stream")) {
				d.sin_port = htons(9000);
				connect(fd, (struct sockaddr *)&d, sizeof d);
				for (long j = 0; j < it; j++)
					send(fd, buf, sizeof buf, MSG_DONTWAIT);
			} else { /* churn */
				/* Vary the destination port so each datagram is
				 * a distinct tuple. Varying the source would
				 * need a bind per flow, which measures bind
				 * rather than conntrack. */
				for (long j = 0; j < it; j++) {
					d.sin_port = htons(1024 + (j + p * it) % 60000);
					sendto(fd, buf, sizeof buf, MSG_DONTWAIT,
					       (struct sockaddr *)&d, sizeof d);
				}
			}
			_exit(0);
		}
	}
	while (wait(NULL) > 0) ;
	t1 = now();

	printf("%10.0f ops/s  %7.3f s\n", np * it / (t1 - t0), t1 - t0);
	return 0;
}
EOF
gcc -O2 -o /tmp/nb /tmp/nb.c || { echo "generator build failed"; exit 1; }

ctcount() { conntrack -C 2>/dev/null || cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "?"; }

# One measurement plus the control that goes with it.
measure() { # measure <label> <mode> <procs>
	local label="$1" mode="$2" np="$3"
	local ctl out ops norm
	ctl=$(ip netns exec $NS_L /tmp/nb ctl "$np" $((ITERS * 4)) | awk '{print $1}')
	out=$(ip netns exec $NS_L /tmp/nb "$mode" "$np" "$ITERS")
	ops=$(echo "$out" | awk '{print $1}')
	norm=$(awk -v a="$ops" -v b="$ctl" 'BEGIN{if(b>0)printf "%.5f",a/b; else printf "n/a"}')
	printf '  %-22s %s  ctl=%s  norm=%s  ct=%s\n' "$label" "$out" "$ctl" "$norm" "$(ctcount)"
}

########################## conntrack flow churn ##########################
echo "### conntrack flow churn (patches 4, 7, 8)"
echo "  every datagram is a new 5-tuple: one conntrack entry created per op."
echo "  This is the cost DNS and QUIC actually pay -- a flow of one or two"
echo "  packets pays the full setup and teardown and nothing amortises it."
if need nft && setup_topology; then
	nft -f - <<'NFT'
table ip nbench {
	chain fwd {
		type filter hook forward priority filter; policy accept;
		ct state new counter
	}
}
NFT
	ip netns exec $NS_R /tmp/nb sink 1 1 &
	SINK=$!
	sleep 0.3
	/tmp/nb churn 1 $((ITERS / 8)) >/dev/null 2>&1   # warm-up, discarded
	for r in 1 2 3 4; do
		printf '  run %d:' "$r"
		measure "churn" churn "$PROCS"
	done
	kill $SINK 2>/dev/null
	echo "  conntrack table: $(ctcount) entries, max $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"
else
	echo "  topology or nftables unavailable -- section skipped"
fi
echo

########################## established forwarding ##########################
echo "### established forwarding through the flowtable (patch 3)"
echo "  one 5-tuple for the whole run, so conntrack is touched once and every"
echo "  packet after that is the per-packet path the flowtable hash sits on."
if need nft && setup_topology; then
	nft -f - <<'NFT'
table ip nbench {
	flowtable ft {
		hook ingress priority filter; devices = { vl-r, vr-r };
	}
	chain fwd {
		type filter hook forward priority filter; policy accept;
		ct state established flow add @ft
	}
}
NFT
	ip netns exec $NS_R /tmp/nb sink 1 1 &
	SINK=$!
	sleep 0.3
	/tmp/nb stream 1 $((ITERS / 8)) >/dev/null 2>&1
	for r in 1 2 3 4; do
		printf '  run %d:' "$r"
		measure "stream" stream "$PROCS"
	done
	kill $SINK 2>/dev/null
else
	echo "  topology or nftables unavailable -- section skipped"
fi
echo

########################## cake ##########################
echo "### cake shaped egress (patches 1, 2)"
echo "  CAKE arms an hrtimer after nearly every shaped packet. The figure of"
echo "  merit is softirq time per delivered packet, not throughput: the shaper"
echo "  holds throughput at the configured rate by construction."
if need tc && setup_topology; then
	if tc qdisc replace dev vr-r root cake bandwidth 200mbit 2>/dev/null; then
		ip netns exec $NS_R /tmp/nb sink 1 1 &
		SINK=$!
		sleep 0.3
		for r in 1 2 3; do
			s0=$(awk '/^cpu /{print $3+$4+$7+$8}' /proc/stat)
			out=$(ip netns exec $NS_L /tmp/nb stream "$PROCS" "$ITERS")
			s1=$(awk '/^cpu /{print $3+$4+$7+$8}' /proc/stat)
			printf '  run %d: %s  sys+irq ticks=%s\n' "$r" "$out" "$((s1 - s0))"
		done
		kill $SINK 2>/dev/null
		echo "  qdisc stats:"
		tc -s qdisc show dev vr-r | sed 's/^/    /' | head -12
	else
		echo "  sch_cake not available in this kernel -- section skipped"
	fi
else
	echo "  tc unavailable -- section skipped"
fi
echo

########################## bridge arp ##########################
echo "### bridge ARP flood (patch 6)"
echo "  ARP is broadcast, so it can never be offloaded and its cost scales"
echo "  with port count. br_do_proxy_suppress_arp() runs on every frame."
if setup_topology; then
	ip link add nbbr0 type bridge 2>/dev/null
	ip link set nbbr0 up 2>/dev/null
	for i in 1 2 3 4; do
		ip link add nbp$i type veth peer name nbp${i}p 2>/dev/null
		ip link set nbp$i master nbbr0 2>/dev/null
		ip link set nbp$i up 2>/dev/null
		ip link set nbp${i}p up 2>/dev/null
	done
	echo "  bridge with 4 ports up; ARP entries before: $(ip neigh show | wc -l)"
	t0=$(date +%s.%N)
	for j in $(seq 1 200); do
		ip netns exec $NS_L ping -c1 -W0 -q 10.99.1.$((j % 250 + 3)) >/dev/null 2>&1
	done
	t1=$(date +%s.%N)
	echo "  200 ARP resolutions for absent hosts: $(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2f s", b-a}')"
	echo "  NOTE: this is a weak proxy. It measures ARP timeout, not the"
	echo "  per-frame path cost, and a real measurement needs a frame"
	echo "  generator on the bridge. Treat as a smoke test, not a result."
	for i in 1 2 3 4; do ip link del nbp$i 2>/dev/null; done
	ip link del nbbr0 2>/dev/null
fi
echo

########################## gro ##########################
echo "### GRO receive (patch 5)"
echo "  the gro list walk is wasted for any protocol with no ->gro_receive."
echo "  Compare GRO on against GRO off on the receiving veth."
if need ethtool && setup_topology; then
	ip netns exec $NS_R /tmp/nb sink 1 1 &
	SINK=$!
	sleep 0.3
	for g in on off; do
		ip netns exec $NS_R ethtool -K vr gro $g 2>/dev/null
		ethtool -K vr-r gro $g 2>/dev/null
		printf '  gro=%-4s' "$g"
		measure "stream" stream "$PROCS"
	done
	kill $SINK 2>/dev/null
else
	echo "  ethtool unavailable -- section skipped"
fi
echo

########################## client: udp rx wakeup batching ##########################
echo "### client: UDP RX wakeup batching (client patch 1)"
echo "  One receiver draining many sockets from epoll, fed as fast as the"
echo "  sender manages, so datagrams arrive in batches. dgram/wait is the"
echo "  number that matters: it says how many datagrams one epoll_wait"
echo "  round-trip collected. The patch changes wakeups per batch, not"
echo "  throughput, so read that column and not the rate."
if setup_topology; then
	for socks in 1 8 32; do
		ip netns exec $NS_R /tmp/nb epollsink "$socks" $((ITERS / 4)) &
		SINK=$!
		sleep 0.4
		ip netns exec $NS_L /tmp/nb burst "$socks" $((ITERS / 4 / socks)) >/dev/null 2>&1
		wait $SINK 2>/dev/null
	done
else
	echo "  topology unavailable -- section skipped"
fi
echo

########################## client: udp tx small ##########################
echo "### client: UDP TX small datagrams on a connected socket (client patch 2)"
echo "  connect() then send: the QUIC shape. Every send takes the IP-ID"
echo "  atomic on inet_id, which is the only write this path makes to that"
echo "  cacheline. Sweep the process count sharing one socket, because that"
echo "  is when a per-socket atomic starts to matter."
if setup_topology; then
	ip netns exec $NS_R /tmp/nb sink 1 1 &
	SINK=$!
	sleep 0.3
	for n in 1 4 16; do
		[ "$n" -gt "$(nproc)" ] && continue
		ctl=$(ip netns exec $NS_L /tmp/nb ctl "$n" $((ITERS * 4)) | awk '{print $1}')
		out=$(ip netns exec $NS_L /tmp/nb stream "$n" "$ITERS")
		ops=$(echo "$out" | awk '{print $1}')
		norm=$(awk -v a="$ops" -v b="$ctl" 'BEGIN{if(b>0)printf "%.5f",a/b; else printf "n/a"}')
		printf '  procs=%-3s %s  ctl=%s  norm=%s\n' "$n" "$out" "$ctl" "$norm"
	done
	kill $SINK 2>/dev/null
else
	echo "  topology unavailable -- section skipped"
fi
echo

########################## client: epoll readiness burst ##########################
echo "### client: epoll readiness burst (client patch 3)"
echo "  N sockets in one epoll set all made ready at once, which is the shape"
echo "  a page load has. ep_poll_callback() runs once per ready socket, so"
echo "  the cost per socket is what the struct reorder targets. The figure of"
echo "  merit is the SLOPE across N."
if setup_topology; then
	for socks in 1 8 32 128; do
		ip netns exec $NS_R /tmp/nb epollsink "$socks" $((ITERS / 8)) &
		SINK=$!
		sleep 0.4
		printf '  sockets=%-4s ' "$socks"
		ip netns exec $NS_L /tmp/nb burst "$socks" $((ITERS / 8 / socks)) >/dev/null 2>&1
		wait $SINK 2>/dev/null
	done
else
	echo "  topology unavailable -- section skipped"
fi
echo

echo "### skb->hash on ingress (decides whether GRO can bucket at all)"
echo "  veth does not set an RSS hash, so skb->hash is computed in software"
echo "  here. On real hardware this is the single biggest unknown for the"
echo "  GRO path: if the NIC leaves it zero, every packet lands in bucket 0."
echo

echo "############ net-bench complete: $REPORT ############"
