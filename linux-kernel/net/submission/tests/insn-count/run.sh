#!/bin/bash
# Build the harness against kernel objects and count retired user
# instructions per call with perf.  Usage: run.sh <objdir-base> <objdir-patched>
# Each objdir must contain nf_flow_table_core.o; the directory given by
# $KOBJ must contain lib/siphash.o and lib/string.o from the same build.
set -e
H=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
link() { # link <out> <nf_flow_table_core.o>
	objcopy --globalize-symbol=flow_offload_hash "$2" $T/foh.o
	gcc -O2 -static -no-pie -o "$1" $H/harness.c $T/foh.o \
		$KOBJ/siphash.o $KOBJ/string.o \
		-Wl,--unresolved-symbols=ignore-all -Wl,--no-warn-rwx-segments \
		-Wl,-z,noexecstack 2>/dev/null
}
count() { # count <bin> <mode> -> instructions per call
	local n=20000000 a b
	a=$(perf stat -x, -e instructions:u "$1" "$2" 0 2>&1 | awk -F, '/instructions/{print $1}')
	b=$(perf stat -x, -e instructions:u "$1" "$2" $n 2>&1 | awk -F, '/instructions/{print $1}')
	awk -v a="$a" -v b="$b" -v n=$n 'BEGIN{printf "%.2f", (b-a)/n}'
}
link $T/base "$1/nf_flow_table_core.o"
link $T/patched "$2/nf_flow_table_core.o"
# loop overhead: the loop in main() with the call is included in both;
# report differences, and the absolute per-iteration counts.
printf "%-12s %10s %10s\n" mode base patched
for m in foh-plain foh-encap; do
	printf "%-12s %10s %10s\n" $m $(count $T/base $m) $(count $T/patched $m)
done
for m in sip39 sip2u64 null; do
	printf "%-12s %10s\n" $m $(count $T/base $m)
done
rm -rf $T
