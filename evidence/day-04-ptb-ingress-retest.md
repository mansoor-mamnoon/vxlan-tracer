# evidence/day-04-ptb-ingress-retest.md

Re-test of synthetic PTB injection after fixing `inject_ptb.py` (`nexthopmtu=`).
Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.
bpftool: `/usr/lib/linux-tools-5.15.0-181/bpftool` v5.15.199.

---

## Context

Day 3 Commit 6 found `next_hop_mtu: 0` in the BPF map despite injecting PTBs
with `--next-hop-mtu 1400`. Root cause: scapy ICMP type=3 uses two ShortFields:
- `unused`    (bytes 4-5): `icmph->un.frag.__unused`
- `nexthopmtu` (bytes 6-7): `icmph->un.frag.mtu` ← what the BPF reads

The original script used `unused=args.next_hop_mtu` which populated bytes 4-5.
The BPF reads bytes 6-7 (`bpf_ntohs(icmph->un.frag.mtu)`), finding 0.

The fix was committed in Day 3 Commit 6. This commit re-runs the test to verify
the fix produces `next_hop_mtu: 1400` in the BPF map.

---

## Test procedure

```sh
# Compile
clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/tc_ingress_eth0.bpf.c -o /tmp/tc_ingress_eth0.bpf.o
# Exit: 0, zero warnings

# Lab: ns1 (192.168.100.1 on veth1) + ns2 (192.168.100.2 on veth2)

# Attach
ip netns exec ns1 tc qdisc add dev veth1 clsact
ip netns exec ns1 tc filter add dev veth1 ingress bpf da \
  obj /tmp/tc_ingress_eth0.bpf.o sec tc
# Filter: id 168 tag 20bd2d524d2b4592 jited  ← verifier+JIT confirmed

# Inject
ip netns exec ns2 python3 spikes/inject_ptb.py \
  --src 192.168.100.2 --dst 192.168.100.1 \
  --dev veth2 --next-hop-mtu 1400 --count 5
```

---

## Map dump before injection

```json
ptb_ingress_counts: []
ptb_ingress_total:  [{"key": 0, "value": 0}]
```

---

## Map dump after injection

```json
ptb_ingress_counts:
[{
    "key": {
        "ptb_src_ip": 40151232,
        "ptb_dst_ip": 23374016
    },
    "value": {
        "first_seen_ns": 172458178062122,
        "last_seen_ns": 172458756481914,
        "ptb_count": 5,
        "next_hop_mtu": 1400,
        "pad": 0
    }
}]

ptb_ingress_total:
[{"key": 0, "value": 5}]
```

---

## Result

| Field | Expected | Actual |
|-------|----------|--------|
| ptb_count | 5 | 5 ✓ |
| ptb_ingress_total | 5 | 5 ✓ |
| next_hop_mtu | 1400 | **1400 ✓** |
| ptb_src_ip | 192.168.100.2 | 40151232 = 192.168.100.2 ✓ |
| ptb_dst_ip | 192.168.100.1 | 23374016 = 192.168.100.1 ✓ |

`next_hop_mtu: 1400` confirms that the BPF program correctly reads
`icmph->un.frag.mtu` (bytes 6-7 of the ICMP header) and that the scapy
`nexthopmtu=` field correctly places the value in those bytes.

---

## What is now fully confirmed for tc_ingress_eth0

1. Compiles with zero warnings on aarch64 Docker linuxkit.
2. BPF verifier accepts; JIT compiles (`jited` in tc filter).
3. Counts ICMP PTBs arriving at veth1 ingress before netfilter: ptb_count=5 ✓.
4. Populates VTEP-pair map key correctly: 192.168.100.2→192.168.100.1 ✓.
5. Reads next-hop MTU from ICMP header: next_hop_mtu=1400 ✓.

## What remains unproven

- Post-netfilter count (`icmp_rcv` BPF): not yet implemented (Commits 2-6).
- Suppression signal (`ptb_ingress > 0` AND `icmp_rcv == 0`): requires both
  programs running simultaneously (Commits 5-6).
