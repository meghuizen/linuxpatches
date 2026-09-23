#!/bin/bash
# build_step.sh <label>: build the net series' touched objects in the worktree and save them
S=/tmp/claude-0/-usr-src-linuxpatches/9691c9a3-b70d-4804-a7be-7a4acdddcb51/scratchpad
cd /usr/src/sub-net
OBJS="net/sched/sch_cake.o net/netfilter/nf_flow_table_core.o net/netfilter/nf_conntrack_core.o net/core/gro.o net/bridge/br_arp_nd_proxy.o net/bridge/br_if.o net/bridge/br_input.o net/netfilter/nf_conntrack_extend.o net/netfilter/nf_conntrack_standalone.o net/netfilter/nf_conntrack_netlink.o"
nice -n 19 make O=build -j4 W=1 $OBJS > $S/build-$1.log 2>&1
rc=$?
grep -E "warning:|error:" $S/build-$1.log
[ $rc -ne 0 ] && { echo "BUILD FAILED $1"; exit 1; }
mkdir -p $S/objs/$1
for o in $OBJS; do cp build/$o $S/objs/$1/; done
echo "built $1 at $(git log --oneline -1) (no warnings above = clean W=1)"
