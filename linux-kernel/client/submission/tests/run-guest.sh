#!/bin/bash
# Run inside the guest, once per kernel, booted back to back (interleaved).
# Needs gcc, perf, and /sys/kernel/tracing with the function profiler.
# Output goes to stdout; save it per kernel.
set -u
cd "$(dirname "$0")"
gcc -O2 -Wall -pthread -o udp_batch_wake udp_batch_wake.c || exit 1
gcc -O2 -Wall -pthread -o epoll_cb epoll_cb.c || exit 1
TR=/sys/kernel/tracing
echo "kernel: $(uname -r)"

# Hit counts of the functions on the patch-1 path, via the ftrace
# function profiler. sock_data_ready_nr exists only on the patched kernel.
prof() { # prof <cmd...>
	local f
	echo > $TR/set_ftrace_filter
	for f in __udp_enqueue_schedule_skb sock_def_readable ep_poll_callback \
		 sock_data_ready_nr; do
		echo "$f" >> $TR/set_ftrace_filter 2>/dev/null
	done
	echo 0 > $TR/function_profile_enabled
	echo 1 > $TR/function_profile_enabled
	"$@"
	echo 0 > $TR/function_profile_enabled
	cat $TR/trace_stat/function* | awk '
		$1 ~ /^(__udp_enqueue_schedule_skb|sock_def_readable|ep_poll_callback|sock_data_ready_nr)$/ { h[$1] += $2 }
		END { for (f in h) printf "    hits %-28s %d\n", f, h[f] }'
	echo > $TR/set_ftrace_filter
}

# Alternative when bpftrace is installed: per-enqueue histograms.
btprof() { # btprof <cmd...>
	local out; out=$(mktemp)
	bpftrace udp_batch_wake.bt > "$out" 2>&1 &
	local bt=$! i
	for i in $(seq 50); do grep -q Attach "$out" && break; sleep 0.2; done
	"$@"
	kill -INT $bt; wait $bt 2>/dev/null
	sed 's/^/    /' "$out"; rm -f "$out"
}

echo "## T1a: callbacks per datagram, epoll consumer"
for s in 1 2 6 12; do
	[ "$s" -ge "$(nproc)" ] && continue
	if [ -w $TR/function_profile_enabled ]; then
		prof ./udp_batch_wake epoll "$s" 3
	elif command -v bpftrace >/dev/null; then
		btprof ./udp_batch_wake epoll "$s" 3
	else
		echo "  no function profiler and no bpftrace -- T1a skipped"
	fi
done

echo "## T1b: exclusive waiters (threads blocked in recv)"
for r in 1 3; do
	./udp_batch_wake block 6 4 3
	./udp_batch_wake block 2 4 3
done

echo "## T1c: kernel instructions per datagram (perf counts, 3 runs each)"
for s in 1 6; do
	for r in 1 2 3; do
		perf stat -x, -e instructions:k,cycles:k -o perf.tmp -- \
			./udp_batch_wake epoll "$s" 3 | tee run.tmp
		got=$(sed -n 's/.* got=\([0-9]*\).*/\1/p' run.tmp)
		awk -F, -v g="$got" -v s="$s" '$3 ~ /instructions:k|cycles:k/ {
			printf "    senders=%s %-15s per datagram %.1f\n", s, $3, $1 / g }' perf.tmp
	done
done

echo "## T2a: uncontended epoll (eventfd write + epoll_wait + read, 1 thread)"
for r in 1 2 3 4 5; do
	perf stat -x, -e instructions:k,cycles:k,L1-dcache-load-misses -o perf.tmp -- \
		./epoll_cb single 1000000 >/dev/null
	awk -F, '$3 ~ /:k|misses/ { printf "    %-24s per iter %.2f\n", $3, $1 / 1000000 }' perf.tmp
done

echo "## T2b: contended epoll (4 and 12 writer threads, 1 epoll_wait thread)"
for w in 4 12; do
	[ "$w" -ge "$(nproc)" ] && continue
	for r in 1 2 3; do
		perf stat -x, -e instructions:k,cycles:k,L1-dcache-load-misses -o perf.tmp -- \
			./epoll_cb multi "$w" 3 | tee run.tmp
		cb=$(sed -n 's/.* callbacks=\([0-9]*\).*/\1/p' run.tmp)
		awk -F, -v c="$cb" -v w="$w" '$3 ~ /:k|misses/ {
			printf "    writers=%s %-24s per callback %.2f\n", w, $3, $1 / c }' perf.tmp
	done
done
rm -f perf.tmp run.tmp
