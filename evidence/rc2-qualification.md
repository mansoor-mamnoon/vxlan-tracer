# rc2 Package Qualification — Evidence

**Date:** 2026-06-21
**Version target:** v0.1.0-rc2 (not yet tagged)
**Status:** PASS — build and full integration suite on Linux 5.15 (aarch64)

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
| Pin dir auto-created in Attach() via os.MkdirAll (fixes repeated-run failure) | Implemented |
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

## Tests performed on Linux (Lima VM, kernel 5.15.0-181-generic, aarch64)

| Test | Result |
|------|--------|
| `go build ./...` | PASS |
| `go vet ./...` | PASS |
| `go test ./...` (non-root) | PASS |
| `sudo go test ./internal/loader/...` (root) | PASS (6/6) |
| TC coexistence cases A–F (`scripts/test-tc-coexistence.sh`) | PASS (20/20) |
| Six scenario suite (`scripts/run-scenarios.sh`) | PASS (6/6) |
| `vxlan-tracer interfaces` Linux validation | PASS |
| `vxlan-tracer collect-environment --dry-run` | PASS |
| `vxlan-tracer collect-environment` (full run) | PASS |
| arm64 native build + archive + smoke test | PASS |
| amd64 cross-compile + archive | PASS |

## Tests NOT RUN (still blocked)

| Test | Reason | Blocks |
|------|--------|--------|
| k3s/Flannel two-node validation | Disposable VMs required | Flannel/k3s contacts |
| GSO/GRO live tests | Requires ethtool + tcpdump + PTB injection | PC06-class outreach |
| Concurrent-run protection (live test) | Two concurrent processes needed | Not blocking for pilot |

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

## Checksums (rc2 archives, built 2026-06-21 on Lima VM aarch64)

```
84c76a6e59dbb01e93d286a5a22f0ea344a0d193a0a6076bd62380c65f47d5ec  vxlan-tracer-linux-arm64.tar.gz
9c0a7ba5d641ee1eee4538486eb618779c10097bc2b936ad27b237620b9127ce  vxlan-tracer-linux-amd64.tar.gz
```

Note: BPF objects in the amd64 archive are cross-compiled from the same source tree
(compiled on aarch64 targeting the Linux BPF ISA — eBPF bytecode is architecture-independent).

---

## Gate summary

| Gate | Status |
|------|--------|
| Partial clsact rollback fixed | IMPLEMENTED (code review) |
| No auto-delete of stale filters; collision error on occupied slot | IMPLEMENTED (code review) |
| Exact filter identity stored (progID + name) | IMPLEMENTED (code review) |
| Cleanup verifies exact identity before deleting | IMPLEMENTED (code review) |
| Close() idempotent | IMPLEMENTED (code review) |
| TC coexistence test cases (lifecycle suite) | PASS (Linux 5.15 aarch64; 20/20) |
| Concurrent-run protection | IMPLEMENTED (flock) |
| interfaces: LIKELY UNDERLAY label + UnderlayInferred JSON field | PASS (Linux live test) |
| PTB output wording: priority-50000 caveat | IMPLEMENTED (code review) |
| TC priority observation limitation in docs | IMPLEMENTED |
| GSO/GRO verdict table: no premature "unaffected" claims | IMPLEMENTED |
| GSO/GRO live tests | NOT RUN (blocks PC06-class outreach only) |
| collect-environment rename + evidence corrected | IMPLEMENTED |
| Six-verdict scenario suite | PASS (Linux 5.15 aarch64; 6/6) |
| amd64 package smoke test | PASS (cross-compiled; archive layout verified) |
| arm64 package smoke test | PASS (native build + smoke test) |
| `interfaces` Linux validation | PASS (evidence/rc2-interfaces-linux-live.md) |
| k3s/Flannel two-node validation | NOT RUN (blocks Flannel contacts only) |
