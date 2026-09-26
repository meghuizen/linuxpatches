# lockref: adjust the count with a single addition -- per-ISA evidence

Measured 2026-09-26 for the v2 of the patch (`../../lockref/`). Base is
v7.3-rc3 (518e5b794c06). gcc 15.2 everywhere (aarch64-linux-gnu-gcc and
riscv64-linux-gnu-gcc for the cross builds).

## Instructions per function, kernel lib/lockref.o

x86-64 built with the test kernel's config; i386, arm64 and riscv64 with
`defconfig`. Counted with `count2.sh` (global symbols only, local `.L`
labels ignored, trailing alignment nops dropped).

| function | x86-64 | i386 | arm64 | riscv64 |
|---|---|---|---|---|
| lockref_get | 27 -> 19 | 42 -> 42 | 39 -> 34 | 47 -> 44 |
| lockref_get_not_zero | 42 -> 36 | 65 -> 65 | 52 -> 49 | 58 -> 57 |
| lockref_get_not_dead | 42 -> 36 | 65 -> 65 | 50 -> 47 | 58 -> 56 |
| lockref_put_or_lock | 37 -> 33 | 51 -> 51 | 49 -> 45 | 57 -> 55 |
| lockref_put_return | 24 -> 21 | 48 -> 48 | 31 -> 30 | 45 -> 43 |

- i386: the v2 object disassembles identically to the base object (0
  differing lines). The v1 form (word add on 32-bit too) was worse on
  i386: lockref_get 42 -> 51, put_return 48 -> 51, the others +1, because
  the u64 add is spilled around cmpxchg8b's fixed register pairs.
- x86-64, arm64, riscv64: the v2 object disassembles identically to the
  v1 object (0 differing lines each), so the v1 measurements carry over.
- riscv64 defconfig uses combo (ticket/queued) spinlocks; the unlocked
  test is `owner == next`, so the lock half can be nonzero while
  unlocked. Little-endian: irrelevant to the add.

## Big-endian

arm64 `CPU_BIG_ENDIAN` is `depends on BROKEN`, and there is no s390,
powerpc or mips cross compiler here, so no big-endian kernel object.
Instead:

- `model.c` compiled with `aarch64-linux-gnu-gcc -mbig-endian`: unit is
  1 (`mov x0, #1` in `step_value`), the update is `add x3, x1, #1`, and
  the per-function counts equal the little-endian LSE build.
- `becheck.c` (freestanding, no libc) compares both update forms for
  counts {-128, -127, -2, -1, 0, 1, 2, 3, INT_MAX-1, INT_MAX, INT_MIN}
  and lock halves {0, 1, 0x00010001, 0xffffffff}, +1 and -1. Exit status
  0 = equal everywhere except the documented exceptions, and the
  exceptions verified to differ:

      x86_64 native            exit=0
      aarch64 LE (qemu-user)   exit=0
      aarch64 BE (qemu-user)   exit=0   (exceptions: +1 on -1, -1 on 0)
      riscv64 (qemu-user)      exit=0

## Userspace timing (x86-64 host, AMD Ryzen 9 8940HX, WSL2)

`../lockref-model/lockref_model.c`, single thread, uncontended,
5*10^7 get+put pairs per run, old/new interleaved, `perf stat`:

    run1 old: 58.0 insns/pair 29.3 cycles/pair
    run1 new: 51.0 insns/pair 26.9 cycles/pair
    run2 old: 58.0 insns/pair 29.4 cycles/pair
    run2 new: 51.0 insns/pair 26.9 cycles/pair
    run3 old: 58.0 insns/pair 29.3 cycles/pair
    run3 new: 51.0 insns/pair 26.9 cycles/pair

Earlier run (2026-09-23, same host): 29.8 -> 28.4 cycles/pair.

## In-kernel

patchtest campaign 2026-09-23, the v1 patch alone on v7.3-rc3, 2 boots
against 9 base boots: kernel instructions per open() and per stat()
within +-1.3%, inside the 2-4% boot-to-boot spread; 16-process open
storm on one file 10874 and 11816 kernel cycles/open against base
11326-13011 (inside spread). No measurable effect at the syscall level.

## Files

- `model.c`, `count.sh`: header-free model of the loop, old/new/LE-only
  variants, for cross-compiling; `c-<target>.txt` are the counts.
- `becheck.c`: the freestanding equivalence check.
- `count2.sh`: per-function instruction counter for kernel objects.
- `kbuild.sh`, `kbuild-i386.sh`: how the cross kernel objects were built.
