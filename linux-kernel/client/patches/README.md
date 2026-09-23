# Old export (superseded)

This directory held the first `git format-patch` export of the three client
patches. It is superseded.

- The current series is in [`../submission/netdev/`](../submission/netdev/):
  1 UDP patch, `[PATCH net-next]`, base v7.3-rc3 (518e5b794c06).
- Not sent: eventpoll layout in
  [`../submission/removed/`](../submission/removed/), IPv4 IP ID in
  [`../submission/dropped/`](../submission/dropped/). Reasons in
  [`../submission/REVIEW.md`](../submission/REVIEW.md).
- Known bug in the old UDP patch (old 0001), fixed in the submission
  version: when every skb of a batch was dropped, `nb == 0` was passed to
  the wakeup, and `__wake_up_common(nr_exclusive=0)` woke every waiter.
  The submission version returns for `nr <= 0`.
- The old versions of CAKE timer slack and conntrack raw hashes in
  `../../net/` also had bugs, fixed in their submission versions.

Overall status: [`../../SUBMISSION-STATUS.md`](../../SUBMISSION-STATUS.md).
