# evidence/day-03-vxlan-egress.md

TC egress attachment and flow map results for `tc_egress_vxlan0.bpf.c`.
Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.
bpftool: `/usr/lib/linux-tools-5.15.0-181/bpftool` v5.15.199.

Note: `/usr/sbin/bpftool` wrapper fails on kernel 6.10.14 ("not found for kernel version");
the versioned binary at the path above works correctly.

---

## Compilation

```sh
clang -O2 -g -target bpf \
  -I/usr/include \
  -I/usr/include/aarch64-linux-gnu \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/tc_egress_vxlan0.bpf.c -o /tmp/tc_egress_vxlan0.bpf.o
# Exit: 0  (zero warnings)
```

ELF sections:
```
Idx Name    Size      Type
  3 tc      0x290     TEXT   (BPF bytecode — 656 bytes)
  4 .reltc  0x20      (relocations)
  5 .maps   0x20      DATA   (flow_state map descriptor)
  6 license 0x04      DATA   ("GPL")
```

Object size: 17K (slightly smaller than tc_ingress_eth0.bpf.o at 18K because
flow_state HASH has a simpler key than ptb_ingress_counts with its two maps).

---

## TC filter attachment

```sh
# Add clsact qdisc on vxlan0 in ns1
ip netns exec ns1 tc qdisc add dev vxlan0 clsact
# Exit: 0

# Attach BPF program to egress
ip netns exec ns1 tc filter add dev vxlan0 egress bpf da \
    obj /tmp/tc_egress_vxlan0.bpf.o sec tc
# Exit: 0
```

TC filter verification:
```
$ ip netns exec ns1 tc filter show dev vxlan0 egress

filter protocol all pref 49152 bpf chain 0
filter protocol all pref 49152 bpf chain 0 handle 0x1 tc_egress_vxlan0.bpf.o:[tc] \
    direct-action not_in_hw id 161 tag 8d5c7a9a173ff918 jited
```

Key fields:
- `id 161`: kernel-assigned BPF program ID
- `tag 8d5c7a9a173ff918`: SHA hash of BPF bytecode
- `jited`: BPF verifier accepted the program and JIT-compiled it

For reference, tc_ingress_eth0 simultaneously on veth1 ingress:
```
filter protocol all pref 49152 bpf chain 0 handle 0x1 tc_ingress_eth0.bpf.o:[tc] \
    direct-action not_in_hw id 157 tag 20bd2d524d2b4592 jited
```

---

## bpftool map list (all three maps live)

```
77: hash  name ptb_ingress_cou  key 8B  value 24B  max_entries 1024   btf_id 63
78: array name ptb_ingress_tot  key 4B  value 8B   max_entries 1      btf_id 63
79: hash  name flow_state       key 16B value 16B  max_entries 4096   btf_id 69
```

All three maps created and live:
- Map 77 (ptb_ingress_counts): HASH, key=ptb_key(8B), value=ptb_val(24B)
- Map 78 (ptb_ingress_total):  ARRAY, key=u32(4B), value=u64(8B)
- Map 79 (flow_state):         HASH, key=flow_key(16B), value=flow_val(16B)

---

## Traffic test

Lab topology:
- ns1: veth1 (192.168.100.1, MTU 1500) + vxlan0 (10.0.0.1, MTU 1450)
- ns2: veth2 (192.168.100.2, MTU 1500) + vxlan0 (10.0.0.2, MTU 1450)

TC programs attached:
- veth1 ingress (ns1): tc_ingress_eth0 — counts ICMP PTBs before netfilter
- vxlan0 egress (ns1): tc_egress_vxlan0 — tracks inner flows before encapsulation

### Small traffic: 3x ping -s 56 (inner IP 84B, outer IP 134B)

```
PING 10.0.0.2 56(84) bytes of data.
64 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=0.673 ms
64 bytes from 10.0.0.2: icmp_seq=2 ttl=64 time=0.274 ms
64 bytes from 10.0.0.2: icmp_seq=3 ttl=64 time=0.156 ms
3 packets transmitted, 3 received, 0% packet loss
```

### Large traffic: 3x ping -s 1400 (inner IP 1428B, outer IP 1478B)

```
PING 10.0.0.2 1400(1428) bytes of data.
1408 bytes from 10.0.0.2: icmp_seq=1 ttl=64 time=0.134 ms
1408 bytes from 10.0.0.2: icmp_seq=2 ttl=64 time=0.254 ms
1408 bytes from 10.0.0.2: icmp_seq=3 ttl=64 time=0.170 ms
3 packets transmitted, 3 received, 0% packet loss
```

Note: outer IP 1478B < underlay MTU 1500B for both small and large traffic,
so no fragmentation and no PTB. Both ping sets succeed with 0% loss.

---

## Map dump after traffic

### flow_state map (id 79)

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
        "last_seen_ns": 171504865083229,
        "pkt_count": 6,
        "max_inner_ip_len": 1428,
        "max_outer_ip_len": 1478
    }
}]
```

Decoded:
- `src_ip: 16777226` = 10.0.0.1 (ns1 overlay, ping sender)
- `dst_ip: 33554442` = 10.0.0.2 (ns2 overlay, ping target)
- `proto: 1` = ICMP
- `src_port: 0, dst_port: 0` — ICMP has no ports; zero-initialised as expected
- `pkt_count: 6` = 3 small ICMP echoes + 3 large ICMP echoes from ns1 vxlan0 egress ✓
- `max_inner_ip_len: 1428` = inner IP length of the large ping (1400B payload + 28B headers) ✓
- `max_outer_ip_len: 1478` = 1428 + 50 (VXLAN overhead) ✓

IP conversion formula (LE host, NBO struct field):
  `16777226 = 0x0100000A`; LE bytes = [0x0A, 0x00, 0x00, 0x01] = 10.0.0.1
  `33554442 = 0x0200000A`; LE bytes = [0x0A, 0x00, 0x00, 0x02] = 10.0.0.2

### ptb_ingress_counts (id 77)

```json
[]
```

Empty — correct. No ICMP PTBs arrived at veth1 ingress because the outer IP
packet (max 1478B) fits within the underlay MTU (1500B). No PTB was generated.

### ptb_ingress_total (id 78)

```json
[{"key": 0, "value": 0}]
```

Zero — consistent with empty ptb_ingress_counts.

---

## Result summary

| What | Expected | Actual |
|------|----------|--------|
| tc_egress_vxlan0 compiles | 0 warnings | 0 warnings ✓ |
| Verifier accepts, JIT compiles | jited in tc show | jited ✓ |
| flow_state populated after traffic | 1 ICMP entry | 1 entry ✓ |
| pkt_count for 6 outbound packets | 6 | 6 ✓ |
| max_inner_ip_len tracks largest packet | 1428 | 1428 ✓ |
| max_outer_ip_len = inner + 50 | 1478 | 1478 ✓ |
| ptb_ingress_counts empty (no PTBs) | [] | [] ✓ |
| ptb_ingress_total = 0 | 0 | 0 ✓ |

## What remains unproven

- Blackhole scenario: for outer IP > underlay MTU (requires alternative topology
  with underlay MTU=1400 so that inner IP > 1350 triggers PTB). Deferred to Day 4.
- PTB in ptb_ingress_counts with non-zero next_hop_mtu: requires re-running
  the inject_ptb.py test after the nexthopmtu= fix from Commit 6.
- kprobes.bpf.c (icmp_rcv count post-netfilter): not yet implemented (Day 4).
- Go loader calling BPF programs directly without bpftool: deferred.
