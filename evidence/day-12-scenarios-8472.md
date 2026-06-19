# Day 12 — Full 6-scenario suite with 8472 port scenario

**Date:** 2026-06-18
**Kernel:** 5.15.0-181-generic aarch64
**Environment:** Lima VM (Ubuntu 22.04.5 LTS)

---

## Command

```bash
sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s bash scripts/run-scenarios.sh
```

---

## Results

| # | Scenario | Expected | Actual | Result |
|---|----------|----------|--------|--------|
| 1 | healthy_small | VXLAN_MTU_MISCONFIGURATION | VXLAN_MTU_MISCONFIGURATION | PASS |
| 2 | fragmentation | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED | PASS |
| 3 | ptb_delivered | PTB_DELIVERED | PTB_DELIVERED | PASS |
| 4 | ptb_suppressed | PTB_SUPPRESSED | PTB_SUPPRESSED | PASS |
| 5 | fragmentation (2nd run) | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED | PASS |
| 6 | ptb_delivered port=8472 | PTB_DELIVERED + vxlan_port=8472 | PTB_DELIVERED + vxlan_port=8472 | PASS |

**Results: 6 passed, 0 failed**

---

## Scenario 6 detail

Scenario 6 uses `_run_port_ptb_delivered 8472`:

1. Lab created with `VXLAN_PORT=8472 bash scripts/setup-netns.sh` — `vxlan0` has `dstport 8472`.
2. `vxlan-tracer` invoked without `--vxlan-port` (auto-detect path, default 0).
   Auto-detect reads port 8472 from `vxlan0` via rtnetlink; writes `portNBO=bpf_htons(8472)` into the `vxlan_config` BPF map.
3. PTBs injected with `inject_ptb.py --vxlan-port 8472` — embedded UDP `dstport=8472`.
4. BPF TC ingress counts all 5 PTBs (port 8472 matches filter).

JSON output:
```json
{
  "verdict": "PTB_DELIVERED",
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

Runner assertion: `verdict==PTB_DELIVERED AND vxlan_port==8472` — both passed.

---

## What this proves

1. **Scenarios 1–5 remain unaffected by the vxlan_config map addition.**
   All five original scenarios pass identically to the Day 10 baseline.
   The ARRAY map zero-initializes; when no port is written the BPF code falls back
   to `bpf_htons(4789)` — existing behavior is preserved.

2. **Non-4789 port (8472) end-to-end path works in the scenario runner.**
   The `_run_port_ptb_delivered` function creates a dedicated lab, lets auto-detect
   configure the BPF map, injects port-8472 PTBs, and asserts both the verdict and
   the JSON `vxlan_port` field.

3. **Scenario runner is the definitive regression guard.**
   A single `BINARY=... BPF_DIR=... bash scripts/run-scenarios.sh` command
   validates all diagnostic paths including non-default VXLAN ports.
