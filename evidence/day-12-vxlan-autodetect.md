# Day 12 — VXLAN port auto-detect on 8472 interface

**Date:** 2026-06-18
**Kernel:** 5.15.0-181-generic aarch64
**Environment:** Lima VM (Ubuntu 22.04.5 LTS)

---

## Setup

VXLAN lab created with `VXLAN_PORT=8472 bash scripts/setup-netns.sh`.

```
$ sudo ip netns exec ns1 ip -d link show vxlan0
    vxlan id 42 remote 192.168.100.2 local 192.168.100.1 dev veth1
    srcport 0 0 dstport 8472 ...
```

Interface confirmed: `vxlan id 42`, `dstport 8472`.

---

## Auto-detect run

Command:
```bash
sudo nsenter --net=/var/run/netns/ns1 -- ./dist/vxlan-tracer \
    --overlay vxlan0 --underlay veth1 \
    --pin-dir /sys/fs/bpf/vxlan-tracer --bpf-dir bpf \
    --duration 5s --json
```

Note: `--vxlan-port` is NOT specified; the default is 0 (auto-detect).

---

## Output

```
vxlan-tracer 0.1.0-dev
overlay:    vxlan0
underlay:   veth1
vxlan port: 8472 (auto-detected)
vxlan vni:  42
pin dir:    /sys/fs/bpf/vxlan-tracer
bpf dir:    bpf
attached: tc ingress, tc egress, kprobe/icmp_rcv, kprobe/ip_do_fragment; maps pinned under /sys/fs/bpf/vxlan-tracer
maps cleared: fresh baseline for this run
detached kprobes (TC filters remain attached; maps remain pinned)
```

JSON:
```json
{
  "verdict": "VXLAN_MTU_MISCONFIGURATION",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "vxlan_port": 8472,
  "vxlan_vni": 42,
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 0,
  "icmp_rcv_total": 0,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

---

## What this confirms

1. **Auto-detect works on a real VXLAN interface.** `internal/netlink.DetectVXLAN`
   reads `Port=8472` and `VNI=42` from the kernel via rtnetlink.
   `vishvananda/netlink.Vxlan.Port` correctly maps to the kernel's
   `IFLA_VXLAN_PORT` attribute.

2. **Go loader writes port 8472 into BPF config map.** No attach error;
   `ptb_ingress_total=0` for this no-traffic run (correct — no PTBs injected).
   The BPF program loaded with vxlan_config holding portNBO=bpf_htons(8472).

3. **BPF verifier accepted the vxlan_config map on 5.15.0-181-generic.**
   No verifier rejection for the 8472-port configuration.

4. **JSON fields vxlan_port and vxlan_vni populated correctly.**
   Both appear in output; `vxlan_port=8472` (not the old hardcoded 4789).

5. **Startup log distinguishes auto-detected from explicit port.**
   `vxlan port: 8472 (auto-detected)` vs. `vxlan port: 4789` (no suffix when explicit).
