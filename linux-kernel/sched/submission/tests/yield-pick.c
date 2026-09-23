// SPDX-License-Identifier: GPL-2.0
/*
 * yield-pick <cpu> <ntasks> <seconds>
 *
 * Start <ntasks> SCHED_OTHER processes pinned to <cpu>, each calling
 * sched_yield() in a loop for <seconds>. Every yield ends in a pick over
 * an rbtree of <ntasks> entities, so kernel work per context switch is
 * dominated by the switch path and pick_eevdf(), not by the tick.
 * Count it from outside with perf stat -C <cpu>.
 */
#define _GNU_SOURCE
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	int cpu, n, secs, i;
	cpu_set_t set;
	pid_t *pids;

	if (argc != 4) {
		fprintf(stderr, "usage: %s <cpu> <ntasks> <seconds>\n", argv[0]);
		return 2;
	}
	cpu = atoi(argv[1]);
	n = atoi(argv[2]);
	secs = atoi(argv[3]);
	pids = calloc(n, sizeof(*pids));
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);

	for (i = 0; i < n; i++) {
		pids[i] = fork();
		if (pids[i] == 0) {
			if (sched_setaffinity(0, sizeof(set), &set))
				_exit(1);
			for (;;)
				sched_yield();
		}
	}
	sleep(secs);
	for (i = 0; i < n; i++)
		kill(pids[i], SIGKILL);
	while (wait(NULL) > 0)
		;
	return 0;
}
