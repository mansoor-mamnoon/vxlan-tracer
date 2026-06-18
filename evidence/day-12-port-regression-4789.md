# Day 12 — 4789 port regression suite

**Date:** 2026-06-18
**Kernel:** 5.15.0-181-generic aarch64
**Environment:** Lima VM (Ubuntu 22.04.5 LTS, macOS VZ hypervisor)

---

## Purpose

Confirm that the `vxlan_config` BPF map addition (Day 11) does not regress
the existing 5-scenario suite on the default 4789 VXLAN port.

---

## BPF compile result

```
  prereqs OK  clang=Ubuntu clang version 14.0.0-1ubuntu1.1  arch=aarch64  bpf_target=-D__TARGET_ARCH_arm64
  CC  bpf/tc_ingress_eth0.bpf.c → bpf/tc_ingress_eth0.bpf.o  (19K)
```

Compiled without errors or warnings. Object size 19K vs 17.9K pre-Day 11 —
the increase is the additional `vxlan_config` ARRAY map section.

BPF verifier accepted the map lookup on 5.15.0-181-generic. No verifier
rejection for the `bpf_map_lookup_elem(&vxlan_config, &cfg_k)` null check
or the ternary dereference of `cfg->vxlan_dport`.

---

## Go unit tests

```
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap  0.007s
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/diag    0.001s
```

All unit tests pass.

---

## Scenario results — 5/5 PASS

**Environment:** lab netns topology, VNI=42, port=4789, underlay MTU=1400,
overlay MTU=1450 (stale/misconfigured).

### Scenario 1: VXLAN_MTU_MISCONFIGURATION

```json
{
  "verdict": "VXLAN_MTU_MISCONFIGURATION",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "vxlan_port": 4789,
  "vxlan_vni": 42,
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 0,
  "icmp_rcv_total": 0,
  "frag_events_total": 0,
  "max_outer_ip_len": 118
}
```

**[PASS]**

### Scenario 2: VXLAN_FRAGMENTATION_OBSERVED

```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "fragmentation_scope": "global_corroborated",
  "vxlan_port": 4789,
  "vxlan_vni": 42,
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 0,
  "icmp_rcv_total": 0,
  "frag_events_total": 6,
  "frag_max_skb_len": 1438,
  "max_outer_ip_len": 1438
}
```

**[PASS]**

### Scenario 3: PTB_DELIVERED

PTBs injected with `dport=4789` in embedded header. vxlan_config map held
`portNBO=0xB512` (bpf_htons(4789)); comparison with `udph->dest` matched.

```json
{
  "verdict": "PTB_DELIVERED",
  "vxlan_port": 4789,
  "vxlan_vni": 42,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 5,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

**[PASS]** — ptb_ingress_total=5 confirms BPF vxlan_config map lookup
returned the correct port and the comparison fired for all 5 packets.

### Scenario 4: PTB_SUPPRESSED

```json
{
  "verdict": "PTB_SUPPRESSED",
  "vxlan_port": 4789,
  "vxlan_vni": 42,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 0,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

**[PASS]** — TC ingress count 5 > icmp_rcv 0; suppression detected.

### Scenario 5: Second fragmentation run (idempotency)

```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "fragmentation_scope": "global_corroborated",
  "vxlan_port": 4789,
  "vxlan_vni": 42,
  "frag_events_total": 6,
  "frag_max_skb_len": 1438,
  "max_outer_ip_len": 1438
}
```

**[PASS]**

---

## Key confirmations

1. **BPF verifier accepts vxlan_config map on 5.15.0-181-generic.** No rejection.
2. **Byte order conversion correct.** PTB_DELIVERED (ptb_ingress_total=5) and
   PTB_SUPPRESSED (ptb_ingress_total=5) prove the map lookup returned the right
   port value (0xB512 for 4789) and the comparison matched all 5 PTB packets.
3. **Auto-detect works.** vxlan_port=4789 and vxlan_vni=42 appear in all JSON
   outputs, read from the `vxlan0` interface via rtnetlink (DetectVXLAN).
4. **No regression.** All 5 pre-existing scenario verdicts are identical to Day 9.

---

## Summary

```
Results: 5 passed, 0 failed
Kernel:  5.15.0-181-generic aarch64
```
