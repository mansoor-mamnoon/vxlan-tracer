# Day 12 — PTB_SUPPRESSED with VXLAN port 8472

**Date:** 2026-06-18
**Kernel:** 5.15.0-181-generic aarch64
**Environment:** Lima VM (Ubuntu 22.04.5 LTS)

---

## Setup

Same 8472 VXLAN lab as previous commits. iptables DROP rule for ICMP type 3/4
installed in ns1 before injection.

```bash
ip netns exec ns1 iptables -A INPUT -p icmp --icmp-type 3/4 -j DROP
```

---

## Traffic

```bash
ip netns exec ns2 python3 spikes/inject_ptb.py \
    --src 192.168.100.2 --dst 192.168.100.1 \
    --dev veth2 --next-hop-mtu 1400 --count 5 \
    --vxlan-port 8472
```

```
Injecting 5 synthetic ICMP PTB(s):
  embedded: 192.168.100.1→192.168.100.2 UDP dport=8472 (outer IP len=1438 DF=1)
  sent 1/5 ... sent 5/5
Done. Sent 5 ICMP PTB(s).
```

---

## vxlan-tracer output

Startup:
```
vxlan port: 8472 (auto-detected)
vxlan vni:  42
```

JSON:
```json
{
  "verdict": "PTB_SUPPRESSED",
  "message": "5 ICMP type=3/code=4 packet(s) were observed at TC ingress, but 0 reached icmp_rcv: something between the NIC and icmp_rcv — commonly a netfilter/iptables DROP rule — is suppressing PTBs before the kernel can act on them.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "vxlan_port": 8472,
  "vxlan_vni": 42,
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 0,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

---

## What this confirms

1. **PTB_SUPPRESSED works with port 8472.**
   `ptb_ingress_total=5` — TC ingress BPF counted all 5 PTBs with embedded
   dstport=8472 (the vxlan_config map was written with portNBO=bpf_htons(8472)).

2. **`icmp_rcv_total=0` — iptables DROP rule worked as expected.**
   The delta `ptb_ingress_total(5) > icmp_rcv_total(0)` triggers PTB_SUPPRESSED.

3. **vxlan_port=8472 in JSON** — correctly reflects the auto-detected port.

4. **Non-4789 PTB suppression detection end-to-end proven.**
   This is the critical path for CNI environments using port 8472
   (k3s/Flannel) where PTB suppression by iptables policies must be detected.
