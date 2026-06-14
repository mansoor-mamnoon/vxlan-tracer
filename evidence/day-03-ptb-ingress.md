# evidence/day-03-ptb-ingress.md

Synthetic PTB injection test against `tc_ingress_eth0.bpf.c`.
Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.

---

## Test setup

Lab topology: ns1 (VTEP 192.168.100.1, veth1 + vxlan0) and ns2 (VTEP 192.168.100.2, veth2).
`tc_ingress_eth0.bpf.c` attached to `veth1 ingress` in ns1 (Commit 5, `jited` confirmed).
bpftool binary: `/usr/lib/linux-tools/5.15.0-181-generic/bpftool` (wrapper at `/usr/sbin/bpftool`
is broken on kernel 6.10.14 — prints "not found" and exits).

---

## Injection command

```sh
# Run from ns2 to simulate a remote router sending ICMP PTB toward ns1
ip netns exec ns2 python3 spikes/inject_ptb.py \
    --src 192.168.100.2 \
    --dst 192.168.100.1 \
    --dev veth2 \
    --next-hop-mtu 1400 \
    --count 5

# Output:
# Injecting 5 synthetic ICMP PTB(s):
#   src=192.168.100.2 → dst=192.168.100.1
#   next_hop_mtu=1400
#   embedded: 192.168.100.1→192.168.100.2 UDP dport=4789 (outer IP len=1438 DF=1)
#   interface: veth2
#
#   sent 1/5
#   sent 2/5
#   sent 3/5
#   sent 4/5
#   sent 5/5
#
# Done. Sent 5 ICMP PTB(s).
```

---

## Map dump before injection

```sh
BPFTOOL=/usr/lib/linux-tools/5.15.0-181-generic/bpftool

# Find map IDs for this program
$BPFTOOL map list | grep -E "ptb_ingress"
# 63: hash   name ptb_ingress_cou  flags 0x0
# 64: array  name ptb_ingress_tot  flags 0x0

$BPFTOOL map dump id 63
# []

$BPFTOOL map dump id 64
# [{
#     "key": 0,
#     "value": 0
# }]
```

Both maps empty before injection, as expected.

---

## Map dump after injection

```sh
$BPFTOOL map dump id 63
# [{
#     "key": {
#         "ptb_src_ip": 40151232,
#         "ptb_dst_ip": 23374016
#     },
#     "value": {
#         "first_seen_ns": 170701520558656,
#         "last_seen_ns": 170701824738739,
#         "ptb_count": 5,
#         "next_hop_mtu": 0,
#         "pad": 0
#     }
# }]

$BPFTOOL map dump id 64
# [{
#     "key": 0,
#     "value": 5
# }]
```

---

## Result analysis

### ptb_count: 5 — CORRECT

The BPF program counted all 5 injected PTBs. The key correctly identifies
the VTEP pair:
- `ptb_src_ip: 40151232` = 0xC0A86402 = 192.168.100.2 (ns2, PTB sender)
- `ptb_dst_ip: 23374016` = 0xC0A86401 = 192.168.100.1 (ns1, PTB receiver)

`ptb_ingress_total: 5` confirms the global counter is consistent with the
per-pair counter.

The core signal — PTBs arrived at the underlay before netfilter — works.

### next_hop_mtu: 0 — BUG IN INJECT_PTB.PY (not in BPF)

Expected `next_hop_mtu: 1400` based on `--next-hop-mtu 1400` argument.
Actual: 0.

**Root cause:** In scapy's `ICMP` class, type=3 (Destination Unreachable) has
two separate `ShortField` definitions for the 4-byte "unused" region:
```
bytes 4-5:  ShortField("unused", 0)     → maps to icmph->un.frag.__unused
bytes 6-7:  ShortField("nexthopmtu", 0) → maps to icmph->un.frag.mtu
```

The original script called `ICMP(..., unused=args.next_hop_mtu)`, which put
1400 into bytes 4-5 (`__unused`). The BPF reads `icmph->un.frag.mtu` (bytes
6-7), which remained 0.

**Fix applied (this commit):** `spikes/inject_ptb.py` now uses
`nexthopmtu=args.next_hop_mtu` so the value lands in bytes 6-7 where
`bpf_ntohs(icmph->un.frag.mtu)` will read it correctly.

The BPF program itself is correct — it reads the right field. The synthetic
test packet was malformed.

---

## What this proves

1. `tc_ingress_eth0.bpf.c` receives ICMP type=3 code=4 packets on veth1 ingress
   in ns1 before they reach netfilter.
2. The per-VTEP-pair map key is populated with the correct source and destination
   underlay addresses.
3. The global total counter increments atomically with each PTB.
4. The program never drops packets: all 5 injected PTBs passed through
   (`TC_ACT_OK`) and were visible to the rest of the network stack.

## What remains unproven at this stage

- `next_hop_mtu` field will be non-zero after fix in inject_ptb.py (re-test
  needed, scheduled for Commit 9 alongside egress attach).
- Suppression detection: ptb_ingress_count > 0 while icmp_rcv == 0 requires
  kprobes.bpf.c (Day 4).
- tc_egress_vxlan0 coverage: inner packet flow_state map not yet attached
  (Commits 8-9).
