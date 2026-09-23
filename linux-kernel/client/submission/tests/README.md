# Tests for the client series

Host: AMD Ryzen 9 8940HX, WSL2 kernel 6.18.40.1-microsoft-standard-WSL2
(has the per-NUMA UDP producer queues from b650bf0977d3; none of the patches
here). Host runs validate the test programs; they say nothing about the
patched kernel.

| file | what |
|---|---|
| udp_batch_wake.c | N senders into one UDP socket over loopback; `epoll` mode (one epoll consumer) or `block` mode (threads blocked in recv(), counts late wakeups and lost datagrams) |
| udp_batch_wake.bt | bpftrace: per `__udp_enqueue_schedule_skb()` call, how many `sock_def_readable()` / `ep_poll_callback()` calls it made (= nb on an unpatched kernel) |
| run-host.sh | what was run on the host for patch 1 (1, 2, 6 senders + block mode) |
| host-results.txt, host-results-12-24.txt, bt.*.out | raw output of those runs (12 and 24 senders run by hand, same commands) |
| nb-summary.txt | table derived from bt.*.out (in the patch 1 changelog) |
| epoll_cb.c | eventfd + epoll: `single` (uncontended, one pinned thread) and `multi` (N writer threads, one epoll_wait thread) |
| run-guest.sh | the guest script for TESTS-TO-RUN.md (T1a-c, T2a-b) |
| host-run-guest-validation.txt | run-guest.sh on the host: shows run-to-run spread; T1a is empty because the host denies the function profiler |
| pahole-eventpoll.txt | struct eventpoll before/after (patch 2) |
| sock_def_readable-disasm.txt | sock_def_readable() before/after patch 1 |
| bisect-build.txt | W=1 object build at each commit of the branch |

Commands:

    gcc -O2 -Wall -pthread -o udp_batch_wake udp_batch_wake.c
    ./run-host.sh > host-results.txt 2>&1
    bpftrace udp_batch_wake.bt &   ./udp_batch_wake epoll 12 3   # same for 24
    gcc -O2 -Wall -pthread -o epoll_cb epoll_cb.c
    ./run-guest.sh > host-run-guest-validation.txt 2>&1
    pahole -C eventpoll build/fs/eventpoll.o      # base and patched
    nice -n 19 make O=build -j4 W=1 <objects>     # at each commit

Host repeatability seen in host-run-guest-validation.txt:
- udp epoll, 1 sender, instructions:k per datagram: 11849-11893 (0.4%)
- udp epoll, 6 senders: 12863-14639 (13%, varies with drops) -- not usable
- epoll_cb single, instructions:k per iteration: 2781-2786 (0.2%);
  cycles:k 6937-7307 (5%); L1-dcache-load-misses 135-142 (5%)
- epoll_cb multi 4 writers, per callback: cycles:k 3712-3845 (3.6%),
  L1 misses 67.2-69.6 (3.5%); 12 writers: cycles 20% -- not usable
