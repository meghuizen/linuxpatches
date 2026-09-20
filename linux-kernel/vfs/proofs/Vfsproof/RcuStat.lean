/-
  RcuStat.lean -- why a stat answered without references is the same stat.

  Patch: "fs: answer statx() without leaving rcu-walk when the filesystem
  allows it" (0006 in ../patches).

  WHAT IS MODELLED

  The terminal dentry's binding to an inode, versioned by `d_seq`, and the
  two ways of reading through it:

  * ref-walk (today): pin the binding (`lockref_get_not_dead`), read the
    inode, unpin. The binding cannot change while pinned.
  * rcu-walk (the patch): sample `d_seq`, read whatever the dentry is bound
    to *now*, re-check `d_seq`. Anything that changed the binding in between
    -- `d_move()`, `__d_drop()`, `dentry_unlink_inode()`, `d_splice_alias()`
    -- bumps `d_seq`, so a stale answer is detected and thrown away.

  The property is: the rcu-walk stat never returns an answer that the
  ref-walk stat could not have returned. It either returns the same thing or
  asks for the ref-walk to be done instead. Errors count as answers: a hard
  error computed on the wrong inode is exactly as wrong as a wrong kstat.

  What is *not* claimed is anything about the inode's *contents* changing
  under a concurrent `setattr`; that race exists in ref-walk today too
  (../10-validation-rules.md, rule 7.6, torn reads) and is unchanged.
-/

namespace Vfs.RcuStat

/-- A dentry's binding: which inode, and the `d_seq` at which it was set. -/
structure Binding where
  seq : Nat
  inode : Option Nat   -- none: negative / killed
deriving DecidableEq, Repr

/-- What another CPU may do to the terminal dentry between the walk arriving
    and the seqcount re-check. Everything that changes the binding goes through
    a `d_seq` write section (`fs/dcache.c`); nothing else touches `d_inode`. -/
inductive Interference where
  | none
  /-- `d_move()`: renamed; same inode, but this dentry is no longer what the
      path names. `d_seq` bumped. -/
  | moved
  /-- `dentry_unlink_inode()` / `__dentry_kill()`: `d_inode` cleared. -/
  | killed
  /-- unlink + create under the same name resolved to a different inode:
      the dentry is negative then a new one is spliced. -/
  | rebound (newInode : Nat)
deriving DecidableEq, Repr

open Interference

def perturb (i : Interference) (b : Binding) : Binding :=
  match i with
  | Interference.none => b
  | moved => { b with seq := b.seq + 1 }
  | killed => { seq := b.seq + 1, inode := Option.none }
  | rebound n => { seq := b.seq + 1, inode := some n }

/-- The result of a stat attempt. `retry` is -ECHILD: do it in ref-walk. -/
inductive Result where
  | answer (inode : Nat)
  | retry
deriving DecidableEq, Repr

/-- `getattr` reads through whatever inode the dentry holds at read time. -/
def getattr (b : Binding) : Result :=
  match b.inode with
  | some n => Result.answer n
  | Option.none => Result.retry   -- a negative dentry: the walk would have said ENOENT

/-- Ref-walk: the binding is pinned before the interference can land. -/
def refStat (b : Binding) (_ : Interference) : Result := getattr b

/-- Rcu-walk: sample, read the binding *after* the interference, re-check. -/
def rcuStat (b : Binding) (i : Interference) : Result :=
  let seq0 := b.seq
  let b' := perturb i b
  let r := getattr b'
  if b'.seq = seq0 then r else Result.retry

/-!
## Every answer the rcu-walk stat gives, the ref-walk stat gives too

Bindings and inode numbers are unbounded; the theorem is by case analysis on
the interference, which is what determines whether `d_seq` moved.
-/

theorem rcu_never_answers_differently :
    ∀ (b : Binding) (i : Interference),
      rcuStat b i = Result.retry ∨ rcuStat b i = refStat b i := by
  intro b i
  cases i with
  | none => right; simp [rcuStat, refStat, perturb]
  | moved => left; simp [rcuStat, perturb]
  | killed => left; simp [rcuStat, perturb]
  | rebound n => left; simp [rcuStat, perturb]

/-- And with no interference it does answer, so the fast path is not vacuous. -/
theorem rcu_answers_when_undisturbed :
    ∀ (b : Binding), rcuStat b Interference.none = refStat b Interference.none := by
  intro b; simp [rcuStat, refStat, perturb]

/-!
## The check is on the *result*, whatever it is

`path_lookupat_op()` re-checks `d_seq` after `->rcu` returned, before looking
at what it returned. A variant that only checked on success would return a
hard error computed on the wrong inode. Model it and reject it.
-/

/-- `->rcu` may also produce a hard error (e.g. the LSM denying) from the
    inode it saw. -/
inductive Result' where
  | answer (inode : Nat)
  | denied (inode : Nat)   -- -EACCES computed from this inode's label
  | retry
deriving DecidableEq, Repr

/-- Deny access to odd inodes: a stand-in for "the label of that inode". -/
def getattr' (b : Binding) : Result' :=
  match b.inode with
  | some n => if n % 2 = 1 then Result'.denied n else Result'.answer n
  | Option.none => Result'.retry

def refStat' (b : Binding) (_ : Interference) : Result' := getattr' b

/-- The patch: check the seqcount regardless of what `->rcu` returned. -/
def rcuStat' (b : Binding) (i : Interference) : Result' :=
  let b' := perturb i b
  if b'.seq = b.seq then getattr' b' else Result'.retry

/-- The tempting shortcut: only validate successes. -/
def rcuStatCheckOnSuccess (b : Binding) (i : Interference) : Result' :=
  let b' := perturb i b
  match getattr' b' with
  | Result'.answer n => if b'.seq = b.seq then Result'.answer n else Result'.retry
  | other => other

theorem patched_check_is_sound :
    ∀ b i, rcuStat' b i = Result'.retry ∨ rcuStat' b i = refStat' b i := by
  intro b i
  cases i with
  | none => right; simp [rcuStat', refStat', perturb]
  | moved => left; simp [rcuStat', perturb]
  | killed => left; simp [rcuStat', perturb]
  | rebound n => left; simp [rcuStat', perturb]

/-- Rebinding an allowed inode (2) to a denied one (3) makes the shortcut deny
    a stat that ref-walk would have answered. -/
theorem check_on_success_only_denies_the_wrong_inode :
    rcuStatCheckOnSuccess ⟨0, some 2⟩ (rebound 3) = Result'.denied 3 ∧
    refStat' ⟨0, some 2⟩ (rebound 3) = Result'.answer 2 := by
  simp [rcuStatCheckOnSuccess, refStat', getattr', perturb]

/-!
## The fallback does not walk twice

`filename_lookup_op()` calls `->rcu`; on -ECHILD it does not restart, it
calls `complete_walk()` where it stands and then `->ref`. Only a *failed*
`complete_walk()` (the same `try_to_unlazy()` failure that makes today's
`filename_lookup()` restart) restarts.
-/

inductive RcuVerdict where
  | answered      -- ->rcu answered and d_seq held
  | declined      -- ->rcu returned -ECHILD, or d_seq moved
deriving DecidableEq, Repr

inductive Unlazy where
  | ok            -- try_to_unlazy() succeeded
  | failed        -- try_to_unlazy() failed: restart in ref-walk
deriving DecidableEq, Repr

/-- Number of complete path walks performed. -/
def walksPatched (v : RcuVerdict) (u : Unlazy) : Nat :=
  match v with
  | RcuVerdict.answered => 1
  | RcuVerdict.declined => match u with
    | Unlazy.ok => 1
    | Unlazy.failed => 2

/-- Today: rcu-walk, `complete_walk()`, then the operation with references. -/
def walksMainline (u : Unlazy) : Nat :=
  match u with
  | Unlazy.ok => 1
  | Unlazy.failed => 2

theorem never_more_walks_than_today :
    ∀ v u, walksPatched v u ≤ walksMainline u := by
  intro v u; cases v <;> cases u <;> decide

/-!
## Not proved here

1. That every binding change goes through a `d_seq` write section. Read from
   `fs/dcache.c` (`d_move`, `__d_drop`/`___d_drop`, `dentry_unlink_inode`,
   `__d_set_inode_and_type`); it is also what the rcu-walk of every earlier
   component already relies on.
2. That the inode's memory stays valid through the read: `destroy_inode()`
   frees through `call_rcu`, and the read is inside `rcu_read_lock()`.
   Filesystems that reuse inode memory without a grace period (xfs) are
   discussed in their opt-in patch.
3. Contents changing under the read without a binding change (`setattr`).
   Unchanged from today; see rule 7.6.
4. The mount side: `mount_lock` is sampled and re-checked the same way; the
   same argument applies and it is not repeated here.
-/

end Vfs.RcuStat
