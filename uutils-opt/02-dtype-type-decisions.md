# Fix 2 — Use `d_type` (via `DirEntry::file_type()`) for type-only decisions

**Target repository:** `uutils/coreutils`
**What this fix does, in one sentence:** wherever code only needs to know *what kind* of filesystem object a directory entry is (directory? symlink?), read it from the directory entry itself — which the kernel already delivered for free during `getdents64` — instead of issuing a `stat` syscall per entry.

| | |
|---|---|
| Pattern to fix | `path.is_dir()` / `path.is_symlink()` / `metadata()?.is_dir()` on paths that came from a directory walk |
| Replacement | `dir_entry.file_type()` — zero syscalls on Linux in the common case |
| Effort | Grep-driven audit; days |
| Risk | Low — Rust std handles the fallback case itself |
| Line refs | As of shallow clone of master, 2026-08-31 |

---

## 1. Background: the free metadata nobody uses

When the kernel returns directory entries from `getdents64`, each record already carries a `d_type` byte: `DT_REG`, `DT_DIR`, `DT_LNK`, `DT_FIFO`, and so on. Rust's standard library exposes exactly this: on Linux, `std::fs::DirEntry::file_type()` reads the stored `d_type` **without any syscall**. Only when a filesystem reports `DT_UNKNOWN` (some can't fill it cheaply) does std silently fall back to an `lstat` — so calling `file_type()` is never *worse* than stating, and is usually free.

By contrast, `path.is_dir()`, `path.is_symlink()`, and `fs::metadata(path)?.is_dir()` each issue a full `statx` with a complete path walk — to answer a one-byte question the kernel already answered.

## 2. The teaching contrast — both patterns live in `rm.rs` today

The good pattern, already in the tree (`src/uu/rm/src/rm.rs:535-536`):

```rust
.map(|entry| match entry.file_type() {          // d_type: zero syscalls
    Ok(ft) if ft.is_dir() => count_files_in_directory(&entry.path()),
```

The bad pattern, 130 lines later (`rm.rs:669`):

```rust
if !path.is_dir() || path.is_symlink() {        // TWO statx path walks
```

Same file, same author intent, 2x per-entry syscalls apart. The audit is exactly this: find every type-only check on a path that originated from a directory walk, and route it through the `DirEntry` it came from.

## 3. The audit rule — and the two exceptions

> If the question is only "what type is it," and a `DirEntry` is in scope (or can be kept in scope), use `entry.file_type()`.

**Exception 1 — dereference semantics.** `entry.file_type()` reports the *symlink itself* (like `lstat`). Code that must classify the symlink **target** (e.g., `ls` with `-L`/dereference logic, see `ls.rs:868` where dereferencing is explicitly requested) genuinely needs the following `metadata()` call — leave those.

**Exception 2 — metadata needed anyway.** `du` fetches full metadata per entry for sizes (`du.rs:148-156`); its type checks (`du.rs:167`) piggyback on metadata it must have regardless. Converting those buys nothing — skip them. The wins are in tools that walk without needing sizes: `rm -r`'s prompting/counting paths, tree recursion checks, `-F`-style classification.

**Design consequence worth stating in the PR:** several call sites take `&Path` where the caller *had* a `DirEntry` and threw it away. The mechanical fix is sometimes one line; the right fix is occasionally a signature change to pass the entry (or its `FileType`) down. Keep those refactors small and per-utility.

## 4. Upstreaming notes

Same flow as Fix 1: per-utility PRs, GNU compatibility suite as the semantic gate. Special attention to filesystems returning `DT_UNKNOWN` is *not* needed in review — std's fallback covers it — but saying so preemptively in the PR description (with a pointer to std's `DirEntry::file_type` docs) pre-answers the one objection this always gets.

## 5. Effectiveness test — did it actually work?

```bash
# Build a mixed tree, then count syscalls:
mkdir -p /tmp/t && cd /tmp/t && for i in $(seq 500); do mkdir d$i; : > f$i; ln -s f$i l$i; done
strace -cf ./target/release/rm -ri /tmp/t < /dev/null 2>&1 | grep -E 'statx|lstat|newfstatat'
```

| Gate | Threshold | Meaning |
|---|---|---|
| stat-family calls per entry during traversal | Drops for every converted call site; ideally near zero for type-only phases | The d_type is being used |
| Same run on an fs returning `DT_UNKNOWN` (e.g., some FUSE) | Works, stat count returns — but never exceeds the pre-fix count | Fallback intact |
| GNU test suite for the utility | Identical pass set | Symlink/dereference semantics survived (Exception 1 handled) |

**The honest failure mode:** converting a call site inside a loop that also fetches full metadata two lines later (Exception 2) — strace shows no delta because the expensive call remains. The strace gate catches this; if the count didn't move, the conversion was decorative and should be dropped from the PR.
