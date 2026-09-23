# Old export (superseded)

This directory held the first export of the two scheduler patches
(wake_entry placement, EEVDF field grouping). It is superseded, and no
scheduler patch is being submitted.

- EEVDF `sched_entity` reorder: measured on v7.3-rc3 (518e5b794c06), no
  difference beyond the base spread. Cover letter and patch in
  [`../submission/removed/`](../submission/removed/).
- wake_entry placement: dropped before measurement; standalone form in
  [`../submission/dropped/`](../submission/dropped/).
- Details: [`../submission/REVIEW.md`](../submission/REVIEW.md).
- The old versions of CAKE timer slack and conntrack raw hashes
  (`../../net/`) and UDP batch wake (`../../client/`) had bugs, fixed in
  their submission versions.

Overall status: [`../../SUBMISSION-STATUS.md`](../../SUBMISSION-STATUS.md).
