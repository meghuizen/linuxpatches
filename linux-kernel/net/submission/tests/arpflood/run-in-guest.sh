#!/bin/bash
# Run inside the guest, once per kernel. Needs perf, iproute2, gcc.
# Measures kernel instructions per ARP frame received on a bridge port,
# with no proxy_arp / neigh_suppress configured on any port.
set -e
H=$(cd "$(dirname "$0")" && pwd)
gcc -O2 -o /tmp/arpflood $H/arpflood.c
N=${N:-2000000}
ip link add abr0 type bridge
ip link set abr0 up
ip addr add 10.200.0.254/24 dev abr0
for i in 1 2 3 4; do
	ip link add ap$i type veth peer name ap${i}x
	ip link set ap$i master abr0
	ip link set ap$i up
	ip link set ap${i}x up
done
# Neighbour entries for the targets, so that the unpatched path takes
# neigh_lookup() hits and the fdb lookup, as on a LAN with known hosts.
for t in $(seq 1 200); do
	ip neigh replace 10.200.0.$t lladdr 02:00:00:00:00:$(printf %02x $t) \
		dev abr0 nud permanent
done
sleep 1
for run in 1 2 3; do
	perf stat -x, -e instructions:k,instructions:u \
		taskset -c 2 /tmp/arpflood ap1x $N 10.200.0 200 2>&1 |
	awk -F, -v n=$N '/instructions:k/{k=$1} /instructions:u/{u=$1}
		/^sent=/{print}
		END{printf "run: kernel instructions per frame = %.1f\n", k/n}'
done
for i in 1 2 3 4; do ip link del ap$i; done
ip link del abr0
