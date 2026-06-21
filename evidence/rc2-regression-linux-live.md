# Linux Regression Suite Results — rc2 Evidence

**Date:** 2026-06-21
**Host:** Lima VM `vxlan-test` — Ubuntu 22.04.5 LTS, kernel 5.15.0-181-generic, aarch64
**Binary:** `vxlan-tracer dev` (built from source, 2026-06-21)

---

## `go test ./...` (non-root)

```
?   	github.com/mansoormmamnoon/vxlan-tracer/cmd/vxlan-tracer	[no test files]
ok  	github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap	(cached)
ok  	github.com/mansoormmamnoon/vxlan-tracer/internal/diag	(cached)
?   	github.com/mansoormmamnoon/vxlan-tracer/internal/output	[no test files]
?   	github.com/mansoormmamnoon/vxlan-tracer/spikes/probe_frag_scope	[no test files]
ok  	github.com/mansoormmamnoon/vxlan-tracer/internal/loader	0.002s
ok  	github.com/mansoormmamnoon/vxlan-tracer/internal/netlink	0.002s
?   	github.com/mansoormmamnoon/vxlan-tracer/spikes/probe_helper	[no test files]
```

All packages PASS. Loader and netlink tests pass on Linux kernel 5.15 without root
(root-required tests skip automatically when not root).

## `sudo go test -v -count=1 ./internal/loader/...`

```
=== RUN   TestPartialClsactRollback
--- PASS: TestPartialClsactRollback (0.03s)
=== RUN   TestDoubleCloseIdempotency
--- PASS: TestDoubleCloseIdempotency (0.02s)
=== RUN   TestCollisionDetection
--- PASS: TestCollisionDetection (0.02s)
=== RUN   TestReplacementFilterRace
--- PASS: TestReplacementFilterRace (0.03s)
=== RUN   TestWriteVXLANPortToMapsMissing
--- PASS: TestWriteVXLANPortToMapsMissing (0.00s)
=== RUN   TestWriteVXLANPortToMapsMissingPort0
--- PASS: TestWriteVXLANPortToMapsMissingPort0 (0.00s)
PASS
ok  	github.com/mansoormmamnoon/vxlan-tracer/internal/loader	0.096s
```

6/6 PASS with root.

---

## Six-scenario suite (`scripts/run-scenarios.sh`)

Setup: `sudo bash scripts/setup-netns.sh`
Run: `sudo BINARY=./vxlan-tracer BPF_DIR=./bpf PIN_DIR=/sys/fs/bpf/vt-scenarios bash scripts/run-scenarios.sh`

```
[preflight] OK: Linux 5.15.0-181-generic, root, binary=./vxlan-tracer, BPF_DIR=./bpf, BTF present

Scenario: healthy_small — Expected: VXLAN_MTU_MISCONFIGURATION
[PASS] verdict=VXLAN_MTU_MISCONFIGURATION

Scenario: fragmentation — Expected: VXLAN_FRAGMENTATION_OBSERVED
[PASS] verdict=VXLAN_FRAGMENTATION_OBSERVED

Scenario: ptb_delivered — Expected: PTB_DELIVERED
[PASS] verdict=PTB_DELIVERED

Scenario: ptb_suppressed — Expected: PTB_SUPPRESSED
[PASS] verdict=PTB_SUPPRESSED

Scenario: fragmentation (SECOND RUN — no teardown) — Expected: VXLAN_FRAGMENTATION_OBSERVED
[PASS] Second run: verdict=VXLAN_FRAGMENTATION_OBSERVED scope=global_corroborated

Scenario: ptb_delivered (port 8472) — Expected: PTB_DELIVERED vxlan_port=8472
[PASS] verdict=PTB_DELIVERED  vxlan_port=8472

Results: 6 passed, 0 failed
```

**All 6 scenarios PASS.** All verdict paths confirmed working on Linux 5.15, aarch64.

---

## Gate summary

| Test | Status |
|------|--------|
| `go test ./...` (Linux) | PASS |
| `sudo go test ./internal/loader/...` (Linux, root) | PASS (6/6) |
| VXLAN_MTU_MISCONFIGURATION scenario | PASS |
| VXLAN_FRAGMENTATION_OBSERVED scenario | PASS |
| PTB_DELIVERED scenario | PASS |
| PTB_SUPPRESSED scenario | PASS |
| VXLAN_FRAGMENTATION_OBSERVED (second run, no teardown) | PASS |
| PTB_DELIVERED (port 8472) | PASS |
