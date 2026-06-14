# evidence/day-03.md

Day 3 synthesis: first real BPF programs compiled, verified, and producing map output.
Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64 (M-series Mac).

---

## What was implemented

### bpf/tc_ingress_eth0.bpf.c

TC sched_cls attached to the underlay interface (veth1) ingress in ns1.
Fires on every incoming packet BEFORE netfilter (iptables/nft INPUT chain).

- Parses: ETH → outer IP → ICMP type=3 code=4 → embedded outer IP → embedded outer UDP
- Checks embedded UDP destination port for 4789 (VXLAN); counts conservatively if truncated
- Increments `ptb_ingress_counts` HASH (key: VTEP pair) and `ptb_ingress_total` ARRAY
- Uses `__sync_fetch_and_add` for atomic increments; always returns TC_ACT_OK

### bpf/tc_egress_vxlan0.bpf.c

TC sched_cls attached to the overlay interface (vxlan0) egress in ns1.
Fires on inner packets BEFORE the kernel adds VXLAN/UDP/outer-IP headers.

- Parses: inner ETH → inner IP → inner TCP or UDP (for ports)
- Records inner 5-tuple in `flow_state` HASH: proto, src/dst IP, src/dst port
- Tracks: pkt_count, max_inner_ip_len, max_outer_ip_len (= inner + 50), last_seen_ns
- IHL clamped [5,15] before use as variable offset; all pointer accesses bounds-checked

### internal/bpfmap/reader.go

Pure Go package parsing bpftool JSON map dump output.

- `ParsePTBCounts([]byte) → []PTBEntry`: reads ptb_ingress_counts HASH dump
- `ParsePTBTotal([]byte) → uint64`: reads ptb_ingress_total ARRAY dump
- `leU32ToIP(uint32) → net.IP`: converts bpftool's LE uint32 IP to dotted-decimal
- 6 unit tests pass on macOS (no BPF or kernel dependency)

---

## What was verified in this lab

### BPF verifier + JIT compilation

Both programs accepted by the kernel BPF verifier and JIT-compiled:
```
veth1 ingress:  id 157 tag 20bd2d524d2b4592 jited
vxlan0 egress:  id 161 tag 8d5c7a9a173ff918 jited
```

### TC ingress: PTB counting

5 synthetic ICMP PTBs injected from ns2 via inject_ptb.py:
```
ptb_ingress_counts[{192.168.100.2 → 192.168.100.1}].ptb_count = 5  ✓
ptb_ingress_total = 5  ✓
next_hop_mtu = 0  ← known bug (inject_ptb.py used unused= not nexthopmtu=; fixed)
```

The VTEP pair key is correct: 40151232 = 192.168.100.2, 23374016 = 192.168.100.1.
PTB counting is the first half of the suppression detection signal.

### TC egress: flow observation

After 6 ICMP echo packets (3 small 56B + 3 large 1400B payload):
```
flow_state[{10.0.0.1 → 10.0.0.2, ICMP}]:
  pkt_count = 6
  max_inner_ip_len = 1428     (large ping: 1400B payload + 28B headers)
  max_outer_ip_len = 1478     (= 1428 + 50) ✓
```

max_outer_ip_len 1478 < underlay MTU 1500: no PTBs generated. ptb_ingress_counts
empty and ptb_ingress_total = 0. Both correct.

### Compile correctness

Both BPF objects compile with zero warnings:
```
tc_ingress_eth0.bpf.o  18K   sections: tc(0x2e8B), .maps(2 maps), license
tc_egress_vxlan0.bpf.o 17K   sections: tc(0x290B), .maps(1 map),  license
```

Required include fix (first encountered in Commit 3): `#include <linux/in.h>`
for `IPPROTO_ICMP` and `IPPROTO_UDP`. Not transitively included by `linux/ip.h`
in the BPF clang compilation context.

---

## Compilation environment fix (documented for reproducibility)

On aarch64 Docker ubuntu:22.04:
```sh
# Required include paths:
clang -O2 -g -target bpf \
  -I/usr/include \
  -I/usr/include/aarch64-linux-gnu \     # provides asm/types.h
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/<file>.bpf.c -o <file>.bpf.o

# bpftool (wrapper at /usr/sbin/bpftool fails on kernel 6.10.14):
BPFTOOL=/usr/lib/linux-tools-5.15.0-181/bpftool
apt-get install linux-tools-5.15.0-181-generic  # installs the binary
```

---

## What is confirmed

| Claim | Evidence |
|-------|----------|
| tc_ingress_eth0 counts ICMP PTBs before netfilter | ptb_count=5 after 5 injected PTBs |
| tc_egress_vxlan0 sees inner packets before VXLAN encap | max_inner_ip_len=1428 for 1400B ping |
| max_outer_ip_len = max_inner_ip_len + 50 | 1428+50=1478 ✓ in map |
| BPF verifier accepts both programs | jited in tc filter show |
| bpfmap Go parser correct for real bpftool output | 6/6 unit tests pass |

---

## What remains unproven

### next_hop_mtu in TC ingress map

inject_ptb.py originally used scapy's `unused=` field (bytes 4-5 of ICMP header)
instead of `nexthopmtu=` (bytes 6-7, what BPF reads as `icmph->un.frag.mtu`).
Fixed in Commit 6. Re-test with the fixed script is scheduled for Day 4.

### Blackhole scenario (outer IP > underlay MTU)

Day 3 pings used outer IP=1478B against underlay MTU=1500B — no PTBs generated.
To observe the blackhole path:
- Create vxlan0 while underlay=1500 (kernel sets vxlan0 MTU=1450)
- Reduce underlay to 1400 (vxlan0 MTU remains 1450 — stale)
- Inner IP > 1350 → outer IP > 1400 → ip_do_fragment (DF=0) or drop+PTB (DF=1)
- flow_state will show max_outer_ip_len > 1400 for the oversized flow

### PTB suppression signal

Requires both:
1. `ptb_ingress_counts` > 0 (TC ingress: PTB arrived) — ✓ demonstrated
2. `icmp_rcv` count == 0 (post-netfilter: PTB was dropped by iptables) — NOT YET
   → `kprobes.bpf.c` (icmp_rcv fentry or kprobe) not yet implemented

This is the core diagnostic claim; confirmed only after Day 4 kprobe work.

### Go loader

Currently using bpftool + tc command for attachment. A Go-based loader using
cilium/ebpf is planned but not needed to prove the hook signal.

---

## Day 4 priorities

1. `kprobes.bpf.c`: ip_do_fragment kprobe + icmp_rcv kprobe/fentry
   - icmp_send: must use `tracepoint:net:icmp_send` (not T symbol on 6.10.14)
   - BTF vmlinux present → fentry supported for icmp_rcv
2. Blackhole + iptables suppression demo:
   - Alternative topology (underlay=1400), oversized traffic, iptables DROP rule
   - ptb_ingress_count > 0 AND icmp_rcv == 0 → suppression confirmed in maps
3. Re-run inject_ptb.py with nexthopmtu= fix; verify next_hop_mtu=1400 in map
4. Go loader for cilium/ebpf-based attachment (optional if time permits)
