# Old export (superseded)

This directory held the first `git format-patch` export of the nine
networking patches. It is superseded.

- The current series is in [`../submission/`](../submission/):
  [`nf-next/`](../submission/nf-next/) (3 conntrack patches) and
  [`net-next/`](../submission/net-next/) (CAKE timer slack, pending).
  Base v7.3-rc3 (518e5b794c06).
- Patches not sent are in [`../submission/removed/`](../submission/removed/)
  and [`../submission/dropped/`](../submission/dropped/); reasons in
  [`../submission/REVIEW.md`](../submission/REVIEW.md).
- Known bugs in the old versions, fixed in the submission versions:
  - CAKE timer slack (old 0001): passed an absolute time
    (`next + slack`) where `qdisc_watchdog_schedule_range_ns()` takes a
    delta, so the default slack 0 was not inert.
  - Conntrack raw hashes (old 0008): `nf_conntrack_hash_check_insert()`
    (ctnetlink/bpf insert path) did not set `hash_raw`.
- The same applies to the UDP batch wake patch in `../../client/`: the old
  version woke every waiter when `nb == 0`.

Overall status: [`../../SUBMISSION-STATUS.md`](../../SUBMISSION-STATUS.md).
