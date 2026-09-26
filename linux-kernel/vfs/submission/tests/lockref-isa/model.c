/*
 * Header-free model of lib/lockref.c's CMPXCHG_LOOP, for looking at the
 * generated code on several ISAs (gcc -m32 -c, aarch64 -mbig-endian, ...).
 * Same struct layout and same loop shape as the kernel; the lock is modelled
 * as a qspinlock (unlocked == 0). The slow path is an external call so the
 * compiler keeps the structure.
 */
typedef unsigned long long u64;
typedef long long s64;
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

extern void slow_get(struct lockref *);
extern int slow_get_not_zero(struct lockref *);
extern int slow_put_or_lock(struct lockref *);
extern int slow_get_not_dead(struct lockref *);

#define READ_ONCE(x) (*(volatile __typeof__(x) *)&(x))

#define CMPXCHG_LOOP(CODE, SUCCESS) do {				\
	int retry = 100;						\
	struct lockref old;						\
	old.lock_count = READ_ONCE(lr->lock_count);			\
	while (__builtin_expect(old.lock == 0, 1)) {			\
		struct lockref new = old;				\
		CODE							\
		if (__builtin_expect(__atomic_compare_exchange_n(	\
				&lr->lock_count, &old.lock_count,	\
				new.lock_count, 0,			\
				__ATOMIC_RELAXED, __ATOMIC_RELAXED), 1)) { \
			SUCCESS;					\
		}							\
		if (!--retry)						\
			break;						\
	}								\
} while (0)

static inline __attribute__((always_inline)) u64 lockref_step(void)
{
	const union {
		struct lockref lr;
		u64 v;
	} one = { .lr = { .count = 1 } };

	return one.v;
}

/* ---- old form: new.count++ / new.count-- ---- */

__attribute__((noinline)) void get_old(struct lockref *lr)
{
	CMPXCHG_LOOP(new.count++;, return;);
	slow_get(lr);
}

__attribute__((noinline)) int get_not_zero_old(struct lockref *lr)
{
	CMPXCHG_LOOP(new.count++; if (old.count <= 0) return 0;, return 1;);
	return slow_get_not_zero(lr);
}

__attribute__((noinline)) int put_return_old(struct lockref *lr)
{
	CMPXCHG_LOOP(new.count--; if (old.count <= 0) return -1;, return new.count;);
	return -1;
}

__attribute__((noinline)) int put_or_lock_old(struct lockref *lr)
{
	CMPXCHG_LOOP(new.count--; if (old.count <= 1) break;, return 1;);
	return slow_put_or_lock(lr);
}

__attribute__((noinline)) int get_not_dead_old(struct lockref *lr)
{
	CMPXCHG_LOOP(new.count++; if (old.count < 0) return 0;, return 1;);
	return slow_get_not_dead(lr);
}

/* ---- new form (the patch): whole-word add of the count's unit ---- */

__attribute__((noinline)) void get_new(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count += lockref_step();, return;);
	slow_get(lr);
}

__attribute__((noinline)) int get_not_zero_new(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count += lockref_step(); if (old.count <= 0) return 0;, return 1;);
	return slow_get_not_zero(lr);
}

__attribute__((noinline)) int put_return_new(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count -= lockref_step(); if (old.count <= 0) return -1;, return new.count;);
	return -1;
}

__attribute__((noinline)) int put_or_lock_new(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count -= lockref_step(); if (old.count <= 1) break;, return 1;);
	return slow_put_or_lock(lr);
}

__attribute__((noinline)) int get_not_dead_new(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count += lockref_step(); if (old.count < 0) return 0;, return 1;);
	return slow_get_not_dead(lr);
}

#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
/*
 * ---- exploration, little-endian only: also test the condition on the
 * whole word. count is the high half, so count <= 0 <=> (s64)word < 1<<32,
 * count <= 1 <=> (s64)word < 2<<32, count < 0 <=> (s64)word < 0, whatever
 * the lock half holds. Not valid on big-endian.
 */
__attribute__((noinline)) int get_not_zero_le(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count += lockref_step();
		     if ((s64)old.lock_count < (s64)lockref_step()) return 0;, return 1;);
	return slow_get_not_zero(lr);
}

__attribute__((noinline)) int put_return_le(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count -= lockref_step();
		     if ((s64)old.lock_count < (s64)lockref_step()) return -1;, return new.count;);
	return -1;
}

__attribute__((noinline)) int put_or_lock_le(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count -= lockref_step();
		     if ((s64)old.lock_count < (s64)(2 * lockref_step())) break;, return 1;);
	return slow_put_or_lock(lr);
}

__attribute__((noinline)) int get_not_dead_le(struct lockref *lr)
{
	CMPXCHG_LOOP(new.lock_count += lockref_step();
		     if ((s64)old.lock_count < 0) return 0;, return 1;);
	return slow_get_not_dead(lr);
}
#endif

/* the step constant, to read off per target */
u64 step_value(void) { return lockref_step(); }
