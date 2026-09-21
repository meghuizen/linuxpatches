# Lean 4 model of the VFS reference-ownership contract

    lake build        # proves everything; silence is success

Lean 4.34.0 via elan, no Mathlib — the model is finite and every theorem
discharges by `decide`, so there is nothing to depend on.

## What is modelled

One thing: who owns a reference on `path.dentry` and on `path.mnt` between
entering `path_openat()` and leaving it. Not locking, not RCU, not
permissions, not the filesystem's `->open`.

`Vfsproof/Open.lean` defines an abstract machine (`St`) whose state is the
number of references taken and not yet released, plus which structure field
holds each one, and expresses three implementations over it:

| | |
|---|---|
| `open_mainline` | `do_dentry_open()` does its own `path_get()` |
| `open_consume_dentry` | ours — `kbench/patches-dopen/0001`, dentry handed over, mount kept |
| `open_consume_both` | Guzik v5 — both handed over, dedicated `mntget` for `O_TRUNC` |

## The three exits, which is the part worth having

`do_dentry_open()` has **three** exit shapes, not two, and the third does not
look like an error path:

| | `FMODE_OPENED` | `f_path` | |
|---|---|---|---|
| `Ok` | set | held | released later by `__fput()` |
| `EarlyErr` | clear | released | `cleanup_file:` did `path_put` and NULLed both, `fs/open.c:1027-1031` |
| `LateErr` | **set** | **held** | `fs/open.c:1017-1018` returns `-EINVAL` for `O_DIRECT` without passing through `cleanup_file` |

`LateErr` is not a curiosity. NFS returns `-EOPENSTALE` after a successful
`finish_open` (`fs/nfs/dir.c:2099`) and `path_openat`'s retry loop depends on
it; cifs returns `-ENOMEM` after it (`fs/smb/client/dir.c:618-624`). And
`__fput()` skips its entire teardown when `FMODE_OPENED` is clear
(`fs/file_table.c:493-494`), which is what makes the distinction load-bearing.

The model was written with two exits first. The third was found by checking a
claim in `../20-filesystems-and-vfs.md` against `fs/open.c`, and adding it is
what gives the negative controls below any force.

## What is proved

    mainline_balanced          ∀ o trunc, balanced (open_mainline o trunc)
    consume_dentry_balanced    ∀ o trunc, balanced (open_consume_dentry o trunc)
    consume_both_balanced      ∀ o trunc, balanced (open_consume_both o trunc)
    consume_dentry_agrees      ∀ o trunc, agree (open_consume_dentry ..) (open_mainline ..)
    consume_both_agrees        ∀ o trunc, agree (open_consume_both ..) (open_mainline ..)
    mainline_no_uaf            ∀ o trunc, ¬ reaches mnt_drop_write on a dead mount
    consume_dentry_no_uaf      ∀ o trunc, likewise
    consume_both_no_uaf        ∀ o trunc, likewise

`balanced` means every reference taken was either handed to the file or
released — a leak makes the count too high, a double-put makes it negative.
`agree` means two implementations leave the same references outstanding and
the same ownership in the `struct file`.

`o` ranges over the three exits above; `trunc` is the `O_TRUNC` branch that
calls `mnt_want_write()`. `mnt_want_write` takes **no reference of its own** —
it bumps a per-cpu write counter on a mount the caller is assumed to be keeping
alive — so the mount must still be referenced when `mnt_drop_write()` runs.
That is a use-after-free, not a refcount imbalance, and `balanced` alone cannot
see it. Hence the second obligation.

## Negative controls

A model that accepts everything proves nothing. Both mistakes below were
actually made by someone, and the model rejects both.

    v4_has_use_after_free
        (open_consume_both_v4 EarlyErr true).dropWriteViolation = true

Guzik's withdrawn v4: hand both halves to the file and truncate anyway. On the
early-error path `cleanup_file:` has already done `path_put`, so nothing holds
the mount by the time `mnt_drop_write()` runs. This is the bug his v5 changelog
describes as *"the extra ref is of course needed, i blame the heatwave"*.

    naive_double_puts_on_early_error
        ¬ balanced (open_consume_dentry_naive EarlyErr false)
    naive_loses_the_reference_on_late_error
        ¬ balanced (open_consume_dentry_naive LateErr false)

Clearing `nd->path.dentry` only on success — the shape a reader reaches for
first. It fails in **both** directions: a double put on `EarlyErr`, and on
`LateErr` it drops the only reference out from under a file that still points
at it. Our own commit message argues for the unconditional clear in prose;
this is the same argument, checked.

    unconditional_clear_is_balanced_where_naive_is_not

## Why bother

The failure mode in this area is not subtle reasoning, it is an unenumerated
case — and both of the enumerations above were missed by people who knew this
code far better than we do.

## What is NOT proved

Stated in full at the bottom of `Open.lean`. The short version:

1. That `do_dentry_open()`'s error path really releases `f_path`. That is read
   out of `cleanup_file:` in `fs/open.c` and *assumed* by the model. If it
   changes, every theorem here is about the wrong program.
2. Anything about `->atomic_open` / `finish_open()`, which is what Viro's
   series changes. 11 filesystems implement the first, 24 call the second.
   Modelling it needs `../20-filesystems-and-vfs.md` first, so the Viro variant
   is deliberately absent — it must not be claimed proved.
3. The other `vfs_open()` callers: `vfs_tmpfile()`, `do_o_path()`,
   `dentry_open()`, `kernel_file_open()`.
4. Concurrency. This is a sequential model.

A proof here says the reference algebra is unchanged. It says nothing about
whether a patch is otherwise correct — that is `../10-validation-rules.md`,
and it is the larger half.

---

## The three models for the new patches

Same method, three more files, `lake build` proves all four together.

| file | patch | what is modelled | theorems |
|---|---|---|---|
| `Vfsproof/LazyAlloc.lean` | 3 | the `struct file` across all nine exits of `path_openat()`; that a NULL file at `do_open()` entry implies `lookup_open()` never ran, which is what makes reading `f_mode` from a possibly-NULL file sound; allocation counts before and after, including the `-ECHILD` retry | 9 |
| `Vfsproof/RcuStat.lean` | 6 | a dentry's inode binding versioned by `d_seq`; every interference (`d_move`, kill, rebind) bumps it, so the rcu-walk stat either retries or answers exactly what the ref-walk stat answers — for hard errors as well as successes, which is why the seqcount is checked before looking at the result; and that the fall-back never performs more walks than today | 5 |

Like `Open.lean`, each file ends with the list of what it does **not** prove:
the source facts it asserts (that `lookup_open()` is the only setter of
`FMODE_CREATED`; that `sget_fc()` pins the module; that every binding change
is a `d_seq` write section) are read from the tree and would have to be
re-read if the tree changes.
