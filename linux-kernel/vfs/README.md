# VFS from the ground up

Working directory for a first-principles pass over the Linux VFS: isolate the
code, draw the real dependency graph, find where the memory and the cache
lines go, read what gcc actually emitted, locate the hot paths, and only then
propose changes.

Everything here is written against **one tree and one build**, and the numbers
are reproducible against that build alone:

    source   /usr/src/linux            518e5b794c06
    version  7.3.0-rc3 + 824 commits   (Makefile says 7.3.0-rc3)
    build    /usr/src/kbench/builds/baseline
    uname    7.3.0-rc3-kbench-baseline-00824-g518e5b794c06
    gcc      15.2.0 (Ubuntu 15.2.0-16ubuntu1), -O2
    config   RANDSTRUCT_NONE, MITIGATION_RETPOLINE=y, X86_KERNEL_IBT=y,
             FUNCTION_TRACER=y, DEBUG_INFO_DWARF5 + BTF

`RANDSTRUCT_NONE` is not optional: under `RANDSTRUCT_FULL` gcc reorders
`inode`, `dentry` and `file` on its own and every layout statement below
becomes a statement about a random permutation.

## Status

Series for submission: [`submission/`](submission/), `[RFC PATCH 0/3]`, base
v7.3-rc3 (518e5b794c06). RFC because patch 2 overlaps Mateusz Guzik's posted
work. Each patch was measured alone in a nested KVM guest (29 interleaved
boots, 2 rounds, 9 baseline boots; see
[`../SUBMISSION-STATUS.md`](../SUBMISSION-STATUS.md)).

| # | patch | measured result |
|---|---|---|
| 1/2 | selftests: build and run the openat2 tests again | builds and passes every boot |
| 2/2 | fs: allocate the struct file for open() only when it is needed | failed open (ENOENT): -22% kernel instructions/open on ext4, -13% on tmpfs; successful open inside the base range |

The series is based on vfs.git `vfs-7.4.lookup`, on top of Mateusz
Guzik's "fs: avoid spurious dentry ref/unref cycle on open"
(161ce1e692d0), queued for Linux 7.4.

Removed (in [`submission/removed/`](submission/removed/), reasons in
[`submission/REVIEW.md`](submission/REVIEW.md)):

| old # | patch | reason |
|---|---|---|
| 1 | fs: hand the path walk's dentry reference to the opened file | superseded: the same change by Mateusz Guzik is queued in vfs.git (161ce1e692d0) and also saves the mount reference operation. Our measurement of the idea: -38% kernel cycles/open with 16 processes on one file |
| 11 | lockref: adjust the count with a single addition | no measurable difference: open/stat instructions within +-1.3%, inside the 2-4% spread |
| 3-8 | rcu-walk statx (lsm, selinux, fs, ext4, btrfs, xfs) | bug: NULL dereference race under `rcu_read_lock()`; also skips `security_inode_getattr()` |
| 9 | embed the LSM per-file blob in the struct file allocation | regression: +40 bytes per open file with AppArmor/Landlock (filp 192 -> 256) |
| 12 | move `i_fop` and `i_flctx` off the refcount cacheline | regression that cannot be fixed: one more line on stat and open at some inode offsets |
| 13 | place `inode->i_data` on a cacheline boundary | premise false: `struct inode` is not cacheline aligned |
| 14 | regroup `struct address_space` | no difference on its target workload (10.21M vs 10.18M iops) |

The module-pin patch (15 in the original count) was withdrawn earlier; see
`05-proposal.md` §2.1. The old export in `patches/` is superseded
([`patches/README.md`](patches/README.md)).

## Why static first

The measurement rig for this work is a KVM guest on a WSL2 laptop, and it has
a documented, measured inability to resolve small effects: the same open/close
workload scales 5x across 6x the processes on the host and does not scale at
all inside the guest (`/usr/src/kbench/README.md`). Nested virtualisation
manufactures cross-CPU cacheline traffic that is not there on real hardware.

So the order of evidence here is deliberate:

1. **What the compiler emitted** — instruction counts, stack frames, atomic
   instructions, indirect dispatches. Read out of the `.o` files. This is a
   fact about the build and needs no machine to measure on.
2. **What the layout is** — `pahole` on the built `vmlinux`. Also a fact.
3. **What executes** — ftrace `function_profile` hit counts from inside the
   guest. Counts are reliable there; the nanosecond column is not, without
   `FUNCTION_GRAPH_TRACER`.
4. **What it costs** — only ever as a control-normalised ratio, never a raw
   number. See kbench's `norm=`.

A proposal that only survives step 4 is not established. A proposal that
survives steps 1-3 is worth building.

## Documents

| file | what it is |
|---|---|
| `05-proposal.md` | the original 15-patch proposal (superseded by `submission/`, see Status): the ledger of shared writes before/after, the three mechanisms found by re-reading the code, what was left alone and why, validation plan |
| `submission/` | the 3 patches for submission, `REVIEW.md` (per-patch review and runtime results), tests |
| `patches/` | old export, superseded; only a note remains |
| `03-vfs-structure.md` | the whole layer: object model, leverage, per-syscall cost, cascades, reuse — **start here** |
| `04-hypotheses.md` | what we believe and what would show it false — the live list |
| `40-abi-and-wordsize.md` | 32-bit / 64-bit / UAPI compatibility, and the 12-item checklist |
| `50-concurrency-and-scaling.md` | shared state, cache lines, scaling ceilings, what is and is not fixable |
| `01-open-path.md` | static anatomy of `openat` — graph, code volume, atomics, cache lines |
| `02-stat-path.md` | the same for `statx`, plus the open-then-stat and stat-then-open sequences |
| `10-validation-rules.md` | every rule a VFS change must still satisfy: permission, LSM, mount, namespace, path-walk, refcount, fsnotify, stat, concurrency |
| `20-filesystems-and-vfs.md` | how each filesystem uses the VFS and what a change must be validated against |
| `30-workload-matrix.md` | what real software does to the VFS, and the covering test matrix |
| `proofs/` | Lean 4 models: reference ownership (open), lazy file allocation, borrowed module reference, seqcount-validated stat — 33 theorems |
| `graphs/` | generated: `static-graph.json`, `*.dot` |
| `tools/` | the extractors |

`10-` and `20-` are the constraint half. Nothing in the proposal half is
allowed to contradict them.

## Tools

    tools/static-graph.py <objects...> -o graphs/static-graph.json
    tools/path-report.py graphs/static-graph.json <root> [--depth N] [--dot f]

`static-graph.py` disassembles the built objects rather than parsing the
source, because on this path inlining *is* the story: `do_open()`,
`open_last_lookups()`, `walk_component()` and `lookup_open()`'s callers do not
exist as functions in `namei.o` — they are inside `path_openat`'s 592
instructions. A source-level call graph would describe a program that was
never compiled.

It records, per function: instruction count, byte size, stack frame
(`sub $N,%rsp` plus callee-saved pushes), direct callees, indirect dispatch
count, lock-prefixed instructions by mnemonic, and `pause` count (a cmpxchg
retry loop).

Two details that cost a rewrite each, kept here so they are not rediscovered:

- In a relocatable object a call to a **global** symbol prints as
  `call ab5 <do_dentry_open+0x5>` with the real callee only in the following
  relocation line; the inline annotation points just past the call site and is
  meaningless. A call to a **file-local static** prints as
  `call 9bb0 <path_openat>` with no relocation, and there the annotation is
  the truth. A call must be held pending until it is known which it was.
- With `MITIGATION_RETPOLINE=y` an indirect call is emitted as a direct call
  to `__x86_indirect_thunk_rax`. Every `->i_op` / `->f_op` / `->d_op` dispatch
  therefore looks like a direct call to a thunk. Counting those as callees
  puts a fictional hub in the middle of the graph; they are counted as
  indirect dispatches instead.

## Analysis checklist

- [x] baseline updated and all kbench worktrees rebased onto it
- [x] static graph extracted (2503 functions)
- [x] `01-open-path.md`
- [x] `10-validation-rules.md`
- [x] `20-filesystems-and-vfs.md`
- [x] `30-workload-matrix.md`
- [x] Lean model of the reference-ownership contract — `proofs/`, 13 theorems,
      including negative controls for Guzik's withdrawn v4 and for the naive
      conditional clear
- [x] `02-stat-path.md`
- [x] `03-vfs-structure.md` — full-VFS graph, 4378 functions
- [x] `04-hypotheses.md` — 13 hypotheses + 5 rejected, each falsifiable
- [x] `40-abi-and-wordsize.md`
- [x] `50-concurrency-and-scaling.md`
- [ ] hot-path separation: ftrace `function_profile` counts from the guest
- [x] `seq-bench.sh` — the sequence harness (gap G1), in
      `/usr/src/kbench/scripts/guest/`; measures the filename_lookup-per-op
      invariant, not just wall clock
- [ ] run it: `kbench build` + boot, baseline vs dopen
- [ ] a `relatime` mount in the rig — the guest root is `noatime`
      (`mkrootfs.sh:48`) so nothing measured has ever included `touch_atime`
- [x] one-line selftest fix to send upstream, see below (now `submission/` 1/3)
- [x] proposal — `05-proposal.md`, 14 patches (old export, since superseded by the 3 in `submission/`), all compiled, full build of the series
- [x] Lean models for the two new mechanisms (`LazyAlloc`, `RcuStat`), 14 theorems
- [x] `scripts/guest/vfs-verify.sh` — exact hit counts for the predictions in `05-proposal.md` §8 (`KB_EXTRA=kbench.vfsverify=1`)
- [ ] run vfs-verify on `vfs` and `baseline` and record the two columns
- [ ] 32-bit size check of patches 13–15 per `40-abi-and-wordsize.md` §5.3 (moot: those patches were removed)

## An upstream bug found on the way

`tools/testing/selftests/Makefile:106` says `TARGETS += openat2`, and
`tools/testing/selftests/openat2/` does not exist — the tests live in
`filesystems/openat2/` and that path is **not** in `TARGETS` either (lines
35-49 enumerate the `filesystems/` subdirectories and openat2 is not among
them), nor is it built by `filesystems/Makefile`.

So `openat2_test`, `resolve_test`, `rename_attack_test` and `emptypath_test`
are orphaned: four binaries covering the entire `RESOLVE_*` surface —
`RESOLVE_BENEATH`, `RESOLVE_IN_ROOT`, `RESOLVE_NO_SYMLINKS`,
`RESOLVE_NO_MAGICLINKS`, `RESOLVE_NO_XDEV`, and a rename-race attack test —
that a default kselftest run silently does not build or execute.

That is the suite which would validate the path-walk work in this directory.
Fixing it is a one-line change and should go upstream on its own, ahead of
anything else here. It is patch 1/3 in [`submission/`](submission/).
