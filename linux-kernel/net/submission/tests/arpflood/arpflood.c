// SPDX-License-Identifier: GPL-2.0
/*
 * arpflood: send N broadcast ARP requests out of one interface through an
 * AF_PACKET socket, as fast as possible, from the calling CPU.
 *
 *   arpflood <ifname> <count> <target-prefix, e.g. 10.200.0> [nr_targets]
 *
 * Target addresses cycle through <prefix>.1 .. <prefix>.<nr_targets>
 * (default 200).  Used to measure the per-frame cost of the bridge ARP
 * input path (br_do_proxy_suppress_arp()) with perf stat on the sending
 * task: frames sent into a veth whose peer is a bridge port are received
 * by the bridge in the sender's softirq context.
 */
#include <arpa/inet.h>
#include <linux/if_packet.h>
#include <net/ethernet.h>
#include <net/if.h>
#include <netinet/if_ether.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	unsigned char frame[ETH_ZLEN] = { 0 };
	struct ether_header *eh = (void *)frame;
	struct ether_arp *ea = (void *)(frame + sizeof(*eh));
	struct sockaddr_ll sll = { 0 };
	unsigned int ntgt = 200, a, b, c;
	unsigned char mac[ETH_ALEN];
	struct ifreq ifr = { 0 };
	long count, i, sent = 0;
	int fd;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <ifname> <count> <a.b.c> [nr_targets]\n",
			argv[0]);
		return 2;
	}
	count = atol(argv[2]);
	if (sscanf(argv[3], "%u.%u.%u", &a, &b, &c) != 3)
		return 2;
	if (argc > 4)
		ntgt = atoi(argv[4]);
	if (ntgt < 1 || ntgt > 254)
		ntgt = 200;

	fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ARP));
	if (fd < 0) {
		perror("socket");
		return 1;
	}
	strncpy(ifr.ifr_name, argv[1], IFNAMSIZ - 1);
	if (ioctl(fd, SIOCGIFHWADDR, &ifr) < 0) {
		perror("SIOCGIFHWADDR");
		return 1;
	}
	memcpy(mac, ifr.ifr_hwaddr.sa_data, ETH_ALEN);

	sll.sll_family = AF_PACKET;
	sll.sll_protocol = htons(ETH_P_ARP);
	sll.sll_ifindex = if_nametoindex(argv[1]);
	sll.sll_halen = ETH_ALEN;
	memset(sll.sll_addr, 0xff, ETH_ALEN);

	memset(eh->ether_dhost, 0xff, ETH_ALEN);
	memcpy(eh->ether_shost, mac, ETH_ALEN);
	eh->ether_type = htons(ETH_P_ARP);
	ea->arp_hrd = htons(ARPHRD_ETHER);
	ea->arp_pro = htons(ETH_P_IP);
	ea->arp_hln = ETH_ALEN;
	ea->arp_pln = 4;
	ea->arp_op = htons(ARPOP_REQUEST);
	memcpy(ea->arp_sha, mac, ETH_ALEN);
	ea->arp_spa[0] = a; ea->arp_spa[1] = b; ea->arp_spa[2] = c;
	ea->arp_spa[3] = 253;	/* not the bridge's own .254 */
	ea->arp_tpa[0] = a; ea->arp_tpa[1] = b; ea->arp_tpa[2] = c;

	for (i = 0; i < count; i++) {
		ea->arp_tpa[3] = 1 + i % ntgt;
		if (sendto(fd, frame, sizeof(frame), 0,
			   (struct sockaddr *)&sll, sizeof(sll)) == sizeof(frame))
			sent++;
	}
	printf("sent=%ld of %ld\n", sent, count);
	return sent == count ? 0 : 1;
}
