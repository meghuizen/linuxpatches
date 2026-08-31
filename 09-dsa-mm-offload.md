# Task 9 — Offload bulk page copying to DSA (Intel Data Streaming Accelerator)

**What this task delivers, in one sentence:** teach the memory-management subsystem to hand its bulk page-copy work — migration for CXL/NUMA tiering, compaction, khugepaged collapse — to the DSA DMA engine that ships idle in every recent Xeon, instead of burning CPU cores on `memcpy`.

| | |
|---|---|
| Target | `mm/migrate.c` / `mm/util.c` (`folio_copy`), `mm/khugepaged.c`, using `drivers/dma/idxd` through the dmaengine API |
| Kernel | Linux 7.2, vanilla, `/mnt/data/linux-src/linux-7.2` |
| Nature | Integration project — both halves exist, the bridge between them does not |
| Hardware | Intel DSA: on-die in Xeon since Sapphire Rapids (2023). No hardware = clean CPU fallback |
| Realistic effort | Weeks; needs a DSA-capable Xeon to measure on |
| Risk | Low-medium — background paths only; the design forbids touching latency-critical paths |
| Impact | Frees CPU cores during memory-tiering churn; scales with how much your fleet migrates pages |

---

## 1. Background: what DSA is and why mm should care

Modern Xeons carry a **Data Streaming Accelerator** — a small on-die DMA engine that can copy, zero, and compare memory ranges by itself. You enqueue a descriptor ("copy 2 MB from A to B"), it does the work, you get a completion. The CPU is free the entire time.

Meanwhile, mm performs enormous amounts of plain copying with CPU loops:

- **Page migration** — every folio moved between NUMA nodes or memory tiers is copied by the CPU (`folio_copy`, `mm/util.c:750`). On a box doing CXL tiering, this is a continuous background tax: hot pages promoted, cold pages demoted, terabytes over a day.
- **Compaction** — defragmenting memory to make huge pages copies folios the same way (`mm/compaction.c:2668`).
- **khugepaged** — collapsing 512 base pages into one 2 MB huge page copies all 512 (`__collapse_huge_page_copy`, `mm/khugepaged.c:933`).

A CPU core sustains roughly 10-20 GB/s of memcpy while being 100% occupied. DSA does comparable rates per engine while the core does real work. The copies above are **batched and background** — nobody is synchronously waiting on any single page — which is exactly the shape DMA offload wants.

## 2. Verified state in this tree: both halves exist, no bridge

| Piece | State | Evidence |
|---|---|---|
| DSA driver exposing a generic copy channel | **Done** — idxd registers a dmaengine device with `DMA_MEMCPY` capability | `drivers/dma/idxd/dma.c:235,246` |
| The single CPU copy loop behind migration | **Done and centralized** — one function to intercept | `folio_copy`, `mm/util.c:750`, exported |
| Batched, async-friendly callers | **Done** — `migrate_pages()` takes whole lists | `mm/compaction.c:2668`, `mm/mempolicy.c:1319`, demotion in `mm/vmscan.c` |
| In-kernel precedent for "try DMA, fall back to CPU" | **Done, 15+ years old** — the RAID layer's async_tx API | `async_memcpy`, `crypto/async_tx/async_memcpy.c:32` |
| mm actually using any of it | **Absent** | `grep -rl dmaengine mm/` → empty |

That last row is the entire task. Multiple RFC series have attempted this over the years (search lore.kernel.org for "migrate" + "DMA" / "DSA") without merging — section 6 covers why, because the objections define the design.

## 3. Where offload pays — and where it must never go

The economics: submitting a descriptor and taking a completion costs microseconds. A 4 KB copy takes the CPU ~1 microsecond. So:

| Path | Offload? | Why |
|---|---|---|
| `migrate_pages()` with a list of folios (tiering, compaction, `move_pages`) | **Yes — primary target** | Large batches, large folios (up to 2 MB each), caller already tolerates latency, list shape allows submit-all-then-wait pipelining |
| khugepaged collapse copy | **Yes — secondary** | 2 MB per collapse, background kthread |
| Page fault zeroing / COW copy | **Never** | Latency-critical, single page, submission overhead exceeds the copy; the CPU string-op path (`clear_pages`) is already optimal |
| Small folios inside a migration batch | **CPU fallback** | Below a threshold (measure; likely 16-64 KB) the CPU wins — the helper must decide per-folio |

## 4. The work, in review-sized pieces

**Item A — a batch copy helper with guaranteed fallback.**
A small mm-internal API: take a list of (src, dst) folio pairs, submit what qualifies to a dmaengine `DMA_MEMCPY` channel, CPU-copy the rest and anything that fails, wait for completions before returning. Kernel pages — no pinning games. Must behave identically to `folio_copy` semantically, including the "no DSA present" case compiling down to today's behavior. The async_tx fallback pattern is the model.

**Item B — hook the migration copy stage.**
`migrate_pages()` internally separates "unmap" from "move"; the move stage per folio calls the copy. Restructure so the copy stage of a batch flows through item A — submit the whole batch, overlap DMA with the metadata work of other folios, then complete. This is the patch that produces the headline number.

**Item C — khugepaged.**
Same helper, one call site, 2 MB at a time.

**Item D — the numbers that decide merge or reject.**
(1) migration throughput (pages/s) and **CPU cycles per migrated GB** with DSA on/off, on a CXL or 2-socket tiering workload; (2) proof of no regression when DSA is absent, busy, or the batch is small; (3) the threshold measurement justifying the size cutoff.

## 5. How to test

```bash
# DSA present and configured? (needs accel-config, a work queue enabled)
ls /sys/bus/dsa/devices/
accel-config list

# Drive migration hard, measure both sides:
numactl --membind=0 <alloc-heavy workload> &
migratepages <pid> 0 1                      # forced migration, timeable
# or tiering churn: enable numa_balancing + a CXL node, watch:
grep -E 'pgmigrate|pgdemote|pgpromote' /proc/vmstat
perf stat -e cycles,instructions -- <the migration window>

# Correctness: data integrity across migration under memory pressure,
# plus the mm selftests (tools/testing/selftests/mm/migration.c).
```

## 6. Why earlier attempts died — the objections to pre-answer

1. **"Submission overhead eats the win on normal folios."** True for 4 KB pages — hence the per-folio threshold and the batch-pipelining design. Lead with large-folio/2 MB numbers, where it is not close.
2. **"Completion latency stalls migration."** Overlap: submit folio N's copy while doing folio N+1's rmap/metadata work; the batch structure of `migrate_pages()` makes this natural.
3. **"What about cache state?"** DMA writes land in memory, not the destination CPU's cache — a subsequently-accessed migrated page eats cold misses the CPU-copy version would not. DSA descriptors have cache-control hints; measure both settings and report. This is the subtlest technical point — do not hand-wave it.
4. **"Vendor-specific."** The integration is via generic dmaengine `DMA_MEMCPY`, not idxd directly — any capable engine (AMD PTDMA, ARM SMMU-adjacent engines) qualifies. Say so in the cover letter.
5. **"mm doesn't want to depend on drivers."** Optional, runtime-detected, fallback-first — the async_tx precedent shows the kernel already accepts exactly this shape.

## 7. Getting it merged

Two subsystems: mm (`scripts/get_maintainer.pl -f mm/migrate.c` — Andrew Morton, linux-mm) and dmaengine (Vinod Koul, dmaengine list); cc the idxd maintainer (Intel, `drivers/dma/idxd`). Study the prior rejected RFCs on lore first — citing them and answering their review objections directly (section 6) is what separates attempt N+1 from attempt N. Series shape: helper + fallback first (no behavior change), migration hook second, khugepaged third, numbers in every commit message.

## 8. Realistic expectation

This is not a latency win and never will be — it is a **CPU-liberation** win for machines whose background memory churn is real: CXL tiering, heavy compaction, NUMA rebalancing at scale. On such fleets, entire cores currently spent on memcpy come back for work; on a laptop it does nothing whatsoever. It is also the rare item in this whole audit where the hardware is already everywhere (every deployed Sapphire Rapids+ Xeon), the driver is done, the precedent API exists, and the gap is one honest integration layer that multiple people tried and nobody finished — which makes the prior-art homework the most important line item of the entire project.

---

## 9. Effectiveness test — did the offload actually pay?

The claim is CPU liberation at equal-or-better migration throughput. Both halves must hold.

```bash
# Controlled migration window, both kernels (or DSA on/off via accel-config), 5 runs:
<start memory-heavy victim pinned to node 0>
perf stat -e cycles,instructions -- migratepages <pid> 0 1
grep pgmigrate_success /proc/vmstat        # before/after delta = pages moved
```

| Gate | Threshold | Meaning |
|---|---|---|
| **Cycles per migrated GB** (the headline) | Large drop with DSA for 2 MB folios — the copy was most of the cycles | CPU was liberated |
| Migration throughput (pages/s) | Equal or better | Offload didn't slow the operation it serves |
| Small-folio regime (force 4 KB-only workload) | Identical to baseline | The threshold logic works; no submission-overhead tax |
| DSA-absent / DSA-busy fallback | Bit-identical performance to unpatched kernel | The fallback is genuinely free |
| **Post-migration access latency**: pointer-chase over the migrated region immediately after | Within noise of CPU-copy baseline — else re-test with descriptor cache hints and report both | The cache-cold-destination concern (section 6.3) is answered with data, not assertion |
| Data integrity: mm migration selftests + checksum of victim memory across forced migration under pressure | Zero mismatches | Table stakes |

**System-level proof for the cover letter:** a CXL-tiering or `numa_balancing` soak where `%sys` attributable to migration drops while promotion/demotion rates (`pgpromote_*`, `pgdemote_*` in `/proc/vmstat`) hold — cores returned to userspace at unchanged tiering behavior.

**The honest failure mode:** cycles/GB improves but pages/s falls — completion latency is gating the pipeline, meaning the overlap design (submit N while processing N+1) isn't working; that's a bug in the series, not a reporting nuance. The reverse — throughput up, cycles flat — means you measured the batching restructure, not the offload; isolate by running the restructured code with DSA disabled.
