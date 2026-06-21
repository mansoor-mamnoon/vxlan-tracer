# rc2 Package Qualification — Evidence

**Date:** 2026-06-21
**Version target:** v0.1.0-rc2 (not yet tagged)
**Status:** PARTIAL — build verification on macOS; Linux integration tests NOT RUN

---

## What changed from rc1 to rc2

| Change | Status |
|--------|--------|
| Attachment created before first mutation; partial clsact rollback fixed | Implemented |
| TC slot collision check: no auto-delete; fail with clear error | Implemented |
| Exact filter identity stored (handle, prio, name, progID) after FilterAdd | Implemented |
| Close() verifies identity before deleting; warns if identity changed | Implemented |
| Close() idempotent: second call is no-op | Implemented |
| `vxlan-tracer cleanup` subcommand for explicit stale-filter removal | Implemented |
| `VXLANCandidate.UnderlayInferred` bool field added to JSON | Implemented |
| `interfaces` column header changed from UNDERLAY to LIKELY UNDERLAY | Implemented |
| Inferred-underlay note added to `interfaces` output | Implemented |
| PTB_SUPPRESSED / PTB_DELIVERED human output updated for priority-50000 caveat | Implemented |
| TC priority observation limitation added to forbidden-claims.md, hook-model.md | Implemented |
| docs/forbidden-claims.md: claims 17 (TC priority) and 18 (GSO/GRO) added | Implemented |
| GSO/GRO verdict reliability table: VXLAN_FRAGMENTATION_OBSERVED now UNVALIDATED | Implemented |
| collect-support renamed to collect-environment; old name kept as alias | Implemented |
| evidence/rc2-collect-support.md: corrected to match actual implementation | Implemented |
| evidence/rc2-gso-gro-live.md: created, status NOT RUN | Implemented |
| loader_lifecycle_test.go: Linux integration test skeletons added | Implemented |
| Ownership-safe TC attachment (priority 50000, handle 0x7674) | Implemented (prior) |
| Concurrent-run lock (/run/vxlan-tracer.lock) | Implemented (prior) |
| `ensureClsact()` tracks pre-existing qdiscs | Implemented (prior) |
| `vxlan-tracer interfaces` subcommand | Implemented (prior) |
| `--keep-state` flag (skip cleanup) | Implemented (prior) |
| docs/tc-lifecycle-audit.md | Implemented (prior) |
| Verdict count corrected from five to six everywhere | Implemented (prior) |
| Overconfident cloud-drop claims corrected | Implemented (prior) |
| tcpdump claim in technical article corrected | Implemented (prior) |
| veth MTU claims in outreach corrected | Implemented (prior) |

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
| `vxlan-tracer collect-environment --dry-run` | PASS on macOS (outputs manifest, exit 0) |

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
| `collect-environment` Linux integration | Linux + root | Partial gate |
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
| Partial clsact rollback fixed | IMPLEMENTED (code review) |
| No auto-delete of stale filters; collision error on occupied slot | IMPLEMENTED (code review) |
| Exact filter identity stored (progID + name) | IMPLEMENTED (code review) |
| Cleanup verifies exact identity before deleting | IMPLEMENTED (code review) |
| Close() idempotent | IMPLEMENTED (code review) |
| TC coexistence test cases (lifecycle suite) | NOT RUN (Linux required) |
| Concurrent-run protection | IMPLEMENTED (flock) |
| interfaces: LIKELY UNDERLAY label + UnderlayInferred JSON field | IMPLEMENTED (code review) |
| PTB output wording: priority-50000 caveat | IMPLEMENTED (code review) |
| TC priority observation limitation in docs | IMPLEMENTED |
| GSO/GRO verdict table: no premature "unaffected" claims | IMPLEMENTED |
| GSO/GRO live tests | NOT RUN |
| collect-environment rename + evidence corrected | IMPLEMENTED |
| Six-verdict unit tests pass | PASS (macOS) |
| amd64 package smoke test | NOT RUN |
| arm64 package smoke test | NOT RUN |
| `interfaces` Linux validation | NOT RUN |
| k3s/Flannel two-node validation | NOT RUN |
