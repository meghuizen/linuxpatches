# The open path, as compiled

Static anatomy of `openat(2)` in Linux 7.3.0-rc3+824 (`518e5b794c06`), read out
of the objects in `/usr/src/kbench/builds/baseline`, gcc 15.2.0 at `-O2`.
Nothing here is a measurement of time. Everything here is a property of the
binary and can be re-derived with `tools/static-graph.py`.

## 1. What the compiler did to the source

The first thing the objects say is that the source-level call graph of
`fs/namei.c` does not exist in the binary. These functions have no symbol in
`namei.o`:

    do_open()               inlined into path_openat
    open_last_lookups()     inlined into path_openat
    walk_component()        inlined into path_openat and link_path_walk
    handle_mounts()         inlined
    step_into()             partially inlined; the slow half survives as
                            step_into_slowpath

`path_openat` is **592 instructions, 2507 bytes, one 96-byte frame**. It is
the open path. Reasoning about `do_open()` as a separate function — which is
how both Guzik's and Viro's patches are written, and how our own
`patches-dopen/0001` is written — is reasoning about source that the compiler
folded into a single block with shared registers and shared spill slots.

This matters concretely for a reference-transfer patch: "clear `nd->path.dentry`
so `terminate_walk()` does not drop it" is, after inlining, a store to a stack
slot that the very next basic block reloads. Whether that store survives, and
whether gcc can prove the reload redundant, is visible in the disassembly and
nowhere else.

`link_path_walk` stays out of line: 401 instructions, 64-byte frame.

## 2. Volume

Reachable from `do_sys_openat2`, following direct calls only, stopping at the
allocator, printk, RCU and raw spinlocks:

| | |
|---|---:|
| functions reachable | 345 (215 with bodies here, 130 external) |
| instructions under it | 18 795 |
| bytes of text | 62 747 |
| lock-prefixed instructions | 50 |
| indirect dispatches (retpoline thunks) | 40 |
| `pause` instructions (cmpxchg retry loops) | 28 |
| largest single stack frame | 312 bytes (`do_file_open`) |

**That 345 is an upper bound, not the hot path.** Reachability follows edges
that a successful `open("/tmp/f", O_RDONLY)` never takes. `propagate_umount`
(468 insns) and `umount_tree` (232) are in the set because `mntput` can, in
principle, drop the last reference to a lazily-unmounted tree. `fsnotify`
(1011 insns — the largest body in the whole set) is in it because
`vfs_open` calls it, but on a warm open with no watches it exits early.
`notify_change` and `do_truncate` are there for `O_TRUNC`.

Separating the two is the next step and it needs execution counts, not the
graph: ftrace `function_profile` hit counts from inside the guest. kbench's
README establishes that the hit counts are reliable there and the nanosecond
column is not.

## 3. Where the atomics are

Lock-prefixed instructions are the operations that cost a cache line, and on
a file several CPUs open at once they are the entire cost. Emitted inline:

    path_openat        lock cmpxchg %edx,0x150(%rbp)     inode->i_writecount
                       lock decl    0x150(%rbp)          inode->i_writecount
    do_dentry_open     lock addl    $0x0,-0x4(%rsp)      smp_mb()
                       lock incl    0x154(%r12)          inode->i_readcount
                       lock xadd    %eax,0x154(%rdx)     inode->i_readcount
                       lock decl    0x150(%rax)          inode->i_writecount
                       lock cmpxchg %ecx,0x150(%rdx)     inode->i_writecount
                       lock decl    0x150(%rax)          inode->i_writecount

`0x150` is 336 and `0x154` is 340; `pahole` on this build puts
`inode->i_writecount` at 336 and `inode->i_readcount` at 340. Of those eight,
a plain `O_RDONLY` open executes the `smp_mb()` and one `lock incl` on
`i_readcount`; the rest are the write, deny-write and `O_TRUNC` paths.

The ones that matter most are **not** inline, because they are out-of-line
calls:

| call | atomic | on |
|---|---|---|
| `lockref_get` (via `path_get` → `dget`) | `lock cmpxchg` + retry loop | `dentry->d_lockref` |
| `lockref_get_not_dead` (via `__legitimize_path`) | `lock cmpxchg` + retry loop | `dentry->d_lockref` |
| `lockref_put_return` (via `dput`) | `lock cmpxchg` + retry loop | `dentry->d_lockref` |
| `mntget` / `mntput` | per-cpu for longterm mounts | `mount->mnt_pcp` |
| `file_ref_get/put` (via `fput`) | `lock xadd %rsi,0xa8(%rbx)` | `file->f_ref` |
| `iget`/`iput` | `lock` inc/dec | `inode->i_count` |

`path_get` itself is 12 instructions and does nothing but call `mntget` then
tail-call `lockref_get`, with a NULL check between — both are real calls, and
`mnt_want_write` contains **no** lock-prefixed instruction at all (it is the
per-cpu write counter).

So the open/close cycle on one shared file, counted in atomic RMWs on **shared**
lines:

    __legitimize_path   lockref_get_not_dead   d_lockref    (dentry line)
    do_dentry_open      lockref_get            d_lockref    (dentry line)
    terminate_walk      lockref_put_return     d_lockref    (dentry line)
    __fput              lockref_put_return     d_lockref    (dentry line)
    do_dentry_open      lock incl i_readcount  inode+340    (inode line 5)
    __fput              lock xadd i_readcount  inode+340    (inode line 5)

Four on the dentry's line, two on the inode's. `file->f_ref` is on a freshly
allocated `file` and is private to the opener, so it does not contend.

This is the same count our `patches-dopen/0001` was written against, and it is
still four, on the current baseline.

## 4. Where the cache lines are

`pahole` on this build, `RANDSTRUCT_NONE`:

    struct file           176 bytes, 3 lines
    struct dentry         192 bytes, 3 lines
    struct inode          560 bytes, 9 lines
    struct address_space  152 bytes
    struct nameidata      240 bytes   (on the stack of path_openat's caller)
    struct kstat          192 bytes
    struct path            16 bytes
    struct vfsmount        32 bytes

### `struct dentry` is already well separated

    line 0   d_flags(0) d_seq(4) d_hash(8) d_parent(24) d_name(32) d_inode(48)
    line 1   d_shortname(56..95) d_op(96) d_sb(104) d_time(112) d_fsdata(120)
    line 2   d_lockref(128) d_lru(136) d_sib(152) d_children(168) d_alias(176)

Everything RCU-walk reads — `d_flags`, `d_seq`, `d_hash`, `d_parent`,
`d_name`, `d_inode` — is on line 0. The refcount is on line 2 with the LRU and
sibling links. The four atomic RMWs per open/close land on line 2 and do not
invalidate the line the lookup reads. There is no false sharing to fix here;
the cost is the four RMWs themselves, which is why removing one get and one
put is the only lever.

### `struct inode` has read-hot and write-hot fields on the same line

Line 5 of `struct inode` (offsets 320-383) on this build:

    320  atomic64_t i_sequence          write
    328  atomic_t   i_count             write   (iget/iput)
    332  atomic_t   i_dio_count         write
    336  atomic_t   i_writecount        write   (open, deny_write_access)
    340  atomic_t   i_readcount         write   (open, fput)
    344  const struct file_operations *i_fop      READ   (every open)
    352  struct file_lock_context     *i_flctx    READ   (every open)
    360  struct address_space i_data ...          -- and it starts here
     └─  368  spinlock_t i_pages.xa_lock          write  (every page-cache op)
     └─  376  void *     i_pages.xa_head          READ   (every page-cache op)

`i_fop` is read by `do_dentry_open()` on every single open, four bytes after
`i_readcount`, which `do_dentry_open()` then writes with a `lock incl`.

`i_flctx` is loaded on every open too — `break_lease()` calls
`locks_inode_context(inode)` unconditionally (`include/linux/filelock.h:486`).
Be precise about what that costs: the *pointer* at 352 is loaded every time
and so the line is touched every time, but the `file_lock_context` it points
at is only dereferenced when the file has a lease context, which on a file
nobody has locked it does not. The cacheline claim holds; a claim that
`__break_lease` runs on every open would not.

The bigger one is at the end. `i_data` is an inlined `struct address_space`
starting at 360, and its first member after `host` is the page-cache xarray:
`i_pages.xa_lock` lands at **368** and `xa_head` at **376**. So inode line 5
carries five different subsystems — inode lifetime, write-access accounting,
file operations dispatch, lock contexts, and the page cache's own lock — on
one 64-byte line. Two CPUs opening the same file ping the line that a third
reading it needs for `xa_head`.

This is the situation `linux-kernel/03-inode-false-sharing.md` describes, and
it is still present, unchanged, in the current baseline — `i_fop` is at 344
today. The existing patch
`kbench/patches/0003-fs-move-i_fop-and-i_flctx-off-the-refcount-cacheline` is
aimed at part of this — `i_fop` and `i_flctx` only, not `i_pages`. What it
has never had is evidence: its own stated gate
is HITM reduction under `perf c2c`, and WSL2 exposes no AMD IBS, so neither
host nor guest can produce HITM data. The layout claim is verifiable by
`pahole`; the benefit is not verifiable on this machine.

## 5. Indirect dispatch

Forty indirect dispatches are reachable under `do_sys_openat2`. With
`MITIGATION_RETPOLINE=y` every one is a call to `__x86_indirect_thunk_<reg>`,
not an `call *%reg`. On the open path they are:

    d_op->d_revalidate          lookup_fast, link_path_walk
    i_op->lookup                lookup_open
    i_op->atomic_open           lookup_open
    i_op->permission            inode_permission
    i_op->get_link              pick_link
    f_op->open                  do_dentry_open  (via the `open` argument)
    dentry_operations->d_delete dput

These are the boundary of what static analysis can see: past them the code is
the filesystem's, which is why `20-filesystems-and-vfs.md` exists as a separate
document. They are also the reason a "batch the open" idea is harder than it
looks — each of these can sleep, can return a different dentry, and can drop
out of RCU-walk.

## 6. What this says about the candidate patches

**The reference round trip is real and is four RMWs on one line.** Confirmed on
the current baseline, in the emitted code, not inferred from the source.

**Our `patches-dopen/0001` transfers only the dentry.** Guzik's v5 transfers
the mount too (`path->mnt = NULL`) and takes one dedicated `mntget` solely for
the `do_truncate` case. `mntget`/`mntput` on a longterm mount are per-cpu, so
that saves two per-cpu RMWs, not two shared-line RMWs — a smaller win than the
dentry half, on an uncontended line. It is still strictly less work and his
shape is better than ours: he moves `path_get()` out of `do_dentry_open()` into
its two callers rather than adding a `bool consume_dentry` parameter, which
removes a branch from a 304-instruction function on the hot path.

**Viro's series additionally removes the `dput`/`dget` round trip in
`atomic_open()`** and changes `finish_open()` to take only the dentry. That
reaches the 11 filesystems implementing `->atomic_open` and the 24 calling
`finish_open()`, all of them network or stacking filesystems. The static graph
cannot see past those indirect dispatches, so that change cannot be validated
from the binary — it has to be validated against `20-filesystems-and-vfs.md`
and the rules in `10-validation-rules.md`.

**`i_fop` on the refcount line is a second, independent finding** and it is
not what any of the three patches address.

## Reproducing

    cd /usr/src/linux/build
    /usr/src/linuxpatches/linux-kernel/vfs/tools/static-graph.py \
        fs/namei.o fs/open.o fs/stat.o fs/dcache.o fs/file.o fs/file_table.o \
        fs/inode.o fs/namespace.o ... -o graphs/static-graph.json
    tools/path-report.py graphs/static-graph.json do_sys_openat2 --depth 3
    pahole -C inode /usr/src/kbench/builds/baseline/vmlinux
