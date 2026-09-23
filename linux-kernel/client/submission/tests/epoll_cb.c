// SPDX-License-Identifier: GPL-2.0
/*
 * epoll_cb - exercise ep_poll_callback() and epoll_wait() on one
 * struct eventpoll, for comparing field layouts with perf stat.
 *
 *   epoll_cb single <iters>
 *	Uncontended: one thread, one eventfd in one epoll set.
 *	write(efd) -> ep_poll_callback(); epoll_wait(); read(efd).
 *	Prints iterations; divide perf counters by it.
 *
 *   epoll_cb multi <writers> <secs>
 *	<writers> threads, each on its own CPU and its own eventfd, all
 *	in one epoll set, write continuously; one thread drains with
 *	epoll_wait(). ep_poll_callback() then runs on the writer CPUs
 *	while the drainer runs ep_poll()/ep_send_events() on another.
 *	Prints callbacks issued (writes) and events harvested.
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <time.h>
#include <unistd.h>

static atomic_int stop;
static atomic_long writes;

static void pin(int cpu)
{
	cpu_set_t s;

	CPU_ZERO(&s);
	CPU_SET(cpu % sysconf(_SC_NPROCESSORS_ONLN), &s);
	sched_setaffinity(0, sizeof(s), &s);
}

static void *writer(void *arg)
{
	int efd = (int)(long)arg & 0xffff;
	int cpu = (int)((long)arg >> 16);
	uint64_t one = 1;
	long n = 0;

	pin(cpu);
	while (!atomic_load_explicit(&stop, memory_order_relaxed)) {
		if (write(efd, &one, sizeof(one)) == sizeof(one))
			n++;
	}
	atomic_fetch_add(&writes, n);
	return NULL;
}

int main(int argc, char **argv)
{
	struct epoll_event e = { .events = EPOLLIN }, evs[64];
	int ep = epoll_create1(0);
	uint64_t v;

	if (argc < 3) {
		fprintf(stderr, "usage: %s single <iters> | multi <writers> <secs>\n",
			argv[0]);
		return 2;
	}

	if (!strcmp(argv[1], "single")) {
		long it = atol(argv[2]);
		int efd = eventfd(0, EFD_NONBLOCK);

		pin(1);
		e.data.fd = efd;
		epoll_ctl(ep, EPOLL_CTL_ADD, efd, &e);
		v = 1;
		for (long i = 0; i < it; i++) {
			if (write(efd, &v, sizeof(v)) != sizeof(v))
				return 1;
			if (epoll_wait(ep, evs, 64, -1) != 1)
				return 1;
			if (read(efd, &v, sizeof(v)) != sizeof(v))
				return 1;
		}
		printf("single iters=%ld\n", it);
		return 0;
	}

	{
		int nw = atoi(argv[2]), secs = atoi(argv[3]);
		pthread_t *t = calloc(nw, sizeof(*t));
		int *efd = calloc(nw, sizeof(*efd));
		long events = 0, waits = 0;
		struct timespec t0, t1;

		pin(0);
		for (int i = 0; i < nw; i++) {
			efd[i] = eventfd(0, EFD_NONBLOCK);
			e.data.fd = efd[i];
			epoll_ctl(ep, EPOLL_CTL_ADD, efd[i], &e);
		}
		for (int i = 0; i < nw; i++)
			pthread_create(&t[i], NULL, writer,
				       (void *)(long)(efd[i] | ((i + 1) << 16)));
		clock_gettime(CLOCK_MONOTONIC, &t0);
		do {
			int n = epoll_wait(ep, evs, 64, 100);

			if (n > 0) {
				waits++;
				events += n;
				for (int i = 0; i < n; i++)
					if (read(evs[i].data.fd, &v, sizeof(v)) < 0)
						break;
			}
			clock_gettime(CLOCK_MONOTONIC, &t1);
		} while (t1.tv_sec - t0.tv_sec < secs);
		atomic_store(&stop, 1);
		for (int i = 0; i < nw; i++)
			pthread_join(t[i], NULL);
		printf("multi writers=%d callbacks=%ld events=%ld epoll_waits=%ld\n",
		       nw, atomic_load(&writes), events, waits);
	}
	return 0;
}
