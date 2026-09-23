#!/bin/bash
# run32.sh <dir with i386 lib/siphash.o>: instructions per siphash call on i386
set -e
H=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
gcc -m32 -O2 -ffreestanding -fno-stack-protector -fno-pic -static -nostdlib \
	-o $T/h32 $H/harness32.c "$1/siphash.o" -Wl,--no-warn-rwx-segments
count() {
	local n=20000000 a b
	a=$(perf stat -x, -e instructions:u $T/h32 "$1" 0 2>&1 | awk -F, '/instructions/{print $1}')
	b=$(perf stat -x, -e instructions:u $T/h32 "$1" $n 2>&1 | awk -F, '/instructions/{print $1}')
	awk -v a="$a" -v b="$b" -v n=$n 'BEGIN{printf "%.2f", (b-a)/n}'
}
for m in sip39 sip2u64; do printf "%-10s %10s\n" $m $(count $m); done
rm -rf $T
