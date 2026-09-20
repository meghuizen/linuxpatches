# VFS Path-Walk / Open / Stat — Correctness Validation Rules

## 0. Intro

### 0.1 Tree under specification

| Item | Value |
|---|---|
| Source tree | `/usr/src/linux` |
| Version | `7.3.0-rc3` (`Makefile:2-5`, `NAME = Baby Opossum Posse`) |
| Commit | `518e5b794c06c0f0eb40df3e202274a66202c137` ("Merge tag 'for-7.3-rc3-tag' ... kdave/linux") |

Every rule below was read out of this tree. Line numbers are valid for this
commit only and **must be re-derived** if the tree moves. Where a construct
differs from historical mainline (this tree has `__f_path`, `vfs_lookup_open()`,
`start_dirop()`/`end_dirop()`, `may_delete_dentry()`/`may_create_dentry()`,
`lookup_inode_permission_may_exec()`, `__O_REGULAR`/`OPENAT2_REGULAR`,
`FD_ADD()`, `delayed_filename`), the rule is stated against *this* tree.

### 0.2 Purpose

This document is the acceptance criteria for a redesign of the VFS path-walk,
open and stat paths. It is the complete, explicit list of properties that must
still hold after the redesign. It is not a design document and contains no
proposals.

It is also intended as the input to a Lean formalisation, so rules are phrased
to be mechanisable: reference-ownership rules in particular are stated as
"at point X, reference R is owned by Y".

### 0.3 How to read a rule

Each rule is numbered within its category and has three parts:

```
N.  STATEMENT — one line, the property that must hold.
    Source: file:line — where the property is established or relied on.
    Break:  one line — how a refactor could silently violate it.
```

Conventions used throughout:

- **"owns a reference"** means: that entity is obliged to release it exactly
  once, and no other entity will release it.
- **"borrows"** means: valid for a bounded region, no release obligation, and
  the region's terminator must not sleep or drop the pin that makes it valid.
- **implicit** marks a rule that is nowhere written down as a rule; it is only
  encoded in the control flow of the code cited. These are the dangerous ones:
  a refactor can violate them without failing to compile and without tripping
  any assertion.
- **not established from source** means exactly that — it was looked for in
  this tree and not found. It is not a claim that the property is false.

### 0.4 Enforcement available today

Almost nothing in the VFS asserts these rules at runtime on a production
kernel. `VFS_BUG_ON`, `VFS_WARN_ON`, `VFS_WARN_ON_ONCE`, `VFS_BUG_ON_INODE` and
`VFS_WARN_ON_INODE` compile to `BUILD_BUG_ON_INVALID()` — i.e. nothing — unless
`CONFIG_DEBUG_VFS` is set (`include/linux/vfsdebug.h:34-43`; enabled forms at
`include/linux/vfsdebug.h:9-33`). There are only 6 such uses in `fs/namei.c` and
0 in `fs/dcache.c`, `fs/open.c` and `fs/file_table.c`.

The assertions that *are* always compiled in on these paths are:

- `fs/namei.c:953` — `BUG_ON(nd->inode != parent->d_inode)` in `try_to_unlazy()`.
- `fs/namei.c:3686,3688` — `BUG_ON(!inode)`, `BUG_ON(victim->d_parent->d_inode != dir)` in `may_delete_dentry()`.
- `fs/open.c:1055` — `BUG_ON(file->f_mode & FMODE_OPENED)` in `finish_open()`.
- `fs/open.c:1120` — `BUG_ON(!path->mnt)` in `dentry_open()`.
- `fs/namei.c:4393`, `fs/namei.c:5006`, `fs/open.c:968`, `fs/open.c:1023` — `WARN`s.

Consequence, and it applies to the whole of category 5: **a reference-ownership
bug on these paths is not detected by the kernel at runtime.** It manifests as a
leak (unmountable filesystem, growing `dentry`/`filp` slab) or as a
use-after-free at some unrelated later point.

---

## 1. Permission and access

### 1.1 `inode_permission()` and its call order

1.  `inode_permission()` performs its checks in a fixed order: superblock
    (`sb_permission`), immutability, unmapped-ID, filesystem/`generic_permission`,
    device cgroup, LSM. Each stage returns immediately on error.
    Source: `fs/namei.c:628-661` (stages at `:633`, `:637-641`, `:646-648`, `:650`, `:654`, `:658`).
    Break: reordering changes the *errno* userspace sees (e.g. `EROFS` vs `EACCES`
    vs `EPERM`) even when the allow/deny decision is unchanged; this is an ABI change.

2.  The read-only-superblock check precedes every other check, and applies only
    when `MAY_WRITE` is requested and only to `S_IFREG`, `S_IFDIR`, `S_IFLNK`;
    it returns `-EROFS`.
    Source: `fs/namei.c:604-614`, invoked at `fs/namei.c:633`.
    Break: hoisting the fs-specific `->permission` call above it makes writes to a
    read-only superblock fail with the filesystem's errno instead of `EROFS`, and
    lets the filesystem see a request it currently never sees.

3.  `MAY_WRITE` on an immutable inode is `-EPERM`, checked before any DAC
    evaluation and therefore not overridable by any capability.
    Source: `fs/namei.c:637-641`.
    Break: moving it after `do_inode_permission()` would let `CAP_DAC_OVERRIDE`
    grant write to an immutable inode.

4.  `MAY_WRITE` on an inode whose uid or gid does not map through the mount's
    idmap is `-EACCES`, because a subsequent mtime update would write back a
    wrong owner.
    Source: `fs/namei.c:643-648` (`HAS_UNMAPPED_ID(idmap, inode)`).
    Break: dropping it permits silent ownership corruption on idmapped mounts;
    nothing later re-checks.

5.  `security_inode_permission()` is the **last** thing `inode_permission()` does,
    and it runs only if every preceding check passed.
    Source: `fs/namei.c:658`.
    Break: calling the LSM first would expose the LSM to requests the DAC layer
    would have refused, changing audit volume and LSM policy semantics; calling it
    conditionally would silently disable LSM mediation for some opens.

6.  `devcgroup_inode_permission()` runs after `do_inode_permission()` and before
    the LSM hook.
    Source: `fs/namei.c:654-656`.
    Break: device cgroup denial would be reported after LSM auditing, or skipped.

7.  `do_inode_permission()` calls `inode->i_op->permission` if present, otherwise
    `generic_permission()`; the `IOP_FASTPERM` opflag caches "no `->permission`"
    for the inode's lifetime and is set under `i_lock`.
    Source: `fs/namei.c:578-592` (opflag set at `:585-587`).
    Break: setting `IOP_FASTPERM` without checking `i_op->permission` first, or
    caching it before `i_op` is final, permanently bypasses a filesystem's own
    permission model for that inode.

### 1.2 `generic_permission()` and `acl_permission_check()`

8.  `generic_permission()` consults capabilities **only** after
    `acl_permission_check()` has returned `-EACCES`; any other return (including
    `-ECHILD`, `-EAGAIN`, `0`) is propagated unchanged.
    Source: `fs/namei.c:521-532`.
    Break: applying `CAP_DAC_OVERRIDE` to an `-ECHILD` would grant access on the
    basis of an *incomplete* RCU-mode check.

9.  For directories: `CAP_DAC_READ_SEARCH` overrides only when `MAY_WRITE` is not
    requested; `CAP_DAC_OVERRIDE` overrides unconditionally.
    Source: `fs/namei.c:534-543`.
    Break: swapping the two lets `CAP_DAC_READ_SEARCH` grant directory write.

10. For non-directories: `CAP_DAC_READ_SEARCH` overrides only when the effective
    mask is exactly `MAY_READ`; `CAP_DAC_OVERRIDE` overrides only if `MAY_EXEC`
    was not requested or at least one execute bit is set in `i_mode`.
    Source: `fs/namei.c:545-561` (mask narrowed at `:549`, checks at `:550-552`
    and `:558-561`).
    Break: dropping the `S_IXUGO` condition lets root execute a file with mode 0.

11. Both capability overrides go through `capable_wrt_inode_uidgid()`, which
    requires the capability in the current user namespace **and** that the
    inode's vfsuid *and* vfsgid map into that namespace.
    Source: `fs/namei.c:536,539,551,560`; `kernel/capability.c:490-498`;
    `kernel/capability.c:472-478`.
    Break: substituting a plain `capable()` grants root-in-a-container override
    over files it cannot name — a container escape.

12. `acl_permission_check()` has a fast path that returns 0 without any
    owner/group/ACL evaluation when the requested `rwx` bits are set for all of
    u, g and o, and the inode is known to have no cached ACL or the superblock is
    not POSIX-ACL.
    Source: `fs/namei.c:457-462`; helper `no_acl_inode()` at `fs/namei.c:413-419`.
    Break: `no_acl_inode()` is a one-way test — false does not mean "has ACLs"
    (`fs/namei.c:405-412`). A refactor that reads it as a definitive answer will
    skip ACL evaluation on inodes with uncached ACLs.

13. Owner is determined by `i_uid_into_vfsuid(idmap, inode)` compared with
    `current_fsuid()` via `vfsuid_eq_kuid()`; if the caller is the owner, ACLs are
    not consulted at all and only the `u` bits apply.
    Source: `fs/namei.c:467-472`.
    Break: comparing `inode->i_uid` directly makes every idmapped mount evaluate
    permissions against the wrong identity.

14. Group is determined by `i_gid_into_vfsgid(idmap, inode)` and
    `vfsgid_in_group_p()`, and is only consulted when the group bits actually
    differ from the other bits for the requested mask.
    Source: `fs/namei.c:481-491`.
    Break: as above for gid; and evaluating the group unconditionally is a
    correctness-neutral but measurable behaviour change for `vfsgid_in_group_p()`
    side effects — none observed in this tree, but the conditional is load-bearing
    for cost, not semantics.

15. POSIX ACLs are evaluated only when `IS_POSIXACL(inode)` and at least one
    group bit is set in `i_mode`; `check_acl()` returning `-EAGAIN` means
    "no ACL, fall through to mode bits".
    Source: `fs/namei.c:475-479`; `check_acl()` at `fs/namei.c:374-401`,
    `-EAGAIN` returns at `fs/namei.c:381` and `fs/namei.c:400`.
    Break: treating `-EAGAIN` as an error denies access on every non-ACL inode on
    an ACL-capable filesystem.

16. In RCU mode (`mask & MAY_NOT_BLOCK`), `check_acl()` may only use
    `get_cached_acl_rcu()`; an uncached ACL must produce `-ECHILD`, and a missing
    cached entry `-EAGAIN`. `->get_inode_acl()` must not be called.
    Source: `fs/namei.c:380-387` (comment "no ->get_inode_acl() calls in RCU mode"
    at `:385`).
    Break: calling the blocking variant under RCU sleeps in an atomic section.
    The distinction between `-EAGAIN` (no ACL) and `-ECHILD` (retry non-lazily) is
    semantic, not cosmetic: collapsing them either denies access or spuriously
    drops out of RCU-walk.

### 1.3 The `may_lookup()` fast path (tree-specific)

17. `may_lookup()` calls `lookup_inode_permission_may_exec()`, not
    `inode_permission()`, and that function deliberately **skips**
    `sb_permission()`, the immutable check, the unmapped-ID check and
    `devcgroup_inode_permission()`.
    Source: `fs/namei.c:1955-1977`; `lookup_inode_permission_may_exec()` at
    `fs/namei.c:683-706`.
    Break: this is only sound because the mask is provably `MAY_EXEC`
    (± `MAY_NOT_BLOCK`) and the inode is provably a directory — both asserted at
    `fs/namei.c:697-698`, and both compiled out without `CONFIG_DEBUG_VFS`. Adding
    any other bit to the mask at the call site silently skips four checks. The
    comment at `fs/namei.c:600-602` records this coupling; the coupling is
    otherwise **implicit**.

18. The fast path still calls `security_inode_permission()`; the LSM is never
    skipped even when DAC is short-circuited.
    Source: `fs/namei.c:700-706` — both exits (`:701`, `:704`) fall back to full
    `inode_permission()`, and the fast exit at `:706` calls the hook directly.
    Break: an `inode->i_opflags` fast path that returns 0 without the hook disables
    LSM mediation of directory traversal, which is the single most security-load-
    bearing hook on the path-walk.

19. `may_lookup()` treats a failure in RCU mode as non-final: it must
    `try_to_unlazy()` and, if the error was `-ECHILD`, re-run the check in
    ref-walk mode before reporting.
    Source: `fs/namei.c:1964-1976`.
    Break: reporting the RCU-mode error directly turns a transient `-ECHILD` into
    a spurious `EACCES` for the caller.

### 1.4 `may_open()` and `may_open_dev()`

20. `may_open()` rejects by file type before performing any permission check:
    `S_IFLNK` → `-ELOOP`; `S_IFDIR` with `MAY_WRITE` → `-EISDIR`, with `MAY_EXEC`
    → `-EACCES`; FIFO/socket/device with `MAY_EXEC` → `-EACCES`.
    Source: `fs/namei.c:4241-4267`.
    Break: an `O_WRONLY` open of a directory must fail `EISDIR`, not `EACCES`; and
    reaching `inode_permission()` first would let a permissive directory be opened
    for write.

21. A device node may only be opened if neither `MNT_NODEV` on the mount nor
    `SB_I_NODEV` on the superblock is set — both must be checked, and via the
    `struct path`, not the inode.
    Source: `fs/namei.c:4225-4229` (`may_open_dev()`), called at `fs/namei.c:4252`.
    Break: this check is *only* reachable through a `struct path`. Any refactor
    that passes an inode where a path was passed loses `MNT_NODEV` entirely — an
    inode has no mount. This is the archetype of the path-vs-inode rule that also
    governs Landlock (category 2).

22. `O_TRUNC` is cleared for FIFO, socket and device opens.
    Source: `fs/namei.c:4259`.
    Break: passing `O_TRUNC` through to a device `->open()` is a filesystem-visible
    behaviour change.

23. `MAY_EXEC` on a regular file requires `!path_noexec(path)`, i.e. neither
    `MNT_NOEXEC` on the mount nor `SB_I_NOEXEC` on the superblock.
    Source: `fs/namei.c:4261-4264`; `path_noexec()` at `fs/exec.c:117`.
    Break: as rule 21 — mount-scoped, unreachable from an inode.

24. `may_open()` calls `inode_permission()` with `MAY_OPEN | acc_mode`; the
    `MAY_OPEN` bit must be present so LSMs can distinguish an open from an access
    check.
    Source: `fs/namei.c:4269`.
    Break: dropping `MAY_OPEN` makes `security_inode_permission()` unable to tell
    an `open()` from a path-walk, which SELinux and Smack both use.

25. An append-only inode may only be opened for write with `O_APPEND`, and never
    with `O_TRUNC` — checked *after* `inode_permission()` succeeded.
    Source: `fs/namei.c:4273-4281`.
    Break: hoisting it above `inode_permission()` leaks the existence of an
    append-only attribute to callers who have no permission on the file.

26. `O_NOATIME` requires `inode_owner_or_capable()`, i.e. owner (via the idmap) or
    `CAP_FOWNER` in a namespace the owner maps into.
    Source: `fs/namei.c:4283-4285`; `inode_owner_or_capable()` at `fs/inode.c:2749-2763`.
    Break: dropping it lets any user suppress atime updates on files they do not own.

27. `may_open()` returns `-ENOENT` for a negative dentry before touching anything
    else.
    Source: `fs/namei.c:4238-4239`.
    Break: a refactor that assumes `do_open()` only ever reaches `may_open()` with
    a positive dentry loses the last guard against a `NULL` inode dereference in
    `vfs_open()`/`do_dentry_open()` (`fs/open.c:938` dereferences `d_inode`
    unconditionally).

### 1.5 `may_create_*` / `may_delete_*` / sticky / setgid

28. `may_delete_dentry()` enforces, in order: negative → `-ENOENT`; unmapped uid or
    gid → `-EOVERFLOW`; audit; `MAY_WRITE|MAY_EXEC` on the parent; append-only
    parent → `-EPERM`; sticky/append/immutable/swapfile/unmapped victim → `-EPERM`;
    type mismatch; dead parent; NFS silly-rename.
    Source: `fs/namei.c:3678-3719` (stages at `:3684`, `:3691-3693`, `:3695`,
    `:3697`, `:3700`, `:3703-3706`, `:3707-3713`, `:3714`, `:3716`).
    Break: the `audit_inode_child()` at `:3695` is deliberately *before* the
    permission check, so a denied unlink is still audited. Moving it after the
    check silently loses those audit records.

29. `may_delete_dentry()` asserts the caller has already established that `victim`
    is a child of `dir`, with an always-on `BUG_ON`.
    Source: `fs/namei.c:3688`.
    Break: a refactor that changes who takes the parent's `i_rwsem` can make this
    race rather than assert — the assertion is only meaningful while the parent is
    locked exclusive, which is **implicit** here and stated in
    `Documentation/filesystems/directory-locking.rst:30-33`.

30. `__check_sticky()` permits the operation if the caller's fsuid equals the
    victim's vfsuid **or** the directory's vfsuid, else requires `CAP_FOWNER`
    qualified by `capable_wrt_inode_uidgid()`.
    Source: `fs/namei.c:3645-3655`.
    Break: comparing raw `i_uid` breaks sticky-bit semantics on idmapped mounts in
    the permissive direction.

31. `may_create_dentry()` audits first, then rejects an existing child `-EEXIST`,
    a dead directory `-ENOENT`, an unrepresentable fsuid/fsgid `-EOVERFLOW`, and
    finally requires `MAY_WRITE|MAY_EXEC` on the parent.
    Source: `fs/namei.c:3731-3743`.
    Break: as rule 28 for the audit ordering.

32. `may_o_create()` — the O_CREAT-within-open variant — has a *different* order:
    `security_path_mknod()` first, then `fsuidgid_has_mapping()`, then
    `inode_permission()`, then `security_inode_create()`.
    Source: `fs/namei.c:4315-4332`.
    Break: there are two LSM hooks here, a path-based one before and an
    inode-based one after the DAC check. Collapsing them, or reordering them to
    match `may_create_dentry()`, changes what AppArmor and Landlock see
    (`security_path_mknod` is the path-based hook; see category 2).

33. `may_create_in_sticky()` blocks `O_CREAT` on an *existing* FIFO or regular
    file in a sticky directory that the caller does not own and whose owner is not
    the directory owner, gated by `protected_fifos` / `protected_regular`; level 2
    extends it from world-writable to group-writable directories.
    Source: `fs/namei.c:1410-1453`; sysctls at `fs/namei.c:1206-1207`,
    `fs/namei.c:1229-1246`.
    Break: it reads `nd->dir_mode` and `nd->dir_vfsuid`, which are snapshotted in
    `link_path_walk()` at `fs/namei.c:2646-2647` and cleared for the empty path at
    `fs/namei.c:2593`. A refactor that stops recording them, or records them at a
    different point in the walk, silently disables the hardening — with no error.

34. `may_follow_link()` blocks following a symlink in a sticky, world-writable
    directory unless the follower owns the link or the directory owner owns the
    link, gated by `protected_symlinks`.
    Source: `fs/namei.c:1274-1302`.
    Break: same `nd->dir_mode` / `nd->dir_vfsuid` dependency as rule 33. Note it
    returns `-ECHILD` rather than denying while in RCU mode (`fs/namei.c:1296-1297`)
    precisely so the audit call at `:1299-1300` can happen in ref-walk.

35. `may_linkat()` rejects a source whose vfsuid or vfsgid is invalid with
    `-EOVERFLOW` *before* consulting `protected_hardlinks`.
    Source: `fs/namei.c:1360-1381` (`:1364-1367`).
    Break: the `-EOVERFLOW` check is unconditional; making it conditional on the
    sysctl allows creating links whose writeback would corrupt ownership.

36. A hardlink source is "safe" only if it is a regular file, not setuid, not
    setgid-and-group-executable, and the caller has both read and write permission
    on it.
    Source: `fs/namei.c:1317-1339`.
    Break: all four conditions are required; `safe_hardlink_source()` is the only
    thing preventing an unprivileged user pinning a setuid binary.

37. `S_ISGID` is stripped from a newly created non-directory unless the caller is
    in the parent's group or is privileged over it; directories always inherit
    `S_ISGID` from an `S_ISGID` parent.
    Source: `mode_strip_sgid()` at `fs/inode.c:3061-3072`; `inode_init_owner()` at
    `fs/inode.c:2719-2733` (directory inheritance at `:2726-2728`).
    Break: `vfs_prepare_mode()` (`fs/namei.c:4145-4160`) is the single choke point
    that applies `mode_strip_sgid()` and `mode_strip_umask()` before calling into
    the filesystem. Any create path that builds a mode without going through it
    creates setgid files for unprivileged users.

38. `vfs_prepare_mode()` also forces the file type bits, so the filesystem never
    sees a caller-controlled `S_IFMT`.
    Source: `fs/namei.c:4156-4157`.
    Break: allowing caller-supplied type bits through lets `open(O_CREAT)` create
    device nodes.

### 1.6 Idmapped mounts

39. Every `i_uid` / `i_gid` comparison on these paths must go through the mount's
    `mnt_idmap`. The complete set of such comparisons reachable from path-walk,
    open and the create/delete helpers in `fs/namei.c` and `fs/inode.c` is:
    - `fs/namei.c:467` — owner check in `acl_permission_check()`
    - `fs/namei.c:487` — group check in `acl_permission_check()`
    - `fs/namei.c:1283` — symlink owner in `may_follow_link()`
    - `fs/namei.c:1293` — directory owner in `may_follow_link()`
    - `fs/namei.c:1365-1366` — validity in `may_linkat()`
    - `fs/namei.c:1425` — file owner in `may_create_in_sticky()`
    - `fs/namei.c:2646` — `nd->dir_vfsuid` snapshot in `link_path_walk()`
    - `fs/namei.c:3650`, `fs/namei.c:3652` — victim and dir owner in `__check_sticky()`
    - `fs/namei.c:3691-3692` — validity in `may_delete_dentry()`
    - `fs/inode.c:2755` — `inode_owner_or_capable()`
    - `fs/inode.c:3068` — parent gid in `mode_strip_sgid()`
    - `kernel/capability.c:476-477` — `privileged_wrt_inode_uidgid()`
    Source: as listed.
    Break: any new comparison added against the raw `inode->i_uid` is a silent
    security bug on idmapped mounts and on no other configuration, so it will not
    be caught by ordinary testing. **This list is the checklist.**

40. The idmap is obtained from the mount that the inode was *reached through*,
    `mnt_idmap(nd->path.mnt)`, and is re-derived per component during the walk.
    Source: `fs/namei.c:2603` (per component in `link_path_walk()`),
    `fs/namei.c:1282`, `fs/namei.c:4506`, `fs/namei.c:4805`.
    Break: hoisting the `mnt_idmap()` call out of the loop is wrong across a mount
    crossing — a bind mount of the same filesystem with a different idmap is
    exactly the case that breaks, and it is not the common case.

41. `HAS_UNMAPPED_ID()` and `fsuidgid_has_mapping()` gate write and create
    respectively; they are separate checks and neither implies the other.
    Source: `fs/namei.c:647` (write), `fs/namei.c:4323` (`may_o_create`),
    `fs/namei.c:4877` (`vfs_tmpfile`), `fs/namei.c:3739` (`may_create_dentry`).
    Break: unifying them changes the errno (`-EACCES` vs `-EOVERFLOW`) and the set
    of operations covered.

### 1.7 The order of checks in `do_open()`

42. `do_open()` performs, in this exact order:
    1. `complete_walk()` — unless the file was already opened or created (`fs/namei.c:4798-4802`)
    2. `audit_inode()` — unless created (`fs/namei.c:4803-4804`)
    3. `mnt_idmap()` capture (`fs/namei.c:4805`)
    4. `O_EXCL` → `-EEXIST`, directory → `-EISDIR`, `may_create_in_sticky()` (`fs/namei.c:4806-4815`)
    5. `__O_REGULAR` → `-EFTYPE` (`fs/namei.c:4817-4818`)
    6. `LOOKUP_DIRECTORY` → `-ENOTDIR` (`fs/namei.c:4820-4821`)
    7. `mnt_want_write()` for `O_TRUNC` (`fs/namei.c:4829-4834`)
    8. `may_open()` (`fs/namei.c:4835`)
    9. `vfs_open()` (`fs/namei.c:4836-4837`)
    10. `security_file_post_open()` (`fs/namei.c:4838-4839`)
    11. `handle_truncate()` (`fs/namei.c:4840-4841`)
    12. `mnt_drop_write()` (`fs/namei.c:4846-4847`)
    Source: `fs/namei.c:4789-4849`.
    Break: see rules 43–47 for why each adjacency matters.

43. `complete_walk()` must run before any check that can sleep or that inspects
    the inode, and must be skipped when `FMODE_OPENED|FMODE_CREATED` is set
    because in that case the walk already ended inside `lookup_open()`.
    Source: `fs/namei.c:4798-4802`.
    Break: calling it unconditionally double-drops the RCU/ref state; skipping it
    when it was needed leaves the walk in RCU mode into `may_open()`, which sleeps.

44. `audit_inode()` runs *before* the permission checks, so a denied open is still
    audited against the right object; it is skipped when `FMODE_CREATED` because
    `lookup_open()` already audited the parent and child.
    Source: `fs/namei.c:4803-4804`; the created-case audit is at
    `fs/namei.c:4493` (`AUDIT_INODE_PARENT`) and `fs/namei.c:4549`
    (`audit_inode_child(..., AUDIT_TYPE_CHILD_CREATE)`).
    Break: moving it after `may_open()` loses audit records for denied opens —
    exactly the records an auditor most wants.

45. `mnt_want_write()` for `O_TRUNC` is taken **before** `may_open()`, so that an
    open-for-truncate on a read-only mount reports `-EROFS` rather than whatever
    `may_open()` would have said.
    Source: `fs/namei.c:4829-4834` then `fs/namei.c:4835`.
    Break: swapping them changes the errno; and taking the write reference after
    `vfs_open()` opens a window where the mount can be remounted read-only between
    the check and the truncate.

46. `security_file_post_open()` runs **after** `vfs_open()` has succeeded and
    **before** `handle_truncate()`. This is the only ordering that lets an LSM veto
    a truncating open before any data is destroyed.
    Source: `fs/namei.c:4836-4841`.
    Break: this is the single most consequential ordering rule in `do_open()`.
    Moving `handle_truncate()` above `security_file_post_open()` makes LSM denial
    of `O_TRUNC` useless — the file is already empty. Nothing in the code states
    this; it is **implicit** in the adjacency.

47. Any of `may_open()`, `vfs_open()`, `security_file_post_open()` or
    `handle_truncate()` returning a positive value is a bug, converted to `-EINVAL`
    with a `WARN_ON`.
    Source: `fs/namei.c:4842-4845`.
    Break: an LSM or `->open()` returning a positive value would otherwise be read
    as success by `path_openat()`, which then checks `FMODE_OPENED` (rule 5.x).

48. `mnt_drop_write()` is called on exactly the paths where `do_truncate` is true,
    including the error paths, and `do_truncate` is the sole record that the
    reference was taken.
    Source: `fs/namei.c:4823` (init `false`), `:4833` (set `true`), `:4846-4847`.
    Break: an early `return` inserted between `:4834` and `:4846` leaks a mount
    write reference — which makes the filesystem permanently unfreezable and
    un-remountable-read-only, with no warning until someone tries.

49. `handle_truncate()` takes `get_write_access()` on the inode, calls
    `security_file_truncate()`, does the truncate, and releases the write access on
    every path.
    Source: `fs/namei.c:4290-4306`.
    Break: the `put_write_access()` at `:4304` is unconditional; an early return
    added after `:4294` leaks `i_writecount`, which makes the file permanently
    un-`deny_write_access()`-able, i.e. it can never be executed again.

---

## 2. Security / LSM

### 2.1 Hook call order on the open path

50. The complete ordered sequence of LSM hooks for `openat2(O_CREAT|O_TRUNC)`
    through `path_openat()` is:
    1. `security_file_alloc()` — `fs/file_table.c:184` (from `alloc_empty_file()`, `fs/file_table.c:266`, called at `fs/namei.c:4986`)
    2. `security_inode_permission(inode, MAY_EXEC[|MAY_NOT_BLOCK])` — once per path component, `fs/namei.c:698` (fast path) or `fs/namei.c:661` (full path)
    3. `security_inode_follow_link(dentry, inode, rcu)` — per symlink, `fs/namei.c:2053`
    4. `security_path_mknod(dir, dentry, mode, 0)` — `fs/namei.c:4319`
    5. `security_inode_permission(dir_inode, MAY_WRITE|MAY_EXEC)` — `fs/namei.c:4326`
    6. `security_inode_create(dir_inode, dentry, mode)` — `fs/namei.c:4331`
    7. `security_inode_permission(inode, MAY_OPEN|acc_mode)` — via `may_open()`, `fs/namei.c:4269`
    8. `security_file_open(f)` — `fs/open.c:973`
    9. `security_file_post_open(file, op->acc_mode)` — `fs/namei.c:4839`
    10. `security_file_truncate(filp)` — `fs/namei.c:4298`
    11. `security_inode_setattr()` / `security_inode_post_setattr()` — `fs/attr.c:540`, `fs/attr.c:562`
    Source: as listed.
    Break: LSM policy is written against this order. Any reordering is a policy
    change for every deployed SELinux/AppArmor/Smack/Landlock ruleset.

51. Hooks 4, 5 and 6 are all inside `may_o_create()` and must stay in that order:
    the path-based hook first, then DAC, then the inode-based hook.
    Source: `fs/namei.c:4315-4332`; called from `fs/namei.c:4512-4513`.
    Break: AppArmor mediates via `security_path_mknod` and needs the parent
    `struct path` (rule 66); SELinux mediates via `security_inode_create`. Merging
    them loses one of the two models.

52. `security_file_open()` runs **before** `f_op->open()` and before `FMODE_OPENED`
    is set; `security_file_post_open()` runs **after** both.
    Source: `fs/open.c:973` vs `fs/open.c:995-999` vs `fs/open.c:1000`;
    `fs/namei.c:4839`.
    Break: this split is why IMA is a `file_post_open` hook — it reads file
    content, which requires a fully constructed file. Moving IMA's hook earlier
    would have it read through a half-initialised `struct file`.

53. `security_file_alloc()` is handed a `struct file` in which **only `f_cred` is
    valid**. `f_path`, `f_mode`, `f_flags`, `f_op` and `f_inode` still hold garbage
    from the previous user of the slab object, because `filp_cache` is
    `SLAB_TYPESAFE_BY_RCU`.
    Source: `fs/file_table.c:183` (`f_cred`), `fs/file_table.c:184` (the hook),
    then `fs/file_table.c:199` (`memset(&f->__f_path, ...)`), `:202` (`f_flags`),
    `:203` (`f_mode`), `:210` (`f_op = NULL`), `:213` (`f_inode = NULL`),
    `:229` (`file_ref_init`); slab flag at `fs/file_table.c:641`.
    Break: **implicit** — nothing documents or asserts this. A refactor that moves
    any initialisation *after* the hook, or that moves the hook earlier, widens the
    window; a refactor that moves initialisation *before* the hook is safe but
    changes what LSMs may rely on. In-tree LSMs comply by touching only their own
    blob (`security/apparmor/lsm.c:508-517`, `security/landlock/fs.c:1834-1845`).

54. On `security_file_alloc()` failure, `security_file_alloc()` itself calls
    `security_file_free()`; the caller must not free the blob again.
    Source: `security/security.c:2404-2413` (free at `:2412`); caller unwinds only
    `f_cred` at `fs/file_table.c:186-187` and the slab object at `fs/file_table.c:268`.
    Break: adding a `security_file_free()` in the caller double-frees.

### 2.2 Return-value contract

55. `call_int_hook()` starts at the hook's default (0 for every hook on these
    paths) and **stops at the first LSM that returns anything other than the
    default**. Only the first refusing LSM's errno is visible.
    Source: `security/security.c:488-496`, expanding `__CALL_STATIC_INT` at
    `security/security.c:480-487` (bail at `:483-484`); defaults materialised at
    `security/security.c:447-455`.
    Break: any aggregation change (e.g. "run all hooks and OR the results") alters
    which errno userspace sees under stacked LSMs, and changes audit output.

56. `call_void_hook()` calls every enabled LSM and cannot bail.
    Source: `security/security.c:473-476`, `security/security.c:466-472`.
    Break: void hooks on these paths (`security_inode_post_setattr`
    `security/security.c:1875`, `security_path_post_mknod` called at
    `fs/namei.c:5321`, `security_inode_post_create_tmpfile` called at
    `fs/namei.c:4908`, `security_file_free` called at `fs/file_table.c:97`) are
    notifications, not decisions; converting one to an int hook changes semantics.

57. A positive return from any of these hooks is a bug; `do_open()` converts it to
    `-EINVAL` with a `WARN_ON`, and `do_dentry_open()` has its own
    `WARN_ON_ONCE(error > 0)`.
    Source: `fs/namei.c:4842-4845`; `fs/open.c:1023-1024`.
    Break: removing either guard lets a positive value be read as success.

58. `security_inode_*` and `security_path_*` wrappers short-circuit to 0 for
    `IS_PRIVATE()` inodes; `security_file_open` and `security_file_post_open`
    **do not**.
    Source: private-inode filters at `security/security.c:1414`, `:1560`, `:1578`,
    `:1596`, `:1627`, `:1819`, `:1840`, `:1860`, `:1893`, `:2067`, `:1771-1774`;
    no filter at `security/security.c:2737-2740` and `:2753-2756`.
    Break: this asymmetry is deliberate — `file_open` hooks see anon/private inodes
    that `inode_permission` hid. Adding a filter to `file_open` would blind LSMs to
    anon-inode fds; removing one elsewhere would feed LSMs internal inodes.

### 2.3 RCU-walk and sleeping

59. `MAY_NOT_BLOCK` is set by the VFS in exactly one place: `may_lookup()`, from
    `LOOKUP_RCU`. Therefore `security_inode_permission()` is the **only** LSM hook
    on the lookup path that can be entered in RCU-walk.
    Source: `fs/namei.c:1960`; assertion that the mask carries nothing else at
    `fs/namei.c:688`.
    Break: setting `MAY_NOT_BLOCK` at any other call site, or adding a hook call
    inside the RCU region, introduces a sleep-in-atomic that only fires under
    cache-hit conditions.

60. An LSM returning `-ECHILD` from `security_inode_permission()` **will be called
    again** with `mask == 0` after `try_to_unlazy()`. It must therefore be free of
    side effects in RCU mode.
    Source: `fs/namei.c:1962-1976`; the re-invocation at `fs/namei.c:1976`.
    Break: **implicit** — nothing states it. An LSM that audits or counts on the
    RCU-mode pass would double-count.

61. `security_inode_follow_link()` receives an explicit `bool rcu` argument rather
    than a mask bit, and the hook's documented contract is that `@inode` is not
    stable when `rcu` is true.
    Source: `fs/namei.c:2053-2054`; prototype `include/linux/lsm_hook_defs.h:140`;
    contract stated at `security/security.c:1811`.
    Break: dropping the argument, or passing a constant, makes SELinux
    (`security/selinux/hooks.c:3125`, `:3134`) call the sleeping revalidation path
    under RCU.

62. Everything from `may_open()` onward is unconditionally sleepable, because
    `complete_walk()` has already left RCU mode or returned `-ECHILD`.
    Source: `fs/namei.c:1055-1066` (the RCU exit) and `fs/namei.c:4798-4802`
    (`complete_walk()` in `do_open()`), preceding `fs/namei.c:4835-4841`.
    Break: **implicit** — no comment states it. If a refactor were ever to reach
    `may_open()`/`vfs_open()` with `LOOKUP_RCU` still set, `security_file_open`,
    `security_file_post_open`, `security_file_truncate` and the `MAY_OPEN`
    `security_inode_permission` would all sleep in an RCU read-side section.

63. SELinux's `-ECHILD` originates in `__inode_security_revalidate()`, which is
    the only place that decides whether it may sleep.
    Source: `security/selinux/hooks.c:283`, `:289-292`; reached via
    `inode_security_rcu()` at `security/selinux/hooks.c:309`, `:317-319`;
    propagated by `selinux_inode_permission()` at `security/selinux/hooks.c:3267-3269`.
    Break: as rule 60.

64. Smack can **deny** (not just `-ECHILD`) while still in RCU-walk: the
    `SMK_SB_UNTRUSTED` check precedes the `no_block` bail.
    Source: `security/smack/smack_lsm.c:1249-1253` before `:1256-1257`.
    Break: a refactor that assumes "RCU mode can only produce `-ECHILD`" is wrong;
    `may_lookup()` handles the hard-error case explicitly at `fs/namei.c:1973`.

65. AppArmor and Landlock register **no** `inode_permission` hook and are therefore
    never entered in RCU-walk from `may_lookup()`.
    Source: hook tables — `security/smack/smack_lsm.c:5178` and
    `security/selinux/hooks.c:7595` are the only `LSM_HOOK_INIT(inode_permission,…)`;
    Landlock's full table is `security/landlock/fs.c:2085-2112`.
    Break: informational, but it means RCU-mode LSM testing only exercises two of
    the four major modules.

### 2.4 Landlock, AppArmor, Smack, SELinux: what they need from the VFS

66. **Landlock requires a `struct path`, not an inode.** Its open hook passes
    `&file->f_path` and then walks *up the mount and dentry hierarchy*, using
    `follow_up()`, `dget_parent()`, `path_get()` and `path_put()`.
    Source: `security/landlock/fs.c:1856`, `:1886-1887`; the walk at
    `security/landlock/fs.c:894-895`, `:961-966`, `:976-985`, `:987-995`, `:996`,
    `:1002`.
    Break: this is the strongest argument against any "pass the inode instead of
    the path" simplification. Every Landlock fs hook takes `const struct path *`
    (`security/landlock/fs.c:1621`, `:1629`, `:1641`, `:1647`, `:1655`, `:1662`,
    `:1668`, `:1674`), all funnelling into `current_check_access_path()` at
    `security/landlock/fs.c:1030`. An inode has no mount, so Landlock cannot
    compute a pathname from one.

67. Landlock's use of `dget_parent()` and `path_get()`/`path_put()` makes
    `hook_file_open` unconditionally sleepable and non-RCU.
    Source: `security/landlock/fs.c:894-895`, `:996`, `:1002`.
    Break: as rule 62.

68. Landlock caches the open-time decision in the file blob so later inode-only
    operations (notably `ftruncate`) do not need a path. This requires
    `security_file_open` to be called while `f_path` is fully valid.
    Source: cache write at `security/landlock/fs.c:1909`, rationale comment at
    `security/landlock/fs.c:1903-1908`; read back by `hook_file_truncate()` at
    `security/landlock/fs.c:1940` and by the ioctl hook at `:1962`, `:1970`;
    the validity guarantee is `path_get(&f->f_path)` at `fs/open.c:941` preceding
    the hook at `fs/open.c:973`.
    Break: moving `path_get()` after `security_file_open()` — an obvious-looking
    "take the reference only once we know we'll succeed" optimisation — hands
    Landlock an unpinned path.

69. Landlock also reads `f_mode`, `f_flags`, `file_inode()` and `f_cred` in
    `get_required_file_open_access()`; all must be set before `security_file_open`.
    Source: `security/landlock/fs.c:1816-1830`, `:1849-1854`, `f_cred` use at
    `security/landlock/fs.c:1861`; set at `fs/file_table.c:203` (`f_mode`),
    `fs/file_table.c:202` (`f_flags`), `fs/open.c:942` (`f_inode`).
    Break: note it uses `file->f_cred`, not `current_cred()` — correct for
    `dentry_open()` on foreign creds. A refactor that substitutes `current_cred()`
    mis-attributes every kernel-initiated open.

70. **No LSM `file_open` hook runs for `O_PATH` opens at all**, because
    `do_dentry_open()` returns before reaching `security_file_open()`.
    Source: `fs/open.c:947-952` (the early return) vs `fs/open.c:973`.
    Break: this is a deliberate property of the current code. A refactor that
    "tidies up" the `O_PATH` early return into the main flow would start invoking
    LSMs for `O_PATH`, which no in-tree LSM expects (Landlock documents the gap at
    `security/landlock/fs.c:1869-1873`).

71. AppArmor's `apparmor_file_open` needs `file->f_path` (mount included) to
    compute a pathname, reads `__FMODE_EXEC` out of `f_flags` (not `f_mode`), and
    uses `file->f_cred`.
    Source: `security/apparmor/lsm.c:464`, `:466`, `:471`, `:480-483`, `:486`,
    `:488`, `:489-493`, `:496-498`, cache at `:500`.
    Break: as rules 66 and 69.

72. AppArmor's `path_*` hooks take the parent as a `struct path` and the child as a
    bare dentry, and reconstruct `{ .mnt = dir->mnt, .dentry = child }`. The VFS
    must guarantee that `dir->mnt` is the mount the child lives on.
    Source: `security/apparmor/lsm.c:401-404` (`apparmor_path_rename`);
    hooks at `security/apparmor/lsm.c:326`, `:331`, `:338`, `:343`, `:349`, `:359`,
    `:366`, `:385`, `:449`, `:454`, `:459`. Landlock states the same assumption
    explicitly at `security/landlock/fs.c:1635`.
    Break: **implicit** in AppArmor; explicit only in a Landlock comment. Passing a
    parent path from a different mount than the child produces a wrong pathname and
    therefore a wrong policy decision.

73. `apparmor_file_truncate` is implemented as
    `apparmor_path_truncate(&file->f_path)`, so `f_path` must still be valid at
    `security_file_truncate()` time.
    Source: `security/apparmor/lsm.c:354-357`; guaranteed by `handle_truncate()`
    reading `&filp->f_path` at `fs/namei.c:4292`.
    Break: an fput-before-truncate reordering would hand AppArmor a dangling path.

74. SELinux's `selinux_file_open` deliberately re-checks permission at open time
    even though `selinux_inode_permission` already ran, to close the race between
    them.
    Source: `security/selinux/hooks.c:4256`, `:4261`, `:4271-4272`, and the
    re-check at `security/selinux/hooks.c:4279-4280` with the in-code comment
    "This check is not redundant - do not remove".
    Break: "removing a redundant check" here reintroduces a documented TOCTOU.

75. SELinux's `file_path_has_perm` uses `f_path` only for **audit**
    (`LSM_AUDIT_DATA_FILE`); the decision is made from the inode.
    Source: `security/selinux/hooks.c:1736-1745`; audit printer at
    `security/lsm_audit.c:212` (`audit_log_d_path(ab, " path=", &a->u.file->f_path)`).
    Break: `f_path` must still be valid when a denial is audited — which is after
    the decision, so any teardown that clears `f_path` before auditing loses the
    pathname from the audit record.

76. SELinux audit under RCU is safe only because `selinux_inode_permission` uses
    `LSM_AUDIT_DATA_INODE`, whose printer takes `rcu_read_lock()` and never calls
    `d_path()`, and whose buffer is `GFP_ATOMIC`.
    Source: `security/selinux/hooks.c:3141`, `:3148`; printer at
    `security/lsm_audit.c:253-269`; allocation at `security/lsm_audit.c:441-443`.
    The path-based variants that *do* call `d_path()` are at
    `security/lsm_audit.c:199`, `:212`, `:237-243`, and are only reachable from the
    non-RCU hooks `path_has_perm` (`security/selinux/hooks.c:1719`),
    `file_path_has_perm` (`:1736`) and `dentry_has_perm` (`:1690`).
    Break: **implicit** — the safety is by construction, not by an assertion.
    Changing which audit data type `selinux_inode_permission` uses would sleep or
    take `d_lock` in an RCU read-side section.

77. `selinux_inode_setattr` distinguishes `ftruncate` from `truncate` by the
    presence of `ATTR_FILE`, adding `FILE__OPEN` to the required access for a bare
    `ATTR_SIZE`.
    Source: `security/selinux/hooks.c:3322-3326`; `ATTR_FILE` is set by
    `do_truncate()` at `fs/open.c:52-55`.
    Break: dropping `ATTR_FILE` from the `do_truncate()` path silently tightens
    SELinux policy for `ftruncate`.

78. Smack's `smack_file_open` copies `f_path` **by value** into the audit data.
    Source: `security/smack/smack_lsm.c:2076-2077`; hook at `:2069-2082`; same
    pattern in `smack_inode_getattr` at `security/smack/smack_lsm.c:1303-1304`.
    Break: as rule 68 — requires `f_path` pinned before the hook.

79. `security_file_open` **can be called with the parent directory's `i_rwsem`
    held** on the `->atomic_open` path, but never on the `vfs_open` path.
    Source: lock taken at `fs/namei.c:4458` (exclusive for `O_CREAT`) / `:4460`,
    `atomic_open()` invoked at `fs/namei.c:4522`, filesystem calls `finish_open()`
    (`fs/open.c:1052`) → `do_dentry_open()` → hook at `fs/open.c:973`; lock dropped
    at `fs/namei.c:4578`/`:4580`.
    Break: **implicit and undocumented.** An LSM `file_open` hook that performed a
    lookup in the parent directory would deadlock — but only on filesystems that
    implement `->atomic_open`. `security_file_post_open` is deliberately outside
    the lock (`fs/namei.c:4839`, after the unlock), which is why IMA — which reads
    file content — is a `post_open` hook.

80. `security_inode_getattr` takes a `const struct path *` and is called before
    anything else in `vfs_getattr()` — before the `memset`, before `->getattr`, and
    outside any lock.
    Source: `fs/stat.c:259-261`; definition `security/security.c:1891-1896`
    (private-inode filter at `:1893-1894`).
    Break: as rule 66 — it is path-based by design. `vfs_getattr_nosec()` bypasses
    it entirely (`fs/stat.c:181`), and the set of legitimate `nosec` callers is
    closed (rule 106).

81. `security_inode_rename` is called **twice** for `RENAME_EXCHANGE`, with the
    arguments swapped, bailing on the first error.
    Source: `security/security.c:1778-1785`.
    Break: calling it once for an exchange mediates only one direction.

### 2.5 Audit

82. Every audit wrapper is gated on `!audit_dummy_context()`, so in the common case
    nothing happens — but the dentry/file handed in must still be valid.
    Source: `include/linux/audit.h:397-402` (`audit_inode`), `:403-407`
    (`audit_file`), `:408-414` (`audit_inode_parent_hidden`), `:415-420`
    (`audit_inode_child`); flags at `include/linux/audit.h:313-315`.
    Break: passing a dentry that is only valid under RCU works 99.9% of the time
    and faults when auditing is enabled.

83. `__audit_inode()` dereferences `d_backing_inode(dentry)` immediately, takes
    `rcu_read_lock()`, walks `context->names_list`, and can allocate. It must not be
    called from RCU-walk and must be given a positive dentry.
    Source: `kernel/auditsc.c:2245`, `:2248`, `:2259-2273`, `:2293`, `:2319`,
    `:2339-2340`; `AUDIT_INODE_NOEVAL` handling at `kernel/auditsc.c:2232-2235`.
    Break: this is why `may_follow_link()` returns `-ECHILD` before auditing
    (rule 84).

84. `may_follow_link()` returns `-ECHILD` in RCU mode **specifically so that
    `audit_inode()` is never called from RCU-walk**.
    Source: `fs/namei.c:1296-1297` immediately preceding `fs/namei.c:1299-1300`.
    Break: **implicit** — the `-ECHILD` looks like an ordinary lazy-walk bail. A
    refactor that "handles the denial in RCU mode too" calls a sleeping audit path
    under `rcu_read_lock()`.

85. `audit_inode()`/`audit_inode_child()` are placed **before** the corresponding
    LSM and DAC checks at every site, so denials are attributable to a pathname.
    Source: `fs/namei.c:4493` (`AUDIT_INODE_PARENT`, before `may_o_create()` at
    `:4512`); `fs/namei.c:4549` (before the `create_error` bail at `:4551`);
    `fs/namei.c:3695` (before `inode_permission()` at `:3697`); `fs/namei.c:3734`
    (first statement of `may_create_dentry()`); `fs/namei.c:4804` (before
    `may_open()` at `:4835` and `security_file_post_open()` at `:4839`).
    Break: **implicit** at every one of these sites. Moving audit after the check
    is the single easiest way to silently destroy audit coverage of denied
    operations, and no test detects it.

86. `audit_inode()` in `do_open()` is placed after `complete_walk()`, guaranteeing
    non-RCU and a legitimized `nd->path`.
    Source: `fs/namei.c:4799` then `fs/namei.c:4803-4804`.
    Break: as rule 83.

87. `__audit_file(file)` is exactly `__audit_inode(NULL, file->f_path.dentry, 0)` —
    it has no `struct filename`, so it always allocates a fresh name record.
    Source: `kernel/auditsc.c:2343-2346`; callers `fs/open.c:702` (before
    `chmod_common()` → `security_path_chmod` at `fs/open.c:681`) and `fs/open.c:889`
    (before `chown_common()` → `security_path_chown` at `fs/open.c:820`).
    Break: same pre-check placement rule as 85.

88. The remaining `audit_inode()` sites on the lookup path are `fs/namei.c:2849`
    (`filename_lookup`, with `AUDIT_INODE_NOEVAL` iff `LOOKUP_MOUNTPOINT`, `:2850`),
    `fs/namei.c:2892` (`AUDIT_INODE_PARENT`), `fs/namei.c:4960` (`do_tmpfile`, on
    `file->f_path.dentry` after `vfs_tmpfile()` succeeded) and `fs/namei.c:4973`
    (`do_o_path`, **before** `vfs_open()` at `:4974` — the only observation point
    for `O_PATH`, since no LSM `file_open` hook runs, rule 70).
    Source: as listed.
    Break: `do_o_path`'s audit is the only record of an `O_PATH` open. Losing it
    makes `O_PATH` invisible to audit.

89. `audit_openat2_how()` records the `open_how` before any lookup or LSM hook.
    Source: `fs/open.c:1460`, before `do_sys_openat2()` at `fs/open.c:1466`.
    Break: recording it later would lose the record for opens that fail in
    `build_open_flags()`.

90. `audit_inode_parent_hidden()` has **no caller under `fs/`** in this tree.
    Source: definition `include/linux/audit.h:408`, stub `:639`; no call sites found.
    Break: not a rule to preserve — noted so that a refactor does not assume it is
    live. Whether its absence is intentional is **not established from source**.

---

## 3. Mount and namespace

### 3.0 Structural note — this tree differs from historical mainline

Three flags a reader may expect **do not exist** in this tree, and a spec written
from memory would be wrong about all three:

- `MNT_WRITE_HOLD` is not an `mnt_flags` bit. It is the stolen LSB of a pointer:
  `#define WRITE_HOLD 1` at `fs/mount.h:67`, applied to
  `struct mount * __aligned(1) *mnt_pprev_for_sb` at `fs/mount.h:64-65`.
  Accessors `__test_write_hold()` `fs/mount.h:256-259`, `test_write_hold()`
  `fs/mount.h:261-264`, `set_write_hold()` `fs/mount.h:266-270`,
  `clear_write_hold()` `fs/mount.h:272-276`. The only surviving textual use of the
  old name is a stale comment at `fs/internal.h:159`.
- `MNT_SHARED` and `MNT_MARKED` are gone; the propagation state lives in a
  separate, `namespace_sem`-protected word `mount.mnt_t_flags` (`fs/mount.h:95`)
  as `T_SHARED = 1` (`fs/mount.h:107`), `T_UNBINDABLE = 2` (`:108`),
  `T_MARKED = 4` (`:109`), `T_UMOUNT_CANDIDATE = 8` (`:110`).
- `MNT_STRICTATIME` is not a kernel-internal flag. Strict atime is the *absence*
  of `MNT_NOATIME|MNT_NODIRATIME|MNT_RELATIME`
  (`include/linux/mount.h:52`; encode `fs/namespace.c:5276-5281`, decode
  `fs/namespace.c:5087`, `:5095-5096`).
- `MNT_LONGTERM` / `mnt_make_longterm()` do not exist. "Longterm" is now simply
  `mnt_ns != NULL`; the reverse operation is `mnt_make_shortterm()`
  (`fs/namespace.c:1439-1443`).

The complete flag enum is `include/linux/mount.h:25-56`.

### 3.1 Mount flags and where each is enforced

91. `MNT_NOSYMFOLLOW` is tested in exactly one place in path-walk, against
    `link->mnt` (the mount the *symlink* was found on), not `nd->path.mnt`.
    Source: `fs/namei.c:2040-2042`.
    Break: testing `nd->path.mnt` instead is wrong whenever the symlink and the
    current directory are on different mounts — which is precisely the bind-mount
    case the flag exists for. The check is also positioned *after* the link is
    pushed onto `nd->stack` (`fs/namei.c:2029-2032`), so the error return must
    leave the stack entry for `terminate_walk()` to release (see rule 141).

92. `MNT_NODEV` is enforced only through `may_open_dev()`, which checks both the
    mount flag and `SB_I_NODEV`, and is called only for `S_IFBLK`/`S_IFCHR`.
    FIFOs and sockets deliberately fall through past it.
    Source: `fs/namei.c:4225-4229`; called at `fs/namei.c:4252`; the `fallthrough`
    at `fs/namei.c:4254-4255`.
    Break: moving the call above the `fallthrough` would apply `nodev` to FIFOs.

93. `MNT_NOSUID` has **no test in `fs/namei.c`**. It is consumed only via
    `mnt_may_suid()`, which additionally requires `check_mnt()` — so mounts from a
    foreign mount namespace are implicitly nosuid.
    Source: `fs/namespace.c:6456-6467`; `check_mnt()` at `fs/namespace.c:947-950`;
    rationale comment `fs/namespace.c:6458-6464`. Callers: `fs/exec.c:1639-1640`,
    `security/commoncap.c:774` (with a note at `:778` that the duplication is
    deliberate), `security/selinux/hooks.c:2290`.
    Break: the "foreign mount ⇒ nosuid" property is a *consequence* of
    `check_mnt()` being inside `mnt_may_suid()`, not an explicit rule. Splitting
    the two loses it.

94. `MNT_NOEXEC` is enforced through `path_noexec()`, which checks both the mount
    flag and `SB_I_NOEXEC`; it appears on the open path and the `access(2)` path.
    Source: `fs/exec.c:117-124`; `fs/namei.c:4261-4263` (`may_open`),
    `fs/open.c:495-501` (`do_faccessat`), `fs/exec.c:790`.
    Break: as rule 21 — path-scoped, unreachable from an inode.

95. Read-only is enforced on the open path by `sb_permission()` (`-EROFS`) and by
    `mnt_want_write()`, **not** by a direct `MNT_READONLY` test.
    Source: `fs/namei.c:604-614`, called at `fs/namei.c:633`; write-hold sites at
    `fs/namei.c:4451`, `fs/namei.c:4830`, `fs/open.c:96`;
    `__mnt_is_readonly()` at `fs/namespace.c:360-363` with its documented
    non-guarantee at `fs/namespace.c:349-359`.
    Break: `sb_permission()` covers only `S_IFREG`/`S_IFDIR`/`S_IFLNK`; the mount's
    `MNT_READONLY` is enforced solely by `mnt_want_write()`. Dropping a
    `mnt_want_write()` therefore permits writes to a read-only *mount* of a
    read-write superblock, with no other check catching it.

96. `access(2)` reports `-EROFS` using a deliberately racy bare
    `__mnt_is_readonly()` with no want/drop pair. This is the one sanctioned use.
    Source: `fs/open.c:508-519` with the justifying comment at `fs/open.c:508-517`.
    Break: "fixing" this to take a write reference changes `access(2)` into an
    operation that can block on filesystem freeze.

97. `MNT_LOCK_*` flags can never be cleared once set, and that is why
    `can_change_locked_flags()` tests them without holding any lock.
    Source: `fs/namespace.c:3259-3284`; the invariant is stated in the comment at
    `fs/namespace.c:3256-3257`.
    Break: adding any code path that clears a `MNT_LOCK_*` bit invalidates that
    lockless read.

98. `MNT_INTERNAL` mounts are torn down synchronously rather than being deferred
    to task work.
    Source: set at `fs/namespace.c:1187-1188` and `fs/namespace.c:1481`; tested at
    `fs/namespace.c:1380` with the inline `cleanup_mnt()` at `fs/namespace.c:1391`.
    Break: deferring internal mounts risks a kernel mount outliving its module.

99. `MNT_DOOMED` and `MNT_SYNC_UMOUNT` are what make RCU→ref promotion fail.
    Source: `MNT_DOOMED` set at `fs/namespace.c:1363`, tested at
    `fs/namespace.c:1358` and `fs/namespace.c:754`; `MNT_SYNC_UMOUNT` set at
    `fs/namespace.c:1816`, tested at `fs/namespace.c:754` and `fs/mount.h:147`.
    Break: removing either test from `__legitimize_mnt()` lets an RCU-walk promote
    a reference to a mount that is being torn down.

### 3.2 The write-hold protocol

100. `mnt_get_write_access()` must increment the per-CPU writer count **before**
     the `smp_mb()` and before spinning on `WRITE_HOLD`. The slowpath's per-CPU sum
     is only correct because of this order.
     Source: `fs/namespace.c:432-479` — increment `:438`, barrier `:444` with the
     rationale comment `:439-443`, spin `:446-448`, `smp_rmb()` `:470` with
     rationale `:463-469`, readonly re-check `:471-474`.
     Break: reordering the increment after the spin makes `mnt_hold_writers()`
     undercount — it can read one CPU pre-increment and another post-decrement and
     conclude there are no writers while a write is in flight. The correctness
     argument is spelled out at `fs/namespace.c:617-632`.

101. `mnt_get_write_access()` returns `0` or `-EROFS`, and nothing else.
     Source: `fs/namespace.c:435`, `:473`, `:477`.
     Break: a new error value would flow into `got_write = !mnt_want_write(...)`
     (`fs/namei.c:4451`) as "no write access" rather than as an error.

102. On `CONFIG_PREEMPT_RT` the spin is replaced by an acquire/release of
     `mount_lock`'s spinlock, to avoid priority inversion.
     Source: `fs/namespace.c:457-460`, rationale `:450-456`.
     Break: a refactor that unifies the two paths reintroduces an unbounded
     priority-inversion livelock on RT.

103. `mnt_want_write()` takes freeze protection **first**, then write access, and
     releases freeze protection if write access fails.
     Source: `fs/namespace.c:490-500`.
     Break: taking them in the other order deadlocks against the freeze protocol
     (`sb_start_write -> i_rwsem -> s_umount`, documented at
     `include/linux/fs/super.h:115-121`).

104. `mnt_get_write_access_file()` does **not** bump `mnt_writers` when the file
     already has `FMODE_WRITER` — the open file holds that reference.
     Source: `fs/namespace.c:511-523`, with the `errors=remount-ro` rationale at
     `fs/namespace.c:514-517`; it only re-tests `__mnt_is_readonly()` at `:518-519`.
     Break: double-counting here makes the mount permanently un-remountable-ro;
     under-counting makes `mnt_put_write_access_file()` underflow.

105. `mnt_want_write_file()` uses `file_inode(file)->i_sb`, **not**
     `file->f_path.mnt->mnt_sb`, for the freeze protection.
     Source: `fs/namespace.c:534-543`; matching release at `fs/namespace.c:583-588`.
     Break: the two differ for stacked and backing files; using the wrong one takes
     freeze protection on the wrong superblock, which is both a missing guarantee
     and a lock-ordering hazard.

106. `mnt_hold_writers()` must be called inside `mount_locked_reader` scope
     (`read_seqlock_excl(&mount_lock)`), and `mnt_unhold_writers()` in the *same*
     scope. It returns `0` or `-EBUSY`.
     Source: `fs/namespace.c:608-637` (documented context `:603-604`, return
     `:605-606`, barrier `:615` with rationale `:611-614`, sum `:633-634`);
     `mnt_unhold_writers()` at `fs/namespace.c:651-661` (self-check `:653`,
     `smp_wmb()` `:659` with rationale `:655-658`).
     Break: because `WRITE_HOLD` lives in `mnt_pprev_for_sb`'s LSB, the per-sb list
     splices (`mnt_del_instance()` `fs/namespace.c:663-671`, `mnt_add_instance()`
     `:673-682`) share the same word. Any list manipulation outside `mount_lock`
     corrupts the hold bit — **implicit**, enforced only by the fact that
     `mnt_del_instance()` is called solely under `lock_mount_hash()`
     (`fs/namespace.c:1366`, inside `:1344`…`:1377`).

107. The read-only state-change barriers must pair: `sb_start_ro_state_change()`
     writes `s_readonly_remount` then `smp_wmb()`; readers do `smp_rmb()` after
     reading it.
     Source: `fs/internal.h:150-163` and `fs/internal.h:170-182`;
     reader sides `fs/namespace.c:400-414` (`mnt_is_readonly`, barrier `:412`,
     rationale `:404-411`) and `fs/namespace.c:470` (`mnt_get_write_access`).
     Break: dropping either barrier lets a writer that passed the `WRITE_HOLD` spin
     miss the newly-set `MNT_READONLY`.

108. Every `mnt_want_write*` must have a matching `mnt_drop_write*` on every path.
     The complete set of pairs in the four core files is:
     `fs/open.c:96`↔`:123`, `fs/open.c:674`↔`:696`, `fs/open.c:851`↔`:854`,
     `fs/open.c:886`↔`:891`, `fs/open.c:917`/`:921`↔`:928`;
     `fs/namei.c:2978`↔`:2993`, `:4451`↔`:4583`, `:4830`↔`:4847`, `:4954`↔`:4962`,
     `:5085`↔`:5105`/`:5133`, `:5561`↔`:5577`, `:5696`↔`:5730`, `:6290`↔`:6335`;
     `fs/inode.c:2314`↔`:2329` (nested inside `sb_start_write_trylock()` `:2311` /
     `sb_end_write()` `:2331`), `fs/inode.c:2478`↔`:2484`.
     Source: as listed.
     Break: **this is the checklist.** An unmatched want is not detected at
     runtime; it manifests as a filesystem that can never be frozen or remounted
     read-only, arbitrarily later.

109. `fs/namei.c:4451` uses the idiom `got_write = !mnt_want_write(nd->path.mnt)`
     and deliberately does **not** propagate `-EROFS`; the error is re-derived later
     as `create_error = -EROFS` (`fs/namei.c:4515`) so that an `O_EXCL` open of an
     existing file reports `EEXIST` rather than `EROFS`.
     Source: `fs/namei.c:4450-4456` with the comment at `fs/namei.c:4495-4503`;
     `fs/namei.c:4504-4505` clears `O_TRUNC` when the write reference was not got.
     Break: "simplifying" this to propagate the error immediately changes the errno
     for a very common case and breaks the atomicity argument in the comment.

110. `file_get_write_access()` takes **two or three** references — inode write
     access, mount write access, and for `FMODE_BACKING` a second mount write
     access on the backing path — and unwinds them in reverse on failure.
     Source: `fs/open.c:910-932`; the `FMODE_BACKING` case at `fs/open.c:920-924`
     and its unwind at `:927-928`.
     Break: the release side is `file_put_write_access()` at `fs/internal.h:113-119`,
     which mirrors all three. Adding a reference on one side and not the other is
     a permanent leak.

### 3.3 `struct vfsmount` reference lifetime

111. `mntget()` is a bare counted increment with no validity check; the caller must
     already hold a reference or the mount hash lock.
     Source: `fs/namespace.c:1426-1432`; `mnt_add_count()` at
     `fs/namespace.c:255-264`, whose header comment `:252-254` states "vfsmount
     lock must be held for read".
     Break: `mntget()` on a mount you do not already pin is a use-after-free.

112. `mnt_get_count()` requires the write side of `mount_lock` because it sums
     per-CPU counters.
     Source: `fs/namespace.c:269-283`, header comment `:266-268`; callers relying on
     it at `fs/namespace.c:1602-1605` (with an explicit comment), `:1895`, `:1351`,
     and `fs/pnode.c:371-374`.
     Break: summing without write-side exclusion races with `mnt_add_count()` on
     another CPU and can read a count of zero for a live mount.

113. `mntput_no_expire()` has an RCU fast path: if `READ_ONCE(mnt->mnt_ns)` is
     non-NULL, the reference being dropped is provably not the last one.
     Source: `fs/namespace.c:1394-1412`; the correctness argument at
     `fs/namespace.c:1398-1406`; the `WRITE_ONCE(p->mnt_ns, NULL)` it races against
     at `fs/namespace.c:1814`; the RCU delay that makes it safe at
     `fs/namespace.c:1724` (`synchronize_rcu_expedited()` in `namespace_unlock()`).
     Break: this is a three-way coupling between `mntput`, `umount_tree` and
     `namespace_unlock`. Removing the `synchronize_rcu_expedited()` — or NULLing
     `mnt_ns` at a different point — breaks the fast path silently.

114. `mntput_no_expire_slowpath()` needs the `smp_mb()` at `fs/namespace.c:1349` to
     pair with the one in `__legitimize_mnt()`.
     Source: `fs/namespace.c:1338-1392` (`VFS_BUG_ON(mnt->mnt_ns)` `:1343`,
     `lock_mount_hash()` `:1344`, barrier `:1349` with rationale `:1345-1348`,
     decrement+resum `:1350-1351`, `MNT_DOOMED` re-entry guard `:1358-1363`);
     the paired barrier is `fs/namespace.c:750`, and a third at
     `fs/namespace.c:1957` in `do_umount()` ("paired with __legitimize_mnt()").
     Break: these three barriers are a single protocol. Removing any one lets a
     concurrent `__legitimize_mnt()` resurrect a mount whose count just hit zero.

115. `__legitimize_mnt()` is **three-valued**: `0` = legitimized, `>0` = failed with
     no reference taken, `<0` = failed **but a reference was taken and the caller
     must release it**.
     Source: `fs/namespace.c:741-762` — `:744-745` (`>0`), `:746-747`,
     `:749` (increment), `:750` (barrier), `:751-752` (`0`), `:754-758` (`1`, count
     dropped), `:760-761` (`-1`, caller must `mntput`). Must be called under
     `rcu_read_lock()` (`fs/namespace.c:740`).
     Break: **this is the single most dangerous signature in the reference
     protocol.** Treating the return as a boolean leaks a mount reference on the
     `<0` path (unmountable filesystem) or, if inverted, double-puts. The two
     in-tree consumers handle it differently and both must keep doing so:
     `legitimize_mnt()` at `fs/namespace.c:765-776` drops out of RCU to `mntput()`
     (`:770-774`); `__legitimize_path()` at `fs/namei.c:865-879` instead leaves
     `path->mnt` set when `res < 0` (`:869-870`) so that the caller's mandatory
     `path_put()` releases it — the contract line is `fs/namei.c:864`,
     "path_put is needed afterwards regardless of success or failure".

116. In ref-walk, a `vfsmount *` is kept valid by a counted reference. In RCU-walk,
     **nothing pins the mount**; validity rests on `rcu_read_lock()` being held for
     the whole walk, on mounts being freed only via RCU, and on revalidation
     against `nd->m_seq`.
     Source: `rcu_read_lock()` at `fs/namei.c:2689`; RCU free at
     `fs/namespace.c:735-738` using the `mnt_rcu` union member `fs/mount.h:52-55`;
     `nd->m_seq` sampled at `fs/namei.c:2696`.
     Break: any code added to the RCU-walk region that dereferences `path->mnt`
     after a `rcu_read_unlock()` — including an inlined helper that happens to drop
     RCU — is a use-after-free.

117. `mnt_rcu`, `mnt_node` and `mnt_llist` share a union, so RCU-freeing and
     rbtree membership are mutually exclusive in time.
     Source: `fs/mount.h:51-55`; `move_from_ns()` clears the node at
     `fs/mount.h:218-219` before teardown.
     Break: **implicit** — nothing asserts it. Freeing a mount still on the
     namespace rbtree corrupts the tree through the aliased `mnt_rcu` head.

118. `clone_mnt()` takes an idmap reference for the new mount.
     Source: `fs/namespace.c:1272` (`mnt_idmap_get(mnt_idmap(&old->mnt))`); flags
     copied minus `MNT_INTERNAL_FLAGS` at `:1255-1256`; `mnt_group_id` zeroed for
     `CL_SLAVE|CL_PRIVATE` at `:1258-1259`. Released in `free_vfsmnt()` at
     `fs/namespace.c:727`.
     Break: missing the get leaks or, worse, frees a shared idmap early.

### 3.4 `mount_lock`, `namespace_sem`, and the seq protocol

119. `mount_lock` has **three non-interchangeable read modes**: optimistic
     (`read_seqbegin`/`read_seqretry`, RCU-paired), locked-reader
     (`read_seqlock_excl`, used where modification must be *prevented*), and writer
     (`write_seqlock`).
     Source: definition `fs/namespace.c:127`, declaration `fs/mount.h:164`, contract
     comment `fs/namespace.c:119-126`; guards `mount_locked_reader` /
     `mount_writer` at `fs/mount.h:166-169`; raw helpers
     `lock_mount_hash()`/`unlock_mount_hash()` at `fs/namespace.c:188-196`.
     Break: substituting the optimistic form where the locked form is required
     (e.g. in `mnt_hold_writers()`'s caller, `fs/namespace.c:603-604`, or in
     `follow_up()` at `fs/namei.c:1465-1485`, which takes refs while reading
     `mnt_parent`) silently reintroduces the race the locked form exists to prevent.

120. `namespace_sem` protects `mnt_t_flags`, `ns->mounts`, `mnt->mnt_ns` (normally),
     `unmounted`, `ex_mountpoints`, `emptied_ns` and `notify_list`.
     Source: `fs/namespace.c:83` (declaration), `:84-86`, `:97`; `fs/mount.h:15`,
     `fs/mount.h:77`, `fs/mount.h:95`; `fs/pnode.h:30-32` ("EXCL[namespace_sem]");
     guards at `fs/namespace.c:90-92`.
     Break: reading `mnt_t_flags` under `mount_lock` instead of `namespace_sem` is
     a lock-type confusion that will not fail visibly.

121. `nd->m_seq` is sampled **once** for the entire walk and never re-sampled. Any
     mount-tree change anywhere during the walk invalidates the whole RCU walk.
     Source: `fs/namei.c:2696` (`nd->m_seq`), `:2697` (`nd->r_seq`), `:2698`
     (`smp_rmb()`).
     Break: re-sampling `m_seq` mid-walk to "reduce retries" destroys the property
     that the whole walk is a single consistent snapshot of the mount tree — which
     is what `__follow_mount_rcu()`'s retries at `fs/namei.c:1717-1718` and
     `:1721-1722` rely on ("makes sure that non-RCU pathwalk could reach this
     state").

122. `choose_mountpoint()`, unlike the walk, re-samples `mount_lock` per iteration,
     and retries the **not-found** case as well as the found case.
     Source: `fs/namei.c:1508-1531`; per-iteration sample at `:1515`; not-found
     retry at `:1519`; `__legitimize_path()` at `:1522`; the drop-RCU-to-put dance
     at `:1524-1526`.
     Break: skipping the not-found retry can conclude "no parent mount" from a
     torn read and silently escape the intended subtree.

123. `lookup_mnt()` returns a **new counted reference**, and its retry loop
     validates the sequence even when the result is NULL.
     Source: `fs/namespace.c:808-822`; the NULL still passes through
     `__legitimize_mnt()`'s `read_seqretry` at `fs/namespace.c:744` *before* the
     NULL check at `:746`.
     Break: short-circuiting `legitimize_mnt(NULL, seq)` to `true` loses the
     validation of a negative answer.

124. `__lookup_mnt()` requires either the `mount_lock` spinlock or
     `rcu_read_lock()` plus a sample-and-recheck of the seqcount.
     Source: `fs/namespace.c:790-799`; the contract is stated at
     `fs/namespace.c:783-788`.
     Break: one of the few places where the contract *is* written down. Honour it.

125. `handle_mounts()` must save and restore `path->mnt`, `path->dentry` and
     `nd->next_seq` around a failed `__follow_mount_rcu()`, because that function
     mutates `*path` in place even when it ultimately fails.
     Source: `fs/namei.c:1736-1747`; save `:1737`, restore `:1743-1745`, with the
     comment at `fs/namei.c:1742`.
     Break: omitting the restore hands `try_to_unlazy_next()` a half-updated path
     and legitimizes the wrong dentry.

126. `path_overmounted()` must not be called under `lock_mount_hash()`, and requires
     `namespace_sem` at least shared.
     Source: `fs/namespace.c:3506-3520`; the rule is stated at
     `fs/namespace.c:3501-3503`.
     Break: an explicitly documented deadlock.

### 3.5 Propagation and namespaces

127. Upward traversals terminate on `mnt_has_parent()`, relying on the invariant
     that the root of a tree is its own parent — so no NULL check is needed.
     Source: `fs/mount.h:129-132`; loop terminators at `fs/namei.c:1491`,
     `fs/namespace.c:1750`, `:1819`, `:1949`, `:2578`, `:3528`, `:3660`, `:4664`,
     `:4716`, `:4720`.
     Break: **implicit.** A refactor that makes a detached tree's root have a NULL
     parent turns every one of these loops into a NULL dereference.

128. `propagate_mount_busy()` and `propagate_mount_unlock()` require the **write**
     side of `mount_lock`, because they call `mnt_get_count()`.
     Source: `fs/pnode.c:423-459` (header `fs/pnode.c:421`), `do_refcount_check()`
     at `fs/pnode.c:371-374`; `fs/pnode.c:466-479` (header `:464`); called from
     `do_umount()` at `fs/namespace.c:1960` under `lock_mount_hash()` taken at
     `fs/namespace.c:1939`.
     Break: as rule 112.

129. `umount_tree()` requires `mount_lock` held **and** `namespace_sem` held for
     write.
     Source: header comment `fs/namespace.c:1772-1774`; the `MNT_UMOUNT` +
     `move_from_ns()` loop at `fs/namespace.c:1785-1790`; the
     `WRITE_ONCE(p->mnt_ns, NULL)` at `fs/namespace.c:1814`.
     Break: as rule 113.

130. A `struct path` carried across any sleep must pin **both** the dentry and the
     mount.
     Source: this is **implicit — there is no assertion anywhere.** The code that
     assumes it: `path_get()`/`path_put()` symmetry `fs/namei.c:707-712`, `:720-725`;
     `__legitimize_path()`'s contract line `fs/namei.c:864`; `terminate_walk()`'s
     unconditional `path_put()`s `fs/namei.c:849-854`; and most explicitly the
     manual bookkeeping in `__traverse_mounts()` at `fs/namei.c:1598-1628`
     (crossing puts the old pair `:1598-1601`, takes the new `:1602` with
     `need_mntput = true` `:1605`, and handles "possible if you race with several
     mount --move" at `:1627-1628`), plus `handle_mounts()`'s error path
     `fs/namei.c:1752-1756` and `follow_down()` at `fs/namei.c:1677-1678`.
     Break: this is the rule a reference-ownership refactor is most likely to
     violate, and nothing in the kernel will tell you. See section 9.

131. `__traverse_mounts()` operates on pinned-but-unlocked dentries, so a negative
     dentry can become positive underneath it; `smp_load_acquire()` on `d_flags` is
     the barrier that makes `d_inode` and `d_flags` mutually consistent.
     Source: `fs/namei.c:1569-1572` (the comment stating exactly this);
     `smp_load_acquire()` uses at `fs/namei.c:1590`, `:1619`, `:1638`.
     Break: replacing `smp_load_acquire()` with `READ_ONCE()` — a plausible-looking
     micro-optimisation — lets `d_flags_negative(flags)` (`fs/namei.c:1629`,
     `:1643`) disagree with `d_inode`.

### 3.6 Idmapped mounts — mechanism

132. `vfsuid_t` and `vfsgid_t` are distinct single-field structs with
     `static_assert`s tying their layout to `kuid_t`/`kgid_t`. This is what makes
     "did this comparison go through the idmap?" a *type* question.
     Source: `include/linux/mnt_idmapping.h:15-21`, asserts at `:23-26`;
     construction restricted to kuids by `VFSUIDT_INIT`/`VFSGIDT_INIT` at
     `include/linux/mnt_idmapping.h:109-110` with the rule at `:105-108`.
     Break: adding an implicit conversion, or a `#define vfsuid_t kuid_t`, removes
     the only mechanical defence the tree has for category-1 rule 39.

133. `nop_mnt_idmap` is the identity map; `invalid_mnt_idmap` maps everything to
     `INVALID_VFSUID`/`INVALID_VFSGID`. `is_valid_mnt_idmap()` excludes both.
     Source: `fs/mnt_idmapping.c:31-34` (rationale `:26-30`), `:40-43` (rationale
     `:36-39`); `include/linux/mnt_idmapping.h:28-31`.
     Break: conflating the two makes every comparison on an `invalid_mnt_idmap`
     mount succeed instead of failing closed.

134. `vfsuid_eq()`/`vfsgid_eq()` require the left operand to be valid; two invalid
     ids never compare equal.
     Source: `include/linux/mnt_idmapping.h:65-73`, `:85-88`, `:100-103`, with the
     documented rule at `:83` and `:98`.
     Break: a comparison written as `a.val == b.val` makes two unmapped owners
     compare equal, which grants sticky-bit and setgid privileges wrongly.

135. `mnt_idmap()` reads with `READ_ONCE()` and pairs with a `smp_store_release()`
     on the write side.
     Source: reader `include/linux/mount.h:64-68` (with the pairing comment at
     `:65`); writer `fs/namespace.c:4909` with the old-idmap put at `:4910`;
     initial assignment `fs/namespace.c:326`.
     Break: note the asymmetry — the comment claims a pairing but the reader is
     `READ_ONCE()`, not `smp_load_acquire()`. Whether this is intentional is
     **not established from source.** A refactor should not "fix" it without
     establishing which is correct.

136. Under `!CONFIG_MULTIUSER`, `__vfsuid_val`/`__vfsgid_val` return 0 and
     `vfsgid_in_group_p()` returns 1, so all vfsuid comparisons degenerate.
     Source: `include/linux/mnt_idmapping.h:44-52`; `fs/mnt_idmapping.c:212-215`.
     Break: any rule that assumes vfsuid comparisons are meaningful must be
     understood as conditional on `CONFIG_MULTIUSER`.

137. `inode_owner_or_capable()` checks the *mapping* before the capability, so
     `CAP_FOWNER` cannot be exercised over an inode whose owner does not map into
     the caller's user namespace.
     Source: `fs/inode.c:2755-2762` — mapping check at `:2760` gating
     `ns_capable(ns, CAP_FOWNER)`.
     Break: reordering makes container root the owner of every file it can see.

138. The write side of ownership goes through `i_uid_update()`/`i_gid_update()`,
     which map back **down** with `from_vfsuid()`/`from_vfsgid()`.
     Source: `include/linux/fs.h:1477-1484`, `:1529-1536`; used at
     `fs/attr.c:347-348`. `setattr_vfsuid()`/`setattr_vfsgid()` at
     `fs/open.c:764-769`, `:779-784` deliberately build a vfsuid from the raw
     syscall argument **without** an idmap, because the argument is already
     expressed in the mount's view.
     Break: adding an idmap conversion in `setattr_vfsuid()` double-maps.

139. There are **zero** raw `inode->i_uid`/`inode->i_gid` comparisons in
     `fs/namei.c`, `fs/attr.c`, `fs/open.c` or `fs/inode.c`. The only non-idmapped
     uid/gid comparisons in those files are in
     `access_need_override_creds()`/`access_override_creds()`, which compare fields
     of the caller's own `struct cred` and involve no inode.
     Source: `fs/open.c:395-396`, `:401`, `:428-429`, `:434`; the two raw
     assignments (not comparisons) are `fs/inode.c:2724` (setgid group inheritance)
     and `fs/inode.c:244-245` (initialisation).
     Break: this is a *currently-true invariant* of the tree and therefore a
     testable acceptance criterion: `grep -n 'inode->i_uid\|inode->i_gid'` over
     those four files must continue to match only comments, assignments and the
     `i_*_into_vfs*`/`i_*_update` helpers.

### 3.7 Automount

140. Automount is not triggered for a bare `stat`, but **is** triggered whenever any
     of `LOOKUP_PARENT|LOOKUP_DIRECTORY|LOOKUP_OPEN|LOOKUP_CREATE|LOOKUP_AUTOMOUNT`
     is set, or when the dentry is negative.
     Source: `fs/namei.c:1553-1556`, rationale `fs/namei.c:1542-1552`.
     Break: the `dentry->d_inode` conjunct is what lets autofs's negative
     automount dentries through unconditionally. Dropping it breaks autofs.
     Consequence worth recording: `AT_NO_AUTOMOUNT` alone does **not** guarantee no
     automount — a trailing `/` sets `LOOKUP_DIRECTORY` and defeats it.

141. Automounts share the symlink budget (`MAXSYMLINKS`, `nd->total_link_count`),
     and `follow_down()` passes `count == NULL`, so external callers bypass it.
     Source: `fs/namei.c:1562-1563`; `fs/namei.c:1675` (`traverse_mounts(path,
     &jumped, NULL, flags)`).
     Break: unifying the two call sites would either impose a budget on NFS or
     remove it from path-walk.

142. **RCU-walk can never automount.** `__follow_mount_rcu()` returns `false` when
     `DCACHE_NEED_AUTOMOUNT` is set, forcing the fall-back to ref-walk.
     Source: `fs/namei.c:1724`; the fall-back at `fs/namei.c:1746-1749`.
     Break: **implicit** — `->d_automount` may sleep. A refactor that "handles the
     automount case in RCU mode" sleeps under `rcu_read_lock()`.

143. `-EISDIR` from `follow_automount()` is a control-flow signal, not an error,
     and is swallowed by `__traverse_mounts()`.
     Source: `fs/namei.c:1624-1625`; the contract is documented at
     `fs/namei.c:1534-1536`.
     Break: propagating it makes `stat()` on an automount point fail.

144. `LOOKUP_NO_XDEV` is enforced at seven distinct points, and the RCU variants
     return `-ECHILD` (retry) where the ref variants return `-EXDEV` (final).
     Source: `fs/namei.c:1136-1139` (`nd_jump_root`), `:1177-1179` (`nd_jump_link`),
     `:1559-1560` (`follow_automount`), `:1585-1587` and `:1606-1608`
     (`__traverse_mounts`), `:1692-1693` (`__follow_mount_rcu`), `:2167-2168`
     (`follow_dotdot_rcu`, `-ECHILD`), `:2210-2211` (`follow_dotdot`, `-EXDEV`).
     Break: returning `-EXDEV` from an RCU-mode site turns a retryable condition
     into a user-visible failure; returning `-ECHILD` from a ref-mode site loops.

---

## 4. Path-walk invariants

### 4.1 The two modes

145. Path lookup has exactly two modes, RCU-walk (`LOOKUP_RCU`) and ref-walk, and
     the entry points attempt them in a fixed three-phase escalation: RCU, then
     ref, then ref with `LOOKUP_REVAL`.
     Source: `fs/namei.c:5029-5033` (`do_file_open`), `fs/namei.c:2842-2846`
     (`filename_lookup`), `fs/namei.c:5053-5057` (`do_file_open_root`);
     documented at `Documentation/filesystems/path-lookup.rst:659-666`.
     Break: collapsing or reordering the phases changes which errors are
     retryable. Note the documented one-way property: "The `LOOKUP_RCU` attempt may
     drop that flag internally and switch to REF-walk, but will never then try to
     switch back" (`Documentation/filesystems/path-lookup.rst:668-672`).

146. **The master RCU-walk invariant:** RCU-walk may only reach a conclusion that
     ref-walk could also have reached had it been walking at the same time. If it
     cannot, it must give up and restart from the top in ref-walk.
     Source: `Documentation/filesystems/path-lookup.rst:645-651`.
     Break: this is the property every seqcount check in the walk exists to
     maintain. Each `read_seqretry(&mount_lock, nd->m_seq)` in `__follow_mount_rcu`
     and `follow_dotdot_rcu` carries the comment "makes sure that non-RCU pathwalk
     could reach this state" (`fs/namei.c:1715-1718`, `:1721-1722`, `:2172-2174`).
     Removing one is invisible until it produces a path that never existed.

147. The mechanical translation rule: where ref-walk increments a refcount or takes
     a spinlock, RCU-walk samples a seqcount; where ref-walk decrements or unlocks,
     RCU-walk retries. The checks must be at or near the same places.
     Source: `Documentation/filesystems/path-lookup.rst:696-703`.
     Break: moving a seqcount check "for efficiency" breaks the correspondence.

148. A seqlock-protected value that is *used* rather than merely tested must be
     copied and then validated with `read_seqcount_retry()`.
     Source: `Documentation/filesystems/path-lookup.rst:706-713`; the retry is a
     read barrier, not only a comparison (`:712-713`).
     Break: using a field in place and validating afterwards is not equivalent.

149. In RCU-walk, **nothing pins anything**: `nd->path`, `nd->root`, `nd->inode` and
     every `nd->stack[i].link` hold **zero** references.
     Source: `path_init()` takes no reference in the RCU branches —
     `fs/namei.c:2707-2709` (`ND_ROOT_PRESET`), `:2728-2737` (`AT_FDCWD`),
     `:2761-2764` (dfd, where `nd->path = fd_file(f)->f_path` is a bare copy),
     `:2774-2775` (scoped root); `set_root()` `fs/namei.c:1117-1124`;
     `nd_jump_root()` `fs/namei.c:1146-1153`; `put_link()` `fs/namei.c:1200-1201`
     skips `path_put` under RCU; `terminate_walk()` `fs/namei.c:856-858` skips all
     `path_put`s under RCU.
     Break: **this is the single most important asymmetry in the whole file.** Any
     code that puts a reference on an RCU-mode `nd->path` under-counts; any code
     that fails to put one on a ref-mode `nd->path` leaks. The mode is carried only
     in `nd->flags & LOOKUP_RCU`, and there is no assertion at any `path_put` site.

150. In ref-walk, `nd->path` always holds a counted reference through **both**
     `d_lockref` and `mnt_count`.
     Source: `Documentation/filesystems/path-lookup.rst:387-396` ("A reference
     through `d_lockref` and `mnt_count` is always held").
     Break: see category 5.

### 4.2 Leaving RCU-walk

151. `try_to_unlazy()` legitimizes, in order: the link stack, `nd->path`, and
     `nd->root`; and it must leave RCU on *every* exit path.
     Source: `fs/namei.c:935-962` — `LOOKUP_CACHED` early-out `:941-945`,
     `legitimize_links()` `:946-947`, `legitimize_path()` `:948-949`,
     `legitimize_root()` `:950-951`, `leave_rcu()` on success `:952` and on both
     failure labels `:960`.
     Break: the order is not arbitrary. `legitimize_links()` failing sets
     `nd->depth = i + 1` (`fs/namei.c:897`) so that `terminate_walk()` puts exactly
     the entries that were legitimized and no more. Changing the order or the depth
     adjustment produces either a leak or a double-put.

152. On failure, `try_to_unlazy()` NULLs `nd->path.mnt` and `nd->path.dentry` at the
     `out1` label but only `nd->path.dentry` is left set at `out` — the distinction
     determines what `terminate_walk()` subsequently puts.
     Source: `fs/namei.c:956-961`.
     Break: `terminate_walk()` calls `path_put(&nd->path)` unconditionally in
     ref-walk (`fs/namei.c:849`), and `path_put()` dereferences both members
     (`fs/namei.c:722-723`). The NULLing is the only thing making the
     partially-legitimized case safe. `dput(NULL)` and `mntput(NULL)` are both
     no-ops, so this works — but it is **implicit**.

153. After `try_to_unlazy()` or `try_to_unlazy_next()` fails, nothing may touch the
     `nameidata` except `terminate_walk()`.
     Source: the contract is stated at `fs/namei.c:932-933` and `fs/namei.c:973-974`.
     Break: one of the few rules written down. Honour it.

154. `try_to_unlazy_next()` must legitimize the parent **before** the child, and the
     child's `d_seq` validates both because the parent's seq was checked after the
     child's seq was obtained.
     Source: `fs/namei.c:976-1029`; the sufficiency argument is the comment at
     `fs/namei.c:998-1004`; the parent grab at `:995`, the child grab at `:1005`,
     the child retry at `:1007`.
     Break: reversing the order invalidates the argument; the `out_dput` label at
     `fs/namei.c:1025-1028` exists specifically to release the child reference taken
     at `:1005` when the retry at `:1007` or `legitimize_root()` at `:1013` fails.

155. `__legitimize_path()` must take the mount reference first, then the dentry, then
     validate `d_seq` — and a `path_put()` is required afterwards **regardless of
     success or failure**.
     Source: `fs/namei.c:865-879`; the contract line is `fs/namei.c:864`; the mount
     at `:867`, the `res > 0` NULLing at `:869-870`, the dentry at `:874`, the seq
     at `:878`.
     Break: see rule 115 — the `res < 0` case deliberately leaves `path->mnt` set so
     the caller's `path_put()` releases the reference `__legitimize_mnt()` took.

156. `legitimize_root()` must skip `ND_ROOT_PRESET` roots (externally owned) and must
     set `ND_ROOT_GRABBED` **before** attempting the grab.
     Source: `fs/namei.c:904-911` — the skip at `:907`, the flag at `:909`, the grab
     at `:910`.
     Break: setting the flag after a successful grab would leak on the failure path,
     because `terminate_walk()` keys its `path_put(&nd->root)` on the flag
     (`fs/namei.c:852-855`), not on whether the grab succeeded. Setting it first and
     letting `terminate_walk()` put a NULLed path is the intended behaviour.

157. `try_to_unlazy()` asserts, always-on, that the inode cached in `nd->inode` still
     matches the legitimized dentry's `d_inode`.
     Source: `fs/namei.c:953` (`BUG_ON(nd->inode != parent->d_inode)`); the reason
     `nd->inode` can be trusted at all is
     `Documentation/filesystems/path-lookup.rst:787-789`.
     Break: this is one of the few always-compiled assertions on the path. It is the
     canary for a broken `nd->seq`/`nd->inode` correspondence.

158. `complete_walk()` must drop out of RCU before doing anything else, must clear
     `LOOKUP_CACHED`, and must not zero `nd->root` for scoped or externally-managed
     roots.
     Source: `fs/namei.c:1050-1066` — the `ND_ROOT_PRESET`/`LOOKUP_IS_SCOPED` guard
     at `:1060-1062`, the `LOOKUP_CACHED` clear at `:1063`, the unlazy at `:1064-1065`.
     Break: zeroing a scoped `nd->root` loses the scope for the `path_is_under()`
     check at `fs/namei.c:1085`.

159. On `complete_walk()` failure, the caller must **not** drop `nd->path`.
     Source: the contract is stated at `fs/namei.c:1047-1048`; `try_to_unlazy()`
     already NULLed the path (`fs/namei.c:956-958`) before returning false.
     Break: `do_open()` returns the error directly (`fs/namei.c:4800-4801`) and
     relies on `terminate_walk()` in `path_openat()` (`fs/namei.c:5001`) to clean up.
     Adding a `path_put()` in `do_open()` double-puts.

160. Scoped lookups get a final `path_is_under()` sanity check that must not be
     removed, even though the walk is supposed to guarantee scoping already.
     Source: `fs/namei.c:1068-1087`, with the rationale at `fs/namei.c:1069-1084`
     ("we want to avoid a namei BUG resulting in userspace being given a path that
     was not scoped within the root").
     Break: this is a deliberate belt-and-braces check against exactly the class of
     bug a path-walk redesign risks introducing. It must survive.

### 4.3 `terminate_walk()`

161. `terminate_walk()` is responsible for, in this order: running the delayed calls
     for every stack entry; in ref-walk only, putting `nd->path`, every
     `nd->stack[i].link` for `i < nd->depth`, and `nd->root` if `ND_ROOT_GRABBED`;
     in RCU-walk, leaving RCU; and in both cases zeroing `nd->depth` and `nd->path`.
     Source: `fs/namei.c:843-862` — `drop_links()` `:845-846`,
     `path_put(&nd->path)` `:849`, the stack loop `:850-851`, the root `:852-855`,
     `leave_rcu()` `:857`, the zeroing `:859-861`.
     Break: `drop_links()` (`fs/namei.c:826-834`) runs in **both** modes, because
     `->get_link()` may have registered a `delayed_call` even in RCU mode
     (`fs/namei.c:2064`). Moving it inside the ref-walk branch leaks whatever the
     filesystem allocated for the link body.

162. `terminate_walk()` must be called exactly once per `path_init()`.
     Source: the pairing is stated at `fs/namei.c:2676` ("must be paired with
     terminate_walk()"); the call sites are `fs/namei.c:2830` (`path_lookupat`),
     `fs/namei.c:5001` (`path_openat`), and the `path_parentat` equivalent.
     Break: **implicit** beyond that one comment. `path_lookupat()` hands the path
     out by copying it and NULLing `nd->path` (`fs/namei.c:2826-2829`) *before*
     calling `terminate_walk()` — this is the ownership transfer. A refactor that
     calls `terminate_walk()` first, or forgets the NULLing, either double-puts or
     returns a path the caller does not own.

### 4.4 The link stack, symlink limits and ELOOP

163. `MAXSYMLINKS` is 40 and bounds `nd->total_link_count`, which is carried across
     nested `nameidata` via `saved`.
     Source: `include/linux/namei.h:14`; the check at `fs/namei.c:1981-1982`
     (`reserve_stack`); propagation at `fs/namei.c:767` and `fs/namei.c:788-789`.
     Break: the budget is *per syscall*, not per nameidata. Losing the
     `total_link_count` propagation in `__set_nameidata`/`restore_nameidata` lets a
     nested lookup (e.g. from a filesystem's `->get_link`) reset the budget,
     reopening unbounded symlink recursion.

164. Automounts consume the same `MAXSYMLINKS` budget.
     Source: `fs/namei.c:1562-1563`, with `count` being `&nd->total_link_count`
     passed through `traverse_mounts()` at `fs/namei.c:1749`.
     Break: as rule 141.

165. The stack starts as the 2-entry embedded array `nd->internal` and is promoted to
     a `MAXSYMLINKS`-sized heap allocation on first overflow; the promotion in RCU
     mode uses `GFP_ATOMIC`.
     Source: `EMBEDDED_LEVELS` at `fs/namei.c:727`; the array at `fs/namei.c:743`;
     `nd_alloc_stack()` at `fs/namei.c:794-805` (allocation flags at `:799`);
     `reserve_stack()` at `fs/namei.c:1979-2003`; the free at `fs/namei.c:790-791`.
     Break: `restore_nameidata()` frees the stack only when `nd->stack !=
     nd->internal` (`fs/namei.c:790`). Any refactor that reallocates the stack must
     preserve that test exactly.

166. `reserve_stack()` in RCU mode must grab the link **before** attempting
     `try_to_unlazy()`, and must call `try_to_unlazy()` even if the grab failed,
     because cleanup needs it.
     Source: `fs/namei.c:1991-2001`; the comment at `fs/namei.c:1992-1993` states
     exactly this; the grab at `:1994`, the combined test at `:1996`.
     Break: the ordering is counter-intuitive and the comment is the only
     documentation. Short-circuiting the `try_to_unlazy()` on grab failure leaves
     the walk in RCU mode with a reference taken.

167. On `reserve_stack()` failure, `pick_link()` releases the link **only in
     ref-walk**.
     Source: `fs/namei.c:2023-2028`.
     Break: calling `path_put()` in RCU mode releases a reference that was never
     taken.

168. `pick_link()` in ref-walk must take an extra `mntget()` when `link->mnt ==
     nd->path.mnt`, because `handle_mounts()` only supplied a mount reference when it
     actually crossed a mount.
     Source: `fs/namei.c:2018-2021`; the corresponding conditional acquisition in
     `__traverse_mounts()` at `fs/namei.c:1596-1605`.
     Break: **this is the most easily-missed refcount rule in the walk.** Without it
     the stack entry and `nd->path` share one mount reference and
     `terminate_walk()`'s two `path_put()`s underflow `mnt_count`. With a
     *unconditional* `mntget()` the count leaks whenever a mount was crossed.

169. `pick_link()` pushes the stack entry (incrementing `nd->depth`) **before** the
     `may_follow_link()`, `LOOKUP_NO_SYMLINKS`/`MNT_NOSYMFOLLOW`, atime and
     `security_inode_follow_link()` checks, so every one of those error returns
     leaves the entry for `terminate_walk()` to release.
     Source: push at `fs/namei.c:2029-2032`; the checks at `:2034-2038`, `:2040-2042`,
     `:2044-2051`, `:2053-2056`.
     Break: **implicit.** Adding an early return *before* the push, or converting one
     of these to release the link itself, changes the ownership contract for every
     one of the other four.

170. `put_link()` decrements `nd->depth`, runs the delayed call, and `path_put()`s
     the link **only in ref-walk**.
     Source: `fs/namei.c:1196-1202`.
     Break: as rule 149.

171. `walk_component()` and `open_last_lookups()` must `put_link()` the current link
     before stepping into the next component, except when `WALK_MORE` says more
     components follow.
     Source: `fs/namei.c:2274-2275` and `:2286-2287` (`walk_component`);
     `fs/namei.c:4744-4745` and `:4778-4779` (`open_last_lookups`).
     Break: omitting a `put_link()` leaves `nd->depth` too high, which
     `terminate_walk()` will then correct by putting an entry the walk still
     considers live — in practice a double-put.

172. A symlink body that is a pure jump (empty result after processing) must
     `put_link()` itself.
     Source: `fs/namei.c:2084-2086` (the `all_done` label).
     Break: the pure-jump case is the only one where `pick_link()` pops its own
     entry; unifying the return paths leaks a stack slot.

173. `nd_jump_link()` — the magic-link entry point — must `path_put()` the *caller's*
     path on error and `path_put()` `nd->path` on success.
     Source: `fs/namei.c:1168-1194` — the error `path_put(path)` at `:1192`, the
     success `path_put(&nd->path)` at `:1185`.
     Break: the function consumes the reference the caller took in both cases. The
     contract is stated only in the comment at `fs/namei.c:1164-1167` ("caller must
     have taken a reference to path beforehand").

174. `nd_jump_link()` must refuse `LOOKUP_NO_MAGICLINKS`, `LOOKUP_NO_XDEV` across a
     mount change, and **all** scoped lookups.
     Source: `fs/namei.c:1173-1174`, `:1176-1180`, `:1181-1183` (with the comment
     "Not currently safe for scoped-lookups").
     Break: the scoped refusal is unconditional and deliberately conservative;
     relaxing it is a `RESOLVE_BENEATH`/`RESOLVE_IN_ROOT` escape.

### 4.5 `LOOKUP_*` flag semantics

175. The complete flag set, with the tree's own three reserved-bit gaps, is
     `include/linux/namei.h:17-46`. Per-flag semantics as enforced:
     - `LOOKUP_FOLLOW` (`:17`) — consumed in `step_into_slowpath()` at
       `fs/namei.c:2108-2110`: a trailing symlink is not followed if
       `(flags & WALK_TRAILING) && !(nd->flags & LOOKUP_FOLLOW)`.
     - `LOOKUP_DIRECTORY` (`:18`) — checked at `fs/namei.c:2822-2824`
       (`path_lookupat`) and `fs/namei.c:4820-4821` (`do_open`); also forces
       automount (rule 140).
     - `LOOKUP_AUTOMOUNT` (`:19`) — rule 140.
     - `LOOKUP_EMPTY` (`:20`) — permits a zero-length pathname; enforced in
       `getname_flags()` at `fs/namei.c:204-205`.
     - `LOOKUP_LINKAT_EMPTY` (`:21`) — additionally requires matching creds or
       `CAP_DAC_READ_SEARCH` on the dirfd, `fs/namei.c:2750-2754`.
     - `LOOKUP_DOWN` (`:22`) — `handle_lookup_down()` at the start,
       `fs/namei.c:2806-2810`.
     - `LOOKUP_MOUNTPOINT` (`:23`) — `handle_lookup_down()` at the end **and**
       clears `ND_JUMPED` to suppress `d_weak_revalidate()`,
       `fs/namei.c:2815-2818`.
     - `LOOKUP_REVAL` (`:24`) — the third escalation phase; also the terminator for
       `retry_estale()` (`include/linux/namei.h:217`).
     - `LOOKUP_RCU` (`:25`) — the mode bit; rule 149.
     - `LOOKUP_CACHED` (`:26`) — requires `LOOKUP_RCU` or the walk returns `-EAGAIN`
       before starting (`fs/namei.c:2683-2684`); forces `try_to_unlazy*` to fail
       outright (`fs/namei.c:941-945`, `:982-986`); cleared by `complete_walk()`
       at `fs/namei.c:1063`.
     - `LOOKUP_PARENT` (`:27`) — set for all but the last component
       (`fs/namei.c:2584`), cleared at the last (`fs/namei.c:2648`).
     - `LOOKUP_OPEN`/`LOOKUP_CREATE`/`LOOKUP_EXCL`/`LOOKUP_RENAME_TARGET`
       (`:31-34`) — passed to the filesystem as intent; `LOOKUP_EXCL` makes
       `lookup_one_qstr_excl()` return `-EEXIST` for a positive dentry
       (`fs/namei.c:1822-1825`) and `LOOKUP_CREATE` makes it tolerate a negative one
       (`fs/namei.c:1818-1821`). All three are cleared on a failed trailing
       `step_into()` (`fs/namei.c:4781-4782`).
     - `LOOKUP_NO_SYMLINKS` (`:39`) — `-ELOOP` in `pick_link()`, `fs/namei.c:2040-2042`.
     - `LOOKUP_NO_MAGICLINKS` (`:40`) — `-ELOOP` in `nd_jump_link()`, `fs/namei.c:1173-1174`.
     - `LOOKUP_NO_XDEV` (`:41`) — seven enforcement points, rule 144.
     - `LOOKUP_BENEATH` (`:42`) and `LOOKUP_IN_ROOT` (`:43`) — together
       `LOOKUP_IS_SCOPED` (`:45`); enforced at `fs/namei.c:1068-1087`
       (`complete_walk` final check), `fs/namei.c:1134-1135` and `:2189-2190`,
       `:2222-2223` (`..` at root), `fs/namei.c:1181-1183` (magic links),
       `fs/namei.c:2248-2260` (the `..` race detection), `fs/namei.c:2772-2780`
       (root set to the dirfd), `fs/namei.c:1114-1115` (`set_root()` WARNs).
     Break: each flag is enforced at exactly the sites listed. There is no central
     dispatcher, so a refactor that restructures the walk must re-derive this list.

176. `LOOKUP_IN_ROOT` changes the meaning of an absolute path: `path_init()` must
     **not** take the absolute-path shortcut, so that `nd->dfd` becomes the root.
     Source: `fs/namei.c:2719` (`if (*s == '/' && likely(!(flags & LOOKUP_IN_ROOT)))`).
     Break: losing the `LOOKUP_IN_ROOT` exclusion makes `RESOLVE_IN_ROOT` silently
     resolve absolute paths against the real root — a complete containment escape.

177. Scoped `..` handling must, after each `..`, re-check both `mount_lock` and
     `rename_lock` against the values sampled at `path_init()`, returning `-EAGAIN`
     on either.
     Source: `fs/namei.c:2248-2260` (barrier `:2255`, mount check `:2256-2257`,
     rename check `:2258-2259`); samples at `fs/namei.c:2696-2698`; rationale
     comment `fs/namei.c:2249-2254`; doc at
     `Documentation/filesystems/path-lookup.rst:239-244`.
     Break: this is the defence against a racing rename or mount moving the path
     above `nd->root` mid-walk. It is only correct because `m_seq` and `r_seq` are
     whole-walk snapshots (rule 121).

### 4.6 `openat2` / `open_how` / `RESOLVE_*`

178. `build_open_flags()` validates all of `how->flags`, `how->resolve` and
     `how->mode` and rejects unknown bits — unlike the legacy syscalls, which
     silently clear them.
     Source: `fs/open.c:1229-1232`; the contrast is noted at `fs/open.c:1224-1228`;
     legacy masking at `fs/open.c:1185-1198` (`build_open_how`).
     Break: openat2's extensibility contract depends on unknown bits being an error.

179. `RESOLVE_BENEATH` and `RESOLVE_IN_ROOT` are mutually exclusive.
     Source: `fs/open.c:1235-1236`.
     Break: allowing both makes the scoping semantics undefined.

180. The `RESOLVE_*` → `LOOKUP_*` mapping is one-to-one and unconditional except for
     `RESOLVE_CACHED`:
     `RESOLVE_NO_XDEV`→`LOOKUP_NO_XDEV` (`fs/open.c:1336-1337`),
     `RESOLVE_NO_MAGICLINKS`→`LOOKUP_NO_MAGICLINKS` (`:1338-1339`),
     `RESOLVE_NO_SYMLINKS`→`LOOKUP_NO_SYMLINKS` (`:1340-1341`),
     `RESOLVE_BENEATH`→`LOOKUP_BENEATH` (`:1342-1343`),
     `RESOLVE_IN_ROOT`→`LOOKUP_IN_ROOT` (`:1344-1345`),
     `RESOLVE_CACHED`→`LOOKUP_CACHED` **only after** rejecting
     `O_TRUNC|O_CREAT|__O_TMPFILE` with `-EAGAIN` (`:1346-1351`).
     UAPI definitions `include/uapi/linux/openat2.h:33-48`.
     Break: `RESOLVE_NO_SYMLINKS` is documented in the UAPI as implying
     no-magiclinks (`include/uapi/linux/openat2.h:37-38`), but the *implementation*
     maps only to `LOOKUP_NO_SYMLINKS`. The implication holds because magic links
     are only reachable through `nd_jump_link()` from a `->get_link`, which
     `pick_link()` refuses first at `fs/namei.c:2040-2042`. That is **implicit** —
     a refactor that reaches `nd_jump_link()` by another route breaks the documented
     UAPI guarantee without touching either flag.

181. `RESOLVE_CACHED` must fail the whole open with `-EAGAIN` rather than fall back
     to a blocking walk.
     Source: `fs/open.c:1346-1351`; `path_init()` `-EAGAIN` at `fs/namei.c:2683-2684`;
     `try_to_unlazy*` refusing at `fs/namei.c:941-945` and `:982-986`; the
     `VFS_BUG_ON(nd->flags & LOOKUP_CACHED)` in `legitimize_links()` at
     `fs/namei.c:891`.
     Break: that `VFS_BUG_ON` is compiled out without `CONFIG_DEBUG_VFS` (rule 0.4),
     so a refactor that lets a `LOOKUP_CACHED` walk reach `legitimize_links()` will
     simply take references it should not, on a production kernel, silently.

182. This tree adds `OPENAT2_REGULAR` (bit 32 of `how->flags`), carried internally as
     `__O_REGULAR`, which `do_dentry_open()` strips before the file becomes visible
     to userspace, and which is contradictory with `O_DIRECTORY`.
     Source: UAPI `include/uapi/linux/openat2.h:30`; the `BUILD_BUG_ON`s asserting
     non-aliasing at `fs/open.c:1208-1217`; the translation at `fs/open.c:1301-1304`
     with its rationale `:1293-1300`; the contradiction check at `fs/open.c:1273-1275`;
     the strip at `fs/open.c:1012`; enforcement at `fs/namei.c:4817-4818`.
     Break: the bit must remain unrepresentable in a C `int` so that legacy
     `open()`/`openat()` cannot express it — that is the whole point, asserted by
     `BUILD_BUG_ON_MSG` at `fs/open.c:1211-1212`.

183. `O_DIRECTORY|O_CREAT` is rejected, which also protects `O_TMPFILE` (which
     requires `O_DIRECTORY`).
     Source: `fs/open.c:1254-1255`, rationale `:1250-1253`; the `__O_TMPFILE`
     requirements at `fs/open.c:1258-1268`.
     Break: the comment states the coupling explicitly; removing the check
     reintroduces the historical "O_DIRECTORY|O_CREAT created regular files" bug.

184. `O_PATH` restricts the permissible flag set to `O_PATH_FLAGS` and zeroes
     `acc_mode`; `O_PATH` also suppresses `op->intent`.
     Source: `fs/open.c:1183` (`O_PATH_FLAGS`), `:1277-1282`, `:1319`.
     Break: an `O_PATH` open with a non-zero `acc_mode` would run `may_open()`
     permission checks that `O_PATH` is defined not to perform.

---

## 5. Reference-count and ownership invariants

This section is the core of the specification. Each rule is phrased as an
ownership assertion at a program point, so that it can be discharged
mechanically. Notation:

- `R(d)` = one count on `dentry->d_lockref.count`.
- `R(m)` = one count on `mnt_count` of a `struct vfsmount`.
- `R(p)` = the pair `R(d) + R(m)` for a `struct path` — note these are two
  independent counts that happen always to be acquired and released together
  by `path_get()`/`path_put()` (`fs/namei.c:707-712`, `:720-725`).
- `R(i)` = one count on `inode->i_count`.
- `R(f)` = one count on `file->f_ref`.
- `W(i)` = one unit of `inode->i_writecount` via `get_write_access()`.
- `W(m)` = one unit of the mount's per-CPU `mnt_writers` via
  `mnt_get_write_access()`.
- `F(sb)` = one unit of superblock freeze protection via `sb_start_write()`.

### 5.1 The `FMODE_OPENED` contract

This is the pivot of the whole open path. Everything else in this section
depends on it.

185. **Before `FMODE_OPENED` is set on a `struct file`, that file owns no
     `R(p)`, no `R(i)`, no `W(i)`, no `W(m)`, and no `f_op` reference.** The only
     things it owns are `f_cred` and the LSM blob.
     Source: `init_file()` at `fs/file_table.c:179-231` — `f_cred` at `:183`,
     LSM blob at `:184`, `__f_path` zeroed at `:199`, `f_op = NULL` at `:210`,
     `f_inode = NULL` at `:213`.
     Break: any code that stores into `__f_path` without a matching acquisition
     creates a `struct file` that looks owned but is not.

186. **After `FMODE_OPENED` is set, the file owns `R(p)` on `f_path`, and owns
     `R(i)`-equivalent access through `f_inode`, a `fops_get()` reference on
     `f_op`, and — if `FMODE_WRITER` — `W(i)` plus one or two `W(m)`.**
     Source: `FMODE_OPENED` is set at `fs/open.c:1000` (and at
     `fs/file_table.c:378` for `file_init_path()`); `path_get(&f->f_path)` at
     `fs/open.c:941`; `f->f_inode = inode` at `fs/open.c:942`; `fops_get` at
     `fs/open.c:967`; `file_get_write_access()` at `fs/open.c:957` setting
     `FMODE_WRITER` at `:960`; `i_readcount_inc()` at `fs/open.c:955`.
     Break: see rules 187–189.

187. **`FMODE_OPENED` is the sole discriminator `__fput()` uses to decide whether
     to release anything.** With it clear, `__fput()` jumps straight to
     `file_free()` and releases **nothing** — no `dput`, no `mntput`, no
     `fops_put`, no `put_file_access`, no `fsnotify_close`, no
     `security_file_release`.
     Source: `fs/file_table.c:493-494` (`goto out`) versus `:498-523`;
     `__fput_deferred()` has the same gate at `fs/file_table.c:566-569`.
     Break: **this is the rule most likely to be silently broken.** A refactor
     that takes `R(p)` before `FMODE_OPENED` is set, and then errors out to an
     `fput()`, leaks a dentry and a mount permanently, with no warning. A
     refactor that sets `FMODE_OPENED` before taking `R(p)` produces a
     `dput(NULL)`/`mntput(NULL)` — harmless today only because both are
     NULL-tolerant — or a use-after-free if the path was merely borrowed.

188. **`finish_open()` asserts, always-on, that `FMODE_OPENED` is not yet set.**
     Source: `fs/open.c:1055` (`BUG_ON(file->f_mode & FMODE_OPENED)`), with the
     comment "once it's opened, it's opened".
     Break: this is the only runtime enforcement of the contract anywhere. It
     covers the `->atomic_open` path only.

189. **`do_dentry_open()` has two distinct failure regimes, and they differ in
     what the file owns on return.**
     - Failures at or before `open(inode, f)` (`fs/open.c:996`) unwind through
       `cleanup_all`/`cleanup_file`: `fops_put(f->f_op)` `:1025`,
       `put_file_access(f)` `:1026`, `path_put(&f->f_path)` `:1028`,
       `__f_path.mnt = NULL` `:1029`, `__f_path.dentry = NULL` `:1030`,
       `f->f_inode = NULL` `:1031`. `FMODE_OPENED` was never set. **The file owns
       nothing on return; `fput()` will free it without touching anything.**
     - The failure at `fs/open.c:1017-1018` — `(f_flags & O_DIRECT) &&
       !(f_mode & FMODE_CAN_ODIRECT)` → `-EINVAL` — returns **after**
       `FMODE_OPENED` was set at `:1000`, and does **not** unwind. **The file owns
       the full set from rule 186, and `fput()` is the only correct disposal.**
     Source: as cited.
     Break: this asymmetry is entirely implicit. There is no comment and no
     assertion. A refactor that unifies the two error paths — the obvious
     tidy-up — will either leak (if it stops unwinding the early failures) or
     double-free (if it starts unwinding the `O_DIRECT` failure). See also
     rule 216 for the observability consequence.

190. **Within `cleanup_all`, the order of release is load-bearing:** `fops_put`
     needs `f_op`, `put_file_access()` needs both `f_inode` and `f_path.mnt`, and
     only then may `path_put()` and the NULLing of `f_inode` happen.
     Source: `fs/open.c:1025-1031`; `put_file_access()` at `fs/internal.h:121-128`
     reads `file->f_inode` at `:124`; `file_put_write_access()` at
     `fs/internal.h:113-119` reads `file->f_inode` at `:115` and
     `file->f_path.mnt` at `:116`, plus `backing_file_user_path(file)->mnt` at
     `:118`.
     Break: hoisting `path_put()` or the `f_inode = NULL` above
     `put_file_access()` releases mount write access against a NULL or freed
     mount.

191. `__fput()` releases in the order: `fsnotify_close`, `eventpoll_release`,
     `locks_remove_file`, `security_file_release`, `->fasync`, `->release`,
     `cdev_put`, `fops_put`, `file_f_owner_release`, `put_file_access`, `dput`,
     `dissolve_on_fput`, `mntput`, `file_free`.
     Source: `fs/file_table.c:496-525` — `:498`, `:503`, `:504`, `:506`,
     `:507-510`, `:511-512`, `:513-516`, `:517`, `:518`, `:519`, `:520`,
     `:521-522`, `:523`, `:525`.
     Break: `dentry` and `mnt` are cached in locals at `fs/file_table.c:488-489`
     *before* any of this runs, so `->release()` may legitimately alter
     `f_path`; the `dput`/`mntput` use the cached values. Removing the caching
     makes the teardown depend on what `->release()` did.

192. `put_file_access()` releases `i_readcount` for read-only files and
     `W(i)` + `W(m)` for `FMODE_WRITER` files, and these are mutually exclusive.
     Source: `fs/internal.h:121-128`; acquisition at `fs/open.c:954-961`.
     Break: a file that is both read and write takes the `FMODE_WRITER` branch
     only (`fs/open.c:956`); the `i_readcount` branch requires exactly
     `FMODE_READ` (`fs/open.c:954`). Changing either condition on one side
     without the other underflows `i_readcount` (which has a `BUG_ON`,
     `include/linux/fs.h:2887`) or leaks `i_writecount` (which has none).

### 5.2 `struct path` ownership through `path_openat()`

Numbered as ownership assertions at each program point.

193. At entry to `path_openat()` (`fs/namei.c:4980`), `nd` owns nothing; `file`
     does not yet exist.
     Source: `fs/namei.c:4986` allocates it.

194. After `path_init()` (`fs/namei.c:2677-2782`) returns successfully:
     - in ref-walk, `nd` owns `R(p)` on `nd->path`, and additionally `R(p)` on
       `nd->root` iff `ND_ROOT_GRABBED` is set;
     - in RCU-walk, `nd` owns **nothing**.
     Source: ref-walk acquisitions at `fs/namei.c:2711` (`ND_ROOT_PRESET`),
     `:2739` (`get_fs_pwd`), `:2766` (dfd), `:2777-2778` (scoped root);
     `set_root()` at `fs/namei.c:1126-1127`; the RCU branches take none
     (`:2707-2709`, `:2728-2737`, `:2762-2764`, `:2774-2775`).
     Break: rule 149.

195. In the `dfd` case in RCU mode, `nd->path` **borrows** the fd's path; validity
     is bounded by the `CLASS(fd_raw, f)` scope, which ends when `path_init()`
     returns.
     Source: `fs/namei.c:2744` (the class), `:2761` (the bare copy), `:2762-2764`
     (no `path_get`).
     Break: **implicit and subtle.** After `path_init()` returns, the fd reference
     is gone and the borrowed path is protected only by RCU plus the `m_seq`/`d_seq`
     protocol. A refactor that extends the borrow past the class scope in ref-walk
     mode — or that removes the `path_get()` at `fs/namei.c:2766` — produces a
     use-after-free that requires a racing `close()` to trigger.

196. At every point inside `link_path_walk()` (`fs/namei.c:2578-2674`), in
     ref-walk, `nd` owns `R(p)` on `nd->path` and `R(p)` on each
     `nd->stack[i].link` for `i < nd->depth`.
     Source: `Documentation/filesystems/path-lookup.rst:387-396`; the
     hand-over-hand transfer is described at `:453-461` and `:463-466`.
     Break: see rules 197–199.

197. `handle_mounts()` produces a `path` that owns `R(d)` unconditionally and
     `R(m)` **only if a mount was crossed** (i.e. `path->mnt != nd->path.mnt`).
     Source: `fs/namei.c:1728-1758`; the acquisition in `__traverse_mounts()` at
     `fs/namei.c:1602` (`dget`) and the conditional mount ownership tracked by
     `need_mntput` at `fs/namei.c:1605`; the no-cross fast path at
     `fs/namei.c:1638-1646` takes nothing new (`path->dentry` is the caller's
     dentry reference). Documented at
     `Documentation/filesystems/path-lookup.rst:453-458`.
     Break: this conditional mount ownership propagates into `step_into_slowpath()`
     (rule 198) and `pick_link()` (rule 168). It is the root cause of the two most
     error-prone refcount rules in the walk.

198. On the non-symlink path, `step_into_slowpath()` transfers ownership of `path`
     into `nd->path`: in ref-walk it releases the **old** `nd->path.dentry` and,
     only if the mount changed, the old `nd->path.mnt`.
     Source: `fs/namei.c:2117-2124` — `dput(nd->path.dentry)` `:2118`,
     conditional `mntput(nd->path.mnt)` `:2119-2120`, install `:2122`.
     Break: the `if (nd->path.mnt != path.mnt)` guard at `fs/namei.c:2119` is the
     counterpart of `need_mntput` in rule 197. Making either unconditional breaks
     the other.

199. On the `handle_mounts()` error path, the caller must release `path->dentry`
     unconditionally and `path->mnt` only if it differs from `nd->path.mnt`.
     Source: `fs/namei.c:1752-1756`.
     Break: as rules 197–198.

200. `follow_dotdot()` (ref-walk) `path_put()`s `nd->path` when it crosses up out
     of a mount, and returns a parent dentry that the caller owns `R(d)` on.
     Source: `fs/namei.c:2195-2225` — `path_put(&nd->path)` `:2207`, install
     `:2208`, `dget_parent()` `:2214`, the `dput(parent)` on the
     `path_connected()` failure `:2216`, `dget()` on the in-root path `:2224`.
     Break: the returned dentry is then consumed by `step_into()`
     (`fs/namei.c:2244`), which either installs it or releases it. Returning a
     borrowed dentry from either exit is a double-put.

201. `follow_dotdot_rcu()` returns a **borrowed** parent dentry and owns nothing.
     Source: `fs/namei.c:2155-2193`; no `dget` anywhere.
     Break: rule 149.

202. `nd_jump_root()` in ref-walk releases `nd->path` and takes a fresh `R(p)` on
     `nd->root`; in RCU-walk it takes nothing.
     Source: `fs/namei.c:1154-1158` versus `:1146-1153`.
     Break: as rule 149.

203. `path_lookupat()` transfers ownership of `nd->path` to the caller's `*path`
     by copying and then NULLing `nd->path`, **before** calling
     `terminate_walk()`.
     Source: `fs/namei.c:2825-2830`.
     Break: the NULLing at `fs/namei.c:2827-2828` is the ownership transfer. It is
     load-bearing and has no comment.

204. `do_o_path()` and `do_tmpfile()` own the `struct path` they obtained from
     `path_lookupat()` and must `path_put()` it on every exit.
     Source: `fs/namei.c:4968-4978` (`path_put(&path)` at `:4975`);
     `fs/namei.c:4945-4966` (`path_put(&path)` at `:4964`, plus `mnt_drop_write()`
     at `:4962`).
     Break: `do_o_path()` calls `vfs_open(&path, file)` at `fs/namei.c:4974`, which
     takes its *own* `R(p)` inside `do_dentry_open()` (`fs/open.c:941`). The
     `path_put()` at `:4975` releases the caller's reference, not the file's.
     Collapsing the two is a double-put.

205. At entry to `do_open()` (`fs/namei.c:4789`), `nd` owns `R(p)` on `nd->path`
     — after `complete_walk()` succeeded — and `file` owns nothing unless
     `FMODE_OPENED|FMODE_CREATED` is already set.
     Source: `fs/namei.c:4798-4802`.
     Break: the `!(file->f_mode & (FMODE_OPENED | FMODE_CREATED))` guard is what
     prevents a second `complete_walk()` on an already-terminated walk.

206. `vfs_open()` does **not** consume the caller's `R(p)`; it takes a fresh one.
     Source: `fs/open.c:1096-1111` — `file->__f_path = *path` at `:1100` is a bare
     copy; `do_dentry_open()` takes the reference at `fs/open.c:941`.
     Break: this is why `do_open()` never `path_put()`s `nd->path` — that is
     `terminate_walk()`'s job (`fs/namei.c:5001`). Making `vfs_open()` consume the
     reference would require changing every one of its seven callers.

207. `path_openat()` owns `R(f)` on `file` from `alloc_empty_file()` until either
     it returns the file or calls `fput_close()`.
     Source: `fs/namei.c:4986` (acquire), `:5003-5005` (return), `:5009`
     (`fput_close`).
     Break: `fput_close()` (`fs/file_table.c:626-630`) is the
     optimised-for-last-reference variant; it still routes to `__fput_deferred()`
     and therefore still honours the `FMODE_OPENED` gate.

208. `path_openat()` enforces, with an always-on `WARN_ON`, that a zero return
     implies `FMODE_OPENED`.
     Source: `fs/namei.c:5003-5008`.
     Break: this is the second of the two always-on assertions guarding the
     contract. It catches a success path that forgot to open, but **not** an error
     path that forgot to unwind.

209. `FD_ADD()` takes ownership of the file and, on success, transfers it to the
     fd table; on failure the cleanup class releases it.
     Source: `include/linux/file.h:252-253` → `:236-243` → `FD_PREPARE` `:217-218`
     → `__FD_PREPARE_INIT` `:195-204`; `fd_publish()` at `include/linux/file.h:224-233`
     with `fd_install()` `:230` and `retain_and_null_ptr(fdp->__file)` `:231`.
     Break: the `retain_and_null_ptr()` at `include/linux/file.h:231` is what stops
     the cleanup class from putting a file that `fd_install()` now owns. It is the
     ownership transfer and it is a single token.

### 5.3 `atomic_open()` / `lookup_open()` / `finish_open()` / `finish_no_open()`

210. `atomic_open()` **consumes the caller's `R(d)` on `dentry` in every case** —
     success, replacement, and error.
     Source: the contract is documented at `fs/namei.c:4354-4355` ("The reference
     to @dentry is consumed in either case"); implementation: the
     `dput(dentry); dentry = dget(opened)` swap at `fs/namei.c:4377-4378`, the
     `dput(dentry); dentry = replaced` at `:4385-4386`, and the error `dput(dentry)`
     at `:4411`.
     Break: one of the few ownership contracts that *is* written down.

211. `atomic_open()` seeds `file->__f_path.dentry` with the sentinel
     `DENTRY_NOT_SET` and `__f_path.mnt` with the parent's mount, and treats a
     filesystem that leaves the sentinel in place as `-EIO`.
     Source: `fs/namei.c:4361`, `:4365-4366`, the detection at `:4390-4396`
     (`WARN(1, "...left file->f_path.dentry unset!")`).
     Break: `__f_path.mnt` is set **before** `->atomic_open()` and is *not* a
     counted reference at that point — `do_dentry_open()` will take it via
     `path_get()` only if the filesystem calls `finish_open()`. A refactor that
     takes the mount reference eagerly at `fs/namei.c:4366` leaks it on the
     `finish_no_open()` path.

212. `finish_open()` does **not** consume the dentry reference;
     `finish_no_open()` **does**.
     Source: `fs/open.c:1046-1048` ("the dentry reference is _not_ consumed") and
     `fs/open.c:1070-1071` ("unlike finish_open() this function does consume the
     dentry reference").
     Break: both are documented. Both are exported to filesystems
     (`fs/open.c:1060`, `:1083`), so the contract is an external ABI.

213. `lookup_open()` returns a dentry the caller owns `R(d)` on, or an `ERR_PTR`;
     it releases the parent's `i_rwsem` and any `W(m)` it took, on every path.
     Source: `fs/namei.c:4431-4600` — `mnt_want_write` `:4451`, lock `:4457-4460`,
     the `out:` label `:4570-4594` performing unlock `:4577-4580` and
     `mnt_drop_write` `:4582-4583`, `out_dput:` `:4596-4599`.
     Break: the unlock at `fs/namei.c:4577-4580` is keyed on
     `(open_flag & O_CREAT) || create_error` — **not** on the same condition used
     to take the lock at `fs/namei.c:4457` (`open_flag & O_CREAT`). They differ
     because `open_flag` has `O_CREAT` cleared at `fs/namei.c:4517-4518` when
     `create_error` is set. Any refactor of the `create_error` logic must preserve
     this or it takes a shared lock and drops an exclusive one.

214. When `lookup_open()` reports `FMODE_OPENED|FMODE_CREATED`,
     `open_last_lookups()` transfers ownership: it `dput()`s the old
     `nd->path.dentry` and installs the new dentry, which `nd->path` now owns.
     Source: `fs/namei.c:4771-4775`.
     Break: `nd->path.mnt` is unchanged here — the new dentry is on the same mount
     — so only the dentry reference moves. Adding an `mntget`/`mntput` pair here is
     a leak.

215. `vfs_tmpfile()` sets `__f_path` to `{parentpath->mnt, child}` before calling
     `->tmpfile()`, then `dput(child)` unconditionally, relying on the filesystem
     having taken its own reference via `finish_open()`.
     Source: `fs/namei.c:4886-4893`.
     Break: the `dput(child)` at `fs/namei.c:4893` runs on both success and
     failure. If `->tmpfile()` did not call `finish_open()`, `file->__f_path.dentry`
     is left dangling — but `FMODE_OPENED` is then clear, so `__fput()` never
     touches it (rule 187). The safety depends entirely on that gate.

### 5.4 `file->f_path` / `__f_path` lifetime

216. `f_path` is `const`; `__f_path` is the writable alias, and its use is
     restricted by the header to "core VFS and only before the file gets open".
     Source: the union at `include/linux/fs.h:1267-1270`; the restriction is
     stated at `include/linux/fs.h:1240-1241`.
     Break: the complete set of legitimate writers in this tree is
     `fs/file_table.c:199` (zeroing), `fs/file_table.c:364` (`file_init_path`),
     `fs/open.c:1029-1030` (teardown), `fs/open.c:1057` (`finish_open`),
     `fs/open.c:1081` (`finish_no_open`), `fs/open.c:1100` (`vfs_open`),
     `fs/namei.c:4365-4366` (`atomic_open`), `fs/namei.c:4889-4890`
     (`vfs_tmpfile`). This is the checklist: any new writer is a contract
     violation, and the `const` is the only enforcement.

217. `fput()` may defer `__fput()` to task work or to a workqueue; the deferred
     path is taken for interrupt context and kernel threads.
     Source: `fs/file_table.c:586-590` (`fput`), `:562-584` (`__fput_deferred`) —
     the `!in_interrupt() && !(task->flags & PF_KTHREAD)` test at `:571`, the
     `task_work_add(..., TWA_RESUME)` at `:573`, the fall-through to the
     `delayed_fput_list` llist at `:582-583` when `task_work_add` fails after
     `exit_task_work()` (rationale `:575-579`).
     Break: `__fput_deferred()` repeats the `FMODE_OPENED` gate at
     `fs/file_table.c:566-569` — with `FMODE_BACKING` also accepted. The two gates
     must stay in agreement with `__fput()`'s at `fs/file_table.c:493`.

218. `__fput_sync()` and `fput_close_sync()` run `__fput()` inline and must only be
     used where that is provably safe.
     Source: `fs/file_table.c:601-606` with the warning comment `:593-600`;
     `fs/file_table.c:614-618` with `:608-613`.
     Break: the comments state the constraint; there is no assertion.

219. `flush_delayed_fput()` must not be called with locks held or from a thread
     that might need to do umount work.
     Source: `fs/file_table.c:555-560`, with the warning at `fs/file_table.c:545-554`.
     Break: documented; no assertion.

220. `struct file` is allocated from a `SLAB_TYPESAFE_BY_RCU` cache, so a freed
     file's memory may be immediately reused for another file while RCU readers
     still hold a pointer to it.
     Source: `fs/file_table.c:639-641`; `file_ref_init()` deliberately last in
     `init_file()` at `fs/file_table.c:229` with the rationale `:224-228`.
     Break: this is why `f_ref` must be the last field initialised, and why
     `security_file_alloc()` sees garbage (rule 53).

### 5.5 Dentry refcount rules

221. `dget()` requires that the caller already holds a reference; using it on a
     zero-count dentry is a bug, and calling it under that dentry's `d_lock` (or a
     descendant's) is a deadlock.
     Source: `include/linux/dcache.h:361-366`, with the rules stated at
     `include/linux/dcache.h:351-358`.
     Break: documented.

222. `dget_dlock()` requires `d_lock` held **and** independent knowledge that the
     dentry is alive; it is a bare increment with no dead check.
     Source: `include/linux/dcache.h:336-340`; the sufficient conditions are
     enumerated at `include/linux/dcache.h:330-334` ("anything with non-negative
     refcount is alive, so's anything hashed, anything positive, anyone's parent").
     Break: documented.

223. `lockref_get_not_dead()` succeeds on a **zero** count and fails only on a
     negative one; `lockref_get_not_zero()` fails on both. The path walk uses the
     former.
     Source: `lib/lockref.c:143-163` (`:149`, `:156`) versus `lib/lockref.c:61-80`
     (`:67`, `:74`); `__LOCKREF_DEAD_VAL = -128` at `include/linux/lockref.h:37`.
     Walk call sites: `fs/namei.c:874`, `:995`, `:1005`; `fs/dcache.c:2787`.
     `dget_parent()` uses `get_not_zero` at `fs/dcache.c:1108`.
     Break: substituting one for the other in `__legitimize_path()` makes RCU→ref
     promotion fail for every dentry that is cached-but-unreferenced — i.e. the
     common case — silently converting the fast path into a slow path. In the other
     direction it promotes dead dentries.

224. A dentry is marked unrecoverably dead by `lockref_mark_dead()` under `d_lock`,
     and `DCACHE_DENTRY_KILLED` is set *later*, after `->d_release()`.
     Source: `lib/lockref.c:131-135` (with the lock assertion at `:133`);
     the single fs caller `fs/dcache.c:810` with the comment `:807-809`;
     `DCACHE_DENTRY_KILLED` at `include/linux/dcache.h:221`, set at
     `fs/dcache.c:664`.
     Break: the window between them is the documented "half-killed" state —
     `Documentation/filesystems/porting.rst:1114-1121`: "`->d_iput()` and
     `->d_release()` are called with victim dentry still in the list of parent's
     children... taking `->d_lock` on those will see them negative, unhashed and
     with negative refcount."

225. `dput()` may sleep.
     Source: `fs/dcache.c:1039` (`might_sleep()`).
     Break: any `dput()` added inside an RCU read-side section or a spinlock is a
     sleep-in-atomic. This is the failure mode of "just release it here" fixes in
     the RCU-walk region.

226. `dput()`'s slow path returns from `fast_dput()` with `d_lock` held and the
     refcount guaranteed zero.
     Source: the contract is stated at `fs/dcache.c:925-927`; implementation
     `fs/dcache.c:929-996`, using `lockref_put_return()` at `:939` and taking
     `rcu_read_lock()` *before* the decrement at `:938` (rationale `:934-937`).
     Break: `lockref_put_return()` returns `-1` both for a dead lockref and for a
     *held spinlock* (`lib/lockref.c:88`, `:94-95`, `:99`), and on non-cmpxchg
     builds it always returns `-1` (`lib/lockref.c:31`). Code that interprets `-1`
     as "dead" is wrong on half the architectures.

227. `dentry_kill()` is passed a reference that **does not** contribute to the
     count, requires `d_lock` held, drops it, and the caller must not touch the
     dentry afterwards. It returns the parent with `d_lock` held iff this eviction
     dropped the parent's last reference.
     Source: the full contract at `fs/dcache.c:761-798`; implementation
     `fs/dcache.c:799-851`; the parent return at `:846-850`.
     Break: documented in detail. Honour it verbatim.

228. A dentry that is some other dentry's `d_parent` always has a nonzero refcount.
     Source: **implicit**, asserted by `BUG_ON(!ret->d_lockref.count)` in
     `dget_parent()` at `fs/dcache.c:1130`.
     Break: this always-on `BUG_ON` is the only statement of the invariant.

229. A counted reference on a **positive** dentry transitively pins the inode,
     because `d_delete()` only nulls `d_inode` when the count is exactly 1.
     Source: `fs/dcache.c:2687-2706` — the `d_lockref.count == 1` test at `:2696`,
     `dentry_unlink_inode()` at `:2700`, the unhash-only alternative at `:2701-2705`;
     stated as a rule at `Documentation/filesystems/path-lookup.rst:193-194` ("as
     long as a counted reference is held to a dentry, a non-`NULL` `->d_inode` value
     will never be changed").
     Break: **this is the invariant that makes `nd->inode` safe to cache.**
     `try_to_unlazy()`'s `BUG_ON(nd->inode != parent->d_inode)` (`fs/namei.c:953`)
     is its enforcement. A change to `d_delete()`'s threshold breaks path-walk in a
     way that only shows up under concurrent unlink.

230. A reference on a **negative** dentry pins a cached negative result and no
     inode.
     Source: `d_inode == NULL` by construction; `__d_clear_type_and_inode()` at
     `fs/dcache.c:414-427`.
     Break: note the in-tree TODO at `include/linux/dcache.h:496` — `d_is_negative()`
     does **not** currently include whiteouts, so a whiteout is `d_is_positive()`.
     Any rule phrased as "whiteouts are negative" is false in this tree.

231. The inode reference held by a positive dentry is taken by the **caller** of
     `d_instantiate()`/`d_add()`/`d_splice_alias()`, never by those functions.
     Source: stated at `fs/dcache.c:2167-2169` ("This assumes that the inode count
     has been incremented ... by the caller"); `__d_instantiate()` at
     `fs/dcache.c:2138-2155` and `__d_add()` at `fs/dcache.c:2934-2941` contain no
     `__iget`/`ihold`; `d_splice_alias_ops()` disposes of the caller's reference
     with `iput(inode)` at `fs/dcache.c:3286` when it returns an existing alias.
     Break: `d_splice_alias()` consuming the reference in one branch and the caller
     retaining it in another is exactly the kind of asymmetry a refactor gets wrong.

232. The inode reference is released by `dentry_unlink_inode()`, via `->d_iput()` if
     the filesystem provides one, else `iput()`.
     Source: `fs/dcache.c:457-480`, the dispatch at `:476-479`.
     Break: a filesystem providing `d_iput` **owns** the reference; the VFS must not
     also `iput()`.

233. `d_seq` write sites are exactly five: `dentry_unlink_inode()`
     (`fs/dcache.c:463`/`:471`), `__d_drop()` (`write_seqcount_invalidate` at
     `fs/dcache.c:579`), `__d_instantiate()` (`:2151`/`:2153`), `__d_add()`
     (`:2937`/`:2939`), and `__d_move()` (`:3092`/`:3093` … `:3125`/`:3126`,
     nested and unwound in reverse).
     Source: as listed; `d_seq` is bound to `d_lock` by
     `seqcount_spinlock_init()` at `fs/dcache.c:1947`, so all writers hold `d_lock`.
     Break: a successful `read_seqcount_retry(&dentry->d_seq, seq)` guarantees that
     none of those five happened. It guarantees **nothing** about
     `d_lockref.count`, `d_lru`, `d_children`, or most `d_flags` bits. A refactor
     that relies on `d_seq` to validate something outside that set is unsound.

234. `__d_lookup_rcu()` returns a **bare pointer with no reference and no lock**,
     plus a `d_seq` sample taken before the field comparisons; the caller must
     validate before storing or using any state.
     Source: `fs/dcache.c:2469-2544`; contract at `fs/dcache.c:2456-2467`.
     Break: documented.

235. `__d_lookup()` returns a **counted** reference; `d_lookup()` additionally
     retries under `rename_lock` so that a NULL result is authoritative.
     Source: `fs/dcache.c:2587-2641` (increment at `:2631`);
     `fs/dcache.c:2557-2569` (the retry loop at `:2562-2567`); the false-negative
     caveat at `fs/dcache.c:2578-2579` and the mandate at `:2585`
     ("`__d_lookup` callers must be commented").
     Break: `lookup_fast()` uses the un-retried `__d_lookup` at `fs/namei.c:1878`
     and carries the required comment at `fs/namei.c:1848-1852`. Substituting
     `d_lookup()` is correct but slower; substituting `__d_lookup()` where
     `d_lookup()` was used makes a NULL result non-authoritative.

236. `d_revalidate()` returning 0 obliges the caller to `d_invalidate()`; a negative
     return does not.
     Source: `fs/namei.c:1883-1888` (`lookup_fast`), `fs/namei.c:1771-1776`
     (`lookup_dcache`), `fs/namei.c:1909-1914` (`__lookup_slow`, which additionally
     retries the whole allocation), `fs/namei.c:4481-4485` (`lookup_open`).
     Break: four sites, same policy, no shared helper. A refactor must keep all four
     in agreement.

### 5.6 Inode reference rules

237. `i_state` is not a bare field in this tree; it is
     `struct inode_state_flags i_state` and must be accessed through the
     `inode_state_*()` accessors, the non-`_raw` forms of which assert `i_lock`.
     Source: `include/linux/fs.h:814`, `:753-755`, the mandate at
     `include/linux/fs.h:750-752` and `:873-877`; accessors at
     `include/linux/fs.h:878-945`.
     Break: direct `inode->i_state` access does not compile — that is the point.
     Using a `_raw` variant outside a documented no-concurrency window silently
     drops the lockdep guarantee.

238. `icount_read()` asserts `i_lock` and its guarantee is precisely: no 0→1 or 1→0
     transition can occur while the lock is held.
     Source: `include/linux/fs.h:2233-2237`, the guarantee stated at
     `include/linux/fs.h:2229-2232`; the lockless variant `icount_read_once()` at
     `:2224-2227`.
     Break: this sentence is the exact statement of what `i_lock` buys for
     refcounting. Any reasoning about `i_count` that does not cite it is unsound.

239. `__iget()` requires `i_lock`; `ihold()` does not, but requires that the caller
     already holds a reference.
     Source: `include/linux/fs.h:3032-3036` (assertion at `:3034`);
     `fs/inode.c:1578-1583` (assertion at `:1580`, `WARN_ON` at `:1581`),
     precondition stated at `fs/inode.c:1575`.
     Break: substituting `ihold()` for `__iget()` where no reference is held is a
     use-after-free that the `VFS_BUG_ON_INODE` at `fs/inode.c:1580` only catches
     under `CONFIG_DEBUG_VFS`.

240. It is illegal to take a reference on an inode with `I_FREEING` or `I_WILL_FREE`
     set; both can only be set when `i_count == 0`.
     Source: stated at `fs/inode.c:1628-1629`; enforced by `igrab()` at
     `fs/inode.c:1596-1606`.
     Break: the statement in `igrab_from_hash()`'s header comment
     (`fs/inode.c:1612-1634`) is the authoritative one, including the note that
     `atomic_add_unless` provides the acquire fence pairing with the `smp_wmb()`
     before `I_NEW` is cleared (`fs/inode.c:1623-1626`; paired sites
     `fs/inode.c:1213`, `:1228`, `fs/dcache.c:2206`).

241. `iput()` may sleep, must not be called with `i_lock` held, and
     `iput_final()` drops `i_lock` itself and may free the inode.
     Source: `fs/inode.c:2027-2066` — `might_sleep()` `:2029`,
     `lockdep_assert_not_held(&inode->i_lock)` `:2034`,
     `VFS_BUG_ON_INODE(state & (I_FREEING|I_CLEAR))` `:2035`; `iput_final()` at
     `fs/inode.c:1971-2016`.
     Break: the `VFS_BUG_ON_INODE`s are compiled out without `CONFIG_DEBUG_VFS`;
     the `lockdep_assert_not_held` requires lockdep.

242. An inode must be removed from the LRU **before** `I_FREEING` is set, and
     atomically with it; `evict()` asserts the terminal state.
     Source: the requirement is stated at `fs/inode.c:791-797`, asserted at
     `fs/inode.c:803-804`; the terminal assertion is
     `BUG_ON(inode_state_read_once(inode) != (I_FREEING | I_CLEAR))` at
     `fs/inode.c:844`.
     Break: an always-on `BUG_ON`.

243. Filesystems whose inodes are reachable from RCU-walk **must** RCU-free them,
     and must not touch `i_dentry` in the RCU callback (it shares storage with
     `i_rcu`).
     Source: `Documentation/filesystems/porting.rst:396-400` (marked **mandatory**)
     and `:402-405`; the union at `include/linux/fs.h:834-837`; the reliance at
     `fs/dcache.c:1237-1239`.
     Break: this is a filesystem-facing contract that a VFS refactor can invalidate
     by widening what RCU-walk dereferences.

### 5.7 Write-access and freeze references

244. `get_write_access()` returns `-ETXTBSY` and takes `W(i)`; `put_write_access()`
     is an unconditional decrement. `deny_write_access()` takes a `struct file *`
     while `get_write_access()` takes an inode — an asymmetric pair.
     Source: `include/linux/fs.h:2833-2836`, `:2837-2841`, `:2842-2845`, `:2846-2850`;
     semantics documented at `include/linux/fs.h:2812-2832`.
     Break: `put_write_access()` has no sign check, so an unmatched call silently
     drives `i_writecount` negative, which makes the file permanently
     un-executable.

245. `handle_truncate()` takes `W(i)` and releases it on every path.
     Source: `fs/namei.c:4290-4306` — acquire `:4294`, release `:4304`.
     Break: rule 49.

246. `touch_atime()` takes `F(sb)` by *trylock* and `W(m)`, releases both, and
     ignores the result of the update.
     Source: `fs/inode.c:2303-2333` — `sb_start_write_trylock()` `:2311-2312`
     (silent return on failure), `mnt_get_write_access()` `:2314-2315`,
     `mnt_put_write_access()` `:2329`, `sb_end_write()` `:2331`; the
     deliberately-ignored return is explained at `fs/inode.c:2316-2324`.
     Break: `touch_atime()` therefore **blocks** and must never be called under
     freeze protection or in RCU-walk — which is why `pick_link()` drops out of RCU
     first (`fs/namei.c:2045-2048`).

---

## 6. Observability and side effects that must still happen

### 6.1 `fsnotify_open` / `fsnotify_close` symmetry

247. Once a file has `FMODE_OPENED`, `__fput()` **will** call `fsnotify_close()`.
     Therefore every path that hands out a file with `FMODE_OPENED` set must have
     called `fsnotify_open()`.
     Source: `fs/file_table.c:493-494` (the gate) and `fs/file_table.c:498` (the
     close); the requirement is stated in the comment at `fs/open.c:1103-1106`
     ("Once we return a file with FMODE_OPENED, `__fput()` will call
     `fsnotify_close()`, so we need `fsnotify_open()` here for symmetry").
     Break: **there is no "open was notified" flag.** The symmetry is maintained
     only by construction, at four call sites (rule 248), all guarded by the same
     `FMODE_OPENED` test. Adding a fifth way to hand out an opened file without a
     matching `fsnotify_open()` produces an unpaired `FS_CLOSE_*` event, which
     breaks every fanotify/inotify consumer's open/close accounting — and nothing
     in the kernel detects it.

248. The complete set of `fsnotify_open()` call sites is:
     `fs/open.c:1108` (in `vfs_open()`, after a successful `do_dentry_open()`),
     `fs/namei.c:4575` (in `lookup_open()`, guarded at `:4574`, **while
     `dir_inode` is still locked** — unlock at `:4578`/`:4580`),
     `fs/namei.c:4895` (in `vfs_tmpfile()`, guarded at `:4894`, fired **before**
     the error check at `:4896` and before `may_open()` at `:4899`), and
     `fs/namei.c:5205` (in `dentry_create()`, guarded at `:5204`).
     Source: as listed.
     Break: this is the checklist. Note that `do_dentry_open()` and `finish_open()`
     do **not** fire it — which is exactly why the `atomic_open` path needs the
     explicit call at `fs/namei.c:4575`.

249. Both events are suppressed for the same file by the `FMODE_NONOTIFY*` bits,
     which is what keeps the pairing correct for `O_PATH` and pseudo files.
     Source: `fsnotify_file()` early-return at `include/linux/fsnotify.h:124-125`
     with the rationale at `:118-123`; `fsnotify_open()` at
     `include/linux/fsnotify.h:443-451`; `fsnotify_close()` at `:456-462`;
     `file_set_fsnotify_mode()` at `include/linux/fs.h:2873-2877`; suppression
     sites `fs/file_table.c:208` (default `FMODE_NONOTIFY_PERM`, rationale
     `:204-206`), `fs/open.c:949` (`O_PATH`), `fs/file_table.c:437` and `:466`
     (pseudo files), `fs/open.c:1141` (`dentry_open_nonotify`, set **before**
     `vfs_open` at `:1142`). Bit semantics at `include/linux/fs.h:175`, `:181`,
     `:201-202`, table at `:192-199`, predicates `:204-214`.
     Break: the suppression must be symmetric. `dentry_open_nonotify()` sets the
     bit before `vfs_open()` precisely so that both the open and the later close
     are suppressed; setting it after would suppress only the close.

250. **There is one existing asymmetry in this tree.** The `O_DIRECT` failure in
     `do_dentry_open()` (`fs/open.c:1017-1018`) returns `-EINVAL` **after**
     `FMODE_OPENED` was set at `:1000`. `vfs_open()` therefore does not call
     `fsnotify_open()` (it is gated on `ret == 0`, `fs/open.c:1102`), but the
     subsequent `fput_close()` reaches `__fput()` with `FMODE_OPENED` set and fires
     `fsnotify_close()`.
     Source: as cited; `fs/namei.c:5009` (`fput_close`), `fs/file_table.c:493-498`.
     Break: recorded here because a refactor must not *widen* it, and because a
     future fix must change the failure path, not the notification. Whether this is
     a known and accepted asymmetry is **not established from source** — there is
     no comment either way.

### 6.2 fanotify permission events

251. `fsnotify_open_perm_and_set_mode()` is called inside `do_dentry_open()`, after
     `security_file_open()` and before `break_lease()` and `->open()`.
     Source: `fs/open.c:983`, between `:973` and `:987`; the comment at
     `fs/open.c:978-982`.
     Break: the ordering means the **LSM verdict is taken before userspace is
     consulted**, so an LSM denial never blocks on a fanotify daemon. That is a
     deliberate property; reversing it makes every LSM-denied open wait on
     userspace.

252. A denial from the permission event unwinds through `cleanup_all` with
     `FMODE_OPENED` never set, so no `fsnotify_close()` can fire for it.
     Source: `fs/open.c:984-985` → `:1022-1032`; the gate at `fs/file_table.c:493`.
     Break: this is the symmetry invariant for the denial case, and it depends on
     the hook being called *before* `fs/open.c:1000`.

253. The permission event can block indefinitely on userspace, killable and
     freezable only.
     Source: `fanotify_get_response()` at `fs/notify/fanotify/fanotify.c:222-289`,
     the wait at `:230-232`
     (`wait_event_state(..., TASK_KILLABLE|TASK_FREEZABLE)`); invoked at
     `fs/notify/fanotify/fanotify.c:1007-1010`; denial mapping at `:260-274`
     (`FAN_ALLOW`→0 `:261-263`, custom errno `:264-270`, default `-EPERM`
     `:272-273`), audit at `:276-281`, signal handling `:234-257` (`-ERESTARTSYS`,
     kerneldoc `:215-221`).
     Break: any lock held across `fs/open.c:983` is held for an unbounded time.
     The set currently held is: `f_path` pinned, `fops_get` reference, write
     access if `FMODE_WRITE`, and — on the `->atomic_open` path — the parent
     directory's `i_rwsem` (rule 79). No sb freeze protection.

254. Superblock freeze protection must **not** be held across a permission event
     — but this rule is stated and enforced only for the read/write/mmap/truncate
     hooks, and **the open-permission hook is reached with freeze protection held
     on the `O_TRUNC` path**.
     Source: the rule and rationale are at `include/linux/fsnotify.h:140-148`
     ("filesystem may be modified in the context of permission events (e.g. by HSM
     filling a file on access), so sb freeze protection must not be held"),
     enforced by `lockdep_assert_once(file_write_not_started(file))` at
     `include/linux/fsnotify.h:150` — which guards `fsnotify_file_area_perm()`
     (`include/linux/fsnotify.h:137-169`) and its siblings `:174-184`, `:189-199`,
     `:204-207`, but **not** `fsnotify_open_perm_and_set_mode()`.
     The open path reaches it holding `F(sb)`: `do_open()` calls
     `mnt_want_write(nd->path.mnt)` at `fs/namei.c:4830` for a regular-file
     `O_TRUNC` open; `mnt_want_write()` takes `sb_start_write(m->mnt_sb)` at
     `fs/namespace.c:494`; the reference is not dropped until `fs/namei.c:4847`;
     and `fsnotify_open_perm_and_set_mode()` is called at `fs/open.c:983`, inside
     `vfs_open()` at `fs/namei.c:4837`, which lies between them.
     Break: record this as a fact about the current tree, not as a rule to
     preserve. Whether the exemption for the open hook is deliberate is **not
     established from source** — there is no comment either way, and the
     `file_write_not_started()` predicate itself is documented as possibly
     false-positive (`include/linux/fs.h:1744-1756`). A redesign that adds the
     assertion to the open hook will trip on every `O_TRUNC` open; a redesign that
     moves `mnt_want_write()` later must not reorder it past
     `security_file_post_open()` (rule 46).

255. SRCU must be dropped before blocking on a permission event.
     Source: `fsnotify()` holds `fsnotify_mark_srcu` across the group loop
     (`fs/notify/fsnotify.c:568` … `:607`); `fanotify_handle_event()` calls
     `fsnotify_prepare_user_wait()` at `fs/notify/fanotify/fanotify.c:977` (passing
     the event through on failure, `:978`), which pins marks by refcount and drops
     SRCU — `fs/notify/mark.c:556-589`, annotated
     `__releases(&fsnotify_mark_srcu)` at `:557`, unlock at `:581`, rationale
     `:576-580`; re-acquired by `fsnotify_finish_user_wait()`
     (`fs/notify/mark.c:591-599`, `__acquires` `:592`, lock `:596`) called at
     `fs/notify/fanotify/fanotify.c:1012-1013`.
     Break: documented by annotation.

256. Permission events are never merged and never replaced by an overflow event.
     Source: `fanotify_merge()` returns 0 for them at
     `fs/notify/fanotify/fanotify.c:196-197` (rationale `:191-195`), `BUG_ON` on
     merge at `:1002`, overflow exclusion at `:988-993`; `fsnotify()` aborts the
     group loop on the first non-zero permission result at
     `fs/notify/fsnotify.c:600-601`.
     Break: merging a permission event would lose a decision.

### 6.3 `file_ra_state_init`

257. `file_ra_state_init()` is called after `FMODE_OPENED`, after `->open()`, after
     the `f_flags` cleanup and `f_iocb_flags` computation, and before the
     `O_DIRECT` check.
     Source: `fs/open.c:1015`, relative to `:1000`, `:996`, `:1012`, `:1013`,
     `:1017-1018`.
     Break: being after `->open()` is load-bearing — an `->open()` implementation
     may change `f_mapping`, and the call uses `f->f_mapping->host->i_mapping`
     (note: *not* `f->f_mapping`; for a block device these differ).

258. `file_ra_state_init()` assumes `f_ra` has been zeroed by the caller.
     Source: the assumption is stated at `mm/readahead.c:137-140`; implementation
     `mm/readahead.c:141-147`; the zeroing is `memset(&f->f_ra, 0, sizeof(f->f_ra))`
     at `fs/file_table.c:200`.
     Break: `f_ra` lives in a union with `f_task_work`, `f_llist` and `f_freeptr`
     (`include/linux/fs.h:1287-1292`), so it is genuinely dirty after slab reuse. A
     refactor that drops the memset produces garbage readahead state — a
     performance and correctness bug with no crash.

259. `O_PATH` files skip `file_ra_state_init()` entirely and keep the zeroed state.
     Source: the early return at `fs/open.c:951`.
     Break: reaching it for `O_PATH` dereferences `f_mapping`, which the `O_PATH`
     path leaves as the inode's mapping but whose `f_op` is `empty_fops`
     (`fs/open.c:950`).

### 6.4 Atime

260. **`open()` never updates atime.** `fs/open.c` contains no `touch_atime()` or
     `file_accessed()` call.
     Source: the only `touch_atime` callers in `fs/` are `fs/inode.c`,
     `fs/namei.c:2049`, `fs/readdir.c:113`, `fs/stat.c:582`, `fs/splice.c:1121`,
     `fs/pipe.c:487`.
     Break: adding one changes long-standing `relatime` behaviour for every open.

261. **`stat()` never updates atime.** The single `touch_atime()` in `fs/stat.c` is
     in `do_readlinkat()`, not in any `getattr` path.
     Source: `fs/stat.c:582`, inside `do_readlinkat()` (`fs/stat.c:559-594`),
     guarded by `security_inode_readlink()` at `:580-581` and preceding
     `vfs_readlink()` at `:583`.
     Break: with one caveat — on a multigrain-timestamp filesystem, `stat()` *does*
     write to the inode: `fill_mg_cmtime()` performs
     `atomic_fetch_or(I_CTIME_QUERIED, ...)` at `fs/stat.c:59`. So `stat()` is not
     side-effect-free on such filesystems. See rule 281.

262. Symlink traversal **does** update atime, and the cheap
     `atime_needs_update()` predicate must be evaluated *first, while still in RCU
     mode*, so that the expensive unlazy + blocking `touch_atime()` is avoided in
     the common case.
     Source: `fs/namei.c:2044-2051` — the predicate at `:2044`, the RCU drop at
     `:2045-2048`, `touch_atime()` at `:2049`, `cond_resched()` at `:2050`.
     Break: this is a performance-critical ordering with a correctness consequence:
     `touch_atime()` blocks (rule 246), so calling it before the RCU drop is a
     sleep-in-atomic. Note also that symlink atime is updated **before**
     `security_inode_follow_link()` at `fs/namei.c:2053` — an LSM denial still
     leaves the atime updated.

263. `atime_needs_update()` evaluates its conditions in a fixed precedence:
     inode `S_NOATIME` → idmap-unmapped-id → superblock `SB_RDONLY|SB_NOATIME` →
     superblock `SB_NODIRATIME` (directories) → mount `MNT_NOATIME` → mount
     `MNT_NODIRATIME` (directories) → relatime heuristic → "already equal".
     Source: `fs/inode.c:2267-2301` — `:2272-2273`, `:2278-2279` (with the
     idmap rationale at `:2275-2277`), `:2281-2282`, `:2283-2284`, `:2286-2287`,
     `:2288-2289`, `:2293-2294`, `:2296-2298`, `:2300`.
     Break: the `HAS_UNMAPPED_ID()` check at `fs/inode.c:2278` is the idmapped-mount
     interaction — an atime writeback would persist a bogus uid/gid the VFS cannot
     represent. It must survive any reordering. Note `S_NOATIME` at `:2272` is
     tested raw, while `IS_NOATIME()` at `:2281` is the *superblock* test
     (`include/linux/fs.h:2141` = `SB_RDONLY|SB_NOATIME`) — the apparent redundancy
     is two different flags.

264. `O_NOATIME` is checked in `file_accessed()` and **nowhere else**;
     `atime_needs_update()` knows nothing about it.
     Source: `include/linux/fs.h:2274-2278`.
     Break: path-based `touch_atime()` callers (symlink traversal, readlink)
     therefore ignore `O_NOATIME` by construction. Moving the check into
     `atime_needs_update()` would change symlink behaviour.

265. `relatime_need_update()` returns `true` immediately when `MNT_RELATIME` is
     clear — that is the entirety of the strictatime path.
     Source: `fs/inode.c:2112-2118` (`:2117-2118`); the remaining heuristics at
     `:2122-2125` (mtime ≥ atime), `:2129-2131` (ctime ≥ atime), `:2137-2138`
     (24 hours), `:2142`.
     Break: rule 3.0 — there is no `MNT_STRICTATIME` bit to test.

266. `touch_atime()` dispatches to `->update_time` if present, else
     `generic_update_time()`, and the return value is deliberately ignored.
     Source: `fs/inode.c:2325-2328`; the rationale for ignoring is at
     `fs/inode.c:2316-2324`.
     Break: propagating the error would make `stat`/`readlink`/symlink-traversal
     fail on a full filesystem.

267. `inode_update_time()` returns positive `I_DIRTY_*` flags for the caller to pass
     to `__mark_inode_dirty()`; it does **not** mark the inode dirty itself.
     `generic_update_time()` does.
     Source: `fs/inode.c:2212-2225` (dispatcher, `WARN_ON_ONCE` + `-EIO` default at
     `:2220-2222`, kerneldoc `:2205-2210`); `generic_update_time()` at
     `fs/inode.c:2235-2256` with `__mark_inode_dirty()` at `:2253` and the
     `IOCB_NOWAIT` short-circuit at `:2236-2237` (rationale `:2240-2246`).
     Break: the documentation at `Documentation/filesystems/vfs.rst:590-593` says
     the VFS calls `mark_inode_dirty_sync()`, while the code calls
     `__mark_inode_dirty(inode, dirty)`. The doc is imprecise for this tree; the
     code is authoritative.

---

## 7. Stat path specifics

### 7.1 Call chain

268. The stat call chain is
     `sys_statx` (`fs/stat.c:804`) → `do_statx` (`:744-766`) → `vfs_statx`
     (`:341-363`) → `filename_lookup` (`:353`) → `vfs_statx_path` (`:296-315`) →
     `vfs_getattr` (`:254-264`) → `security_inode_getattr` (`:259`) →
     `vfs_getattr_nosec` (`:181-231`) → `inode->i_op->getattr` (`:213-214`) **or**
     `generic_fillattr` (`:218`) → `bdev_statx` if `S_ISBLK` (`:226-227`) →
     mount-id and `STATX_ATTR_MOUNT_ROOT` (`:303-313`) → `cp_statx` (`:699-742`).
     Source: as listed; the fd variant is `do_statx_fd` (`:768-790`) →
     `vfs_statx_fd` (`:317-324`); the legacy variant is `sys_newfstatat`
     (`:532-543`) → `vfs_fstatat` (`:365-375`) → `vfs_fstat` (`:276-282`) or
     `vfs_statx`; `io_uring` enters at `io_uring/statx.c:58`.
     Break: `io_uring` calls `do_statx()` directly, so any refactor of it must keep
     that entry point working.

269. `vfs_getattr()` is exactly `security_inode_getattr()` + `vfs_getattr_nosec()`.
     That is the whole difference.
     Source: `fs/stat.c:254-264`.
     Break: the set of legitimate `vfs_getattr_nosec()` callers is closed and each
     is either a stacking filesystem re-entering a lower layer or a kernel-internal
     consumer that exposes nothing to userspace: `fs/overlayfs/inode.c:168`,
     `fs/ecryptfs/inode.c:977`, `fs/exportfs/expfs.c:303` (rationale at
     `expfs.c:297-302`), `drivers/block/loop.c:156` (rationale `:151-155`),
     `security/integrity/ima/ima_api.c:279`, `security/integrity/ima/ima_main.c:194`.
     A new caller must fit one of those two categories. Note the kerneldoc at
     `fs/stat.c:177-179` claiming "the only caller other than vfs_getattr is
     internal to the filehandle lookup code" is **stale** in this tree.

270. `vfs_fstat()` never calls `vfs_statx_path()`, so `stat->mnt_id` and
     `STATX_MNT_ID` are never set on the `fstat` path, and neither is
     `STATX_ATTR_MOUNT_ROOT`.
     Source: `fs/stat.c:276-282` (`vfs_getattr(&fd_file(f)->f_path, stat,
     STATX_BASIC_STATS, 0)` at `:281`) versus `fs/stat.c:303-313`.
     Break: a refactor that routes `fstat` through `vfs_statx_path()` would start
     returning a mount id where none was returned before — an ABI change.

### 7.2 `request_mask` versus `result_mask`

271. `vfs_getattr_nosec()` zeroes the entire `kstat` before anything else, and
     filesystems rely on receiving a zeroed struct.
     Source: `fs/stat.c:187` (`memset(stat, 0, sizeof(*stat))`).
     Break: **implicit** — no `->getattr` implementation checks. Dropping the
     memset returns stack garbage to userspace.

272. `vfs_getattr_nosec()` pre-asserts `STATX_BASIC_STATS` in `result_mask`
     **before** the filesystem is asked. A filesystem may therefore leave
     `result_mask` completely untouched and still report all 11 basic stats as
     valid; it must OR in bits only for extended data.
     Source: `fs/stat.c:188`; the comment at `fs/stat.c:191` ("allow the fs to
     override these if it really wants to").
     Break: moving the pre-set after the `->getattr` call silently clears the basic
     bits for every filesystem that does not set them itself.

273. Generic code clears `result_mask` bits in exactly three places:
     `STATX_ATIME` when `SB_NOATIME` (`fs/stat.c:193-194`, rationale `:192`);
     `STATX_CTIME|STATX_MTIME` when neither was requested on a multigrain-timestamp
     inode (`fs/stat.c:50-52`, via `fill_mg_cmtime()`); and the kernel-private
     `STATX_CHANGE_COOKIE` on the way out (`fs/stat.c:707`).
     Source: as listed; the request-side strips at `fs/stat.c:759` and `:783`; the
     attribute strip at `fs/stat.c:710`.
     Break: these three are the complete set. Adding a fourth changes the
     "filled in anyway" contract documented at `include/uapi/linux/stat.h:88-91`.

274. `generic_fillattr()` touches `result_mask` in exactly one place:
     `STATX_CHANGE_COOKIE` when requested and `IS_I_VERSION(inode)`.
     Source: `fs/stat.c:108-111`; the unconditional field fills at `fs/stat.c:88-106`.
     Break: it never clears a bit itself (the `fill_mg_cmtime()` clear at
     `fs/stat.c:99` is indirect).

275. The full `STATX_*` set in this tree is
     `STATX_TYPE 0x1` (`include/uapi/linux/stat.h:203`), `MODE 0x2` (`:204`),
     `NLINK 0x4` (`:205`), `UID 0x8` (`:206`), `GID 0x10` (`:207`),
     `ATIME 0x20` (`:208`), `MTIME 0x40` (`:209`), `CTIME 0x80` (`:210`),
     `INO 0x100` (`:211`), `SIZE 0x200` (`:212`), `BLOCKS 0x400` (`:213`),
     `BASIC_STATS 0x7ff` (`:214`), `BTIME 0x800` (`:215`), `MNT_ID 0x1000` (`:216`),
     `DIOALIGN 0x2000` (`:217`), `MNT_ID_UNIQUE 0x4000` (`:218`),
     `SUBVOL 0x8000` (`:219`), `WRITE_ATOMIC 0x10000` (`:220`),
     `DIO_READ_ALIGN 0x20000` (`:221`), `__RESERVED 0x80000000` (`:223`).
     Kernel-private: `STATX_CHANGE_COOKIE 0x40000000` (`include/linux/stat.h:67`).
     Source: as listed; `STATX__RESERVED` is rejected with `-EINVAL` at
     `fs/stat.c:750-751` and `:774-775`.
     Break: `STATX_ALL 0xfff` is `#ifndef __KERNEL__` only
     (`include/uapi/linux/stat.h:225-232`), explicitly deprecated and frozen, with
     **zero in-kernel users**. A refactor must not reintroduce it kernel-side.

276. `STATX_MNT_ID` is set unconditionally (it is "Got" only); `STATX_MNT_ID_UNIQUE`
     is genuinely request-gated.
     Source: `fs/stat.c:303-309`; the UAPI comments at
     `include/uapi/linux/stat.h:216` versus `:218`.
     Break: making `STATX_MNT_ID` request-gated is an ABI change.

277. Request-gating by a filesystem is advisory, not mandatory: ext4 gates
     btime/dioalign/write-atomic on `request_mask` while btrfs sets
     `STATX_BTIME`/`STATX_SUBVOL` unconditionally. Both are legal.
     Source: `fs/ext4/inode.c:6274`, `:6282`, `:6298` versus
     `fs/btrfs/inode.c:8257`, `:8280`; the permitting clause is
     `include/uapi/linux/stat.h:88-91`.
     Break: a refactor that enforces gating breaks btrfs.

278. `bdev_statx` must run **after** `->getattr`, because it overrides
     `stat->blksize` the filesystem already set.
     Source: `fs/stat.c:221-227`; `block/bdev.c:1423` (the override), `:1408-1412`
     (`STATX_DIOALIGN`), `:1414-1421` (atomic writes); the earlier
     `stat->blksize = i_blocksize(inode)` at `fs/stat.c:105`.
     Break: ordering.

### 7.3 Sync flags

279. `AT_STATX_SYNC_TYPE` is a 2-bit enum in which `AT_STATX_SYNC_AS_STAT` is zero,
     so setting both `FORCE_SYNC` and `DONT_SYNC` is the illegal fourth value and
     is rejected with `-EINVAL`.
     Source: `include/uapi/linux/fcntl.h:146-149` (with the reuse warning at
     `:142-145`); the check at `fs/stat.c:752-753` (`do_statx`) and `fs/stat.c:776-777`
     (`do_statx_fd`).
     Break: the check is **not** in `vfs_statx`, `vfs_statx_path` or `vfs_getattr`,
     so in-kernel callers are unvalidated and `newfstatat(..., AT_STATX_FORCE_SYNC)`
     is accepted — `vfs_fstatat` forwards flags verbatim (`fs/stat.c:373`) and
     `vfs_statx`'s own filter at `fs/stat.c:348-350` permits `AT_STATX_SYNC_TYPE`
     through. Moving the check into `vfs_statx` would be a behaviour change for
     legacy `stat`.

280. `vfs_getattr_nosec()` masks `query_flags` down to `AT_STATX_SYNC_TYPE` before
     calling `->getattr`, so a filesystem never sees `AT_SYMLINK_NOFOLLOW`,
     `AT_NO_AUTOMOUNT` or `AT_EMPTY_PATH`.
     Source: `fs/stat.c:189`, preceding the `->getattr` call at `fs/stat.c:213-214`.
     Break: **implicit and load-bearing.** Filesystems test `flags & X` directly —
     NFS at `fs/nfs/inode.c:966` and `:980`, ceph at `fs/ceph/inode.c:3161-3164`,
     cifs at `fs/smb/client/inode.c:2967`, `:2975`, fuse at `fs/fuse/dir.c:1559-1561`,
     afs at `fs/afs/inode.c:610`. Removing the mask makes all of them misbehave for
     `AT_SYMLINK_NOFOLLOW` (0x100), which does not collide with the sync bits but
     does with nothing else either — the failure would be silent.

281. `stat()` performs a **write** to the inode on multigrain-timestamp
     filesystems: `fill_mg_cmtime()` does
     `atomic_fetch_or(I_CTIME_QUERIED, ...)` on the ctime nanoseconds field.
     Source: `fs/stat.c:45-63` — the `atomic_t` reinterpretation at `:47`, the
     fetch-or at `:59`, the tracepoint at `:61`; selected by `is_mgtime()` →
     `i_opflags & IOP_MGTIME` (`include/linux/fs.h:2326-2329`), branched at
     `fs/stat.c:98-103`; the flag is `I_CTIME_QUERIED = BIT(31)`
     (`include/linux/fs.h:1676`), masked off by `inode_get_ctime_nsec()` at
     `include/linux/fs.h:1685`.
     Break: any assumption that the stat path is read-only is false on such
     filesystems. A lock-free or `const`-ified stat refactor will break here.

### 7.4 `AT_*` flags

282. The flag translation for statx is, verbatim, `fs/stat.c:284-294`: `LOOKUP_FOLLOW`
     unless `AT_SYMLINK_NOFOLLOW`; `LOOKUP_AUTOMOUNT` unless `AT_NO_AUTOMOUNT`. Both
     are *negative* mappings. Called once, at `fs/stat.c:345`.
     Break: for `statx` automount is **on** by default; for legacy `stat`/`lstat` it
     is forced off by `vfs_fstatat` passing `flags | AT_NO_AUTOMOUNT`
     (`fs/stat.c:373`); for `statx` on an fd it is stripped as meaningless
     (`fs/stat.c:812`).

283. `AT_EMPTY_PATH` is **not** translated to `LOOKUP_EMPTY` on the stat path. It is
     handled entirely in filename acquisition, and an empty path short-circuits to
     the fd path without any walk.
     Source: `CLASS(filename_maybe_null, name)(filename, flags)` at `fs/stat.c:809`
     and `fs/stat.c:368`; `getname_maybe_null()` at `include/linux/fs.h:2561-2569`
     via `EXTEND_CLASS` at `:2588`; `__getname_maybe_null()` at `fs/namei.c:240-255`
     (the empty-path NULL returns at `:247-248` and `:252-253`, the `LOOKUP_EMPTY`
     use at `:250`); the short-circuits at `fs/stat.c:811-812` and `:370-371`.
     The generic `AT_EMPTY_PATH` → `LOOKUP_EMPTY` mapping still exists for other
     syscalls at `fs/namei.c:235` and `:330`.
     Break: a refactor that unifies the two mechanisms must preserve the property
     that `statx(fd, "", AT_EMPTY_PATH, ...)` performs no path walk at all.

284. Unknown-flag validation is asymmetric: `vfs_statx()` rejects stray flags but
     `vfs_statx_fd()` does not.
     Source: `fs/stat.c:348-350` versus `fs/stat.c:317-324`.
     Break: recorded as a fact. `statx(fd, NULL, AT_EMPTY_PATH | <any other AT_
     bit>, ...)` is accepted silently today. Whether that is intentional is **not
     established from source**.

### 7.5 `STATX_ATTR_*`

285. The full attribute set is `STATX_ATTR_COMPRESSED 0x4`
     (`include/uapi/linux/stat.h:248`), `IMMUTABLE 0x10` (`:249`), `APPEND 0x20`
     (`:250`), `NODUMP 0x40` (`:251`), `ENCRYPTED 0x800` (`:252`),
     `AUTOMOUNT 0x1000` (`:253`), `MOUNT_ROOT 0x2000` (`:254`),
     `VERITY 0x100000` (`:255`), `DAX 0x200000` (`:256`),
     `WRITE_ATOMIC 0x400000` (`:257`); doc block at `:234-247`. Kernel-only:
     `STATX_ATTR_CHANGE_MONOTONIC` at `include/linux/stat.h:70`. Groupings at
     `include/linux/stat.h:29-36` and `:37-40`.
     Source: as listed.

286. Generic code sets `STATX_ATTR_AUTOMOUNT` (`fs/stat.c:200-201`),
     `STATX_ATTR_DAX` (`:203-204`), and `STATX_ATTR_MOUNT_ROOT` (`:311-313`, value
     only when `path_mounted()`, **mask unconditionally**). The
     `KSTAT_ATTR_FS_IOC_FLAGS` set (COMPRESSED, NODUMP, ENCRYPTED, VERITY) has no
     generic setter and must come from `->getattr`. `generic_fill_statx_attr()`
     (`fs/stat.c:124-132`) is opt-in — it is not called by `vfs_getattr_nosec()`.
     Source: as listed; the in-code warning at `fs/stat.c:196-199` ("If you add
     another clause to set an attribute flag, please update attributes_mask below")
     and the mask ORs at `fs/stat.c:206-207`.
     Break: that warning is the maintenance rule. Honour it.

287. `attributes_mask` declares which `attributes` bits are *meaningful*; a zero bit
     means "unknown", not "false". Generic code only ever ORs into it.
     Source: `fs/stat.c:130`, `:153`, `:206`, `:313`; copied out unfiltered at
     `fs/stat.c:718`.
     Break: unlike `stx_mask` (`fs/stat.c:707`) and `stx_attributes`
     (`fs/stat.c:710`), `stx_attributes_mask` is **not** stripped of kernel-private
     bits on the way to userspace. So no kernel-private `STATX_ATTR_*` bit may ever
     be added to `attributes_mask`. This is **implicit** — it is an invariant of
     the current bit assignments, not an enforced rule.

### 7.6 Torn reads

288. `i_size` is read with `i_size_read()`, which is seqcount-protected only on
     32-bit SMP; no lock is required of the stat caller.
     Source: `fs/stat.c:95`; `i_size_read()` at `include/linux/fs.h:1123-1145`
     (seqcount `:1125-1133`, preempt `:1134-1140`, `smp_load_acquire` `:1141-1144`);
     the writer-side requirement at `include/linux/fs.h:1147-1151`.

289. `i_blocks` is read as a **bare unsynchronised load** while every writer holds
     `i_lock`. `stat` is therefore permitted to observe a torn `i_blocks` on 32-bit
     and a stale/inconsistent `i_blocks`-versus-`i_size` pair everywhere.
     Source: `fs/stat.c:106`; writers `inode_add_bytes()` at `fs/stat.c:917-924`
     (lock `:919`), `inode_sub_bytes()` at `:939-946` (lock `:941`),
     `inode_get_bytes()` at `:948-958`; the caller-locked variants documented at
     `fs/stat.c:904`, `:926`, `:962-963`.
     Break: **implicit and deliberate.** Recorded so a refactor does not "fix" it by
     taking `i_lock` in the stat path, which would serialise every `stat()` against
     every write.

290. Timestamps are read as two independent `READ_ONCE`s with no seqlock, so a torn
     sec/nsec pair is architecturally permitted.
     Source: `inode_get_atime()` at `include/linux/fs.h:1609-1615` over
     `inode_get_atime_sec()` `:1599-1602` and `inode_get_atime_nsec()` `:1604-1607`;
     the same shape for mtime `:1634-1649` and ctime `:1678-1694`; writers
     `:1617-1623`, `:1651-1657`.
     Break: as rule 289.

---

## 8. Concurrency

### 8.1 Lock inventory and ordering

291. The dcache lock ordering is
     `inode->i_lock` → `dentry->d_lock` → {`s_dentry_lru_lock`, hash bucket lock,
     `s_roots_lock`}, and for ancestors, parent's `d_lock` outside child's.
     Source: `fs/dcache.c:60-65` and `:67-71`; the no-ancestor case is serialised on
     `rename_lock` (`fs/dcache.c:73-74`); restated at `fs/dcache.c:703-704`.
     Break: `i_lock` nests **outside** `d_lock`, which is why `lock_for_kill()` must
     drop and retake `d_lock` and then re-verify `inode == dentry->d_inode`
     (`fs/dcache.c:740-752`, verification at `:745-748`).

292. What each dcache lock protects:
     `inode->i_lock` — `i_dentry`, `d_alias`, **and `d_inode` of aliases**
     (`fs/dcache.c:42-43`); hash bucket bit-lock — the hash table (`:44-45`);
     `s_roots_lock` — `s_roots` (`:46-47`); `s_dentry_lru_lock` — LRU lists and
     counters (`:48-49`); `d_lock` — `d_flags`, `d_name`, `d_lru`, `d_count`,
     `d_unhashed()`, `d_parent`, `d_children`, children's `d_sib` and `d_parent`,
     `d_alias`, `d_inode` (`:50-58`).
     Source: as listed.
     Break: `d_inode` appears under both `i_lock` and `d_lock`; both are needed to
     modify it.

293. The inode lock ordering is
     `s_inode_list_lock` → `i_lock` → LRU list locks; `bdi->wb.list_lock` → `i_lock`;
     `inode_hash_lock` → `i_lock`.
     Source: `fs/inode.c:46-56`; what each protects at `fs/inode.c:32-44`
     (`i_lock`: `i_state`, `i_hash`, `__iget()`, `i_io_list`, `:35-36`;
     `inode_hash_lock`: `inode_hashtable`, `i_hash`, `:43-44`).
     Break: combined with rule 291 the full chain is
     `s_inode_list_lock` → `inode->i_lock` → `dentry->d_lock` → {LRU, hash bucket,
     `s_roots`}. `inode_hash_lock` is file-static (`fs/inode.c:62`) with no external
     users.

294. `iget5_locked()`'s `@test` and `@set` callbacks and `ilookup5_nowait()`'s
     `@test` run under `inode_hash_lock` and must not sleep.
     Source: `fs/inode.c:1371-1372`; `fs/inode.c:1666`.
     Break: documented.

295. `i_rwsem` subclasses and their ordering are
     `parent[2] → child → grandchild → normal → xattr → second non-directory`.
     Source: `include/linux/fs.h:996-1011` (ordering stated at `:1009-1010`);
     `enum inode_i_mutex_lock_class` at `include/linux/fs.h:1012-1020`
     (`I_MUTEX_NORMAL` `:1014`, `I_MUTEX_PARENT` `:1015`, `I_MUTEX_CHILD` `:1016`,
     `I_MUTEX_XATTR` `:1017`, `I_MUTEX_NONDIR2` `:1018`, `I_MUTEX_PARENT2` `:1019`);
     helpers `include/linux/fs.h:1022-1075`.
     Break: `__d_move()` uses raw subclasses 2 and 3
     (`fs/dcache.c:3083-3084`) beyond the two-value `enum dentry_d_lock_class` at
     `include/linux/dcache.h:149-153` — a pre-existing inconsistency to preserve.

296. The directory-operation locking scheme is: non-directories locked in **inode
     pointer order**; all directory `i_rwsem` on a filesystem share one rank, lower
     than any non-directory's on that filesystem; `s_vfs_rename_mutex` lower than
     any `i_rwsem` on the same filesystem; across filesystems, the relative
     filesystem rank.
     Source: `Documentation/filesystems/directory-locking.rst:137-147`, worked
     example `:149-158`; operation classes `:20-63`; the guarantee that all
     directories touched by a method are locked by the caller `:65-66`.
     Break: deadlock-freedom is conditional on "no directory is its own ancestor"
     (`directory-locking.rst:133`) and on the cross-filesystem relation being
     asymmetric (`:121-127`). The common-ancestor check in cross-directory rename is
     explicitly load-bearing — "without it a deadlock would be possible"
     (`directory-locking.rst:239-248`).

297. Per-operation `i_rwsem` requirements are tabulated at
     `Documentation/filesystems/locking.rst:97-139`: `lookup` shared (`:103`),
     `create`/`link`/`mknod`/`symlink`/`mkdir`/`unlink`/`rmdir`/`rename` exclusive
     (`:104-111`), `setattr` exclusive (`:114`), `permission` **none** and "may not
     block if called in rcu-walk mode" (`:115`), `getattr` none (`:118`),
     `atomic_open` shared but **exclusive if `O_CREAT`** (`:123`), `tmpfile` none
     (`:124`). Supplementary rules at `:131-136`.
     Break: `lookup_open()` implements the `atomic_open` rule at
     `fs/namei.c:4457-4460`; `lookup_slow()` the shared-lookup rule at
     `fs/namei.c:1935-1937`.

298. `i_rwsem` on a directory protects **all** names in it; `d_lock` protects one
     name. Dentry eviction under memory pressure uses `d_lock` only — `i_rwsem`
     plays no role.
     Source: `Documentation/filesystems/path-lookup.rst:256-262` and `:249-254`.
     Break: the eviction exception is why `retain_dentry()` and `dentry_kill()` can
     run concurrently with a directory operation.

299. `i_rwsem` plays no role in RCU-walk, because `rcu_read_lock()` forbids sleeping;
     a missed dentry or a failed `read_seqretry()` simply degrades to ref-walk.
     Source: `Documentation/filesystems/path-lookup.rst:806-816`.
     Break: informational, but it is why RCU-walk is allowed to observe a directory
     mid-modification.

300. `d_parent` may be read only if at least one of: the filesystem has no
     cross-directory rename; the parent is known locked; you are inside `->rename()`;
     or the child's `d_lock` is held.
     Source: `Documentation/filesystems/porting.rst:245-258`.
     Break: the cleanest citable rule for `d_parent` access. `follow_dotdot()` uses
     `dget_parent()` (`fs/namei.c:2214`), which implements the lockless variant with
     a `d_seq` re-check (`fs/dcache.c:1106-1114`); the comment at `fs/namei.c:2213`
     flags it as "rare case of legitimate `dget_parent()`".

301. `rename_lock` protects hash-chain stability across renames, serialises the
     no-ancestor `d_lock` ordering, stabilises tree topology for upward walks, and
     provides the scoped-lookup `..` race detection.
     Source: definition `fs/dcache.c:85`, declaration `include/linux/dcache.h:245`;
     roles at `Documentation/filesystems/path-lookup.rst:220-237`,
     `fs/dcache.c:73-74`, `fs/d_path.c:148-151`,
     `Documentation/filesystems/path-lookup.rst:239-244`.
     Break: write sites are `d_move()` (`fs/dcache.c:3151-3153`), `d_exchange()`
     (`:3164-3173`), and `d_splice_alias_ops()` (`:3256`, `:3258`, `:3270`, `:3284`).
     `__d_move()` itself does **not** take it — the caller must
     (`fs/dcache.c:3051-3053`).

302. `d_compare()` runs with `rename_lock` held; `d_revalidate`, `d_hash`,
     `d_delete`, `d_prune` and `d_iput` do not.
     Source: `Documentation/filesystems/locking.rst:45` and `:42-51`; the
     cross-reference mandate at `include/linux/dcache.h:180-186`.
     Break: documented.

303. `->d_delete()` is called with `d_lock` held and refcount **zero**, and may not
     drop or regain `d_lock`. `->d_prune()` is called without the parent's `d_lock`.
     `->d_iput()` and `->d_release()` are called with the victim still in the
     parent's children list, negative, unhashed, with negative refcount.
     Source: `Documentation/filesystems/porting.rst:1102-1104` (**mandatory**),
     `:1110-1112`, `:1114-1121`; call sites `fs/dcache.c:882`, `:816-817`,
     `:826-831` relative to the parent lock at `:835-838`.
     Break: these are filesystem-facing contracts. A dcache refactor changes them
     for every filesystem simultaneously.

### 8.2 `d_revalidate` and retry-on-ESTALE

304. The `retry_estale()` protocol is: a `retry:` label before the lookup; a
     **mutable local** `lookup_flags`; release **all** path references before the
     test; on true, set `LOOKUP_REVAL` and jump back. The retry therefore happens at
     most once, structurally.
     Source: `include/linux/namei.h:214-218` (kerneldoc `:204-213`); the canonical
     instance is `fs/stat.c:341-363` — label `:352`, flags `:345`, lookup `:353`,
     operation `:356`, `path_put(&path)` `:357` **before** the test at `:358`,
     flag-set `:359`, jump `:360`.
     Break: **the `path_put()` must precede the `goto`.** Two call sites needed
     special structure to achieve it: `linkat` at `fs/namei.c:5997-6008` has the
     ESTALE branch do its own `path_put(&old_path)` at `:6005` because it jumps over
     the normal `out_putpath`; `renameat` at `fs/namei.c:6337-6345` uses a
     `should_retry` bool (`:6338`) so that both paths can be put (`:6339`, `:6341`)
     before the jump (`:6342-6345`). A refactor that regularises these loses the
     reference release.

305. The complete `retry_estale()` caller set is `fs/utimes.c:101`; `fs/open.c:144`,
     `:523`, `:563`, `:614`, `:733`, `:857`; `fs/namei.c:5339`, `:5454`, `:5585`,
     `:5733`, `:5827`, `:6004`, `:6337`; `fs/xattr.c:694`, `:839`, `:976`, `:1068`;
     `fs/stat.c:358`, `:589`; `fs/statfs.c:108`; `fs/smb/server/vfs.c:762`.
     Source: as listed.
     Break: 22 sites, same protocol, no shared helper.

306. `-ESTALE` is generated inside the VFS in two places: `complete_walk()`
     converting a zero `->d_weak_revalidate()` return, and `__d_unalias()` when its
     trylocks fail.
     Source: `fs/namei.c:1099-1100`; `fs/dcache.c:3209`, `:3216-3220`.
     Break: the `__d_unalias()` case means a **trylock failure during dentry
     splicing surfaces to userspace as an ESTALE retry, not an error**. This is
     non-obvious and must survive.

307. `d_revalidate()`'s return contract is `> 0` valid, `0` invalid, `< 0` error,
     `-ECHILD` "retry me in ref-walk"; in RCU mode the filesystem must not block or
     store to the dentry, and `d_parent`/`d_inode` may change or become NULL.
     Source: `Documentation/filesystems/vfs.rst:1228-1240`, RCU constraints
     `:1231-1236`; restated as **mandatory** at
     `Documentation/filesystems/porting.rst:425-429`;
     `d_weak_revalidate` same semantics (`vfs.rst:1254-1255`) and never called in
     RCU mode (`vfs.rst:1257`, `locking.rst:43`).
     Break: `lookup_fast()` consumes `-ECHILD` locally rather than propagating it —
     it unlazies and re-calls in ref-walk (`fs/namei.c:1871-1876`). That local
     handling is what keeps `-ECHILD` from escaping to userspace.

308. This tree's `d_revalidate` signature takes the parent inode and the name as
     extra leading arguments.
     Source: `include/linux/dcache.h:161-163`; the porting note at
     `Documentation/filesystems/porting.rst:1146`.
     Break: a spec written from an older tree will have the wrong signature.

### 8.3 What can change between lookup and open

309. Between `complete_walk()` and `may_open()`, everything except the dentry's
     identity can change: the inode's mode, uid, gid and flags; the mount's flags;
     the superblock's read-only state; and the LSM policy.
     Source: `do_open()` holds no lock across `fs/namei.c:4799-4835`; the only
     stabilised item is `nd->path`, pinned by `R(p)`.
     Break: **implicit.** The VFS deliberately re-reads everything in `may_open()`
     rather than caching it from the walk. A refactor that caches mode or ownership
     from the lookup phase introduces a TOCTOU. The one thing that *is* cached —
     `nd->dir_mode` and `nd->dir_vfsuid` from `fs/namei.c:2646-2647` — is cached on
     purpose and is used only by the hardening sysctls (rules 33, 34), where a stale
     value fails safe.

310. Between `lookup_open()` returning and `do_open()` running, the parent's
     `i_rwsem` has been dropped, so the dentry may have been unlinked, renamed, or
     made negative.
     Source: unlock at `fs/namei.c:4577-4580`, `do_open()` at `fs/namei.c:4789`.
     Break: `may_open()` re-checks for a negative dentry at `fs/namei.c:4238-4239`
     and re-reads `i_mode` at `:4241`. Those are the only guards.

311. A positive dentry cannot become negative while a reference is held, so
     `nd->inode` remains valid across the gap.
     Source: rule 229 — `fs/dcache.c:2696`;
     `Documentation/filesystems/path-lookup.rst:193-194`.
     Break: this is the one thing the open path is entitled to assume, and it is an
     invariant of `d_delete()`, not of the open path.

312. SELinux explicitly re-checks at `file_open` time to close the window between
     `inode_permission` and open, with an in-code instruction not to remove it.
     Source: `security/selinux/hooks.c:4279-4280`.
     Break: rule 74.

---

## 9. Rules most at risk from a reference-ownership refactor

These are the subset of category 5 that a reference-ownership change is most
likely to break *silently* — no compile error, no assertion, no test failure —
together with the category 2, 3 and 6 rules that depend on them. They are ordered
by how long the damage stays invisible.

### 9.1 Tier 1 — no runtime detection at all

**A. The `FMODE_OPENED` gate (rules 185–189, 187 especially).**
`__fput()` releases nothing when `FMODE_OPENED` is clear
(`fs/file_table.c:493-494`). Every reference a `struct file` will ever own is
acquired inside `do_dentry_open()` between `fs/open.c:941` and `fs/open.c:1000`.
The two always-on assertions (`BUG_ON` at `fs/open.c:1055`, `WARN_ON` at
`fs/namei.c:5006`) cover only the "opened twice" and "succeeded without opening"
cases. They do **not** cover the case a refactor actually produces: references
acquired before the flag, then an error return. That leaks a dentry and a mount
per occurrence, and the only symptom is a filesystem that cannot be unmounted,
arbitrarily later.
*Depends on it:* rule 247 (fsnotify symmetry is gated on the same flag), rule 252
(permission-denial symmetry), rule 192 (`put_file_access` pairing).

**B. `do_dentry_open()`'s two failure regimes (rule 189).**
The `O_DIRECT` check at `fs/open.c:1017-1018` returns `-EINVAL` after
`FMODE_OPENED` is set and deliberately does **not** unwind, while every earlier
failure unwinds fully at `fs/open.c:1022-1032`. There is no comment. Unifying the
two error paths is the single most natural-looking cleanup in this function and
it is wrong in both directions.
*Depends on it:* rule 250 (the existing `fsnotify_close`-without-open asymmetry
lives precisely in this window), rule 190 (the unwind order).

**C. The conditional mount reference (rules 168, 197, 198, 199).**
`handle_mounts()` yields a `path` that owns `R(m)` **only if a mount was
crossed**. Three separate sites encode that condition differently:
`need_mntput` in `__traverse_mounts()` (`fs/namei.c:1605`), the
`if (nd->path.mnt != path.mnt)` guard in `step_into_slowpath()`
(`fs/namei.c:2119`), and the `if (link->mnt == nd->path.mnt) mntget()` in
`pick_link()` (`fs/namei.c:2018-2021`). They must all agree. There is no shared
helper and no assertion. Getting `pick_link()` wrong is the classic failure:
unconditional `mntget()` leaks on every mount crossing; no `mntget()` underflows
`mnt_count` on every same-mount symlink — and `mnt_count` underflow is a
use-after-free of the mount.
*Depends on it:* rule 130 (a `struct path` across a sleep must pin both members),
rule 116 (RCU-walk pins nothing), rule 161 (`terminate_walk()` puts every stack
entry).

**D. `__legitimize_mnt()`'s three-valued return (rule 115).**
`0` / `>0` / `<0` where `<0` means "failed **and** the caller owns a reference".
The two consumers dispose of it differently on purpose — `legitimize_mnt()`
drops RCU to `mntput()` (`fs/namespace.c:770-774`); `__legitimize_path()` leaves
`path->mnt` set for the caller's mandatory `path_put()` (`fs/namei.c:869-870`).
Treating the return as a boolean is the obvious simplification and leaks a mount
reference on every contended unmount race.
*Depends on it:* rule 155, rule 151 (`try_to_unlazy` ordering), rule 122
(`choose_mountpoint()`'s drop-RCU-and-put dance).

**E. The RCU/ref-walk ownership asymmetry (rule 149).**
`nd->path`, `nd->root` and every `nd->stack[i].link` hold zero references in
RCU-walk and full references in ref-walk. The mode is carried only in
`nd->flags & LOOKUP_RCU`, and it is tested independently at eight places:
`put_link()` (`fs/namei.c:1200`), `terminate_walk()` (`:847`), `pick_link()`
(`:2018`, `:2025`, `:2045`, `:2063`), `step_into_slowpath()` (`:2112`, `:2117`),
`nd_jump_root()` (`:1146`, `:1154`), `set_root()` (`:1117`, `:1125`),
`path_init()` (four branches), `handle_lookup_down()` (`:2794`). A refactor that
extracts a helper and gets the mode test wrong in one of them produces either a
leak or a put of a reference that was never taken.
*Depends on it:* rules 194–202 in their entirety.

### 9.2 Tier 2 — detected only under `CONFIG_DEBUG_VFS` or lockdep

**F. `try_to_unlazy()`'s partial-legitimization depth adjustment (rule 151).**
`legitimize_links()` sets `nd->depth = i + 1` on failure (`fs/namei.c:897`) so
`terminate_walk()` releases exactly the entries that were legitimized. Off by one
in either direction is a leak or a double-put. Nothing asserts it.

**G. `LOOKUP_CACHED` must never reach `legitimize_links()` (rule 181).**
Guarded only by `VFS_BUG_ON(nd->flags & LOOKUP_CACHED)` at `fs/namei.c:891`,
which compiles to nothing without `CONFIG_DEBUG_VFS`
(`include/linux/vfsdebug.h:35`).

**H. `dput()` may sleep (rule 225).**
`might_sleep()` at `fs/dcache.c:1039` fires only with `CONFIG_DEBUG_ATOMIC_SLEEP`.
Adding a `dput()` inside the RCU-walk region — the natural way to "just release
it here" — is invisible on a production build.

**I. `put_file_access()`'s dependence on field order (rule 190).**
`file_put_write_access()` reads `f_inode` and `f_path.mnt`
(`fs/internal.h:115-116`), so both must still be live when it runs. The only
thing enforcing the order is the sequence at `fs/open.c:1025-1031`.

### 9.3 Cross-category dependencies

| Category-5 rule | What breaks in categories 2 / 3 / 6 | Why |
|---|---|---|
| 186, 187 (`FMODE_OPENED` owns `R(p)`) | **6**: rule 247 — `fsnotify_open`/`fsnotify_close` symmetry | Both the close and every `fsnotify_open()` call site are gated on the same flag. Change when the flag is set and the pairing moves with it. |
| 186 (`f_path` pinned before hooks) | **2**: rules 68, 71, 78 — Landlock, AppArmor and Smack all read `f_path` in `file_open` | `path_get()` at `fs/open.c:941` precedes `security_file_open()` at `:973`. Deferring the reference "until we know we'll succeed" hands three LSMs an unpinned path. |
| 189 (`O_DIRECT` post-`FMODE_OPENED` failure) | **6**: rule 250 — the existing close-without-open asymmetry | The asymmetry exists exactly in this window. Widening the window widens the bug. |
| 197, 198, 168 (conditional `R(m)`) | **3**: rules 91, 92, 94 — `MNT_NOSYMFOLLOW`, `MNT_NODEV`, `MNT_NOEXEC` | All three are reachable only through a `struct path`. `MNT_NOSYMFOLLOW` in particular is tested against `link->mnt` (`fs/namei.c:2041`), which is the very reference `pick_link()` conditionally acquires. |
| 130, 149 (path pins both members) | **2**: rule 66 — Landlock walks up the mount hierarchy | `follow_up()`, `dget_parent()`, `path_get()`/`path_put()` inside `security/landlock/fs.c:894-1002` all require a fully pinned path. |
| 205, 206 (`vfs_open` does not consume `R(p)`) | **3**: rule 108 — `mnt_want_write`/`mnt_drop_write` pairing | `do_open()` holds `W(m)` across `vfs_open()` (`fs/namei.c:4830`…`:4847`). If `vfs_open()` started consuming the path reference, the `mnt_drop_write()` at `:4847` would operate on a released mount. |
| 246 (`touch_atime` takes `F(sb)` + `W(m)`) | **6**: rules 262, 263 — symlink atime | `touch_atime()` blocks, which is why `pick_link()` drops RCU first (`fs/namei.c:2045-2048`). A refactor that keeps RCU across it sleeps in atomic. |
| 213 (`lookup_open` lock/unlock asymmetry) | **2**: rule 79 — `security_file_open` under `i_rwsem` | The unlock condition at `fs/namei.c:4577-4580` differs from the lock condition at `:4457`. Getting it wrong leaves the parent directory locked across the LSM hook and the fanotify wait (rule 253), i.e. an unbounded hold of a directory lock. |
| 209 (`FD_ADD` ownership transfer) | **6**: rule 247 | If `fd_install()` runs but `retain_and_null_ptr()` does not, the cleanup class `fput()`s an installed file — a double close that fires `fsnotify_close()` twice. |
| 244, 245 (`W(i)`) | **3**: rule 49 | `put_write_access()` has no sign check; an unmatched call drives `i_writecount` negative and the file becomes permanently un-executable. |

### 9.4 Minimum acceptance evidence for a reference-ownership patch

For each patch touching any rule above, the following should be demonstrable:

1. `CONFIG_DEBUG_VFS=y` build boots and runs the workload — this is the only way
   the `VFS_BUG_ON`s in `fs/namei.c` (6 of them) and `fs/inode.c` (10) are live at
   all (`include/linux/vfsdebug.h:9-33`).
2. Mount/unmount cycling under the workload completes — a leaked `mnt_count` shows
   up as `EBUSY` on unmount and as nothing else.
3. `dentry` and `filp` slab counts return to baseline after the workload
   (`/proc/slabinfo`); no in-tree test does this (rule 10.9).
4. KASAN build, since `mnt_count`/`d_lockref` underflow manifests as
   use-after-free rather than as an assertion.
5. The `grep` invariant from rule 139 still holds:
   `grep -n 'inode->i_uid\|inode->i_gid' fs/namei.c fs/attr.c fs/open.c fs/inode.c`
   matches only comments, assignments, and the `i_*_into_vfs*`/`i_*_update`
   helpers.

---

## 10. How each rule is tested today

Scope note: this section reports what exists **in this tree**
(`tools/testing/selftests/`, `fs/**/kunit`, `lib/tests/`) and what is referenced
from it. xfstests/fstests and LTP are external suites; this tree carries no
harness for either, and the only in-tree references to them are the incidental
ones listed in 10.8. Where a rule has no coverage, that is stated plainly.

### 10.1 Path-walk scoping and `RESOLVE_*` — partial coverage

`tools/testing/selftests/filesystems/openat2/resolve_test.c` is the only
systematic test of category 4:

| Rule | Test | Coverage |
|---|---|---|
| 175 (`LOOKUP_BENEATH`), 177 | `TEST_F(openat2_resolve, resolve_beneath)` `resolve_test.c:216`, 22 cases at `:221-289` | `..`, `/`, absolute and relative symlinks, magic links, dotdot-links |
| 175 (`LOOKUP_IN_ROOT`), 176, 177 | `resolve_in_root` `resolve_test.c:299`, 25 cases at `:303-388` | |
| 144, 180 (`RESOLVE_NO_XDEV`) | `resolve_no_xdev` `resolve_test.c:398`, 14 cases at `:403-449` | includes `/proc/self/root`, bind-mount crossing |
| 174, 180 (`RESOLVE_NO_MAGICLINKS`) | `resolve_no_magiclinks` `resolve_test.c:459`, 7 cases at `:464-485` | `-ELOOP` for `/proc/self/exe` |
| 180 (`RESOLVE_NO_SYMLINKS`) | `resolve_no_symlinks` `resolve_test.c:495`, 15+ cases at `:500-553` | |
| 177 (the `..` race) | `TEST_F_TIMEOUT(rename_attack, test, 120)` `rename_attack_test.c:110` | races `rename()` against `RESOLVE_IN_ROOT` |
| 178, 179, 183, 184 | `TEST_F(openat2, flag_validation)` `openat2_test.c:161`; `struct_argument_sizes` `:68` | |
| 182 (`OPENAT2_REGULAR`) | `TEST_F(openat2, regular_flag)` `openat2_test.c:327`; `TEST(legacy_openat_ignores_o_regular)` `:347` | |
| 283 (`AT_EMPTY_PATH`/`O_EMPTYPATH`) | `emptypath_test.c:49`, `:64` | |

**Not covered: rule 181 (`RESOLVE_CACHED`).** `grep -rn 'RESOLVE_CACHED'
tools/testing/selftests/` returns nothing. The `LOOKUP_CACHED` path — including
the `VFS_BUG_ON` at `fs/namei.c:891` and the `try_to_unlazy` refusals at
`fs/namei.c:941-945` and `:982-986` — has **no test at all**.

**Build gap:** `tools/testing/selftests/Makefile:106` lists `TARGETS += openat2`,
but no `tools/testing/selftests/openat2/` directory exists — the tests live under
`filesystems/openat2/`, which is **not** in `TARGETS`. Neither are
`filesystems/xattr`, `filesystems/eventfd` or `filesystems/open_tree_ns`. **The
entire `RESOLVE_*` suite does not run in a default `make -C
tools/testing/selftests` build.** Fixing this is a prerequisite to using these
tests as acceptance criteria.

### 10.2 Mount flags and the write-hold protocol — partial coverage

| Rule | Test |
|---|---|
| 91 (`MNT_NOSYMFOLLOW`) | `tools/testing/selftests/mount/nosymfollow-test.c` — `test_link_traversal()` `:131`, `ELOOP` assertion `:137`; also `mount_setattr_test.c:1466` (`mount_attr_nosymfollow`, `ELOOP` at `:1503`) |
| 97 (`MNT_LOCK_*` never cleared) | `tools/testing/selftests/mount/unprivileged-remount-test.c` — `test_unpriv_remount()` `:182`, `test_unpriv_remount_simple()` `:246`, `test_unpriv_remount_atime()` `:251`, `test_priv_mount_unpriv_remount()` `:257` |
| 95, 99, 111–118 (mount flags, detached-tree refcounts) | `mount_setattr_test.c` — `basic` `:530`, `basic_recursive` `:565`, **`mount_has_writers` `:659`**, `mixed_mount_options` `:717`, `time_changes` `:751`, `multi_threaded` `:897`; the detached-tree group `open_tree_detached` `:1528` through `detached_tree_propagation` `:2085` |
| 3.6 (idmapped mounts) | `mount_setattr_test.c` idmapped fixture `:991`, `change_idmapping` `:1378`, `idmap_mount_tree_invalid` `:1423`; `filesystems/overlayfs/idmapped_mounts.c` (6 tests `:262-453`); `filesystems/idmapped_tmpfile.c` (`:106`, `:133`) |
| 3.1 (mount attrs via fsmount) | `filesystems/fsmount_ns/` — `readonly` `:976`, `noexec` `:1007`, `nosuid` `:1038`, `noatime` `:1069`, `combined` `:1100` |
| 126, 3.5 (propagation, beneath) | `filesystems/move_mount/` — 8 tests `:134-449`; `move_mount_set_group/` |

`mount_setattr_test.c:659` (`mount_has_writers`) is the closest thing in the tree
to a test of rule 100/106 — the `WRITE_HOLD` spin-wait and the per-CPU writer
sum. It exercises the `-EBUSY` return, not the memory ordering.

**Not covered:** rules 100–102 (the barrier protocol and the RT variant),
rules 107 (`sb_start_ro_state_change` pairing), rule 108 (want/drop pairing —
there is no leak detector, see 10.9).

### 10.3 Permission, capabilities, ACLs, hardening sysctls — largely uncovered

- **Rules 33, 34 (`protected_fifos`, `protected_regular`, `protected_symlinks`,
  `protected_hardlinks`): NO TEST.** `grep -rn 'protected_symlinks\|protected_hardlinks\|protected_fifos\|protected_regular'
  tools/testing/selftests/` returns zero hits. `may_create_in_sticky()` and
  `may_follow_link()` — and therefore the `nd->dir_mode`/`nd->dir_vfsuid` snapshot
  at `fs/namei.c:2646-2647` that both depend on — are entirely untested.
- **Rules 28–30 (sticky bit, `S_ISVTX`): NO TEST.** The only `S_ISVTX` reference in
  selftests is a *comment* at `filesystems/failfs/failfs_test.c:414`.
- **Rules 8–16 (POSIX ACLs, `generic_permission`): effectively NO TEST.** The only
  ACL-aware test is `filesystems/fuse/fuse_acl_cache_test.c` —
  `TEST_F(acl_cache, stale_after_force_sync)` `:252` — which is a FUSE cache
  invalidation regression test, not a test of `acl_permission_check()`.
- **Rules 9–11 (`CAP_DAC_OVERRIDE`, `CAP_DAC_READ_SEARCH`, `CAP_FOWNER`): NO TEST
  as subject.** They appear only as scaffolding in `landlock/common.h:41` and
  `landlock/fs_test.c` (`:6809`, `:6813`, `:7276-7329`, `:10472-10724`).
  `tools/testing/selftests/capabilities/` covers execve capability transitions,
  not DAC override in path walk.
- **Rule 163 (`MAXSYMLINKS` / real symlink cycles): NO TEST.** Every `ELOOP` in
  the tree comes from `MNT_NOSYMFOLLOW` or `RESOLVE_NO_SYMLINKS`
  (`resolve_test.c:469-553`, `nosymfollow-test.c:137`,
  `mount_setattr_test.c:1503`). No test constructs an `a -> b -> a` cycle or a
  40-deep symlink chain.
- **Rule 139 (the no-raw-`i_uid` invariant):** testable only by the `grep` in
  rule 9.4. No automated check exists.

### 10.4 LSM hooks — Landlock only

`tools/testing/selftests/landlock/fs_test.c` (175 test macros) is the only
substantial in-tree exercise of category 2, and it constrains the VFS
path-handling contract more than any other test:

| Rule | Test |
|---|---|
| 66, 67 (Landlock needs a path, walks up mounts) | `rule_on_mountpoint` `:1487`, `rule_over_mountpoint` `:1513`, `rule_over_root_allow_then_deny` `:1543`, `rule_over_root_deny` `:1567`, `rule_inside_mount_ns` `:1584` |
| 130 (path pins both members), 3.5 | `mount_and_pivot` `:1608`, `move_mount` `:1628`, `topology_changes_with_net_only` `:1658`, `umount_sandboxer` `:2021` |
| 175 (`AT_FDCWD`/chroot-relative walk) | `relative_open` `:1900`, `relative_chdir` `:1905`, `relative_chroot_only` `:1910`, `relative_chroot_chdir` `:1915` |
| 197–199 (mount-crossing references) | the `layout1_bind` fixture `:4974` — `reparent_cross_mount` `:5189`, **`path_disconnected` `:5228`**, `path_disconnected_rename` `:5323`, `path_disconnected_link` `:5491` |
| 68 (open-time decision cached in the file blob, `security/landlock/fs.c:1909`) | `truncate` `:3736`, `ftruncate` `:3843`, `open_and_ftruncate` `:3985`, `open_and_ftruncate_in_different_processes` `:4009`, `o_path_ftruncate_and_ioctl` `:4115` |
| 70 (`O_PATH` runs no `file_open` hook) | `o_path_ftruncate_and_ioctl` `:4115`; `proc_unlinked_file` `:3562`, `proc_pipe` `:3598` |
| 72 (parent path + child dentry) | `link` `:2098`, `rename_file` `:2176`, `rename_dir` `:2424`, `reparent_refer` `:2483`, `reparent_link` `:2682`, `reparent_rename` `:2756`, `reparent_exdev_layers_*` `:2943-3166` |
| 5.6 (inode reference release) | `release_inodes` `:1707` and `:7398` |
| 85–88 (audit) | the `audit_layout1` group `:7524-8002`, `audit_quiet_layout1` `:8308-9550` |

**No in-tree test exercises SELinux, AppArmor or Smack hooks** on these paths —
rules 63, 64, 74–78 are untested here. **Rules 50–58 (hook call order and the
`call_int_hook` bail-on-first-error semantics) have no test.**
**Rule 53 (`security_file_alloc` sees an uninitialised file) has no test** and no
assertion; it is enforced by convention only.

### 10.5 Observability — no coverage of the symmetry rule

- **Rule 247 (`fsnotify_open`/`fsnotify_close` symmetry): NO TEST.** There is no
  selftest that opens files and checks that `FS_OPEN` and `FS_CLOSE_*` events
  balance. `filesystems/dnotify_test.c` is a manual demo, not a pass/fail test,
  and is `TEST_GEN_PROGS_EXTENDED` so kselftest does not run it.
  `filesystems/mount-notify/` covers `FAN_MNT_ATTACH`/`DETACH` only (7 tests each
  in `mount-notify_test.c` and `mount-notify_test_ns.c`).
- **Rules 251–256 (fanotify permission events): NO TEST** of the open path.
- **Rules 257–259 (`file_ra_state_init`): NO TEST.**
- **Rules 260–267 (atime): NO DIRECT TEST.** `fsmount_ns` covers the `noatime`
  *mount attribute* (`:1069`) but nothing exercises `atime_needs_update()`'s
  precedence order, the relatime heuristic, or symlink-traversal atime.

### 10.6 Stat path — no coverage

**There is no statx selftest in this tree.** `find tools/testing/selftests -iname
'*statx*'` returns nothing. `statx()` appears only as a *helper* in
`filesystems/utils.c`, `filesystems/statmount/statmount_test.c`,
`filesystems/move_mount/move_mount_test.c`,
`filesystems/overlayfs/dev_in_maps.c`,
`filesystems/fuse/fuse_acl_cache_test.c` (which does use
`AT_STATX_FORCE_SYNC`), `mount_setattr/mount_setattr_test.c`, `mm/hugetlb_dio.c`,
`proc/fd-003-kthread.c` and `nolibc/nolibc-test.c`.

The only statx-focused program is `samples/vfs/test-statx.c`, which prints fields
and asserts nothing and is not run by kselftest.

**Consequence: every rule in category 7 — 268 through 290 — is untested.** That
includes the `request_mask`/`result_mask` contract (271–274), the `STATX_*` bit
set (275), the sync-flag `-EINVAL` (279), the `query_flags` mask that protects
every network filesystem (280), the multigrain-ctime write (281), and the
`STATX_ATTR_*` contract (285–287).

The adjacent `statmount`/`listmount` suite does exist and is thorough —
`filesystems/statmount/statmount_test.c` (12 functions, `:182-769`),
`statmount_test_ns.c` (`:65-275`), `listmount_test.c` (`:23`, `:45`) — but it
tests the mount-statistics syscalls, not `statx`.

### 10.7 Concurrency and dcache — almost no coverage

- **No KUnit test exists for `fs/namei.c`, `fs/dcache.c`, `fs/open.c` or
  `fs/file_table.c`** — `grep -c kunit` is 0 for all four.
- **`lockref` has no test.** `lib/lockref.c` has no `lockref_kunit.c` and no
  users under `tools/testing/`. Rules 223 and 226 —
  `lockref_get_not_dead` vs `_not_zero`, and `lockref_put_return`'s `-1`
  double-meaning — are entirely untested, on a function that is the heart of
  `dget`/`dput`.
- The only VFS-adjacent KUnit test is `lib/tests/test_hash.c`, which exercises
  `full_name_hash()` (`:157`, `:184`) and `hashlen_string()` (`:183`) — i.e. the
  dcache name hash, with assertions at `:188` and `:192`.
- Other `fs/` KUnit tests are filesystem-specific and do not touch these paths:
  `fs/tests/exec_kunit.c`, `fs/tests/binfmt_elf_kunit.c`, `fs/ext4/*-test.c`,
  `fs/fat/fat_test.c`, `fs/hfs/string_test.c`, `fs/hfsplus/unicode_test.c`,
  `fs/unicode/tests/utf8_kunit.c` (relevant only to `d_compare`/`d_hash` for
  casefolding filesystems), `fs/smb/client/smb*maperror_test.c`.
- **Rules 304–306 (`retry_estale`): NO TEST.** Nothing in the tree drives a
  `-ESTALE` retry.
- **Rules 307–308 (`d_revalidate` contract): NO TEST** of the return-value
  semantics.
- **Rules 296–303 (lock ordering): covered only by lockdep**, which requires a
  `CONFIG_PROVE_LOCKING` build and a workload that actually takes the locks in
  the conflicting order.

### 10.8 xfstests / fstests / LTP

This tree carries no xfstests or LTP harness. `generic/NNN` references appear
only as incidental comments, none of them in core VFS:

| Reference | Location |
|---|---|
| `generic/095` | `fs/xfs/xfs_iomap.c:1738` |
| `generic/388` | `fs/xfs/xfs_inode_item.c:987` |
| `generic/422` | `fs/ext4/ext4_jbd2.h:422` |
| `generic/157` | `fs/smb/client/cifsfs.c:1485` |
| `generic/213` | `fs/ntfs3/file.c:635` |
| `generic/041` | `fs/ntfs3/ntfs.h:31` |
| `generic/340` | `fs/orangefs/orangefs-bufmap.c:451` |
| `generic/342` | `Documentation/filesystems/f2fs.rst:272` |
| `generic/399,548,549,550` | `Documentation/filesystems/fscrypt.rst:1575-1578` |
| `xfs/122` | `fs/xfs/libxfs/xfs_ondisk.h:136`, `:180`, `:225` |

**`fs/namei.c`, `fs/dcache.c`, `fs/open.c`, `fs/namespace.c` and
`fs/file_table.c` carry no xfstests cross-reference at all.**

The normative expectation that a filesystem be testable under fstests is
`Documentation/filesystems/adding-new-filesystems.rst:66-80` (the requirement at
`:73-79`). Invocation recipes appear at
`Documentation/filesystems/fscrypt.rst:1560-1597`,
`fsverity.rst:759-784`, `orangefs.rst:59`, `:154-180`, and
`iomap/porting.rst:49`, `:77`. There is **no
`Documentation/filesystems/testing.rst`** or equivalent central VFS-testing
document. `Documentation/process/adding-syscalls.rst:556` points new syscalls at
LTP and xfstests.

Since no fstests case can be identified from this tree as covering categories 1,
4, 5, 6 or 7, mapping those rules to `generic/NNN` numbers would be guesswork and
is therefore **not established from source**.

### 10.9 Reference-leak and refcount debugging infrastructure

This is the crux for category 5, and the answer is that the infrastructure is
thin.

- `VFS_BUG_ON`, `VFS_WARN_ON`, `VFS_WARN_ON_ONCE`, `VFS_WARN_ONCE`, `VFS_WARN`,
  `VFS_BUG_ON_INODE`, `VFS_WARN_ON_INODE` are defined at
  `include/linux/vfsdebug.h:12-33` under `CONFIG_DEBUG_VFS` and compile to
  `BUILD_BUG_ON_INVALID()` otherwise (`include/linux/vfsdebug.h:35-42`).
  `CONFIG_DEBUG_VFS` is `lib/Kconfig.debug:845`.
- **`VFS_BUG_ON_DENTRY` and `VFS_WARN_ON_DENTRY` do not exist.** The inode is the
  only object with a dumping variant (`dump_inode()`, `fs/inode.c:3083`).
- Usage counts: `fs/namei.c` has 2 `VFS_BUG_ON_INODE` and 4 `VFS_BUG_ON`;
  `fs/inode.c` has 9 and 1; `fs/namespace.c` has 1 `VFS_BUG_ON` and 5
  `VFS_WARN_ON_ONCE`; `fs/file.c` has 3 `VFS_BUG_ON`. **`fs/dcache.c`,
  `fs/open.c` and `fs/file_table.c` have zero.** The dentry cache and the file
  table — exactly where reference bugs live — carry no `VFS_*` assertions at all.
- **No fault injection exists in VFS core.** There is no `should_fail()` or
  `DECLARE_FAULT_ATTR` in `fs/namei.c`, `fs/dcache.c`, `fs/open.c`,
  `fs/file_table.c` or `fs/namespace.c`. The only `CONFIG_FAULT_INJECTION` user
  under `fs/` is f2fs (`fs/f2fs/Kconfig:87`, `fs/f2fs/super.c:77`). There is no
  way to inject `d_alloc()` or `alloc_empty_file()` failures, which is precisely
  how the error paths in category 5 would be reached.
- Two in-tree debug filesystems exist and may be useful:
  `fs/failfs.c` and `fs/nullfs.c` (`fs/Makefile:19`), documented at
  `Documentation/filesystems/failfs.rst`. `failfs` is exercised by
  `tools/testing/selftests/filesystems/failfs/` (17 tests covering
  `fchroot`/`fchdir` sentinel-fd semantics, `:106-563`).

**Reference-leak detection: there is none.**
`tools/testing/selftests/filesystems/file_stressor.c` —
`TEST_F_TIMEOUT(file_stressor, slab_typesafe_by_rcu, 900*2)` at `:109`, fixture
`:49`, setup `:58`, the open/`close_range` loop `:112-134` — is the only
purpose-built `struct file` lifetime test. It races per-CPU openers against
`getdents` on `/proc/<pid>/fd` to shake out `SLAB_TYPESAFE_BY_RCU` use-after-free,
and depends on KASAN to report. **It does not count file descriptors or compare
before/after totals**, and its teardown (`:85-105`) asserts nothing about
refcounts. A steady leak that never causes a use-after-free passes it.

Nothing in the selftests tree reads `/proc/sys/fs/file-nr`; the only mention is a
TODO comment at `tools/testing/selftests/seccomp/seccomp_bpf.c:4344` ("Should
probably spot check /proc/sys/fs/file-nr"). Other `/proc/sys/fs/` readers
(`core/unshare_test.c:34`, `splice/short_splice_read.sh:122`) read `nr_open`, not
`file-nr`.

**Conclusion for category 5: no existing test would detect a dentry or vfsmount
reference leak introduced by this refactor.** The acceptance evidence in 9.4 has
to be produced by the patch author, because the tree provides no harness for it.

### 10.10 Summary of untested rule ranges

| Category | Rules | Coverage |
|---|---|---|
| 1 — permission | 1–27, 37–41 | none as subject |
| 1 — hardening sysctls, sticky | 28–36 | **none** |
| 2 — hook order, return aggregation | 50–58 | **none** |
| 2 — Landlock path requirement | 66–70 | good (`landlock/fs_test.c`) |
| 2 — SELinux/AppArmor/Smack | 71–79 | **none** |
| 2 — audit | 82–90 | partial, via Landlock audit tests only |
| 3 — mount flags | 91–99 | partial (`mount/`, `mount_setattr/`, `fsmount_ns/`) |
| 3 — write-hold protocol | 100–110 | one test (`mount_has_writers`), no barrier coverage |
| 3 — vfsmount lifetime | 111–118 | partial (`mount_setattr` detached-tree group) |
| 3 — idmapped mounts | 132–139 | partial |
| 3 — automount | 140–144 | **none** |
| 4 — RCU/ref-walk | 145–162 | **none directly**; exercised incidentally by every test |
| 4 — symlink stack, ELOOP | 163–174 | **none** |
| 4 — `LOOKUP_*` / `RESOLVE_*` | 175–184 | good, **but not built by default** (10.1) |
| 5 — all | 185–246 | **none** |
| 6 — fsnotify symmetry | 247–250 | **none** |
| 6 — fanotify perm | 251–256 | **none** |
| 6 — readahead, atime | 257–267 | **none** |
| 7 — stat | 268–290 | **none** |
| 8 — locking | 291–303 | lockdep only |
| 8 — estale, revalidate | 304–308 | **none** |
| 8 — lookup/open races | 309–312 | **none** |

