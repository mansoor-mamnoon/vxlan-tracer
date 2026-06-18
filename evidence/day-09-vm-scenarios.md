# Day 9 — Scenario suite on Lima VM (5.15.0-181-generic)

**Date:** 2026-06-17
**Kernel:** 5.15.0-181-generic (Ubuntu 22.04.5 LTS, aarch64)
**VM:** Lima vxlan-test (macOS VZ hypervisor, Apple Silicon host)
**Binary:** `dist/vxlan-tracer` (natively compiled on VM, 4.8M ELF aarch64)
**BPF_DIR:** `bpf/` (compiled on VM with `make bpf`)
**Duration:** 15s per scenario

## Command

```sh
BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s bash scripts/run-scenarios.sh
```

Run as root from `/tmp/vxlan-tracer` inside the Lima VM.

## Results

```
Results: 5 passed, 0 failed
```

## Per-scenario output

### Scenario 1: healthy_small → VXLAN_MTU_MISCONFIGURATION — PASS

```json
{
  "verdict": "VXLAN_MTU_MISCONFIGURATION",
  "message": "No PTBs, fragmentation events, or oversized traffic were observed during this run, but the overlay MTU (1450) exceeds the safe value for the underlay MTU (1400) by 100 byte(s). This is a static configuration risk: traffic large enough to use the full overlay MTU would trigger either fragmentation or a PTB, depending on the DF bit.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 0,
  "icmp_rcv_total": 0,
  "frag_events_total": 0,
  "max_outer_ip_len": 118
}
```

### Scenario 2: fragmentation → VXLAN_FRAGMENTATION_OBSERVED — PASS

```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "message": "6 ip_do_fragment invocation(s) were observed while vxlan-tracer was attached; concurrently, the TC egress hook recorded an outer packet length of 1438 bytes, 38 bytes over the underlay MTU (1400). Fragmentation was observed while oversized VXLAN traffic was present — these two signals together are consistent with VXLAN outer packets triggering ip_do_fragment. Note: ip_do_fragment is a global kernel function and may include non-VXLAN fragmentation events on a busy host. Fragmented VXLAN UDP is commonly dropped silently by cloud fabric; in a local lab fragments may reassemble — fragmentation observed here does not by itself confirm packet loss.",
  "fragmentation_scope": "global_corroborated",
  "overlay": "vxlan0",
  "underlay": "veth1",
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

Notes:
- `frag_events_total=6`: 3 pings × 2 directions (each oversized outer VXLAN packet triggers ip_do_fragment once per direction)
- `frag_max_skb_len=1438`: skb->len at ip_do_fragment entry is the outer IP length (1438B), not the inner
- `fragmentation_scope=global_corroborated`: both signals agree — ip_do_fragment fired AND TC egress saw outer > underlay MTU
- This confirms CO-RE skb->len resolution works on 5.15.0-181-generic's BTF

### Scenario 3: ptb_delivered → PTB_DELIVERED — PASS

```json
{
  "verdict": "PTB_DELIVERED",
  "message": "5 ICMP type=3/code=4 packet(s) were observed at TC ingress and 5 reached icmp_rcv: PTBs are reaching the kernel's ICMP handling path, not being suppressed.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 5,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

### Scenario 4: ptb_suppressed → PTB_SUPPRESSED — PASS

```json
{
  "verdict": "PTB_SUPPRESSED",
  "message": "5 ICMP type=3/code=4 packet(s) were observed at TC ingress, but 0 reached icmp_rcv: something between the NIC and icmp_rcv — commonly a netfilter/iptables DROP rule — is suppressing PTBs before the kernel can act on them.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 0,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

### Scenario 5: fragmentation second run → VXLAN_FRAGMENTATION_OBSERVED — PASS

```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "fragmentation_scope": "global_corroborated",
  "frag_events_total": 6,
  "frag_max_skb_len": 1438,
  "max_outer_ip_len": 1438
}
```

`ip route flush cache` was effective on 5.15.0-181-generic — route MTU cache cleared between runs, restoring oversized outer packets and the global_corroborated verdict.

## Summary

| Scenario | Expected | Actual | Result |
|----------|---------|--------|--------|
| healthy_small | VXLAN_MTU_MISCONFIGURATION | VXLAN_MTU_MISCONFIGURATION | PASS |
| fragmentation | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED | PASS |
| ptb_delivered | PTB_DELIVERED | PTB_DELIVERED | PASS |
| ptb_suppressed | PTB_SUPPRESSED | PTB_SUPPRESSED | PASS |
| fragmentation (rerun) | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED | PASS |

**5/5 PASS** — first validation on a non-linuxkit kernel.

## Comparison with 6.10.14-linuxkit (aarch64)

All verdicts and JSON field values are identical:
- `frag_events_total=6`: same
- `frag_max_skb_len=1438`: same (outer IP length; not inner)
- `fragmentation_scope=global_corroborated`: same
- `max_outer_ip_len=1438`: same
- `ptb_ingress_total=5`, `icmp_rcv_total=5` (delivered) and `0` (suppressed): same
- `ip route flush cache` effective: same

No behavioral differences between the two kernels in these tests.
Architecture is aarch64 in both cases. x86_64 testing remains as a future target.

## BPF program acceptance on 5.15.0-181-generic

The scenario run confirms:
- TC sched_cls programs (`tc_ingress_eth0`, `tc_egress_vxlan0`) loaded by the BPF verifier
- kprobe programs (`kprobes.bpf.o` for icmp_rcv, `frag_kprobes.bpf.o` for ip_do_fragment) loaded
- CO-RE BTF relocations resolved for `skb->len`, `skb->data`, `skb->network_header`, `skb->transport_header`
- All map operations (ARRAY, HASH, pinning, clearing) work correctly
