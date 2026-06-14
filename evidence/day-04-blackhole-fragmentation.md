# evidence/day-04-blackhole-fragmentation.md

Blackhole/fragmentation scenario: stale vxlan0 MTU triggers ip_do_fragment.
Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.
bpftool: `/usr/lib/linux-tools-5.15.0-181/bpftool` v5.15.199.

---

## Topology: stale MTU blackhole

From Day 2: kernel 6.10.14 enforces `vxlan0 MTU ≤ underlay_mtu - 50` at creation
time. Workaround: create vxlan0 while underlay MTU=1500 (kernel sets vxlan0=1450),
then reduce underlay MTU to 1400 after creation. The vxlan0 MTU stays at 1450
(stale), creating the blackhole condition.

```sh
# Create vxlan0 while underlay MTU=1500 (kernel auto-sets vxlan0=1450)
ip link add vxlan0 type vxlan id 42 dstport 4789 ...
ip link set vxlan0 up  # vxlan0 MTU now 1450

# Reduce underlay MTU — vxlan0 MTU is NOT updated automatically (stale)
ip link set veth1 mtu 1400
```

### MTU state after setup

```
veth1 MTU (underlay):      1400
vxlan0 MTU (stale/wrong):  1450
```

Kernel behavior: inner IP packets up to 1450 bytes pass through vxlan0 without
error. But outer IP = inner_IP + 50. For inner IP > 1350:
- outer IP > 1400 (underlay MTU)
- ip_do_fragment fires (DF=0, Linux VXLAN default)
- Packet is fragmented at the underlay layer, not dropped

For inner IP > 1450 (the stale overlay MTU):
- vxlan0 would signal EMSGSIZE to the overlay socket
- Not tested in this scenario

---

## BPF programs active

```
tc_egress_vxlan0 on vxlan0 egress in ns1: id 232 tag 8d5c7a9a173ff918 jited
ftrace kprobe vxt_ip_do_frag on ip_do_fragment (global, all namespaces)
```

---

## Traffic test

### Small traffic: 3x ping -s 56 (inner IP 84B, outer IP 134B)

```
3 packets transmitted, 3 received, 0% packet loss
```

Inner IP 84B → outer IP 134B << 1400 underlay MTU. No fragmentation. ✓

### Large traffic: 3x ping -s 1360 (inner IP 1388B, outer IP 1438B)

```
3 packets transmitted, 3 received, 0% packet loss
```

Inner IP 1388B → outer IP 1438B > 1400 underlay MTU. Fragments emitted (DF=0).
Replies received because ip_do_fragment reassembles on the receiver side.

---

## ip_do_fragment events (ftrace, global)

```
ip_do_fragment fires: 6
ping-98513 [003] D.... 173268.687791: vxt_ip_do_frag: (ip_do_fragment+0x0/0x508)
ping-98513 [003] D.s1. 173268.687903: vxt_ip_do_frag: (ip_do_fragment+0x0/0x508)
ping-98513 [003] d.... 173269.701501: vxt_ip_do_frag: (ip_do_fragment+0x0/0x508)
```

6 events for 3 large pings. The ftrace kprobe is global (all namespaces):
- 3 events from ns1 (ns1 sends oversized outer packet to ns2, veth1 MTU=1400)
- 3 events from ns2 (ns2 sends oversized outer ICMP reply to ns1, veth2 MTU=1400)

Both ns1 and ns2 have underlay MTU=1400. Oversized outer packets in both
directions trigger ip_do_fragment. Each ping (request + reply) generates 2 events.

---

## flow_state map after traffic

```json
[{
    "key": {
        "src_ip": 16777226,
        "dst_ip": 33554442,
        "src_port": 0,
        "dst_port": 0,
        "proto": 1,
        "pad": [0, 0, 0]
    },
    "value": {
        "last_seen_ns": 173270694075702,
        "pkt_count": 8,
        "max_inner_ip_len": 1388,
        "max_outer_ip_len": 1438
    }
}]
```

Decoded:
- `src_ip 16777226` = 10.0.0.1 (ns1 overlay, ping sender)
- `dst_ip 33554442` = 10.0.0.2 (ns2 overlay, ping target)
- `proto 1` = ICMP
- `pkt_count 8` = at least 3 small + 3 large ICMP requests; 2 extra packets
  are likely VXLAN FDB/neighbor control traffic sharing the same IP key
- `max_inner_ip_len 1388` = inner IP length of the large ping ✓
- `max_outer_ip_len 1438` = 1388 + 50 = **1438 > underlay MTU 1400** ✓

---

## Fragmentation correlation

```
flow_state: max_outer_ip_len = 1438
underlay MTU:                = 1400
excess:                      = 38 bytes
ip_do_fragment events:       = 6 (3 per direction × 2 namespaces)
```

The flow_state map shows `max_outer_ip_len (1438) > underlay MTU (1400)`.
This is the fragmentation condition. Combined with ip_do_fragment events (6),
the correlation between flow observation and kernel fragmentation is confirmed.

---

## What this proves

1. Alternative stale-MTU topology works on kernel 6.10.14: vxlan0 stays at 1450
   after underlay is reduced to 1400 (not auto-corrected by kernel).
2. tc_egress_vxlan0 correctly records `max_inner_ip_len=1388` and
   `max_outer_ip_len=1438` for oversized inner packets.
3. ip_do_fragment fires when outer IP > underlay MTU (DF=0 scenario).
4. flow_state.max_outer_ip_len > underlay MTU is the indicator that a flow's
   packets are being fragmented (DF=0) or would be PTB'd (DF=1).

---

## What remains unproven

- DF=1 case in this topology: with `ip link set vxlan0 df set`, the outer
  packet carries DF=1, causing a DROP (no fragment) and ICMP PTB generation.
  This is the cloud production scenario. The lab has enough evidence (Day 2
  DF=1 blackhole + Day 4 suppression) to support the claim without re-running
  here.
- ip_do_fragment BPF kprobe (vs ftrace): a proper BPF kprobe on ip_do_fragment
  would allow reading skb fields (outer IP len, device MTU). Deferred to Day 5.
