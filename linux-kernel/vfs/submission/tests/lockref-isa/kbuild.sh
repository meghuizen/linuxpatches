#!/bin/bash
# Build lib/lockref.o for arm64 and riscv64 from the base tree and the
# lockref-patch tree, in out-of-tree O= dirs (nothing written into the sources).
S=${OUT:-/tmp/lockref-isa}
for arch in arm64 riscv; do
	case $arch in arm64) CC=aarch64-linux-gnu- ;; riscv) CC=riscv64-linux-gnu- ;; esac
	for t in base:/usr/src/linux pt:/usr/src/linux-pt-lockref; do
		n=${t%%:*}; src=${t#*:}; O=$S/kb-$arch-$n
		mkdir -p "$O"
		if ! nice -n 19 make -s -C "$src" ARCH=$arch CROSS_COMPILE=$CC O="$O" defconfig > "$O/log" 2>&1; then
			echo "FAIL defconfig $arch $n"; tail -5 "$O/log"; continue
		fi
		echo "$arch $n: $(grep -E '^CONFIG_(SMP|DEBUG_SPINLOCK|ARCH_USE_CMPXCHG_LOCKREF|PREEMPT_RT|RISCV_COMBO_SPINLOCKS|RISCV_QUEUED_SPINLOCKS|ARM64_LSE_ATOMICS)=' "$O/.config" | tr '\n' ' ')"
		if nice -n 19 make -s -C "$src" ARCH=$arch CROSS_COMPILE=$CC O="$O" -j8 lib/lockref.o >> "$O/log" 2>&1; then
			echo "built $arch $n"
		else
			echo "FAIL build $arch $n"; grep -E 'error|Error' "$O/log" | head -5
		fi
	done
done
echo KBUILD-DONE
