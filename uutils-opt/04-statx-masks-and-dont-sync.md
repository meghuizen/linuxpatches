# Fix 4 — Trim the irreducible stats: statx field masks + `AT_STATX_DONT_SYNC` in uucore

**Target repository:** `uutils/coreutils`, new helper in `src/uucore/src/lib/features/` (fs area), consumers `ls`, `du`, `stat`
**What this fix does, in one sentence:** for the stats that Fixes 1-3 cannot eliminate (`ls -l`, `du` genuinely need inode data), stop requesting *every* attribute with *full freshness* — ask only for the fields the tool prints, and on network filesystems accept cached attributes — using two statx features that have existed for years and that `std::fs::metadata` cannot express.

| | |
|---|---|
| Pattern to fix | `fs::metadata()` everywhere — which on Linux issues `statx(..., STATX_ALL-equivalent)` with sync-as-stat freshness |
| Replacement | Direct `rustix::fs::statx` with a per-tool field mask and an optional `AT_STATX_DONT_SYNC` |
| New dependency | **None** — `rustix` with the `fs` feature is already in `src/uucore/Cargo.toml:40` |
| Effort | One uucore helper + converting three consumers; a week |
| Risk | Low for masks; `DONT_SYNC` carries a staleness contract that must be a deliberate choice |

---

## 1. Background: two statx features std can't reach

`struct statx` was designed with a **request mask**: the caller says which fields it wants (`STATX_MODE | STATX_SIZE | ...`), and the filesystem may skip work for everything else. Some fields are disproportionately expensive on some filesystems (block counts, birth time, remote attributes). `std::fs::metadata` asks for everything, always — it has no API surface for the mask.

Separately, statx has **sync flags** (`include/uapi/linux/fcntl.h:145-148` in the kernel): `AT_STATX_DONT_SYNC` means "cached attributes are acceptable — do not revalidate with the server." NFS honors it directly (`fs/nfs/inode.c:973`: with the flag, it serves from the attribute cache and skips the wire round trip). Combined with the kernel's existing readdirplus behavior — NFS *detects* `ls -l`-shaped access and prefetches all entry attributes during readdir (`fs/nfs/dir.c:698`) — the flag turns `ls -l` on NFS from *1 readdir + N GETATTR round trips* into *1 round trip + N cache hits*.

Neither feature needs new kernel work, new ABI, or new crates: `rustix::fs::statx` exposes both, and rustix is already a uucore dependency.

## 2. The fix shape

**The helper** (uucore, feature-gated `#[cfg(target_os = "linux")]` with a `fs::metadata` fallback for other platforms):

- Input: path (or dirfd+name — prefer `statx(dirfd, name)` during directory walks to skip re-walking the parent path), a field mask, a freshness choice.
- Output: a lightweight metadata type exposing the requested fields. It cannot be `std::fs::Metadata` (not constructible from outside std) — uucore already wraps metadata concerns in `fsext.rs`, which is where the type belongs.

**Per-tool masks** (what each actually prints):

| Tool | Mask | Notably excluded |
|---|---|---|
| `ls -l` | `STATX_MODE\|STATX_NLINK\|STATX_UID\|STATX_GID\|STATX_SIZE\|STATX_MTIME` | blocks (unless `-s`), btime, atime/ctime (unless `-u`/`-c`) |
| `du` | `STATX_BLOCKS\|STATX_SIZE\|STATX_INO\|STATX_NLINK\|STATX_MODE` | ownership, all timestamps (unless `--time`) |
| `stat` | everything the format string references — parse first, mask second | whatever the user didn't ask to print |

**Freshness policy:** `DONT_SYNC` is a behavior change on network filesystems — output may reflect attributes as of the cache, not this instant. GNU has no exact equivalent, so this must be deliberate: default it on only where staleness is harmless and GNU-undetectable in practice (`ls`, `du` on unchanged trees), and keep an escape hatch. The defensible sequencing: land masks first (pure win, zero semantic change), propose `DONT_SYNC` separately with the NFS numbers attached.

## 3. Upstreaming notes

uucore changes ripple into every utility, so the project reviews them harder than per-tool fixes — keep the helper minimal and let consumers adopt one PR at a time (`du` first: simplest mask, biggest stat volume, least output-sensitivity). The cross-platform story must be airtight: non-Linux paths compile to today's `fs::metadata` behavior with zero divergence. GNU test suite green on all consumers is the merge gate as usual; for `DONT_SYNC` specifically, note in the PR that GNU's own output on NFS is equally cache-dependent (the kernel serves both from the same attribute cache when the heuristic fires) — the flag widens an existing window, it does not create one.

## 4. Effectiveness test — did it actually work?

```bash
# Masks, local fs - fields the fs skips:
strace -e statx ./target/release/du -s /usr 2>&1 | head -3   # inspect the mask argument
# The real gate is NFS. On an NFS mount with a cold client cache:
nfsstat -c > /tmp/before
./target/release/ls -l /mnt/nfs/bigdir > /dev/null
nfsstat -c > /tmp/after   # compare GETATTR counts
```

| Gate | Threshold | Meaning |
|---|---|---|
| statx mask in the trace | Exactly the per-tool mask, not `STATX_ALL` | Masks wired correctly |
| Local warm-cache wall time | Neutral (masks are not a local-fs win — say so) | No regression |
| NFS `GETATTR` ops for `ls -l` on N entries, `DONT_SYNC` on | Near zero after the readdir (vs ~N before) | The round-trip elimination — the entire payoff |
| Attribute staleness check: modify a file server-side, `ls -l` with `DONT_SYNC` within the cache window | May show old size — **expected**; document, don't hide | The contract is understood |
| GNU suite, masks-only build | Identical pass set | Masks changed nothing observable |

**The honest failure mode:** measuring on local ext4 and concluding the fix is worthless. Masks and `DONT_SYNC` are *network-filesystem* levers; the local-fs delta is noise by design. The NFS `nfsstat` gate is the only number that belongs in the PR headline.
