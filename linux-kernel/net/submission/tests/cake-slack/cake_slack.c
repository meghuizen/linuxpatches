// SPDX-License-Identifier: GPL-2.0
/*
 * cake_slack: set or read TCA_CAKE_TIMER_SLACK on an existing root cake
 * qdisc, without an iproute2 that knows the attribute.
 *
 *   cake_slack <ifname>            print the slack from a qdisc dump
 *   cake_slack <ifname> <ns>       change the slack (RTM_NEWQDISC, no create)
 *
 * Exit status 0 on success.  An unpatched kernel accepts and ignores the
 * attribute on change (cake parses its options leniently), so always read
 * the value back: on an unpatched kernel the dump does not contain it.
 */
#include <errno.h>
#include <linux/netlink.h>
#include <linux/pkt_sched.h>
#include <linux/rtnetlink.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define TCA_CAKE_TIMER_SLACK_ID	(TCA_CAKE_FWMARK + 1)

struct req {
	struct nlmsghdr n;
	struct tcmsg t;
	char buf[256];
};

static struct rtattr *addattr(struct nlmsghdr *n, int type, const void *d,
			      int len)
{
	struct rtattr *rta = (void *)((char *)n + NLMSG_ALIGN(n->nlmsg_len));

	rta->rta_type = type;
	rta->rta_len = RTA_LENGTH(len);
	if (len)
		memcpy(RTA_DATA(rta), d, len);
	n->nlmsg_len = NLMSG_ALIGN(n->nlmsg_len) + RTA_ALIGN(rta->rta_len);
	return rta;
}

static int talk(int fd, struct nlmsghdr *n, int ifindex, int dump)
{
	char buf[16384];
	int len;

	if (send(fd, n, n->nlmsg_len, 0) < 0)
		return -errno;
	for (;;) {
		struct nlmsghdr *h;

		len = recv(fd, buf, sizeof(buf), 0);
		if (len < 0)
			return -errno;
		for (h = (void *)buf; NLMSG_OK(h, len); h = NLMSG_NEXT(h, len)) {
			struct tcmsg *t = NLMSG_DATA(h);
			struct rtattr *a, *o;
			int al, ol;

			if (h->nlmsg_type == NLMSG_DONE)
				return dump ? 1 : 0;
			if (h->nlmsg_type == NLMSG_ERROR) {
				struct nlmsgerr *e = NLMSG_DATA(h);

				return e->error;
			}
			if (!dump || h->nlmsg_type != RTM_NEWQDISC ||
			    t->tcm_ifindex != ifindex || t->tcm_parent != TC_H_ROOT)
				continue;
			al = h->nlmsg_len - NLMSG_LENGTH(sizeof(*t));
			for (a = (void *)((char *)t + NLMSG_ALIGN(sizeof(*t)));
			     RTA_OK(a, al); a = RTA_NEXT(a, al)) {
				if (a->rta_type != TCA_OPTIONS)
					continue;
				ol = RTA_PAYLOAD(a);
				for (o = RTA_DATA(a); RTA_OK(o, ol);
				     o = RTA_NEXT(o, ol))
					if (o->rta_type == TCA_CAKE_TIMER_SLACK_ID) {
						printf("timer_slack=%u\n",
						       *(unsigned int *)RTA_DATA(o));
						return 0;
					}
			}
		}
	}
}

int main(int argc, char **argv)
{
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	struct req r = { 0 };
	int fd, ifindex, err;
	struct rtattr *opt;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <ifname> [slack_ns]\n", argv[0]);
		return 2;
	}
	ifindex = if_nametoindex(argv[1]);
	if (!ifindex) {
		perror(argv[1]);
		return 1;
	}
	fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
	if (fd < 0 || bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		perror("netlink");
		return 1;
	}

	r.n.nlmsg_len = NLMSG_LENGTH(sizeof(struct tcmsg));
	r.t.tcm_family = AF_UNSPEC;
	if (argc > 2) {
		unsigned int slack = strtoul(argv[2], NULL, 0);

		r.n.nlmsg_type = RTM_NEWQDISC;
		r.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
		r.t.tcm_ifindex = ifindex;
		r.t.tcm_parent = TC_H_ROOT;
		addattr(&r.n, TCA_KIND, "cake", 5);
		opt = addattr(&r.n, TCA_OPTIONS, NULL, 0);
		addattr(&r.n, TCA_CAKE_TIMER_SLACK_ID, &slack, sizeof(slack));
		opt->rta_len = (char *)&r.n + r.n.nlmsg_len - (char *)opt;
		err = talk(fd, &r.n, ifindex, 0);
		if (err) {
			fprintf(stderr, "change: %s\n", strerror(-err));
			return 1;
		}
		memset(&r, 0, sizeof(r));
		r.n.nlmsg_len = NLMSG_LENGTH(sizeof(struct tcmsg));
		r.t.tcm_family = AF_UNSPEC;
	}
	r.n.nlmsg_type = RTM_GETQDISC;
	r.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
	err = talk(fd, &r.n, ifindex, 1);
	if (err) {
		fprintf(stderr, err > 0 ? "no TCA_CAKE_TIMER_SLACK in dump\n" :
			"dump failed\n");
		return 1;
	}
	return 0;
}
