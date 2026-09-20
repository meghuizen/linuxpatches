# ABI and word size

What "backwards compatible on both 32-bit and 64-bit" means, concretely, for the
VFS in Linux 7.3.0-rc3+824 (`518e5b794c06`). Read out of `/usr/src/linux`.

Every claim below is either **read from source** with a `file:line` citation, or
**measured** by compiling the UAPI structure definitions verbatim with
`gcc -m64` / `gcc -m32` and reading the object's symbol sizes, or explicitly
marked *not established from source*. Nothing here is inferred from memory of
how the kernel used to work.

The purpose is narrow: a proposal that reorders a VFS structure, or refactors a
path, gets checked against this document before anyone claims it preserves the
ABI. Section 6 is the checklist that does the checking.

---

## 0. The three surfaces, and which one a change is allowed to touch

There are exactly three distinct things called "layout" in this area and
conflating them is the single most common error:

| surface | may change? | enforced by |
|---|---|---|
| **UAPI structs** copied to/from userspace (`struct stat`, `statx`, `flock`, `linux_dirent*`, `statfs*`, `file_handle`) | **never** — not one byte of offset, size or padding | nothing automatic; review only |
| **internal structs** (`struct inode`, `dentry`, `file`, `path`, `super_block`, `address_space`) | freely, subject to §5's word-size arithmetic | nothing; the compiler already permutes most of them under `RANDSTRUCT` |
| **the syscall entry surface** (which numbers exist, what compat variant they route to) | additively only | `syscall_*.tbl`, `unistd.h` |

The cache-layout patches in this repository operate entirely in row 2. That is
why they are allowed to exist at all. §4 establishes what row 2 actually costs.

---

## 1. The syscall surface

### 1.1 Three tables, three conventions

x86 carries the full historical load and is therefore the worst case:

- `arch/x86/entry/syscalls/syscall_32.tbl` — 480 lines, the i386 ABI. Column 4
  is the native entry point, column 5 the compat entry used when a 32-bit
  process runs on a 64-bit kernel (`syscall_32.tbl:5-11` documents the format
  and states that `__ia32_sys`/`__ia32_compat_sys` stubs are generated when
  `IA32_EMULATION` is set).
- `arch/x86/entry/syscalls/syscall_64.tbl` — 444 lines. Rows tagged `common`
  are the 64-bit ABI; rows 512-547 tagged `x32` (`syscall_64.tbl:407-442`) are
  the x32 ABI, which is ILP32 with 64-bit registers and therefore needs compat
  handlers for anything containing a pointer or a `long`.
- `include/uapi/asm-generic/unistd.h` — 919 lines, the table every architecture
  added since ~2009 uses. Current end: `__NR_syscalls 473`
  (`unistd.h:870-871`).

`unistd.h` does the 32/64 split with three macros
(`unistd.h:19-30`):

    #if __BITS_PER_LONG == 32 || defined(__SYSCALL_COMPAT)
    #define __SC_3264(_nr, _32, _64) __SYSCALL(_nr, _32)
    #else
    #define __SC_3264(_nr, _32, _64) __SYSCALL(_nr, _64)
    #endif
    #define __SC_COMP(_nr, _sys, _comp)           /* compat build -> _comp */
    #define __SC_COMP_3264(_nr, _32, _64, _comp)  /* both axes */

`__SC_3264` is the *width* axis (does this arch need the `_64` twin?);
`__SC_COMP` is the *ABI* axis (is this a 32-bit process on a 64-bit kernel?).
They are orthogonal and a syscall can need either, both or neither.

The tail of `unistd.h` (`:883-919`) then aliases the two spellings onto one
number, so that `__NR_fstat` on a 64-bit arch and `__NR_fstat64` on a 32-bit
arch are the same slot:

    #if __BITS_PER_LONG == 64 && !defined(__SYSCALL_COMPAT)
    #define __NR_fcntl  __NR3264_fcntl      ...
    #else
    #define __NR_fcntl64 __NR3264_fcntl     ...
    #endif

**Consequence for a new syscall:** on `unistd.h` architectures you cannot add a
syscall that takes an `off_t`, a `time_t`, a `long`, or a bare `u64` argument
pair without deciding which of these three macros it goes through. Adding it
via plain `__SYSCALL` commits you forever to the 64-bit-clean shape.

### 1.2 The legacy twins

Every one of these exists because the original took a 32-bit quantity. Verified
from the tables:

| concept | 32-bit legacy | 64-bit-clean form | citation |
|---|---|---|---|
| seek | `lseek` (`off_t`) | `_llseek` (`u32` hi/lo + `loff_t*` out) | `syscall_32.tbl:34`, `:155`; `fs/read_write.c:412`, `:426` |
| stat | `stat`/`lstat`/`fstat` → `sys_newstat` etc. | `stat64`/`lstat64`/`fstat64`/`fstatat64` | `syscall_32.tbl:121-123`, `:210-212`, `:315` |
| stat, older still | `sys_stat` on `__old_kernel_stat` (16-bit dev/ino) | — | `fs/stat.c:383-418` (prints a `KERN_WARNING` per use, 5 times) |
| fcntl | `fcntl` | `fcntl64` | `syscall_32.tbl:70`, `:236`; `fs/fcntl.c:607` |
| statfs | `statfs`/`fstatfs` | `statfs64`/`fstatfs64` | `syscall_32.tbl:114-115`, `:283-284` |
| truncate | `truncate`/`ftruncate` | `truncate64`/`ftruncate64` | `syscall_32.tbl:107-108`, `:208-209` |
| readdir | `old_readdir` (one entry), then `getdents` | `getdents64` | `syscall_32.tbl:104`, `:156`, `:235` |
| sendfile | `sendfile` | `sendfile64` | `syscall_32.tbl:202`, `:254` |
| mmap | `old_mmap` | `mmap2` (page units) | `syscall_32.tbl:105`, `:207` |
| fadvise | `fadvise64` | `fadvise64_64` | `syscall_32.tbl:265`, `:287` |
| utime | `utime`/`utimes`/`futimesat`/`utimensat` (`_time32`) | `utimensat_time64` | `syscall_32.tbl:45`, `:286`, `:314`, `:335`, `:421` |

Three of these are *not* symmetric and are worth knowing:

1. **`getdents` vs `getdents64` is a genuine wire-format difference, not just a
   width.** `struct linux_dirent` (`fs/readdir.c:242`) is
   `unsigned long d_ino; unsigned long d_off; unsigned short d_reclen; char d_name[]`
   — measured `offsetof(d_name)` = **18** on x86-64 and **10** on i386, and
   `filldir()` aligns the record to `sizeof(long)` (`fs/readdir.c:263`). So the
   record stride differs by word size, which is exactly why
   `compat_sys_getdents` and `struct compat_linux_dirent` (`fs/readdir.c:483`,
   measured 12 bytes, `d_name` at 10) exist. `struct linux_dirent64`
   (`include/linux/dirent.h`) has `offsetof(d_name)` = **19 on both**, and
   `filldir64()` aligns to `sizeof(u64)` = 8 on both (`fs/readdir.c:347`).
   `getdents64` therefore needs **no compat variant at all** and there is none
   in any table. That is the model for anything new.
2. **`fcntl` on 32-bit is the `fcntl64` entry point.** `syscall_32.tbl:70`
   routes i386 `fcntl` (nr 55) to `compat_sys_fcntl64`, the same handler as nr
   331. And `F_OFD_GETLK`/`F_OFD_SETLK`/`F_OFD_SETLKW` are **compiled out of
   `sys_fcntl` when `BITS_PER_LONG == 32`** (`fs/fcntl.c:479-494`, comment:
   `/* 32-bit arches must use fcntl64() */`). OFD locks are a 64-bit-only
   interface on the 32-bit `fcntl` entry.
3. **`pread64`/`pwrite64`/`truncate64`/`fallocate`/`sync_file_range` do not
   take a `loff_t`.** They take a split register pair. Generically this is
   `compat_arg_u64(name)` (`include/asm-generic/compat.h:17-27`), which expands
   to `u32 name_lo, u32 name_hi` on little-endian and the reverse on big-endian,
   reassembled by `compat_arg_u64_glue()`. x86 additionally has its own
   hand-written set in `arch/x86/kernel/sys_ia32.c:54-123`
   (`sys_ia32_truncate64`, `sys_ia32_pread64`, `sys_ia32_fallocate`,
   `sys_ia32_sync_file_range`, …). **This is endian-sensitive code and it is
   duplicated per arch.** Any new syscall taking a 64-bit offset inherits the
   whole problem; taking a pointer to a struct instead does not.

### 1.3 The 64-bit-clean-only set

These appear in `syscall_32.tbl` with **no compat column** and have no legacy
twin anywhere. They are the shape a new VFS interface must take:

`statx` (`:398`), `openat2` (`:445`), `getdents64` (`:235`), `sendfile64`
(`:254`), `renameat2` (`:368`), `copy_file_range` (`:392`), `faccessat2`
(`:447`), `fchmodat2` (`:460`), `name_to_handle_at` (`:356`), `open_tree`
(`:436`), `move_mount` (`:437`), `fsopen` (`:438`), `fsconfig` (`:439`),
`fsmount` (`:440`), `fspick` (`:441`), `mount_setattr` (`:450`), `cachestat`
(`:459`), `statmount` (`:465`), `listmount` (`:466`), `setxattrat` /
`getxattrat` / `listxattrat` / `removexattrat` (`:471-474`), `open_tree_attr`
(`:475`), `file_getattr` / `file_setattr` (`:476-477`), `listns` (`:478`),
`fchroot` (`:480`), `utimensat_time64` (`:421`).

What they have in common, without exception: **every 64-bit quantity is passed
inside a struct as an explicit `__u64` or `__s64`, never as a register-width
argument, and never as a `long`.** `statx` passes `struct statx *`; `openat2`
passes `struct open_how *` plus its `size`; `statmount` passes
`struct mnt_id_req *` plus its `size`. There is exactly one exception in the
list — `open_by_handle_at`, which *does* carry a compat entry
(`syscall_32.tbl:357` → `compat_sys_open_by_handle_at`,
`fs/fhandle.c:469`) — because its `struct file_handle` is followed by a
variable-length blob and the wrapper exists to handle the userspace pointer,
not a width.

**`statx` has no compat variant on any table.** Verified: `grep` for `statx` in
`syscall_32.tbl` yields only line 398 with four columns, and
`fs/stat.c` contains no `COMPAT_SYSCALL_DEFINE(statx)`. This is the single most
important fact in this document for anyone designing a replacement stat path.

### 1.4 `COMPAT_SYSCALL_DEFINE` under `fs/` — complete enumeration

53 sites. Grouped by what forces the wrapper to exist:

**Width of a scalar argument (`off_t`, `size_t`, `long`):**

    fs/open.c:158        truncate            compat_off_t
    fs/open.c:215        ftruncate           compat_off_t
    fs/open.c:235        truncate64          compat_arg_u64
    fs/open.c:243        ftruncate64         compat_arg_u64
    fs/open.c:371        fallocate           compat_arg_u64_dual x2
    fs/read_write.c:418  lseek               compat_off_t
    fs/read_write.c:776  pread64             compat_arg_u64
    fs/read_write.c:806  pwrite64            compat_arg_u64
    fs/sync.c:366        sync_file_range     compat_arg_u64_dual x2
    fs/statfs.c:390      ustat               struct compat_ustat

**Layout of a struct copied out:**

    fs/stat.c:853        newstat             struct compat_stat
    fs/stat.c:865        newlstat            struct compat_stat
    fs/stat.c:878        newfstatat          struct compat_stat  (#ifndef __ARCH_WANT_STAT64)
    fs/stat.c:892        newfstat            struct compat_stat
    fs/statfs.c:304      statfs              struct compat_statfs
    fs/statfs.c:313      fstatfs             struct compat_statfs
    fs/statfs.c:361      statfs64            struct compat_statfs64
    fs/statfs.c:380      fstatfs64           struct compat_statfs64
    fs/readdir.c:462     old_readdir         struct compat_old_linux_dirent
    fs/readdir.c:544     getdents            struct compat_linux_dirent
    fs/fcntl.c:806       fcntl64             struct compat_flock / compat_flock64
    fs/fcntl.c:812       fcntl               same, via do_compat_fcntl64()

**Array of pointers or `iovec`:**

    fs/read_write.c:1222 preadv64            fs/read_write.c:1230 preadv
    fs/read_write.c:1240 preadv64v2          fs/read_write.c:1250 preadv2
    fs/read_write.c:1263 pwritev64           fs/read_write.c:1271 pwritev
    fs/read_write.c:1281 pwritev64v2         fs/read_write.c:1291 pwritev2
    fs/read_write.c:1436 sendfile            fs/read_write.c:1456 sendfile64
    fs/exec.c:2046       execve              fs/exec.c:2055       execveat
    fs/select.c:1279     select              fs/select.c:1294     old_select
    fs/aio.c:1466        io_setup            fs/aio.c:2177        io_submit

**`time_t` in a struct:**

    fs/select.c:1357     pselect6_time64     fs/select.c:1372     pselect6_time32
    fs/select.c:1388     ppoll_time32        fs/select.c:1414     ppoll_time64
    fs/aio.c:2431        io_pgetevents       fs/aio.c:2466        io_pgetevents_time64
    fs/eventpoll.c:2962  epoll_pwait         fs/eventpoll.c:2975  epoll_pwait2
    fs/signalfd.c:337    signalfd4           fs/signalfd.c:345    signalfd

**Generic pointer / ioctl dispatch:**

    fs/ioctl.c:638       ioctl               fs/fhandle.c:469     open_by_handle_at

Plus, outside `fs/` but on the same ABI, `arch/x86/kernel/sys_ia32.c`:
`ia32_stat64` (`:165`), `ia32_lstat64` (`:176`), `ia32_fstat64` (`:186`),
`ia32_fstatat64` (`:196`), `ia32_mmap` (`:224`).

**A detail worth recording:** the i386 `struct stat64` ABI has *two* kernel
implementations. `fs/stat.c:616` `cp_new_stat64()` is used by a native i386
kernel and zeroes the padding via `INIT_STRUCT_STAT64_PADDING`
(`arch/x86/include/uapi/asm/stat.h:76-79`, memsets `__pad0` and `__pad3`).
`arch/x86/kernel/sys_ia32.c:132` `cp_stat64()` is used by a 64-bit kernel under
`IA32_EMULATION`, writes each field with `unsafe_put_user()`, and **never
writes `__pad0` or `__pad3` at all**. Both are correct as ABI (the buffer is the
caller's), but they are not the same code and a change to one is not a change to
the other.

---

## 2. Type widths and the overflow traps

### 2.1 The types

All from `include/linux/types.h` and `include/uapi/asm-generic/posix_types.h`,
measured widths confirmed by compiling with `-m32`/`-m64`.

| type | definition | 32-bit | 64-bit | citation |
|---|---|---:|---:|---|
| `loff_t` | `__kernel_loff_t` = `long long` | 8 | 8 | `types.h:51`, `posix_types.h:88` |
| `off_t` | `__kernel_off_t` = `__kernel_long_t` | **4** | 8 | `types.h:25`, `posix_types.h:87` |
| `ino_t` | `__kernel_ulong_t` | **4** | 8 | `types.h:21`, `posix_types.h:14-17` |
| `inode->i_ino` | `u64` | 8 | 8 | `include/linux/fs.h:782` |
| `blkcnt_t` | `u64` | 8 | 8 | `types.h:137` |
| `sector_t` | `u64` | 8 | 8 | `types.h:136` |
| `time64_t` | `__s64` | 8 | 8 | `include/linux/time64.h:8` |
| `dev_t` | `__kernel_dev_t` = `u32` | 4 | 4 | `types.h:17`, `:20` |
| `nlink_t` | `u32` | 4 | 4 | `types.h:24` |
| `umode_t` | `unsigned short` | 2 | 2 | `types.h:23` |
| `size_t` | `unsigned int` / `__kernel_ulong_t` | **4** | 8 | `posix_types.h:66-75` |
| `pgoff_t` | `unsigned long` | **4** | 8 | `types.h:146` |

Three of these deserve emphasis.

**`blkcnt_t` and `sector_t` are unconditionally `u64`.** `types.h:136-137` has
no `#ifdef`. The `CONFIG_LBDAF` switch that used to make them 32-bit on 32-bit
kernels is **gone from this tree**: `grep -rn "LBDAF\|CONFIG_LBD"` over every
`*.c`, `*.h`, `Kconfig*`, `*.rst` and `*.txt` returns **zero hits**. Any
proposal reasoning about "small sector_t on 32-bit" is reasoning about a kernel
that no longer exists.

**`inode->i_ino` is `u64`, not `unsigned long`** (`include/linux/fs.h:782`).
The VFS therefore does not truncate inode numbers on 32-bit anywhere internally.
Truncation happens only at the copy-out boundary (§2.3). *Not established from
source:* when this changed — the git history in this working tree is grafted and
`git log -L` on that line resolves only to the merge commit `08df884136f1`.

**`pgoff_t` is `unsigned long`** (`types.h:146`), which is what makes `MAX_LFS_FILESIZE`
word-size dependent (`include/linux/fs.h:1320-1324`):

    #if BITS_PER_LONG==32
    #define MAX_LFS_FILESIZE  ((loff_t)ULONG_MAX << PAGE_SHIFT)
    #elif BITS_PER_LONG==64
    #define MAX_LFS_FILESIZE  ((loff_t)LLONG_MAX)

With 4 KiB pages that is 16 TiB on 32-bit against 8 EiB on 64-bit. The page
cache index, not the ABI, is the binding constraint on 32-bit.

### 2.2 The EOVERFLOW machinery — every site

`MAX_NON_LFS` is `((1UL<<31) - 1)` (`include/linux/fs.h:1316`). It is the
threshold for "this file does not fit in a non-LFS `off_t`".

| function | checks | returns `-EOVERFLOW` when | line |
|---|---|---|---|
| `cp_old_stat` | `st_ino` (16-bit) | ino doesn't round-trip | `fs/stat.c:400-401` |
| | `st_nlink` (16-bit) | nlink doesn't round-trip | `:404-405` |
| | size, `#if BITS_PER_LONG == 32` | `size > MAX_NON_LFS` | `:409-411` |
| `cp_new_stat` | `st_dev`, `st_rdev` if `sizeof < 4` | `!old_valid_dev()` | `fs/stat.c:468-471` |
| | size, `#if BITS_PER_LONG == 32` | `size > MAX_NON_LFS` | `:472-475` |
| | `st_ino` | doesn't round-trip | `:481-482` |
| | `st_nlink` | doesn't round-trip | `:486-487` |
| `cp_new_stat64` | `st_ino` | doesn't round-trip | `fs/stat.c:629-631` |
| `cp_compat_stat` | `st_dev`, `st_rdev` | `!old_valid_dev()` | `fs/stat.c:822-825` |
| | `st_ino` | doesn't round-trip | `:830-831` |
| | `st_nlink` | doesn't round-trip | `:834-835` |
| | size, **unconditionally** | `(u64)size > MAX_NON_LFS` | `:839-840` |
| `do_statfs_native` | blocks/bfree/bavail/bsize/frsize | any high 32 bits set | `fs/statfs.c:134-137` |
| | files, ffree (unless `-1`) | high 32 bits set | `:142-147` |
| `put_compat_statfs` | blocks/bfree/bavail/bsize/frsize | high 32 bits set | `fs/statfs.c:270-272` |
| | files, ffree (unless all-ones) | high 32 bits set | `:275-280` |
| `put_compat_statfs64` | bsize, frsize | high 32 bits set | `fs/statfs.c:326-327` |
| `ksys_lseek` | result narrowed to `off_t` | `res != (loff_t)retval` | `fs/read_write.c:405-407` |
| `fillonedir` | `d_ino` | `sizeof(d_ino) < sizeof(ino)` and differs | `fs/readdir.c:196-200` |
| `filldir` | `d_ino` | same | `fs/readdir.c:276-280` |
| `compat_filldir` | `d_ino` | same | `fs/readdir.c:517-521` |
| `fixup_compat_flock` | `l_start` | `> COMPAT_OFF_T_MAX` | `fs/fcntl.c:734-739` |

The `fixup_compat_flock` comment (`fs/fcntl.c:726-733`) is the clearest
statement of the policy the whole area follows: overflow an *identity* → error;
overflow a *length* → clamp.

    /* l_start shouldn't be too big ... so we return -EOVERFLOW in that case.
     * l_len could be too big, in which case we just truncate it, and only
     * allow the app to see that part of the conflicting lock that might make
     * sense to it anyway */

### 2.3 What truncates **silently** — no check at all

These are not bugs (they are the defined ABI), but a patch that changes the
producers must not change them:

1. **Timestamps in `struct stat` / `compat_stat`.** `cp_new_stat` does
   `tmp.st_atime = stat->atime.tv_sec;` (`fs/stat.c:492`) into an
   `unsigned long`. On i386 that is 32 bits. `cp_compat_stat`
   (`fs/stat.c:842-847`) does the same into `u32`. **There is no
   `-EOVERFLOW` for time anywhere in `fs/stat.c`.** After 2038, a 32-bit
   `stat()` silently returns a wrapped `st_atime`, and a 64-bit kernel serving
   a 32-bit process does the same. The escape hatch is `statx`, whose
   `stx_atime.tv_sec` is `__s64` (`include/uapi/linux/stat.h:57`).
2. **`d_off` in `getdents`.** `filldir()` stores the directory offset with
   `unsafe_put_user(offset, &prev->d_off)` (`fs/readdir.c:288`) where `offset`
   is `loff_t` and `prev->d_off` is `unsigned long`. There is an overflow check
   for `d_ino` three lines earlier and **none for `d_off`**. Same in
   `compat_filldir` (`fs/readdir.c:528`). `filldir64` has no truncation because
   `linux_dirent64.d_off` is `s64`.
3. **`st_blksize`, `st_blocks` in `compat_stat`** — `u32` fields assigned from
   `u64`/`u32` sources with no check (`fs/stat.c:848-849`). `st_blocks` is the
   one that can realistically overflow, on a file over 2 TiB.

### 2.4 Inode numbers

The truncation points, in order along the path:

    inode->i_ino            u64      include/linux/fs.h:782
      -> stat->ino          u64      fs/stat.c:89   (generic_fillattr)
        -> stx_ino          __u64    fs/stat.c:715  no check   [lossless]
        -> stat64.st_ino    u64      fs/stat.c:629  checked    [lossless in practice]
        -> stat.st_ino      ulong    fs/stat.c:481  checked -> EOVERFLOW
        -> compat_stat.st_ino u32    fs/stat.c:830  checked -> EOVERFLOW
        -> linux_dirent.d_ino ulong  fs/readdir.c:277 checked -> EOVERFLOW

So the VFS is lossless end-to-end and the loss is at the last hop only, and it
is *reported* at every hop except `statx` (which cannot lose) — this is the one
place where the 32-bit story is actually clean.

The 32-bit inode number problem is therefore not a kernel-internal truncation;
it is that filesystems producing >32-bit inode numbers make 32-bit `stat()`
fail. The kernel's responses to that, all verified:

- `get_next_ino()` deliberately uses a `unsigned int` counter
  (`fs/inode.c:1128-1131`; the comment is at `:1124-1126`). Its comment is explicit: *"On a 32bit, non LFS
  stat() call, glibc will generate an EOVERFLOW error if st_ino won't fit in
  target struct field. Use 32bit counter here to attempt to avoid that."*
- tmpfs has `full_inums` (`mm/shmem.c:121`), the `inode32`/`inode64` mount
  options (`mm/shmem.c:4627`, `:4635`), and refuses a remount to `inode32`
  once `next_ino > UINT_MAX` (`mm/shmem.c:4788-4789`). `CONFIG_TMPFS_INODE64`
  `depends on TMPFS && 64BIT` and its help text (`fs/Kconfig:214-228`) names
  the failure mode directly.
- XFS has the same split: `Opt_inode32` (`fs/xfs/xfs_super.c:153`),
  `XFS_FEAT_SMALL_INUMS`, and the allocator constrains inode placement to the
  low AGs when it is set (`fs/xfs/xfs_super.c:291-359`).
- `is_zero_ino()` (`include/linux/fs.h:3027-3030`) tests `(u32)ino == 0`, with
  a comment noting this is because userspace built with `_FILE_OFFSET_BITS=32`
  on a 64-bit kernel only reads the low 32 bits.

### 2.5 time64 and y2038

What the VFS stores, verified at `include/linux/fs.h:796-801`:

    time64_t  i_atime_sec;  time64_t  i_mtime_sec;  time64_t  i_ctime_sec;
    u32       i_atime_nsec; u32       i_mtime_nsec; u32       i_ctime_nsec;

`time64_t` is `s64` on both word sizes. Accessors are `READ_ONCE`/`WRITE_ONCE`
wrappers (`include/linux/fs.h:1599-1631`) — note that on a 32-bit machine a
`READ_ONCE` of an `s64` is *not* a single access; see §5.1.

What the ABI can express:

| interface | seconds field | y2038-safe? |
|---|---|---|
| `struct stat` (i386) | `unsigned long st_atime` | **no** — `arch/x86/include/uapi/asm/stat.h:21` |
| `struct stat64` (i386) | `unsigned long st_atime` | **no** — `:63` |
| `struct compat_stat` | `u32 st_atime` | **no** — `arch/x86/include/asm/compat.h:47` |
| `struct stat` (x86-64) | `__kernel_ulong_t st_atime` (`:97`) | yes (64-bit) |
| `struct statx` | `__s64 stx_atime.tv_sec` | **yes on both** — `include/uapi/linux/stat.h:57` |
| `utimensat` | `struct __kernel_timespec` (`__kernel_time64_t`) | yes — `include/uapi/linux/time_types.h:7-10` |
| `utimensat_time32` | `struct old_timespec32` | no — `fs/utimes.c:246` |

The two timespec shapes:

    struct __kernel_timespec  { __kernel_time64_t tv_sec; long long tv_nsec; };  /* 16 bytes, both */
    struct __kernel_old_timespec { __kernel_old_time_t tv_sec; __kernel_long_t tv_nsec; };  /* 8 on 32-bit */

`__ARCH_WANT_TIME32_SYSCALLS` controls whether the 32-bit-time variants exist at
all (`arch/Kconfig:1502-1508`, `config COMPAT_32BIT_TIME`, `default !64BIT ||
COMPAT`). In `unistd.h` the guard
`#if defined(__ARCH_WANT_TIME32_SYSCALLS) || __BITS_PER_LONG != 32`
(`unistd.h:245-248`) suppresses `__NR_utimensat` entirely on a 32-bit arch that
did not ask for it, leaving only `__NR_utimensat_time64` at 412 (`:733-734`).
Verified: of all in-tree architectures only `arch/openrisc/include/asm/unistd.h:6`
defines `__ARCH_WANT_TIME32_SYSCALLS` in a header; riscv, arm64, csky, nios2 and
loongarch do not. **riscv32 therefore has no 32-bit-time VFS syscall at all.**

### 2.6 `CONFIG_64BIT` / `BITS_PER_LONG` conditionals in `fs/`

Complete list for core VFS files (filesystem-private ones under `fs/btrfs`,
`fs/f2fs`, `fs/proc`, `fs/afs` are excluded; they are covered by
`20-filesystems-and-vfs.md`):

    include/linux/fs.h:592        __NEED_I_SIZE_ORDERED / i_size_seqcount
    include/linux/fs.h:1125,1134  i_size_read()
    include/linux/fs.h:1154,1160  i_size_write()
    include/linux/fs.h:1320       MAX_LFS_FILESIZE
    include/linux/dcache.h:72     DNAME_INLINE_WORDS
    fs/fcntl.c:479,490            F_OFD_* excluded from sys_fcntl on 32-bit
    fs/fcntl.c:607                SYSCALL_DEFINE3(fcntl64) only on 32-bit
    fs/read_write.c:424           sys_llseek existence
    fs/fs-writeback.c:1506        inode_dirtied_after() jiffies wrap guard
    fs/namei.c:2316               64-bit hash mixing in the dcache word-at-a-time hash
    fs/select.c:812,1116          time32 pselect/ppoll
    fs/aio.c:2302,2362            aio ring / time32

Twelve sites in the whole core VFS, and five of them are one cluster in
`include/linux/fs.h` (the `i_size` accessors plus `MAX_LFS_FILESIZE`). The
surface is small enough to audit by hand on every patch.

---

## 3. Structure layout as ABI vs as internal detail

### 3.1 Internal — reorderable

Verified sizes from `pahole` on `/usr/src/kbench/builds/baseline/vmlinux`
(`RANDSTRUCT_NONE`, x86-64):

| struct | size | lines | where |
|---|---:|---:|---|
| `struct inode` | 560 | 9 | `include/linux/fs.h:762-871` |
| `struct dentry` | 192 | 3 | `include/linux/dcache.h:93-141` |
| `struct file` | 176 | 3 | `include/linux/fs.h:1255-1296` |
| `struct path` | 16 | 1 | `include/linux/path.h:8-11` |
| `struct qstr` | 16 | 1 | `include/linux/dcache.h:49-57` |
| `struct kstat` | 192 | 3 | `include/linux/stat.h:22-62` |
| `struct super_block` | — | — | `include/linux/fs/super_types.h:135-290` |

All of these are internal. None is copied to userspace. `struct kstat` in
particular is an internal staging buffer — `cp_statx()` copies field by field
into a `struct statx` (`fs/stat.c:700-742`), it is not a `memcpy`. So `kstat`
may be reordered and even resized freely.

**`struct super_block` has moved** in this tree, out of `include/linux/fs.h`
into the new `include/linux/fs/super_types.h`. A patch written against an older
tree will not apply.

### 3.2 UAPI — frozen

Measured by compiling each definition verbatim under `-m64` and `-m32`.
Sizes in bytes.

| struct | definition | x86-64 | i386 | notes |
|---|---|---:|---:|---|
| `struct stat` (i386 branch) | `arch/x86/include/uapi/asm/stat.h:10-29` | — | **64** | 14 × `unsigned long` + 4 × `unsigned short`; `__unused4`, `__unused5` are the only spare |
| `struct stat` (x86-64 branch) | `:83-104` | **144** | — | `__pad0` after `st_gid`, `__unused[3]` at the end |
| `struct stat64` (i386) | `:42-73` | — | **96** | `__pad0[4]`, `__pad3[4]`, plus the `__st_ino`/`st_ino` pair |
| `struct __old_kernel_stat` | `:117-136` | — | 32 | all `unsigned short` except size/times |
| `struct compat_stat` | `arch/x86/include/asm/compat.h:36-55` | **64** | 64 | fixed-width by construction; matches i386 `struct stat` |
| `struct statx` | `include/uapi/linux/stat.h:99-192` | **256** | **256** | word-size invariant |
| `struct statx_timestamp` | `:56-60` | 16 | 16 | `__s64` + `__u32` + `__s32 __reserved` |
| `struct linux_dirent` | `fs/readdir.c:242-247` | 24 | 12 | `d_name` at 18 / 10 — **the wire format differs** |
| `struct linux_dirent64` | `include/linux/dirent.h:5-11` | 24 | 20 | `d_name` at **19 on both**; record aligned to 8 on both |
| `struct compat_linux_dirent` | `fs/readdir.c:483-488` | 12 | 12 | matches i386 `linux_dirent` |
| `struct flock` | `include/uapi/asm-generic/fcntl.h:206-218` | 32 | 16 | `__kernel_off_t` |
| `struct flock64` | `:220-229` | 32 | **24** | `__kernel_loff_t`; `l_start` at 8 / **4** |
| `struct compat_flock` | `include/linux/compat.h:270-282` | 16 | 16 | |
| `struct compat_flock64` | `:284-293` | **24** | 24 | only because of `__ARCH_COMPAT_FLOCK64_PACK` |
| `struct statfs` | `include/uapi/asm-generic/statfs.h:23-36` | 120 | 64 | `__statfs_word` is `long` on 64-bit, `__u32` on 32-bit |
| `struct statfs64` | `:46-59` | 120 | 84 | |
| `struct compat_statfs` | `arch/x86/include/asm/compat.h:63-76` | 64 | 64 | x86-specific override |
| `struct compat_statfs64` | `include/uapi/asm-generic/statfs.h:69-82` | **84** | 84 | **only with the pack attribute** |
| `struct file_handle` | `include/linux/fs.h:1298-1303` | 8 | 8 | flexible array, `__counted_by(handle_bytes)` |

Four of these carry a lesson that generalises.

**`struct compat_statfs64` is the worked example of the whole document.**
Compiled without the arch override it measures **88 bytes on x86-64 and 84 on
i386** — the 64-bit ABI rounds the struct up to a multiple of 8 because it
contains `__u64` members, and the 32-bit one does not. `arch/x86/include/uapi/asm/statfs.h:5-10`
fixes it and says exactly why:

    /*
     * We need compat_statfs64 to be packed, because the i386 ABI won't
     * add padding at the end to bring it to a multiple of 8 bytes, but
     * the x86_64 ABI will.
     */
    #define ARCH_PACK_COMPAT_STATFS64 __attribute__((packed,aligned(4)))

With the attribute it is 84 on both, verified. ARM has the mirror-image problem
and packs `statfs64` itself (`arch/arm/include/uapi/asm/statfs.h:5-10`: *"With
EABI there is 4 bytes of padding added to this structure"*).

**`struct compat_flock64` is the same problem at a member offset rather than at
the end.** `arch/x86/include/asm/compat.h:57-60`:

    /*
     * IA32 uses 4 byte alignment for 64 bit quantities, so we need to pack the
     * compat flock64 structure.
     */
    #define __ARCH_NEED_COMPAT_FLOCK64_PACKED

Without it, `l_start` would land at offset 8 on x86-64 and 4 on i386. With the
`packed` (`include/linux/compat.h:264-268`) it is 4 on both.

**`struct flock` has no reserved fields.** `include/uapi/asm-generic/fcntl.h:206-218`
provides `__ARCH_FLOCK_EXTRA_SYSID` and `__ARCH_FLOCK_PAD` hooks for
architectures that already have padding, but the generic struct is exactly
`{short, short, off_t, off_t, pid_t}`. There is **no room to extend `flock`**.
Anything new in file locking has to be a new `F_*` command with a new struct, or
go through a size-versioned struct.

**`struct file_handle` is the one UAPI struct with a built-in growth path**, and
it is a length prefix rather than reserved space: `handle_bytes` is set by the
caller on the way in and by the kernel on the way out.

### 3.3 `struct statx` specifically

Layout at `include/uapi/linux/stat.h:99-192`, measured 256 bytes on both word
sizes. Offsets are annotated in the source at every 16-byte boundary and are
therefore part of the contract:

    0x00  stx_mask        u32   stx_blksize      u32   stx_attributes   u64
    0x10  stx_nlink u32  stx_uid u32  stx_gid u32  stx_mode u16  __spare0[1] u16
    0x20  stx_ino u64    stx_size u64   stx_blocks u64   stx_attributes_mask u64
    0x40  stx_atime  stx_btime  stx_ctime  stx_mtime   (4 x statx_timestamp, 16 each)
    0x80  stx_rdev_major/minor u32 x2    stx_dev_major/minor u32 x2
    0x90  stx_mnt_id u64   stx_dio_mem_align u32   stx_dio_offset_align u32
    0xa0  stx_subvol u64   stx_atomic_write_unit_min u32  ..._max u32
    0xb0  stx_atomic_write_segments_max u32  stx_dio_read_offset_align u32
          stx_atomic_write_unit_max_opt u32  __spare2[1] u32
    0xc0  __spare3[8] u64                                        /* 64 bytes */
    0x100 end

Reserved space remaining: `__spare0[1]` (2 bytes, `:122`), `__spare2[1]`
(4 bytes, `:187`), `__spare3[8]` (64 bytes, `:190`). **68 bytes and two
fragments.** That is the entire budget for every future extension of `statx`
without changing `sizeof(struct statx)`.

The compatible-extension protocol, all four parts verified:

1. **The struct never changes size.** A new field consumes `__spare*`.
   `cp_statx()` does `memset(&tmp, 0, sizeof(tmp))` first (`fs/stat.c:704`), so
   every unconsumed spare byte is zero on return, on every kernel.
2. **A new `STATX_` bit is added** at the next free position in
   `include/uapi/linux/stat.h:203-221`. Highest currently used:
   `STATX_DIO_READ_ALIGN 0x00020000U`. `STATX__RESERVED 0x80000000U` (`:223`)
   is refused on input: `do_statx()` returns `-EINVAL` if
   `mask & STATX__RESERVED` (`fs/stat.c:750-751`, and again in `do_statx_fd()`
   at `:774-775`).
3. **`result_mask` is the contract.** The header's own specification
   (`include/uapi/linux/stat.h:66-97`) is the normative text: a requested datum
   that is unsupported gets its bit **cleared** and its field set to a fabricated
   value or zero; a datum not requested but free may be filled in **and its bit
   set**. So `stx_mask` is not "what you asked for" and callers must test it.
   A caller on a new kernel asking for a bit an old kernel never heard of gets
   that bit back clear and the field zero — which is why adding a bit is safe.
4. **Kernel-only bits are stripped on the way out.** `STATX_CHANGE_COOKIE`
   (`include/linux/stat.h:67`, `0x40000000U`) and
   `STATX_ATTR_CHANGE_MONOTONIC` (`include/linux/stat.h:70`) live in the
   *internal* `include/linux/stat.h`, are masked out of the user-visible
   `stx_mask`/`stx_attributes` in `cp_statx()` (`fs/stat.c:706-710`), and are
   also cleared from the incoming request (`fs/stat.c:759`, `:783`).

`STATX_ALL` is deprecated and frozen at `0x00000fffU` with a `#ifndef __KERNEL__`
guard and a comment saying it *"shall remain the same value in the future"*
(`include/uapi/linux/stat.h:226-232`, the define itself at `:231`). Nothing may be added to it.

### 3.4 The modern alternative: size-versioned extensible structs

Since `openat2`, new interfaces do not freeze a struct — they pass its size and
let `copy_struct_from_user()` / `copy_struct_to_user()`
(`include/linux/uaccess.h:393`, `:490`) reconcile the two. The rule those
implement: a shorter userspace struct is zero-extended; a longer one is accepted
only if its trailing bytes are all zero, otherwise `-E2BIG`.

In-tree VFS users, each with a `BUILD_BUG_ON` pinning the published sizes:

| struct | sizes | assertion |
|---|---|---|
| `struct open_how` | 24 (`OPEN_HOW_SIZE_VER0`) | `fs/open.c:1448-1449` |
| `struct mount_attr` | 32 (`MOUNT_ATTR_SIZE_VER0`) | `fs/namespace.c:5125` |
| `struct mnt_id_req` | 24 → 32 (VER0 → VER1) | `fs/namespace.c:5904`; `include/uapi/linux/mount.h:212-213` |
| `struct xattr_args` | 16 (`XATTR_ARGS_SIZE_VER0`) | `fs/xattr.c:747-748`, `:886-887` |
| `struct file_attr` | 24 (`FILE_ATTR_SIZE_VER0`) | `fs/file_attr.c:384-385`, `:437-438` |

Measured: all five are the same size under `-m32` and `-m64`, because every
member is `__u32`/`__u64` and any `__u64` is either first or naturally aligned.

`struct statmount` (`include/uapi/linux/mount.h:157-191`) combines both techniques: a
leading `__u32 size`, a `__u64 mask` result mask in the `statx` style,
`__u64 supported_mask`, `__u64 __spare2[43]`, and a trailing `char str[]` into
which all variable-length data is packed by offset. It is the most extensible
shape in the VFS and the one to copy.

---

## 4. What a layout change actually affects

### 4.1 Hardcoded offsets — the full survey

A tree-wide search for `offsetof(struct {inode,dentry,file,path,super_block,
address_space,vfsmount,qstr,file_operations}, ...)` returns **four hits in the
entire kernel**:

    kernel/trace/trace_probe.c:2403   offsetof(struct dentry, d_name.name)
    kernel/trace/trace_probe.c:2409   offsetof(struct dentry, d_name.name)
    kernel/trace/trace_probe.c:2410   offsetof(struct file, f_path.dentry)
    fs/file_table.c:636               offsetof(struct file, f_freeptr)

The three in `trace_probe.c` are inside `traceprobe_expand_dentry_args()`
(`:2380-2415`), which *stringifies* the offsets into a probe expression like
`"%s%s+0x0(+0x%zx(+0x%zx(%s))):string"` and re-parses it. They are compile-time
correct and follow any reorder automatically. `fs/file_table.c:636` sets the
slab free-pointer offset for `filp_cachep`.

`__builtin_offsetof` and `offsetofend` on these structs: **zero hits tree-wide.**

**Assembly: clean.** All 21 `arch/*/kernel/asm-offsets.c` were checked for
`inode|dentry|d_name|f_path|f_inode|i_ino|super_block|vfsmount|mnt_|
address_space|qstr|file_operations` — zero matches; none of them include
`linux/fs.h`, `dcache.h`, `path.h` or `mount.h`. No in-tree `.S` file references
a VFS field.

**Rust: clean.** `rust/kernel/` uses `core::mem::offset_of!` in about fifteen
places (`usb.rs:345`, `platform.rs:331`, `i2c.rs:487`, `jump_label.rs:57`, …),
none of them on a VFS struct. `rust/kernel/miscdevice.rs` treats
`bindings::inode` and `bindings::file` as opaque pointers (`:215`, `:256`,
`:315`, `:340`) and uses `bindings::file_operations` only as a designated
initializer (`:402`).

**drgn / crash: clean.** The fifteen drgn scripts in `tools/` read none of these
structs. The only layout-aware VFS tooling in the tree is
`scripts/gdb/linux/vfs.py`, which resolves members by name through DWARF
(`:21` `d['d_parent']`, `:25` `d['d_name']['name']`, `:57` `container_of(d_u,
…, "d_u")`) and therefore tracks any reorder as long as the debuginfo matches
the running kernel.

### 4.2 BPF and BTF

BPF never hardcodes an offset; it resolves one, either at link time (CO-RE) or
at load time (verifier). Both paths follow a reorder automatically **provided
the BTF the program is relocated against is the BTF of the running kernel.**

- CO-RE intent is recorded by `__builtin_preserve_field_info()`
  (`tools/lib/bpf/bpf_core_read.h:44`), with
  `BPF_FIELD_BYTE_OFFSET = 0` (`:16`) and the user-facing
  `bpf_core_field_offset()` (`:212-213`), `bpf_core_field_exists()` (`:188`),
  `BPF_CORE_READ()` (`:525`).
- It is resolved in `tools/lib/bpf/relo_core.c`:
  `bpf_core_calc_field_relo()` (`:679`), `case BPF_CORE_FIELD_BYTE_OFFSET:
  *val = byte_off;` (`:774-775`), member-offset accumulation at `:350-351` and
  `:511-518`.
- Kernel-side, `bpf_core_apply()` (`kernel/bpf/btf.c:9731`) runs the same
  computation via `bpf_core_calc_relo_insn()` (`:9791`).
- Programs that access fields *directly* are checked, not relocated:
  `btf_struct_access()` (`kernel/bpf/btf.c:7394`) and `btf_struct_walk()`
  (`:7128`) validate the offset against BTF, with
  `moff = __btf_member_bit_offset(t, member) / 8;` at `:7179`, `:7204`, `:7210`.
- The sanctioned VFS surface for BPF is `fs/bpf_fs_kfuncs.c:422-427`
  (`bpf_path_d_path`, `bpf_get_dentry_xattr`, `bpf_get_file_xattr`,
  `bpf_set_dentry_xattr`, `bpf_real_data_inode`), plus
  `BTF_ID_LIST_SINGLE(bpf_d_path_btf_ids, struct, path)`
  (`kernel/trace/bpf_trace.c:990`) and the `bpf_d_path()` hook allowlist at
  `kernel/trace/bpf_trace.c:961-975`, which includes
  `security_inode_getattr`, `vfs_getattr` and `dentry_open`.
- In-tree BPF programs reading VFS fields all go through CO-RE, e.g.
  `tools/testing/selftests/bpf/progs/profiler.inc.h:488`
  (`BPF_CORE_READ(filp_dentry, d_name.name)`), `:512`
  (`d_inode, i_ino`), `:529` (`d_sb, s_dev`), `:683`
  (`bprm, file, f_inode, i_ino`). `samples/bpf/` has none.

**The practical risk is not a reorder; it is a rename or a removal.** A reorder
relocates cleanly. Deleting `struct inode.i_ino`, or moving a field into or out
of an anonymous union, does not — CO-RE resolves by name and type.

### 4.3 `CONFIG_RANDSTRUCT` — internal layout is already unstable

`__randomize_layout` expands to `__attribute__((randomize_layout))`
(`include/linux/compiler_types.h:469`) and is a no-op otherwise (`:475`).
Which VFS structs carry it, verified:

| carries `__randomize_layout` | does **not** |
|---|---|
| `struct inode` — `include/linux/fs.h:871` | **`struct dentry`** — `include/linux/dcache.h:141`, bare `};` |
| `struct file` — `fs.h:1295` | **`struct qstr`** — `dcache.h:57`, bare `};` |
| `struct address_space` — `fs.h:485` | |
| `struct file_operations` — `fs.h:1963` | |
| `struct renamedata` — `fs.h:1797` | |
| `struct super_block` — `include/linux/fs/super_types.h:290` | |
| `struct path` — `include/linux/path.h:11` | |
| `struct vfsmount` — `include/linux/mount.h:63` | |
| `struct fs_struct` — `include/linux/fs_struct.h:17` | |
| `struct file_lock`, `file_lease` — `include/linux/filelock.h:145`, `:154` | |

This is the strongest available argument that internal layout is not ABI:
under `RANDSTRUCT_FULL` the compiler already permutes `inode`, `file`,
`super_block`, `address_space` and `path` on its own
(`security/Kconfig.hardening:308-322`). `RANDSTRUCT_PERFORMANCE` (`:324-334`)
restricts the permutation to cacheline-sized groups — which is exactly the
granularity the cache-layout patches care about, and means **a layout tuned
under `RANDSTRUCT_NONE` is not the layout a `RANDSTRUCT_PERFORMANCE` kernel
runs.**

Two consequences that a patch author must not overlook:

1. **`RANDSTRUCT_FULL` and `RANDSTRUCT_PERFORMANCE` both `select MODVERSIONS`**
   (`security/Kconfig.hardening:311`, `:327`).
2. **BTF and the GCC randstruct plugin are mutually exclusive**:
   `config DEBUG_INFO_BTF ... depends on !GCC_PLUGIN_RANDSTRUCT || COMPILE_TEST`
   (`lib/Kconfig.debug:398-401`). So a randstruct kernel built with the plugin
   has no BTF, and every CO-RE consumer in §4.2 stops working on it.

**`struct dentry` is the exception and this matters.** It is the one hot VFS
structure whose layout the compiler is *not* permitted to permute, and it is
hand-laid-out for cachelines (`include/linux/dcache.h:66-69`: *"Try to keep
struct dentry aligned on 64 byte cachelines"*, and the explicit
`/* --- cacheline N boundary --- */` comments at `:106`, `:113`). A patch that
reorders `struct dentry` is therefore changing something no build configuration
currently changes, and cannot appeal to "randstruct already does this".

### 4.4 Module ABI

`CONFIG_MODVERSIONS` (`kernel/module/Kconfig:161-170`) computes *"A CRC value of
the full prototype for an exported symbol"* (`Documentation/kbuild/modules.rst:391-396`).
`genksyms` (`scripts/genksyms/`) expands the prototype through its argument
types, so the CRC of every `EXPORT_SYMBOL` taking `struct inode *` changes when
`struct inode`'s definition changes. Under `MODVERSIONS` that means out-of-tree
modules must be rebuilt; without it, they load and misbehave.

The sharper issue is the **static inlines in the headers**, which bake the
layout into the module's own text regardless of `MODVERSIONS`. In
`include/linux/fs.h` alone, all of these are `static inline` and dereference a
VFS struct member directly:

    i_size_read() / i_size_write()            :1123, :1152   inode->i_size
    iminor() / imajor()                       :1174, :1179   inode->i_rdev
    inode_get_atime_sec() … inode_set_atime() :1599-1631     inode->i_*_sec/_nsec
    __iget()                                  :3032          inode->i_count
    get_file()                                :1305          file->f_ref
    file_mnt_idmap()                          :2462          file->f_path.mnt

So a module compiled against a different `struct inode` or `struct file` layout
has wrong offsets compiled into it wherever it merely *called* one of these
helpers, not only where it named a field. **There is no configuration in which reordering
`struct inode` is safe for pre-built modules.** For an in-tree change that is
not an objection — the whole tree is rebuilt — but it is the reason such a
change cannot be backported into a distribution kernel's stable ABI.

---

## 5. 32-bit specific performance and correctness

### 5.1 64-bit quantities that are not single accesses

**`i_size`.** `include/linux/fs.h:590-598`:

    #if BITS_PER_LONG==32 && defined(CONFIG_SMP)
    #include <linux/seqlock.h>
    #define __NEED_I_SIZE_ORDERED
    #define i_size_ordered_init(inode) seqcount_init(&inode->i_size_seqcount)

and the field itself is conditional (`include/linux/fs.h:809-811`):

    #ifdef __NEED_I_SIZE_ORDERED
        seqcount_t  i_size_seqcount;
    #endif

Three distinct implementations of `i_size_read()` (`:1123-1147`):

| config | `i_size_read` | `i_size_write` |
|---|---|---|
| 32-bit + SMP | seqcount retry loop | `preempt_disable` + `write_seqcount_{begin,end}` |
| 32-bit + `PREEMPTION`, !SMP | `preempt_disable` / `enable` | `preempt_disable` / `enable` |
| everything else | `smp_load_acquire()` | `smp_store_release()` |

So **on 32-bit SMP every `i_size_read()` is a seqcount read with a retry loop**,
not a load — and `i_size_write()` additionally requires the caller to hold
`i_rwsem`, per the comment at `:1149-1153`: *"unlike `i_size_read()`,
`i_size_write()` does need locking around it (normally `i_rwsem`), otherwise on
32bit/SMP an update of `i_size_seqcount` can be lost, resulting in subsequent
`i_size_read()` calls spinning forever."* A refactor that moves an `i_size`
update out from under `i_rwsem` is correct on x86-64 and hangs 32-bit SMP.

**`struct inode` is 4 bytes bigger on 32-bit SMP than on 32-bit UP** because of
`i_size_seqcount`. Any statement of the form "this reorder is size-neutral" has
to hold for three configurations, not two.

**`i_version` and `i_sequence`** are `atomic64_t` (`include/linux/fs.h:838-839`).
On 32-bit x86 that is `arch/x86/include/asm/atomic64_32.h`: out-of-line
`cmpxchg8b`-based helpers (`ATOMIC64_DECL` at `:59`, `:66`, with a `_386`
fallback), i.e. **a function call and a locked `cmpxchg8b` for what is a plain
load on x86-64**. On architectures without a 64-bit atomic at all,
`CONFIG_GENERIC_ATOMIC64` (`lib/Kconfig:439`) routes to `lib/atomic64.c`, which
uses a hashed array of spinlocks. `inode_query_iversion()` is on the `statx`
path (see `02-stat-path.md` §5) — on 32-bit it is not free.

**Timestamps.** `inode_get_atime_sec()` is `READ_ONCE(inode->i_atime_sec)` on a
`time64_t` (`include/linux/fs.h:1599-1602`). On 32-bit that is not a single
access and is not torn-read-proof; there is no seqcount for it, unlike `i_size`.
This is the existing state, not a defect introduced by anything here, but a
proposal that starts reading timestamps from a new place on 32-bit inherits it.

**`f_pos`.** `loff_t` at `include/linux/fs.h:1277`, protected by `f_pos_lock`
(a mutex, `:1273`) for regular files and directories with `FMODE_ATOMIC_POS`.
That protection is word-size independent, so nothing extra is needed here.

### 5.2 Alignment, measured

`_Alignof(long long)` measured with the system gcc 15.2.0:

    gcc      -> 8
    gcc -m32 -> 4

That single difference is the source of every packed-struct override in §3.2,
and the kernel says so in two places:
`arch/x86/include/asm/compat.h:57-59` (*"IA32 uses 4 byte alignment for 64 bit
quantities"*) and `arch/x86/include/uapi/asm/statfs.h:5-9`.

It is **not** universal among 32-bit architectures. ARM EABI, powerpc32 and
others align `u64` to 8 while pointers stay at 4. The kernel's runtime hook for
the resulting mismatch is `compat_need_64bit_alignment_fixup()`
(`include/linux/compat.h:969-971`, default `false`;
`arch/x86/include/asm/compat.h:103` defines it as `in_ia32_syscall`), used in
`fs/quota/quota.c:219`, `:294`, `:445`, `net/ethtool/ioctl.c:900`, `:976` and
`drivers/gpio/gpiolib-cdev.c:1828`. There is no such hook for struct layout —
struct layout has to be got right at compile time.

### 5.3 The rule for checking a reorder across word sizes

**A reorder that is size-neutral on one word size can change size on the other,
in either direction.** Both directions demonstrated with the system compiler:

*Same on 32-bit, different on 64-bit* — because on i386 everything is 4-aligned
and `sizeof` is order-independent for these members, while on x86-64 an 8-aligned
`u64` after a lone `u32` costs 4 bytes of padding:

    struct X1 { u32 a; u32 b; u64 c; void *p; };   x86-64: 24   i386: 20
    struct X2 { u32 a; u64 c; u32 b; void *p; };   x86-64: 32   i386: 20

*Same on 64-bit, different on 32-bit* — on a 32-bit arch where `u64` is
**8**-aligned but pointers are 4 bytes (arm32 EABI, ppc32; modelled here with
`__attribute__((aligned(8)))` under `-m32`):

    struct Y1 { void *p; u64 c; u32 a; };          x86-64: 24   arm32-model: 24
    struct Y2 { void *p; u32 a; u64 c; };          x86-64: 24   arm32-model: 16

Y1 → Y2 is free on x86-64 and saves 8 bytes per object on arm32. Y2 → Y1 is
free on x86-64 and costs 8 bytes per object on arm32 — on `struct inode`, once
per cached inode, on the machines least able to afford it.

**The rule.** For any reorder of a struct containing both pointers and 64-bit
scalars, compute `sizeof` under all four ABI models before claiming
size-neutrality:

| model | pointer | `u64` align | example |
|---|---:|---:|---|
| LP64 | 8 | 8 | x86-64, arm64, riscv64 |
| ILP32, `u64` 4-aligned | 4 | 4 | i386 |
| ILP32, `u64` 8-aligned | 4 | 8 | arm32 EABI, ppc32 |
| ILP32 + SMP (VFS-specific) | 4 | as above | adds `i_size_seqcount` to `struct inode` |

A simpler sufficient condition, which `struct filename` already uses: order
members strictly by decreasing alignment requirement (8-byte scalars and
pointers first, then 4, then 2, then 1). Under that ordering `sizeof` is the sum
of the member sizes rounded up to the largest alignment, on every model, and a
reorder within an alignment class is provably free. `struct filename`
(`include/linux/fs.h:2449-2460`) enforces the outcome rather than the ordering:

    #define EMBEDDED_NAME_MAX (192 - sizeof(struct __filename_head))
    static_assert(offsetof(struct filename, iname) % sizeof(long) == 0);
    static_assert(sizeof(struct filename) % 64 == 0);

`__filename_head` is 24 bytes on 64-bit and 12 on 32-bit, and
`EMBEDDED_NAME_MAX` absorbs the difference so the total is 192 on both. That is
the pattern to copy when a size must be held constant across word sizes.

### 5.4 Cacheline size is not 64 everywhere

`L1_CACHE_BYTES` is `1 << L1_CACHE_SHIFT`, and the shift varies:

| arch | `L1_CACHE_SHIFT` | bytes | citation |
|---|---:|---:|---|
| x86 | `CONFIG_X86_L1_CACHE_SHIFT`: 6 for `X86_64`/`X86_GENERIC`/`MK7`/`MATOM`, **7** for `MPENTIUM4`, 5 for several 586/K6, 4 for `MGEODEGX1` | 16-128 | `arch/x86/include/asm/cache.h:8-9`, `arch/x86/Kconfig.cpu:240-245` |
| arm64 | 6 (fixed); `ARCH_DMA_MINALIGN` 128 | 64 | `arch/arm64/include/asm/cache.h:8-9`, `:35` |
| arm | `CONFIG_ARM_L1_CACHE_SHIFT` | 32 or 64 | `arch/arm/include/asm/cache.h:8-9` |
| powerpc | 4, 5, 6 or **7** depending on subarch | 16-128 | `arch/powerpc/include/asm/cache.h:10-30` |
| riscv | 6 | 64 | `arch/riscv/include/asm/cache.h:10-12` |
| **s390** | **8** | **256** | `arch/s390/include/asm/cache.h:13-14` |

`____cacheline_aligned` is `__attribute__((__aligned__(SMP_CACHE_BYTES)))`
(`include/vdso/cache.h:11-13`); `__cacheline_aligned` adds a
`.data..cacheline_aligned` section attribute (`include/linux/cache.h:71-75`);
`____cacheline_aligned_in_smp` collapses to nothing on UP
(`include/linux/cache.h:63-67`). `SMP_CACHE_BYTES` defaults to
`L1_CACHE_BYTES` (`include/vdso/cache.h:7-9`) on the architectures that do not
override it (e.g. `arch/powerpc/include/asm/cache.h:32`).

What this means for the layout work in this repository:

- **A layout tuned for 64-byte lines is a layout tuned for x86-64, arm64,
  riscv64 and most arm32.** It is not tuned for s390 (256), ppc64 with a
  128-byte line, or a Pentium 4.
- On a 128- or 256-byte-line machine, two fields the x86-64 layout deliberately
  put on *different* 64-byte lines may still share one real line, and the false
  sharing the patch was meant to remove is still there. The layout is not wrong,
  it just does nothing.
- Conversely, inserting `____cacheline_aligned` inside a struct to force a split
  costs 64 bytes on x86-64 and **256 bytes on s390**, per object. On
  `struct inode` that is not acceptable.
- The `struct dentry` comment (`include/linux/dcache.h:66-69`) states the
  compromise the kernel actually chose: *"Try to keep struct dentry aligned on
  64 byte cachelines (this will give reasonable cacheline footprint with larger
  lines without the large memory footprint increase)."* — i.e. tune to 64 and
  accept that bigger lines merely get a coarser result, rather than padding to
  the largest line any architecture has.
- `DNAME_INLINE_WORDS` (`include/linux/dcache.h:71-79`) is the concrete
  consequence, and is the clearest existing example of a VFS struct hand-tuned
  per word size:

        #ifdef CONFIG_64BIT
        # define DNAME_INLINE_WORDS 5  /* 192 bytes */
        #else
        # ifdef CONFIG_SMP
        #  define DNAME_INLINE_WORDS 9  /* 128 bytes */
        # else
        #  define DNAME_INLINE_WORDS 11 /* 128 bytes */
        # endif
        #endif

  Three values for three configurations, chosen so that `sizeof(struct dentry)`
  lands on 192 (64-bit, measured with `pahole`) and 128 (32-bit, per the
  comments — *not independently verified here; no 32-bit build exists in this
  tree*). **Any patch that adds or removes a member of `struct dentry` must
  re-derive all three numbers.**

  This matters more than it looks. `__dentry_cache` is created with
  `KMEM_CACHE_USERCOPY(dentry, SLAB_RECLAIM_ACCOUNT|SLAB_PANIC|SLAB_ACCOUNT,
  d_shortname.string)` (`fs/dcache.c:3479-3481`) — **no `SLAB_HWCACHE_ALIGN`**.
  The only reason every dentry starts on a 64-byte boundary is that 192 is a
  multiple of 64 and the objects pack contiguously from a page-aligned base.
  Add one pointer without adjusting `DNAME_INLINE_WORDS` and the object becomes
  200 bytes; dentries stop being 64-byte aligned; and the hand-laid-out
  `/* --- cacheline N boundary --- */` structure in `include/linux/dcache.h`
  becomes meaningless for every object but the first. That is a silent
  regression `pahole` alone will not flag, because `pahole` reports the struct,
  not the slab stride.

---

## 6. The checklist

Run before claiming a VFS change is backwards compatible on both word sizes.
Each item states the command and the pass condition. Items 1-6 are mechanical;
7-12 need judgement.

---

**1. No UAPI struct changed size, member offset, or padding.**

    cd /usr/src/linux
    git diff --stat -- 'include/uapi/**' 'arch/*/include/uapi/**' \
        include/linux/dirent.h fs/readdir.c

    # For each UAPI struct the diff touches, extract the definition into a
    # standalone .c file (see the method used in §3.2) and:
    gcc      -O2 -c -o /tmp/u64.o u.c && nm --print-size --radix=d /tmp/u64.o
    gcc -m32 -O2 -c -o /tmp/u32.o u.c && nm --print-size --radix=d /tmp/u32.o

*Pass:* every `sizeof` and every `offsetof` identical to the pre-patch tree, for
both `-m32` and `-m64`. An added member must fit entirely in an existing
`__spare`/`__pad`/`__unused` field. A *new* UAPI struct is exempt from the
sameness test but must satisfy item 4.

---

**2. No internal struct grew a cacheline on either word size.**

    # before and after, same invocation against each vmlinux:
    pahole -C inode,dentry,file /usr/src/kbench/builds/baseline/vmlinux
    pahole -C inode,dentry,file /usr/src/linux/build/vmlinux

    # only structs that still have holes, and how many:
    pahole -H 1 -C inode,dentry,file /usr/src/linux/build/vmlinux

    # the same layout as a 128-byte-line machine sees it (ppc64, some x86):
    pahole -c 128 -C inode,dentry,file /usr/src/linux/build/vmlinux
    pahole -c 256 -C inode,dentry,file /usr/src/linux/build/vmlinux   # s390

*Pass:* `size:` and `cachelines:` unchanged, or changed in the intended
direction and stated in the commit message. Baseline for this tree (pahole
v1.31, `RANDSTRUCT_NONE`, x86-64): `inode` 560/9, `dentry` 192/3, `file` 176/3.
A claim of the form "this moves field X off the contended line" must also be
checked at `-c 128`; if it does nothing there, say so.

---

**3. The reorder is size-neutral under all four ABI models (§5.3).**

For the struct under change, write out the member list and compute `sizeof`
under: LP64; ILP32 with 4-aligned `u64`; ILP32 with 8-aligned `u64`; and
ILP32+SMP if the struct is `struct inode` (which gains `i_size_seqcount`).
Mechanically, the same technique as item 1 works on an extracted copy of the
internal struct:

    gcc      -O2 -c -o /tmp/s64.o s.c && nm --print-size --radix=d /tmp/s64.o
    gcc -m32 -O2 -c -o /tmp/s32.o s.c && nm --print-size --radix=d /tmp/s32.o
    # then repeat -m32 with the u64 members marked __attribute__((aligned(8)))
    # to model arm32/ppc32

*Pass:* no model gets larger. If one does, either fix the ordering (largest
alignment first) or state the cost per object explicitly.

---

**4. New UAPI is 64-bit clean.**

    grep -nE '\b(long|unsigned long|off_t|time_t|size_t|ino_t|__kernel_long_t|__kernel_ulong_t|__kernel_off_t|__kernel_old_time_t)\b' \
        $(git diff --name-only -- 'include/uapi/**')

*Pass:* zero hits in any struct copied to or from userspace. Use `__u32`,
`__u64`, `__s64`, `__kernel_time64_t`, `struct __kernel_timespec`. Any `__u64`
must be at an offset that is a multiple of 8 within the struct, or the struct
needs an `ARCH_PACK_*`-style override — check with item 1.

---

**5. A new syscall needs no compat variant.**

    grep -n '<name>' arch/x86/entry/syscalls/syscall_32.tbl \
                     arch/x86/entry/syscalls/syscall_64.tbl \
                     include/uapi/asm-generic/unistd.h

*Pass:* four columns in `syscall_32.tbl` (no compat entry point), a `common`
row in `syscall_64.tbl`, and plain `__SYSCALL` — not `__SC_COMP`,
`__SC_3264` or `__SC_COMP_3264` — in `unistd.h`. If any of those is needed, the
interface shape is wrong; pass the 64-bit quantity inside a struct instead.
Also check the x32 rows (`syscall_64.tbl:407-442`) if the syscall takes a
pointer to anything containing a pointer.

---

**6. The overflow contract is unchanged.**

    git diff fs/stat.c fs/statfs.c fs/readdir.c fs/fcntl.c fs/read_write.c \
        | grep -nE 'EOVERFLOW|MAX_NON_LFS|COMPAT_OFF_T_MAX|old_valid_dev|sizeof\(tmp\.'

*Pass:* the set of `-EOVERFLOW` sites in the table in §2.2 is unchanged, and no
new copy-out assigns a 64-bit source to a narrower destination without either a
round-trip check or an explicit decision to truncate (documented in a comment,
as `fixup_compat_flock` does).

---

**7. `i_size` locking rules still hold.**

    git diff | grep -n 'i_size_write\|i_size_read\|->i_size'

*Pass:* every `i_size_write()` is still under `i_rwsem` (or the filesystem's
documented equivalent), per `include/linux/fs.h:1149-1153`. A lost seqcount
update deadlocks 32-bit SMP readers and is invisible on x86-64.

---

**8. No new `atomic64_t` or `time64_t` on a 32-bit hot path.**

    git diff | grep -n 'atomic64_\|time64_t\|READ_ONCE(.*_sec)'

*Pass:* if a new 64-bit atomic or 64-bit timestamp read is added to a path that
runs per-syscall, the cost on 32-bit (`cmpxchg8b` out-of-line call, or a hashed
spinlock under `CONFIG_GENERIC_ATOMIC64`) is stated in the commit message.

---

**9. `struct dentry` accounting, if `struct dentry` changed.**

    grep -n 'DNAME_INLINE_WORDS' include/linux/dcache.h
    pahole -C dentry /usr/src/linux/build/vmlinux | tail -5
    grep -n 'KMEM_CACHE_USERCOPY(dentry' fs/dcache.c

*Pass:* all three `DNAME_INLINE_WORDS` values re-derived so `sizeof(struct
dentry)` stays 192 (64-bit) and 128 (32-bit SMP and UP). `struct dentry` is not
`__randomize_layout`, so nothing else will absorb the change, and
`__dentry_cache` has no `SLAB_HWCACHE_ALIGN` (`fs/dcache.c:3479-3481`), so a
size that is not a multiple of 64 silently destroys the per-dentry cacheline
alignment the rest of the layout depends on (§5.4).

---

**10. Cross-compile the headers and at least one 32-bit arch.**

    # UAPI headers must still be self-contained:
    make -C /usr/src/linux O=/tmp/hdr headers
    # with CONFIG_UAPI_HEADER_TEST=y (needs HEADERS_INSTALL), init/Kconfig:272

    # a 32-bit build, both alignment models:
    make ARCH=i386 O=/tmp/b-i386 defconfig && make ARCH=i386 O=/tmp/b-i386 fs/
    make ARCH=arm CROSS_COMPILE=arm-linux-gnueabi- O=/tmp/b-arm \
         multi_v7_defconfig && make ARCH=arm CROSS_COMPILE=... O=/tmp/b-arm fs/

*Pass:* both configure and compile `fs/` clean. i386 covers the 4-aligned-`u64`
model; arm covers the 8-aligned-`u64` model. Building `fs/` alone is enough for
a layout change and is cheap; a full `vmlinux` is only needed if item 2 is to be
run on the 32-bit build. *Not verified here:* no cross toolchain is installed in
this environment, so these commands are specified, not demonstrated.

---

**11. Selftests.**

In-tree coverage that touches this surface, verified present:

    tools/testing/selftests/filesystems/statmount/   statmount + listmount, mask semantics
    tools/testing/selftests/filesystems/xattr/       xattrs on sockets/sockfs
    tools/testing/selftests/filesystems/ustat_test.c compat_ustat
    tools/testing/selftests/filelock/ofdlocks.c      F_OFD_* (32-bit: fcntl64 only)
    tools/testing/selftests/fchmodat2/
    tools/testing/selftests/mount/  mount_setattr/  move_mount_set_group/
    tools/testing/selftests/splice/
    tools/testing/selftests/x86/                     builds -m32 when CAN_BUILD_I386

        make -C tools/testing/selftests TARGETS="filesystems/statmount filelock \
             fchmodat2 mount mount_setattr splice" run_tests

*Pass:* no new failures. Two gaps to state rather than paper over:

- **There is no `statx` selftest anywhere in the tree.** `find
  tools/testing/selftests -iname '*statx*'` returns nothing. The `result_mask`
  contract in §3.3 — the thing every compatible extension depends on — is
  untested in-tree.
- **`openat2` is orphaned from the build.** Already recorded in this directory's
  `README.md`: `tools/testing/selftests/Makefile:106` says `TARGETS += openat2`
  and that directory does not exist; the tests are in `filesystems/openat2/`,
  which is in neither `TARGETS` (`Makefile:35-49`) nor `filesystems/Makefile`.
  The `RESOLVE_*` surface is not exercised by a default run.

`x86/` is the only selftest directory that builds 32-bit binaries at all
(`tools/testing/selftests/x86/Makefile:9`, `:28`, `:84`), and it contains no VFS
tests. **Verified 32-bit VFS ABI coverage in-tree is effectively zero.** A
change to a copy-out function must be tested by hand, with a 32-bit binary, or
against LTP.

---

**12. Module and BTF consumers.**

    # CRCs that changed (needs CONFIG_MODVERSIONS=y in both builds; the
    # baseline in /usr/src/kbench/builds/baseline has no Module.symvers, so
    # keep a copy of the pre-patch one before rebuilding):
    cp /usr/src/linux/build/Module.symvers /tmp/symvers.before   # before
    diff <(sort /tmp/symvers.before) \
         <(sort /usr/src/linux/build/Module.symvers) | head -50

    # BTF for the changed struct, before and after:
    bpftool btf dump file /usr/src/linux/build/vmlinux format raw | grep -A40 "'inode'"

*Pass:* every changed CRC is attributable to the change, no field was **renamed
or removed** (a reorder relocates under CO-RE; a rename does not — §4.2), and
the commit message says that out-of-tree modules need a rebuild. If the change
touches a field named in `fs/bpf_fs_kfuncs.c:422-427` or in the `bpf_d_path()`
allowlist (`kernel/trace/bpf_trace.c:961-975`), say so explicitly.

---

## Reproducing

    # syscall surface
    grep -nE '^[0-9]+\s+i386' arch/x86/entry/syscalls/syscall_32.tbl
    grep -rn 'COMPAT_SYSCALL_DEFINE' fs/ arch/x86/kernel/sys_ia32.c

    # internal layout
    pahole -C inode -C dentry -C file /usr/src/kbench/builds/baseline/vmlinux

    # UAPI sizes, both word sizes  (the .c files used for §3.2 and §5.3 are
    # transcriptions of the header definitions; regenerate them from the
    # headers cited in each row rather than trusting a copy)
    gcc      -O2 -c -o a64.o abi.c && nm --print-size --radix=d a64.o
    gcc -m32 -O2 -c -o a32.o abi.c && nm --print-size --radix=d a32.o

    # alignment model
    printf 'char a[_Alignof(long long)];\n' > al.c
    gcc -c -o al64.o al.c && gcc -m32 -c -o al32.o al.c
    nm --print-size --radix=d al64.o al32.o
