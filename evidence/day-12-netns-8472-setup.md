# Day 12 — Non-4789 VXLAN lab setup (port 8472)

**Date:** 2026-06-18
**Kernel:** 5.15.0-181-generic aarch64
**Environment:** Lima VM (Ubuntu 22.04.5 LTS)

---

## Change: VXLAN_PORT env var in setup-netns.sh and run-scenarios.sh

`scripts/setup-netns.sh`: `VXLAN_PORT=4789` → `VXLAN_PORT=${VXLAN_PORT:-4789}`

`scripts/run-scenarios.sh`:
- Added `VXLAN_PORT="${VXLAN_PORT:-4789}"` to variable block
- `_traffic_ptb_delivered` and `_traffic_ptb_suppressed` now pass
  `--vxlan-port "$VXLAN_PORT"` to `inject_ptb.py`

Both scripts remain backward-compatible: callers that do not set `VXLAN_PORT`
continue to use 4789.

---

## 8472 lab setup run

```
$ sudo VXLAN_PORT=8472 bash scripts/setup-netns.sh

[setup] Creating network namespaces...
[setup] Creating VXLAN in ns1 (kernel will auto-set MTU=1450)...
[setup] vxlan0 MTU after creation: 1450 (expected 1450)
[setup] Reducing underlay MTU to 1400 AFTER vxlan0 creation...
[setup] underlay ping: OK
[setup] overlay ping (small): OK

Lab topology ready:
  ns1: vxlan0=10.244.0.1/24 (MTU=1450 stale)  veth1=192.168.100.1/24 (MTU=1400)
  ns2: vxlan0=10.244.0.2/24 (MTU=1450 stale)  veth2=192.168.100.2/24 (MTU=1400)
  VNI=42  port=8472
```

---

## VXLAN interface confirmation

```
$ sudo ip netns exec ns1 ip -d link show vxlan0

2: vxlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 qdisc noqueue state UNKNOWN
    link/ether c2:a2:12:cc:ce:cc brd ff:ff:ff:ff:ff:ff
    vxlan id 42 remote 192.168.100.2 local 192.168.100.1 dev veth1
    srcport 0 0 dstport 8472 ttl auto ageing 300 udpcsum
    noudp6zerocsumtx noudp6zerocsumrx addrgenmode eui64
```

Key fields:
- `vxlan id 42` — VNI=42 (same as 4789 lab)
- `dstport 8472` — VXLAN UDP destination port confirmed as 8472

This confirms the setup script correctly creates a VXLAN interface with the
non-default port. The kernel's rtnetlink attribute `IFLA_VXLAN_PORT` is set to
8472, which is what `DetectVXLAN` reads via `vishvananda/netlink.Vxlan.Port`.
