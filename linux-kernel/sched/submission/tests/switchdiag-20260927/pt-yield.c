// SPDX-License-Identifier: GPL-2.0
/*
 * pt-yield [-t] <cpu> <ntasks> <warm_ms> -- <measure command...>
 *
 * The yield-pick test from sched/submission/tests/yield-pick.c, with the
 * measurement window moved off the fork and the exit: start <ntasks>
 * SCHED_OTHER yielders pinned to <cpu>, each calling sched_yield() in a
 * loop, wait until every one of them is on <cpu> and running, let them
 * run <warm_ms> more, then run <measure command> (typically
 * "perf stat -C <cpu> ... -- sleep 1"), and kill the yielders when it
 * returns. Every switch on <cpu> during the window is a pick over an
 * rbtree of <ntasks> entities.
 *
 * Without -t the yielders are processes (each switch is also an mm
 * switch); with -t they are threads of this process (same mm).
 *
 * Exit status is that of the measure command, or 3 if the yielders could
 * not all be started.
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int cpu, pfd[2];
static cpu_set_t set;

static void *yielder(void *arg)
{
	if (sched_setaffinity(0, sizeof(set), &set))
		return NULL;
	sched_yield();
	if (sched_getcpu() != cpu)
		return NULL;
	if (write(pfd[1], "r", 1) != 1)
		return NULL;
	for (;;)
		sched_yield();
	return arg;
}

int main(int argc, char **argv)
{
	int n, warm, i, ready = 0, st, rc = 3, threads = 0;
	pid_t *pids = NULL, m;
	pthread_t *tids = NULL;
	char c;

	if (argc > 1 && !strcmp(argv[1], "-t")) {
		threads = 1;
		argv++;
		argc--;
	}
	if (argc < 6 || strcmp(argv[4], "--")) {
		fprintf(stderr, "usage: %s [-t] <cpu> <ntasks> <warm_ms> -- cmd...\n", argv[0]);
		return 2;
	}
	cpu = atoi(argv[1]);
	n = atoi(argv[2]);
	warm = atoi(argv[3]);
	if (pipe(pfd))
		return 3;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);

	if (threads) {
		tids = calloc(n, sizeof(*tids));
		if (!tids)
			return 3;
		for (i = 0; i < n; i++)
			if (pthread_create(&tids[i], NULL, yielder, NULL))
				break;
	} else {
		pids = calloc(n, sizeof(*pids));
		if (!pids)
			return 3;
		for (i = 0; i < n; i++) {
			pids[i] = fork();
			if (pids[i] < 0)
				break;
			if (pids[i] == 0) {
				close(pfd[0]);
				yielder(NULL);
				_exit(1);
			}
		}
	}
	while (ready < n && read(pfd[0], &c, 1) == 1)
		ready++;
	if (ready == n) {
		struct timespec ts = { warm / 1000, (warm % 1000) * 1000000L };

		nanosleep(&ts, NULL);
		m = fork();
		if (m == 0) {
			execvp(argv[5], &argv[5]);
			perror(argv[5]);
			_exit(127);
		}
		if (m > 0 && waitpid(m, &st, 0) == m && WIFEXITED(st))
			rc = WEXITSTATUS(st);
	} else {
		fprintf(stderr, "pt-yield: only %d of %d yielders started on cpu %d\n",
			ready, n, cpu);
	}
	if (threads) {
		/* the threads never return; end the whole process */
		fflush(NULL);
		_exit(rc);
	}
	for (i = 0; i < n; i++)
		if (pids[i] > 0)
			kill(pids[i], SIGKILL);
	while (wait(NULL) > 0)
		;
	return rc;
}
