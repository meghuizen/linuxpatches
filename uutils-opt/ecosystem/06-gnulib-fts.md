# Ecosystem 2 — Metadata batching in gnulib fts (the GNU C toolchain's walker)

**Target repositories (where these changes must land):**

| Change | Repository | File(s) | Beneficiaries |
|---|---|---|---|
| Batched stat in FTS traversal | gnulib — git.savannah.gnu.org/gnulib | `lib/fts.c`, `lib/fts_.h` | GNU coreutils `du`, `rm`, `chmod`, `chown`, `chgrp`; findutils `find` |
| `ls -l` batching (separate — ls does **not** use fts) | GNU coreutils — git.savannah.gnu.org/coreutils | `src/ls.c` (the `gobble_file` stat site) | `ls` itself |

**What this change does, in one sentence:** give the C-world traversal layer the same per-directory batched-statx capability as the Rust walkers (document 05) — landing it once in gnulib's `fts` upgrades five GNU coreutils tools and `find` together, with GNU `ls` as a separate, smaller patch in coreutils proper.

**Written for:** contributors to gnulib/coreutils, which means: C, GNU coding standards, copyright assignment to the FSF (a real process step — start it early), and review on bug-gnulib / coreutils@gnu lists.

---

## 1. Why gnulib fts is the right landing zone — and the ls exception

GNU's recursive tools do not each implement traversal; they share gnulib's `fts` (a descendant of BSD fts with GNU extensions). `du`, `rm`, `chmod`, `chown`, `chgrp` in coreutils and `find` in findutils all walk through it, and fts *already* stats entries on the tools' behalf (`FTS_NOSTAT` exists precisely because stats are its known cost — callers that only need types opt out and ride `d_type`, the C equivalent of Fix 2).

That existing structure is the opportunity: fts controls the stat loop, so batching lands in exactly one place — where fts fills `FTSENT.fts_statp` for a directory's children — invisible to every caller.

**The exception that surprises people:** GNU `ls` does not use fts. Its per-entry stat lives in `src/ls.c` (`gobble_file`), which already uses `statx` with **field masks** on Linux — GNU ls did the mask half of uutils Fix 4 years ago (worth citing in the uutils PRs as precedent). So `ls -l` batching is a separate, self-contained coreutils patch against `gobble_file`'s loop, not a gnulib one.

## 2. Where the change lands in `lib/fts.c`

fts reads a directory (`fts_build`), creating the child `FTSENT` list; unless `FTS_NOSTAT`, each child gets statted (`fts_stat`). The batch point is the seam between: after the children list exists and before descent, submit statx for all children needing it as one io_uring batch (`IORING_OP_STATX`, kernel 5.6+, no new ABI), landing results in each `fts_statp`; fall back to today's serial loop when the ring is unavailable.

Design constraints specific to this codebase:

1. **liburing cannot be a hard dependency.** gnulib policy and coreutils portability both forbid it. The workable shapes: raw `io_uring_setup/enter` syscalls behind a configure check (gnulib already carries raw-syscall wrappers for statx itself in `lib/statx.c`), or dlopen. Runtime fallback regardless — same seccomp reality as document 05.
2. **fts's own dirfd discipline.** fts walks with directory fds and `fstatat(dirfd, name)` to avoid path re-resolution; the batch must preserve that (statx SQEs take dirfd+name naturally — this is a fit, not a fight).
3. **Error semantics are contractual.** `FTSENT.fts_errno` per entry, and tools print errors in traversal order — batch completion order must not leak into output order.
4. **`FTS_NOSTAT` interaction.** Callers that opted out stay opted out; the batch path only replaces stats that would have happened.

## 3. Sequencing and politics

Gnulib review is careful and the fts code is shared with real history — propose in this order: (a) an RFC on bug-gnulib with the measured N+1 (5001 statx / 5000 entries; NFS round-trip math), (b) the fallback-first patch where io_uring absence produces byte-identical behavior, (c) coreutils/findutils version bumps consuming it (their maintainers overlap — Pádraig Brady, Jim Meyering review both). The `ls.c` patch can proceed in parallel in coreutils and will likely land first (smaller blast radius). FSF copyright assignment before any of it.

## 4. Effectiveness test — did it actually work?

```bash
# fts consumers, 5000-entry tree:
strace -cf ./du -s /tmp/lstest          # statx count: N+1 -> few io_uring_enter
strace -cf ./find /tmp/lstest -newer /tmp/ref -print > /dev/null
# The NFS gate (the headline, as everywhere in this series):
nfsstat -c > b; ./du -s /mnt/nfs/tree; nfsstat -c > a; diff b a   # GETATTR delta
# ls separately:
strace -cf ./ls -l /tmp/lstest > /dev/null
```

| Gate | Threshold | Meaning |
|---|---|---|
| statx count per fts consumer | Collapses to submissions | Batch wired at the right seam |
| `FTS_NOSTAT` callers (`find -name`-only runs) | Zero new syscalls | Opt-out respected |
| io_uring absent/blocked | Byte-identical strace vs unpatched | The gnulib acceptance bar |
| GNU test suites (coreutils + findutils full runs) | Green | fts is load-bearing for half the toolchain — this gate is absolute |
| NFS GETATTR delta on `du`/`ls -l` | Round trips collapse | The number that carries the RFC |

**The honest failure mode:** treating this as one patch. It is one *design* in two codebases with two review cultures and a legal prerequisite; the Rust version (document 05) will land months earlier and its measured results are the strongest evidence the gnulib RFC can cite. Do 05 first, bring the numbers here.
