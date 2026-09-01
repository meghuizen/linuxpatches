# Userspace stat/syscall optimization series

Companion to [`../linux-kernel/`](../linux-kernel/README.md) (kernel-side work). Baseline measurement that motivates everything here: `ls -l` on 5000 files = 5001 statx syscalls (33% of syscall time warm; N serial wire round trips on NFS). Strategy: eliminate, then trim, then batch — the cheapest syscall is the one never made. No kernel ABI changes anywhere in this series.

| File | Target codebase | What |
|---|---|---|
| 01-fstat-after-open.md | uutils/coreutils | Eliminate: path-stat on files that get opened (fstat the fd instead; race fix) |
| 02-dtype-type-decisions.md | uutils/coreutils | Eliminate: type-only checks ride getdents d_type |
| 03-ls-color-stat-skipping.md | uutils/coreutils (+ lscolors crate) | Eliminate: color without stats when the palette permits |
| 04-statx-masks-and-dont-sync.md | uutils/coreutils (uucore) | Trim the irreducible: field masks + AT_STATX_DONT_SYNC (NFS round-trip elimination) |
| ecosystem/05-rust-walk-crates.md | walkdir / ignore (ripgrep) / jwalk | Batch: per-directory statx batching in the walkers the ecosystem shares |
| ecosystem/06-gnulib-fts.md | gnulib + GNU coreutils | Batch: same design for the C world (fts for du/rm/chmod/chown/find; ls.c separately) |
| 07-unify-shared-fs-helpers.md | uutils/coreutils (uucore) | Consolidate: the fixes above, shared once in uucore — and which ones must not be shared |

Recommended order: 01+02 (mechanical, this week) → 04 masks (uucore) → 03 → 05 (prototype in jwalk, then walkdir/ignore) → 04 DONT_SYNC with NFS numbers → 06 (bring 05's results as evidence; FSF paperwork first).

07 comes after 01-04 have landed, not before: it is written from a census of what those fixes turned out to have in common, and two of its five steps depend on 04. Read it before starting a fifth per-utility fix.
