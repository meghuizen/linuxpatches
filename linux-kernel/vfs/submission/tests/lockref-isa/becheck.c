/*
 * Freestanding equivalence check for "lockref: adjust the count with a
 * single addition", runnable under qemu-user on targets without a libc
 * (aarch64 big-endian).  For every count in a set of edge values and
 * several lock-half values, compare the word produced by "count += d" with
 * the word produced by "lock_count += d * unit".
 *
 * Exit status: number of mismatches outside the documented exceptions
 * (0 = pass).  100 is added if a documented exception did NOT mismatch,
 * so the exception list is verified too.  The documented exceptions are
 * big-endian only: +1 on count == -1 and -1 on count == 0, where the
 * carry/borrow crosses into the lock half.
 */
typedef unsigned long long u64;
typedef unsigned int u32;

struct lockref {
	union {
		u64 lock_count __attribute__((aligned(8)));
		struct {
			u32 lock;
			int count;
		};
	};
};

static inline __attribute__((always_inline)) u64 lockref_step(void)
{
	const union {
		struct lockref lr;
		u64 v;
	} one = { .lr = { .count = 1 } };

	return one.v;
}

#define BE (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)

static int run(void)
{
	static const int counts[] = { -128, -127, -2, -1, 0, 1, 2, 3, 0x7ffffffe,
				      0x7fffffff, (int)0x80000000 };
	static const u32 locks[] = { 0, 1, 0x00010001, 0xffffffff };
	int bad = 0, exc_ok = 0, exc_n = 0;

	for (unsigned li = 0; li < sizeof(locks) / sizeof(locks[0]); li++) {
		for (unsigned ci = 0; ci < sizeof(counts) / sizeof(counts[0]); ci++) {
			for (int d = -1; d <= 1; d += 2) {
				struct lockref a, b;
				int exception;

				a.lock = locks[li];
				a.count = counts[ci];
				b = a;
				/* old form: 32-bit arithmetic on the count */
				a.count += d;
				/* new form: one add on the whole word */
				b.lock_count += (u64)(long long)d * lockref_step();

				exception = BE && ((d == 1 && counts[ci] == -1) ||
						   (d == -1 && counts[ci] == 0));
				if (exception) {
					exc_n++;
					if (a.lock_count != b.lock_count)
						exc_ok++;
				} else if (a.lock_count != b.lock_count) {
					bad++;
				}
			}
		}
	}
	if (exc_n != exc_ok)
		bad += 100;
	/* on little-endian there must be no exceptions at all */
	if (!BE && exc_n)
		bad += 200;
	return bad;
}

void _start(void)
{
	int r = run();

#if defined(__aarch64__)
	__asm__ volatile("mov w0, %w0\n\tmov x8, #93\n\tsvc #0" : : "r"(r) : "x0", "x8");
#elif defined(__riscv)
	__asm__ volatile("mv a0, %0\n\tli a7, 93\n\tecall" : : "r"(r) : "a0", "a7");
#elif defined(__x86_64__)
	__asm__ volatile("mov %0, %%edi\n\tmov $60, %%eax\n\tsyscall" : : "r"(r) : "rdi", "rax");
#else
#error "no exit syscall for this target"
#endif
	for (;;)
		;
}
