#!/bin/bash
# spikes/day04_blackhole_test.sh - run inside Docker --privileged container
set -e
BPFTOOL=/usr/lib/linux-tools-5.15.0-181/bpftool
cd /work

echo "=== Mount tracefs ==="
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null || true
TRACEFS=/sys/kernel/tracing
[ -d "$TRACEFS" ] && echo "tracefs: $TRACEFS" || { echo "no tracefs"; exit 1; }

echo "=== Compile tc_egress_vxlan0 ==="
clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/tc_egress_vxlan0.bpf.c -o /tmp/tc_egress_vxlan0.bpf.o
echo "compile exit: $?"

echo "=== Setup stale-MTU topology ==="
ip netns add ns1; ip netns add ns2
ip link add veth1 type veth peer name veth2
ip link set veth1 netns ns1
ip link set veth2 netns ns2
ip netns exec ns1 ip addr add 192.168.100.1/24 dev veth1
ip netns exec ns2 ip addr add 192.168.100.2/24 dev veth2
ip netns exec ns1 ip link set veth1 up
ip netns exec ns2 ip link set veth2 up
ip netns exec ns1 ip link set lo up
ip netns exec ns2 ip link set lo up
ip netns exec ns1 ip link add vxlan0 type vxlan id 42 dstport 4789 \
  remote 192.168.100.2 local 192.168.100.1 dev veth1
ip netns exec ns1 ip addr add 10.0.0.1/24 dev vxlan0
ip netns exec ns1 ip link set vxlan0 up
ip netns exec ns2 ip link add vxlan0 type vxlan id 42 dstport 4789 \
  remote 192.168.100.1 local 192.168.100.2 dev veth2
ip netns exec ns2 ip addr add 10.0.0.2/24 dev vxlan0
ip netns exec ns2 ip link set vxlan0 up
# Reduce underlay MTU after vxlan0 creation (stale MTU scenario)
ip netns exec ns1 ip link set veth1 mtu 1400
ip netns exec ns2 ip link set veth2 mtu 1400
echo "veth1 MTU (underlay): $(ip netns exec ns1 ip link show veth1 | awk '/mtu/{print $5}')"
echo "vxlan0 MTU (stale):   $(ip netns exec ns1 ip link show vxlan0 | awk '/mtu/{print $5}')"

echo "=== Attach tc_egress_vxlan0 to vxlan0 egress ==="
ip netns exec ns1 tc qdisc add dev vxlan0 clsact
ip netns exec ns1 tc filter add dev vxlan0 egress bpf da \
  obj /tmp/tc_egress_vxlan0.bpf.o sec tc
ip netns exec ns1 tc filter show dev vxlan0 egress

echo "=== Enable ip_do_fragment kprobe via ftrace ==="
echo 0 > $TRACEFS/tracing_on
echo "" > $TRACEFS/trace
# Use unique probe name to avoid conflict with pre-existing probes in this container
PROBE=vxt_ip_do_frag
echo "-:$PROBE" >> $TRACEFS/kprobe_events 2>/dev/null || true
echo "p:$PROBE ip_do_fragment" >> $TRACEFS/kprobe_events
echo 1 > $TRACEFS/events/kprobes/$PROBE/enable
echo 1 > $TRACEFS/tracing_on
echo "ftrace probe $PROBE enabled"

echo "=== flow_state BEFORE traffic ==="
FLOW_ID=$($BPFTOOL map list | awk '/flow_state/{print $1}' | tr -d ':')
echo "flow_state map id: $FLOW_ID"
$BPFTOOL map dump id "$FLOW_ID"

echo "=== Small traffic: 3x ping -s 56 (inner 84B, outer 134B < 1400 MTU) ==="
ip netns exec ns1 ping -c 3 -s 56 -W 2 10.0.0.2

echo "=== Large traffic: 3x ping -s 1360 (inner 1388B, outer 1438B > 1400 MTU) ==="
ip netns exec ns1 ping -c 3 -s 1360 -W 2 10.0.0.2 || true

echo "=== ip_do_fragment events ==="
echo 0 > $TRACEFS/tracing_on
FRAG_COUNT=$(grep -c $PROBE $TRACEFS/trace 2>/dev/null || echo 0)
echo "ip_do_fragment fires: $FRAG_COUNT"
grep $PROBE $TRACEFS/trace | head -3 || true

echo "=== flow_state AFTER traffic ==="
$BPFTOOL map dump id "$FLOW_ID"

echo "=== MTU arithmetic ==="
echo "  inner IP 1388 + 50 VXLAN overhead = outer IP 1438"
echo "  underlay MTU = 1400, excess = 38 bytes"
echo "  ip_do_fragment fires for each oversized outer packet (DF=0)"
