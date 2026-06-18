# Day 12 — PTB_DELIVERED with VXLAN port 8472

**Date:** 2026-06-18
**Kernel:** 5.15.0-181-generic aarch64
**Environment:** Lima VM (Ubuntu 22.04.5 LTS)

---

## Setup

VXLAN lab with `VXLAN_PORT=8472`; interface `vxlan0` has `dstport 8472`.
(Same lab as `evidence/day-12-netns-8472-setup.md`.)

---

## vxlan-tracer invocation

```bash
sudo nsenter --net=/var/run/netns/ns1 -- ./dist/vxlan-tracer \
    --overlay vxlan0 --underlay veth1 \
    --duration 20s --json
```

(No `--vxlan-port` — auto-detect reads 8472 from the interface.)

---

## Traffic

```bash
sudo ip netns exec ns2 python3 spikes/inject_ptb.py \
    --src 192.168.100.2 --dst 192.168.100.1 \
    --dev veth2 --next-hop-mtu 1400 --count 5 \
    --vxlan-port 8472
```

Output:
```
Injecting 5 synthetic ICMP PTB(s):
  src=192.168.100.2 → dst=192.168.100.1
  next_hop_mtu=1400
  embedded: 192.168.100.1→192.168.100.2 UDP dport=8472 (outer IP len=1438 DF=1)
  interface: veth2

  sent 1/5 ... sent 5/5
Done. Sent 5 ICMP PTB(s).
```

---

## vxlan-tracer output

Startup:
```
vxlan-tracer 0.1.0-dev
overlay:    vxlan0
underlay:   veth1
vxlan port: 8472 (auto-detected)
vxlan vni:  42
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/vxlan-tracer
maps cleared: fresh baseline for this run
detached kprobes (TC filters remain attached; maps remain pinned)
```

JSON:
```json
{
  "verdict": "PTB_DELIVERED",
  "message": "5 ICMP type=3/code=4 packet(s) were observed at TC ingress and 5 reached icmp_rcv: PTBs are reaching the kernel's ICMP handling path, not being suppressed.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "vxlan_port": 8472,
  "vxlan_vni": 42,
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 5,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

---

## What this confirms

1. **BPF vxlan_config map with port 8472 matches PTBs at TC ingress.**
   `ptb_ingress_total=5` — the TC ingress BPF program correctly identified
   5 ICMP PTBs whose embedded UDP header had `dstport=8472`.
   With the old hardcoded 4789, all 5 would have been silently discarded
   (`ptb_ingress_total=0`).

2. **PTB_DELIVERED verdict correct for port 8472.**
   `icmp_rcv_total=5` — PTBs passed through netfilter. Both signals agree.

3. **JSON vxlan_port=8472** — correctly reflects the auto-detected port.

4. **BPF verifier accepted port 8472 in the config map** — same code path,
   different value; the map is writable after collection creation.
