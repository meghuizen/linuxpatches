#!/bin/bash
# Run inside the guest, once per boot.  Same topology and load as the
# net-bench.sh cake section (two netns, forwarding root ns, cake 1gbit
# on vr-r, 2 UDP senders on connected sockets, 128-byte payload), plus
# frequency-independent counters.
#
#   cake-run-in-guest.sh [slack_ns] [senders]
#
# slack_ns: if given, set TCA_CAKE_TIMER_SLACK with cake_slack (patched
#           patch-1 kernels only; the script aborts if the kernel does not
#           echo the value back).
# senders:  number of sending processes (default 2; 32 for the patch 2
#           many-flows case).
set -e
H=$(cd "$(dirname "$0")" && pwd)
SLACK=${1:-}
NP=${2:-2}
IT=$((400000 / NP))
gcc -O2 -o /tmp/cake_slack $H/cake_slack.c
cat > /tmp/cs.c <<'C'
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <string.h>
int main(int c, char **v)
{
	if (!strcmp(v[1], "sink")) {
		char b[2048];
		struct sockaddr_in a = { .sin_family = AF_INET,
					 .sin_port = htons(9000) };
		int fd = socket(AF_INET, SOCK_DGRAM, 0);
		if (bind(fd, (void *)&a, sizeof(a)))
			return 1;
		for (;;)
			recv(fd, b, sizeof(b), 0);
	}
	int np = atoi(v[1]); long it = atol(v[2]);
	for (int p = 0; p < np; p++) if (!fork()) {
		char buf[128] = { 0 };
		struct sockaddr_in d = { .sin_family = AF_INET,
					 .sin_port = htons(9000) };
		int fd = socket(AF_INET, SOCK_DGRAM, 0);
		inet_pton(AF_INET, "10.99.2.2", &d.sin_addr);
		connect(fd, (void *)&d, sizeof(d));
		for (long j = 0; j < it; j++)
			send(fd, buf, sizeof(buf), MSG_DONTWAIT);
		_exit(0);
	}
	while (wait(NULL) > 0)
		;
	return 0;
}
C
gcc -O2 -o /tmp/cs /tmp/cs.c
ip netns del csl 2>/dev/null || true; ip netns del csr 2>/dev/null || true
ip netns add csl; ip netns add csr
ip link add vl type veth peer name vl-r; ip link add vr type veth peer name vr-r
ip link set vl netns csl; ip link set vr netns csr
ip -n csl addr add 10.99.1.2/24 dev vl; ip -n csl link set vl up
ip -n csl route add default via 10.99.1.1
ip -n csr addr add 10.99.2.2/24 dev vr; ip -n csr link set vr up
ip -n csr route add default via 10.99.2.1
ip addr add 10.99.1.1/24 dev vl-r; ip addr add 10.99.2.1/24 dev vr-r
ip link set vl-r up; ip link set vr-r up
sysctl -qw net.ipv4.ip_forward=1
tc qdisc replace dev vr-r root cake bandwidth 1gbit
if [ -n "$SLACK" ]; then
	/tmp/cake_slack vr-r "$SLACK" | grep -qx "timer_slack=$SLACK" ||
		{ echo "kernel did not accept TCA_CAKE_TIMER_SLACK"; exit 1; }
fi
ip netns exec csr /tmp/cs sink &
SINK=$!
sleep 0.5
sent() { tc -s qdisc show dev vr-r | awk '/Sent/ {print $4; exit}'; }
loc() { awk '/^ *LOC:/ {s=0; for (i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s}' /proc/interrupts; }
for r in 1 2 3; do
	p0=$(sent); l0=$(loc)
	s0=$(awk '/^cpu /{print $3+$4+$7+$8}' /proc/stat)
	perf stat -a -x, -o /tmp/cs.perf \
		-e instructions,timer:hrtimer_start,timer:hrtimer_expire_entry,irq:softirq_entry \
		ip netns exec csl /tmp/cs $NP $IT
	s1=$(awk '/^cpu /{print $3+$4+$7+$8}' /proc/stat)
	p1=$(sent); l1=$(loc)
	awk -F, -v p=$((p1 - p0)) -v t=$((s1 - s0)) -v l=$((l1 - l0)) -v r=$r '
		/instructions/ {i=$1} /hrtimer_start/ {hs=$1}
		/hrtimer_expire_entry/ {he=$1} /softirq_entry/ {si=$1}
		END { printf "run %d: delivered=%d ticks/kpkt=%.2f insn/pkt=%.0f hrtimer_start/pkt=%.3f hrtimer_expire/pkt=%.3f softirq/pkt=%.3f LOC/pkt=%.3f\n",
			r, p, 1000*t/p, i/p, hs/p, he/p, si/p, l/p }' /tmp/cs.perf
done
tc -s qdisc show dev vr-r | head -3
kill $SINK 2>/dev/null || true
ip netns del csl; ip netns del csr
