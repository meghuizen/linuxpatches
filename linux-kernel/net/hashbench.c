/* Isolated copies of the kernel's hash primitives, byte-for-byte from
 * include/linux/siphash.h, include/linux/jhash.h and lib/siphash.c, so the
 * generated code can be compared across ISAs without building a kernel.
 */
typedef unsigned long long u64;
typedef long long s64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
typedef unsigned long size_t_;

static inline u64 rol64(u64 word, unsigned int shift)
{
	return (word << (shift & 63)) | (word >> ((-shift) & 63));
}
static inline u32 rol32(u32 word, unsigned int shift)
{
	return (word << (shift & 31)) | (word >> ((-shift) & 31));
}

typedef struct { u64 key[2]; } siphash_key_t;

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

/* ---- what patch 4 introduces: the IPv4 conntrack tuple, 16 bytes ---- */
u64 bench_siphash_2u64(const u64 first, const u64 second,
		       const siphash_key_t *key)
{
	PREAMBLE(16)
	v3 ^= first;
	SIPROUND;
	SIPROUND;
	v0 ^= first;
	v3 ^= second;
	SIPROUND;
	SIPROUND;
	v0 ^= second;
	POSTAMBLE
}

/* ---- what patch 4 replaces: the generic 39-byte tuple hash ---- */
u64 bench_siphash_39(const void *data, const siphash_key_t *key)
{
	const u8 *end = (const u8 *)data + 39 - (39 % sizeof(u64));
	const u8 left = 39 & (sizeof(u64) - 1);
	const u64 *in = (const u64 *)data;
	u64 m;
	PREAMBLE(39)
	while (in != (const u64 *)end) {
		m = *in++;
		v3 ^= m;
		SIPROUND;
		SIPROUND;
		v0 ^= m;
	}
	{
		const u8 *e = end;
		switch (left) {
		case 7: b |= ((u64)e[6]) << 48; /* fallthrough */
		case 6: b |= ((u64)e[5]) << 40; /* fallthrough */
		case 5: b |= ((u64)e[4]) << 32; /* fallthrough */
		case 4: b |= (u64)*(const u32 *)e; break;
		case 3: b |= ((u64)e[2]) << 16; /* fallthrough */
		case 2: b |= (u64)*(const u16 *)e; break;
		case 1: b |= e[0];
		}
	}
	POSTAMBLE
}

/* ---- HalfSipHash-1-3 permutation, the 32-bit variant ---- */
#define HSIPHASH_PERMUTATION(a, b, c, d) ( \
	(a) += (b), (b) = rol32((b), 5), (b) ^= (a), (a) = rol32((a), 16), \
	(c) += (d), (d) = rol32((d), 8), (d) ^= (c), \
	(a) += (d), (d) = rol32((d), 7), (d) ^= (a), \
	(c) += (b), (b) = rol32((b), 13), (b) ^= (c), (c) = rol32((c), 16))

u32 bench_hsiphash_perm(u32 a, u32 b, u32 c, u32 d)
{
	HSIPHASH_PERMUTATION(a, b, c, d);
	return a ^ b ^ c ^ d;
}

/* ---- jhash, as used by the flowtable ---- */
#define __jhash_mix(a, b, c)			\
{						\
	a -= c;  a ^= rol32(c, 4);  c += b;	\
	b -= a;  b ^= rol32(a, 6);  a += c;	\
	c -= b;  c ^= rol32(b, 8);  b += a;	\
	a -= c;  a ^= rol32(c, 16); c += b;	\
	b -= a;  b ^= rol32(a, 19); a += c;	\
	c -= b;  c ^= rol32(b, 4);  b += a;	\
}

#define __jhash_final(a, b, c)			\
{						\
	c ^= b; c -= rol32(b, 14);		\
	a ^= c; a -= rol32(c, 11);		\
	b ^= a; b -= rol32(a, 25);		\
	c ^= b; c -= rol32(b, 16);		\
	a ^= c; a -= rol32(c, 4);		\
	b ^= a; b -= rol32(a, 14);		\
	c ^= b; c -= rol32(b, 24);		\
}

#define JHASH_INITVAL 0xdeadbeef

static inline u32 jhash_len(const void *key, u32 length, u32 initval)
{
	u32 a, b, c;
	const u8 *k = (const u8 *)key;

	a = b = c = JHASH_INITVAL + length + initval;

	while (length > 12) {
		a += *(const u32 *)(k);
		b += *(const u32 *)(k + 4);
		c += *(const u32 *)(k + 8);
		__jhash_mix(a, b, c);
		length -= 12;
		k += 12;
	}
	switch (length) {
	case 12: c += (u32)k[11] << 24; /* fallthrough */
	case 11: c += (u32)k[10] << 16; /* fallthrough */
	case 10: c += (u32)k[9] << 8;   /* fallthrough */
	case 9:  c += k[8];             /* fallthrough */
	case 8:  b += (u32)k[7] << 24;  /* fallthrough */
	case 7:  b += (u32)k[6] << 16;  /* fallthrough */
	case 6:  b += (u32)k[5] << 8;   /* fallthrough */
	case 5:  b += k[4];             /* fallthrough */
	case 4:  a += (u32)k[3] << 24;  /* fallthrough */
	case 3:  a += (u32)k[2] << 16;  /* fallthrough */
	case 2:  a += (u32)k[1] << 8;   /* fallthrough */
	case 1:  a += k[0];
		 __jhash_final(a, b, c);
	case 0:
		 break;
	}
	return c;
}

/* flowtable today: 88-byte key */
u32 bench_jhash_88(const void *key, u32 initval)
{
	return jhash_len(key, 88, initval);
}

/* flowtable with patch 3: 42-byte head */
u32 bench_jhash_42(const void *key, u32 initval)
{
	return jhash_len(key, 42, initval);
}

/* ---- primitives in isolation: one round each, no loop, no outlining ---- */
__attribute__((noinline)) u64 one_sipround(u64 a, u64 b, u64 c, u64 d)
{
	SIPHASH_PERMUTATION(a, b, c, d);
	return a ^ b ^ c ^ d;
}

__attribute__((noinline)) u32 one_jhash_mix(u32 a, u32 b, u32 c)
{
	__jhash_mix(a, b, c);
	return a ^ b ^ c;
}

__attribute__((noinline)) u32 one_jhash_final(u32 a, u32 b, u32 c)
{
	__jhash_final(a, b, c);
	return c;
}

__attribute__((noinline)) u64 one_rol64(u64 x) { return rol64(x, 13); }
__attribute__((noinline)) u32 one_rol32(u32 x) { return rol32(x, 13); }

/* 39-byte hash, unrolled so static count == dynamic count */
u64 bench_siphash_39u(const u64 *in, const siphash_key_t *key)
{
	u64 m;
	PREAMBLE(39)
	m = in[0]; v3 ^= m; SIPROUND; SIPROUND; v0 ^= m;
	m = in[1]; v3 ^= m; SIPROUND; SIPROUND; v0 ^= m;
	m = in[2]; v3 ^= m; SIPROUND; SIPROUND; v0 ^= m;
	m = in[3]; v3 ^= m; SIPROUND; SIPROUND; v0 ^= m;
	b |= ((const u8 *)in)[32];
	POSTAMBLE
}

/* jhash with the loop unrolled: N mixes + final, straight line */
#define JH_BODY(n) \
	u32 a, b, c; const u8 *k = (const u8 *)key; \
	a = b = c = JHASH_INITVAL + (n) + initval; \
	for (int i = 0; i < (n) / 12; i++) { \
		a += *(const u32 *)(k); b += *(const u32 *)(k + 4); \
		c += *(const u32 *)(k + 8); __jhash_mix(a, b, c); k += 12; }

u32 bench_jhash_88u(const void *key, u32 initval)
{
	JH_BODY(88)
	a += k[0]; __jhash_final(a, b, c); return c;
}
u32 bench_jhash_42u(const void *key, u32 initval)
{
	JH_BODY(42)
	a += k[0]; __jhash_final(a, b, c); return c;
}

/* ---- expanded-key form: SIPHASH_CONST_i ^ key precomputed ---- */
typedef struct { u64 v[4]; } siphash_ekey_t;

#define EPREAMBLE(len) \
	u64 v0 = ekey->v[0]; \
	u64 v1 = ekey->v[1]; \
	u64 v2 = ekey->v[2]; \
	u64 v3 = ekey->v[3]; \
	u64 b = ((u64)(len)) << 56;

u64 bench_siphash_2u64_ekey(const u64 first, const u64 second,
			    const siphash_ekey_t *ekey)
{
	EPREAMBLE(16)
	v3 ^= first;  SIPROUND; SIPROUND; v0 ^= first;
	v3 ^= second; SIPROUND; SIPROUND; v0 ^= second;
	POSTAMBLE
}
