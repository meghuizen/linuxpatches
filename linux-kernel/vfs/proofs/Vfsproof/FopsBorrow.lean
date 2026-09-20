/-
  FopsBorrow.lean -- the module reference behind `file->f_op`, with the
  superblock's reference standing in for the file's own.

  Patch: "fs: don't pin the filesystem module per open when the mount already
  does" (0002 in ../patches).

  WHAT IS MODELLED

  Two things that must both hold for the life of a `struct file`:

  * balance: every `try_module_get()` on `f_op->owner` is matched by exactly
    one `module_put()`, and no `module_put()` runs without a matching get
    (an unbalanced put is how a module gets unloaded with a user still alive);
  * pinning: whenever `f_op` is dereferenced, the module it lives in is held
    by *something* -- a reference of ours, or the superblock's reference on
    its own module, which exists for as long as `f_path.mnt` is held.

  The patch replaces the first mechanism by the second when the two modules
  are the same. The cases that matter are the three possible owners of
  `->i_fop` relative to the superblock's module, with and without an `->open`
  instance that swaps `f_op` via `replace_fops()`.
-/

namespace Vfs.FopsBorrow

/-- Who owns `->i_fop`, relative to `i_sb->s_type->owner`. -/
inductive Owner where
  /-- built in: `owner == NULL`, `fops_get()`/`fops_put()` do nothing -/
  | builtin
  /-- the filesystem's own module -/
  | fsModule
  /-- some other module (a filesystem serving another module's file operations) -/
  | otherModule
deriving DecidableEq, Repr

open Owner

structure St where
  /-- references this file holds on the module owning the *current* `f_op` -/
  modrefs : Int
  /-- FMODE_FOPS_BORROWED -/
  borrowed : Bool
  /-- `f_path.mnt` held: from `do_dentry_open()`'s `path_get`/`mntget` to
      `__fput()`'s `mntput()` -/
  mntHeld : Bool
  /-- `f_op` was dereferenced while its module was held by nothing -/
  unpinnedUse : Bool
  /-- `module_put()` with no reference to put -/
  underflow : Bool
  /-- atomic operations on `module->refcnt` performed -/
  atomics : Nat
deriving DecidableEq, Repr

def St.init : St :=
  { modrefs := 0, borrowed := false, mntHeld := false, unpinnedUse := false,
    underflow := false, atomics := 0 }

/-- `try_module_get(owner)`: a cmpxchg on `module->refcnt`, unless NULL. -/
def fops_get (o : Owner) (s : St) : St :=
  match o with
  | builtin => s
  | _ => { s with modrefs := s.modrefs + 1, atomics := s.atomics + 1 }

/-- `module_put(owner)`: another cmpxchg, unless NULL. -/
def fops_put (o : Owner) (s : St) : St :=
  match o with
  | builtin => s
  | _ => if s.modrefs ≥ 1
         then { s with modrefs := s.modrefs - 1, atomics := s.atomics + 1 }
         else { s with underflow := true, atomics := s.atomics + 1 }

/-- Is the module owning `f_op` held by something right now? -/
def pinned (o : Owner) (s : St) : Bool :=
  match o with
  | builtin => true
  | fsModule => decide (s.modrefs ≥ 1) || s.mntHeld
  | otherModule => decide (s.modrefs ≥ 1)

/-- Dereferencing `f_op`: `->open`, `->read`, `->release`, ... -/
def use (o : Owner) (s : St) : St :=
  if pinned o s then s else { s with unpinnedUse := true }

/-- `file_put_fops()` from the patch. -/
def file_put_fops (o : Owner) (s : St) : St :=
  if s.borrowed then { s with borrowed := false } else fops_put o s

/-!
## `replace_fops()`

An `->open` instance that substitutes its own operations (chrdev_open(),
misc_open(), debugfs, drm) releases the reference on the old `f_op` and
installs a new one on which the caller has already taken its own reference
(`fops_get(cdev->ops)` etc.). After that the file's module bookkeeping is
about the new module. We model the new operations as owned by `n`, with the
caller's reference already taken.
-/

/-- The old macro: `fops_put(old); f_op = new`. -/
def replace_fops_old (o n : Owner) (s : St) : St :=
  let s := fops_put o s
  -- new f_op arrives with the caller's own reference
  fops_get n { s with borrowed := false }

/-- The patched macro: `file_put_fops(); f_op = new`. -/
def replace_fops_new (o n : Owner) (s : St) : St :=
  let s := file_put_fops o s
  fops_get n { s with borrowed := false }

/-!
## The two implementations, open to close

`repl = some n` means `->open` swapped `f_op` for operations owned by `n`.
-/

/-- Mainline `do_dentry_open()` .. `__fput()`. -/
def mainline (o : Owner) (repl : Option Owner) : St :=
  let s := { St.init with mntHeld := true }      -- path_get(&f->f_path)
  let s := fops_get o s                           -- f_op = fops_get(i_fop)
  let s := use o s                                -- ->open
  match repl with
  | none =>
    let s := use o s                              -- ->read/->release
    let s := fops_put o s                         -- __fput: fops_put(f_op)
    { s with mntHeld := false }                   -- __fput: mntput
  | some n =>
    let s := replace_fops_old o n s
    let s := use n s
    let s := fops_put n s
    { s with mntHeld := false }

/-- The patch. -/
def borrow (o : Owner) (repl : Option Owner) : St :=
  let s := { St.init with mntHeld := true }
  let s := if o = fsModule then { s with borrowed := true } else fops_get o s
  let s := use o s
  match repl with
  | none =>
    let s := use o s
    let s := file_put_fops o s
    { s with mntHeld := false }
  | some n =>
    let s := replace_fops_new o n s
    let s := use n s
    let s := file_put_fops n s
    { s with mntHeld := false }

/-- What must hold at close. -/
def safe (s : St) : Prop :=
  s.modrefs = 0 ∧ s.underflow = false ∧ s.unpinnedUse = false ∧ s.borrowed = false

instance (s : St) : Decidable (safe s) := by unfold safe; infer_instance

theorem mainline_safe : ∀ o repl, safe (mainline o repl) := by
  intro o repl; cases o <;> cases repl with
  | none => decide
  | some n => cases n <;> decide

theorem borrow_safe : ∀ o repl, safe (borrow o repl) := by
  intro o repl; cases o <;> cases repl with
  | none => decide
  | some n => cases n <;> decide

/-!
## The point: two fewer atomics on a machine-wide word per open/close

On a filesystem built as a module and no `->open` swapping `f_op`, mainline
does two cmpxchg on `module->refcnt` per open/close cycle; the patch does none.
Everything else is unchanged.
-/

theorem fs_module_saves_two_atomics :
    (mainline fsModule none).atomics = 2 ∧ (borrow fsModule none).atomics = 0 := by
  decide

theorem other_owners_unchanged :
    ∀ repl, (borrow builtin repl).atomics = (mainline builtin repl).atomics ∧
            (borrow otherModule repl).atomics = (mainline otherModule repl).atomics := by
  intro repl; cases repl with
  | none => decide
  | some n => cases n <;> decide

/-!
## Negative controls

Two shapes that a reader might think are equivalent, and are not.
-/

/-- Borrowing for *any* non-NULL owner -- forgetting that the mount pins only
    the filesystem's own module. -/
def borrow_any (o : Owner) : St :=
  let s := { St.init with mntHeld := true }
  let s := if o = builtin then s else { s with borrowed := true }
  let s := use o s
  let s := use o s
  let s := file_put_fops o s
  { s with mntHeld := false }

theorem borrowing_a_foreign_module_is_an_unpinned_use :
    (borrow_any otherModule).unpinnedUse = true := by decide

/-- Keeping the old `replace_fops()` -- `fops_put()` unconditionally -- with the
    patch's borrowed `f_op`: `module_put()` on a reference nobody took. -/
def borrow_with_old_replace (o n : Owner) : St :=
  let s := { St.init with mntHeld := true }
  let s := if o = fsModule then { s with borrowed := true } else fops_get o s
  let s := use o s
  let s := replace_fops_old o n s
  let s := use n s
  let s := file_put_fops n s
  { s with mntHeld := false }

theorem old_replace_fops_underflows_a_borrowed_ref :
    (borrow_with_old_replace fsModule builtin).underflow = true := by decide

/-!
## Not proved here

1. That the superblock really pins `s_type->owner` while a mount on it is
   referenced: `sget_fc()` does `get_filesystem(s->s_type)`,
   `deactivate_locked_super()` does `put_filesystem()` after `kill_sb`. This is
   `mntHeld → pinned` in the model, asserted from `fs/super.c`, not derived.
2. The direct `f_op` assignments without `replace_fops()` (cifs, mem.c, tty,
   sound). Each replaces `f_op` by operations with the *same* owner as before,
   which the model would treat as `use` with the same `o`; they are enumerated
   in the commit message rather than modelled.
3. Concurrency: `module->refcnt` is an atomic and the patch removes operations
   on it, it does not reorder any.
-/

end Vfs.FopsBorrow
