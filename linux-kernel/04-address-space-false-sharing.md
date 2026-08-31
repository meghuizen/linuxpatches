# Task 4 — Fix false sharing in `struct address_space`: page-cache counters vs `a_ops`

**What the patch does, in one sentence:** it regroups `struct address_space` so the fields *written* on every page-cache add/remove (`i_pages`, `nrpages`, `writeback_index`) sit together on one cache line, and the fields *read* on every fault/read/writeback (`host`, `a_ops`, `gfp_mask`, `flags`) sit together on another — today they are interleaved, so cache mutations on one CPU invalidate the read path on every other CPU using the same file.

| | |
|---|---|
| Target file | `include/linux/fs.h` |
| Kernel | Linux 7.2, vanilla, `/mnt/data/linux-src/linux-7.2` |
| Patch size | Reorder 13 fields, no size change (168 bytes before and after) |
| Risk | Low |
| Realistic gain | Two effects: (1) removes read-vs-write false sharing under concurrent access to one file; (2) halves dirty lines per page-cache add/remove (write-combining). Scales with core count and single-file concurrency |
| Relation to Task 3 | Same disease, same recipe, one struct over — but weaker (see section 9) |

---

## 1. Background: two rules, not one

Task 3 used one rule: *never put a frequently-written field on the same cache line as a frequently-read one* (false sharing). This task adds the mirror rule:

> Fields that are **written together in the same operation** should share a line —
> then the operation dirties one line instead of two.

Both rules come from the same fact: cache coherence works on 64-byte lines. Separating a writer from a reader avoids ping-pong; co-locating two writers that always fire together halves the write traffic. This patch applies both.

`struct address_space` is the kernel's per-file page-cache object (every `inode` embeds one as `i_data`; `folio->mapping` points at it). Every page-cache lookup, insertion, removal, fault, and writeback goes through it.

---

## 2. The problem, with evidence

The 7.2 definition (`include/linux/fs.h`, `struct address_space`) in current order:

```c
struct address_space {
	struct inode		*host;             READ everywhere (folio->mapping->host)
	struct xarray		i_pages;           lock WRITTEN per add/remove, head READ per lookup
	struct rw_semaphore	invalidate_lock;   taken rarely (truncate vs fault races)
	gfp_t			gfp_mask;          READ per page-cache allocation
	atomic_t		i_mmap_writable;   written at mmap/munmap
	struct rb_root_cached	i_mmap;            rmap tree, mmap/munmap frequency
	unsigned long		nrpages;           WRITTEN per add/remove
	pgoff_t			writeback_index;   WRITTEN per writeback batch
	const struct address_space_operations *a_ops;   READ per fault/read/writeback
	unsigned long		flags;             READ per op (AS_* checks)
	errseq_t		wb_err;            written on wb errors (rare), read at fsync
	spinlock_t		i_private_lock;    written by fs (buffer heads)
	struct rw_semaphore	i_mmap_rwsem;      rmap lock
} __attribute__((aligned(sizeof(long)))) __randomize_layout;
```

The writers and readers, with the actual code:

**Writers (every page-cache mutation):**
- `mapping->nrpages += nr` in `__filemap_add_folio` — `mm/filemap.c:919`
- `mapping->nrpages -= nr` in delete paths — `mm/filemap.c:147`, `:317`
- All three run **under `xa_lock`**, i.e. they write `i_pages` and `nrpages` in the same operation
- `mapping->writeback_index = ...` per writeback batch — `mm/page-writeback.c:2542,2554`

**Readers (every fault / buffered read / writeback):**
- `mapping->a_ops->read_folio` — `mm/filemap.c:2603,2654,3680`; `mapping->a_ops->writepages` — `mm/page-writeback.c:2570`; capability check — `mm/readahead.c:364`
- `gfp_mask` via `mapping_gfp_mask()` on every page-cache folio allocation
- `flags` via `mapping_large_folio_support()`, `mapping_use_writeback_tags()` etc. on the same paths
- `host` all over the hot paths — `mm/filemap.c:213,255`

**The two layout defects:**

1. **Read/write interleaving.** `nrpages` (write-hot) sits 16 bytes from `a_ops` (read-hot), with `writeback_index` (write-hot) in between. In the embedded reality (see section 5) these land on one line: CPU A appending pages to a file keeps stealing the line CPU B needs just to find `->read_folio`.
2. **Split writers.** `i_pages` and `nrpages` — always written together, under the same lock — are 65+ bytes apart, so every add/remove dirties **two** lines where one would do.

### Reproduce it yourself

```bash
cd /mnt/data/linux-src/linux-7.2
grep -n 'nrpages += \|nrpages -= ' mm/filemap.c            # writers
grep -n 'a_ops->read_folio' mm/filemap.c | head -3          # readers

# The layout THAT MATTERS is the embedded one (see section 5):
pahole -C inode /sys/kernel/btf/vmlinux | grep -A20 'struct address_space i_data'
```

---

## 3. The patch

```diff
--- a/include/linux/fs.h
+++ b/include/linux/fs.h
@@ struct address_space {
-	struct inode		*host;
-	struct xarray		i_pages;
-	struct rw_semaphore	invalidate_lock;
-	gfp_t			gfp_mask;
-	atomic_t		i_mmap_writable;
-	struct rb_root_cached	i_mmap;
-	unsigned long		nrpages;
-	pgoff_t			writeback_index;
-	const struct address_space_operations *a_ops;
-	unsigned long		flags;
-	errseq_t		wb_err;
-	spinlock_t		i_private_lock;
-	struct rw_semaphore	i_mmap_rwsem;
+	/*
+	 * Read-mostly: set at init, read on every fault, buffered read
+	 * and writeback. Kept together and away from the write-hot
+	 * fields below, which used to share their cacheline and made
+	 * every page-cache add/remove invalidate these reads on all
+	 * other CPUs touching the same file.
+	 */
+	struct inode		*host;
+	const struct address_space_operations *a_ops;
+	gfp_t			gfp_mask;
+	errseq_t		wb_err;
+	unsigned long		flags;
+
+	/* Rarely contended; 40 bytes of separation between the groups. */
+	struct rw_semaphore	invalidate_lock;
+
+	/*
+	 * Write-hot: i_pages (xa_lock) and nrpages are modified together,
+	 * under the same lock, on every page-cache add/remove
+	 * (see __filemap_add_folio() and page_cache_delete()).
+	 * Adjacent so one operation dirties one cacheline, not two.
+	 */
+	struct xarray		i_pages;
+	unsigned long		nrpages;
+	pgoff_t			writeback_index;
+	spinlock_t		i_private_lock;
+
+	/* rmap: mmap/munmap frequency; the lock stays with its tree. */
+	atomic_t		i_mmap_writable;
+	struct rb_root_cached	i_mmap;
+	struct rw_semaphore	i_mmap_rwsem;
 } __attribute__((aligned(sizeof(long)))) __randomize_layout;
```

### What each change does

1. **Read group first** — `host` (8) + `a_ops` (8) + `gfp_mask` (4) + `wb_err` (4) + `flags` (8) = exactly 32 bytes. `wb_err` joins them because its hot side is the *read* at every fsync; error writes are rare.
2. **`invalidate_lock` becomes the spacer.** 40 bytes of rw_semaphore between the groups. It is not read-mostly (even `down_read()` writes the lock word), which is exactly why it must not sit *inside* the read group — but it is taken only on truncate/hole-punch coordination, so it is quiet enough to be the wall between the groups. Its placement guarantees `a_ops` and `nrpages` are 73+ bytes apart: **never on the same 64-byte line, regardless of alignment.**
3. **Write group together** — `i_pages` (16) + `nrpages` (8) + `writeback_index` (8) + `i_private_lock` (4) = 36 bytes. This is the write-combining half of the patch: `__filemap_add_folio` takes `xa_lock`, inserts, bumps `nrpages` — after the patch that is one dirty line. `i_private_lock` (buffer-head churn in ext4 & friends) joins the writers rather than polluting a read line.
4. **rmap block last, lock with its data** — `i_mmap_writable`, `i_mmap`, and `i_mmap_rwsem` stay adjacent deliberately: a CPU taking the rmap lock touches the rmap tree next (the same "lock belongs with what it guards" lesson as `i_lock` in Task 3 — this time applied, not just avoided).
5. **Size unchanged: 168 bytes before and after.** No field changed type or meaning; no call site changes anywhere — all access is by field name.

---

## 4. Who benefits (use cases)

The conflict needs concurrent CPUs on **one file's** page cache:

- **High: databases** — many threads reading/writing one large table file; page-cache insertions by the readahead of one query vs `a_ops` lookups of another.
- **High: shared log/journal files** — many writers appending (add pages) while a shipper reads.
- **High: one big mmap'd file** shared by a process's threads (caches, embedded KV stores).
- **Medium: parallel builds** re-reading hot files while writeback runs.
- **Zero: many-small-files workloads** — the struct is per-file; if each thread has its own files, there is nothing to fight over.

The write-combining half (one dirty line per add/remove) helps even a **single-threaded** streaming read/write — smaller, but unconditional.

---

## 5. The subtlety a reviewer will raise first: alignment

This struct is different from Task 3's inode in one important way, and pretending otherwise would sink the patch:

`struct address_space` is only `__attribute__((aligned(sizeof(long))))` — 8 bytes, not 64. And its dominant instance is **embedded** inside `struct inode` as `i_data`, at whatever offset the inode layout dictates (it is not 64-byte aligned there). So "cache line 1 of address_space" is not a fixed thing — the line boundaries fall wherever `i_data`'s base puts them.

Two consequences, both handled:

1. **The patch relies on distance, not on line numbers.** `a_ops` (ends at offset 16) and `nrpages` (starts at 96) are 80 bytes apart — more than a full line — so they can never share a line *at any base alignment*. That guarantee is alignment-independent.
2. **Verification must run on `struct inode`, not on `struct address_space`.** `pahole -C address_space` shows the standalone layout, which is not what the kernel mostly runs. Always check `pahole -C inode` and read the `i_data` region offsets. The intra-group adjacency (write group within one line) depends on where `i_data` starts; if your config lands a group straddling a boundary, shuffle the 4-byte members (`gfp_mask`/`wb_err`) and re-check — the guaranteed part (groups far apart) holds regardless.

Putting this analysis in the commit message is not optional decoration — it is the difference between "moved fields around" and a patch the pagecache maintainer can trust.

---

## 6. ABI and compatibility

| Consumer | Affected? | Why |
|---|---|---|
| Userspace ABI | **No** | Never exposed; `mmap`/`read` semantics unchanged |
| Filesystems (ext4, xfs, btrfs...) | **No** | Access by field name; embedded use via `inode->i_data` and `folio->mapping` pointers, both position-independent |
| `folio->mapping` bit tricks | **No** | `FOLIO_MAPPING_ANON` uses the low bits of the *pointer to* the struct; the `aligned(sizeof(long))` attribute that guarantees those bits is preserved untouched |
| Assembly / asm-offsets | **No** | No address_space offsets exported |
| BPF CO-RE | **No** | Load-time relocation from BTF |
| Out-of-tree fs (ZFS) | Rebuild | Standard for any fs.h change |
| Distro kABI | Breaks if backported | Distro's concern, not upstream's |
| `CONFIG_RANDSTRUCT_FULL` | Patch is a no-op | Struct is `__randomize_layout` (`include/linux/fs.h`, struct terminator); compiler shuffles regardless. Same situation as Task 3 — and the same reason any future `CACHELINE_ASSERT` additions must be guarded with `#ifndef CONFIG_RANDSTRUCT` |

---

## 7. How to verify

```bash
# 1. Layout — on the EMBEDDED instance (section 5):
pahole -C inode vmlinux | sed -n '/i_data/,/i_mmap_rwsem/p'
#    Check: a_ops-to-nrpages distance > 64; i_pages..i_private_lock within ~40 bytes.

# 2. Size unchanged (168 bytes), inode size unchanged:
pahole -C address_space vmlinux | tail -3
pahole -C inode vmlinux | tail -3

# 3. Correctness: the page cache is exercised by everything, but run
#    xfstests (-g quick) on ext4 and xfs anyway; add -g punch for
#    invalidate_lock paths.

# 4. The proof — needs multi-CPU contention on ONE file:
fio --name=fs --filename=/tank/one-big-file --rw=randread --bs=4k \
    --numjobs=32 --time_based --runtime=60 --group_reporting &
fio --name=fw --filename=/tank/one-big-file --rw=write --bs=1M ...   # concurrent appender
perf c2c record -ag -- sleep 30
perf c2c report --call-graph none -k vmlinux
#    Before: HITM entries inside struct inode at the i_data region,
#            readers in filemap_read/filemap_fault, writers in
#            __filemap_add_folio / page_cache_delete.
#    After:  those entries drop; xa_lock contention (real, not false)
#            remains - that one is honest contention, not layout.

# 5. Write-combining effect (single-threaded, unconditional):
perf stat -e L1-dcache-store-misses -- dd if=/dev/zero of=/tank/f bs=1M count=4096
```

---

## 8. Getting it merged

This one has **two** maintainer audiences — the struct lives in VFS territory, the hot paths in mm:

```bash
perl scripts/get_maintainer.pl -f include/linux/fs.h    # Viro, Brauner, Jan Kara
perl scripts/get_maintainer.pl -f mm/filemap.c          # Andrew Morton, linux-mm
```

Send to both lists (`linux-fsdevel`, `linux-mm`); Matthew Wilcox (pagecache/xarray maintainer) will review the `i_pages` reasoning — the write-combining argument (`nrpages` under `xa_lock`) is aimed at exactly that review.

What the commit message must contain:

1. The reader/writer table from section 2 with file:line for each claim.
2. The `pahole -C inode` before/after of the `i_data` region — not standalone address_space (section 5, and say why).
3. `perf c2c` HITM before/after on a single-file contention workload, hardware and config stated.
4. The alignment analysis: distance-based guarantee, embedded-instance verification.
5. xfstests results in the cover letter.
6. `./scripts/checkpatch.pl --strict` clean; subject like `fs: separate read-mostly and write-hot fields in struct address_space`.

---

## 9. Gotchas — including why this is weaker than Task 3

**The same-CPU caveat, stated up front.** A page fault on one CPU does lookup (`i_pages` read), allocation (`gfp_mask` read), insertion (`i_pages`/`nrpages` write) — reader and writer are often the *same CPU in the same operation*, where false sharing costs nothing. The patch pays off only under **cross-CPU** concurrency on one file. Task 3's inode case is stronger because `iget`/`iput` traffic and `open()` calls are naturally spread across CPUs even for boring workloads. Do the `perf c2c` measurement *before* investing in the submission; if your fleet's workloads never contend on single files, this patch is not worth your review-cycle budget.

**Do not try to split the xarray.** `i_pages.xa_lock` (written) and `i_pages.xa_head` (read per lookup) live inside one 16-byte `struct xarray` — that mixing is internal to the xarray and not fixable from here. The patch accepts it and optimizes around it.

**Do not "promote" `invalidate_lock` into the read group** on the grounds that it is "mostly read-locked" — a rw_semaphore's `down_read()` *writes* the lock word. Locks are never read-mostly. It is placed as a quiet spacer, which is the correct use.

**Do not trust standalone-pahole line boundaries** — section 5. Embedded instance or nothing.

---

## 10. Realistic expectation

Two independent effects: the false-sharing fix is conditional (needs multi-CPU, single-file pressure — real for databases and shared-log patterns, absent for many-small-file fleets), while the write-combining of `i_pages`+`nrpages` is small but unconditional. No size change, no call-site churn, same recipe as the already-treated `sock`/`net_device`/`dentry` structs. Rank it behind Task 3 in submission order: land the inode patch first, then present this as "the same treatment for the next struct down the fault path."

---

## 11. Effectiveness test — did the patch actually work?

Two independent claims, two independent tests. Run both; they can pass or fail separately.

**Claim 1 — false-sharing removal (conditional on cross-CPU single-file pressure):**

```bash
# 32 readers + 1 writer on ONE file, both kernels:
fio --name=r --filename=/tank/bigfile --rw=randread --bs=4k --numjobs=32 \
    --time_based --runtime=60 --group_reporting &
fio --name=w --filename=/tank/bigfile --rw=write --bs=1M --time_based --runtime=60 &
perf c2c record -ag -- sleep 30; wait
```

| Gate | Threshold |
|---|---|
| HITM inside `struct inode`'s `i_data` region (baseline: readers in `filemap_read`/`filemap_fault`, writers in `__filemap_add_folio`) | Present before, gone after |
| Reader IOPS during concurrent write | Up, outside run spread |
| Remaining `xa_lock` HITM | Still present — that one is *real* contention; if it also vanished, distrust your measurement |

**Claim 2 — write-combining (unconditional, small):**

```bash
perf stat -e L1-dcache-store-misses,cycles \
  -- dd if=/dev/zero of=/tank/f bs=1M count=8192 conv=fsync   # 5 runs, medians
```

| Gate | Threshold |
|---|---|
| Store misses per GB written | Measurable drop (the `i_pages`+`nrpages` line merge) |
| Throughput | Neutral or better |

**The honest failure mode:** claim 1's baseline shows no HITM — your fleet doesn't contend on single files, and section 9's warning applies: the patch is correct but not worth *your* submission budget. Claim 2 failing (no store-miss delta) usually means the embedded alignment put the write group across a boundary — re-check `pahole -C inode` per section 5 before concluding.
