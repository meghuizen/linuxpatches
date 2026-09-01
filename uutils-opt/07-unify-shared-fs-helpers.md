# Fix 7 — Shared filesystem helpers in uucore

**Target repository:** `uutils/coreutils`, `src/uucore` plus adopting utilities
**Summary:** Documents 01-04 each fix one utility. Several of those fixes are the same work done in different places. This document says which of them should be shared code in `uucore`, which should stay duplicated, and what happened when the work was done.

| | |
|---|---|
| Pattern to fix | The same filesystem question answered separately in many utilities |
| Replacement | Two shared helpers, one timestamp bridge, two memoizations |
| Effort | Five PRs, staged |
| Risk | Low per step. `src/uucore` gets reviewed harder than per-tool fixes |
| Line refs | Against `meghuizen/coreutils` at 3251833, 2026-09-01. Re-grep before patching |

**Status: implemented.** Each section below records what was proposed and what
the implementation found. Several proposals turned out to be wrong. Those are
marked, with the reason, because the reasons are the useful part of this
document.

---

## 1. Background

A census of all 109 utilities found these repeated shapes.

| Shape | Utilities | Decision |
|---|---|---|
| Same path stat'ed repeatedly in one operation | 18 | Leave duplicated |
| Type-only question answered by a fresh stat | 4 | Leave duplicated |
| `metadata()` then `open()` on the same file | 13 (later corrected to 11) | Build a helper |
| `canonicalize`/`exists` in a per-entry loop | 7 | Leave duplicated |
| Same-file detection | 10 | Partly consolidate |
| Follow-symlink decision | 12 | Share the leaf only |

`uucore::fs` already contains `FileInformation`, `paths_refer_to_same_file` and
`are_hardlinks_to_same_file`. Some of the duplication exists because five
utilities wrote private versions instead of using them.

Two of the six steps below fix a defect: section 3 and section 6. The other
four remove duplication and change no behaviour. Each PR says which it is in
its first sentence.

---

## 2. Share the `metadata(path, follow)` leaf

### The duplication

`uucore::perms::get_metadata` (`perms.rs:279`) and ls's private
`get_metadata_with_deref_opt` (`ls.rs:1559`) are the same function, character
for character:

```rust
if follow { path.metadata() } else { path.symlink_metadata() }
```

Seven more inline copies of that body exist at `test.rs:405`, `test.rs:443`,
`touch.rs:479-482`, `touch.rs:723-732`, `cp.rs:2698-2700`, `du.rs:150-157` and
`stat.rs:1377`.

### The change

Move the function to `uucore::fs`, which 43 crates already depend on.
`perms` is unix-only and used by 8, so it is the narrower home. Keep
`perms::get_metadata` as a re-export so `chown`, `chgrp` and `chmod` do not
change.

```rust
// src/uucore/src/lib/features/fs.rs
/// Metadata for `path`, following a final symlink only when `follow` is true.
///
/// `follow: true` is `Path::metadata` (stat), which describes the file a
/// symlink points at. `follow: false` is `Path::symlink_metadata` (lstat),
/// which describes the symlink itself.
pub fn get_metadata(path: impl AsRef<Path>, follow: bool) -> IOResult<fs::Metadata> {
    let path = path.as_ref();
    if follow { path.metadata() } else { path.symlink_metadata() }
}

// src/uucore/src/lib/features/perms.rs
pub use crate::features::fs::get_metadata;
```

### Value

This removes duplication. It fixes no bug. The benefit is that the meaning of
`follow` is written down once instead of eight times. Eight separate copies is
eight chances to get the direction backwards.

### What the implementation found

Seven of the nine sites converted, plus a tenth the census missed in
`test/platform/wasi.rs`. Two sites are not this function:

- `du.rs:150-157` is a three-way choice. Between the follow and no-follow arms
  there is a Windows fast path that reads metadata from a `DirEntry`.
- `touch.rs:723-732` falls back to `symlink_metadata` when `metadata` fails
  with anything other than `NotFound`, so a link that is broken in some other
  way still yields times.

The `perms` feature now declares `fs` in `Cargo.toml`. That is a correction:
`perms.rs` already imported `FileInformation` from `fs`, so the dependency
existed and was undeclared.

### What was left alone

The dereference option enums. `du::Deref` needs `Args(Vec<PathBuf>)` for `-D`.
`ls::Dereference` needs `DirArgs`. `perms::TraverseSymlinks` keeps recursion
semantics separate from operand semantics. A single enum covering all of them
would have six variants where each utility uses three, and every `match` would
need arms that cannot happen. Each utility keeps its own enum and reduces it to
a `bool` at the call site, which `du.rs:141-147` and `cp.rs:1289` already do.

---

## 3. Take du's directory timestamp from the descriptor

### The defect

`du::Stat::new_from_dirfd` (`du.rs:178-211`) fstats a directory descriptor it
already holds. The size, block count and inode therefore describe that exact
directory. The timestamp did not: it came from a second, path-based stat.

```rust
let safe_metadata = dir_fd.metadata()?;                  // fstat on a held fd
let blocks = safe_metadata.blocks();

// Create a temporary std::fs::Metadata by reading the same path
// This is still needed for compatibility [...]
let std_metadata = fs::symlink_metadata(full_path)?;     // re-resolves the path
let latest_time = time.and_then(|time| metadata_get_time(&std_metadata, time));
```

Any component of `full_path` can be replaced between the two calls. `du` can
then report a size and inode from one directory and a timestamp from another.
This happens three lines after the safe-traversal code that exists to prevent
it.

`safe_traversal::Metadata` already exposes `modified()`, `accessed()` and
`changed()` (`safe_traversal.rs:779-787`), so the data was already available.
Birth time is not in `struct stat`, so that one field still needs a path
lookup.

### The change

```rust
// src/uucore/src/lib/features/safe_traversal.rs
impl Metadata {
    /// The timestamp `field` names, read out of this stat.
    /// `Birth` is always `None`: struct stat has no birth time.
    pub fn time(&self, field: MetadataTimeField) -> Option<SystemTime> { ... }
}

// src/uu/du/src/du.rs
let latest_time = match time {
    Some(MetadataTimeField::Birth) => /* path lookup, following symlinks */,
    Some(field) => safe_metadata.time(field),
    None => None,
};
```

### Evidence

The affected branch is reached when the path stat of the operand fails but
opening it succeeds, which is when something is changing the tree underneath
`du`. A symlink was flipped between a dangling target and a real directory
dated 2020-01-01, with `du -D -s --time link` running in a loop:

| build | successful runs | wrong timestamp |
|---|---|---|
| before | 3371 | 9 |
| after | 6614 | 0 |

The wrong value was the symlink's own mtime printed next to a size taken from
the directory it pointed at.

The implementation also found a second defect. The path stat passed
`Follow::No` while the descriptor had been opened following symlinks, so for a
symlink operand it read the link's timestamp rather than the directory's.

### The proposal that was dropped

This section originally also asked for the four file-identity types to be
collapsed into `fs::FileInformation`: `safe_traversal::FileInfo`, du's private
`FileInfo { file_id: u128, dev_id: u64 }` and mv's `(u64, u64)` tuple keys.
That does not work.

- `FileInformation` wraps a `rustix::fs::Stat`. On Linux that is rustix's own
  struct, not `libc::stat`. `safe_traversal` works in nix's `libc::stat`.
  Bridging them means copying every field between two struct definitions, or
  building a half-filled struct whose `file_size()` and `number_of_links()`
  then return wrong values.
- `du` identifies files on Windows by the 128-bit `FILE_ID_INFO` because ReFS
  requires it. `FileInformation` carries the 64-bit
  `BY_HANDLE_FILE_INFORMATION` index. Adopting it there loses information.
- `du` stores one identity per file visited in `seen_inodes`. Its own type is
  24 bytes. A `FileInformation` is a whole `struct stat`.
- mv's tuple could become a `FileInformation`, but its pre-scan also needs
  `is_file()` and `nlink()` from the same look, which `FileInformation` does
  not provide. Adopting it costs a second stat per file or new uucore API.

`safe_traversal::FileInfo` was kept. The fix needed the timestamp bridge only.

### Follow-ups

The operand's own `Stat` is still built from a path even in safe-traversal
mode. Opening the descriptor first would close the same window for the operand.
Birth time could come from the descriptor on Linux via
`statx(fd, "", AT_EMPTY_PATH)`. Both are larger changes than the fix above.

---

## 4. Open the file, then stat the descriptor

### The duplication

Several utilities call `fs::metadata(path)` on a file they then open. That is
two path walks, and the metadata can describe a different file than the one
that gets read.

```rust
// src/uucore/src/lib/features/fs.rs
/// Open `path` and describe the file that was actually opened.
///
/// The metadata comes from the descriptor, so it cannot describe a different
/// file than the one that will be read. Only for callers that were going to
/// open the file anyway: opening has side effects a stat does not, such as a
/// FIFO blocking until a writer appears.
///
/// The io::Error is returned unchanged. What File::open reports differs per
/// platform and per file type, so turning it into a message is the caller's
/// job.
pub fn open_and_stat(path: &Path) -> IOResult<(fs::File, fs::Metadata)> {
    let file = fs::File::open(path)?;
    let metadata = file.metadata()?;
    Ok((file, metadata))
}
```

### Value

In `split`, the size taken from the stat decides the chunk arithmetic, and the
file it seeks on is opened separately. If the path is replaced between the two,
split sizes its output for one file and reads another. Taking both from one
descriptor removes that.

The syscall count is not an argument for this change. In split's common branch
a `statx` becomes an `openat`, because that branch never opened the file
before. Only the rare seek branch loses a call.

### The trap

The helper must not interpret the error. On Linux `File::open` on a directory
succeeds and fails later at `read()`. On Windows it fails immediately. A unix
socket fails with ENXIO. Error mapping belongs in each utility. In the `cat`
work (document 01), `cat` needed a fallback that stats the path when the open
fails, so an unreadable directory still prints "Is a directory". That fallback
lives in `cat`.

### What the implementation found

Adopted in `split` and `install`. Corrections to the census:

- `wc` has two sites, not four. `wc.rs:697` and `wc.rs:776` are plain
  `File::open` with no paired stat.
- `sort` has no site. Both its opens are unpaired.
- `sum.rs:80` is a site the census missed, with the same cfg-gated shape as
  `comm.rs:296`.

`wc.rs:285` looks like a straightforward case and is not. `try_as_files0` opens
the file and drops the handle on the non-regular-file path, so converting it
makes `wc --files0-from=FIFO` open the FIFO twice and block on the second open.
This was implemented, confirmed under strace, and reverted. It needs the
descriptor threaded into `Inputs::Files0From` first.

Sites left for other reasons: `wc.rs:741` stats in a phase that runs before
anything is opened; `comm.rs:296` and `sum.rs:80` are cfg-gated to wasi and
windows, where `File::open` on a directory fails so the check must come first;
`tail.rs:230`, `truncate.rs:244` and `shred.rs:667` open for writing or with
custom flags; `pr.rs:762` stats in a different function from the one that
opens; `install.rs:890` and `install.rs:1114` stat one path and open another.

---

## 5. Consolidate same-file detection

### What was claimed

Ten utilities detect "same file" seven different ways, with five near-identical
private canonicalize-and-compare functions at `cp.rs:2065`, `copydir.rs:639`,
`ln.rs:380`, `install.rs:987` and `install.rs:776`.

### What is actually there

Two of the five.

| Site | What it is |
|---|---|
| `cp.rs` `paths_are_same_entry` | `MissingHandling::Normal`, returns false when a path cannot be resolved. One half of an AND with a hardlink check. |
| `copydir.rs` `path_has_prefix` | Not a same-file check. A `starts_with` test used by the recursion guard. |
| `ln.rs` `is_same_entry` | `MissingHandling::Missing`, returns **true** when a path cannot be resolved. The opposite default to cp's. |
| `install.rs:776` | A duplicate. Converted. |
| `install.rs:987` | A duplicate. Converted. |

`cp` and `ln` disagree about what an unresolvable path means, and each is one
half of an AND with a hardlink check. Sharing one helper between them would
change behaviour for at least one.

### Two claims that were wrong

**The suspected data-loss bug is not there.** The idea was that `copy_file`'s
canonicalize check misses hard links, so `install a b` where `b` is a hard link
to `a` would let install truncate its own source. Tested on 2026-09-01:

```
printf 'IMPORTANT SOURCE DATA\n' > a && ln a b   # same inode
install a b   # GNU:    rc=0, a intact
install a b   # uutils: rc=0, a intact
```

Both survive. `copy_file` calls `fs::remove_file(to)` before creating the
destination, which unlinks the name `b` while `a` still holds the inode. GNU
accepts this case as well, so there is no parity gap.

**The "right version and wrong version" framing was backwards.** `copy_file`'s
canonicalize check runs before that `fs::remove_file(to)`. Converting it to a
dev/ino comparison would newly reject the hard-link case that both
implementations accept today. `copy_file_safe`'s dev/ino check is safe because
its caller unlinks first. They are two checks at different points in one flow.
Each is correct where it sits. The shipped change keeps the canonicalize form.

### Result

`install`'s three checks become one. `cp`'s reflink cleanup check uses
`FileInformation` instead of a hand-rolled dev/ino comparison. Nothing else
moved. Verified byte-identical over 276 cells: twelve scenarios against 23
command forms across `cp`, `ln` and `install`.

That sweep also found 31 pre-existing differences against GNU 9.4, two of them
in the direction where uutils accepts what GNU refuses. Those are filed
separately.

---

## 6. Read the umask once, remember uid and gid names

### The umask window

`uucore::mode::get_umask` (`mode.rs:358`) has to set the umask to 0 to read it,
then set it back. `cp` calls it once per file, and `chmod` once per file for a
symbolic mode.

```rust
// before
let mask = umask(Mode::empty());   // process umask is 0 from here
let _ = umask(mask);               // to here, once per file

// after
static UMASK: OnceLock<u32> = OnceLock::new();
*UMASK.get_or_init(|| { ... })
```

The syscall count is secondary. Each call leaves the process umask at 0 for a
moment, so a file another thread creates in that moment gets the wrong
permissions. `cp` is multi-threaded when it shows a progress bar. On a
1953-entry tree that window opens 1953 times.

The doc comment records that this is only correct because no utility here
changes its own umask after startup, and that a caller which does must not use
the helper.

### The name lookups

`uucore::entries::uid2usr` and `gid2grp` (`entries.rs:313,318`) have no cache.
`stat` calls both per file for `%U` and `%G`. `uucore::perms` calls them per
entry for `chown -v` and `chgrp -v`. With nsswitch on files that is an
open/read/close of `/etc/passwd` and `/etc/group` per file. Under LDAP or SSSD
it is a network round trip per file.

Misses are cached as well, so a tree owned by a deleted uid does not repeat the
failed lookup.

### Measurements

`strace -c -f`, release build, 1960-entry tree.

| command | before | after |
|---|---|---|
| `chmod -R g+w tree` | 3922 umask, 12308 syscalls | 2 umask, 8388 |
| `stat` on 1600 files | 3223 openat / 3211 read / 3257 close, 33894 | 25 / 13 / 29, 14616 |
| `chown -Rv root:root tree` | 3972 openat, 30103 | 52 openat, 6469 |
| `chgrp -Rv 0 tree` | 2011 openat, 18275 | 51 openat, 6458 |

### Two implementation notes

The plan said to put the tables behind the existing `PW_LOCK`. That would
deadlock: `PW_LOCK` is taken inside `Passwd::locate`, which the cache calls
while holding its own table. The tables have their own mutexes, always taken
before `PW_LOCK` and never while holding it. The lock order is written in a
comment.

`ls` keeps its private `uid_cache`/`gid_cache`. Removing them was tried and
backed out. The shared table returns a `String`, so `ls` would clone one per
entry where it previously borrowed from its own map, costing about 10% on
`ls -l` over 3000 files with 700 distinct owners. `ls` gains nothing from the
shared table, and it is a benched utility. Returning `Arc<str>` would fix that,
but `uid2usr` and `gid2grp` have 59 call sites across eight crates, and 55 are
`unwrap_or_else(|_| id.to_string())` whose fallback allocates a `String`
anyway. That is separate work.

---

## 7. What was deliberately left duplicated

### Repeated stats of one path (18 utilities)

The largest group by site count: `cp` about 12 clusters, `mv` about 9,
`install` about 8, `chmod` 4. The clusters ask different questions.
`cp.rs:1476` asks whether either side is a symlink and whether the destination
exists. `shred.rs:630` asks whether the path is a directory, a non-directory,
missing, or permission-denied. `install.rs:577` asks whether the path is a
legal install target. A helper covering all of them would take a bitmask of
questions and return a struct of answers.

The fix for each site is local: hold the `Metadata` the function already
fetched. `mv.rs:389-402` and `mv.rs:856-859` carry comments showing this was
already done there by hand, with no shared helper.

### A shared lazy metadata type

`ls::PathData` (`ls.rs:810-1005`) is the only lazy metadata type in the tree
and the obvious candidate to move into uucore. It should stay in `ls`.

- Its `metadata()` getter locks and flushes stdout mid-listing, then calls
  `show!(LsError::IOErrorContext(..))`, which sets the process exit code and
  picks message wording from an ls-specific flag.
- It has an EBADF fallback that exists only for GNU compatibility on
  `/proc/self/fd/N`.
- Its constructor takes `&Config`.
- The one trait it implements is `Colorable`, from the external `lscolors`
  crate. Keeping it would make uucore depend on an ls-specific crate.

Remove all of that and what remains is `OnceCell<Option<Metadata>>`.

The four types that look like reinventions of each other are not.
`ls::PathData` is lazy and reports errors. `du::Stat` is eager and holds
derived values. `cp::copydir::Context` memoises one boolean.
`mv::HardlinkTracker` is a deduplication index. They share only their identity
representation, which is section 3.

### canonicalize or exists inside a loop (7 utilities)

Three are bugs to fix directly, not to abstract. `shred.rs:810` probes with
`exists()` and then calls `rename`, which silently replaces the destination.
Two are the same `--parents` ancestor loop copy-pasted between `cp.rs:1616` and
`copydir.rs:601`, which should be deduplicated inside `cp`.

### Type-only checks (4 sites)

`rm.rs:669`, `ls.rs:1547-1550`, `chmod.rs:587-597`, `copydir.rs:474-481`. Each
is a three-line local fix: pass the `DirEntry` down.

---

## 8. Upstreaming notes

`CONTRIBUTING.md:123-126` requires an issue and an agreed approach before the
PR. `CONTRIBUTING.md:237-244` requires that moving code be its own commit,
separate from adopting it. `CONTRIBUTING.md:282-285` asks for small,
self-contained, stackable PRs.

The practical constraint is CI. `.github/workflows/benchmarks.yml:51-55` means
any diff touching `src/uucore/` runs CodSpeed benchmarks for all 37 benched
utilities in two modes: 74 jobs, 90-minute timeout, already hitting rate
limits. Keep the number of uucore-touching PRs low.

| Order | PR | uucore change | Adopters |
|---|---|---|---|
| 1 | share `get_metadata` | `fs.rs`, `perms.rs` re-export | ls, cp, stat, touch, test |
| 2 | du timestamp from the descriptor | `safe_traversal.rs` | du |
| 3 | `open_and_stat` | `fs.rs` | split, install |
| 4 | same-file consolidation | none | install, cp |
| 5 | umask and uid/gid caches | `entries.rs`, `mode.rs` | none |

Step 2 stacks on the statx-mask work from document 04, which reworked du's
metadata handling first.

---

## 9. Effectiveness test

```bash
# Section 3: no path-based stats during traversal
strace -f -e trace=statx,newfstatat ./target/release/du -s --time /some/tree \
  | grep -c 'AT_FDCWD'

# Section 4: one path walk per input
strace -c -f ./target/release/split -n 2 /some/file 2>&1 | grep -E 'statx|openat'

# Section 6: the umask window
strace -c -f ./target/release/chmod -R g+w /tmp/t 2>&1 | grep umask

# Section 5: regression test, not an open question. Already run; see section 5.
printf 'source data\n' > a && ln a b
./target/release/install a b; echo "rc=$?"; cat a   # rc=0, a intact, as GNU
```

| Gate | Threshold | Meaning |
|---|---|---|
| Path-based stats in `du --time` traversal | 0 | The descriptor's own stat is used |
| `statx` per input in `split` | 1 | `open_and_stat` wired correctly |
| `umask` calls per `chmod -R` run | 2 | The window opens once per process |
| `install a b`, `b` a hard link to `a` | rc=0, `a` intact | Matches GNU; unchanged |
| GNU test suite, every adopting utility | Same pass set | No behaviour drift |
| Lines removed vs added | Net negative | The work is consolidation |

### Failure modes to watch for

The first is describing a cleanup as a fix. Sections 2, 4 and 5 remove
duplication and change no behaviour. Sections 3 and 6 fix a defect. Each PR
should state which it is in its first sentence rather than inheriting the tone
of the series.

The second is building the shared lazy metadata type that section 7 argues
against. That would replace many small duplications with one abstraction that
is harder to read, in a codebase whose guidance puts readability ahead of a
saved syscall.

The third is trusting this document over the code. Nine of its original claims
were wrong, and every one was found by someone reading the source instead of
the plan. Re-check line numbers and re-read the surrounding function before
changing anything here.
