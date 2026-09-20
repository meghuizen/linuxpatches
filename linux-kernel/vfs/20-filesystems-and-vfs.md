# Filesystems and the VFS open/lookup/stat path — compatibility map

**Tree:** `/usr/src/linux`, Linux `7.3.0-rc3` + 824 commits, git `518e5b794c06c0f0eb40df3e202274a66202c137`
(`v7.3-rc3-824-g518e5b794c06`, merge of `for-7.3-rc3-tag` from `kdave/linux`).

**Purpose.** We are redesigning the reference-ownership contract around `do_dentry_open()`,
`finish_open()`, `atomic_open()`, `vfs_open()`, `vfs_tmpfile()` and
`terminate_walk()`/`path_openat()`. This document records, from the source, what every
filesystem on the open/lookup/stat path actually does with `struct file`, with the dentry it
is handed, and with references — so that a change to the contract can be checked against
each of them rather than against memory.

Everything here was read out of the tree named above. Where a fact could not be established
from the source it is written as **not found** or explicitly flagged as undetermined. Every
non-obvious claim carries a `file:line`.

---

## 0. The core contract as it exists today

This section is the baseline the rest of the document is measured against.

### 0.1 `f_path` is already read-only to filesystems

In this tree `struct file` does not have a writable `f_path` at all. It is a union of a
`const` view and a writable alias, `include/linux/fs.h:1267-1270`:

```c
	union {
		const struct path	f_path;
		struct path		__f_path;
	};
```

documented at `include/linux/fs.h:1239-1241`:

> `@f_path`: path of the file
> `@__f_path`: writable alias for `@f_path`; \*ONLY\* for core VFS and only before the file gets open

**The invariant Al Viro wants to forbid is already enforced by the type system, and there is
no violator anywhere in the tree.** A sweep for any assignment to `f_path` or its members
outside core VFS returns nothing in `fs/`, `mm/`, `drivers/` or `include/`; every hit is an
unrelated local variable whose name ends in `_path`. The complete set of `__f_path` writers is:

| site | what it does |
| --- | --- |
| `fs/file_table.c:199` | `init_file()` zeroes it |
| `fs/file_table.c:364` | `file_init_path()` for `alloc_file()`/pseudo files |
| `fs/namei.c:4365-4366` | `atomic_open()` seeds `DENTRY_NOT_SET` + parent mnt |
| `fs/namei.c:4889-4890` | `vfs_tmpfile()` seeds parent mnt + fresh child dentry |
| `fs/open.c:1029-1030` | `do_dentry_open()` error unwind nulls it |
| `fs/open.c:1057` | `finish_open()` |
| `fs/open.c:1080` | `finish_no_open()` |
| `fs/open.c:1100` | `vfs_open()` |

No other file in the tree mentions `__f_path`.

Filesystems *read* `f_path` freely, and several of them **require** it to be populated before
their hook runs — see §0.3 and §0.5.

### 0.2 `do_dentry_open()` takes its own path reference

`fs/open.c:934-1032`. The relevant facts:

* `fs/open.c:941` — `path_get(&f->f_path);` is the **first** thing it does. The file owns an
  independent `(dentry, mnt)` reference from that point on, not borrowed from the nameidata.
* `fs/open.c:967` — `f->f_op = fops_get(inode->i_fop);`
* `fs/open.c:993-999` — the `->open` callback runs.
* `fs/open.c:1000` — `f->f_mode |= FMODE_OPENED;`
* `fs/open.c:1001-1011` — `FMODE_CAN_READ`/`CAN_WRITE`/`LSEEK`/`CAN_ODIRECT` are derived from
  `f->f_op` and `f->f_mapping` **after** `FMODE_OPENED` is set.
* `fs/open.c:1017-1018` — `if ((f->f_flags & O_DIRECT) && !(f->f_mode & FMODE_CAN_ODIRECT)) return -EINVAL;`
  This returns an error **with `FMODE_OPENED` already set and the path reference still held**,
  and it does **not** go through `cleanup_file`. Teardown is left to the caller's `fput()`.
* `fs/open.c:1021-1031` — `cleanup_all`/`cleanup_file` do `fops_put`, `put_file_access`,
  `path_put(&f->f_path)` and then null `__f_path.mnt`/`__f_path.dentry`.

`__fput()` only undoes any of this if the file was opened — `fs/file_table.c:493-494`:

```c
	if (unlikely(!(file->f_mode & FMODE_OPENED)))
		goto out;
```

and the matching `dput(dentry)` / `mntput(mnt)` are at `fs/file_table.c:520` and `:523`.

### 0.3 `finish_open()` / `finish_no_open()` / `finish_open_simple()`

`fs/open.c:1052-1058`:

```c
int finish_open(struct file *file, struct dentry *dentry,
		int (*open)(struct inode *, struct file *))
{
	BUG_ON(file->f_mode & FMODE_OPENED); /* once it's opened, it's opened */

	file->__f_path.dentry = dentry;
	return do_dentry_open(file, open);
}
```

* `fs/open.c:1047-1049` documents that **the dentry reference is not consumed**.
* `finish_no_open()` (`fs/open.c:1076-1082`) **does** consume it (`fs/open.c:1070-1071`).
* `finish_open_simple()` is an inline that re-reads the dentry already in `f_path` —
  `include/linux/fs.h:2596-2602`:

```c
static inline int finish_open_simple(struct file *file, int error)
{
	if (error)
		return error;

	return finish_open(file, file->f_path.dentry, NULL);
}
```

  So every `->tmpfile` handler that uses it depends on `vfs_tmpfile()` having already put the
  child dentry into `__f_path` (`fs/namei.c:4890`).

### 0.4 `atomic_open()` — the dentry-substitution machinery

`fs/namei.c:4356-4413`. Before the callback:

```c
	file->__f_path.dentry = DENTRY_NOT_SET;
	file->__f_path.mnt = path->mnt;
```

(`fs/namei.c:4365-4366`). **`f_path.mnt` is valid on entry to `->atomic_open`** and two
filesystems rely on it (§0.5). After the callback, `fs/namei.c:4371-4396`:

* `FMODE_OPENED` set → the filesystem called `finish_open()`; if
  `file->f_path.dentry != dentry` the VFS `dput()`s the original and `dget()`s the opened one
  (`fs/namei.c:4375-4378`).
* `FMODE_OPENED` clear and `f_path.dentry != DENTRY_NOT_SET` → `finish_no_open()` was called;
  the returned dentry *replaces* the original (`fs/namei.c:4380-4388`).
* Neither → `WARN(1, "%s: ->atomic_open() left file->f_path.dentry unset!\n", ...)` and `-EIO`
  (`fs/namei.c:4389-4395`).
* `fs/namei.c:4398-4411` — on error, `-ENOENT` is rewritten to a stashed `create_error`, with
  an explicit note that "Some filesystems return `-ENOENT` directly instead of calling
  `finish_no_open()` with a negative dentry".

`fs/namei.c:4350-4353` states the reference rule for the whole helper: *"The reference to
@dentry is consumed in either case."*

### 0.5 Filesystems that read `f_path` inside `->atomic_open`/`->tmpfile`

`file_mnt_idmap()` is `mnt_idmap(file->f_path.mnt)` (`include/linux/fs.h:2462-2465`). Two
`->atomic_open` implementations call it at the top of the hook:

* `fs/ceph/file.c:798` — `struct mnt_idmap *idmap = file_mnt_idmap(file);`
* `fs/fuse/dir.c:944` — `struct mnt_idmap *idmap = file_mnt_idmap(file);`

and four `->tmpfile` implementations read `f_path.dentry` directly:

* `fs/btrfs/inode.c:9422`, `fs/xfs/xfs_iops.c:1258`, `fs/ubifs/dir.c:446`,
  `fs/overlayfs/dir.c:1427`, plus `fs/fuse/dir.c:1110` and `fs/smb/client/dir.c:1065`.

### 0.6 `vfs_tmpfile()`

`fs/namei.c:4866-4914`. The ownership shape:

```c
	child = d_alloc(parentpath->dentry, &slash_name);
	if (unlikely(!child))
		return -ENOMEM;
	file->__f_path.mnt = parentpath->mnt;
	file->__f_path.dentry = child;
	mode = vfs_prepare_mode(idmap, dir, mode, mode, mode);
	error = dir->i_op->tmpfile(idmap, dir, file, mode);
	dput(child);
	if (file->f_mode & FMODE_OPENED)
		fsnotify_open(file);
```

* `__f_path.mnt` is assigned **without** an `mntget` (`fs/namei.c:4889`); the mount reference
  the file ends up owning is the one `do_dentry_open()` takes at `fs/open.c:941`.
* `child` is `dput()` at `fs/namei.c:4892` immediately after the hook returns, whether or not
  the hook succeeded. If the hook did not open the file, `__f_path` is left populated with a
  dentry the file does not own a reference to — but `__fput()` will not touch it because
  `FMODE_OPENED` is clear (`fs/file_table.c:493-494`).
* `fs/namei.c:4894-4895` calls `fsnotify_open(file)` when `FMODE_OPENED` is set, **before**
  checking `error` (`fs/namei.c:4896-4897`). So a `->tmpfile` that opened the file and then
  failed still gets an `fsnotify_open`.
* `fs/namei.c:4898` then does `may_open(idmap, &file->f_path, 0, file->f_flags)` — reading
  `f_path` back out.

### 0.7 `path_openat()` / `open_last_lookups()` / `terminate_walk()`

`open_last_lookups()`, `fs/namei.c:4771-4775`:

```c
	if (file->f_mode & (FMODE_OPENED | FMODE_CREATED)) {
		dput(nd->path.dentry);
		nd->path.dentry = dentry;
		return NULL;
	}
```

The nameidata's `path.dentry` is swapped from the parent to the child, dropping the parent's
reference and taking over the one `lookup_open()`/`atomic_open()` returned. `nd->path.mnt` is
not touched. `terminate_walk()` (`fs/namei.c:843-862`) then `path_put(&nd->path)` in the
non-RCU case. **The file's references and the nameidata's references are entirely separate**;
the file got its own pair at `fs/open.c:941`.

`do_open()` skips `complete_walk()` entirely once the filesystem has opened or created —
`fs/namei.c:4798-4802` — so `->d_revalidate` is not re-run on the result of `->atomic_open`.

`path_openat()` `fs/namei.c:4980-5017`: after `do_open()` it asserts
`WARN_ON(1); error = -EINVAL;` if no error was returned but `FMODE_OPENED` is clear
(`fs/namei.c:5003-5008`), and converts `-EOPENSTALE` to `-ECHILD` (RCU) or `-ESTALE`
(`fs/namei.c:5010-5015`). `do_file_open()` retries on both (`fs/namei.c:5029-5033`).

---

## 1. Summary matrix

Legend: **n/f** = not found. "Diff dentry" = can hand `finish_open()`/`finish_no_open()` a
dentry other than the one passed in. "f_path write" = writes `file->f_path`/`__f_path` inside
`->open` (or anywhere).

| fs | `->atomic_open` | `finish_open*` | `->tmpfile` | `->d_revalidate` | RCU-walk | diff dentry | f_path write |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ext4 | n/f | `fs/ext4/namei.c:2918` (simple) | `fs/ext4/namei.c:4233` | n/f | n/a | no | **no** |
| ext2 | n/f | `fs/ext2/namei.c:131` (simple) | `fs/ext2/namei.c:423` | n/f | n/a | no | **no** |
| btrfs | n/f | `fs/btrfs/inode.c:9471` (simple) | `fs/btrfs/inode.c:10769` | n/f | n/a | no | **no** |
| xfs | n/f | `fs/xfs/xfs_iops.c:1260` (simple) | `fs/xfs/xfs_iops.c:1299`, `:1327` | n/f | n/a | no | **no** |
| f2fs | n/f | `fs/f2fs/namei.c:944` (simple) | `fs/f2fs/namei.c:1424` | n/f | n/a | no | **no** |
| ubifs | n/f | `fs/ubifs/dir.c:512` (simple) | `fs/ubifs/dir.c:1756` | n/f | n/a | no | **no** |
| ntfs3 | n/f | n/f (comment only, `fs/ntfs3/inode.c:1870`) | **n/f** | n/f | n/a | no | **no** |
| udf | n/f | `fs/udf/namei.c:403` (simple) | `fs/udf/namei.c:1027` | n/f | n/a | no | **no** |
| minix | n/f | `fs/minix/namei.c:59`, `:63` (simple) | `fs/minix/namei.c:290` | n/f | n/a | no | **no** |
| ramfs | n/f | `fs/ramfs/inode.c:186` (simple) | `fs/ramfs/inode.c:199` | n/f | n/a | no | **no** |
| tmpfs/shmem | n/f | `mm/shmem.c:3882` (simple) | `mm/shmem.c:5212` | n/f | n/a | no | **no** |
| hugetlbfs | n/f | `fs/hugetlbfs/inode.c:998` (simple) | `fs/hugetlbfs/inode.c:1228` | n/f | n/a | no | **no** |
| proc | n/f | n/f | **n/f** | 5 variants, `fs/proc/base.c:2043` etc. | mixed — `pid_revalidate` RCU-safe; 4 others `-ECHILD` | no | **no** |
| sysfs/kernfs | n/f | n/f | **n/f** | `fs/kernfs/dir.c:1171` | **never** — `-ECHILD` at `fs/kernfs/dir.c:1177-1178` | no | **no** |
| devtmpfs | n/f (inherits) | n/f | inherits shmem/ramfs | inherits | inherits | no | **no** |
| overlayfs | **n/f** | `fs/overlayfs/dir.c:1462` (`finish_open` + `ovl_dummy_open`) | `fs/overlayfs/dir.c:1489` | `fs/overlayfs/super.c:152`, `:158` | **yes**, forwards flags to lower layers | `->lookup` yes (`d_splice_alias`), `->tmpfile` no | **no** — makes a second `struct file` |
| nfs v2/v3 | `fs/nfs/proc.c:711`, `fs/nfs/nfs3proc.c:1044` | `fs/nfs/dir.c:2332`, `:2334`, `:2345` | n/f | `fs/nfs/dir.c:1979` | partial — `-ECHILD` at `fs/nfs/dir.c:1816-1817` | **yes** | **no** |
| nfs v4 | `fs/nfs/nfs4proc.c:10710` | `fs/nfs/dir.c:2093`, `:2167`, `:2253` | n/f | `fs/nfs/dir.c:2067` | partial — fast path returns 1 in RCU (`fs/nfs/dir.c:2297-2298`) | **yes** (`fs/nfs/dir.c:2162`, `:2216`) | **no** |
| ceph | `fs/ceph/dir.c:2271` | `fs/ceph/file.c:781`, `:983`, `:1005` | n/f | `fs/ceph/dir.c:2284` | partial — `-ECHILD` at `fs/ceph/dir.c:2021-2022` | **yes** (`fs/ceph/file.c:959`) | **no** |
| cifs/smb client | `fs/smb/client/cifsfs.c:1245` | `fs/smb/client/dir.c:556`, `:601`, `:1143` | `fs/smb/client/cifsfs.c:1246` | `fs/smb/client/dir.c:869` | **never** — `-ECHILD` at `fs/smb/client/dir.c:872-873` | **yes** (`fs/smb/client/dir.c:591-593`) | **no** (but rewrites `f_op`, §14) |
| 9p | `fs/9p/vfs_inode.c:1368`, `:1383`, `fs/9p/vfs_inode_dotl.c:963` | `fs/9p/vfs_inode.c:782`, `:787`, `:805`; `fs/9p/vfs_inode_dotl.c:244`, `:249`, `:316` | n/f | `fs/9p/vfs_dentry.c:213` | **never** — `-ECHILD` at `fs/9p/vfs_dentry.c:145-146` | via `finish_no_open` only | **no** |
| gfs2 | `fs/gfs2/inode.c:2325` | `fs/gfs2/inode.c:758`, `:760`, `:907`, `:1012`, `:1398` | **n/f** | `fs/gfs2/dentry.c:99` | **never** — `-ECHILD` at `fs/gfs2/dentry.c:46-47` | via `finish_no_open` only | **no** |
| fuse / virtiofs | `fs/fuse/dir.c:2425` | `fs/fuse/dir.c:916`, `:953`, `:957`, `:977` | `fs/fuse/dir.c:2426` | `fs/fuse/dir.c:539` | partial — RCU-valid while entry timeout holds (`fs/fuse/dir.c:461-470`) | via `finish_no_open` only | **no** |
| vboxsf | `fs/vboxsf/dir.c:473` | `fs/vboxsf/dir.c:324`, `:329`, `:341` | n/f | `fs/vboxsf/dir.c:208` | **never** — `-ECHILD` at `fs/vboxsf/dir.c:198-199` | via `finish_no_open` only | **no** |
| bad_inode | `fs/bad_inode.c:183` | n/f (returns `-EIO`) | `fs/bad_inode.c:184` (returns `-EIO`) | n/f | n/a | no | **no** |

`->atomic_open` implementations, exhaustive (`grep '\.atomic_open' fs/`): 9p ×3, bad_inode,
ceph, fuse, gfs2, nfs ×3, cifs, vboxsf — **twelve registrations across nine filesystems.**

`->tmpfile` implementations, exhaustive (`grep '\.tmpfile' fs/ mm/ drivers/`): bad_inode,
btrfs, ext2, ext4, f2fs, fuse, hugetlbfs, minix, overlayfs, ramfs, cifs, ubifs, udf, xfs ×2,
shmem — **sixteen registrations.** Notably absent: **ntfs3, nfs, ceph, 9p, gfs2, vboxsf,
proc, sysfs/kernfs**. `O_TMPFILE` on those fails at `fs/namei.c:4884-4885` with `-EOPNOTSUPP`.

---

## 2. ext4

* `->atomic_open`: **not found.**
* `->tmpfile`: `ext4_tmpfile` at `fs/ext4/namei.c:2884`, registered `fs/ext4/namei.c:4233` in
  `ext4_dir_inode_operations`. It never dereferences `file` itself; `file` is a carrier passed
  to `d_tmpfile(file, inode)` (`fs/ext4/namei.c:2907`) and `finish_open_simple(file, err)`
  (`:2918`).
* **Failure after instantiation, without `FMODE_OPENED`.** The `err_unlock_inode` path at
  `fs/ext4/namei.c:2919-2922` is reached from `:2909-2910`, i.e. **after** `d_tmpfile()` has
  already instantiated the inode onto `file->f_path.dentry`, and it returns `err` directly,
  bypassing `finish_open_simple`. The inode reference has moved into the dentry, and
  `vfs_tmpfile`'s `dput(child)` (`fs/namei.c:4892`) releases it.
* `->open`: `ext4_file_open` (`fs/ext4/file.c:962`, registered `:1045`), `ext4_dir_open`
  (`fs/ext4/dir.c:687`, registered `:699`). `->permission`: **not found.**
* `f_path` inside `->open`: one **read**, `fs/ext4/file.c:973` —
  `ext4_sample_last_mounted(inode->i_sb, filp->f_path.mnt)`. Plus an indirect read of
  `f_path.dentry` through `fscrypt_file_open` → `file_dentry()` (`fs/crypto/hooks.c:44`,
  `include/linux/fs.h:1361`).
* Extra refs in `->open`: none. `fscrypt_file_open`'s `dget_parent`/`dput`
  (`fs/crypto/hooks.c:61`, `:69`) are balanced inside the call.
* `->getattr`: `ext4_getattr` (`fs/ext4/inode.c`, registered `fs/ext4/namei.c:4236`, `:4247`).
  Handles `STATX_BTIME` (`fs/ext4/inode.c:6274`), `STATX_DIOALIGN` (`:6282`),
  `STATX_WRITE_ATOMIC` (`:6298`), and sets `STATX_ATTR_*` at `:6311-6329`.
  **`AT_STATX_DONT_SYNC` is never examined** — `query_flags` is forwarded but not read.

## 3. ext2

* `->atomic_open`: **not found.** `->tmpfile`: `ext2_tmpfile` (`fs/ext2/namei.c:120`),
  registered `fs/ext2/namei.c:423`. Single exit through `finish_open_simple(file, 0)` at
  `fs/ext2/namei.c:131`; `file` is never dereferenced by ext2.
* `->open`: `ext2_file_open` (`fs/ext2/file.c:184`, registered `:199`). **Zero `f_path`
  references anywhere in `fs/ext2/`.** No refs taken.
* `->getattr`: `ext2_getattr` (`fs/ext2/inode.c:1594`). `STATX_ATTR_*` only
  (`fs/ext2/inode.c:1601-1614`); no `STATX_BTIME`, **no `AT_STATX_DONT_SYNC`**.
* `->d_revalidate` / `->d_op`: **not found.**

## 4. btrfs

* `->atomic_open`: **not found.**
* `->tmpfile`: `btrfs_tmpfile` (`fs/btrfs/inode.c:9413`), registered `fs/btrfs/inode.c:10769`.
  **It reads `file->f_path.dentry` directly**, `fs/btrfs/inode.c:9420-9424`:

```c
	struct btrfs_new_inode_args new_inode_args = {
		.dir = dir,
		.dentry = file->f_path.dentry,
		.orphan = true,
	};
```

  so `btrfs_create_new_inode` can derive the name and inherited properties. The dentry is
  **borrowed**, no reference taken. Single exit through `finish_open_simple(file, ret)` at
  `fs/btrfs/inode.c:9471`.
* `->open`: `btrfs_file_open` (`fs/btrfs/file.c:3777`, registered `:3826`), `btrfs_opendir`
  (`fs/btrfs/inode.c:6265`, registered `:10778`). Neither touches `f_path`.
  `->permission`: `btrfs_permission` (registered `fs/btrfs/inode.c:10765` and three others).
* `->d_op`: `btrfs_dentry_operations` (`fs/btrfs/inode.c:10879`), installed via
  `set_default_d_op` at `fs/btrfs/super.c:959`; it has only `.d_delete`, **no `->d_revalidate`.**
* `->getattr`: `btrfs_getattr` (`fs/btrfs/inode.c:8246`). Sets `STATX_BTIME`
  (`fs/btrfs/inode.c:8258-8260`) and `STATX_SUBVOL` (`:8279-8281`) **unconditionally, without
  consulting `request_mask`**. `attributes_mask` at `:8271-8274` omits `STATX_ATTR_VERITY`
  even though `:8269` can set it. `query_flags` is never read — **no `AT_STATX_DONT_SYNC`.**

## 5. xfs

* `->atomic_open`: **not found.**
* `->tmpfile`: `xfs_vn_tmpfile` (`fs/xfs/xfs_iops.c:1251`), registered twice —
  `fs/xfs/xfs_iops.c:1299` (`xfs_dir_inode_operations`) and `:1327`
  (`xfs_dir_ci_inode_operations`):

```c
	int err = xfs_generic_create(idmap, dir, file->f_path.dentry, mode, 0, file);

	return finish_open_simple(file, err);
```

  (`fs/xfs/xfs_iops.c:1258-1260`). It reads `f_path.dentry` **and** passes `file` on so that
  `xfs_generic_create` can read `file->f_flags` at `fs/xfs/xfs_iops.c:224` (`O_EXCL` →
  `XFS_ICREATE_UNLINKABLE`) and call `d_tmpfile(tmpfile, inode)` at `:261`.
* `->open`: `xfs_file_open` (`fs/xfs/xfs_file.c:1772`, registered `:2169`), `xfs_dir_open`
  (`:1785`, registered `:2183`). Neither touches `f_path`. `->permission`: **not found.**
* `->d_revalidate` / `->d_op`: **not found** — case-insensitivity is done with a separate
  `inode_operations`, not dentry ops.
* `->getattr`: `xfs_vn_getattr` (`fs/xfs/xfs_iops.c:681`). The most thorough `STATX_` handling
  of the local filesystems: `STATX_BTIME` (`:711`), `STATX_DIOALIGN|STATX_DIO_READ_ALIGN`
  (`:742`), `STATX_WRITE_ATOMIC` (`:744`), `STATX_ATTR_*` at `:723-732`. `query_flags` is a
  parameter at `:686` but is **never read — no `AT_STATX_DONT_SYNC`.**
* One notable `f_path` consumer outside open: `fs/xfs/xfs_handle.c:272` does
  `path.mnt = mntget(parfilp->f_path.mnt);`, released by a `__free(path_put)` declared at
  `fs/xfs/xfs_handle.c:240`.

## 6. f2fs

* `->atomic_open`: **not found.** `->tmpfile`: `f2fs_tmpfile` (`fs/f2fs/namei.c:931`),
  registered `fs/f2fs/namei.c:1424`; `finish_open_simple` at `:944`.
* `__f2fs_tmpfile` is shared with two in-kernel callers that pass `file == NULL`
  (`f2fs_create_whiteout` at `fs/f2fs/namei.c:947`, `f2fs_get_tmpfile` at `:955`), hence the
  NULL test at `fs/f2fs/namei.c:909-912` guarding `d_tmpfile(file, inode)`.
* `->open`: `f2fs_file_open` (`fs/f2fs/file.c:676`, registered `:5899`). It does **not** touch
  `f_path` directly, but reads it through `fscrypt_file_open` (`fs/f2fs/file.c:678`).
* **Counter taken inside `->open`:** `fs/f2fs/file.c:704` —
  `atomic_inc(&F2FS_I(inode)->open_count);`. This is an `atomic_t`, not an inode refcount, and
  it is incremented *before* `FMODE_OPENED` is set (`fs/open.c:1000`). If `do_dentry_open()`
  fails after `->open` returned 0 — e.g. the `O_DIRECT` check at `fs/open.c:1017-1018` —
  `->release` will not run and the counter is not decremented.
* `->getattr`: `f2fs_getattr` (`fs/f2fs/file.c:1035`). `STATX_BTIME` (`:1043-1049`),
  `STATX_DIOALIGN` (`:1058`), `STATX_ATTR_*` (`:1067-1086`). `query_flags` declared at
  `fs/f2fs/file.c:1036`, **never read — no `AT_STATX_DONT_SYNC`.**
* `->d_revalidate` / `->permission`: **not found.**

## 7. ubifs

* `->atomic_open`: **not found.** `->tmpfile`: `ubifs_tmpfile` (`fs/ubifs/dir.c:443`),
  registered `fs/ubifs/dir.c:1756`. It reads `f_path.dentry` at the top, `fs/ubifs/dir.c:446`:
  `struct dentry *dentry = file->f_path.dentry;` — needed because it feeds `dentry->d_name`
  (the `slash_name` `/` that `vfs_tmpfile` allocated, `fs/namei.c:4886`) to
  `fscrypt_setup_filename`.
* **Failure after `d_tmpfile()`, without `FMODE_OPENED`.** `fs/ubifs/dir.c:508` can fail
  `ubifs_jnl_update` and jump to `out_cancel` (`:514`), falling through to a plain
  `return err` at `:524` — never reaching `finish_open_simple` at `:512`. The `instantiated`
  flag (`:499`) correctly suppresses the `iput` at `:517-518`, since `d_instantiate` inside
  `d_tmpfile` already transferred the inode reference to the dentry.
* `->open`: `fscrypt_file_open` is used *directly* as the file `->open`
  (`fs/ubifs/file.c:1662`), so `f_path.dentry` is read via `file_dentry()`
  (`fs/crypto/hooks.c:44`). `ubifs_dir_open` at `fs/ubifs/dir.c:1724`, registered `:1762`.
* `->getattr`: `ubifs_getattr` (`fs/ubifs/dir.c:1670`). `STATX_ATTR_*` only
  (`fs/ubifs/dir.c:1679-1692`); the query-flags parameter is even named `flags` (`:1671`) and
  is **never read — no `AT_STATX_DONT_SYNC`.**
* `->d_revalidate` / `->permission`: **not found.**

## 8. ntfs3

ntfs3 does not participate in the ownership handoff at all.

* `->atomic_open`: **not found.** `->tmpfile`: **not found** — `ntfs_dir_inode_operations`
  (`fs/ntfs3/namei.c:529`) has none, so `O_TMPFILE` fails with `-EOPNOTSUPP` at
  `fs/namei.c:4884-4885`.
* `finish_open` is never called. The only textual match is a stale comment at
  `fs/ntfs3/inode.c:1868-1872` inside `ntfs_create_inode` ("Call `d_instantiate` after
  `inode->i_op` is set but before `finish_open`"), referring to the VFS's later
  `finish_open`, not to a call ntfs3 makes.
* `->open`: `ntfs_file_open` (`fs/ntfs3/file.c:1374`, registered `:1597` and
  `fs/ntfs3/dir.c:740`). It reads only `file->f_flags` and writes `file->f_mode`
  (`fs/ntfs3/file.c:1406`). **Zero `f_path` references in `fs/ntfs3/`.**
* `->d_op`: `ntfs_dentry_ops` (`fs/ntfs3/namei.c:559`) — `.d_hash`/`.d_compare` only, installed
  conditionally at `fs/ntfs3/super.c:1313`. **No `->d_revalidate`, no `->permission`.**
* `->getattr`: `ntfs_getattr` (`fs/ntfs3/file.c:264`). Sets `STATX_BTIME` **unconditionally**
  at `fs/ntfs3/file.c:274-275` without testing `request_mask`; `attributes_mask` at `:294-295`
  omits `STATX_ATTR_NODUMP` even though `:286` can set it. **No `AT_STATX_DONT_SYNC`.**

## 9. udf

* `->atomic_open`: **not found.** `->tmpfile`: `udf_tmpfile` (`fs/udf/namei.c:389`),
  registered `fs/udf/namei.c:1027`; `finish_open_simple(file, 0)` at `:403`. `file` is never
  dereferenced by udf.
* `->open`: `udf_dir_open` (`fs/udf/dir.c:132`, registered `:154`); regular files use
  `generic_file_open` (`fs/udf/file.c:204`). **Zero `f_path` references, zero `dget`/`mntget`/
  `igrab`/`path_get` anywhere in `fs/udf/`.**
* `->getattr`: only `udf_symlink_getattr` (`fs/udf/symlink.c:136`, registered `:172`).
  **Regular files and directories have no `->getattr` at all** — `vfs_getattr_nosec` falls
  through to `generic_fillattr` at `fs/stat.c:218`. No `STATX_ATTR_*`, no
  `AT_STATX_DONT_SYNC`.
* `->d_revalidate` / `->d_op` / `->permission`: **not found.**

## 10. minix

* `->atomic_open`: **not found.** `->tmpfile`: `minix_tmpfile` (`fs/minix/namei.c:53`),
  registered `fs/minix/namei.c:290`. It is the only handler that routes its **error** return
  through the helper too, `fs/minix/namei.c:56-63`:

```c
	struct inode *inode = minix_new_inode(dir, mode);

	if (IS_ERR(inode))
		return finish_open_simple(file, PTR_ERR(inode));
	minix_set_inode(inode, 0);
	mark_inode_dirty(inode);
	d_tmpfile(file, inode);
	return finish_open_simple(file, 0);
```

  Harmless, because `finish_open_simple` short-circuits on non-zero error
  (`include/linux/fs.h:2598-2599`) and never touches `file`.
* `->open`: **not found** — neither `minix_file_operations` (`fs/minix/file.c:17`) nor
  `minix_dir_operations` (`fs/minix/dir.c:22`) has one.
* `->getattr`: `minix_getattr` (`fs/minix/inode.c:727`). Sets **no** `STATX_ATTR_*`, no
  `attributes_mask`, no `result_mask`; never reads the query flags.
* **Zero `f_path` references and zero refcount operations anywhere in `fs/minix/`.**

## 11. ramfs, tmpfs/shmem, hugetlbfs, devtmpfs

All three real ones have the same shape: no `->atomic_open`, a `->tmpfile` that calls
`d_tmpfile()` then `finish_open_simple()`, and **zero `f_path` references**.

**ramfs** — `ramfs_tmpfile` `fs/ramfs/inode.c:166`, registered `:199`; `finish_open_simple` at
`:186`. `->open`: **not found** (`fs/ramfs/file-mmu.c:41-50`). `->getattr`: `simple_getattr`
(`fs/ramfs/file-mmu.c:54`). No `->permission`, no `->d_revalidate`, no `->d_op`.

**tmpfs/shmem** — `shmem_tmpfile` `mm/shmem.c:3859`, registered `:5212`; `finish_open_simple`
at `:3882`. Its `out_iput:` error path (`mm/shmem.c:3887`) bypasses the helper.
`->open`: `shmem_file_open` (`mm/shmem.c:2934`, registered `:5175`) — touches `f_mode` only:

```c
static int shmem_file_open(struct inode *inode, struct file *file)
{
	file->f_mode |= FMODE_CAN_ODIRECT;
	return generic_file_open(inode, file);
}
```

`->getattr`: `shmem_getattr` (`mm/shmem.c:1296`) — handles `STATX_BTIME`, sets
`STATX_ATTR_APPEND|IMMUTABLE|NODUMP`; `query_flags` accepted at `:1297` but never examined
(correct for an in-memory fs).

**hugetlbfs** — `hugetlbfs_tmpfile` `fs/hugetlbfs/inode.c:987`, registered `:1228`;
`finish_open_simple(file, 0)` at `:998`. **No `->open` and no `->getattr` at all**
(`fs/hugetlbfs/inode.c:1207-1215`, `:1231-1233`) — stat falls through to `generic_fillattr`.
`hugetlb_file_setup()` uses `alloc_file_pseudo` at `fs/hugetlbfs/inode.c:1543`, which is core
VFS setting `__f_path` via `file_init_path` (`fs/file_table.c:364`).

**devtmpfs** — implements no inode/file/dentry operations of its own. It is a
`file_system_type` wrapper delegating to shmem or ramfs, `drivers/base/devtmpfs.c:65-72`:

```c
static struct file_system_type internal_fs_type = {
	.name = "devtmpfs",
#ifdef CONFIG_TMPFS
	.init_fs_context = shmem_init_fs_context,
#else
	.init_fs_context = ramfs_init_fs_context,
#endif
```

The only reference it takes is a mount-time `fc->root = dget(sb->s_root);` at
`drivers/base/devtmpfs.c:82`. **Zero `f_path` references.** Everything on the open path is
inherited from shmem/ramfs.

## 12. proc and sysfs/kernfs

Neither implements `->atomic_open`, `->tmpfile`, or calls `finish_open*`. Both are relevant
only for the RCU-walk and stat columns.

### proc

`->d_revalidate` comes in five flavours, and only one is RCU-capable:

| ops | `d_revalidate` | RCU-walk |
| --- | --- | --- |
| `pid_dentry_operations` `fs/proc/base.c:2079` | `pid_revalidate` `fs/proc/base.c:2043` | **works in RCU** — no `LOOKUP_RCU` check, body is `rcu_read_lock()`/`d_inode_rcu()`/`pid_task()`/`pid_update_inode()` (`fs/proc/base.c:2050-2062`) |
| `tid_map_files_dentry_operations` `fs/proc/base.c:2226` | `map_files_d_revalidate` `:2179` | `-ECHILD` at `fs/proc/base.c:2189-2190` |
| `tid_fd_dentry_operations` `fs/proc/fd.c:169` | `tid_fd_revalidate` `:143` | `-ECHILD` at `fs/proc/fd.c:150-151` |
| `proc_misc_dentry_ops` `fs/proc/generic.c:237` | `proc_misc_d_revalidate` `:221` | `-ECHILD` at `fs/proc/generic.c:224-225` |
| `proc_net_dentry_ops` `fs/proc/generic.c:358` | `proc_net_d_revalidate` `:352` | unconditional `return 0` (`:355`) — always invalidate, RCU-safe by construction |

`->permission`: `proc_pid_permission` (`fs/proc/base.c:3427`), `proc_fd_permission`
(`fs/proc/fd.c:326`), `proc_sys_permission` (`fs/proc/proc_sysctl.c:873`). **None of them
checks `MAY_NOT_BLOCK` or returns `-ECHILD`** — they rely on being RCU-safe.

`->getattr`: seven variants (`pid_getattr` `fs/proc/base.c:1997`, `proc_task_getattr` `:3939`,
`proc_fd_getattr` `fs/proc/fd.c:345`, `proc_getattr` `fs/proc/generic.c:139`,
`proc_sys_getattr` `fs/proc/proc_sysctl.c:838`, `proc_root_getattr` `fs/proc/root.c:406`,
`proc_tgid_net_getattr` `fs/proc/proc_net.c:311`). **No `AT_STATX_*` symbol appears anywhere
in `fs/proc/`** — the sync flags are accepted and ignored.

`f_path` in `fs/proc/`: all **reads**. Two of them take a reference on *another* file's path:
`fs/proc/fd.c:183-184` (`*path = fd_file->f_path; path_get(&fd_file->f_path);`) and
`fs/proc/base.c:1768-1769` (same for `exe_file`), both released by the caller. `proc_reg_open`
takes `use_pde(pde)`, a PDE usage count, not a dentry/mnt/inode reference.

### sysfs / kernfs

`kernfs_dops` (`fs/kernfs/dir.c:1244-1246`) is installed for every kernfs-backed filesystem,
sysfs included, via `set_default_d_op(sb, &kernfs_dops)` at `fs/kernfs/mount.c:322`.
`kernfs_dop_revalidate` **never works in RCU-walk**, `fs/kernfs/dir.c:1171-1178`:

```c
static int kernfs_dop_revalidate(struct inode *dir, const struct qstr *name,
				 struct dentry *dentry, unsigned int flags)
{
	struct kernfs_node *kn, *parent;
	struct kernfs_root *root;

	if (flags & LOOKUP_RCU)
		return -ECHILD;
```

It must: both branches take `down_read(&root->kernfs_rwsem)`. Consequence: **every sysfs path
component forces a drop out of RCU-walk.**

`->permission`: `kernfs_iop_permission` (`fs/kernfs/inode.c:273`) also bails —
`if (mask & MAY_NOT_BLOCK) return -ECHILD;` at `fs/kernfs/inode.c:280-281`.

`->getattr`: `kernfs_iop_getattr` (`fs/kernfs/inode.c:183`) — `kernfs_refresh_inode` +
`generic_fillattr` under the rwsem; `query_flags` is a parameter at `:184` but is never
examined. **No `AT_STATX_*` in `fs/kernfs/` or `fs/sysfs/`.**

One thing worth flagging even though it is not `f_path`: `sysfs_kf_bin_open`
(registered as a **`kernfs_ops.open`**, `fs/sysfs/file.c:272`) **writes `of->file->f_mapping`**,
deliberately decoupling `f_mapping` from `f_path.dentry->d_inode->i_mapping`. Any redesign
that assumes those two stay in step will be wrong here.

`f_path` in kernfs: two reads, `fs/kernfs/file.c:863` and `fs/kernfs/dir.c:1972`. **None in
`fs/sysfs/` at all.**

## 13. overlayfs

The most structurally unusual filesystem in the set, and the one that most constrains a
redesign — but *not* because it violates the `f_path` rule. It does not.

* `->atomic_open`: **not found.** Zero hits for `atomic_open` in `fs/overlayfs/`.
* **Zero `__f_path` hits and zero `f_path` writes in `fs/overlayfs/`.** Every one of the
  thirteen `f_path` references is a read.

### 13.1 `->open` builds a second `struct file` at a different path

`ovl_open` (`fs/overlayfs/file.c:198`, registered `:650`) writes only `file->f_flags`
(`fs/overlayfs/file.c:216`) and `file->private_data` (`:232`). It reads `f_path.dentry`
through `file_dentry(file)` at `:200`. The real work is:

```c
	ovl_path_realdata(dentry, &realpath);
	if (!realpath.dentry)
		return -EIO;

	realfile = ovl_open_realfile(file, &realpath);
```

(`fs/overlayfs/file.c:218-222`). `ovl_open_realfile` (`fs/overlayfs/file.c:27`) ends in
`backing_file_open(file, flags, realpath, current_cred())` at `fs/overlayfs/file.c:51`.

`backing_file_open` (`fs/backing-file.c:34-55`) is the mechanism:

```c
	const struct path *user_path = file_user_path(user_file);
	...
	f = alloc_empty_backing_file(flags, cred, user_file);
	if (IS_ERR(f))
		return f;

	path_get(user_path);
	backing_file_set_user_path(f, user_path);
	error = vfs_open(real_path, f);
```

Its kerneldoc at `fs/backing-file.c:26-32` states the intent outright: the stacked file's path
is stored **alongside** the file, in a container (`struct backing_file`,
`fs/file_table.c:51-60`), retrievable with `backing_file_user_path()`
(`fs/file_table.c:64-68`) — rather than by mutating `f_path`.

So one open of an overlayfs regular file produces:

| | overlay `file` | `realfile` |
| --- | --- | --- |
| `f_path` | the overlay path, set by `path_openat` | the **real** upper/lower path, set by `vfs_open()` at `fs/open.c:1100` |
| `f_mode` | normal | `FMODE_BACKING \| FMODE_NOACCOUNT` (`fs/file_table.c:343`) |
| user-visible path | `&f_path` | `backing_file_user_path()` — a *second, refcounted* copy of the overlay path |
| freed by | fd table | `ovl_release` → `ovl_file_free` → `fput(of->realfile)` (`fs/overlayfs/file.c:108`) |

**A single overlayfs open therefore holds two references on the overlay `(dentry, mnt)` pair**
— one in the overlay file's `f_path` (taken at `fs/open.c:941`) and one in the backing file's
`user_path` (taken at `fs/backing-file.c:46`, released in `backing_file_free`,
`fs/file_table.c:91`) — plus one on the real pair.

`ovl_dir_open` (`fs/overlayfs/readdir.c:1040`, registered `:1068`) does the same thing with a
**plain** file rather than a backing file: `ovl_path_open()` (`fs/overlayfs/util.c:657`) ends
in `dentry_open()`. So a directory's realfile has no `user_path` and no `FMODE_BACKING`.
Both regular files and directories may lazily acquire a **third** file after copy-up
(`of->upperfile`, `fs/overlayfs/file.c:145`; `od->upperfile` via `ovl_dir_real_file`).

### 13.2 `ovl_tmpfile` and `ovl_dummy_open`

`fs/overlayfs/dir.c:1423-1471`, registered `.tmpfile` at `fs/overlayfs/dir.c:1489`:

```c
	err = -EIO;
	if (WARN_ON(inode != d_inode(dentry)))
		goto put_realfile;

	/* inode reference was transferred to dentry */
	inode = NULL;
	err = finish_open(file, dentry, ovl_dummy_open);
put_realfile:
	/* Without FMODE_OPENED ->release() won't be called on @file */
	if (!(file->f_mode & FMODE_OPENED))
		ovl_file_free(file->private_data);
```

`ovl_dummy_open` is three lines, `fs/overlayfs/dir.c:1418-1421`, returning 0.

Why it exists: `finish_open`'s third argument **overrides** `f_op->open`
(`fs/open.c:993-994`). With `NULL`, `do_dentry_open` would call `ovl_open`
(`fs/overlayfs/file.c:650`), which would open a *second, wrong* realfile through the normal
realpath lookup. `ovl_tmpfile` has already created the correct realfile inside
`ovl_create_tmpfile` (`fs/overlayfs/dir.c:1390`, via `backing_tmpfile_open`) and stashed it in
`file->private_data`, so it substitutes a no-op `->open` to suppress `ovl_open` while still
getting the rest of `do_dentry_open` — `path_get`, `fops_get`, `security_file_open`,
`FMODE_OPENED`.

The `put_realfile:` label (`fs/overlayfs/dir.c:1463-1466`) is the interesting part for a
redesign: **overlayfs manually cleans up its `private_data` when `FMODE_OPENED` is clear**,
because `__fput` will not call `->release` in that case (`fs/file_table.c:493-494`). Any
change that alters when `FMODE_OPENED` is set relative to the hook's return must keep this
observable.

The dentry passed to `finish_open` at `fs/overlayfs/dir.c:1462` is `file->f_path.dentry`
itself (read at `:1427`) — no reference is taken or dropped, matching `finish_open`'s
"reference is not consumed" contract.

`ovl_create_tmpfile` reads the *real* file's path: `fs/overlayfs/dir.c:1405` —
`newdentry = dget(realfile->f_path.dentry);` — consumed by `ovl_instantiate` on success,
`dput` at `:1409` otherwise. `ovl_instantiate` calls **`d_mark_tmpfile`** (not `d_tmpfile`) at
`fs/overlayfs/dir.c:335`, which rewrites the dentry's name in place (`fs/dcache.c:3364-3377`)
— see §14.2.

### 13.3 RCU-walk, `->permission`, `->getattr`

`ovl_dentry_operations` (`fs/overlayfs/super.c:166-170`) has `.d_revalidate`
(`ovl_dentry_revalidate`, `:152`) and `.d_weak_revalidate` (`:158`), both funnelling into
`ovl_dentry_revalidate_common` (`:120`) → `ovl_revalidate_real` (`:83`).

**Overlayfs is RCU-walk-capable and forwards `flags` verbatim to the underlying layers'
`->d_revalidate`** (`fs/overlayfs/super.c:97-114`), so it *inherits* the lower filesystem's
RCU capability: over sysfs it always gets `-ECHILD`, over ext4 it never even runs. It
deliberately skips `d_invalidate()` in RCU mode (`fs/overlayfs/super.c:111-113`). The
`DCACHE_OP_REVALIDATE` flags are propagated up from the real dentries in
`ovl_dentry_init_flags` (`fs/overlayfs/util.c:185-198`), so when no layer needs revalidation
overlayfs's hooks are never invoked at all.

`ovl_permission` (`fs/overlayfs/inode.c:306`) does **not** reject `MAY_NOT_BLOCK` outright; it
returns `-ECHILD` only when the real inode cannot be resolved (`fs/overlayfs/inode.c:314-319`)
and otherwise forwards `mask` including `MAY_NOT_BLOCK` to the real filesystem.

`ovl_getattr` (`fs/overlayfs/inode.c:171`) issues **up to three** `vfs_getattr_nosec` calls:
the real layer with the caller's full `request_mask` and `query_flags`
(`fs/overlayfs/inode.c:188-191`); the lower origin narrowed to
`STATX_INO|STATX_BLOCKS|STATX_NLINK` (`:208-216`); and lowerdata narrowed to `STATX_BLOCKS`
(`:260-274`), with a size-based estimate when lowerdata is not resolved. `AT_STATX_DONT_SYNC`
appears **nowhere** in `fs/overlayfs/` — the sync flags are forwarded unmodified and honoured
by whichever filesystem is underneath.

### 13.4 Different dentry?

`ovl_lookup` ends in `return d_splice_alias(ctx.inode, dentry);` (`fs/overlayfs/namei.c:1382`),
so **yes for `->lookup`**. `->create`/`->mkdir`/etc. all end in a plain `d_instantiate` on the
caller's dentry (`fs/overlayfs/dir.c:337`). `->tmpfile` keeps `file->f_path.dentry` and guards
against substitution with `WARN_ON(inode != d_inode(dentry))` at `fs/overlayfs/dir.c:1457`.
There is an acknowledged hazard documented at `fs/overlayfs/dir.c:310-322` about
`ovl_get_inode()` returning a cached inode different from the preallocated one.

## 14. cifs / smb client

The filesystem that most constrains the redesign, for three separate reasons.

### 14.1 It rewrites `file->f_op` — the only filesystem in the tree that does

A tree-wide sweep for assignments to `f_op` outside core VFS
(`fs/file_table.c:210`, `:379`; `fs/open.c:950`, `:967`) finds **six**, all in cifs:

| site | when | consequence |
| --- | --- | --- |
| `fs/smb/client/file.c:1098`, `:1100` | inside `cifs_open` (`fs/smb/client/file.c:1051`), i.e. *inside* `do_dentry_open` | before `FMODE_OPENED`; the `FMODE_CAN_*` derivation at `fs/open.c:1001-1011` sees the new `f_op` |
| `fs/smb/client/dir.c:612`, `:614` | in `cifs_atomic_open`, **after** `finish_open` returned (`:601`) | `FMODE_OPENED` already set and `FMODE_CAN_READ/WRITE/LSEEK/CAN_ODIRECT` already derived from the *old* `f_op` |
| `fs/smb/client/dir.c:1150`, `:1152` | in `cifs_tmpfile`, **after** `finish_open` returned (`:1143`) | same |

None of the six is paired with `fops_put`/`fops_get`. In practice the replacement structs are
in the same module and expose the same `read_iter`/`write_iter`/`release`
(`fs/smb/client/cifsfs.c:1664`, `:1704`, `:1760`), so the derived `FMODE_CAN_*` bits and the
module reference happen to come out right — but this is the one place where the `f_op` a file
ends up with is not the one `do_dentry_open` installed.

### 14.2 `cifs_tmpfile` rewrites the dentry's name in place

`cifs_tmpfile` (`fs/smb/client/dir.c:1062`, registered `fs/smb/client/cifsfs.c:1246`) reads
`file->f_path.dentry` at `fs/smb/client/dir.c:1065` and then calls
`d_mark_tmpfile_name(file, &QSTR_LEN(name, namelen))` at `:1121`. That helper
(`fs/dcache.c:3380-3400`) is used **only** by cifs and mutates the dentry that `f_path` points
at, under `d_lock`:

```c
	spin_lock(&dentry->d_parent->d_lock);
	spin_lock_nested(&dentry->d_lock, DENTRY_D_LOCK_NESTED);
	dentry->__d_name.len = name->len;
	memcpy(dname, name->name, name->len);
	dname[name->len] = '\0';
```

It refuses external names, positive dentries and non-unlinked dentries
(`fs/dcache.c:3385-3388`). The sibling `d_mark_tmpfile` (`fs/dcache.c:3364-3377`) does the
same thing with `#<ino>` and `BUG_ON`s instead; it is used by `d_tmpfile`
(`fs/dcache.c:3403-3410`) and by overlayfs (`fs/overlayfs/dir.c:335`). Neither changes any
refcount.

### 14.3 It can fail after `FMODE_OPENED` is set

Both cifs open paths do real, failure-capable work after `finish_open` succeeded:

* `cifs_atomic_open` — `fs/smb/client/dir.c:617-624`: `cifs_new_fileinfo` returning NULL
  produces `-ENOMEM` with `FMODE_OPENED` set.
* `cifs_tmpfile` — `fs/smb/client/dir.c:1155-1159` (same), and `set_tmpfile_attr` at `:1161`.

### 14.4 Different dentry

`fs/smb/client/dir.c:590-596`:

```c
	if (d_in_lookup(direntry)) {
		alias = d_splice_alias(inode, direntry);
		if (!IS_ERR_OR_NULL(alias))
			direntry = alias;
	} else {
		d_instantiate(direntry, inode);
	}
```

followed by `finish_open(file, direntry, generic_file_open)` at `:601`. So `finish_open` can be
handed the alias rather than the dentry the VFS passed in, and `atomic_open()` will then
`dput` the original and `dget` the opened one (`fs/namei.c:4375-4378`). There is no `dput` of
`alias` anywhere in `cifs_atomic_open` (verified: no `dget`/`dput` at all between
`fs/smb/client/dir.c:505` and `:636`). In practice the branch is unreachable for this call
site because `d_splice_alias` only returns non-NULL for `S_ISDIR` inodes
(`fs/dcache.c:3251-3288`; the non-directory path falls to `__d_add` and `return NULL` at
`:3291-3292`) and this is the `O_CREAT` path for a regular file — but the *code shape* permits
a substituted dentry, and any ownership change must not make that shape start leaking.

### 14.5 Other

* `finish_no_open(file, cifs_lookup(dir, direntry, 0))` at `fs/smb/client/dir.c:556` — the
  lookup's reference is consumed by the helper.
* `->d_revalidate`: `cifs_d_revalidate` (`fs/smb/client/dir.c:869`), registered at `:967` and
  `:1206`. **Never RCU-capable** — `if (flags & LOOKUP_RCU) return -ECHILD;` at `:872-873`.
* `->getattr`: `cifs_getattr` (`fs/smb/client/inode.c:2940`). Handles `AT_STATX_FORCE_SYNC`
  (`:2967`) and `AT_STATX_DONT_SYNC` (`:2975`), sets `STATX_BTIME` (`:2988`) and
  `STATX_ATTR_COMPRESSED|ENCRYPTED` (`:2993-2997`). Attribute cache is time-based:
  `time_in_range(jiffies, cifs_i->time, ...)` at `fs/smb/client/inode.c:2766` and `:2772`.
* Round trips: `cifs_atomic_open` → `cifs_do_create` (`fs/smb/client/dir.c:583`) →
  `__cifs_do_create` (`:197`) — one SMB2 CREATE. `cifs_tmpfile` retries the CREATE with a new
  generated name up to 16 times on `-EEXIST` (`fs/smb/client/dir.c:1114-1134`).

## 15. NFS

Two separate `->atomic_open` implementations: `nfs_atomic_open` for v4
(`fs/nfs/nfs4proc.c:10710`) and `nfs_atomic_open_v23` for v2/v3 (`fs/nfs/proc.c:711`,
`fs/nfs/nfs3proc.c:1044`).

### 15.1 NFSv4 can switch the dentry under itself

`fs/nfs/dir.c:2159-2168`:

```c
	if (!(open_flags & O_CREAT) && !d_in_lookup(dentry)) {
		d_drop(dentry);
		switched = true;
		dentry = d_alloc_parallel(dentry->d_parent,
					  &dentry->d_name);
		if (IS_ERR(dentry))
			return PTR_ERR(dentry);
		if (unlikely(!d_in_lookup(dentry)))
			return finish_no_open(file, dentry);
	}
```

and then at `fs/nfs/dir.c:2216` it calls `nfs_finish_open(ctx, ctx->dentry, file, open_flags)`
— **`ctx->dentry`, not the local `dentry`**. The `out:` label at `fs/nfs/dir.c:2219-2223`
`d_lookup_done()`s and `dput()`s the switched dentry, leaving `file->f_path.dentry`'s only
reference the one `do_dentry_open` took at `fs/open.c:941`.

The `no_open:` path (`fs/nfs/dir.c:2227-2254`) is even more involved, and can return a dentry
from `nfs_lookup`, the original, or an error, all through
`finish_no_open(file, res)` at `fs/nfs/dir.c:2253`.

### 15.2 NFS holds a second, independent dentry reference for the life of the open file

`alloc_nfs_open_context` (`fs/nfs/inode.c:1195`) does `nfs_sb_active(dentry->d_sb)` at `:1204`
and `ctx->dentry = dget(dentry);` at `fs/nfs/inode.c:1205`; `__put_nfs_open_context` does the
matching `dput(ctx->dentry)` at `fs/nfs/inode.c:1249`. `nfs_file_set_open_context`
(`fs/nfs/inode.c:1287`) attaches that context to the file, so **the context outlives
`->atomic_open` holding its own dentry reference plus an active superblock reference**,
entirely independent of `f_path`.

### 15.3 It can fail *after* `finish_open()` succeeded

`nfs_finish_open`, `fs/nfs/dir.c:2087-2102`:

```c
	err = finish_open(file, dentry, do_open);
	if (err)
		goto out;
	if (S_ISREG(file_inode(file)->i_mode))
		nfs_file_set_open_context(file, ctx);
	else
		err = -EOPENSTALE;
```

`-EOPENSTALE` is returned with `FMODE_OPENED` set (`fs/nfs/dir.c:2099`). `path_openat` then
maps it to `-ECHILD`/`-ESTALE` (`fs/namei.c:5010-5015`) and `do_file_open` retries
(`fs/namei.c:5032-5033`).

### 15.4 NFSv4's `->open` unhashes the dentry `f_path` points at

`nfs4_file_open` (`fs/nfs/nfs4file.c:29`, registered `:442`) is called from inside
`do_dentry_open`. It reads `file_dentry(filp)` at `fs/nfs/nfs4file.c:32` and `:60`, and takes
`parent = dget_parent(dentry)` at `:57` to find the directory inode — so **the dentry handed
to `finish_open`/`vfs_open` must be properly parented at `->open` time**. On several errors it
does, `fs/nfs/nfs4file.c:103-106`:

```c
out_drop:
	d_drop(dentry);
	err = -EOPENSTALE;
	goto out_put_ctx;
```

i.e. it unhashes the very dentry in `f_path` and fails, relying on the VFS retry loop.
It also mutates `filp->f_mode` and `filp->f_flags` at `fs/nfs/nfs4file.c:93-95`.

### 15.5 NFSv2/v3

`nfs_atomic_open_v23` (`fs/nfs/dir.c:2266-2302`) is much simpler: `nfs_do_create` then either
`finish_no_open(file, NULL)` (`:2332`, for a non-regular result) or `finish_open(file, dentry,
NULL)` (`:2334`), or a lookup followed by `finish_no_open(file, res)` (`:2345`). It sets
`FMODE_CREATED` at `fs/nfs/dir.c:2333`, before `finish_open`.

### 15.6 RCU-walk, stat, round trips

* `->d_revalidate`: `nfs_lookup_revalidate` (`fs/nfs/dir.c:1846`, registered `:1979`) and
  `nfs4_lookup_revalidate` (`:2258`, registered `:2067`). Both are **partially** RCU-capable:
  the verifier/delegation fast path succeeds in RCU mode (`fs/nfs/dir.c:1801-1814`), and the
  v4 variant has an explicit open-intent shortcut, `fs/nfs/dir.c:2297-2298`:

```c
	/* Let f_op->open() actually open (and revalidate) the file */
	return 1;
```

  Anything needing a round trip returns `-ECHILD` (`fs/nfs/dir.c:1816-1817`, `:1826-1827`,
  `:2300-2301`).
* `->permission`: `nfs_permission` (`fs/nfs/dir.c:3396`) is RCU-capable through the cached
  access list — `may_block = (mask & MAY_NOT_BLOCK) == 0` at `fs/nfs/dir.c:3311` — and returns
  `-ECHILD` only when it must go to the server (`:3387-3388`, `:3441-3442`). For a regular
  file with `MAY_OPEN` on a server with `NFS_CAP_ATOMIC_OPEN` it short-circuits to 0
  (`fs/nfs/dir.c:3415-3417`), deferring the check to the OPEN itself.
* `->getattr`: `nfs_getattr` (`fs/nfs/inode.c:958`). It **honours `AT_STATX_DONT_SYNC`**
  explicitly, `fs/nfs/inode.c:980-984`, unless `AT_STATX_FORCE_SYNC` is also set (`:966`).
  It narrows `request_mask` to what NFS can answer (`:972-975`), flushes writeback when
  c/mtime or the change cookie are requested (`:987-993`), and reports
  `STATX_ATTR_CHANGE_MONOTONIC` (`:1052-1054`) and `STATX_DIOALIGN|STATX_DIO_READ_ALIGN`
  (`:1066-1068`).
* Attribute cache: time-based with exponential back-off —
  `nfs_attribute_cache_expired` (`fs/nfs/inode.c:1438`), `attrtimeo` doubling at
  `fs/nfs/inode.c:2491-2494`, bounded by `NFS_MAXATTRTIMEO`.
* Round trips: NFSv4 open is a single compound via `NFS_PROTO(dir)->open_context`
  (`fs/nfs/dir.c:2182`) → `nfs4_atomic_open` (`fs/nfs/nfs4proc.c:3841`, registered `:10801`).
  A cached-positive-dentry open instead goes through `nfs4_file_open` (§15.4), also one
  compound. NFSv3 does CREATE then possibly LOOKUP (`fs/nfs/dir.c:2286`, `:2343`).
* `->tmpfile`: **not found** for any NFS version.

## 16. ceph

* `ceph_atomic_open` — `fs/ceph/file.c:795`, registered `fs/ceph/dir.c:2271` in
  `ceph_dir_iops`.
* **Reads `f_path.mnt` on entry**: `fs/ceph/file.c:798` —
  `struct mnt_idmap *idmap = file_mnt_idmap(file);`.
* **Can substitute the dentry**, `fs/ceph/file.c:958-965`:

```c
	if (err == -ENOENT) {
		dentry = ceph_handle_snapdir(req, dentry);
		if (IS_ERR(dentry)) {
			err = PTR_ERR(dentry);
			goto out_req;
		}
		err = 0;
	}
```

  `ceph_handle_snapdir` (`fs/ceph/dir.c:727-748`) does `res = d_splice_alias(inode, dentry);`
  at `:740` and `if (res) dentry = res;` at `:744-745`. The substituted dentry is then passed
  to `finish_open(file, dentry, ceph_open)` at `fs/ceph/file.c:1005`, and `atomic_open()`
  reconciles the references at `fs/namei.c:4375-4378`. This branch is only reachable when the
  inode is a directory (`fs/dcache.c:3251-3288`).
* Three call sites into the helpers: `finish_open` in the async-create completion
  (`fs/ceph/file.c:781`) and the normal path (`:1005`), `finish_no_open(file, dn)` at
  `fs/ceph/file.c:983`.
* `FMODE_CREATED` is set **before** `finish_open` at `fs/ceph/file.c:780` (async path) and
  `:999` (sync path).
* `ceph_open` (`fs/ceph/file.c:379`, registered `fs/ceph/dir.c:2251`, `fs/ceph/file.c:3295`)
  works purely from the inode. It uses `d_find_alias(inode)` at `fs/ceph/file.c:416` and
  `dput(dentry)` at `:429` — a balanced, transient reference — and **never touches `f_path`**.
  Only three `f_path` reads exist in all of `fs/ceph/`: `fs/ceph/dir.c:190`, `:346`, and
  `:455` (`req->r_dentry = dget(file->f_path.dentry)` in readdir).
* `->tmpfile`: **not found.**
* `->permission`: `ceph_permission` (`fs/ceph/inode.c:3101`) — **never RCU-capable**,
  `if (mask & MAY_NOT_BLOCK) return -ECHILD;` at `fs/ceph/inode.c:3106-3107`.
* `->d_revalidate`: `ceph_d_revalidate` (`fs/ceph/dir.c:1977`, registered `:2284`). Partially
  RCU-capable: valid dentry/dir leases are checked in RCU mode and return 1
  (`fs/ceph/dir.c:2005-2013`); anything requiring an MDS round trip returns `-ECHILD`
  (`fs/ceph/dir.c:2021-2022`, and `:2006-2007` from `dentry_lease_is_valid`).
* `->getattr`: `ceph_getattr` (`fs/ceph/inode.c:3148`). **Honours `AT_STATX_DONT_SYNC`** at
  `fs/ceph/inode.c:3160-3167`, translates `request_mask` into required caps via
  `statx_to_caps` (`fs/ceph/inode.c:3117`), and reports `STATX_BTIME` (`:3176-3179`),
  `STATX_CHANGE_COOKIE` (`:3181-3183`), `STATX_ATTR_CHANGE_MONOTONIC` and
  `STATX_ATTR_ENCRYPTED` (`:3227-3231`). The "cache" is the MDS capability grant, not a timer.
* Round trips: one MDS request — `ceph_mdsc_do_request` at `fs/ceph/file.c:957` — or an
  asynchronous create (`ceph_mdsc_submit_request` at `:931` followed by
  `ceph_finish_async_create` at `:933`).

## 17. 9p

Two implementations, both structured identically: `v9fs_vfs_atomic_open`
(`fs/9p/vfs_inode.c:768`, registered `:1368` and `:1383`) and `v9fs_vfs_atomic_open_dotl`
(`fs/9p/vfs_inode_dotl.c:226`, registered `:963`).

* Both open with the standard preamble — lookup if `d_in_lookup`, then
  `finish_no_open(file, res)`; `finish_no_open(file, NULL)` if not `O_CREAT`
  (`fs/9p/vfs_inode.c:779-787`, `fs/9p/vfs_inode_dotl.c:241-249`).
* Both call `finish_open(file, dentry, generic_file_open)` with **the dentry they were given**
  (`fs/9p/vfs_inode.c:805`, `fs/9p/vfs_inode_dotl.c:316`).
* **Both set `FMODE_CREATED` *after* `finish_open`** — `fs/9p/vfs_inode.c:821` and
  `fs/9p/vfs_inode_dotl.c:329` — unlike gfs2, ceph and NFSv3, which set it before.
* Both attach state after the open succeeded: `file->private_data = fid`
  (`fs/9p/vfs_inode.c:811`, `fs/9p/vfs_inode_dotl.c:319`), plus `v9fs_open_fid_add`.
  `fs/9p/vfs_inode.c:806-809` shows the failure handling: `p9_fid_put(fid)` if `finish_open`
  failed.
* **Zero `f_path` references anywhere in `fs/9p/`.**
* `->tmpfile`: **not found.** `->permission`: **not found.**
* `->d_revalidate`: `v9fs_lookup_revalidate` (registered `fs/9p/vfs_dentry.c:213`) —
  **never RCU-capable**, `if (flags & LOOKUP_RCU) return -ECHILD;` at
  `fs/9p/vfs_dentry.c:145-146`.
* `->getattr`: `v9fs_vfs_getattr_dotl` (`fs/9p/vfs_inode_dotl.c:417`, registered `:972`,
  `:981`, `:991`) and `v9fs_vfs_getattr` (registered `fs/9p/vfs_inode.c:1376` etc.).
  **9p ignores the query flags entirely** — the `flags` parameter at
  `fs/9p/vfs_inode_dotl.c:419` is never read, so **`AT_STATX_DONT_SYNC` is not honoured**.
  Caching is by mount option: `CACHE_META|CACHE_LOOSE` short-circuits to `generic_fillattr`
  (`fs/9p/vfs_inode_dotl.c:429-431`); otherwise it issues an unconditional
  `p9_client_getattr_dotl(fid, P9_STATS_ALL)` (`:449`) — no timeout-based cache.
* Round trips: the `.L` create-open costs **three or more** — `v9fs_parent_fid`
  (`fs/9p/vfs_inode_dotl.c:257`), `clone_fid` (a Twalk, `:265`), `p9_client_create_dotl`
  (`:288`), and `p9_client_walk` (`:297`).

## 18. gfs2

* `gfs2_atomic_open` — `fs/gfs2/inode.c:1383`, registered `fs/gfs2/inode.c:2325` in
  `gfs2_dir_iops`.
* **Unusual control flow**: it calls `__gfs2_lookup(dir, dentry, file)` (`fs/gfs2/inode.c:1390`)
  and then inspects the *file* to see whether the lookup opened it, `fs/gfs2/inode.c:1391-1398`:

```c
		struct dentry *d = __gfs2_lookup(dir, dentry, file);
		if (file->f_mode & FMODE_OPENED) {
			if (IS_ERR(d))
				return PTR_ERR(d);
			dput(d);
			return excl && (flags & O_CREAT) ? -EEXIST : 0;
		}
		if (d || d_really_is_positive(dentry))
			return finish_no_open(file, d);
```

  So **the same returned dentry `d` is either `dput`ed (open happened) or handed to
  `finish_no_open` (which consumes it)** — the ownership branch is decided by an `f_mode` bit
  rather than by the return value.
* `__gfs2_lookup` (`fs/gfs2/inode.c:986`) calls `d = d_splice_alias(inode, dentry)` at
  `fs/gfs2/inode.c:1006` and then `finish_open(file, dentry, gfs2_open_common)` at `:1012` —
  note it passes **`dentry`, not `d`**. This is safe only because the `finish_open` is gated on
  `S_ISREG(inode->i_mode)` (`fs/gfs2/inode.c:1011`) and `d_splice_alias` returns non-NULL only
  for `S_ISDIR` (`fs/dcache.c:3251-3288`), so `d == NULL` whenever the `finish_open` runs. A
  redesign that changes that gating would expose a real mismatch here.
* Three more `finish_open` sites, all in `gfs2_create_inode`: `fs/gfs2/inode.c:758` (existing
  regular file), `:760` (`finish_no_open(file, NULL)` for a non-regular one), and `:907` after
  `d_instantiate_new`. `FMODE_CREATED` is set **before** `finish_open` at `fs/gfs2/inode.c:906`.
* **Zero `f_path` references anywhere in `fs/gfs2/`.**
* `->tmpfile`: **not found.**
* `->permission`: `gfs2_permission` (registered `fs/gfs2/inode.c:2295`, `:2317`, `:2332`).
  Handles `MAY_NOT_BLOCK` explicitly but always bails — `fs/gfs2/inode.c:1984-1985`:
  `if (may_not_block) return -ECHILD;` when the glock is not already held, and `:1980-1981`
  when the inode is being torn down. So in practice **every gfs2 `->permission` in RCU-walk
  that does not already hold the glock drops out.**
* `->d_revalidate`: `gfs2_drevalidate` (registered `fs/gfs2/dentry.c:99`) — **never
  RCU-capable**, `fs/gfs2/dentry.c:46-47`.
* `->getattr`: `gfs2_getattr` (registered `fs/gfs2/inode.c:2297`, `:2319`, `:2334`).
  **`AT_STATX_DONT_SYNC` is not handled** — the symbol does not appear in `fs/gfs2/`.

## 19. fuse (and virtiofs)

* `fuse_atomic_open` — `fs/fuse/dir.c:939`, registered `fs/fuse/dir.c:2425` in
  `fuse_dir_inode_operations`. **virtiofs shares this table entirely**: `fs/fuse/virtio_fs.c`
  declares no `inode_operations`, `atomic_open`, `tmpfile` or `->open` of its own.
* **Reads `f_path.mnt` on entry**: `fs/fuse/dir.c:944` —
  `struct mnt_idmap *idmap = file_mnt_idmap(file);`.
* **Sets `FMODE_CREATED` before doing the create**, `fs/fuse/dir.c:960`:

```c
	/* Only creates */
	file->f_mode |= FMODE_CREATED;

	if (fc->no_create)
		goto mknod;

	err = fuse_create_open(idmap, dir, entry, file, flags, mode, FUSE_CREATE);
```

  So on a failing `fuse_create_open` the file is returned with `FMODE_CREATED` set and
  `FMODE_OPENED` clear. Note `open_last_lookups` treats `FMODE_CREATED` the same as
  `FMODE_OPENED` for the dentry swap (`fs/namei.c:4771`).
* `fuse_create_open` calls `finish_open(file, entry, fuse_finish_open)` at `fs/fuse/dir.c:916`,
  having already set `file->private_data = ff` at `:915`. On failure it does
  `fuse_sync_release(fi, ff, flags)` (`fs/fuse/dir.c:918-920`) — the same
  "clean up private_data ourselves because `->release` will not run" pattern overlayfs uses.
* `->tmpfile`: `fuse_tmpfile` (`fs/fuse/dir.c:1101`, registered `:2426`) **reads
  `f_path.dentry`** at `fs/fuse/dir.c:1110`:

```c
	err = fuse_create_open(idmap, dir, file->f_path.dentry, file,
			       file->f_flags, mode, FUSE_TMPFILE);
```

  so it goes through `finish_open`, not `finish_open_simple`.
* `f_path` references in `fs/fuse/`: five, all reads — `fs/fuse/readdir.c:159`,
  `fs/fuse/dir.c:1110`, `fs/fuse/backing.c:107`, `:108`, and `fs/fuse/passthrough.c:171`
  (`&fb->file->f_path`, for the passthrough backing file).
* `fuse_open` (`fs/fuse/file.c:250`, registered `:3081`) does not touch `f_path`; it may call
  `fuse_sync_release` if `fuse_finish_open` fails (`fs/fuse/file.c:285-286`).
* `->permission`: `fuse_permission` (`fs/fuse/dir.c`, registered `:2428`, `:2451`). Contains
  both a `BUG_ON(mask & MAY_NOT_BLOCK)` at `fs/fuse/dir.c:1715` (in a helper reached only in
  blocking context) and a `-ECHILD` return at `:1745`.
* `->d_revalidate`: `fuse_dentry_revalidate` (`fs/fuse/dir.c:391`, registered `:539`).
  **Partially RCU-capable**: while the entry timeout has not expired it validates in RCU mode
  and returns 1 (`fs/fuse/dir.c:461-470`); when a FUSE `LOOKUP` round trip is needed it
  returns `-ECHILD` (`fs/fuse/dir.c:419-421`). Also drops out for a readdirplus hint
  (`:463-465`).
* `->getattr`: `fuse_getattr` (`fs/fuse/dir.c:2389`, registered `:2429`, `:2452`, `:2464`).
  **Honours both sync flags** — `AT_STATX_FORCE_SYNC` at `fs/fuse/dir.c:1559` and
  `AT_STATX_DONT_SYNC` at `:1561`. The attribute cache is per-inode with a server-supplied
  timeout (`ATTR_TIMEOUT`, `fs/fuse/dir.c:458`) and an `attr_version` counter
  (`fs/fuse/inode.c:234`, `:343`). If the process is not allowed, it returns `st_dev` only
  when `request_mask == 0` (`fs/fuse/dir.c:2400-2408`).
* Round trips: one `FUSE_CREATE` (or `FUSE_TMPFILE`) request via
  `fuse_simple_idmap_request` at `fs/fuse/dir.c:886`, with a `FUSE_MKNOD` + separate open
  fallback when the server returns `-ENOSYS` (`fs/fuse/dir.c:965-977`).

## 20. vboxsf

* `vboxsf_dir_atomic_open` — `fs/vboxsf/dir.c:313`, registered `fs/vboxsf/dir.c:473` in
  `vboxsf_dir_iops`. Standard shape: lookup + `finish_no_open(file, res)` (`:324`),
  `finish_no_open(file, NULL)` if not `O_CREAT` (`:329`), then create and
  `finish_open(file, dentry, generic_file_open)` (`:341`) with the dentry it was given.
* Like 9p, it sets `FMODE_CREATED` **after** `finish_open` (`fs/vboxsf/dir.c:349`) and attaches
  `file->private_data = sf_handle` at `:348`. On `finish_open` failure it releases the handle
  itself (`fs/vboxsf/dir.c:342-346`).
* `->tmpfile`: **not found.** `->permission`: **not found.**
* `f_path`: the only mention in `fs/vboxsf/` is a comment at `fs/vboxsf/file.c:198`.
* `->d_revalidate`: `vboxsf_dentry_revalidate` (`fs/vboxsf/dir.c:195`, registered `:208`) —
  **never RCU-capable**, `fs/vboxsf/dir.c:198-199`.
* `->getattr`: `vboxsf_getattr` (`fs/vboxsf/utils.c:236`, registered `fs/vboxsf/file.c:224`
  and `fs/vboxsf/dir.c:478`). **Honours the full sync-type switch** —
  `fs/vboxsf/utils.c:244-253` handles `AT_STATX_DONT_SYNC` (no-op), `AT_STATX_FORCE_SYNC`
  (sets `force_restat`) and the default (`vboxsf_inode_revalidate`). It does not do any
  `STATX_` request-mask filtering beyond passing `request_mask` to `generic_fillattr` (`:257`).

## 21. bad_inode

`bad_inode_ops` (`fs/bad_inode.c:163`) registers both hooks and both fail immediately:

```c
static int bad_inode_atomic_open(struct inode *inode, struct dentry *dentry,
				 struct file *file, unsigned int open_flag,
				 umode_t create_mode)
{
	return -EIO;
}
```

(`fs/bad_inode.c:142-147`, registered `:183`), and `bad_inode_tmpfile` returning `-EIO`
(`fs/bad_inode.c:149-154`, registered `:184`).

**This is the one `->atomic_open` that returns an error without ever calling `finish_open()`
or `finish_no_open()`, leaving `f_path.dentry == DENTRY_NOT_SET`.** That is legal only because
`atomic_open()` checks `if (!error)` before inspecting `f_path.dentry`
(`fs/namei.c:4371`) and goes straight to the `if (error)` block at `fs/namei.c:4398`. Any
redesign that reads `file->f_path` unconditionally after `->atomic_open` returns will
dereference `(void *)-1UL` here. `bad_inode` also has `->permission` and `->getattr`
(`fs/bad_inode.c:175-176`), both returning `-EIO`.

---

## 22. What a reference-ownership change must validate against

Each item names the filesystem that forced it into the list and a test that would catch a
violation.

1. **`f_path` must remain populated and valid on entry to `->atomic_open`, at least `f_path.mnt`.**
   `fs/namei.c:4365-4366` seeds it; ceph (`fs/ceph/file.c:798`) and fuse (`fs/fuse/dir.c:944`)
   call `file_mnt_idmap(file)` as their first statement. *Forced by:* ceph, fuse.
   *Test:* mount ceph or fuse on an **idmapped** mount and create a file through it; a wrong
   or NULL `f_path.mnt` produces wrong ownership or an oops. `xfstests generic/633` (idmapped
   mount ownership) on fuse/virtiofs.

2. **`f_path.dentry` must be populated before `->tmpfile` runs, and must be a real, parented,
   negative, unhashed child of the parent directory with an inline name.**
   `vfs_tmpfile` guarantees it at `fs/namei.c:4886-4890`. Six filesystems read it directly:
   btrfs (`fs/btrfs/inode.c:9422`), xfs (`fs/xfs/xfs_iops.c:1258`), ubifs (`fs/ubifs/dir.c:446`),
   overlayfs (`fs/overlayfs/dir.c:1427`), fuse (`fs/fuse/dir.c:1110`),
   cifs (`fs/smb/client/dir.c:1065`). Ten more read it via `finish_open_simple`
   (`include/linux/fs.h:2601`). ubifs additionally requires `d_name` to be usable by
   `fscrypt_setup_filename`; cifs requires it to be inline and unhashed
   (`fs/dcache.c:3385-3388`). *Forced by:* btrfs, xfs, ubifs, cifs.
   *Test:* `xfstests generic/004` (O_TMPFILE) plus `generic/424` on ext4/xfs/btrfs/ubifs;
   for cifs, `open(O_TMPFILE)` on an SMB3 mount (the `-EINVAL` from `d_mark_tmpfile_name` is
   silent otherwise, only a `cifs_dbg(VFS | ONCE)` at `fs/smb/client/dir.c:1123`).

3. **`vfs_tmpfile` must keep `dput(child)` unconditional and must keep `fsnotify_open()`
   before the error check.** `fs/namei.c:4892-4897`. ext4 (`fs/ext4/namei.c:2919-2922`) and
   ubifs (`fs/ubifs/dir.c:514-524`) return an error *after* `d_tmpfile()` instantiated the
   inode onto that dentry and *without* `FMODE_OPENED`; the inode reference is then owned by
   the dentry and only that `dput` frees it. *Forced by:* ext4, ubifs.
   *Test:* fault-inject `ext4_orphan_add` / `ubifs_jnl_update` failure during `O_TMPFILE` and
   watch for an inode leak on unmount (`kmemleak`, or `fsck` finding an orphaned inode).

4. **A filesystem may call `finish_open()` with a dentry different from the one passed in, and
   the VFS must keep reconciling the references at `fs/namei.c:4375-4378`.**
   NFSv4 (`fs/nfs/dir.c:2162` + `:2216` — passes `ctx->dentry`), ceph
   (`fs/ceph/file.c:959` via `ceph_handle_snapdir`), cifs (`fs/smb/client/dir.c:591-593`).
   *Forced by:* NFSv4, ceph, cifs.
   *Test:* `ls /mnt/ceph/.snap` and open a file under it (exercises `ceph_handle_snapdir`);
   for NFSv4, open an existing file by a hashed-but-not-in-lookup dentry —
   `xfstests generic/child` style open-after-rename loops. A refcount regression shows up as a
   `dput` of a freed dentry or a "Dentry still in use" at umount.

5. **A filesystem may return `-E...` with `FMODE_OPENED` already set, and the caller must not
   assume the file is untouched.** NFS (`fs/nfs/dir.c:2099`, `-EOPENSTALE` after a successful
   `finish_open`), cifs (`fs/smb/client/dir.c:618-624`, `:1156-1159`, `-ENOMEM`). The
   `-EOPENSTALE` case is load-bearing: `path_openat` converts it
   (`fs/namei.c:5010-5015`) and `do_file_open` retries with `LOOKUP_REVAL`
   (`fs/namei.c:5032-5033`). *Forced by:* NFS, cifs.
   *Test:* NFSv4 open of a path whose server-side type changed under you (directory replaced
   by a file) — should give `ESTALE` and a clean retry, not a leaked `struct file`.
   `xfstests generic/643`-style ESTALE loops, or `nfstest_posix`.

6. **A filesystem may return an error from `->atomic_open` having called neither helper,
   leaving `f_path.dentry == DENTRY_NOT_SET` (`(void *)-1UL`).** Nothing may dereference
   `file->f_path` after `->atomic_open` without first checking the return value, as
   `fs/namei.c:4371` does. *Forced by:* `bad_inode` (`fs/bad_inode.c:142-147`), and the
   `-ENOENT` direct returns anticipated by the comment at `fs/namei.c:4404-4407`.
   *Test:* force an inode read error (`make_bad_inode`) and open a file under it — e.g. a
   corrupted ext4 image via `dm-flakey`. A regression is an immediate oops on `0xffffffffffffffff`.

7. **`FMODE_CREATED` may be set before *or* after `finish_open()`, and even on a failing path.**
   Before: gfs2 (`fs/gfs2/inode.c:906`), ceph (`fs/ceph/file.c:780`, `:999`), NFSv3
   (`fs/nfs/dir.c:2333`), cifs (`fs/smb/client/dir.c:598-599`). After: 9p
   (`fs/9p/vfs_inode.c:821`, `fs/9p/vfs_inode_dotl.c:329`), vboxsf (`fs/vboxsf/dir.c:349`).
   Before the create even runs, and left set on failure: fuse (`fs/fuse/dir.c:960`).
   `open_last_lookups` keys the dentry swap on `FMODE_OPENED | FMODE_CREATED`
   (`fs/namei.c:4771`), and `do_open` keys `O_EXCL`/permission handling on `FMODE_CREATED`
   (`fs/namei.c:4803`, `:4807`, `:4825`). *Forced by:* fuse, 9p, vboxsf.
   *Test:* `open(O_CREAT|O_EXCL)` on an existing file over fuse and 9p — must be `EEXIST`, not
   a silent success; `open(O_CREAT)` on a fuse server that fails `FUSE_CREATE` must not leave
   a stale `FMODE_CREATED` visible to `may_create_in_sticky`.

8. **`->release` is not called when `FMODE_OPENED` is clear, and three filesystems hand-roll
   the cleanup of `file->private_data` on that basis.** `fs/file_table.c:493-494`.
   overlayfs (`fs/overlayfs/dir.c:1463-1466`, with the comment spelling it out), fuse
   (`fs/fuse/dir.c:918-920`, `fs/fuse/file.c:285-286`), 9p (`fs/9p/vfs_inode.c:806-809`),
   vboxsf (`fs/vboxsf/dir.c:342-346`), cifs (`fs/smb/client/dir.c:602-607`).
   *Forced by:* overlayfs.
   *Test:* fault-inject `security_file_open` failure (LSM deny) during an overlayfs
   `O_TMPFILE` create; the upper filesystem's tmpfile must not leak. `kmemleak` plus
   `lsof`/`/proc/*/fd` on the upper mount.

9. **Two independent references on the same `(dentry, mnt)` pair can exist for one open file,
   and the file that `f_path` describes may not be the file doing the I/O.** overlayfs +
   `backing_file`: `fs/backing-file.c:38-48`, `fs/file_table.c:51-60`, `:64-68`, `:88-93`.
   `file_user_path()` (`include/linux/fs.h:2533-2537`) and `file_user_inode()` (`:2540-2545`)
   are the only correct accessors for the backing file's user-visible identity.
   *Forced by:* overlayfs (and fuse passthrough, `fs/fuse/passthrough.c:171`).
   *Test:* `mmap` a file on overlayfs and check `/proc/self/maps` shows the *overlay* path, not
   the upper path; `xfstests overlay/*` plus `overlay/069`. A regression shows up as the wrong
   path in `maps`, or a `path_put` underflow at umount of the upper layer.

10. **`->open` may unhash the dentry that `f_path` points at and then fail.**
    `nfs4_file_open` does exactly this — `d_drop(dentry); err = -EOPENSTALE;` at
    `fs/nfs/nfs4file.c:103-105` — and it reaches the parent directory with
    `dget_parent(dentry)` at `fs/nfs/nfs4file.c:57`, so the dentry must be **parented** at
    `->open` time. *Forced by:* NFSv4.
    *Test:* NFSv4 open of a cached positive dentry for a file deleted on the server; must
    produce `ESTALE` after one clean retry. `nfstest_delegation` / `generic/13` over NFSv4.

11. **A filesystem may hold its own long-lived dentry reference, independent of `f_path`, for
    the life of the open file.** NFS's open context: `dget` at `fs/nfs/inode.c:1205`,
    `nfs_sb_active` at `:1204`, `dput` at `:1249`, attached by `nfs_file_set_open_context`
    (`fs/nfs/inode.c:1287`). *Forced by:* NFS (all versions).
    *Test:* `umount -l` an NFS mount with files still open — the superblock must stay alive
    until the last `fput`. A regression is a use-after-free in `nfs_file_release`.

12. **`file->f_op` is not guaranteed to be the one `do_dentry_open()` installed.** cifs
    replaces it in three places, twice *after* `finish_open` has already derived
    `FMODE_CAN_READ`/`CAN_WRITE`/`LSEEK`/`CAN_ODIRECT` from the old one
    (`fs/smb/client/dir.c:612`, `:614`, `:1150`, `:1152`) and once inside `->open`
    (`fs/smb/client/file.c:1098`, `:1100`). None is paired with `fops_get`/`fops_put`.
    *Forced by:* cifs. *Test:* `mount -o cache=strict,directio` (i.e. `CIFS_MOUNT_STRICT_IO`)
    and `open(O_DIRECT)`; `fstat`/`lseek`/`read` must all behave. A regression is a module
    refcount imbalance found by `rmmod cifs` after such an open.

13. **`f_mapping` is not guaranteed to be `f_path.dentry->d_inode->i_mapping`.**
    `sysfs_kf_bin_open` (`fs/sysfs/file.c:272`) rewrites `of->file->f_mapping`; overlayfs's
    backing file also has `f_mapping` from the real inode while `user_path` is the overlay.
    Core VFS sets `f_mapping` from the inode at `fs/open.c:943` and `fs/file_table.c:366`.
    *Forced by:* sysfs. *Test:* `mmap` a sysfs binary attribute that supplies `f_mapping`
    (e.g. a PCI resource file) and fault a page.

14. **`->d_revalidate` RCU-capability is per-filesystem and overlayfs inherits it from its
    layers.** Always `-ECHILD`: kernfs/sysfs (`fs/kernfs/dir.c:1177-1178`), cifs
    (`fs/smb/client/dir.c:872-873`), 9p (`fs/9p/vfs_dentry.c:145-146`), gfs2
    (`fs/gfs2/dentry.c:46-47`), vboxsf (`fs/vboxsf/dir.c:198-199`). Partially RCU-capable:
    NFS (`fs/nfs/dir.c:1801-1814`, `:2297-2298`), ceph (`fs/ceph/dir.c:2005-2013`), fuse
    (`fs/fuse/dir.c:461-470`), proc's `pid_revalidate` (`fs/proc/base.c:2050-2062`).
    Overlayfs forwards `flags` verbatim to the lower layer (`fs/overlayfs/super.c:97-114`).
    `do_open` deliberately skips `complete_walk()` once the filesystem opened
    (`fs/namei.c:4798-4802`), so a redesign must not reintroduce a revalidate there.
    *Forced by:* kernfs (hard case), overlayfs (composition case).
    *Test:* `stat` a deep sysfs path in a loop under `perf stat -e ...` and confirm the
    RCU→ref-walk fallback still happens exactly once per component; overlay-on-sysfs and
    overlay-on-ext4 must both still resolve. `xfstests overlay/*` with a mixed lower stack.

15. **`->permission` in RCU-walk must keep working for the filesystems that support it and
    keep bailing for those that do not.** Always `-ECHILD`: kernfs
    (`fs/kernfs/inode.c:280-281`), ceph (`fs/ceph/inode.c:3106-3107`), gfs2 in the common case
    (`fs/gfs2/inode.c:1980-1981`, `:1984-1985`). RCU-capable: NFS via the access cache
    (`fs/nfs/dir.c:3311`, `:3415-3417`), overlayfs by forwarding `mask` down
    (`fs/overlayfs/inode.c:314-319`, `:336-337`). *Forced by:* gfs2, ceph.
    *Test:* `access(2)`/path-walk microbenchmark over a gfs2 mount — a regression that stops
    honouring `MAY_NOT_BLOCK` deadlocks on `gfs2_glock_nq_init` in RCU context.

16. **`AT_STATX_DONT_SYNC` is honoured by only six filesystems, and the redesign must not start
    assuming it is universal.** Honoured: NFS (`fs/nfs/inode.c:980-984`), ceph
    (`fs/ceph/inode.c:3160-3167`), fuse (`fs/fuse/dir.c:1559`, `:1561`), cifs
    (`fs/smb/client/inode.c:2967`, `:2975`), vboxsf (`fs/vboxsf/utils.c:244-253`), afs
    (`fs/afs/inode.c:610`). **Not honoured** (query flags accepted and ignored): ext4, ext2,
    btrfs, xfs, f2fs, ubifs, ntfs3, udf, minix, shmem, hugetlbfs, proc, kernfs/sysfs, gfs2 and
    **9p** (`fs/9p/vfs_inode_dotl.c:419` — the parameter is never read, so every `statx` with
    `AT_STATX_DONT_SYNC` still costs a `Tgetattr` round trip unless `CACHE_META|CACHE_LOOSE`
    short-circuits at `:429-431`). Overlayfs forwards the flag unmodified to the real layer
    and never inspects it. *Forced by:* 9p (worst case), overlayfs (forwarding).
    *Test:* `statx(AT_STATX_DONT_SYNC)` in a loop over a 9p and an NFS mount while counting
    on-wire operations (`tcpdump`, or `/proc/self/mountstats` for NFS); the NFS count must stay
    flat.

17. **`->tmpfile` is absent from nine of the filesystems in scope and `O_TMPFILE` must keep
    failing cleanly with `-EOPNOTSUPP` at `fs/namei.c:4884-4885`, before `d_alloc`.**
    Absent in: ntfs3, nfs, ceph, 9p, gfs2, vboxsf, proc, sysfs/kernfs, devtmpfs's own layer.
    Present but conditionally refusing: overlayfs when the upper lacks support
    (`fs/overlayfs/dir.c:1430-1432`), fuse when the server says `ENOSYS`
    (`fs/fuse/dir.c:1107-1115`), cifs below SMB2 (`fs/smb/client/dir.c:1095-1099`).
    *Forced by:* ntfs3, overlayfs. *Test:* `open(O_TMPFILE)` on each; must be `EOPNOTSUPP`
    with no dentry allocated and no `fsnotify_open`.

18. **`finish_no_open()` consumes the dentry; `finish_open()` does not. Both conventions are in
    active use in the same function.** The clearest case is gfs2
    (`fs/gfs2/inode.c:1391-1398`), where the *same* pointer is `dput`ed on one branch and
    passed to `finish_no_open` on the other, selected by an `f_mode` bit. cifs
    (`fs/smb/client/dir.c:556`) passes a lookup result straight into `finish_no_open`.
    *Forced by:* gfs2, cifs. *Test:* open an existing file over gfs2 with and without
    `O_CREAT|O_EXCL`; run under `CONFIG_DEBUG_VFS` / `CONFIG_KASAN` to catch a double-`dput`.

19. **`nd->path` and `file->f_path` are and must remain independent.** `do_dentry_open` takes
    its own pair at `fs/open.c:941`; `open_last_lookups` re-points `nd->path.dentry` to the
    child while keeping the parent's `mnt` (`fs/namei.c:4771-4775`); `terminate_walk`
    `path_put`s `nd->path` unconditionally in the non-RCU case (`fs/namei.c:849`). Any scheme
    that makes the file *borrow* the nameidata's reference must account for the fact that
    `terminate_walk` runs on both success and failure (`fs/namei.c:5001`).
    *Forced by:* the whole open path; most visible with `bad_inode` and the `-EOPENSTALE`
    retry loop. *Test:* `CONFIG_DEBUG_VFS` + a mount/umount loop under open/close load;
    a borrow bug shows as "VFS: Busy inodes after unmount" or a mount refcount underflow.

20. **`f_path` must stay `const` to filesystems.** There is currently **no violator in the
    tree** — the union at `include/linux/fs.h:1267-1270` plus the eight core writers listed in
    §0.1 are the whole story, and no filesystem calls `path_get`/`path_put` on its own
    `file->f_path` either (the only such calls outside `fs/open.c` and `fs/file_table.c` are
    `fs/proc/fd.c:184` and `fs/proc/base.c:1769`, both operating on *another* file's path).
    *Forced by:* nothing — this is the property to preserve.
    *Test:* keep the `const`/`__f_path` split. The standing regression check is

    ```
    git grep -nE '(->|\.)f_path(\.(dentry|mnt))?[[:space:]]*=[^=]' -- fs/ mm/ drivers/ include/ | grep -v __f_path
    ```

    which is **empty** on this tree. Any hit outside `fs/open.c`, `fs/namei.c` and
    `fs/file_table.c` is the regression.
