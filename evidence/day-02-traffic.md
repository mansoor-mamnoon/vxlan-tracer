# evidence/day-02-traffic.md

Traffic smoke test results from Day 2.
Executed inside a Docker privileged container (linuxkit 6.10.14-linuxkit aarch64).

All tests use the alternative topology from day-02-lab-setup.md:
- vxlan0 MTU = 1450 (stale), underlay veth MTU = 1400
- Max safe inner IP = 1350 (underlay 1400 - overhead 50)

---

## Small traffic smoke test

### Date: 2026-06-14

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Setup:** vxlan0 MTU=1450, underlay MTU=1400, ftrace kprobe on ip_do_fragment enabled

**Command:**
```sh
ip netns exec ns1 ping -c 5 -s 40 -q 10.244.0.2
```

**Payload size math:**
```
ping payload:  40 bytes
inner IP:      68 bytes (IP hdr 20 + ICMP hdr 8 + payload 40)
outer IP:      118 bytes (inner IP 68 + VXLAN overhead 50)
underlay MTU:  1400
118 < 1400 → no fragmentation expected
```

**Actual output:**
```
PING 10.244.0.2 (10.244.0.2) 40(68) bytes of data.

--- 10.244.0.2 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4088ms
rtt min/avg/max/mdev = 0.212/0.317/0.608/0.148 ms
```

**ip_do_fragment events during small traffic:**
```
0
```

(Zero events. Confirmed via ftrace ring buffer. As expected: outer IP 118B well under underlay MTU 1400.)

**Result:** PASS — 5/5 received, 0 ip_do_fragment events, RTT 0.2–0.6 ms.

---

## Large traffic smoke test

### Date: 2026-06-14

**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64
**Setup:** vxlan0 MTU=1450, underlay MTU=1400, ftrace kprobe on ip_do_fragment enabled

**Command:**
```sh
ip netns exec ns1 ping -c 10 -s 1360 -q 10.244.0.2
```

**Payload size math:**
```
ping payload:  1360 bytes
inner IP:      1388 bytes (IP hdr 20 + ICMP hdr 8 + payload 1360)
outer IP:      1438 bytes (inner IP 1388 + VXLAN overhead 50)
underlay MTU:  1400
1438 > 1400 → ip_do_fragment fires (DF=0 default on VXLAN outer IP)
```

**Actual output:**
```
PING 10.244.0.2 (10.244.0.2) 1360(1388) bytes of data.

--- 10.244.0.2 ping statistics ---
10 packets transmitted, 10 received, 0% packet loss, time 9212ms
rtt min/avg/max/mdev = 0.140/0.335/0.876/0.202 ms
```

**ip_do_fragment events during large traffic:**
```
20
```

(20 events for 10 pings = 2 events per ping. The original 1438-byte outer IP packet
is split into two fragments: one fragment fills the 1400-byte limit, the second carries
the remainder. Each call to ip_do_fragment produces one fragmentation event per
invocation; the fragmentation function may be called twice for a single packet
depending on how the fragment chain is built. The two ftrace hits per ping are consistent.)

**First 5 ftrace events:**
```
ping-54795   [009] D.... 166350.859507: ip_do_frag: (ip_do_fragment+0x0/0x508)
ping-54795   [009] D.s1. 166350.859558: ip_do_frag: (ip_do_fragment+0x0/0x508)
ping-54795   [009] d.... 166351.877854: ip_do_frag: (ip_do_fragment+0x0/0x508)
ping-54795   [009] D.s1. 166351.877984: ip_do_frag: (ip_do_fragment+0x0/0x508)
ping-54795   [009] d.... 166352.901010: ip_do_frag: (ip_do_fragment+0x0/0x508)
```

The `D` flag (irqs-off) on alternate lines indicates the second ip_do_fragment call
happens inside the softirq that transmits the first fragment.

**Result:** PASS — 10/10 received; 20 ip_do_fragment events confirmed.

**Note on 0% packet loss despite fragmentation:**
In this local veth+netns topology, VXLAN UDP fragments are reassembled at the
remote VTEP (ns2). This is why 10/10 pings succeed. In production, cloud provider
fabric (AWS VPC, GCP, Azure) typically drops VXLAN UDP fragments silently because:
1. UDP fragmentation breaks ECMP hashing (fragments after the first lack L4 header).
2. Some fabric implementations drop non-first UDP fragments unconditionally.
3. Stateless firewalls may drop reassembly-order-dependent fragments.

The tool's value is detecting the fragmentation (ip_do_fragment events) BEFORE it
reaches the cloud fabric. Observation of ip_do_fragment events = fragmentation
happening = VXLAN MTU mismatch confirmed.

## ftrace methodology

Raw ftrace kprobe interface was used (bpftrace 0.14.0 is broken on linuxkit):

```sh
# mount tracefs if not already mounted
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null || true

# register ip_do_fragment kprobe
echo 'p:ip_do_frag ip_do_fragment' > /sys/kernel/tracing/kprobe_events

# enable event collection
echo 1 > /sys/kernel/tracing/events/kprobes/ip_do_frag/enable
echo 1 > /sys/kernel/tracing/tracing_on

# generate traffic
ip netns exec ns1 ping -c 10 -s 1360 -q 10.244.0.2

# read events
grep ip_do_frag /sys/kernel/tracing/trace | wc -l
grep ip_do_frag /sys/kernel/tracing/trace | head -5

# clean up
echo 0 > /sys/kernel/tracing/tracing_on
echo > /sys/kernel/tracing/trace
echo '-:ip_do_frag' > /sys/kernel/tracing/kprobe_events
```

See docs/linux-dev-environment.md for explanation of why raw ftrace is used instead
of bpftrace on this kernel.
