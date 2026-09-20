/-
  Open.lean -- the reference-ownership contract of the VFS open path,
  as an abstract machine, with the three candidate implementations
  proved to agree on every branch.

  Tree: /usr/src/linux 518e5b794c06 (7.3.0-rc3 + 824).

  WHAT IS MODELLED

  Exactly one thing: who owns a reference on `path.dentry` and on
  `path.mnt` at each point between entering `path_openat()` and leaving
  it. Nothing else -- not locking, not RCU, not permissions, not the
  filesystem's `->open`. A proof here says the reference algebra is
  unchanged; it says nothing about whether the patch is otherwise
  correct. The rules that a proof here does NOT cover are enumerated in
  ../10-validation-rules.md and they are the larger half.

  WHY THIS IS WORTH MECHANISING

  The bugs in this area are not subtle reasoning failures, they are
  case-analysis failures: a path where a reference is dropped twice, or
  not at all, that nobody enumerated. Guzik's own series needed a v5
  because v4 dropped a reference that was still needed ("the extra ref
  is of course needed, i blame the heatwave"). That is precisely the
  class of mistake an exhaustive case split catches and a careful human
  reading does not.

  THE MACHINE

  `refs` counts references *taken and not yet released* by this call,
  relative to entry. The ownership booleans say which structure field
  currently holds one. The correctness condition at exit is:

      refs.dentry = (1 if the file owns it else 0)
      refs.mnt    = (1 if the file owns it else 0)

  i.e. every reference taken is either handed to the file or released.
  A leak makes refs too big; a double-put makes it negative.
-/

namespace Vfs

/-- References taken by this call and not yet released, per object. -/
structure Refs where
  dentry : Int
  mnt    : Int
deriving DecidableEq, Repr

/-- Machine state at a point in `path_openat`. -/
structure St where
  refs : Refs
  /-- `nd->path.dentry` holds a reference. -/
  ndDentry : Bool
  /-- `nd->path.mnt` holds a reference. -/
  ndMnt : Bool
  /-- `file->__f_path.dentry` holds a reference. -/
  fDentry : Bool
  /-- `file->__f_path.mnt` holds a reference. -/
  fMnt : Bool
  /-- `FMODE_OPENED` is set on the file. -/
  opened : Bool
  /-- a separate `struct vfsmount *mnt` local holds a reference
      (Guzik's dedicated reference for the truncate case). -/
  localMnt : Bool
  /-- set if `mnt_drop_write()` was reached with no live reference on the
      mount. Not a refcount imbalance -- a use-after-free. -/
  dropWriteViolation : Bool
deriving DecidableEq, Repr

def St.init : St :=
  { refs := ⟨0, 0⟩, ndDentry := false, ndMnt := false,
    fDentry := false, fMnt := false, opened := false, localMnt := false,
    dropWriteViolation := false }

/-- `dget()` / `lockref_get()` -- one atomic RMW on `dentry->d_lockref`. -/
def dget (s : St) : St := { s with refs := ⟨s.refs.dentry + 1, s.refs.mnt⟩ }
/-- `dput()` / `lockref_put_return()`. -/
def dput (s : St) : St := { s with refs := ⟨s.refs.dentry - 1, s.refs.mnt⟩ }
/-- `mntget()` -- per-cpu for a longterm mount, still a reference. -/
def mntget (s : St) : St := { s with refs := ⟨s.refs.dentry, s.refs.mnt + 1⟩ }
/-- `mntput()`. -/
def mntput (s : St) : St := { s with refs := ⟨s.refs.dentry, s.refs.mnt - 1⟩ }

/-- `path_get()` -- `fs/namei.c`, `mntget` then `lockref_get`. -/
def path_get (s : St) : St := dget (mntget s)
/-- `path_put()`. -/
def path_put (s : St) : St := dput (mntput s)

/-!
## The walk

`complete_walk()` -> `try_to_unlazy()` -> `__legitimize_path()` takes a
reference on both halves so the walk can leave RCU mode. After this the
nameidata owns both. `fs/namei.c`.
-/
def legitimize (s : St) : St :=
  { path_get s with ndDentry := true, ndMnt := true }

/-- `terminate_walk()` -- releases whatever `nd->path` still holds.
    `path_put()` tolerates NULL, so a cleared field costs nothing. -/
def terminate_walk (s : St) : St :=
  let s := if s.ndDentry then dput s else s
  let s := if s.ndMnt then mntput s else s
  { s with ndDentry := false, ndMnt := false }

/-!
## The truncate teardown, and why Guzik needed a v5

`do_open()`'s `O_TRUNC` branch calls `mnt_want_write(nd->path.mnt)` before the
open and `mnt_drop_write(...)` after it. `mnt_want_write` takes no reference of
its own -- it bumps a per-cpu write counter on a mount the caller is assumed to
be keeping alive. So the mount must still be referenced by *somebody* at the
moment `mnt_drop_write` runs.

That is not a refcount imbalance, it is a use-after-free, and a model that only
checks `balanced` cannot see it. Hence a second obligation.
-/

/-- Reaching `mnt_drop_write()`. Flags a violation if nothing holds the mount
    at that point. -/
def mnt_drop_write_at (trunc : Bool) (s : St) : St :=
  if trunc && s.refs.mnt < 1 then { s with dropWriteViolation := true } else s

/-!
## `do_dentry_open()`, three ways

`do_dentry_open()` has **three** exit shapes, not two, and the third is easy
to miss because it does not look like an error path:

* `Ok` -- `FMODE_OPENED` set at `fs/open.c:1000`, `f_path` held, released
  later by `__fput()`.
* `EarlyErr` -- any `goto cleanup_file` / `cleanup_all` *before* line 1000.
  `cleanup_file:` does `path_put(&f->f_path)` and NULLs both halves
  (`fs/open.c:1027-1031`), so `FMODE_OPENED` is clear and nothing is held.
* `LateErr` -- `fs/open.c:1017-1018`, the `O_DIRECT` check:

        if ((f->f_flags & O_DIRECT) && !(f->f_mode & FMODE_CAN_ODIRECT))
                return -EINVAL;

  This returns an error with `FMODE_OPENED` **already set** and `f_path`
  **still held**, without passing through `cleanup_file`. The caller gets a
  non-zero return from a file that owns its references, and `__fput()` does
  the full teardown including `dput`/`mntput` (`fs/file_table.c:517-521`).
  `__fput()` skips all of that when `FMODE_OPENED` is clear
  (`fs/file_table.c:493-494`), which is what makes the distinction load-bearing.

A reference-transfer patch that clears `nd->path.dentry` only when the open
succeeded would leak in `LateErr` and double-put in `EarlyErr`. Both are
exactly the case-analysis failure this model exists to catch.

The filesystems make `LateErr` the normal case rather than a curiosity: NFS
returns `-EOPENSTALE` after a successful `finish_open` (`fs/nfs/dir.c:2099`)
and `path_openat`'s retry loop depends on it; cifs returns `-ENOMEM` after it
(`fs/smb/client/dir.c:618-624`). See `../20-filesystems-and-vfs.md`.
-/

/-- The three ways `do_dentry_open()` can return. -/
inductive Outcome where
  /-- success: `FMODE_OPENED` set, `f_path` held -/
  | Ok
  /-- failed before `FMODE_OPENED`: `cleanup_file:` released `f_path` -/
  | EarlyErr
  /-- failed after `FMODE_OPENED`: `f_path` still held (`O_DIRECT`, `-EOPENSTALE`) -/
  | LateErr
deriving DecidableEq, Repr

open Outcome

/-- Common tail: what the three exits do to ownership, given that `f_path`
    has just been populated and whatever references it needs are in place. -/
def finishOpen (o : Outcome) (s : St) : St :=
  match o with
  | Ok       => { s with opened := true }
  | LateErr  => { s with opened := true }          -- f_path retained
  | EarlyErr => { path_put s with fDentry := false, fMnt := false, opened := false }

/-- Mainline: `do_dentry_open()` does `path_get(&f->f_path)` itself. -/
def dentry_open_mainline (o : Outcome) (s : St) : St :=
  finishOpen o { path_get s with fDentry := true, fMnt := true }

/-- Ours (`kbench/patches-dopen/0001`): the caller's *dentry* reference is
    consumed; the mount reference is still taken, because `do_open()` goes
    on to use `nd->path.mnt` for `mnt_drop_write()`. -/
def dentry_open_consume_dentry (o : Outcome) (s : St) : St :=
  finishOpen o { mntget s with fDentry := true, fMnt := true }

/-- Guzik v5 (`vfs_open_consume`): both halves of the caller's reference are
    consumed; `path->mnt` and `path->dentry` are NULLed by the callee. -/
def dentry_open_consume_both (o : Outcome) (s : St) : St :=
  finishOpen o { s with fDentry := true, fMnt := true, ndDentry := false, ndMnt := false }

/-!
## `do_open()`

`trunc` stands for `open_flag & O_TRUNC && !(file->f_mode & FMODE_OPENED)`,
the branch that calls `mnt_want_write()` and therefore needs a mount
reference to survive until `mnt_drop_write()`.
-/

/-- Mainline `do_open()` + `path_openat()`'s `terminate_walk()`. -/
def open_mainline (o : Outcome) (trunc : Bool) : St :=
  let s := legitimize St.init
  let s := dentry_open_mainline o s
  -- mnt_want_write / mnt_drop_write use nd->path.mnt, which nd still owns.
  let s := mnt_drop_write_at trunc s
  terminate_walk s

/-- Ours: the dentry is handed over, `nd->path.dentry` cleared
    unconditionally, the mount left with the nameidata. -/
def open_consume_dentry (o : Outcome) (trunc : Bool) : St :=
  let s := legitimize St.init
  let s := dentry_open_consume_dentry o s
  let s := { s with ndDentry := false }
  -- nd still owns the mount, which is the whole reason this variant keeps it.
  let s := mnt_drop_write_at trunc s
  terminate_walk s

/-- Guzik v5: both handed over. The truncate branch takes a dedicated
    mount reference *before* the open and releases it after, because
    `nd->path.mnt` is no longer ours once the file has it. -/
def open_consume_both (o : Outcome) (trunc : Bool) : St :=
  let s := legitimize St.init
  let s := if trunc then { mntget s with localMnt := true } else s
  let s := dentry_open_consume_both o s
  let s := mnt_drop_write_at trunc s
  let s := if s.localMnt then { mntput s with localMnt := false } else s
  terminate_walk s

/-- Guzik **v4**, the version that had to be withdrawn: both halves handed
    over and *no* dedicated mount reference for the truncate case. -/
def open_consume_both_v4 (o : Outcome) (trunc : Bool) : St :=
  let s := legitimize St.init
  let s := dentry_open_consume_both o s
  let s := mnt_drop_write_at trunc s
  terminate_walk s

/-- The naive reference transfer: clear `nd->path.dentry` only when the open
    succeeded. This is the shape a reader reaches for first, and our own
    commit message argues against it in prose. -/
def open_consume_dentry_naive (o : Outcome) (trunc : Bool) : St :=
  let s := legitimize St.init
  let s := dentry_open_consume_dentry o s
  let s := match o with | Ok => { s with ndDentry := false } | _ => s
  let s := mnt_drop_write_at trunc s
  terminate_walk s

/-!
## What must hold

An implementation is *balanced* when every reference it took has either
been handed to the file or released: nothing leaked, nothing dropped twice.
-/

/-- The file owns a dentry reference iff exactly one is outstanding, and
    likewise for the mount. -/
def balanced (s : St) : Prop :=
  s.refs.dentry = (if s.fDentry then 1 else 0) ∧
  s.refs.mnt    = (if s.fMnt then 1 else 0)

instance (s : St) : Decidable (balanced s) := by
  unfold balanced; infer_instance

/-- Two implementations *agree* when they leave the same references
    outstanding and the same ownership in the file. Internal bookkeeping
    (`localMnt`) is deliberately not compared. -/
def agree (a b : St) : Prop :=
  a.refs = b.refs ∧ a.fDentry = b.fDentry ∧ a.fMnt = b.fMnt ∧ a.opened = b.opened

instance (a b : St) : Decidable (agree a b) := by
  unfold agree; infer_instance

/-! ### Mainline is balanced on every branch -/
theorem mainline_balanced : ∀ o trunc, balanced (open_mainline o trunc) := by
  intro o trunc; cases o <;> cases trunc <;> decide

/-! ### So is ours -/
theorem consume_dentry_balanced :
    ∀ o trunc, balanced (open_consume_dentry o trunc) := by
  intro o trunc; cases o <;> cases trunc <;> decide

/-! ### So is Guzik's -/
theorem consume_both_balanced :
    ∀ o trunc, balanced (open_consume_both o trunc) := by
  intro o trunc; cases o <;> cases trunc <;> decide

/-! ### And all three agree with mainline, on every branch -/
theorem consume_dentry_agrees :
    ∀ o trunc, agree (open_consume_dentry o trunc) (open_mainline o trunc) := by
  intro o trunc; cases o <;> cases trunc <;> decide

theorem consume_both_agrees :
    ∀ o trunc, agree (open_consume_both o trunc) (open_mainline o trunc) := by
  intro o trunc; cases o <;> cases trunc <;> decide

/-! ### No implementation we would ship reaches `mnt_drop_write` on a dead mount -/
theorem mainline_no_uaf :
    ∀ o trunc, (open_mainline o trunc).dropWriteViolation = false := by
  intro o trunc; cases o <;> cases trunc <;> decide

theorem consume_dentry_no_uaf :
    ∀ o trunc, (open_consume_dentry o trunc).dropWriteViolation = false := by
  intro o trunc; cases o <;> cases trunc <;> decide

theorem consume_both_no_uaf :
    ∀ o trunc, (open_consume_both o trunc).dropWriteViolation = false := by
  intro o trunc; cases o <;> cases trunc <;> decide

/-!
### Negative controls

A model that accepts everything proves nothing. These two are the mistakes
that were actually made, and the model rejects both.

`open_consume_both_v4` is Guzik's withdrawn v4: hand both halves to the file
and truncate anyway. On the early-error path `cleanup_file:` has already done
`path_put`, so by the time `mnt_drop_write()` runs nothing holds the mount.
-/
theorem v4_has_use_after_free :
    (open_consume_both_v4 EarlyErr true).dropWriteViolation = true := by decide

/-!
`open_consume_dentry_naive` clears `nd->path.dentry` only on success. It fails
in *both* directions, which is why clearing unconditionally is not a style
choice:

* `EarlyErr` -- `cleanup_file:` released the dentry and `terminate_walk()`
  releases it again: a double put.
* `LateErr` -- the file still owns `f_path` and `terminate_walk()` drops the
  only reference out from under it: a use-after-free on close.
-/
theorem naive_double_puts_on_early_error :
    ¬ balanced (open_consume_dentry_naive EarlyErr false) := by decide

theorem naive_loses_the_reference_on_late_error :
    ¬ balanced (open_consume_dentry_naive LateErr false) := by decide

/-- And the unconditional clear -- what we and Guzik both do -- is the fix. -/
theorem unconditional_clear_is_balanced_where_naive_is_not :
    balanced (open_consume_dentry EarlyErr false) ∧
    balanced (open_consume_dentry LateErr false) := by decide

/-!
## The point of the exercise

Agreement is the safety property. The *reason* for the patches is the
work they do not do. Count the atomic reference operations each
implementation performs on `dentry->d_lockref`, which is the contended
line when several CPUs open one file.
-/

/-- Mainline, successful open: legitimize(get) + do_dentry_open(get)
    + terminate_walk(put) = 3 while open, plus one put at `__fput()`. -/
def mainlineDentryOps : Nat := 4
/-- Ours and Guzik's: legitimize(get) + __fput(put). -/
def transferDentryOps : Nat := 2

theorem transfer_halves_dentry_traffic :
    transferDentryOps * 2 = mainlineDentryOps := by decide

/-!
`mainlineDentryOps` and `transferDentryOps` are *asserted* from the
disassembly (see ../01-open-path.md section 3), not derived here. The
machine above models ownership, not instruction counts; making it count
atomics as well would be a second model and is the obvious next step.
-/

/-!
## Not proved here, and deliberately so

1. That `do_dentry_open()`'s error path really does release `f_path` --
   modelled as `path_put` in `dentry_open_*`, read from `cleanup_file:`
   in `fs/open.c`. If that changes, every theorem above is about the
   wrong program.
2. Anything about `->atomic_open` and `finish_open()`. Viro's series
   changes those, 11 filesystems implement the first and 24 call the
   second, and modelling them needs the per-filesystem behaviour in
   ../20-filesystems-and-vfs.md. Until that document exists, the Viro
   variant is not modelled and must not be claimed proved.
3. `vfs_tmpfile()`, `do_o_path()`, `dentry_open()`, `kernel_file_open()`
   -- the other callers of `vfs_open()`.
4. Concurrency of any kind. This is a sequential model.
-/

end Vfs
