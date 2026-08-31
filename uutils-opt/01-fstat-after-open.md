# Fix 1 — Use fstat-after-open instead of stat-then-open

**Target repository:** `uutils/coreutils` (github.com/uutils/coreutils)
**What this fix does, in one sentence:** wherever a utility calls path-based `fs::metadata()` on a file it also opens, derive the metadata from the opened handle instead — removing one full kernel path walk per file and a time-of-check/time-of-use race.

| | |
|---|---|
| Pattern to fix | `fs::metadata(path)` (or `symlink_metadata`) followed by `File::open(path)` on the same file |
| Replacement | `File::open(path)` first, then `file.metadata()` (compiles to `fstat(fd)`) |
| Effort | Audit + mechanical fixes; days |
| Risk | Low, with one semantic trap (FIFOs, below) |
| Line refs | As of shallow clone of master, 2026-08-31 — re-grep before patching |

---

## 1. Background: why the order matters

`fs::metadata(path)` makes the kernel resolve the whole path — walk every directory component, check permissions at each step — just to read the inode's attributes. `File::open(path)` does the *same walk again*. Opening first and calling `file.metadata()` instead issues `fstat(fd)`: the kernel already holds the resolved inode from the open, so it is a pure in-memory attribute copy — no walk, no I/O (verified in kernel source: `vfs_fstat` goes straight to `vfs_getattr` on the file's resolved path, `fs/stat.c:276-281`).

There is also a correctness bonus. `stat` then `open` is a race: the path can be swapped (e.g., replaced with a symlink) between the two calls, so the attributes you checked may describe a different file than the one you opened. `open` then `fstat` cannot race — the attributes describe the exact file you hold. GNU coreutils uses open-then-fstat for this reason.

## 2. The worked example: `cat`

`src/uu/cat/src/cat.rs:434` — `get_input_type()` calls `metadata(path)` to classify the input (block device, char device, FIFO, socket, directory) before the file is opened and read.

The fix shape: open the file first, classify from `file.metadata()` (fstat), and handle the two cases people worry about:

- **Directories:** `open(O_RDONLY)` on a directory *succeeds* on Linux; the error comes at `read()` (EISDIR). Classifying from fstat after open works — detect the directory from the metadata and emit the same error message before reading, preserving output parity.
- **FIFOs — the semantic trap:** opening a FIFO read-only *blocks until a writer appears*. That is correct, desired `cat` behavior (GNU cat blocks the same way — it opens first and fstats after). But any *pre-open* logic that currently depends on knowing "this is a FIFO" before the open must be re-checked: if uutils uses the classification to choose splice vs read paths, that decision can move to after the open with no behavior change; if it uses it to avoid blocking, that would be a GNU-behavior divergence that should not exist anyway.

The ELOOP special-case in the current code (`too_many_symlink_code`) transfers directly: `File::open` returns the same errno.

## 3. The audit rule for the other 108 utilities

The candidate list (`grep -ln 'fs::metadata\|symlink_metadata' src/uu/*/src/*.rs`) is long, but most hits are *legitimate*: `chmod`, `chown`, `chgrp`, `rmdir` operate on paths without opening — path-based metadata is correct there. The rule that separates them:

> Fix only where the same utility opens the same file for reading or writing.
> If the tool never opens it, path-based metadata is the right call — leave it.

High-confidence candidates from the scan (each opens its input): `cat`, `comm`, `pr`, `dd`, parts of `cp` (`cp.rs`, `copydir.rs` — where the source is opened for copying, its metadata should come from the source fd). Each needs the individual call-site check against the rule above.

## 4. Upstreaming notes

uutils merges via PR with two gates that fit this change well: the project's own tests (`cargo test -p uu_cat` etc.) and the GNU compatibility suite (`util/build-gnu.sh` + running GNU's cat/misc tests against the uutils binary). The FIFO and directory error-message cases are covered by GNU tests — passing them *is* the semantic proof. Frame the PR as "GNU parity" (GNU already does open-then-fstat), not as optimization — that is the framing the project accepts fastest. One utility per PR; `cat` first as the worked example.

## 5. Effectiveness test — did it actually work?

```bash
# Syscall proof, per fixed utility:
strace -cf ./target/release/cat /tmp/somefile > /dev/null
```

| Gate | Threshold | Meaning |
|---|---|---|
| `statx`/`lstat` count per input file | One fewer than before (the path-based call gone); `fstat`/`statx(fd)` appears instead | The walk was eliminated |
| GNU test suite for the utility | Identical pass set before/after | No semantic drift |
| FIFO behavior: `mkfifo /tmp/p; timeout 1 ./cat /tmp/p; echo $?` | Blocks then times out (124) exactly as GNU cat | The trap was avoided |

**The honest failure mode:** wall-time benchmarks show nothing — a single path walk is ~1µs warm. This fix is not a wall-time win on one file; it is a correctness fix (race removal) plus a per-file syscall reduction that only becomes measurable in many-file loops. Do not claim throughput numbers in the PR; claim GNU parity and show the strace delta.
