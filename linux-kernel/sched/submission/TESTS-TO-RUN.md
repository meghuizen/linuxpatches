# sched: tests to run (coordinator only -- needs the VM)

The series is one patch: `sched/fair: Reorder struct sched_entity for the
EEVDF tree walk` (worktree `/usr/src/sub-sched`, commit `17ebab605729`,
on `518e5b794c06`). It has never been booted. Every scheduler number in
`/usr/src/kbench/results` was measured on `full`/`everything` kernels that
carry the OLD sched pair (sched_class adjacency + nr_cpus_allowed/cpus_ptr
move: e.g. `29488dcc6e44`, `74647f88907c`, `5d2889a8030b`), not this patch
and not the wake_entry patch. None of it applies here.

## Kernels

| variant   | source                                                    |
|-----------|-----------------------------------------------------------|
| baseline  | `518e5b794c06` (the existing `baseline` build, /usr/src/linux at master) |
| schedse   | `518e5b794c06` + `submission/0001-sched-fair-Reorder-struct-sched_entity-for-the-EEVDF.patch` only |

Nothing else in `schedse`: no vfs, net, client or old sched patches.

```
git -C /usr/src/linux worktree add /usr/src/linux-schedse 17ebab605729
/usr/src/kbench/scripts/build-kernel.sh schedse     # same kconfig.sh as baseline
```

Before booting, confirm the build is the layout the patch claims:

```
python3 /usr/src/linuxpatches/linux-kernel/sched/submission/tests/se-lines.py \
    /usr/src/kbench/builds/baseline/vmlinux /usr/src/kbench/builds/schedse/vmlinux
# expect exit 0, "pick_eevdf() ... 3 -> 1", sizeof(task_struct) unchanged
```

## Runs

Interleaved, one boot each, three rounds: baseline, schedse, baseline,
schedse, baseline, schedse (same pattern as `ab-run.sh`, variant list
`baseline schedse`). One VM at a time.

### Test 1 -- existing tree-bench sections (no harness change)

Read these three sections of each `tree-*.txt`:

1. `### eevdf pick depth (sched layout)` -- per `runnable=` row:
   `L1-miss/switch`, `kinsn/switch`, `kcycles/switch`.
2. `### scheduler: switch and wakeup` -- both `same core` and `cross core`,
   reps 1-3: `insn/switch`, `cycles/switch`, `L1-miss/switch`,
   `LLC-miss/switch`.
3. `### cross-cpu wakeup storm` -- `L1-miss/wakeup`, `LLC-miss/wakeup`;
   the `wakeup-pairs/s` rate only on rows with `spread=` <= 15% and no
   `!! control moved`, and only compared within an adjacent B/P pair.

What decides it: the per-switch perf counters (kernel instructions,
cycles, L1 and LLC misses). Rates are secondary.

Resolution warning, from the existing baseline run
`baseline-00824-g518e5b794c06-20260922-054244`: the pick-depth section
does about 350 switches/s (tick-driven), with ~47k kernel instructions and
~2500-2900 L1 misses per switch, and cross-core pipe L1-miss/switch moved
1444 -> 2388 across three reps. The expected effect of this patch is two
fewer lines per tree level on a pick, i.e. roughly 10-30 L1 misses per
pick at runnable=128 (only if those lines are not already in L1). That
is about 1% of this section's per-switch count and below its rep-to-rep
spread, so a null result from Test 1 alone does not decide anything.
Test 1's job is mainly the non-regression check on sections 2 and 3.

### Test 2 -- targeted pick test (needs one extra binary in the guest)

Source: `submission/tests/yield-pick.c` (static build:
`gcc -O2 -Wall -static -o yield-pick yield-pick.c`). It starts N
SCHED_OTHER processes pinned to one CPU that call `sched_yield()` in a
loop, so every switch is a pick over an N-entry tree and switches run at
~10^5-10^6/s instead of 350/s. In the guest, on CPU 3 (not CPU 0, which
takes device interrupts):

```
for n in 2 16 64 128 256 512; do
  for rep in 1 2 3; do
    perf stat -C 3 -x, -e context-switches,L1-dcache-load-misses,instructions:k,cycles:k \
      -- /tmp/yield-pick 3 $n 5
  done
done
```

Report per row: L1-dcache-load-misses/switch, instructions:k/switch,
cycles:k/switch, as median of the 3 reps, baseline vs schedse, for each
interleaved pair.

## Expected result and what changes the recommendation

- instructions:k/switch: equal within 0.5% at every N (the patch changes
  no code; fair.o text is 97 bytes smaller from shorter displacements).
  A larger difference means something else differs between the builds.
- L1-miss/switch in Test 2: equal at N=2; lower with schedse as N grows,
  the gap growing with log2(N) (roughly 2 lines per tree level).
- Test 1 sections 2 and 3: no counter worse than baseline beyond the
  baseline's own rep-to-rep spread.

Recommendation moves from RFC to SEND (non-RFC) if: Test 2 shows
L1-miss/switch lower for schedse at N >= 128 in all three interleaved
pairs, by more than the larger of the two variants' rep spreads, with
cycles:k/switch not higher; AND no Test 1 per-switch counter is
consistently worse (all three pairs) for schedse.

Recommendation moves to DROP if: any per-switch counter in Test 1
section 2 or 3 is worse in all three pairs, or Test 2 shows no
difference at N=512 (layout churn with no measurable benefit).

Anything in between (difference in some pairs only): stays RFC, report
the numbers as they are.

## Optional, low priority -- confirms the wake_entry DROP

`submission/dropped/wake_entry-standalone-DROPPED.diff` applied alone on
`518e5b794c06` (variant `wakeentry`), interleaved with baseline, section
`### cross-cpu wakeup storm` and `### scheduler: switch and wakeup`
(cross core). The static analysis in REVIEW.md predicts no improvement
and possibly one more remotely-dirtied line per queued wakeup. Only run
this if someone wants to revive that patch; it changes nothing for the
series as posted.
