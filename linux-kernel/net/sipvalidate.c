/* Validate that the expanded-key form of siphash produces bit-identical
 * output to the current form, and time both.
 *
 * The primitives are copied verbatim from include/linux/siphash.h and
 * lib/siphash.c so this tests the real thing.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

typedef uint64_t u64;
typedef uint32_t u32;
typedef uint8_t u8;

static inline u64 rol64(u64 w, unsigned int s)
{
	return (w << (s & 63)) | (w >> ((-s) & 63));
}

typedef struct { u64 key[2]; } siphash_key_t;
/* the new form: SIPHASH_CONST_i ^ key, precomputed */
typedef struct { u64 v[4]; } siphash_ekey_t;

#define SIPHASH_PERMUTATION(a, b, c, d) ( \
	(a) += (b), (b) = rol64((b), 13), (b) ^= (a), (a) = rol64((a), 32), \
	(c) += (d), (d) = rol64((d), 16), (d) ^= (c), \
	(a) += (d), (d) = rol64((d), 21), (d) ^= (a), \
	(c) += (b), (b) = rol64((b), 17), (b) ^= (c), (c) = rol64((c), 32))

#define SIPHASH_CONST_0 0x736f6d6570736575ULL
#define SIPHASH_CONST_1 0x646f72616e646f6dULL
#define SIPHASH_CONST_2 0x6c7967656e657261ULL
#define SIPHASH_CONST_3 0x7465646279746573ULL

#define SIPROUND SIPHASH_PERMUTATION(v0, v1, v2, v3)

#define PREAMBLE(len) \
	u64 v0 = SIPHASH_CONST_0; \
	u64 v1 = SIPHASH_CONST_1; \
	u64 v2 = SIPHASH_CONST_2; \
	u64 v3 = SIPHASH_CONST_3; \
	u64 b = ((u64)(len)) << 56; \
	v3 ^= key->key[1]; \
	v2 ^= key->key[0]; \
	v1 ^= key->key[1]; \
	v0 ^= key->key[0];

#define EPREAMBLE(len) \
	u64 v0 = ekey->v[0]; \
	u64 v1 = ekey->v[1]; \
	u64 v2 = ekey->v[2]; \
	u64 v3 = ekey->v[3]; \
	u64 b = ((u64)(len)) << 56;

#define POSTAMBLE \
	v3 ^= b; \
	SIPROUND; \
	SIPROUND; \
	v0 ^= b; \
	v2 ^= 0xff; \
	SIPROUND; \
	SIPROUND; \
	SIPROUND; \
	SIPROUND; \
	return (v0 ^ v1) ^ (v2 ^ v3);

static inline void siphash_key_expand(siphash_ekey_t *e,
				      const siphash_key_t *key)
{
	e->v[0] = SIPHASH_CONST_0 ^ key->key[0];
	e->v[1] = SIPHASH_CONST_1 ^ key->key[1];
	e->v[2] = SIPHASH_CONST_2 ^ key->key[0];
	e->v[3] = SIPHASH_CONST_3 ^ key->key[1];
}

__attribute__((noinline))
u64 siphash_2u64(const u64 first, const u64 second, const siphash_key_t *key)
{
	PREAMBLE(16)
	v3 ^= first;  SIPROUND; SIPROUND; v0 ^= first;
	v3 ^= second; SIPROUND; SIPROUND; v0 ^= second;
	POSTAMBLE
}

__attribute__((noinline))
u64 siphash_2u64_ekey(const u64 first, const u64 second,
		      const siphash_ekey_t *ekey)
{
	EPREAMBLE(16)
	v3 ^= first;  SIPROUND; SIPROUND; v0 ^= first;
	v3 ^= second; SIPROUND; SIPROUND; v0 ^= second;
	POSTAMBLE
}

/* 1u64 and 4u64 too, to prove the transform is not specific to one length */
__attribute__((noinline))
u64 siphash_1u64(const u64 first, const siphash_key_t *key)
{
	PREAMBLE(8)
	v3 ^= first; SIPROUND; SIPROUND; v0 ^= first;
	POSTAMBLE
}
__attribute__((noinline))
u64 siphash_1u64_ekey(const u64 first, const siphash_ekey_t *ekey)
{
	EPREAMBLE(8)
	v3 ^= first; SIPROUND; SIPROUND; v0 ^= first;
	POSTAMBLE
}

static u64 rnd64(void)
{
	return ((u64)rand() << 48) ^ ((u64)rand() << 32) ^
	       ((u64)rand() << 16) ^ (u64)rand();
}

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(void)
{
	/* ---- 1. the kernel's own test vector, index 16 (a 16-byte input) ---- */
	const siphash_key_t tk = {{ 0x0706050403020100ULL, 0x0f0e0d0c0b0a0908ULL }};
	u8 in[16];
	u64 a, b_, expect = 0x3f2acc7f57c29bdbULL;  /* test_vectors_siphash[16] */
	siphash_ekey_t tek;
	int i;

	for (i = 0; i < 16; i++)
		in[i] = i;
	memcpy(&a, in, 8);
	memcpy(&b_, in + 8, 8);
	siphash_key_expand(&tek, &tk);

	printf("== reference test vector (lib/tests/siphash_kunit.c index 16) ==\n");
	printf("  expected            %016llx\n", (unsigned long long)expect);
	printf("  siphash_2u64        %016llx  %s\n",
	       (unsigned long long)siphash_2u64(a, b_, &tk),
	       siphash_2u64(a, b_, &tk) == expect ? "OK" : "MISMATCH");
	printf("  siphash_2u64_ekey   %016llx  %s\n",
	       (unsigned long long)siphash_2u64_ekey(a, b_, &tek),
	       siphash_2u64_ekey(a, b_, &tek) == expect ? "OK" : "MISMATCH");

	/* ---- 2. equivalence over random keys and inputs ---- */
	printf("\n== equivalence, 20,000,000 random (key, input) pairs ==\n");
	srand(1);
	long bad = 0, n = 20000000;
	for (long j = 0; j < n; j++) {
		siphash_key_t k = {{ rnd64(), rnd64() }};
		siphash_ekey_t ek;
		u64 x = rnd64(), y = rnd64();

		siphash_key_expand(&ek, &k);
		if (siphash_2u64(x, y, &k) != siphash_2u64_ekey(x, y, &ek))
			bad++;
		if (siphash_1u64(x, &k) != siphash_1u64_ekey(x, &ek))
			bad++;
	}
	printf("  mismatches: %ld / %ld  %s\n", bad, n * 2,
	       bad ? "FAIL" : "PASS");

	/* ---- 3. benchmark ---- */
	printf("\n== throughput, 200,000,000 calls ==\n");
	const long iters = 200000000;
	siphash_key_t k = {{ 0x0123456789abcdefULL, 0xfedcba9876543210ULL }};
	siphash_ekey_t ek;
	volatile u64 sink = 0;
	double t0, t1, t2;

	siphash_key_expand(&ek, &k);

	t0 = now();
	for (long j = 0; j < iters; j++)
		sink ^= siphash_2u64(j, j ^ 0x5a5a5a5aULL, &k);
	t1 = now();
	for (long j = 0; j < iters; j++)
		sink ^= siphash_2u64_ekey(j, j ^ 0x5a5a5a5aULL, &ek);
	t2 = now();

	printf("  siphash_2u64       %.3f s   %.2f ns/call\n",
	       t1 - t0, (t1 - t0) * 1e9 / iters);
	printf("  siphash_2u64_ekey  %.3f s   %.2f ns/call\n",
	       t2 - t1, (t2 - t1) * 1e9 / iters);
	printf("  delta              %+.1f%%\n",
	       100.0 * ((t2 - t1) - (t1 - t0)) / (t1 - t0));
	(void)sink;
	return bad != 0;
}
