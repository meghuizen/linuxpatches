# Submission status (2026-09-23, 21:00 CEST)

One place for the state of every patch. Details per area are in
`<area>/submission/REVIEW.md`; the emails are the `.patch` files listed
below. Nothing here is committed or sent yet.

## Rules applied (from the submitter)

- Each patch must improve the kernel on its own; no regression, not even
  temporary. Fixable patches are fixed; buggy or regressing patches are
  removed; patches with no measurable difference are removed.
- Emails: short, factual, no rhetoric; what / why / evidence / test
  results (short form of the measured analysis); impact high/medium/low
  and where; Assisted-by trailer; "generated with assistance of Claude"
  notice in the cover letter; anonymous GitHub noreply author
  (`Michiel <367462+meghuizen@users.noreply.github.com>`).
- Before sending: the submitter must add Signed-off-by with a real name
  and reachable address (kernel rules do not accept anonymous DCO).

## How it was measured

patchtest campaign: each patch alone on v7.3-rc3 (518e5b794c06), booted
in a nested KVM guest (16 vCPUs, laptop Ryzen 9 8940HX, KVM in Hyper-V),
29 interleaved boots, 2 rounds, 9 baseline boots. Results:
`/usr/src/kbench/results/patchtest-*` (UTC 20260923-1427 .. -1820), full
report copy: `submission-campaign-report-brief.txt` (next to this file).
Instruction counts are reliable; cycles/rates only between adjacent boots.

## Decisions

| area | patch | result | decision | email |
|---|---|---|---|---|
| vfs | selftests: build openat2 tests | builds and passes every boot | KEEP 1/2 | vfs/submission/0001 |
| vfs | fs: hand the walk's dentry ref to the file | 16 procs one file: -38% kernel cycles/open (6741, 7934 vs 11326-13011); single-process open unchanged | REMOVED: same change as Mateusz Guzik's v5, queued in vfs.git vfs-7.4.lookup (161ce1e692d0); his also saves the mount ref op, ours adds nothing | vfs/submission/removed/ |
| vfs | fs: allocate struct file only when needed (V2b) | ENOENT -22% (ext4) / -13% (tmpfs) kernel insns/open; successful open inside base range | KEEP 2/2, rebased on vfs-7.4.lookup (builds W=1 clean there) | vfs/submission/0002 |
| lib | lockref: single addition (v2, standalone) | fast path -8/-6/-6/-4/-3 insns (x86-64), -5/-3/-3/-4/-1 (arm64), -3/-1/-2/-2/-2 (riscv64); i386 unchanged (v1 had +9 on lockref_get); BE equivalence checked under qemu; in-kernel: inside spread | KEEP as `[PATCH]` standalone (2026-09-26); To: akpm, Cc: Linus, Guzik, hch, Bizjak | vfs/submission/lockref/0001 (branch sub-lockref-v2 in /usr/src/linux-pt-lockref, 77d37d9769a4) |
| nf | 1 hash IPv4 as two words | new flow -155 insns/pkt (below all 21 other boots) | KEEP | net/submission/nf-next/0001 |
| nf | 2 keep unscaled hashes for teardown | flush -597 insns/entry (-31%) | KEEP | nf-next/0002 |
| nf | 3 warn when max > 8x buckets | 8x silent, 9x warns once, netns refused | KEEP | nf-next/0003 |
| net | bridge ARP proxy early return | -0.8%, inside spread (rule needed -2%) | REMOVED | net/submission/removed/ |
| net | CAKE timer slack attribute | slack 0 inert (= baseline); 100 Mbit/170 B: expiries/pkt 0.55 -> 0.12/0.06/0.05, arms 1.55 -> 0.99 at 100 us; guest sys+irq CPU/pkt -26..33% at 100 us; rate stays <= configured; bound slack <= target/2 added (Fable review) | KEEP as [RFC PATCH net-next] (needs iproute2); paced over-limit comparison not completed (host throttled) | net/submission/net-next/0001 (branch sub-cake-final in /usr/src/linux-pt-cake, 9475c7fe8c87 amended) |
| client | udp: one wakeup per drained batch | epoll callbacks/dgram 1.00 -> 0.87-0.91 (6 senders), 0.45-0.47 (12); fixed-rate test: no extra drops at equal load (30 vs 61k of 13.5M) | KEEP, now [PATCH net-next] | client/submission/netdev/0001 |
| client | eventpoll field layout | inside spread | REMOVED | client/submission/removed/ |
| sched | EEVDF sched_entity reorder | no difference (512-task L1 +22% was one outlier boot) | REMOVED, no sched series | sched/submission/removed/ |

Series labels now: vfs `[PATCH 0/2]` on vfs.git vfs-7.4.lookup (branch
sub-vfs-final-7.4 in /usr/src/sub-vfs, tip ef5d4767f13a), nf `[PATCH nf-next 0/3]`, udp
`[PATCH net-next 0/1]`, CAKE `[RFC PATCH net-next]` single patch.

## Open

1. CAKE: decided with the data at hand (submitter closed the laptop).
   Email rewritten per the Fable review (cake-analysis/ANALYSIS.md 5.5),
   value bound added and W=1/checkpatch clean. Not done: a paced
   over-the-limit comparison of drops/delay (every attempt was host
   limited: host load, PMU exits with perf, idle-wakeup cost, then
   thermal throttling), the bound at runtime (TESTS.md T4), T5
   (instructions per timer wakeup without CAKE). These are listed as
   not tested in the email.
2. Final branches, built with `git am` from the exported emails (so the
   commit messages are exactly what is sent; below-`---` notes stay out
   of git), each commit W=1-builds its touched objects with no warnings,
   code identical to the old branches minus the removed patches:
   sub-vfs-final-7.4 (in /usr/src/sub-vfs, 2 commits on vfs.git
   vfs-7.4.lookup 161ce1e692d0, tip ef5d4767f13a; the older 3-commit
   sub-vfs-final on v7.3-rc3 is superseded),
   sub-nf-final (in /usr/src/sub-net, 3 commits, tip 0689b0b51400),
   sub-udp-final (in /usr/src/sub-client, 1 commit, f13187b9a0f8).
   Old branches (sub-vfs, sub-net, sub-client) kept unchanged. CAKE not
   yet (pending).
3. Repo documentation updated in the working tree (not committed): old
   <area>/patches/ exports deleted (they contained the CAKE slack,
   conntrack hash_raw and UDP nb=0 bugs) and replaced by a README pointing
   to submission/; root README, area READMEs and docs 01-04 carry status
   notes with the measured outcome; withdrawn claims marked. Links checked,
   privacy grep clean. The new links point to untracked files
   (submission/, this file), so all of it must be committed together.
   Commit/push only when the submitter asks.
4. Harness notes: lockref call counting is dead (lockref_* have no
   __fentry__, use kprobes); context-switches CPU-wide probe can read 0
   on an idle CPU; staged harness edits live in scratchpad/stage/.

## Key paths

- Scratchpad: /tmp/claude-0/-usr-src-linuxpatches/9691c9a3-b70d-4804-a7be-7a4acdddcb51/scratchpad
  (campaign-report*.txt, stage/, cake-analysis/, follow-up scripts *-after.sh)
- Harness: /usr/src/kbench/scripts/guest/patchtest.sh (+ patchtest-src/),
  report: /usr/src/kbench/scripts/patchtest-report.py
- Per-patch test worktrees: /usr/src/linux-pt-{dentry,lockref,lazyalloc,
  eevdf,nf,cake,bridge,udp,epoll,all}
- Submission branches/worktrees: /usr/src/sub-{vfs,net,client,sched}
