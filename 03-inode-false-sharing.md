# Task 3 — Fix false sharing in `struct inode`: refcounts vs `i_fop`

**What the patch does, in one sentence:** it moves two read-mostly pointers (`i_fop`, `i_flctx`) off the cache line they currently share with six constantly-written atomic counters (`i_count`, `i_writecount`, `i_dio_count`, ...), so refcount traffic on one CPU stops invalidating the `open()` path on every other CPU.

| | |
|---|---|
| Target files | `include/linux/fs.h` (Part 1), `fs/inode.c` (Part 2) |
| Kernel | Linux 7.2, vanilla, `/mnt/data/linux-src/linux-7.2` |
| Patch size | Part 1: move 2 declarations. Part 2: ~15 lines of build-time asserts |
| Risk | Low |
| Realistic gain | Removes a real false-sharing conflict on the `open()`/`iget`/`iput` path; scales with core count and inode sharing |

---

## 1. Background: false sharing, the invisible bug

False sharing is the nastiest cache problem because the code looks perfectly fine.

Two CPUs use two **unrelated** fields that happen to sit in the same 64-byte cache line. The hardware keeps caches coherent per **line**, not per field:

```
CPU 0 writes field_a  ->  must own the whole line exclusively
CPU 1 reads  field_b  ->  must pull the line back from CPU 0
CPU 0 writes field_a  ->  must steal it back
... forever
```

The line ping-pongs between caches. Nobody reads anyone else's data. The program is correct. It is just slow — sometimes dramatically.

The rule:

> Never put a frequently-written field on the same cache line as a frequently-read one.

The kernel documents this exact problem class, the real `mmap_lock` regression it caused, and the two tools for it — `perf c2c` to find it, `pahole` to see it — in `Documentation/kernel-hacking/false-sharing.rst`.

---

## 2. The problem, with evidence

`struct inode` is the kernel's "one per file" object: 624 bytes, 10 cache lines (measured; config-dependent). Line 5 (bytes 320-383) contains:

```
	/* --- cacheline 5 boundary (320 bytes) --- */
	atomic64_t  i_version;     WRITTEN on every metadata change
	atomic64_t  i_sequence;    WRITTEN by futex
	atomic_t    i_count;       WRITTEN on every iget()/iput()
	atomic_t    i_dio_count;   WRITTEN on every direct I/O
	atomic_t    i_writecount;  WRITTEN on every open-for-write
	atomic_t    i_readcount;   WRITTEN on every read-only open
	const struct file_operations *i_fop;   READ on every open(), set once
	struct file_lock_context     *i_flctx; READ on lock checks, rarely set
```

Six write-hot atomics and two read-mostly pointers on one line.

The concrete collision, with the actual code on both sides:

- **The reader:** every `open()` runs `do_dentry_open()`, which does `f->f_op = fops_get(inode->i_fop)` — `fs/open.c:918`.
- **The writers:** every inode grab/release does an atomic read-modify-write on `i_count`, 16 bytes away on the same line — `fs/inode.c:1594`, `:1646`, `:2047` (`atomic_add_unless(&inode->i_count, ...)`).

Now picture a genuinely shared hot inode — `libc.so.6`, or a directory every job of a parallel build stats. CPUs doing `iget`/`iput` keep taking the line exclusive; every CPU trying to `open()` keeps re-fetching it just to read a pointer that has not changed since the inode was created.

### Reproduce it yourself

```bash
pahole -C inode /sys/kernel/btf/vmlinux | \
  awk '/cacheline 5 boundary/,/cacheline 8 boundary/'

cd /mnt/data/linux-src/linux-7.2
grep -n 'i_fop' fs/open.c                             # the reader
grep -n 'atomic_add_unless(&inode->i_count' fs/inode.c # the writers
```

---

## 3. Part 1 — the patch (move the read-mostly fields out)

`struct inode` already has a read-mostly pointer block at the top: `i_op`, `i_sb`, `i_mapping`. That is where `i_fop` and `i_flctx` belong. Once they leave, the atomics have the line to themselves — and atomics sharing a line with other atomics is fine, because they are all writers.

```diff
--- a/include/linux/fs.h
+++ b/include/linux/fs.h
@@ -773,6 +773,20 @@ struct inode {
 	const struct inode_operations	*i_op;
 	struct super_block	*i_sb;
 	struct address_space	*i_mapping;
 
 #ifdef CONFIG_SECURITY
 	void			*i_security;
 #endif
 
+	/*
+	 * Read-mostly: i_fop is set once at inode setup and read on every
+	 * open(); i_flctx is read on file-lock checks. They used to share
+	 * a cacheline with i_count / i_writecount / i_dio_count, which are
+	 * written constantly, so refcount traffic on one CPU invalidated
+	 * the i_fop read on every other CPU. Keep them with the other
+	 * read-mostly pointers instead.
+	 */
+	union {
+		const struct file_operations	*i_fop;	/* former ->i_op->default_file_ops */
+		void (*free_inode)(struct inode *);
+	};
+	struct file_lock_context	*i_flctx;
+
 	/* Stat data, not accessed from path walking */
 	u64			i_ino;
@@ -848,10 +862,6 @@ struct inode {
 #if defined(CONFIG_IMA) || defined(CONFIG_FILE_LOCKING)
 	atomic_t		i_readcount; /* struct files open RO */
 #endif
-	union {
-		const struct file_operations	*i_fop;	/* former ->i_op->default_file_ops */
-		void (*free_inode)(struct inode *);
-	};
-	struct file_lock_context	*i_flctx;
 	struct address_space	i_data;
```

### What each change does

1. The `i_fop`/`free_inode` union and `i_flctx` are deleted from after the atomics and re-declared, byte-for-byte identical, in the read-mostly block near the top.
2. **The union moves as a whole — this is required.** Why is `i_fop` in a union with a destructor callback at all? Because they are live at different times: `i_fop` matters while the inode is in use; when the inode is being destroyed nobody will open it again, so `fs/inode.c:351` reuses the same 8 bytes to stash `free_inode`, which `:316-317` calls later from the RCU callback. Move both together and this trick keeps working untouched. Split them and you waste 8 bytes for nothing.
3. Everything between the two positions shifts up by 16 bytes. Total size is unchanged — this is a reorder, not a shrink.
4. **No call site changes.** Every access in the tree is `inode->i_fop` / `inode->free_inode` / `locks_inode_context()` (`include/linux/filelock.h:250-259`, a `READ_ONCE(inode->i_flctx)`) — all by field name.

### The result

```
Before   line 5: [ i_version i_sequence i_count i_dio_count i_writecount i_readcount | i_fop i_flctx ]
                   ------------------ written constantly ------------------   -- read constantly --

After    line 0: [ i_mode i_uid i_gid ... i_op i_sb i_mapping i_fop i_flctx ]   read-mostly
         ...
         line 5: [ i_version i_sequence i_count i_dio_count i_writecount i_readcount ]   write-hot, writers only
```

An `open()` now reads `i_op`, `i_mapping`, and `i_fop` from lines nobody is dirtying.

---

## 4. Part 2 — lock the layout in so it cannot silently rot

The reorder is the easy part. The hard part is the year 2031, when someone inserts a field in the middle and quietly undoes the fix — and no test fails, because false sharing is invisible to correctness tests.

The kernel already solved this for networking: `struct sock`, `struct tcp_sock`, and `struct net_device` declare named cache-line groups and **assert the layout at compile time** (`include/net/sock.h:406-529`; `net/core/dev.c:13138-13165`). Break the layout, break the build. Apply the same pattern:

In `include/linux/fs.h`:

```diff
 struct inode {
+	__cacheline_group_begin(inode_read_hot);
 	umode_t			i_mode;
 	...
 	struct file_lock_context	*i_flctx;
+	__cacheline_group_end(inode_read_hot);
 
 	/* Stat data, not accessed from path walking */
```

In `fs/inode.c` (`inode_init()` is at `fs/inode.c:2657`):

```diff
 void __init inode_init(void)
 {
+#ifndef CONFIG_RANDSTRUCT
+	/*
+	 * Keep the open()/path-walk read-mostly fields inside two
+	 * cachelines, and keep the write-hot refcounts off them.
+	 * If a new field pushes the group past 128 bytes, this fails
+	 * the build instead of silently reintroducing false sharing.
+	 */
+	CACHELINE_ASSERT_GROUP_MEMBER(struct inode, inode_read_hot, i_op);
+	CACHELINE_ASSERT_GROUP_MEMBER(struct inode, inode_read_hot, i_mapping);
+	CACHELINE_ASSERT_GROUP_MEMBER(struct inode, inode_read_hot, i_fop);
+	CACHELINE_ASSERT_GROUP_SIZE(struct inode, inode_read_hot, 128);
+#endif
 	/* inode slab cache */
 	inode_cachep = kmem_cache_create("inode_cache", ...);
```

These macros live in `include/linux/cache.h:150-164` and compile to `BUILD_BUG_ON` — zero runtime cost.

### Why the `#ifndef CONFIG_RANDSTRUCT` guard is mandatory here

`struct inode` ends with `__randomize_layout` (`include/linux/fs.h:871`): on hardened kernels the compiler deliberately shuffles its fields, so the offset asserts would fire and **break the build**. `struct sock` and `net_device` are not randomized, which is why they assert unconditionally. `inode` is, so the guard is required — without it this patch gets reverted the first time a hardened config builds.

Corollary: under `CONFIG_RANDSTRUCT_FULL` the whole optimisation is a no-op. Check what you run: `grep CONFIG_RANDSTRUCT /boot/config-$(uname -r)` (this machine: `CONFIG_RANDSTRUCT_NONE=y`, so it takes effect).

---

## 5. Who benefits (use cases)

The conflict needs two ingredients: many CPUs, and hot inodes shared between them.

- **High: parallel builds.** Every `cc` process opens the same headers and shared libraries; `make -j64` is the textbook case.
- **High: container fleets.** Hundreds of containers on shared base-image layers open the same files through overlayfs.
- **High: web/app servers** serving a small hot file set, and anything doing `open`/`stat` storms over shared paths.
- **Also helped:** direct I/O to a shared file (`i_dio_count`) and futexes in shared mappings (`i_sequence`) dirty this same line today.
- **Near zero:** single-threaded workloads, or workloads where each thread touches its own private files.

---

## 6. ABI and compatibility

| Consumer | Affected? | Why |
|---|---|---|
| Userspace ABI | **No** | `struct inode` never crosses to userspace. `stat()` fills `struct stat` field by field. |
| In-tree filesystems (ext4, xfs, btrfs...) | **No** | They embed `struct inode` inside their own inode and use `container_of()` — an `offsetof`-based, recomputed-at-build-time operation. Internal reordering is invisible to them. |
| Assembly | **No** | No inode offsets are exported to asm. |
| BPF CO-RE | **No** | Offsets relocated at load time from BTF. |
| Out-of-tree filesystems (ZFS, proprietary) | Rebuild needed | Standard for any VFS header change; expected by those projects on every kernel bump. |
| Distro kABI | Breaks if backported | `struct inode` is on every distro's kABI watchlist. The distro's problem, not upstream's. |
| Hardened kernels (`RANDSTRUCT_FULL`) | No-op, still builds | Thanks to the `#ifndef` guard in Part 2. |

---

## 7. How to verify

```bash
# 1. Layout: i_fop below offset 128; i_count's line holding atomics only.
pahole -C inode vmlinux | grep -E 'i_op|i_mapping|i_fop|i_flctx|i_count|i_version'

# 2. Size unchanged (pure reorder):
pahole -C inode vmlinux | tail -5

# 3. Correctness: filesystems exercise every moved field.
#    Run xfstests (quick group) on ext4 and xfs, plus file-locking tests
#    (the '-g locks' group covers i_flctx).

# 4. The actual proof — false sharing needs contention, so measure under it:
perf c2c record -ag -- make -j$(nproc) -C /path/to/large/project
perf c2c report --call-graph none -k vmlinux
#    Before: HITM entries for struct inode at offsets 320-383,
#            readers in do_dentry_open, writers in iput/ihold.
#    After:  that cacheline's HITM entries drop or disappear.

# 5. A synthetic contender if you lack a big build:
for i in $(seq 200); do
  (for j in $(seq 5000); do cat /usr/lib/x86_64-linux-gnu/libc.so.6 > /dev/null; done) &
done; wait
```

A single-CPU microbenchmark will show **nothing** — no contention, no false sharing. If you cannot see the HITM entries before the patch, you also cannot prove the patch helped; find a workload where you can, or do not send it.

---

## 8. Getting it merged

Maintainers (from the tree): `scripts/get_maintainer.pl -f include/linux/fs.h` — Alexander Viro, Christian Brauner, Jan Kara, cc `linux-fsdevel@vger.kernel.org`.

Send as a two-patch series:

- **Patch 1/2: the reorder** (fs.h only). Commit message carries the evidence: the pahole line-5 dump, the reader (`fs/open.c:918`) and writers (`fs/inode.c:1594,1646,2047`), the `perf c2c` HITM before/after, workload, core count, config. State explicitly: no size change, no call-site change, union moved intact, `__randomize_layout` unaffected.
- **Patch 2/2: the asserts** (fs.h markers + fs/inode.c). Separate, so it can be debated or dropped without losing the fix. Cite the `struct sock` precedent — VFS reviewers respect "networking already does exactly this".

Reviewer objections to pre-empt in the cover letter:

1. *"Does this slow down anything?"* — The atomics keep their own line; writers were already serialized by the coherence protocol. The moved fields join fields read in the same operations (`i_op` and `i_fop` are both read at open).
2. *"Why is `i_lock` not moved?"* — See section 9. Say it before they ask.
3. *"xfstests?"* — Have the results in the cover letter, not in a follow-up.

Plus the usual: `./scripts/checkpatch.pl --strict` clean, one logical change per patch, imperative-mood subject (`vfs: keep i_fop off the inode refcount cacheline`).

---

## 9. Gotchas — the mistakes that look like improvements

**Do not move `i_lock`.** It sits directly before `i_bytes`, `i_blkbits`, `i_blocks` — the exact fields its own comment says it protects (`/* i_blocks, i_bytes, maybe i_size */`). A lock sharing a line with its data is **deliberate and good**: the CPU that takes the lock touches the data next, one line instead of two. "Separate hot from cold" applied mechanically here would make the kernel slower. This is the classic junior mistake in layout work.

**Do not split the write-hot atomics from each other.** They are all writers; spreading them over more lines buys nothing and costs footprint.

**Do not trust this document's offsets.** They came from this machine's config (`CONFIG_SECURITY=y`, `CONFIG_FS_POSIX_ACL=y`, etc.). Different config, different offsets, same field order. Re-run `pahole` on your build before and after — the *order* argument holds everywhere, the numbers are local.

---

## 10. Realistic expectation

This is the strongest of the three tasks: not generic tidying but a specific, currently-live false-sharing conflict with an identified reader, identified writers, and a direct measurement method. It is also the same fix, with build-time enforcement, that `sock`, `tcp_sock`, `net_device`, and `dentry` already received — `inode` is simply the last big hot struct still waiting for it. The payoff scales with cores and inode sharing: real on a 64-core build server, invisible on a laptop.
