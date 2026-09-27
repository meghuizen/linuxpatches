# Context switch diagnostics, 2026-09-27 (one baseline boot)

Where a context switch spends instructions and cache misses. v7.3-rc3
(518e5b794c06), x86-64 guest (qemu/KVM nested in Hyper-V, 16 vCPUs),
harness section `switchdiag` in patchtest.sh, helper `pt-yield.c` (here).
Yielders pinned to one CPU, calling sched_yield() in a loop, as processes
(mm switch on every switch) or as threads of one process (same mm).
N = 1 is the syscall with no other runnable task: no switch happens.
Per-switch values are medians of 3 reps; N = 1 rows are per sched_yield
call. Counted with perf stat -C on the yield CPU; the
syscalls:sys_enter_sched_yield tracepoint was enabled for the call count,
which adds about 280 kernel instructions per syscall to every row
(campaign value for yield.n2 without it: 3450).

Environment:

    INFO kernel 7.3.0-rc3-kbench-baseline-00824-g518e5b794c06
    INFO cmdline root=/dev/vda rw console=ttyS0,115200 earlyprintk=serial,ttyS0,115200 nokaslr no_timer_check mitigations=off audit=0 selinux=0 apparmor=0 rcu_nocbs=1-15 irqaffinity=0 tsc=reliable clocksource=tsc kbench.auto=1 kbench.patchtest=1 kbench.ptonly=switchdiag
    INFO cpu-flags pge invpcid
    INFO meltdown Not affected
    INFO spectre_v2 Vulnerable; IBPB: disabled; STIBP: disabled; PBRSB-eIBRS: Not affected; BHI: Not affected

Note: this guest exposes invpcid but not pcid, so the kernel cannot use
address-space IDs and every process switch flushes the whole TLB. PTI
and the Spectre-v2 mitigations are off in the guest.

## Per switch (N >= 2) or per call (N = 1)

| mode.N | kinsn | kcyc | l1miss | dTLB | iTLB | L2+ miss | branch-misses | L1-icache | switches/s |
|---|---|---|---|---|---|---|---|---|---|
| proc.n1 | 1764.7 | 682.778 | 0.208026 | 0.00468656 | 1.52443 | 0.172729 | 1.39201 | 0.0461788 | - |
| proc.n2 | 3731.62 | 2366.77 | 6.14393 | 0.0544026 | 3.07947 | 1.61611 | 1.93495 | 0.968397 | 1268424 |
| proc.n16 | 3991.55 | 2616.44 | 115.393 | 0.322326 | 0.141626 | 1.64178 | 2.24624 | 1.33427 | 1345941 |
| proc.n128 | 4303.22 | 3271.63 | 134.671 | 0.517731 | 9.48936 | 61.4152 | 3.69208 | 1.62108 | 407896 |
| proc.n512 | 4449.5 | 3998.34 | 153.144 | 2.19046 | 1.65226 | 93.4984 | 3.41016 | 1.46148 | 640735 |
| thread.n1 | 1764.69 | 686.507 | 0.296767 | 0.00450943 | 1.33052 | 0.161777 | 1.34915 | 0.0431973 | - |
| thread.n2 | 3622.79 | 2150.81 | 2.28803 | 0.0144942 | 0.686087 | 0.582913 | 1.60399 | 1.02103 | 1819328 |
| thread.n16 | 3907.23 | 2507.08 | 95.2787 | 0.306277 | 4.21162 | 2.0032 | 2.78173 | 1.31391 | 1391737 |
| thread.n128 | 4589.6 | 4256.89 | 115.32 | 0.845112 | 2.24776 | 60.3991 | 7.63244 | 3.18872 | 66057 |
| thread.n512 | 4837.26 | 5168.83 | 129.544 | 2.43206 | 5.13784 | 102.879 | 11.826 | 5.42013 | 52238 |

Anomaly: in thread mode at N >= 128 the switch rate collapses (1.39M/s at
N = 16 to 66k/s at N = 128) while kernel cycles per switch rise only 30%;
about 90% of wall time on that CPU is then outside the counted kernel
cycles. Not explained by these counters; the per-switch values are not
affected (yields per switch stay 1.000).

## Profiles

`prof-<event>-<mode>-n<N>.txt`: perf record on the yield CPU, cycles:k and
L1-dcache-load-misses:k, reported by kernel symbol (--no-children).
