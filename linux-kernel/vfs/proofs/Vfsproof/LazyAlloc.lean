/-
  LazyAlloc.lean -- ownership of the `struct file` across every exit of
  `path_openat()`, before and after the allocation was moved off the front.

  Patch: "fs: allocate the struct file only once an open can no longer fail
  cheaply" (0003 in ../patches).

  WHAT IS MODELLED

  One object: the `struct file` that `path_openat()` may allocate, and who
  owns it at each exit. Mainline allocates it first thing and frees it on any
  error. The patch allocates it in one of two later places -- in
  `open_last_lookups()` before `lookup_open()`, or in `do_open()` right before
  `vfs_open()` -- and the question is whether every exit still ends with the
  file either returned or freed exactly once.

  The second question the model answers is the one that makes the patch
  correct at all: `do_open()` reads `f_mode` from a possibly-NULL file and
  treats NULL as "neither FMODE_OPENED nor FMODE_CREATED". That is only sound
  if a NULL file at `do_open()` entry implies `lookup_open()` never ran, which
  is a property of the control flow, not of the data. It is proved below.
-/

namespace Vfs.LazyAlloc

/-- The distinct exits of one `path_openat()` attempt. -/
inductive Exit where
  /-- `link_path_walk()` / `lookup_fast()` / `step_into()` failed: ENOENT, ENOTDIR,
      EACCES on a component, ELOOP, EISDIR from `lookup_fast_for_open()`. -/
  | walkErr
  /-- the dcache did not have the last component (or O_CREAT): `lookup_open()`
      ran and failed -/
  | lookupOpenErr
  /-- `lookup_open()` ran and `->atomic_open()` opened the file into it -/
  | lookupOpenOpened
  /-- `lookup_open()` ran, created or found the dentry, did not open; then
      `do_open()` opened it -/
  | lookupOpenThenOk
  /-- `do_open()` refused before opening: EEXIST, EISDIR, ENOTDIR, EFTYPE,
      `may_open()` EACCES/EPERM, `mnt_want_write()` EROFS -/
  | doOpenCheckErr
  /-- `alloc_empty_file()` itself failed: ENFILE or ENOMEM -/
  | allocErr
  /-- `do_dentry_open()` failed -- early or late, `fput_close()` handles both -/
  | vfsOpenErr
  /-- the plain success: dcache hit, `do_open()` opened it -/
  | ok
  /-- `-ECHILD`: the whole attempt is repeated in ref-walk by `do_file_open()` -/
  | childRetry
deriving DecidableEq, Repr

open Exit

structure St where
  /-- `alloc_empty_file()` calls -/
  allocs : Nat
  /-- a file is allocated and owned by this attempt -/
  live : Bool
  /-- `lookup_open()` has run (it may have set FMODE_CREATED / FMODE_OPENED) -/
  lookupOpenRan : Bool
  /-- returned to the caller with FMODE_OPENED -/
  returned : Bool
  /-- `fput_close()` calls -/
  frees : Nat
  /-- `fput_close()` on a file we did not own -/
  doubleFree : Bool
deriving DecidableEq, Repr

def St.init : St :=
  { allocs := 0, live := false, lookupOpenRan := false, returned := false,
    frees := 0, doubleFree := false }

def alloc (s : St) : St := { s with allocs := s.allocs + 1, live := true }

/-- `fput_close()` on the error path: only if a file exists. Mainline calls it
    unconditionally, which is fine there because the file always exists. -/
def fput_close (s : St) : St :=
  if s.live then { s with frees := s.frees + 1, live := false }
  else { s with doubleFree := true }

def return_file (s : St) : St := { s with returned := true, live := false }

/-- Does this exit pass through `lookup_open()`? -/
def needsLookupOpen : Exit → Bool
  | lookupOpenErr | lookupOpenOpened | lookupOpenThenOk => true
  | _ => false

/-- Does this exit reach the point in `do_open()` just before `vfs_open()`? -/
def reachesVfsOpen : Exit → Bool
  | lookupOpenThenOk | allocErr | vfsOpenErr | ok => true
  | _ => false

def isSuccess : Exit → Bool
  | lookupOpenOpened | lookupOpenThenOk | ok => true
  | _ => false

/-- Mainline `path_openat()`: allocate first, free on any error. -/
def mainline (e : Exit) : St :=
  let s := alloc St.init
  let s := if needsLookupOpen e then { s with lookupOpenRan := true } else s
  -- allocErr cannot happen after the allocation already succeeded; mainline
  -- has no second allocation. It is an error exit like any other here.
  if isSuccess e then return_file s else fput_close s

/-- The patch: no file until `lookup_open()` needs one or `do_open()` is about
    to call `vfs_open()`. On `allocErr` the allocation itself fails, so the
    file stays absent; the caller frees only if a file exists. -/
def lazy (e : Exit) : St :=
  let s := St.init
  let s := if needsLookupOpen e then { alloc s with lookupOpenRan := true } else s
  let s := if reachesVfsOpen e && !s.live && e != allocErr then alloc s else s
  if isSuccess e then return_file s
  else if s.live then fput_close s else s

/-!
## Soundness: nothing leaked, nothing freed twice, success returns a file
-/

def sound (s : St) (e : Exit) : Prop :=
  s.doubleFree = false ∧
  s.live = false ∧
  s.returned = isSuccess e ∧
  (isSuccess e = true → s.allocs = 1)

instance (s : St) (e : Exit) : Decidable (sound s e) := by
  unfold sound; infer_instance

theorem mainline_sound : ∀ e, sound (mainline e) e := by
  intro e; cases e <;> decide

theorem lazy_sound : ∀ e, sound (lazy e) e := by
  intro e; cases e <;> decide

/-- Both hand the caller the same thing on every exit. -/
theorem lazy_agrees : ∀ e, (lazy e).returned = (mainline e).returned := by
  intro e; cases e <;> decide

/-!
## The property that makes `do_open()`'s NULL handling sound

`do_open()` computes `f_mode = file ? file->f_mode : 0`. FMODE_CREATED and
FMODE_OPENED can only be set by `lookup_open()` (via `->create` or
`->atomic_open`/`finish_open`). So the substitution is correct exactly when
"no file" implies "`lookup_open()` did not run". In the lazy variant a file is
allocated *before* `lookup_open()` on every path that reaches it.
-/

/-- State at `do_open()` entry for the lazy variant. -/
def lazyAtDoOpen (e : Exit) : St :=
  let s := St.init
  if needsLookupOpen e then { alloc s with lookupOpenRan := true } else s

theorem null_file_means_lookup_open_did_not_run :
    ∀ e, (lazyAtDoOpen e).live = false → (lazyAtDoOpen e).lookupOpenRan = false := by
  intro e; cases e <;> decide

/-!
## The point: where the allocation no longer happens

Every exit that fails in the walk or in `do_open()`'s checks, and the -ECHILD
restart, now costs no allocation and no free.
-/

theorem lazy_never_allocates_more : ∀ e, (lazy e).allocs ≤ (mainline e).allocs := by
  intro e; cases e <;> decide

theorem failed_walks_allocate_nothing :
    (lazy walkErr).allocs = 0 ∧ (lazy doOpenCheckErr).allocs = 0 ∧
    (lazy childRetry).allocs = 0 := by decide

theorem mainline_allocates_on_every_failure :
    (mainline walkErr).allocs = 1 ∧ (mainline doOpenCheckErr).allocs = 1 ∧
    (mainline childRetry).allocs = 1 := by decide

/-- `do_file_open()`: an -ECHILD attempt followed by the real one. -/
def withRetry (impl : Exit → St) (e : Exit) : Nat :=
  (impl childRetry).allocs + (impl e).allocs

theorem retry_costs_mainline_an_extra_file : ∀ e, withRetry mainline e = 1 + (mainline e).allocs := by
  intro e; cases e <;> decide

theorem retry_costs_lazy_nothing : ∀ e, withRetry lazy e = (lazy e).allocs := by
  intro e; cases e <;> decide

/-!
## Not proved here

1. That `lookup_open()` is the only setter of FMODE_CREATED/FMODE_OPENED before
   `do_open()`. Read from `fs/namei.c`; `->atomic_open` instances call
   `finish_open()` on the file `lookup_open()` passed them.
2. That the allocation moved into `open_last_lookups()` happens in ref-walk
   (GFP_KERNEL). It sits after the `try_to_unlazy()` / `WARN_ON_ONCE(LOOKUP_RCU)`
   block that already guarded `lookup_open()`.
3. The ENFILE-vs-walk-error ordering change, which is a semantic decision, not a
   correctness property.
-/

end Vfs.LazyAlloc
