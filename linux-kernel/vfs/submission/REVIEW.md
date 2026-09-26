# VFS series: review for upstream submission

## Runtime results, 2026-09-23 (patchtest campaign, interleaved boots)

Each patch alone on the base commit, 2 boots interleaved with 8 base
boots (/usr/src/kbench/results/patchtest-*, UTC 20260923-1427 onwards).
All FUNC checks (openat2 selftests, errpaths, errpaths-umount,
tmpfs-umount, dmesg) PASS on every boot.

| patch | result | decision |
|---|---|---|
| dentry handoff | storm 16 procs: 11792 (11326-13011) -> 6741, 7934 kernel cycles/open, -38% | REMOVED (superseded): Mateusz Guzik's v5 of the same change is queued in vfs.git vfs-7.4.lookup as 161ce1e692d0 (+39% in his will-it-scale run). His version also hands over the mount reference (extra mntget only for O_TRUNC); ours took a new mntget on every open, so ours adds nothing. Series rebased on top of it |
| lazyalloc V2b (now 2/2, on vfs-7.4.lookup) | ENOENT ext4 5430 -> 4241, 4201 insns/open (-22%); tmpfs 8952 -> 7790, 7819 (-13%); 16-thread ENOENT -25%; successful open inside base range | KEEP, impact raised to medium |
| lockref single addition (was 2/4) | open/stat insns within +-1.3% (spread 2-4%); expected saving ~20 insns/op is below the ~150 per-boot noise; storm 16 procs 10874, 11816 vs base 11326-13011 | RE-ADDED 2026-09-26 as a standalone v2 in lockref/ after a per-ISA analysis (tests/lockref-isa/RESULTS.md): the fast path is 3-8 instructions shorter on x86-64, arm64 and riscv64; v1 regressed i386 (+9 on lockref_get), v2 keeps the 32-bit code unchanged; big-endian equivalence verified under qemu. Sent as a code-size/latency change, not a benchmark win; the in-kernel result stays "not measurable" |
| selftests openat2 (1/2) | tests build and pass on every boot | KEEP |

The final 29-boot report prints REGRESSES for lazyalloc on
vfs.stat.ext4 l1miss_per_op.  That metric is bimodal on every kernel,
baseline included (per boot either ~0.5-0.8 or ~4-8 misses per stat,
coinciding with ~4324 vs ~4400 instructions per stat); lazyalloc's 5.55
and 3.87 are inside the 9 base boots' 0.53-7.30, and stat() does not
reach path_openat().  Not a regression.

Note: vfs.lockcalls lockref_total_per_op is 0 on every kernel: lockref_*
in lib/lockref.o have no __fentry__, so the function profiler cannot count
them. That metric was not used for any decision.


Worktree /usr/src/sub-vfs. The original 14 commits are preserved,
untouched, on branch `sub-vfs-orig` (tip 5947391f6f92). Branch `sub-vfs`
holds the 4 commits exported here, in this order:

    cf230c522a3a selftests: build and run the openat2 tests again
    ffcd8df3551b lockref: adjust the count with a single addition
    8bf21f664407 fs: hand the path walk's dentry reference to the opened file
    1b4443331292 fs: allocate the struct file for open() only when it is needed

Each kernel patch also exists applied alone on 518e5b794c06, for
per-patch measurement (TESTS-TO-RUN.md):

    pt-lockref   1eb071299ac8
    pt-dentry    8ad517267859
    pt-lazyalloc 2677d744f0ed   (differs from 4/4 only in do_open(): vfs_open()
                                 instead of vfs_open_consume_dentry())

Exported as `RFC PATCH` (0000-0004) because the benefit of 2, 3 and 4
rests on static analysis; the only runtime data is from combined kernels.

Policy applied (submitter): a patch that can be fixed is fixed; a patch
that is a bug or a regression and cannot be fixed is removed; a patch
that makes no difference is removed. Every remaining patch builds and is
meant to be non-regressing on its own at its position.

## Summary

| #   | orig | subject | rec. | impact | evidence |
|-----|------|---------|------|--------|----------|
| 1/4 | 10 | selftests: build and run the openat2 tests again | SEND (can go alone) | low: test coverage | tested on host |
| 2/4 | 11 | lockref: adjust the count with a single addition | SEND (RFC) | low: all lookups, few insns/op | static + userspace model |
| 3/4 | 1  | fs: hand the path walk's dentry reference to the opened file | SEND (RFC) after prior-art check | medium: many processes opening one file | static; runtime only on combined kernel |
| 4/4 | 2  | fs: allocate the struct file for open() only when it is needed (reworked) | RFC; KEEP only if TESTS-TO-RUN T3 passes | low until measured: failed opens | static only |

Order: 1/4 and 2/4 are independent of everything; 4/4 is written on top
of 3/4 (they touch the same lines of do_open()), and pt-lazyalloc shows it
also stands alone. No patch depends on a later one.

## Removed

| orig | subject | reason |
|------|---------|--------|
| 3-8 | lsm/selinux/fs/ext4/btrfs/xfs: rcu-walk statx | bug: NULL dereference race under rcu_read_lock() (d_inode re-read after a concurrent unlink); and a stat answered in rcu-walk skips security_inode_getattr(), losing visibility for BPF fmod_ret/kprobe users |
| 9  | fs: embed the LSM's per-file blob in the struct file allocation | regression: +40 bytes per open file with AppArmor/Landlock (blob > 16 bytes pushes filp from 192 to 256); a fits-only version would help practically no distro config |
| 12 | fs: move i_fop and i_flctx off the refcount cacheline in struct inode | regression that cannot be fixed: lengthens the stat span (one more line at start offsets 40/48 mod 64) and adds an open line (0/56); no placement separates i_readcount from what open reads without adding a line on open at 7 of 8 offsets (below) |
| 13 | fs: place inode->i_data on a cacheline boundary | premise false: struct inode is not cacheline aligned (embedded at 232 in ext4_inode_info, stride-696 tmpfs objects), so the offset never gives the intended alignment |
| 14 | fs: regroup struct address_space by read-hot vs write-hot fields | no difference on its target workload (10.21M vs 10.18M iops) |

The removed patches are kept for the record as removed/00NN-*.patch (NN
= original position). The original version of 4/4 is superseded, not
removed; it is sub-vfs-orig 869328f9f734.

### Why orig 12 was removed, not fixed

Requirement for a fix: i_readcount (written on every O_RDONLY open and
close with CONFIG_FILE_LOCKING or CONFIG_IMA) on a line with no field that
open, close, stat, the path walk or read(2) read on other CPUs, at every
start offset of struct inode mod 64 that occurs, without one more line on
stat or open at any offset, without growing struct inode.

- Offsets that occur: ext4 {40,56,8,24} (stride 1040, freeptr_offset);
  tmpfs and inode_cache: all eight multiples of 8 (constructor, free
  pointer after the object, strides 696 and 568). So all eight.
- Fields open/close read near the counters: i_fop (do_dentry_open),
  i_flctx (break_lease, locks_remove_posix), i_data.host
  (file_ra_state_init reads f_mapping->host twice), i_data.a_ops and
  wb_err; i_pages shares i_data's first line and is read by every page
  cache lookup; i_acl (offset 8) is read by no_acl_inode() on nearly every
  permission check, so it cannot be swapped in as a buffer either.
- tests/inode-layout/inode-placement.py moves each candidate block (the
  four counters; i_readcount+i_writecount; i_readcount; i_fop+i_flctx) to
  every position between top-level members and checks all eight offsets
  (tests/inode-layout/model-output.txt): 0 placements meet all three
  conditions. 13 placements of the counter block separate i_readcount at
  every offset, each at the cost of one more open line at 7 of 8 offsets;
  every placement with no extra line separates it only at offset 40,
  where the base layout already does.
- The reason is structural: open touches i_readcount's line whatever the
  layout, so it only avoids an extra line by sharing that line with a
  field open reads -- which is the sharing the patch was meant to remove.
- The original patch in the same model: stat +1 line at 40/48, open +1 at
  0/56, and i_readcount still shares its line with i_data.host/i_pages at
  7 of 8 offsets. linemap-diff.py on inode.o before/after:
  tests/inode-layout/linemap-diff-p12.txt (5 of 9 lines change).
- The neighbour check for i_state, i_lock, i_hash, i_lru, i_sb_list and
  i_wb was not needed once no candidate passed the first three conditions.

## Findings about the existing data (apply to every patch below)

1. **All tree-bench runs are on tmpfs.** tree-bench.sh uses /tmp, and the
   guest image enables systemd's tmp.mount
   (/usr/src/vm/rootfs/usr/lib/systemd/system/local-fs.target.wants/tmp.mount).
   The vfs-verify report confirms it ("statx of an existing file on tmpfs").
   Consequences: the rcu-walk statx path (patches 5-8, which opt in ext4,
   btrfs, xfs but not tmpfs) was never exercised by any tree-bench run;
   the vfs-verify run shows security_inode_getattr_rcu 7 hits vs
   complete_walk 1.0/call on tmpfs. The "shared-path stat storm" shows no
   improvement for that reason (procs=8 bounces between ~12M and ~23M on
   BOTH kernels across boots; procs=16 ~11M on both).
2. **The "deterministic counters" are not deterministic across boots.** They
   repeat to <0.05% within a boot, but the same baseline kernel gave
   6111, 6143, 6178, 6212, 6245 insn:k/open across five boots on 2026-09-21
   (and "everything" 6038-6140). The cited pair (baseline-...-171431 vs
   everything-...-173002) pairs the highest baseline boot with the lowest
   everything boot: 6245.1 -> 6037.7. Median-to-median it is ~6178 -> ~6038.
3. **The cited cycles figure is not supported.** cycles:k/open 1930.8 in the
   cited baseline boot is the highest of the valid baseline boots (others
   1780-1840); "everything" boots give 1764-1852. There is no cycle
   difference that survives boot-to-boot variation.
4. **selinux=0 audit=0 apparmor=0 on every run.** Neither SELinux
   (patch 4) nor the LSM file blob (patch 9; filp objsize 192, no
   lsm_file_cache) was exercised at runtime.
5. The claim "1-4 processes within +-5%" for the open storm: at 4 processes
   the raw rate is -6.3% (8.91M -> 8.34M), norm -4.7%. Reported as such.
6. The 16-process open storm improvement is consistent across boots with
   the series (8.9-9.9M on every "everything"/"full" boot with valid spread
   vs 4.49M on the best baseline boot), but it is a combined-kernel result.
7. The vfs-verify "vfs" build (319eef3c060c, includes the original lazy-alloc patch) shows
   alloc_empty_file 1.0 per failed open: that test opened a missing name on
   tmpfs, which keeps no negative dentries, so the miss reaches
   lookup_open(), where the original version still allocated. The
   reworked 4/4 no longer allocates there (see below); neither version
   has been measured at runtime.
8. The layout analysis assumed tmpfs inodes start at {0,48,32,16} mod 64.
   shmem_inode_cache has a constructor and no freeptr_offset, so SLUB puts
   the free pointer after the object and the stride is 696, not 688:
   tmpfs inodes start at every multiple of 8 mod 64
   (tests/layout-analysis.txt, "Correction").

## Per patch

### 1/4 (orig 10). selftests: build and run the openat2 tests again -- SEND

- Verified: tools/testing/selftests/openat2 does not exist;
  `make TARGETS=openat2` fails ("No targets specified and no makefile
  found"); after the patch the four programs build and run on the host
  (tests/openat2-selftest.txt; 2 subtests need 7.x flags and fail on the
  6.18 host kernel, as expected).
- Changelog corrected (the stale target is an error, not a warning). No
  Fixes: tag possible: the history here is grafted at 08df884136f1, so the
  commit that moved the directory is not visible. The submitter should check
  whether linux-next already fixed this.
- Independent of the rest; best sent alone to linux-kselftest as PATCH.
- Impact: low -- test coverage.

### 2/4 (orig 11). lockref: adjust the count with a single addition -- SEND (RFC)

- Stands alone; strictly fewer instructions on every lockref fast path
  (lib/lockref.o, x86-64: get 44->37, get_not_zero 60->54, get_not_dead
  60->54, put_or_lock 54->51, put_return 40->39).
- The old changelog's userspace-model numbers (-36% single thread) had no
  source anywhere in the project; replaced by a model in
  tests/lockref-model/ (58.0 -> 51.0 insns, 29.8 -> 28.4 cycles per get+put,
  medians of 5 interleaved runs). The "no percentage quoted on purpose"
  narrative removed.
- Correctness: the whole-word add equals the per-count update except when
  the count half would wrap into the lock half; that needs -1 (increment) or
  0 (decrement) on big-endian. Decrementing variants bail out for count <= 0
  / <= 1 before the update; lockref_get() needs a held reference so never
  sees -1 (dead is -128). The old changelog's "exactly equivalent" was
  imprecise; the new one states the condition. BE not compiled.
- Maintainer objection: "is this measurable?" -- no, not in-kernel on this
  machine (boot noise ~130 insns/open vs a saving of a few per lockref op).
  It is a codegen cleanup; that is how it is presented.
- Impact: low.

### 3/4 (orig 1). fs: hand the path walk's dentry reference to the opened file -- SEND (RFC), after prior-art check

- Reworked: `do_dentry_open()` no longer takes references and has no bool
  parameter; `finish_open()`/`vfs_open()` call `path_get()`,
  `vfs_open_consume_dentry()` calls `mntget()`. Comments cut to kernel style,
  changelog rewritten (the old one quoted a profile of unknown provenance).
- Stands alone: yes; it only removes work. Improves by itself: one
  lockref_get() and one lockref_put_return() per open, statically verified
  (fs/open.o: path_get call gone from do_dentry_open, 304 -> 299 insns;
  vfs_open_consume_dentry calls mntget; path_openat 592 -> 594 insns).
- Evidence: static; runtime only on combined kernels (below `---` in the
  patch). Data: baseline-00824-g518e5b794c06-20260921-171431 vs
  everything-00851-g8e1d1eb19a8b-20260921-173002, sections "shared-inode open
  storm" and "cache-miss attribution".
- Correctness checked: all exits of do_dentry_open(): early error
  (cleanup_file path_put()s f_path, which now holds the walk's dentry ref ->
  nd->path.dentry cleared, no double put); O_DIRECT -EINVAL with
  FMODE_OPENED set (file keeps refs, fput in path_openat drops them); O_PATH
  never reaches do_open() (do_o_path()). atomic_open/finish_open() path
  unchanged (still path_get). terminate_walk() -> path_put() with NULL dentry
  is safe (dput(NULL)). Mount ref kept for mnt_drop_write(). The Lean model
  in ../proofs covers the ownership transfer (its "consume_dentry" variant is
  this patch's logic, although it predates the reshaping).
- Maintainer objections: (a) **prior art**: Mateusz Guzik posted the same
  transfer (v5, also transfers the mount), and Al Viro has a related series;
  our own docs (01-open-path.md sec. 6, 50-concurrency-and-scaling.md) say so.
  The submitter must find those threads on lore: if queued, DROP this; if
  pending, reply there with the data instead of sending a competing patch;
  if abandoned, send with a Link: and credit. Not answerable from here.
  (b) "numbers?" -- only combined-kernel; TESTS-TO-RUN T1 gives the
  per-patch run (branch pt-dentry).
- Impact: medium -- workloads with many processes opening one file.

### 4/4 (orig 2, reworked). fs: allocate the struct file for open() only when it is needed -- RFC, KEEP only if T3 passes

- What changed from the original: the allocation in open_last_lookups()
  now happens only when O_CREAT is set or the directory has
  ->atomic_open(); otherwise lookup_open() runs with file == NULL (it
  guards its two uses: clearing FMODE_CREATED and the fsnotify calls at
  out:) and do_open() allocates after may_open(). So plain misses that
  reach lookup_open() -- every tmpfs miss, where no negative dentry is
  kept -- no longer allocate. Comments cut to kernel style; changelog
  rewritten without the unsupported "~300 instructions" and "a build
  spends a visible fraction of its opens failing".
- Correctness, path by path:
  - rcu-walk: nothing allocates in rcu-walk. open_last_lookups() allocates
    only after lookup_fast_for_open() returned NULL, where the O_CREAT
    branch has already done try_to_unlazy() and the non-O_CREAT branch is
    already in ref-walk (lookup_fast() unlazies before returning NULL);
    do_open() allocates after complete_walk().
  - -ECHILD / -ESTALE / -EOPENSTALE retries: path_openat() frees only a
    non-NULL file; each retry starts with file == NULL.
  - Trailing-symlink loop: open_last_lookups() may run several times; a
    file allocated in an earlier round is reused (as before); FMODE_CREATED
    cannot survive a round because it ends the loop.
  - do_open(): f_mode is sampled once; file == NULL means lookup_open()
    neither created nor opened, which is the only way those bits are set.
    ENFILE from the late allocation: vfs_open*() is skipped, nd->path
    stays with the walk (terminate_walk() drops it), security_file_post_open()
    and handle_truncate() are skipped, mnt_drop_write() still balances an
    O_TRUNC mnt_want_write().
  - O_TMPFILE, O_PATH: allocate up front as before (dispatch now tests
    op->open_flag, which is what f_flags was initialised from).
  - ->atomic_open() filesystems (nfs, cifs, fuse, ceph, 9p, gfs2): the
    decision reads nd->path.dentry->d_inode->i_op, the same inode
    lookup_open() uses; the dentry is pinned in ref-walk, so the answer
    cannot change between the two. They allocate before lookup_open() as
    before; a miss there still allocates (atomic_open needs the file).
  - O_CREAT: allocated before lookup_open() takes the directory lock, so
    ENFILE at the limit still happens before anything is created.
    O_CREAT|O_EXCL on an existing name still allocates (EEXIST is decided
    in do_open() after lookup_open()); the changelog does not claim it.
  - vfs_lookup_open() (nfsd) passes its own file; unaffected.
- Visible change: at file-max, an open that fails in the walk returns the
  walk's error instead of ENFILE; audit_inode() now runs before an ENFILE
  on the success path. The capable(CAP_SYS_ADMIN) check at the limit runs
  later (after the walk). All stated in the changelog or here.
- Static evidence (tests/lazyalloc-static/results.txt), instructions
  executed inside path_openat() with do_open()/open_last_lookups()
  inlined:
    success, cached file:    164 -> 166 (series), 163 -> 165 (alone)
    ENOENT, cached negative: 103 -> 97, and no alloc_empty_file() /
                             fput_close() calls: 120 instructions in
                             fs/file_table.c plus 7 calls (slab alloc/free,
                             security_file_alloc/free, mutex_init_generic,
                             2x percpu_counter_add_batch), incl. 3 locked
                             atomics (2 on cred->usage, 1 on f_ref)
  path_openat grows 576 -> 720 instructions statically (gcc duplicates the
  tail of do_open() for file == NULL / != NULL); the traced paths do not
  get longer.
- Stands alone: yes (pt-lazyalloc compiles, W=1 clean). Improves by
  itself: failed opens do less work (static); the success path +2
  instructions, within the ~10 the decision rule allows.
- Maintainer objections likely: "numbers?" (none at runtime; T3); "is it
  worth a struct file ** through two functions?" (answered only by T3);
  the ENFILE ordering change (argued in the changelog).
- Impact: low until measured -- failing opens (search-path probing by
  compilers, loaders, interpreters); nothing on the success path.

## Checks run

- W=1 compile at every commit of the series and of each pt-* branch:
  tests/compile-each-submitted.txt (script tests/compile-each.sh). All
  touched objects: 0 warnings; the base commit also gives 0 for the same
  objects.
- checkpatch --strict on 0001-0004: only "Missing Signed-off-by"
  (intentional; the submitter adds it). 0 warnings, 0 checks. On the
  cover letter checkpatch flags the placeholder addresses (Mateusz Guzik
  without address, the Signed-off-by placeholder) and the table width;
  those are notes for the submitter, not patch content.
- Exported patches apply to 518e5b794c06 and produce the sub-vfs tree
  exactly (git apply --cached into a temporary index; tree 440030310845).
- Static path traces: tests/lazyalloc-static/. Layout model:
  tests/inode-layout/.
- sparse/smatch: not installed on the host; not run.
- Identity: author on all commits Michiel <367462+meghuizen@users.noreply.github.com>;
  the identity grep (the two forbidden strings from the brief) over
  submission/ returns nothing.
