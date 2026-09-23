#!/bin/bash
# Run inside the guest, once per boot (baseline, then sub-net-nf).
# Kernel instructions per packet / per deleted entry for the conntrack
# patches, and the nf_conntrack_max warning.  Needs nft, conntrack, perf.
#
#   ct-run-in-guest.sh
set -e
N=${N:-1000000}
cat > /tmp/ct.c <<'C'
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
/* ct stream <n>: n datagrams on one connected 5-tuple
 * ct churn <n>:  n datagrams, destination port cycling over 60000 values
 * ct sink:       receive on port 9000 */
int main(int c, char **v)
{
	char b[2048] = { 0 };
	struct sockaddr_in d = { .sin_family = AF_INET, .sin_port = htons(9000) };
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	long n = c > 2 ? atol(v[2]) : 0;

	if (!strcmp(v[1], "sink")) {
		if (bind(fd, (void *)&d, sizeof(d)))
			return 1;
		for (;;)
			recv(fd, b, sizeof(b), 0);
	}
	inet_pton(AF_INET, "10.99.2.2", &d.sin_addr);
	if (!strcmp(v[1], "stream")) {
		connect(fd, (void *)&d, sizeof(d));
		for (long i = 0; i < n; i++)
			send(fd, b, 128, 0);
	} else {
		for (long i = 0; i < n; i++) {
			d.sin_port = htons(1024 + i % 60000);
			sendto(fd, b, 128, 0, (void *)&d, sizeof(d));
		}
	}
	return 0;
}
C
gcc -O2 -o /tmp/ct /tmp/ct.c
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
nft -f - <<'NFT'
table ip ctb {
	chain f {
		type filter hook forward priority filter; policy accept;
		ct state new counter
	}
}
NFT
ip netns exec csr /tmp/ct sink &
SINK=$!
sleep 0.5
kinsn() { # kinsn <cmd...>: kernel instructions of one pinned command
	perf stat -x, -e instructions:k taskset -c 2 "$@" 2>&1 >/dev/null |
		awk -F, '/instructions/ {print $1}'
}
BUCKETS=$(cat /proc/sys/net/netfilter/nf_conntrack_buckets)
sysctl -qw net.netfilter.nf_conntrack_max=$BUCKETS
for r in 1 2 3; do
	conntrack -F >/dev/null 2>&1; sleep 1
	s=$(kinsn ip netns exec csl /tmp/ct stream $N)
	conntrack -F >/dev/null 2>&1; sleep 1
	# 60000 datagrams to 60000 distinct ports: 60000 new entries
	ch=$(kinsn ip netns exec csl /tmp/ct churn 60000)
	cnt=$(cat /proc/sys/net/netfilter/nf_conntrack_count)
	f=$(perf stat -a -x, -e instructions:k conntrack -F 2>&1 >/dev/null |
		awk -F, '/instructions/ {print $1}')
	awk -v s=$s -v n=$N -v ch=$ch -v cnt=$cnt -v f=$f -v r=$r 'BEGIN {
		printf "run %d: stream insn/pkt=%.0f  new-flow insn/pkt=%.0f  flush insn/entry=%.0f (entries=%d)\n",
			r, s/n, ch/60000, f/cnt, cnt }'
done
echo "--- patch 3 of nf-next: warning check (expect one line only for 9x)"
dmesg -C 2>/dev/null || true
sysctl -qw net.netfilter.nf_conntrack_max=$((8 * BUCKETS))
sysctl -qw net.netfilter.nf_conntrack_max=$((9 * BUCKETS))
dmesg | grep nf_conntrack_max || echo "(no warning logged)"
ip netns exec csl sh -c "echo 1 > /proc/sys/net/netfilter/nf_conntrack_max" 2>&1 |
	sed 's/^/netns write: /' || true
sysctl -qw net.netfilter.nf_conntrack_max=$BUCKETS
kill $SINK 2>/dev/null || true
nft delete table ip ctb
ip netns del csl; ip netns del csr
