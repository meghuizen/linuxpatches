# VFS: tests that need a boot

For the coordinator. One VM at a time. Every rate comparison below must be an
interleaved sequence (A, B, A, B, A, B), and only rows with control
`spread=` <= 15% count. Perf-counter figures are compared as the MEDIAN over
the three boots of each kernel, not a single boot: the existing data shows
the "deterministic" insn:k/open varying by up to ~130 instructions between
boots of the same kernel (baseline 518e5b794c06: 6111, 6143, 6178, 6212, 6245
across five boots on 2026-09-21), so a single pair cannot resolve a delta
below ~150 instructions. Where a mechanism can be checked with an exact
count (ftrace function_profile hit counts), that check is listed too; it
does not depend on the boot.

IMPORTANT harness fact: tree-bench.sh works under /tmp, and the guest image
enables systemd's tmp.mount (usr/lib/systemd/system/local-fs.target.wants/
tmp.mount), so /tmp is tmpfs. All existing tree-bench numbers are tmpfs
numbers. Tests below that need ext4 say so and use /var/tmp (on the ext4
root).

Kernel variants (all branches in /usr/src/sub-vfs; each is the base plus
exactly the named patch):

| name      | branch        | tip          | contents |
|-----------|---------------|--------------|----------|
| `base`    | -             | 518e5b794c06 | base |
| `pdentry` | pt-dentry     | 8ad517267859 | base + "fs: hand the path walk's dentry reference to the opened file" (submission 3/4) |
| `plockref`| pt-lockref    | 1eb071299ac8 | base + "lockref: adjust the count with a single addition" (2/4) |
| `plazy`   | pt-lazyalloc  | 2677d744f0ed | base + "fs: allocate the struct file for open() only when it is needed" (4/4, rebased onto base) |
| `series`  | sub-vfs       | 1b4443331292 | the submitted series 1-4 |

The selftest patch (1/4) has no kernel effect and needs no kernel of its own.

---

## T1 -- dentry handoff on its own (decides SEND vs HOLD for 3/4)

Kernels: base, pdentry. Sequence base, pdentry, base, pdentry, base, pdentry.
Default cmdline.

Command (inside the guest, per boot): the normal tree-bench run
(`kbench.auto=1`), which gives the deterministic counters and the
shared-inode open storm.

Expected:
- deterministic counters: median insn:k/open lower on pdentry (the static
  count predicts a few tens of instructions: one lockref_get() and one
  lockref_put_return() call chain per open are gone).
- shared-inode open storm: 16-process row higher on pdentry than on base in
  each adjacent pair with spread <= 15% (the combined kernel showed 4.49M ->
  9.31M; pdentry alone should show part of that).
- 1-, 2-, 4-process rows: norm= within +-5%.
- correctness section: "OK: dentries released, no reference leak".

What changes the recommendation: any 1-4 process row worse by more than 5%
(norm) in two of the three pairs, or a leak/complaint -> HOLD. No
improvement at 16 processes in any valid pair -> the changelog loses its
runtime paragraph (the patch still stands on the static argument).

## T2 -- error paths of 3/4 and 4/4 (correctness)

Kernel: series. Inside the guest:

    # openat2 selftests (exercise every do_open() exit via RESOLVE_*):
    make -C tools/testing/selftests TARGETS=filesystems/openat2 run_tests
    # O_DIRECT on tmpfs (the -EINVAL return with FMODE_OPENED set),
    # O_TRUNC (mnt_want_write/mnt_drop_write), EACCES after the walk,
    # ENOENT on ext4 and tmpfs, O_CREAT|O_EXCL on an existing name:
    cat > /tmp/t2.c <<'EOF'
    #define _GNU_SOURCE
    #include <fcntl.h>
    #include <stdio.h>
    #include <unistd.h>
    int main(void)
    {
            int i, fd, bad = 0;
            for (i = 0; i < 200000; i++) {
                    fd = open("/dev/shm/t2", O_RDWR | O_CREAT | O_DIRECT, 0600);
                    if (fd >= 0) close(fd);
                    fd = open("/var/tmp/t2", O_RDWR | O_CREAT | O_TRUNC, 0600);
                    if (fd >= 0) close(fd); else bad++;
                    fd = open("/var/tmp/t2ro", O_RDWR);   /* EACCES as nobody */
                    if (fd >= 0) close(fd);
                    fd = open("/var/tmp/t2-missing", O_RDONLY);
                    if (fd >= 0) { close(fd); bad++; }
                    fd = open("/dev/shm/t2-missing", O_RDONLY);
                    if (fd >= 0) { close(fd); bad++; }
                    fd = open("/var/tmp/t2", O_RDWR | O_CREAT | O_EXCL, 0600);
                    if (fd >= 0) { close(fd); bad++; }
            }
            printf("bad=%d\n", bad);
            return 0;
    }
    EOF
    gcc -O2 -o /tmp/t2 /tmp/t2.c
    touch /var/tmp/t2ro; chmod 0444 /var/tmp/t2ro
    grep -E '^(dentry|filp) ' /proc/slabinfo; cat /proc/sys/fs/file-nr
    setpriv --reuid=65534 --regid=65534 --clear-groups /tmp/t2 || true
    /tmp/t2; echo 2 > /proc/sys/vm/drop_caches
    grep -E '^(dentry|filp) ' /proc/slabinfo; cat /proc/sys/fs/file-nr
    dmesg | grep -iE "warn|bug|leak" | tail

Then the ENFILE ordering of 4/4 (as root; ENFILE is only returned to
tasks without CAP_SYS_ADMIN, so the opener runs as nobody):

    cat > /tmp/t2enfile.c <<'EOF'
    #include <errno.h>
    #include <fcntl.h>
    #include <stdio.h>
    #include <string.h>
    #include <unistd.h>
    int main(void)
    {
            int fd, n = 0;
            while ((fd = open("/var/tmp/t2ro", O_RDONLY)) >= 0)
                    n++;
            printf("filled %d, last errno %s\n", n, strerror(errno));
            fd = open("/var/tmp/t2-missing", O_RDONLY);
            printf("missing name: %s (expect ENOENT on series, ENFILE on base)\n",
                   fd < 0 ? strerror(errno) : "opened?!");
            fd = open("/var/tmp/t2-new", O_RDWR | O_CREAT, 0600);
            printf("create at limit: %s\n", fd < 0 ? strerror(errno) : "opened?!");
            printf("t2-new exists afterwards: %s (expect no)\n",
                   access("/var/tmp/t2-new", F_OK) ? "no" : "yes");
            return 0;
    }
    EOF
    gcc -O2 -o /tmp/t2enfile /tmp/t2enfile.c
    rm -f /var/tmp/t2-new
    old=$(cat /proc/sys/fs/file-max)
    echo $(( $(cut -f1 /proc/sys/fs/file-nr) + 200 )) > /proc/sys/fs/file-max
    setpriv --reuid=65534 --regid=65534 --clear-groups /tmp/t2enfile
    echo $old > /proc/sys/fs/file-max

Expected: all openat2 tests pass except emptypath_test if the guest libc
lacks O_EMPTYPATH; `bad=0`; dentry and filp active counts return to their
starting level after drop_caches; file-nr returns to its starting value; no
WARN/BUG in dmesg. ENFILE test: "filled" ends with "Too many open files in
system"; the missing name gives ENOENT on series; the create gives ENFILE
and t2-new does not exist.

What changes the recommendation: any leak, WARN, `bad` != 0, or t2-new
created at the limit -> the responsible patch is withdrawn.

## T3 -- lazy struct file allocation on its own (decides KEEP vs DROP for 4/4)

Kernels: base, plazy. Interleaved base, plazy, base, plazy, base, plazy.
Needs an ext4 path (/var/tmp) and a tmpfs path (/tmp).

Inside the guest, per boot:

    mkdir -p /var/tmp/neg; : > /var/tmp/neg/exists
    cat > /tmp/t3.c <<'EOF'
    #include <fcntl.h>
    #include <stdlib.h>
    #include <unistd.h>
    int main(int c, char **v)
    {
            long n = atol(v[2]);
            for (long i = 0; i < n; i++) {
                    int fd = open(v[1], O_RDONLY);
                    if (fd >= 0) close(fd);
            }
            return 0;
    }
    EOF
    gcc -O2 -o /tmp/t3 /tmp/t3.c
    N=2000000
    for f in /var/tmp/neg/missing /tmp/missing /var/tmp/neg/exists; do
        /tmp/t3 $f 1000                      # warm; creates the ext4 negative dentry
        /tmp/t3 $f 1                         # startup cost, subtracted below
        taskset -c 1 perf stat -x, -e instructions:k,cycles:k,L1-dcache-load-misses /tmp/t3 $f 1
        taskset -c 1 perf stat -x, -e instructions:k,cycles:k,L1-dcache-load-misses /tmp/t3 $f $N
    done
    # per-op = (count at N - count at 1) / (N - 1)

    # exact mechanism check, boot-independent (CONFIG_FUNCTION_PROFILER):
    T=/sys/kernel/tracing
    echo alloc_empty_file > $T/set_ftrace_filter
    for f in /var/tmp/neg/missing /tmp/missing /var/tmp/neg/exists; do
        echo 0 > $T/function_profile_enabled; echo 1 > $T/function_profile_enabled
        /tmp/t3 $f 100000
        echo 0 > $T/function_profile_enabled
        echo "$f"; grep -h alloc_empty_file $T/trace_stat/function* | awk '{s+=$2} END {print s/100000, "calls per open"}'
    done
    echo > $T/set_ftrace_filter

    # contended failed opens (cred->usage is shared by the threads of a
    # process): 16 threads of one process, each looping on the missing ext4
    # name; report opens/s. Rate row: only from interleaved pairs with the
    # control spread <= 15%.
    cat > /tmp/t3mt.c <<'EOF'
    #include <fcntl.h>
    #include <pthread.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <time.h>
    #include <unistd.h>
    static const char *path; static long n;
    static void *run(void *a)
    {
            for (long i = 0; i < n; i++) {
                    int fd = open(path, O_RDONLY);
                    if (fd >= 0) close(fd);
            }
            return NULL;
    }
    int main(int c, char **v)
    {
            int t = atoi(v[3]); pthread_t th[64]; struct timespec a, b;
            path = v[1]; n = atol(v[2]);
            clock_gettime(CLOCK_MONOTONIC, &a);
            for (int i = 0; i < t; i++) pthread_create(&th[i], NULL, run, NULL);
            for (int i = 0; i < t; i++) pthread_join(th[i], NULL);
            clock_gettime(CLOCK_MONOTONIC, &b);
            printf("%.0f opens/s\n", t * n / ((b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9));
            return 0;
    }
    EOF
    gcc -O2 -pthread -o /tmp/t3mt /tmp/t3mt.c
    for t in 1 16; do /tmp/t3mt /var/tmp/neg/missing 500000 $t; done

Expected (static prediction in tests/lazyalloc-static/results.txt):
- function_profile: base 1.0 alloc_empty_file per open on all three paths;
  plazy 0.0 on /var/tmp/neg/missing and /tmp/missing, 1.0 on
  /var/tmp/neg/exists.
- insn:k per failed open lower on plazy on both ext4 and tmpfs, by
  roughly 120 instructions in fs/file_table.c plus the slab, LSM and
  percpu-counter calls (several hundred in total).
- insn:k per successful open: +2 predicted.
- 16-thread failed-open rate higher on plazy (no get_cred/put_cred on the
  shared cred->usage).

Decision rule: KEEP 4/4 only if (a) function_profile shows 0.0 on both
failed paths on plazy, (b) median insn:k per failed open is lower on plazy
than on base on BOTH ext4 and tmpfs by more than the boot-to-boot range of
base for that row, and (c) a successful open costs no more than ~10
instructions extra (median plazy - median base <= 10; if the boot-to-boot
range of that row is wider than 10, require the plazy median to lie inside
base's range and rely on the static +2). Otherwise DROP 4/4.

## T4 -- lockref on its own (optional; 2/4 is presented as a codegen cleanup)

Kernels: base, plockref, interleaved. The tree-bench deterministic
counters; expected: median insn:k/stat and insn:k/open lower by a few
instructions per lockref operation, which is below the boot noise, so no
outcome changes the recommendation except a correctness failure (T2 run on
series covers the lockref paths as well).

---

## Tests no longer needed

The patches they were written for were removed from the series (see
REVIEW.md, "Removed"): rcu-walk statx (old T4), LSM file blob (old T5),
address_space regroup and i_data alignment (old T6).

For the removed inode layout patch (sub-vfs-orig 08b6d7b92200) the static
model in tests/inode-layout/ already shows the uncontended regression (one
more line for stat at start offsets 40/48 mod 64, one more line for open at
0/56), so no boot is needed to decide it. Should anyone want to revisit a
layout change, the test is: kernels base and base+layout; on ext4 files in
/var/tmp (never /tmp), pinned single-thread loops of statx() and of
open()+close() on 64 different files (so that inodes at all start offsets
are sampled), `perf stat -e instructions:k,cycles:k,L1-dcache-load-misses`
per op; plus the shared-inode open storm (tree-bench) at 1/4/16 processes.
Keep only if the 16-process storm improves in every valid interleaved pair
and no single-thread counter is worse (median over three boots each).
