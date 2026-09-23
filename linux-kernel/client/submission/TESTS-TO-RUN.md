# Client series: tests that need the patched kernel

Everything here runs in the guest. Nothing in this directory boots a VM.
The coordinator runs these one at a time.

## Kernels

| name     | tree / commit                                   | contents                       |
|----------|-------------------------------------------------|--------------------------------|
| baseline | 518e5b794c06                                    | v7.3-rc3 (existing kbench baseline) |
| c1       | /usr/src/sub-client, commit f6c6f3cb5ee9        | baseline + udp patch only      |
| c3       | /usr/src/sub-client, branch sub-client-vfs, d110c676df57 | baseline + eventpoll patch only |

Per-patch kernels, not `everything`: each patch has to be judged on its own.
The ipv4 IP-ID patch is DROPPED and needs no test (see REVIEW.md).

Boot order, interleaved, one script run per boot:

    baseline, c1, c3, baseline, c1, c3

## Command (every boot)

Copy `submission/tests/` into the guest and run:

    ./run-guest.sh > /mnt/results/client-tests-$(uname -r)-$(date +%Y%m%d-%H%M%S).txt 2>&1

It needs gcc and perf (both already used by kbench) and either the ftrace
function profiler (the guest reports `function_profile: yes`) or bpftrace.
It takes about 2.5 minutes. `tests/host-run-guest-validation.txt` shows what
the output looks like on the host kernel (the host denies the function
profiler, so T1a is empty there; the bpftrace version of T1a was run
separately, see `tests/host-results.txt`).

## What to read, and what changes the recommendation

### T1a -- patch 1 mechanism (kernels baseline, c1)

Function hit counts for `udp_batch_wake epoll <senders> 3`.

Expected:
- baseline: `ep_poll_callback` hits = `sock_def_readable` hits = `got`
  (datagrams queued), at every sender count.
- c1: `sock_data_ready_nr` hits = number of drains; `ep_poll_callback`
  hits = `sock_data_ready_nr` hits. At senders=1 that equals `got`; at 6 and
  12 senders it is lower than `got` (host, unpatched: 5.8% and 15.9% fewer
  drains than datagrams, see `tests/nb-summary.txt`).

Changes the recommendation:
- c1 `ep_poll_callback` hits still equal to `got` at 6+ senders: the fast
  path is not taken. Patch 1 -> DROP until understood.

### T1b -- patch 1, exclusive waiters (baseline, c1)

`udp_batch_wake block 6 4 3` and `block 2 4 3`, twice.

Expected on both kernels: `unaccounted=0`, `late_wakeups=0`, `per_rx`
roughly even across the 4 receivers (host: within 3%).

Changes the recommendation:
- any `late_wakeups` > 0 or `unaccounted` != 0 on c1 but not baseline:
  patch 1 -> DROP.

### T1c -- patch 1, no regression at nb = 1 (baseline, c1)

`perf stat` instructions:k per datagram, 3 runs at senders=1 and 3 at
senders=6.

Expected: senders=1 equal within 0.5% (host repeatability: 11849-11893,
0.4%). senders=6 is informational only (host spread 13%, driven by how many
datagrams were dropped).

Changes the recommendation:
- senders=1 higher on c1 than baseline by > 0.5% in both rounds: patch 1
  -> HOLD, look at what else changed in the path.

If T1a, T1b and T1c pass: patch 1 goes out as RFC net-next as prepared in
`netdev/`. Paste the T1a counts into the below-`---` notes.

### T2a -- patch 3, uncontended case (baseline, c3)

`epoll_cb single 1000000`, 5 runs: instructions:k, cycles:k,
L1-dcache-load-misses per iteration.

Expected: instructions:k equal within 0.2% (host: 2781-2786). Cycles and L1
misses vary about 5% run to run on the host, so a one-cacheline change is
not resolvable; this test can only catch a gross regression.

Changes the recommendation:
- cycles:k or L1 misses per iteration higher on c3 than baseline by > 5% in
  both rounds: patch 3 -> DROP.

### T2b -- patch 3, contended case (baseline, c3)

`epoll_cb multi 4 3` and `multi 12 3`, 3 runs each: cycles:k and
L1-dcache-load-misses per callback.

Expected if the patch does what it claims: lower on c3 than baseline at 4
writers. Host within-boot spread at 4 writers: cycles 3.6%, L1 misses 3.5%;
at 12 writers 20%, so use 4 writers.

Changes the recommendation:
- c3 lower than baseline in both rounds by more than the within-boot spread
  of the 3 runs: patch 3 -> RFC to VFS as prepared in `vfs/`, with the
  numbers added.
- otherwise: patch 3 -> DROP (a layout patch with no measurable effect is
  not worth reviewer time).

## Not covered

- perf c2c / precise memory sampling: not available in the guest ("no PMU
  supports the memory events"), so false sharing cannot be observed directly.
- sockmap / sunrpc UDP sockets with patch 1: the fallback is the old loop,
  unchanged code; a runtime test would need a sockmap UDP selftest in the
  guest (`tools/testing/selftests/bpf` `test_progs -t sockmap_basic`) if the
  coordinator wants one.
