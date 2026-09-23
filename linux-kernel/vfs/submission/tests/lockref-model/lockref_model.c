// SPDX-License-Identifier: GPL-2.0
/*
 * Userspace model of lib/lockref.c's CMPXCHG_LOOP, before and after
 * "lockref: adjust the count with a single addition".
 *
 *   ./lockref_model check          functional equivalence over edge values
 *   ./lockref_model old|new N      N x (get + put_return) on one lockref,
 *                                  single thread, for perf stat
 *
 * The lock is modelled as a 32-bit word that is "unlocked" when zero, which is
 * what arch_spin_value_unlocked() tests for qspinlock on x86-64.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct lockref {
	union {
		uint64_t lock_count __attribute__((aligned(8)));
		struct {
			uint32_t lock;
			int count;
		};
	};
};

#define CMPXCHG_LOOP(CODE, SUCCESS) do {				\
	int retry = 100;						\
	struct lockref old;						\
	old.lock_count = __atomic_load_n(&lr->lock_count, __ATOMIC_RELAXED); \
	while (__builtin_expect(old.lock == 0, 1)) {			\
		struct lockref new = old;				\
		CODE							\
		if (__atomic_compare_exchange_n(&lr->lock_count,	\
				&old.lock_count, new.lock_count, 0,	\
				__ATOMIC_RELAXED, __ATOMIC_RELAXED)) {	\
			SUCCESS;					\
		}							\
		if (!--retry)						\
			break;						\
	}								\
} while (0)

static inline __attribute__((always_inline)) uint64_t lockref_step(void)
{
	const union {
		struct lockref lr;
		uint64_t v;
	} one = { .lr = { .count = 1 } };

	return one.v;
}

__attribute__((noinline)) void get_old(struct lockref *lr)
{
	CMPXCHG_LOOP(new.count++;, return;);
	lr->count++;	/* slow path stand-in (no lock taken in the model) */
}

__attribute__((noinline)) void get_new(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count += lockref_step();, return;);
	lr->count++;
}

__attribute__((noinline)) int put_return_old(struct lockref *lr)
{
	CMPXCHG_LOOP(new.count--; if (old.count <= 0) return -1;,
		     return new.count;);
	return -1;
}

__attribute__((noinline)) int put_return_new(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count -= lockref_step(); if (old.count <= 0) return -1;,
		     return new.count;);
	return -1;
}

__attribute__((noinline)) int get_not_dead_old(struct lockref *lr)
{
	int retval = 0;

	CMPXCHG_LOOP(new.count++; if (old.count < 0) return 0;, return 1;);
	return retval;
}

__attribute__((noinline)) int get_not_dead_new(struct lockref *lr)
{
	int retval = 0;

	CMPXCHG_LOOP(new.lock_count += lockref_step(); if (old.count < 0) return 0;,
		     return 1;);
	return retval;
}

static int check(void)
{
	static const int counts[] = {
		-129, -128, -127, -2, -1, 0, 1, 2, 3, 1000,
		0x7ffffffe, 0x7fffffff, (int)0x80000000, (int)0x80000001,
	};
	int bad = 0;

	for (unsigned i = 0; i < sizeof(counts) / sizeof(counts[0]); i++) {
		struct lockref a = { .count = counts[i] }, b = a;
		int ra, rb;

		get_old(&a); get_new(&b);
		bad += memcmp(&a, &b, sizeof(a)) != 0;
		ra = put_return_old(&a); rb = put_return_new(&b);
		bad += ra != rb || memcmp(&a, &b, sizeof(a)) != 0;
		ra = get_not_dead_old(&a); rb = get_not_dead_new(&b);
		bad += ra != rb || memcmp(&a, &b, sizeof(a)) != 0;
		if (bad)
			printf("mismatch at count %d\n", counts[i]);
	}
	printf("step = 0x%016llx, %s\n", (unsigned long long)lockref_step(),
	       bad ? "MISMATCH" : "all edge values equivalent");
	return !!bad;
}

int main(int argc, char **argv)
{
	static struct lockref lr = { .count = 1 };
	long n;

	if (argc > 1 && !strcmp(argv[1], "check"))
		return check();
	if (argc < 3)
		return 2;
	n = atol(argv[2]);
	if (!strcmp(argv[1], "old")) {
		for (long i = 0; i < n; i++) {
			get_old(&lr);
			put_return_old(&lr);
		}
	} else {
		for (long i = 0; i < n; i++) {
			get_new(&lr);
			put_return_new(&lr);
		}
	}
	return lr.count != 1;
}
