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
	# Delete the root-side veth ends explicitly and then WAIT for them.
	# "ip netns del" returns before the namespace is dismantled, so the
	# peer interfaces in the root namespace can outlive it by a moment.
	# The next setup_topology then raced this cleanup and died with
	# "RTNETLINK answers: File exists", which the caller reported as
	# "topology unavailable" -- that silently skipped the GRO section and
	# client patch 1 on the first full run of this script.
	ip link del vl-r 2>/dev/null
	ip link del vr-r 2>/dev/null
	local i=0
	while ip link show vl-r >/dev/null 2>&1 ||
	      ip link show vr-r >/dev/null 2>&1; do
		sleep 0.2
		i=$((i + 1))
		[ "$i" -gt 25 ] && break
	done
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


# The two nftables rulesets, as functions so their exit status can gate the
# section that needs them.
#
# The chain is called nbfwd, not fwd: "fwd" is a reserved word in nftables
# (the netdev fwd statement) and a chain named that fails to parse. It did,
# silently, on the first run of this script -- the ruleset never loaded, so no
# netfilter hook was installed, so conntrack never engaged, and every row of
# the conntrack and flowtable sections printed a plausible rate next to ct=0
# while measuring nothing about patches 3, 4, 7 or 8. A section whose hook did
# not install must skip, not report.
ruleset_ct() {
	nft -f - <<'NFT'
table ip nbench {
	chain nbfwd {
		type filter hook forward priority filter; policy accept;
		ct state new counter
	}
}
NFT
}

ruleset_flowtable() {
	nft -f - <<'NFT'
table ip nbench {
	flowtable ft {
		hook ingress priority filter; devices = { vl-r, vr-r };
	}
	chain nbfwd {
		type filter hook forward priority filter; policy accept;
		ct state established flow add @ft
	}
}
NFT
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
	/* Reject an unknown mode rather than falling into one. "churn" is the
	 * unlabelled else-branch below, so before this check a typo'd or
	 * renamed mode ran churn and printed a perfectly plausible rate under
	 * the wrong section heading. Two results in this project have already
	 * been thrown away for measuring something other than what their
	 * heading claimed; this is a two-line guard against a third. */
	static const char *modes[] = { "churn", "stream", "sink", "ctl",
				       "epollsink", "burst", NULL };
	int m;
	int np;
	long it;
	const char *dst;
	char buf[128];
	double t0, t1;

	if (argc < 4) {
		fprintf(stderr, "usage: nb <mode> <procs> <iters> [dst]\n");
		return 2;
	}
	for (m = 0; modes[m]; m++)
		if (!strcmp(mode, modes[m]))
			break;
	if (!modes[m]) {
		fprintf(stderr, "nb: unknown mode '%s'\n", mode);
		return 2;
	}
	np = atoi(argv[2]);
	it = atol(argv[3]);
	dst = argc > 4 ? argv[4] : "10.99.2.2";

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
# The control, same scheme as tree-bench.sh and for the same reason: ONE
# control sample is as noisy as the measurement it normalises, so dividing by
# it compounds variance instead of removing it. The 2026-09-21 tree-bench pair
# demonstrated it -- the control moved 3x within a single boot and every norm=
# in every rate-based section became noise, while the perf-counter sections
# stayed reproducible to 0.05%. Median of CTL_REPS samples, taken before AND
# after the measurement so it brackets it in time, and the row says for itself
# when the two brackets disagree.
CTL_REPS=${CTL_REPS:-3}
CTL_NOISE_PCT=${CTL_NOISE_PCT:-15}
CTL_UNSTABLE=0
CTL_TOTAL=0

ctl_median() { # ctl_median <procs>
	local np="$1" n=$(( ITERS * 4 / CTL_REPS )) i
	for i in $(seq "$CTL_REPS"); do
		ip netns exec $NS_L /tmp/nb ctl "$np" "$n" | awk '{print $1}'
	done | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
}

# Run between the workload and the trailing control bracket, and again before
# the leading one. Default is a no-op; the conntrack sections override it.
#
# Conntrack's garbage collector keeps working after the traffic stops. On the
# first run of this script the trailing bracket landed in the middle of that
# and reported spreads of 2135%, 807% and 116% -- every conntrack and
# flowtable row marked unusable, not because the measurement was bad but
# because its wake was still being cleaned up when the control ran. Quiesce
# first, then bracket.
settle() { :; }

measure() { # measure <label> <mode> <procs> [iters]
	local label="$1" mode="$2" np="$3" it="${4:-$ITERS}"
	local pre post ctl spread out ops
	settle
	pre=$(ctl_median "$np")
	out=$(ip netns exec $NS_L /tmp/nb "$mode" "$np" "$it")
	# Read the table BEFORE settling. settle() flushes conntrack, so reading
	# it afterwards reported ct=0 on every row of the first run that had a
	# working ruleset -- the entries were created, flushed, then counted.
	ctnow=$(ctcount)
	settle
	post=$(ctl_median "$np")
	ctl=$(( (pre + post) / 2 ))
	spread=$(awk -v a="$pre" -v b="$post" 'BEGIN{
		if (a > b) { t = a; a = b; b = t }
		if (a > 0) printf "%.0f", 100 * (b - a) / a; else print 999 }')
	CTL_TOTAL=$(( CTL_TOTAL + 1 ))
	[ "$spread" -gt "$CTL_NOISE_PCT" ] && CTL_UNSTABLE=$(( CTL_UNSTABLE + 1 ))
	ops=$(echo "$out" | awk '{print $1}')
	printf '  %-22s %s  %s  ct=%s\n' "$label" "$out" \
		"$(awk -v a="$ops" -v b="$ctl" -v s="$spread" -v lim="$CTL_NOISE_PCT" 'BEGIN{
			printf "ctl=%d  spread=%s%%  norm=", b, s
			if (b > 0) printf "%.5f", a/b; else printf "n/a"
			if (s + 0 > lim) printf "  !! control moved during the run: norm is noise"
		 }')" "$ctnow"
}

########################## conntrack flow churn ##########################
echo "### conntrack flow churn (patches 4, 7, 8)"
echo "  every datagram is a new 5-tuple: one conntrack entry created per op."
echo "  This is the cost DNS and QUIC actually pay -- a flow of one or two"
echo "  packets pays the full setup and teardown and nothing amortises it."
if need nft && setup_topology && ruleset_ct; then
	ip netns exec $NS_R /tmp/nb sink 1 1 &
	SINK=$!
	sleep 0.3
	# In NS_L, like the measurement. The warm-up used to run in the root
	# netns, which warms a different path than the one being timed.
	ip netns exec $NS_L /tmp/nb churn 1 $((ITERS / 8)) >/dev/null 2>&1
	# Stay UNDER the conntrack table rather than swamping it. The first run
	# of this section offered 16 x 400000 = 6.4M distinct tuples to a
	# 262144-entry table: it filled on run 1 and every run after that
	# measured early_drop eviction on a full table, which is not the path
	# patches 4 and 7 are on (tuple hash at insert, extension prealloc at
	# alloc). 60% of the table leaves headroom for entries that have not
	# timed out yet.
	CTMAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 262144)
	settle() { conntrack -F >/dev/null 2>&1; sleep 1; }

	# /proc/net/stat/nf_conntrack is per-CPU; sum the columns that say
	# whether the table was under pressure. Without these, saturation has
	# to be inferred from the entry count, which only shows the ceiling was
	# reached, not what it cost.
	# Hex, summed in the shell. awk's strtonum() is a GAWK extension and the
	# guest has mawk ("function strtonum never defined"), so the awk version
	# of this silently reported 0 on every row -- including the over-table
	# regime where early_drop must be in the millions.
	ctstat() { # ctstat <column-name>
		local col total=0 v
		col=$(awk -v w="$1" 'NR==1{for(i=1;i<=NF;i++) if($i==w){print i;exit}}' \
			/proc/net/stat/nf_conntrack 2>/dev/null)
		[ -n "$col" ] || { echo 0; return; }
		while read -r v; do
			total=$(( total + 16#$v ))
		done < <(awk -v c="$col" 'NR>1{print $c}' /proc/net/stat/nf_conntrack)
		echo "$total"
	}

	# TWO regimes, reported separately, because they exercise different
	# patches. Under the table every new flow is a clean insert: that is
	# patch 4 (tuple hash) and patch 7 (extension prealloc). Over it, each
	# new flow additionally forces early_drop() to evict one -- a DELETE on
	# the packet path -- which is what patch 8 removes a rehash from. Sizing
	# the saturated case away, as the first fix here did, would have
	# measured patch 8 in the one condition where it does least.
	#
	# Saturation is not an exotic case for the target hardware: this guest
	# has 7 GB and nf_conntrack_max is derived from RAM at init, so a 1 GB
	# router gets a far smaller table and reaches it far sooner.
	# Hold the WORKLOAD fixed and move the TABLE, rather than the reverse.
	# Sizing the workload to 60% of a 262144-entry table gave 157280 flows,
	# which this guest churns in 0.042s -- shorter than the fork of the 16
	# processes doing it, so the row measured startup, not conntrack. The
	# workload is now identical in both regimes and long enough to time;
	# nf_conntrack_max decides whether the table saturates.
	CHURN_IT=$((ITERS / 2))
	TOTAL=$((PROCS * CHURN_IT))
	for regime in under over; do
		if [ "$regime" = under ]; then
			sysctl -qw net.netfilter.nf_conntrack_max=$((TOTAL * 2)) 2>/dev/null
			echo "  [under] $PROCS x $CHURN_IT = $TOTAL flows, table $((TOTAL * 2)): clean insert"
		else
			sysctl -qw net.netfilter.nf_conntrack_max=$((TOTAL / 10)) 2>/dev/null
			echo "  [over]  $PROCS x $CHURN_IT = $TOTAL flows, table $((TOTAL / 10)): insert + early_drop evict"
		fi
		d0=$(ctstat drop); e0=$(ctstat early_drop); i0=$(ctstat insert_failed)
		for r in 1 2; do
			printf '  %-7s run %d:' "$regime" "$r"
			measure "churn-$regime" churn "$PROCS" "$CHURN_IT"
		done
		echo "    table pressure: drop=$(( $(ctstat drop) - d0 ))  early_drop=$(( $(ctstat early_drop) - e0 ))  insert_failed=$(( $(ctstat insert_failed) - i0 ))"
	done
	sysctl -qw net.netfilter.nf_conntrack_max=$CTMAX 2>/dev/null
	settle() { :; }
	kill $SINK 2>/dev/null
	echo "  conntrack table: $(ctcount) entries, max $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"
else
	echo "  topology, nftables or the ruleset unavailable -- section skipped"
fi
echo

########################## established forwarding ##########################
echo "### established forwarding through the flowtable (patch 3)"
echo "  one 5-tuple for the whole run, so conntrack is touched once and every"
echo "  packet after that is the per-packet path the flowtable hash sits on."
if need nft && setup_topology && ruleset_flowtable; then
	ip netns exec $NS_R /tmp/nb sink 1 1 &
	SINK=$!
	sleep 0.3
	ip netns exec $NS_L /tmp/nb stream 1 $((ITERS / 8)) >/dev/null 2>&1
	# One flush before the sweep: this section wants a table holding its own
	# single flow, not whatever the churn section left behind.
	conntrack -F >/dev/null 2>&1
	sleep 1
	for r in 1 2 3 4; do
		printf '  run %d:' "$r"
		measure "stream" stream "$PROCS"
	done
	kill $SINK 2>/dev/null
else
	echo "  topology, nftables or the ruleset unavailable -- section skipped"
fi
echo

########################## cake ##########################
echo "### cake shaped egress (patches 1, 2)"
echo "  CAKE arms an hrtimer after nearly every shaped packet. The figure of"
echo "  merit is softirq time per delivered packet, not throughput: the shaper"
echo "  holds throughput at the configured rate by construction."
# Offered load is deliberately close to the shaped rate, not far above it.
# The first run of this section pushed 16 senders at a 200mbit shaper and got
# 4.1M drops against 89k delivered packets -- a 98% drop rate, which means
# sys+irq time was dominated by enqueue-and-drop. Both patches here are on the
# DEQUEUE side (the hrtimer arm, the DRR deficit refill), so that arrangement
# measured almost none of what it claimed to. Fewer senders and a wider pipe
# put the packets through the shaper instead of into its tail drop.
#
# Figure of merit is ticks per DELIVERED packet, taken from the qdisc's own
# counters, so a run that still overruns is visible as a drop ratio rather
# than quietly inflating the cost.
cake_pkts() { tc -s qdisc show dev vr-r | awk '/Sent/ {print $4; exit}'; }
cake_drops() { tc -s qdisc show dev vr-r | awk 'match($0,/dropped [0-9]+/) {
	print substr($0,RSTART+8,RLENGTH-8); exit }'; }
if need tc && setup_topology; then
	if tc qdisc replace dev vr-r root cake bandwidth 1gbit 2>/dev/null; then
		ip netns exec $NS_R /tmp/nb sink 1 1 &
		SINK=$!
		sleep 0.3
		for r in 1 2 3; do
			p0=$(cake_pkts); d0=$(cake_drops)
			s0=$(awk '/^cpu /{print $3+$4+$7+$8}' /proc/stat)
			out=$(ip netns exec $NS_L /tmp/nb stream 2 $((ITERS / 2)))
			s1=$(awk '/^cpu /{print $3+$4+$7+$8}' /proc/stat)
			p1=$(cake_pkts); d1=$(cake_drops)
			printf '  run %d: %s  %s\n' "$r" "$out" \
				"$(awk -v t=$((s1 - s0)) -v p=$((p1 - p0)) -v d=$((d1 - d0)) 'BEGIN{
					printf "ticks=%d  delivered=%d  dropped=%d  ticks/kpkt=%s", t, p, d,
					       (p > 0 ? sprintf("%.2f", 1000.0*t/p) : "n/a")
					if (p + d > 0 && d > p)
						printf "  !! more dropped than delivered: dequeue path underweighted" }')"
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
	# -w 1 -W 1, not -W0. The first run of this section used "-c1 -W0"
	# against 200 addresses that by construction never answer. -W 0 in
	# iputils does not mean "no timeout", it means "wait forever":
	# measured, `ping -c1 -W0` to an unreachable host was still blocked
	# when killed at 30s. The script sat in this loop until the run was
	# killed -- the GUEST was fine, a userspace ping was blocked in
	# recvmsg by its own argument, and no kernel was involved. Both caps
	# are needed: -W bounds the wait for a reply, -w the whole invocation.
	t0=$(date +%s.%N)
	for j in $(seq 1 50); do
		ip netns exec $NS_L ping -c1 -w1 -W1 -q 10.99.1.$((j % 250 + 3)) \
			>/dev/null 2>&1
	done
	t1=$(date +%s.%N)
	echo "  50 ARP resolutions for absent hosts: $(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2f s", b-a}')"
	echo "  NOT A RESULT FOR PATCH 6. This times ARP resolution timeout,"
	echo "  which is dominated by the 1s cap above and says nothing about"
	echo "  br_do_proxy_suppress_arp() per-frame cost. Measuring that needs"
	echo "  a raw ARP frame generator on a bridge port, which this harness"
	echo "  does not have. Patch 6 is unmeasured, and the report must say so"
	echo "  rather than quote this number."
	for i in 1 2 3 4; do ip link del nbp$i 2>/dev/null; done
	ip link del nbbr0 2>/dev/null
fi
echo

########################## gro ##########################
echo "### GRO receive (patch 5)"
echo "  the gro list walk is wasted for any protocol with no ->gro_receive."
echo "  Compare GRO on against GRO off on the receiving veth."
if ! need ethtool; then
	:
elif setup_topology; then
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
	# Not "ethtool unavailable": need() already printed if that was the
	# cause. Reaching here means the topology failed, and saying ethtool
	# sent the first investigation of this skip in the wrong direction.
	echo "  topology setup failed -- section skipped"
fi
echo

########################## client: udp rx wakeup batching ##########################
echo "### client: UDP RX wakeup batching (client patch 1)"
echo "  The patch batches the wakeups __udp_enqueue_schedule_skb() issues for"
echo "  one queued batch. It can only matter when a batch forms, i.e. when"
echo "  nb > 1 -- when producers outpace the consumer. ONE sender does not"
echo "  do that: measured on loopback, one sender to one receiver gives"
echo "  dgram/wait = 1.1, every datagram its own wakeup, and the patch is"
echo "  then a no-op by construction."
echo
echo "  So sweep sender concurrency against a single receiving socket."
echo "  dgram/wait is the discriminating number and the only one to read:"
echo "  a row where it is near 1 measured nothing, whatever its rate says."
if setup_topology; then
	for senders in 1 2 6; do
		[ "$senders" -gt "$(nproc)" ] && continue
		ip netns exec $NS_R /tmp/nb epollsink 1 $((ITERS / 2)) > /tmp/nbsink.out 2>&1 &
		SINK=$!
		sleep 0.5
		for i in $(seq "$senders"); do
			ip netns exec $NS_L /tmp/nb burst 1 $((ITERS / 2 / senders)) >/dev/null 2>&1 &
		done
		wait
		printf '  senders=%-3s %s' "$senders" "$(cat /tmp/nbsink.out)"
	done
	rm -f /tmp/nbsink.out
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
		# measure(), not a hand-rolled single control sample: this row
		# carried no spread= and so could not report when its own
		# normalisation had stopped meaning anything.
		printf '  procs=%-3s' "$n"
		measure "stream" stream "$n"
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

echo "### control stability"
awk -v u="$CTL_UNSTABLE" -v t="$CTL_TOTAL" -v lim="$CTL_NOISE_PCT" 'BEGIN{
	if (t == 0) { print "  no normalised measurements taken"; exit }
	printf "  %d of %d measurements had the control move more than %d%% while they ran.\n", u, t, lim
	if (u * 2 > t)
		print "  MOST ROWS ARE UNUSABLE: treat every norm= above as noise."
	else if (u > 0)
		print "  The flagged rows are unusable; the rest are."
	else
		print "  The host held still: every norm= above is comparable."
}'
echo

echo "############ net-bench complete: $REPORT ############"
