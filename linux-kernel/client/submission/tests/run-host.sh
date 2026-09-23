#!/bin/bash
# Host-side validation of the test program only: the host kernel is not the
# patched kernel. Shows that the workload makes nb > 1 on a kernel that
# has the per-NUMA udp_prod_queue (b650bf0977d3), and what that costs in
# ep_poll_callback() runs without the patch.
set -u
cd "$(dirname "$0")"
gcc -O2 -Wall -pthread -o udp_batch_wake udp_batch_wake.c || exit 1
echo "host kernel: $(uname -r)"
for s in 1 2 6; do
	timeout 30 bpftrace udp_batch_wake.bt > bt.$s.out 2>&1 &
	BT=$!
	for i in $(seq 50); do grep -q Attaching bt.$s.out 2>/dev/null && break; sleep 0.2; done
	./udp_batch_wake epoll "$s" 3
	kill -INT $BT; wait $BT 2>/dev/null
	cat bt.$s.out
done
./udp_batch_wake block 6 4 3
./udp_batch_wake block 2 4 3
