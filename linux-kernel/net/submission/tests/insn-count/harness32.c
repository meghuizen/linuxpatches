// SPDX-License-Identifier: GPL-2.0
/*
 * i386 counterpart of harness.c for the siphash calls only.  No 32-bit libc
 * is installed on the build host, so this is freestanding: _start reads
 * argv from the stack and exits via int $0x80.  i386 kernel objects use
 * -mregparm=3, so the prototypes say so.
 *
 *   harness32 <sip39|sip2u64> <iterations>
 */
typedef unsigned long long u64;
typedef struct { u64 key[2]; } siphash_key_t;

#define KABI __attribute__((regparm(3)))
extern KABI u64 __siphash_unaligned(const void *data, unsigned long len,
				    const siphash_key_t *key);
extern KABI u64 siphash_2u64(u64 a, u64 b, const siphash_key_t *key);

__asm__(".globl __fentry__\n__fentry__: ret\n"
	".globl __x86_return_thunk\n__x86_return_thunk: ret\n"
	/* the i386 kernel reads its stack canary at %fs:__ref_stack_chk_guard */
	".globl __ref_stack_chk_guard\n.set __ref_stack_chk_guard, 0x40\n"
	".globl __stack_chk_fail\n__stack_chk_fail: ud2\n");

/* Give %fs a segment for the canary reads (set_thread_area). */
struct user_desc {
	unsigned int entry_number, base_addr, limit;
	unsigned int seg_32bit:1, contents:2, read_exec_only:1,
		     limit_in_pages:1, seg_not_present:1, useable:1;
};
static unsigned char tls_area[256] __attribute__((aligned(64)));

static void setup_fs(void)
{
	struct user_desc d = { .entry_number = -1,
			       .base_addr = (unsigned int)tls_area,
			       .limit = 0xfffff, .seg_32bit = 1,
			       .limit_in_pages = 1, .useable = 1 };
	long ret;
	unsigned short sel;

	__asm__ volatile("int $0x80" : "=a"(ret) : "a"(243), "b"(&d) : "memory");
	sel = (d.entry_number << 3) | 3;
	__asm__ volatile("mov %0, %%fs" : : "r"(sel));
}

static unsigned char tuple[64] __attribute__((aligned(8)));

static long atol_(const char *s)
{
	long v = 0;

	while (*s >= '0' && *s <= '9')
		v = v * 10 + (*s++ - '0');
	return v;
}

__attribute__((used)) static int main_(int argc, char **argv)
{
	siphash_key_t key = { { 0x0706050403020100ULL, 0x0f0e0d0c0b0a0908ULL } };
	volatile u64 sink = 0;
	long n, i;

	if (argc < 3)
		return 2;
	setup_fs();
	n = atol_(argv[2]);
	tuple[0] = 10; tuple[3] = 1; tuple[20] = 10; tuple[23] = 2;
	if (argv[1][3] == '3') {		/* sip39 */
		for (i = 0; i < n; i++) {
			key.key[0] = i;
			sink = __siphash_unaligned(tuple, 39, &key);
		}
	} else {				/* sip2u64 */
		for (i = 0; i < n; i++) {
			key.key[0] = i;
			sink = siphash_2u64(0x0a0000010a000002ULL,
					    0x303901bb00000211ULL, &key);
		}
	}
	return (int)(sink & 0);
}

__asm__(".globl _start\n_start:\n"
	"  mov (%esp), %eax\n"		/* argc */
	"  lea 4(%esp), %edx\n"		/* argv */
	"  and $-16, %esp\n"
	"  push %edx\n push %eax\n"
	"  call main_\n"
	"  mov %eax, %ebx\n mov $1, %eax\n int $0x80\n");
