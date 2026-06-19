# Day 13 — 6-scenario suite after fail-closed changes

**Date:** 2026-06-19
**Kernel:** 5.15.0-181-generic aarch64
**Environment:** Lima VM (Ubuntu 22.04.5 LTS)

---

## Pre-run steps

```bash
# Source sync (no pre-compiled objects)
rsync -a --exclude='*.bpf.o' /mac-repo/bpf/ bpf/
rsync -a /mac-repo/internal/ internal/

# Clean rebuild
sudo make clean-bpf && sudo make bpf
# BPF build complete.
# tc_ingress_eth0.bpf.o: 19K (Jun 19 15:26)

# Verify fresh object
make bpf-verify
#   PASS  bpf/tc_ingress_eth0.bpf.o contains vxlan_config map section

# Go tests (includes loader unit tests)
go test ./...
# ok  github.com/mansoormmamnoon/vxlan-tracer/internal/loader  0.002s
# ok  github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap  (cached)
# ok  github.com/mansoormmamnoon/vxlan-tracer/internal/diag    (cached)
```

---

## Scenario suite

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
| 5 | fragmentation (2nd) | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED | PASS |
| 6 | ptb_delivered port=8472 | PTB_DELIVERED + vxlan_port=8472 | PTB_DELIVERED + vxlan_port=8472 | PASS |

**Results: 6 passed, 0 failed**

---

## Scenario 6 JSON

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

---

## What this confirms (post Day 13 changes)

1. **Fail-closed loader does not break existing scenarios.** All five original
   scenarios pass with the fresh 19K object (contains vxlan_config).

2. **Scenario 6 (port 8472) still passes after Day 13 refactoring.**
   The `writeVXLANPortToMaps` refactor preserves the behavior.

3. **`make bpf-verify` correctly identifies the fresh object** (symbol table
   check via `readelf -s`, not section header check via `-S`).

4. **Unit tests pass on Linux.** `TestWriteVXLANPortToMapsMissing` and
   `TestWriteVXLANPortToMapsMissingPort0` both pass; go test exit 0.
