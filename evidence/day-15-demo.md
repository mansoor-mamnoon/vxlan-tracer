# evidence/day-15-demo.md

Record of `make demo` execution for v0.1.0-rc1 qualification.

---

## Demo definition

Script: `scripts/demo.sh`
Makefile target: `make demo`

What the demo does:
1. Creates two network namespaces (`demo-ns1`, `demo-ns2`)
2. Creates a veth pair (`demo-veth1` ↔ `demo-veth2`)
3. Creates VXLAN devices in each namespace (VNI 42, port 4789)
4. Sets overlay MTU 1450, underlay MTU 1400 (stale-MTU scenario)
5. Runs `vxlan-tracer --json --duration 15s` inside `demo-ns1`
6. Sends 5 large pings: `ping -c 5 -s 1360` (inner IP ~1388B → outer IP ~1438B > 1400B underlay)
7. Reports JSON output + human-readable summary
8. Cleans up all namespaces and pinned maps

Expected verdict: `VXLAN_FRAGMENTATION_OBSERVED`
Expected scope: `global_corroborated` (both ip_do_fragment and oversized outer packets observed)

Requirements: Linux, root, compiled binary (`dist/vxlan-tracer`), compiled BPF objects (`bpf/`)

---

## Day 15 CI status

The `make demo` command requires Linux + root + BPF objects compiled on the target arch.
It was not run as part of the restructured x86-smoke.yml CI jobs (which focus on the
6-scenario suite and human output). The demo is a user-facing validation tool, not a
CI requirement.

**Status at time of writing:** not yet run on Linux in this Day 15 session.

The demo script was written and committed in Day 14 (commit `3e034a4`). The scenario it
demonstrates (stale-MTU VXLAN fragmentation) is covered by the existing Scenario 1 in
`scripts/run-scenarios.sh`, which DOES run in CI and produces `VXLAN_FRAGMENTATION_OBSERVED`.

---

## Expected output (from script review and Scenario 1 CI evidence)

```
=== vxlan-tracer demo: VXLAN fragmentation detection ===

[setup] Creating namespaces and veth pair...
[setup] Creating VXLAN overlay (port 4789, VNI 42)...
[setup] Reducing underlay MTU to 1400 (vxlan0 stays at 1450 — stale MTU)...
[setup] Lab ready:
  vxlan0 MTU: 1450
  demo-veth1 MTU: 1400

[demo] Starting vxlan-tracer (15s window)...
[demo] Sending large traffic (inner IP ~1388 B → outer IP ~1438 B > 1400 B underlay)...
[demo] Waiting for vxlan-tracer to finish...

=== Result ===

JSON output:
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "message": "...",
  "fragmentation_scope": "global_corroborated",
  "overlay": "vxlan0",
  "underlay": "demo-veth1",
  "vxlan_port": 4789,
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 0,
  "icmp_rcv_total": 0,
  "frag_events_total": <N>,
  "max_outer_ip_len": 1438
}

Summary:
  Verdict:                VXLAN_FRAGMENTATION_OBSERVED
  ip_do_fragment events:  <N>
  Largest outer IP seen:  1438 B
  Underlay MTU:           1400 B
  Recommended overlay MTU: 1350 B (= underlay − 50)

  DEMO PASSED: vxlan-tracer correctly identified VXLAN fragmentation.
  ...

=== vxlan-tracer demo complete ===
```

---

## What is proven

- Scenario 1 (stale-MTU fragmentation) produces `VXLAN_FRAGMENTATION_OBSERVED` in 6/6 CI runs
  (Days 7-13). The demo replicates exactly this scenario.
- Script logic reviewed: cleanup trap correctly removes namespaces, demo-veth1, and PIN_DIR.
- Demo verified to compile and pass `go vet` (macOS).

## What remains unproven

- `make demo` not run end-to-end in Day 15 session (requires Linux + BPF objects)
- Cleanup verification (no demo namespaces, no TC filters, no stale maps) not performed live
- JSON output field values (frag_events_total, timing) not captured from a live run
- Human-readable summary output not captured live
