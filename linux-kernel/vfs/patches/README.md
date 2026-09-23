# Old export (superseded)

This directory held the first `git format-patch` export of the VFS series
(14 patches against v7.3-rc3 + 824 commits). It is superseded.

- The current series is in [`../submission/`](../submission/): 3 patches,
  `[RFC PATCH 0/3]`, base v7.3-rc3 (518e5b794c06).
- Patches not sent, with the reason for each, are in
  [`../submission/removed/`](../submission/removed/) and listed in
  [`../submission/REVIEW.md`](../submission/REVIEW.md).
- Old versions with known bugs, fixed in the submission versions: CAKE
  timer slack (`../../net/`), conntrack raw hashes (`../../net/`), UDP batch
  wake (`../../client/`). The old rcu-walk stat patches (old 3-8) had a NULL
  dereference race and were removed, not fixed.

Overall status: [`../../SUBMISSION-STATUS.md`](../../SUBMISSION-STATUS.md).
