#!/bin/bash
S=${OUT:-/tmp/lockref-isa}
for t in base:/usr/src/linux pt:/usr/src/linux-pt-lockref; do
	n=${t%%:*}; src=${t#*:}; O=$S/kb-i386-$n; mkdir -p "$O"
	nice -n 19 make -s -C "$src" ARCH=i386 O="$O" defconfig > "$O/log" 2>&1 || { echo "FAIL defconfig i386 $n"; tail -3 "$O/log"; continue; }
	echo "i386 $n: $(grep -E '^CONFIG_(SMP|DEBUG_SPINLOCK|ARCH_USE_CMPXCHG_LOCKREF|X86_CMPXCHG64|M686|MPENTIUM)' "$O/.config" | tr '\n' ' ')"
	nice -n 19 make -s -C "$src" ARCH=i386 O="$O" -j8 lib/lockref.o >> "$O/log" 2>&1 && echo "built i386 $n" || { echo "FAIL build i386 $n"; grep -iE 'error' "$O/log" | head -3; }
done
echo I386-DONE
