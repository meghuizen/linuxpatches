// SPDX-License-Identifier: GPL-2.0
/*
 * Run hash functions taken from kernel objects (built from the tree, then
 * linked into this static userspace program) so that perf can count the
 * instructions they retire per call.  See README in this directory.
 *
 *   harness <mode> <iterations>
 *
 * modes:
 *   foh-plain   flow_offload_hash() on an IPv4 tuple with encap[]/tun zero
 *   foh-encap   flow_offload_hash() on the same tuple with one VLAN encap
 *   sip39       __siphash_unaligned() over 39 bytes (generic conntrack path)
 *   sip2u64     siphash_2u64() (patch 4 IPv4 path)
 *   null        an empty function with the sip39 loop: loop and call overhead
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Kernel return thunk and ftrace hook: at runtime the kernel patches these
 * to a plain ret and a nop; here they are a ret each. */
__asm__(".globl __fentry__\n__fentry__: ret\n"
	".globl __x86_return_thunk\n__x86_return_thunk: ret\n"
	".globl nullfn\nnullfn: xor %eax,%eax\n ret\n");

typedef struct { unsigned long long key[2]; } siphash_key_t;

extern unsigned long long nullfn(const void *a, unsigned long b,
				 const siphash_key_t *key);

extern unsigned int flow_offload_hash(const void *data, unsigned int len,
				      unsigned int seed);
extern unsigned long long __siphash_unaligned(const void *data,
					      unsigned long len,
					      const siphash_key_t *key);
extern unsigned long long siphash_2u64(unsigned long long a,
				       unsigned long long b,
				       const siphash_key_t *key);

static unsigned char tuple[128] __attribute__((aligned(8)));

int main(int argc, char **argv)
{
	siphash_key_t key = { { 0x0706050403020100ULL, 0x0f0e0d0c0b0a0908ULL } };
	const char *mode = argv[1];
	long n = atol(argv[2]);
	volatile unsigned long long sink = 0;
	long i;

	/* struct flow_offload_tuple, offsets from pahole */
	tuple[0] = 10; tuple[3] = 1;		/* src_v4 */
	tuple[16] = 10; tuple[19] = 2;		/* dst_v4 */
	tuple[32] = 0x30; tuple[33] = 0x39;	/* src_port */
	tuple[34] = 0x01; tuple[35] = 0xbb;	/* dst_port */
	tuple[36] = 3;				/* iifidx */
	tuple[40] = 2; tuple[41] = 17;		/* l3proto, l4proto */
	if (!strcmp(mode, "foh-encap")) {
		tuple[42] = 100;		/* encap[0].id */
		tuple[44] = 0x81;		/* encap[0].proto */
	}

	if (!strncmp(mode, "foh", 3)) {
		for (i = 0; i < n; i++)
			sink = flow_offload_hash(tuple, 0, i);
	} else if (!strcmp(mode, "sip39")) {
		for (i = 0; i < n; i++) {
			key.key[0] = i;
			sink = __siphash_unaligned(tuple, 39, &key);
		}
	} else if (!strcmp(mode, "sip2u64")) {
		for (i = 0; i < n; i++) {
			key.key[0] = i;
			sink = siphash_2u64(0x0a0000010a000002ULL,
					    0x303901bb00000211ULL, &key);
		}
	} else if (!strcmp(mode, "null")) {
		for (i = 0; i < n; i++) {
			key.key[0] = i;
			sink = nullfn(tuple, 39, &key);
		}
	} else {
		fprintf(stderr, "unknown mode\n");
		return 2;
	}
	return (int)(sink & 0);
}
