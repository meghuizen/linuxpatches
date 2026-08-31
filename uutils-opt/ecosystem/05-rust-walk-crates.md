# Ecosystem 1 — Metadata batching in the Rust directory-walking crates

**Target repositories (where these changes must land):**

| Crate | Repository | Role | Downstream beneficiaries |
|---|---|---|---|
| `walkdir` | github.com/BurntSushi/walkdir | The standard recursive walker | half the Rust CLI ecosystem |
| `ignore` | github.com/BurntSushi/ripgrep (crates/ignore) | Gitignore-aware **parallel** walker | `ripgrep`, `fd`, `tokei`, cargo tooling |
| `jwalk` | github.com/Byron/jwalk | Rayon-based parallel walker with per-directory batching hooks | `dua`, others |

**What this change does, in one sentence:** add an opt-in "prefetch metadata for this directory's entries as a batch" capability to the walkers everyone already uses — io_uring `IORING_OP_STATX` batches with a thread/serial fallback — so every downstream tool gets the `ls -l`/`du`-class win without knowing io_uring exists.

**Why here and not in each tool:** patching uutils fixes ~10 metadata-heavy tools; these three crates are the traversal layer for hundreds. One reviewed implementation, ecosystem-wide reach. This document is written for contributors to *those* repositories, not to uutils.

---

## 1. The problem, as it appears in these crates

All three walkers expose per-entry `DirEntry::metadata()`, and all three implement it as one `statx` syscall per call. A consumer that needs metadata for every entry (sorting by mtime, size accounting, mode display) produces the measured N+1: on a 5000-entry directory, 5001 `statx` calls — 33% of syscall time even warm-cache, and N serial network round trips cold on NFS.

The kernel-side batching primitive has existed since 5.6 (`IORING_OP_STATX`), needs no new kernel ABI, and — one honest caveat contributors should know — is internally executed on kernel worker threads (it is force-async in io_uring), so the win is *one submission crossing + parallel execution*, not magic asynchrony.

## 2. Where the change lands, per crate

**`walkdir` (sequential):** the natural seam is `WalkDir`'s per-directory read: it already collects a directory's entries before yielding (sorting support requires this). An opt-in builder flag — `.prefetch_metadata(true)` — batches statx for the collected entries and stores results in each `DirEntry`, so subsequent `entry.metadata()` is a field access. API surface: one builder method, one `OnceCell`-style slot in `DirEntry`. No behavior change unless opted in.

**`ignore` (parallel):** `WalkParallel` workers each process directories; the same per-directory batch slots into the worker loop. Because workers are already parallel, the incremental win here is crossing reduction and NFS round-trip overlap per worker — measure honestly against the existing parallelism, which already hides some of the serial-statx cost. This is BurntSushi's repo: expect the review to demand the fallback story and zero-cost-when-unused proof up front.

**`jwalk` (parallel, batch-oriented):** the best architectural fit — jwalk already processes directories as batches through its `process_read_dir` callback, which receives the whole entry vector. Batched statx there is almost the intended use of the hook; it may even be implementable as a documented recipe using the public API before (or instead of) landing in the crate itself. Prototype here first.

## 3. Design requirements the reviews will impose

1. **Fallback is not optional.** io_uring is unavailable on non-Linux, on kernels < 5.6, and — critically — is seccomp-blocked in a meaningful share of container runtimes. The API must degrade: uring batch → thread-pool statx → serial statx, detected at runtime, invisible to the caller. (The thread-pool tier is nearly as good cold-cache anyway, since the kernel runs uring statx on workers regardless.)
2. **Zero cost when unused.** Non-opted walks must not pay a byte or a branch worth caring about; these crates' other consumers include build tools where startup matters.
3. **Dependency discipline.** BurntSushi's crates are conservative about dependencies. The `io-uring` crate behind a feature flag (`features = ["uring"]`) is the likely acceptable shape; a mandatory dependency is a likely rejection.
4. **Error mapping.** Per-entry statx results must map back to entries exactly as serial calls would — tools print per-file errors in deterministic order.
5. **Prior-art homework:** cite the measured baseline (5001 statx / 5000 entries), the kernel's force-async statx (so nobody oversells asynchrony), and the NFS `DONT_SYNC` interaction from the uutils work — walkers should expose the freshness knob too, since network filesystems are where the big number lives.

## 4. Effectiveness test — did it actually work?

```bash
# In-crate benchmark (each repo has a bench setup; walkdir has compare scripts):
# 5000-entry dir, metadata for every entry:
strace -cf target/release/examples/walk-bench --metadata /tmp/lstest
```

| Gate | Threshold | Meaning |
|---|---|---|
| statx syscall count, opted-in, local | N+1 → single-digit `io_uring_enter` | Batching works |
| Wall time, warm local | Modest improvement (syscall overhead only) — report, don't oversell | Honest local ceiling |
| Wall time, cold NFS directory | The headline: serial round trips → overlapped; expect integer factors | The case that justifies the feature |
| Not opted in | Bit-identical syscalls and timing vs current release | Zero-cost proof |
| Seccomp-blocked io_uring (docker default-like profile) | Silent thread-pool fallback, correct results | The container gate |
| Downstream smoke: `fd` / `ripgrep` built against the branch | No regression un-opted; improvement when the tool opts in for its metadata-needing modes | Real-consumer proof |

**The honest failure mode:** benchmarking only warm local ext4 and concluding the feature isn't worth the complexity — by that measure it barely is. The feature exists for network filesystems and syscall-tax-heavy environments (containers with expensive syscall paths); the NFS row is the one that carries the PR.
