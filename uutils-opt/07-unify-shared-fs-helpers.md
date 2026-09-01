# Fix 7 — Unify the repeated filesystem-access fixes into uucore helpers

**Target repository:** `uutils/coreutils`, `src/uucore` plus adopting utilities
**What this fix does, in one sentence:** the fixes in documents 01–04 keep reappearing in different utilities because each is written where it was noticed; this collapses the ones that are genuinely the same thing into shared helpers, and says explicitly which ones must *not* be shared.

| | |
|---|---|
| Pattern to fix | The same filesystem question answered separately in many utilities |
| Replacement | Three shared helpers, one type consolidation, two memoizations |
| Effort | Five PRs, staged; weeks, not days |
| Risk | Low per step, but `src/uucore` is reviewed harder than per-tool fixes |
| Line refs | Against `meghuizen/coreutils` at 3251833, 2026-09-01 — re-grep before patching |

---

## 1. Background: four shapes, not eleven bugs

Documents 01–04 each fix one utility. A census of all 109 utilities shows why
that keeps happening: the defects are a handful of shapes, each duplicated.

| Shape | Utilities affected | Verdict |
|---|---|---|
| Same path stat'ed repeatedly in one operation | 18 | **Do not unify** |
| Type-only question via a fresh stat | 4 | No helper; pass the `DirEntry` down |
| `metadata()` then `open()` on the same file | 13 | **Build one helper** |
| `canonicalize`/`exists` in a per-entry loop | 7 | Do not unify; three are bugs |
| Same-file detection | 10, with **7 incompatible methods** | **Consolidate — mostly deletion** |
| Follow-symlink decision | 12 | Unify the leaf only, never the enums |

This is also less about new code than it looks. `uucore::fs` already contains
`FileInformation`, `paths_refer_to_same_file` and `are_hardlinks_to_same_file`.
The duplication persists because five utilities wrote private clones instead,
and because no single existing function is trusted enough to be used alone —
`mv.rs:532-535` ORs three of them together.

Where a step below only removes duplication, it says so. Two of them remove a
real bug.

## 2. Share the `metadata(path, follow)` leaf

`uucore::perms::get_metadata` (`perms.rs:279`) and ls's private
`get_metadata_with_deref_opt` (`ls.rs:1559`) are the same function, character
for character. Seven more inline copies of the body exist at `test.rs:405` and
`:443`, `touch.rs:479-482` and `:723-732`, `cp.rs:2698-2700`, `du.rs:150-157`,
`stat.rs:1377`.

```rust
// src/uucore/src/lib/features/fs.rs
/// Metadata for `path`, following a final symlink only when `follow` is true.
///
/// `follow: true` is `Path::metadata` (stat); `follow: false` is
/// `Path::symlink_metadata` (lstat) and describes the link itself.
pub fn metadata_for(path: &Path, follow: bool) -> IOResult<fs::Metadata> {
    if follow { path.metadata() } else { path.symlink_metadata() }
}

// src/uucore/src/lib/features/perms.rs — keep the existing name working
pub use crate::fs::metadata_for as get_metadata;
```

`fs` is the right home: 43 crates already depend on that feature, where `perms`
is unix-only and used by 8.

**Why it helps.** Honestly: this removes duplication, not a bug. The value is
that the polarity stops being retyped. Seven inline copies each independently
encode "follow means `metadata`, not `symlink_metadata`", and that is exactly
the pair a reader inverts.

**What must not be unified:** the option enums. `du::Deref` needs
`Args(Vec<PathBuf>)` for `-D`; `ls::Dereference` needs `DirArgs`;
`perms::TraverseSymlinks` separates recursion from operand semantics and is the
only one that gets that split right. One enum for all of them would have six
variants where each tool uses three, and every `match` would carry unreachable
arms. Each utility collapses its own enum to a `bool` at the call site, which
`du.rs:141-147` and `cp.rs:1289` already do.

## 3. One file-identity type, and bridge the two Metadata types

Four representations of "which file is this" exist: `uucore::fs::FileInformation`
(`fs.rs:54`), `uucore::safe_traversal::FileInfo` (`safe_traversal.rs:655`), du's
private `FileInfo { file_id: u128, dev_id: u64 }` (`du.rs:120`), and mv's bare
`(u64, u64)` tuple keys (`hardlink.rs:20,27`).

The mismatch costs a live bug in `du::Stat::new_from_dirfd` (`du.rs:178-211`):

```rust
let safe_metadata = dir_fd.metadata()?;                  // fd-based, safe
let file_info = safe_metadata.file_info();
let file_info_option = Some(FileInfo {                   // cast between two
    file_id: file_info.inode() as u128,                  // identity types
    dev_id: file_info.device(),
});
let blocks = safe_metadata.blocks();

// Create a temporary std::fs::Metadata by reading the same path
// This is still needed for compatibility [...]
let std_metadata = fs::symlink_metadata(full_path)?;     // path-based!
let latest_time = time.and_then(|time| metadata_get_time(&std_metadata, time));
```

The comment admits the second stat exists only because `Stat.metadata` is typed
`std::fs::Metadata` and cannot be fed from a `DirFd`. Yet
`safe_traversal::Metadata` already exposes `modified()`, `accessed()` and
`changed()` (`safe_traversal.rs:779-787`) — the data was in hand.

```rust
// src/uucore/src/lib/features/safe_traversal.rs
impl Metadata {
    /// The identity of this file, in the type the rest of uucore uses.
    pub fn file_information(&self) -> crate::fs::FileInformation { ... }

    /// The timestamp `field` names, from this stat. `Birth` is not in
    /// `struct stat`, so it is the one field that still needs a path lookup.
    pub fn time(&self, field: MetadataTimeField) -> Option<SystemTime> { ... }
}

// src/uu/du/src/du.rs — after
let safe_metadata = dir_fd.metadata()?;
let latest_time = match time {
    Some(MetadataTimeField::Birth) => birth_time_of(full_path),
    Some(field) => safe_metadata.time(field),
    None => None,
};
```

**Why it helps.** Two things, and the second matters more.

1. One fewer syscall per directory — the small half.
2. It closes a TOCTOU hole **in code whose whole purpose is to be TOCTOU-safe.**
   `dir_fd.metadata()` is an `fstat` on a descriptor already held: it describes
   exactly that directory. `fs::symlink_metadata(full_path)` re-resolves the
   path from scratch, so any component can be replaced in between. Today `du`
   can report a size and inode from one directory and a timestamp from another,
   three lines after the safe-traversal machinery built to prevent exactly that
   has succeeded.

## 4. Open the file, then stat the descriptor

Thirteen utilities call `fs::metadata(path)` on a file they then open: `wc` (4
sites at `wc.rs:285,697,741,776`), `shred` (3), `install` (3),
`head`/`tail`/`truncate`/`dd` (2 each), `cat`/`comm`/`split`/`pr`/`od`/`sort` (1
each). `head.rs:514,540`, `dd.rs:1549` and `od/multifile_reader.rs:171` already
do it correctly, so the target shape is in the tree.

```rust
// src/uucore/src/lib/features/fs.rs
/// Open `path` and describe the file that was actually opened.
///
/// The metadata comes from the descriptor, so it cannot describe a different
/// file than the one that will be read. Only for callers that were going to
/// open the file anyway: opening has side effects a stat does not — a FIFO
/// blocks until a writer appears.
pub fn open_and_stat(path: &Path) -> IOResult<(File, fs::Metadata)> {
    let file = File::open(path)?;
    let metadata = file.metadata()?;
    Ok((file, metadata))
}
```

A representative adoption, `split.rs:475-484`:

```rust
// before — two path walks, and the size may describe a different file
let metadata = metadata(Path::new(input))?;
let metadata_size = metadata.len();
if num_bytes <= metadata_size {
    Ok(metadata_size)
} else {
    let mut tmp_fd = File::open(Path::new(input))?;
    let end = tmp_fd.seek(SeekFrom::End(0))?;

// after — one walk, and the size describes the handle we seek on
let (mut fd, metadata) = uucore::fs::open_and_stat(Path::new(input))?;
let metadata_size = metadata.len();
if num_bytes <= metadata_size {
    Ok(metadata_size)
} else {
    let end = fd.seek(SeekFrom::End(0))?;
```

**Why it helps.** In `split` the size taken from the stat decides the chunk
arithmetic, and the file it then seeks on is opened separately. If the path is
replaced in between, split sizes its output for one file and reads another.
Deriving both from one descriptor makes that impossible. The saved path walk is
incidental.

**The trap.** The helper must not be clever about errors. On Linux `File::open`
on a directory succeeds and fails later at `read()`; on Windows it fails
immediately; a unix socket fails with ENXIO. Error mapping is per-utility, so
the helper returns the raw `io::Error` and the caller decides. Document 01 hit
this: `cat` needed an `open_error` fallback to keep printing "Is a directory"
for an unreadable directory, and that fallback belongs in `cat`. Note
`comm.rs:296` guards its directory check behind
`#[cfg(any(target_os = "wasi", windows))]` — adopt there carefully or not at all.

## 5. Consolidate same-file detection, mostly by deleting code

Ten utilities, seven mutually incompatible methods, and five near-identical
**private** canonicalize-and-compare functions at `cp.rs:2065`,
`copydir.rs:639`, `ln.rs:380`, `install.rs:987`, `install.rs:776`. `cp`, `mv`,
`ln`, `install` and `pwd` each hold more than one internally.

`install` contains both a right and a wrong version, twenty lines apart:

```rust
// install.rs:959 — copy_file_safe, correct, but hand-rolls the comparison
if let Ok(to_stat) = to_parent_fd.stat_at(to_filename, SymlinkBehavior::Follow) {
    #[allow(clippy::unnecessary_cast)]
    if from_meta.dev() == to_stat.st_dev as u64 && from_meta.ino() == to_stat.st_ino as u64 {
        return Err(InstallError::SameFile(...).into());
    }
}

// install.rs:987 — copy_file, uses canonicalize instead
if let Ok(to_abs) = to.canonicalize()
    && from.canonicalize()? == to_abs
{
    return Err(InstallError::SameFile(from.to_path_buf(), to.to_path_buf()).into());
}
```

Both collapse onto the helper that already exists:

```rust
use uucore::fs::FileInformation;

if let (Ok(a), Ok(b)) = (FileInformation::from_path(from, true),
                         FileInformation::from_path(to, true))
    && a == b
{
    return Err(InstallError::SameFile(from.to_path_buf(), to.to_path_buf()).into());
}
```

**Why it helps — but verify first.** Reading the code, `copy_file`'s canonicalize
version looks like it has a false negative that the dev/ino version does not:
canonicalize resolves symlinks, not hard links, so `install a b` where `b` is a
hard link to `a` should compare unequal, skip the SameFile error, and let
install truncate its own source. **This is inferred from reading, not measured.**
The first task in this step is to write that test. If it reproduces, this is a
data-loss fix, gets split out, and ships first. If it does not, this step is a
deduplication and must be described as one.

Also in scope: `split`'s `paths_refer_to_same_file` has **different semantics on
unix and wasi under one name** — `split/platform/unix.rs:214` is dev/ino and
stdin-aware, `split/platform/wasi.rs:13` is canonicalize and is not. A latent
correctness bug, independent of everything above.

**Leave the OR-chains alone for now.** `mv.rs:532-535` ORs three methods because
dev/ino cannot distinguish "the same directory entry" from "two hard links to
one inode" — a real distinction `cp.rs:2064` documents. A discriminated answer
instead of a bool would let those collapse, but that is a new API needing its
own justification and must not ride along inside a deletion PR.

## 6. The two memoizations

```rust
// src/uucore/src/lib/features/mode.rs:358 — before
pub fn get_umask() -> u32 {
    let mask = umask(Mode::empty());   // process umask is 0 from here...
    let _ = umask(mask);               // ...to here, once per file
    mask.bits() as u32
}

// after
pub fn get_umask() -> u32 {
    // Read once: no utility here changes its umask after startup, and each
    // read leaves the process umask at 0 for a moment.
    static UMASK: OnceLock<u32> = OnceLock::new();
    *UMASK.get_or_init(|| { ... })
}
```

**Why it helps.** Not the syscalls. `cp` is multi-threaded when copying with a
progress bar, and every call opens a window in which the process umask is 0, so
a file another thread creates in that window gets the wrong permissions.
`chmod -R g+w` on 1953 entries opens that window 1953 times.

The second is `uucore::entries::uid2usr`/`gid2grp` (`entries.rs:313,318`), which
have no cache. `ls` has a private one (`ls.rs:1015-1024`); `stat` and `chown -v`
pay per file — an `/etc/passwd` open per file locally, a network round trip
under LDAP or SSSD. A memo table behind the existing `PW_LOCK`, caching negative
results too, then `ls` drops its private caches.

## 7. What must not be unified

**The repeated-stat pattern (18 utilities).** The largest by site count — `cp`
~12 clusters, `mv` ~9, `install` ~8, `chmod` 4 — and the one that most looks
like it wants a helper. It does not. The clusters ask different questions:
`cp.rs:1476` asks "is either side a symlink, does dest exist"; `shred.rs:630`
asks "directory / not-a-directory / missing / permission"; `install.rs:577` asks
"is this a legal install target". A helper spanning them takes a bitmask of
questions and returns a struct of answers — worse than the duplication.
`mv.rs:389-402` and `mv.rs:856-859` carry comments showing someone already fixed
these in `mv` by holding the `Metadata` locally, with no shared helper. That is
the model.

**A shared lazy metadata type in uucore.** `ls::PathData` (`ls.rs:810-1005`) is
the only lazy/cached metadata type in the tree and the obvious thing to promote.
It should stay where it is. Its `metadata()` getter locks and flushes stdout
mid-listing and calls `show!(LsError::IOErrorContext(..))`, setting the process
exit code and picking message wording from an ls-specific "is this a
command-line argument" flag. It carries an EBADF fallback that exists only for
GNU compatibility on `/proc/self/fd/N`. Its constructor takes `&Config`. The one
trait it implements is `Colorable`, from the external `lscolors` crate — keeping
it would make uucore depend on an ls-specific crate. Strip all that and what is
left is `OnceCell<Option<Metadata>>`, not worth a shared type.

The four apparent reinventions are reinventions of *different* things:
`PathData` is lazy plus error-reporting, `du::Stat` is eager plus derived
values, `cp::copydir::Context` memoises one boolean, `mv::HardlinkTracker` is a
dedup index. Only their identity representation is genuinely shared — section 3.

**Canonicalize-in-a-loop.** Seven utilities, not one problem. Three are bugs to
fix directly — `shred.rs:810` is a probe-then-rename race where `exists()` is
the wrong tool and `rename` should just be attempted. Two are the same
`--parents` ancestor loop copy-pasted between `cp.rs:1616` and `copydir.rs:601`,
to be deduplicated inside `cp`, not in uucore.

**Type-only checks.** Four sites: `rm.rs:669`, `ls.rs:1547-1550`,
`chmod.rs:587-597`, `copydir.rs:474-481`. Each is a three-line local fix — pass
the `DirEntry` down. A helper for four sites is machinery for nothing.

## 8. Upstreaming notes

`CONTRIBUTING.md:123-126` requires an issue and an agreed approach before the
PR. `CONTRIBUTING.md:237-244` requires that moving code be its own commit,
separate from adopting it. `CONTRIBUTING.md:282-285` asks for small,
self-contained, stackable PRs.

The binding practical constraint is CI: `.github/workflows/benchmarks.yml:51-55`
means **any** diff touching `src/uucore/` runs CodSpeed benchmarks for all 37
benched utilities in two modes — 74 jobs, 90-minute timeout, already hitting
rate limits. So: few uucore PRs, each doing one thing.

| Order | PR | uucore change | Adopters in the same PR |
|---|---|---|---|
| 1 | share the `metadata(path, follow)` leaf | `fs.rs`, `perms.rs` re-export | all 11 copies (mechanical) |
| 2 | one identity type, bridge the Metadata types | `fs.rs`, `safe_traversal.rs` | `du` (closes the TOCTOU hole), `mv` |
| 3 | `open_and_stat` | `fs.rs` | `split`, `wc`, `tail`, `install` |
| 4 | same-file consolidation | none — deletions in utilities | `install`, `cp`, `ln`, `split` |
| 5 | uid/gid memo + `get_umask` `OnceLock` | `entries.rs`, `mode.rs` | `ls` drops its private caches |

Steps 3 and 4 continue as follow-up PRs, one utility each, so a regression
bisects to one tool. Step 2 waits for the statx-mask work in document 04, which
already removes part of du's coupling. If the step-4 hard-link test reproduces,
that fix goes first and alone — a data-loss bug does not wait behind a refactor.

## 9. Effectiveness test — did it actually work?

```bash
# Step 4, first and most important: is this a bug or a cleanup?
cd /tmp && rm -rf t && mkdir t && cd t
printf 'source data\n' > a && ln a b        # b is a hard link to a
./target/release/install a b; echo "rc=$?"; cat a
# GNU install refuses this. If uutils truncates a, step 4 is a data-loss fix.

# Step 2: the TOCTOU claim, not just the syscall count
strace -f -e trace=statx,newfstatat ./target/release/du -s --time /some/tree \
  | grep -c 'AT_FDCWD'        # path-based stats during traversal; want 0

# Step 3: one path walk per input, not two
strace -c -f ./target/release/split -n 2 /some/file 2>&1 | grep -E 'statx|openat'

# Step 5: the umask window
strace -c -f ./target/release/chmod -R g+w /tmp/t 2>&1 | grep umask   # want 2
```

| Gate | Threshold | Meaning |
|---|---|---|
| `install a b` with `b` a hard link to `a` | Refuses, as GNU does; `a` intact | Step 4 is a correctness fix, not a cleanup |
| Path-based stats in `du --time` traversal | Zero | The fd's own stat is being used; the TOCTOU window is closed |
| `statx` per input file in `split` | One, not two | `open_and_stat` wired correctly |
| `umask` calls per `chmod -R` run | 2, not 2×entries | The zero-umask window is opened once |
| GNU test suite, every adopting utility | Identical pass set | No semantic drift |
| Lines removed vs added | Net negative | The refactor is a consolidation, not a growth |

**The honest failure mode:** shipping step 1 and calling the series a success.
Step 1 removes eleven copies of a three-line function and fixes nothing — it is
worth doing, but the value in this document is concentrated in steps 2 and 4,
and step 4's value is unproven until that first test is run. If the hard-link
test does not reproduce, say so and downgrade step 4 to a deduplication rather
than quietly leaving the bug-fix framing in the PR description.

A second failure mode is over-reach: taking "unify" as licence to build the
shared lazy metadata type that section 7 argues against. That would trade eleven
small duplications for one abstraction nobody can read, on a codebase whose own
guidance is that readability beats a saved syscall.
