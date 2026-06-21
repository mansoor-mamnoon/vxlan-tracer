# rc2 Package Qualification — Evidence

**Date:** 2026-06-21
**Version target:** v0.1.0-rc2 (not yet tagged)
**Status:** PARTIAL — build verification on macOS; Linux integration tests NOT RUN

---

## What changed from rc1 to rc2

| Change | Status |
|--------|--------|
| Ownership-safe TC attachment (priority 50000, handle 0x7674) | Implemented |
| Deterministic cleanup (TC filters, maps, qdiscs, lock) | Implemented |
| Concurrent-run lock (/run/vxlan-tracer.lock) | Implemented |
| Filter name reflects actual interface name | Implemented |
| `ensureClsact()` tracks pre-existing qdiscs | Implemented |
| `vxlan-tracer interfaces` subcommand | Implemented |
| `vxlan-tracer collect-support` subcommand (static) | Implemented |
| `--keep-state` flag (skip cleanup) | Implemented |
| GitHub issue templates | Implemented |
| README "Looking for design partners" section | Implemented |
| docs/tc-lifecycle-audit.md | Implemented |
| docs/gso-gro-limitations.md | Implemented |
| Verdict count corrected from five to six everywhere | Implemented |
| Overconfident cloud-drop claims corrected | Implemented |
| tcpdump claim in technical article corrected | Implemented |
| veth MTU claims in outreach corrected | Implemented |
| Demo recording plan updated for netns usage | Implemented |
| Preflight.sh: scapy demoted from FAIL to WARN | Implemented |

---

## Build verification (macOS build host)

```
$ go build ./...
(no output — success)

$ go vet ./...
(no output — success)

$ bash -n scripts/test-tc-coexistence.sh
(no output — syntax OK)

$ bash -n scripts/preflight.sh
(no output — syntax OK)
```

**Result:** All Go packages build and pass vet on macOS. Shell scripts pass syntax check.

---

## Tests performed on macOS

| Test | Result |
|------|--------|
| `go build ./...` | PASS |
| `go vet ./...` | PASS |
| `go test ./internal/diag/...` | PASS (unit tests, no Linux required) |
| `go test ./internal/netlink/...` | PASS on macOS (non-Linux stubs return error; no panic) |
| `bash -n scripts/test-tc-coexistence.sh` | PASS (syntax only) |
| `vxlan-tracer --version` | PASS (outputs version/commit/date) |
| `vxlan-tracer interfaces --json` | PASS on macOS (returns error, exit 2, no crash) |
| `vxlan-tracer collect-support --dry-run` | PASS on macOS (outputs manifest, exit 0) |

---

## Tests NOT RUN (Linux required)

| Test | Reason | Gate? |
|------|--------|-------|
| TC coexistence cases A–F (`scripts/test-tc-coexistence.sh`) | Linux + root + BPF | YES — external CNI outreach |
| Six scenario suite (`scripts/run-scenarios.sh`) | Linux + root + BPF | YES — public release |
| `vxlan-tracer interfaces` 10-case Linux validation | Linux + rtnetlink | YES — external outreach |
| amd64 cross-compile and package smoke test | Linux binary test | YES — public release |
| arm64 cross-compile and package smoke test | Linux binary test | YES — public release |
| k3s/Flannel two-node validation | Disposable VMs | YES — Flannel/k3s outreach |
| `collect-support` Linux integration | Linux + root | Partial gate |
| Preflight script Linux run | Linux | Informational |

---

## Architecture build matrix target

rc2 must produce these archive layouts (same as rc1, matching `Makefile`):

```
vxlan-tracer-linux-amd64.tar.gz
└── vxlan-tracer-linux-amd64/
    ├── vxlan-tracer          (amd64 binary)
    ├── bpf/
    │   ├── tc_ingress_eth0.bpf.o
    │   ├── tc_egress_vxlan0.bpf.o
    │   ├── kprobes.bpf.o
    │   └── frag_kprobes.bpf.o
    ├── scripts/
    │   ├── preflight.sh
    │   ├── setup-netns.sh
    │   ├── teardown-netns.sh
    │   ├── run-scenarios.sh
    │   ├── demo.sh
    │   └── test-tc-coexistence.sh     ← NEW in rc2
    └── docs/
        ├── tc-lifecycle-audit.md      ← NEW in rc2
        └── gso-gro-limitations.md    ← NEW in rc2

vxlan-tracer-linux-arm64.tar.gz       (same layout, arm64 binary + arm64 BPF objects)
```

---

## Checksums

Not yet computed. Will be added after Linux build + package run.

---

## Gate summary

| Gate | Status |
|------|--------|
| No deletion of unrelated TC filters | IMPLEMENTED (code review) |
| Cleanup removes owned filters on exit | IMPLEMENTED (code review) |
| Cleanup removes owned filters on SIGINT/SIGTERM | IMPLEMENTED (signal handler calls Close()) |
| Failed attach leaves no TC state | IMPLEMENTED (Close() safe at any stage) |
| Concurrent-run protection | IMPLEMENTED (flock) |
| TC coexistence test cases A–F | NOT RUN (Linux required) |
| Six-verdict unit tests pass | PASS (macOS) |
| amd64 package smoke test | NOT RUN |
| arm64 package smoke test | NOT RUN |
| `interfaces` Linux validation (10 cases) | NOT RUN |
| `collect-support` Linux integration | NOT RUN (partial) |
| k3s/Flannel two-node validation | NOT RUN |
| Public claims audit | DONE (rc2 commits) |
| GSO/GRO documented | DONE (docs/gso-gro-limitations.md) |
