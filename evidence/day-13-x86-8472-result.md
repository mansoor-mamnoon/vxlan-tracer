# Day 13 — x86_64 6-scenario CI result (run 27851298262)

**Date:** 2026-06-19
**Run:** https://github.com/mansoor-mamnoon/vxlan-tracer/actions/runs/27851298262
**Job conclusion:** PASS ✓
**Kernel:** 6.8.0-1059-azure x86_64
**Runner:** ubuntu-22.04 (GitHub-hosted)

---

## Scenario results

| # | Scenario | Expected verdict | Actual verdict | vxlan_port | Result |
|---|----------|-----------------|----------------|-----------|--------|
| 1 | healthy_small | VXLAN_MTU_MISCONFIGURATION | VXLAN_MTU_MISCONFIGURATION | 4789 | PASS |
| 2 | fragmentation | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED | 4789 | PASS |
| 3 | ptb_delivered | PTB_DELIVERED | PTB_DELIVERED | 4789 | PASS |
| 4 | ptb_suppressed | PTB_SUPPRESSED | PTB_SUPPRESSED | 4789 | PASS |
| 5 | fragmentation (2nd) | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED | 4789 | PASS |
| 6 | ptb_delivered port=8472 | PTB_DELIVERED + vxlan_port=8472 | PTB_DELIVERED + vxlan_port=8472 | 8472 | PASS |

**Results: 6 passed, 0 failed**

---

## Scenario 6 JSON (x86_64, port 8472)

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

## Build and unit test results

```
make bpf-verify
  PASS  bpf/tc_ingress_eth0.bpf.o contains vxlan_config map section

go test ./...
?     github.com/mansoormmamnoon/vxlan-tracer/cmd/vxlan-tracer      [no test files]
ok    github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap        (cached)
ok    github.com/mansoormmamnoon/vxlan-tracer/internal/diag          (cached)
ok    github.com/mansoormmamnoon/vxlan-tracer/internal/loader        0.003s
?     github.com/mansoormmamnoon/vxlan-tracer/internal/netlink       [no test files]
?     github.com/mansoormmamnoon/vxlan-tracer/internal/output        [no test files]
```

---

## Preflight annotation (known CI environment limitation)

The preflight check reported 1 FAIL:

```
FAIL [ENVIRONMENT]  ip link add dummy failed even as root — may be a restricted container/runner
```

This is an expected limitation of GitHub-hosted ubuntu-22.04 runners, which restrict `ip link add` for dummy interfaces. The preflight step has `continue-on-error: true`; the job continued and all scenarios ran. The step emitted an error annotation (`##[error]Process completed with exit code 1.`), which caused `gh run watch` to exit 1, but the job conclusion was **PASS**.

The dummy interface restriction does not affect scenario execution; scenarios use `ip netns add/del` (which worked: `PASS ip netns add/del works`) and `veth` pairs created inside namespaces.

---

## What this confirms

1. **BPF compilation with `__TARGET_ARCH_x86` produces a valid object on x86_64.**
   `bpf-verify` confirmed `vxlan_config` is present in the symbol table.

2. **All 6 scenarios pass on x86_64 kernel 6.8.0-1059-azure.**
   Including the previously ARM64-only scenarios (1–5) and the new port-8472 scenario (6).

3. **Port 8472 works correctly on x86_64.** `vxlan_port=8472` appears in the JSON output.
   The byte-order conversion `portNBO = (portHost >> 8) | (portHost << 8)` is correct on x86_64.

4. **Loader unit tests pass on x86_64 Linux.**
   `TestWriteVXLANPortToMapsMissing` and `TestWriteVXLANPortToMapsMissingPort0` both pass (0.003s).

5. **Fail-closed loader does not regress any of the 6 scenarios.**
   All binary invocations returned exit code 0.

---

## What this does NOT confirm

- Real CNI (k3s/flannel) on x86_64 — requires a two-node cluster.
- ip_do_fragment scoping to VXLAN-only traffic (still global on all kernels).
- Other x86_64 kernel versions (only 6.8.0-1059-azure tested here).
