// SPDX-License-Identifier: GPL-2.0
/*
 * udp_batch_wake - several senders into one UDP socket, so that
 * __udp_enqueue_schedule_skb() drains a per-NUMA llist with nb > 1.
 *
 *   udp_batch_wake epoll <senders> <seconds>
 *	one receiver thread, one socket, drained from epoll_wait()
 *	(a non-exclusive waiter). Prints datagrams, epoll_wait returns,
 *	dgram/wait and UDP RcvbufErrors over the run.
 *
 *   udp_batch_wake block <senders> <receivers> <seconds>
 *	<receivers> threads blocked in recv() on the same socket
 *	(exclusive waiters). Prints what each receiver got, and the number
 *	of recv() calls that returned data only after sleeping for at
 *	least the SO_RCVTIMEO period: that is a wakeup that did not come.
 *	Must be 0.
 *
 * Senders are pinned to CPUs 1..senders, receivers to the CPUs after
 * them. Loopback, so softirq delivery runs on each sender's CPU and the
 * enqueues into the one socket happen concurrently.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define PORT		39871
#define RCVTIMEO_MS	200

static atomic_int stop;
static atomic_long sent;
static int rxfd;

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void pin(int cpu)
{
	cpu_set_t s;

	CPU_ZERO(&s);
	CPU_SET(cpu % sysconf(_SC_NPROCESSORS_ONLN), &s);
	sched_setaffinity(0, sizeof(s), &s);
}

static long rcvbuf_errors(void)
{
	char line[1024], hdr[1024];
	FILE *f = fopen("/proc/net/snmp", "r");
	long v = -1;

	if (!f)
		return -1;
	while (fgets(hdr, sizeof(hdr), f) && fgets(line, sizeof(line), f)) {
		char *hs, *ls, *h, *l;
		int i = 0;

		if (strncmp(hdr, "Udp:", 4))
			continue;
		h = strtok_r(hdr, " \n", &hs);
		l = strtok_r(line, " \n", &ls);
		while (h && l) {
			if (!strcmp(h, "RcvbufErrors"))
				v = atol(l);
			h = strtok_r(NULL, " \n", &hs);
			l = strtok_r(NULL, " \n", &ls);
			i++;
		}
		break;
	}
	fclose(f);
	return v;
}

static void *sender(void *arg)
{
	struct sockaddr_in d = { .sin_family = AF_INET,
				 .sin_port = htons(PORT) };
	char buf[64];
	long n = 0;
	int fd;

	pin((int)(long)arg);
	memset(buf, 0x5a, sizeof(buf));
	inet_pton(AF_INET, "127.0.0.1", &d.sin_addr);
	fd = socket(AF_INET, SOCK_DGRAM, 0);
	connect(fd, (struct sockaddr *)&d, sizeof(d));
	while (!atomic_load_explicit(&stop, memory_order_relaxed))
		if (send(fd, buf, sizeof(buf), 0) > 0)
			n++;
	atomic_fetch_add(&sent, n);
	close(fd);
	return NULL;
}

struct rx {
	int cpu;
	long got;
	long late;
	pthread_t t;
};

static void *blocking_receiver(void *arg)
{
	struct rx *r = arg;
	char buf[64];

	pin(r->cpu);
	for (;;) {
		double t0 = now();
		ssize_t n = recv(rxfd, buf, sizeof(buf), 0);
		double dt = now() - t0;

		if (n > 0) {
			r->got++;
			if (dt * 1000 >= RCVTIMEO_MS * 0.9)
				r->late++;
			continue;
		}
		if (atomic_load(&stop) == 2)
			break;
	}
	return NULL;
}

int main(int argc, char **argv)
{
	struct sockaddr_in a = { .sin_family = AF_INET,
				 .sin_port = htons(PORT) };
	int senders, receivers = 0, secs, i;
	struct timeval tv = { 0, RCVTIMEO_MS * 1000 };
	pthread_t *st;
	long e0, e1;
	double t0, t1;
	int rcvbuf = 4 << 20;

	if (argc < 4 || (!strcmp(argv[1], "block") && argc < 5)) {
		fprintf(stderr, "usage: %s epoll <senders> <secs>\n"
				"       %s block <senders> <receivers> <secs>\n",
			argv[0], argv[0]);
		return 2;
	}
	senders = atoi(argv[2]);
	if (!strcmp(argv[1], "block")) {
		receivers = atoi(argv[3]);
		secs = atoi(argv[4]);
	} else {
		secs = atoi(argv[3]);
	}

	inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
	rxfd = socket(AF_INET, SOCK_DGRAM, 0);
	setsockopt(rxfd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
	setsockopt(rxfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	if (bind(rxfd, (struct sockaddr *)&a, sizeof(a)) < 0) {
		perror("bind");
		return 1;
	}

	st = calloc(senders, sizeof(*st));
	e0 = rcvbuf_errors();

	if (!strcmp(argv[1], "epoll")) {
		struct epoll_event e = { .events = EPOLLIN }, evs[8];
		int ep = epoll_create1(0);
		long got = 0, waits = 0;
		char buf[64];

		pin(senders + 1);
		epoll_ctl(ep, EPOLL_CTL_ADD, rxfd, &e);
		for (i = 0; i < senders; i++)
			pthread_create(&st[i], NULL, sender, (void *)(long)(i + 1));
		t0 = now();
		while (now() - t0 < secs) {
			int n = epoll_wait(ep, evs, 8, 100);

			if (n <= 0)
				continue;
			waits++;
			/* bounded, like an event loop that serves other fds */
			for (int k = 0; k < 64; k++) {
				if (recv(rxfd, buf, sizeof(buf), MSG_DONTWAIT) <= 0)
					break;
				got++;
			}
		}
		atomic_store(&stop, 1);
		for (i = 0; i < senders; i++)
			pthread_join(st[i], NULL);
		while (recv(rxfd, buf, sizeof(buf), MSG_DONTWAIT) > 0)
			got++;
		t1 = now();
		e1 = rcvbuf_errors();
		printf("epoll senders=%d secs=%.1f sent=%ld got=%ld rcvbuf_errors=%ld "
		       "epoll_waits=%ld dgram/wait=%.1f\n",
		       senders, t1 - t0, atomic_load(&sent), got, e1 - e0,
		       waits, waits ? (double)got / waits : 0.0);
		return 0;
	}

	{
		struct rx *r = calloc(receivers, sizeof(*r));
		long got = 0, late = 0;

		for (i = 0; i < receivers; i++) {
			r[i].cpu = senders + 1 + i;
			pthread_create(&r[i].t, NULL, blocking_receiver, &r[i]);
		}
		usleep(100000);
		for (i = 0; i < senders; i++)
			pthread_create(&st[i], NULL, sender, (void *)(long)(i + 1));
		t0 = now();
		sleep(secs);
		atomic_store(&stop, 1);
		for (i = 0; i < senders; i++)
			pthread_join(st[i], NULL);
		/* let the receivers drain, then time out */
		usleep(3 * RCVTIMEO_MS * 1000);
		atomic_store(&stop, 2);
		for (i = 0; i < receivers; i++) {
			pthread_join(r[i].t, NULL);
			got += r[i].got;
			late += r[i].late;
		}
		t1 = now();
		e1 = rcvbuf_errors();
		printf("block senders=%d receivers=%d secs=%.1f sent=%ld got=%ld "
		       "rcvbuf_errors=%ld unaccounted=%ld late_wakeups=%ld per_rx=",
		       senders, receivers, t1 - t0, atomic_load(&sent), got,
		       e1 - e0, atomic_load(&sent) - got - (e1 - e0), late);
		for (i = 0; i < receivers; i++)
			printf("%s%ld", i ? "," : "", r[i].got);
		printf("\n");
	}
	return 0;
}
