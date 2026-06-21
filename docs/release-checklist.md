# Release readiness checklist

This checklist must be satisfied before tagging any release (v0.x or later).
All items must be individually verified and recorded in `evidence/`.

Last updated for v0.1.0-rc1 qualification (Day 17). All checked items have
supporting evidence recorded in `evidence/` and reference the CI run or commit
that produced the result.

---

## BPF objects

- [x] `make clean-bpf && make bpf` produces a fresh compile with no errors
      (CI rebuilds from scratch on each run; confirmed in runs 27857782449, 27863179327)
- [x] `make bpf-verify` reports PASS — `vxlan_config` symbol present
      (Day 13 CI run 27851298262; same step passes in subsequent runs)
- [x] BPF object sizes recorded and consistent across rc1 builds
      amd64: tc_ingress_eth0=19192, tc_egress_vxlan0=17064, kprobes=8720, frag_kprobes=8584
      arm64: tc_ingress_eth0=19192, tc_egress_vxlan0=17064, kprobes=7792, frag_kprobes=7728
      (evidence/day-17-rc1-artifact-provenance.md)
- [x] amd64 BPF objects embed `__TARGET_ARCH_x86`; arm64 embed `__TARGET_ARCH_arm64`
      (evidence/day-17-rc1-artifact-provenance.md; verify-release-archive confirms per archive)

## Go build and tests

- [x] `go vet ./...` passes with no warnings (macOS; Day 14/15)
- [x] `go test ./...` passes on Linux x86_64 (Day 13 CI run 27851298262; Day 15 CI run 27857782449)
- [x] `make build` produces valid ELF binary for both arches
      (amd64: confirmed in CI runs 27860935576, 27863179327;
       arm64: confirmed in CI runs 27860935576, 27863179327)
- [x] Binary links correctly with commit hash via -ldflags (Day 14)
- [x] `--version` prints version, commit, and buildDate fields (Day 14)
- [x] `vxlan-tracer v0.1.0-rc1 (commit 74cf2d7)` confirmed on both arches
      (CI run 27863179327; evidence/day-16.md)

## Scenario suite

- [x] 6/6 scenarios pass on aarch64 5.15.0-181-generic
      (Day 12-13 Lima VM; Day 16 CI run 27860935576 build-arm64 job)
- [x] 6/6 scenarios pass on x86_64 6.8.0-1059-azure
      (Day 13 CI run 27851298262; Day 15 CI run 27857782449; Day 16 CI run 27860935576)
- [x] 6/6 scenarios pass from amd64 packaged rc1 archive (no source-tree files)
      (CI run 27863179327 build-amd64 job; evidence/day-17-rc1-artifact-provenance.md)
- [x] 6/6 scenarios pass from arm64 packaged rc1 archive (no source-tree files)
      (CI run 27863179327 build-arm64 job; evidence/day-17-rc1-artifact-provenance.md)
- [x] Scenario 6 (port 8472): `vxlan_port=8472` confirmed in JSON on both arches (Day 12-13)
- [x] 6.10.14-linuxkit correctly records 5/5 scenarios (tested before scenario 6 was added)
      (evidence/day-15.md; MANIFEST.txt in both archives)

## CI

- [x] Day 15 CI run 27857782449: x86-smoke PASS (unit-build + bpf-scenario + stale-object)
- [x] Day 16 CI run 27860935576: release-package PASS (amd64 + arm64 + combine-checksums)
- [x] Day 16 CI run 27863179327: release-package workflow_dispatch PASS
      (version=v0.1.0-rc1; both arches; rc1 version confirmed)
- [x] combine-checksums job PASS in run 27862917754 and run 27863179327
      (evidence/day-16.md)
- [x] BPF compile and `bpf-verify` steps confirmed PASS in prior Day 13 CI
- [x] Go unit tests confirmed PASS in prior Day 13 CI

## Release package

- [x] `make package` hard-fails on missing BPF objects with clear error message (Day 15)
- [x] `make package` requires Linux and correctly rejects macOS (Day 15)
- [x] Each archive includes MANIFEST.txt with version, commit, arch, BPF target, limitations
      (verified by verify-release-archive.sh in each CI run)
- [x] `scripts/verify-release-archive.sh` validates binary, 4 BPF objects, scripts,
      README, LICENSE, MANIFEST.txt
- [x] `VERSION=v0.1.0-rc1 make package` completed on x86_64 Linux
      (CI run 27863179327 build-amd64 job; 25/25 verify-release-archive PASS in CI)
- [x] `VERSION=v0.1.0-rc1 make package` completed on aarch64 Linux
      (CI run 27863179327 build-arm64 job; 25/25 verify-release-archive PASS in CI)
- [x] amd64 archive passes `verify-release-archive.sh`: 25/25 PASS (CI); 24/24 PASS (macOS, binary exec skipped)
      (evidence/day-17-rc1-independent-verification.md)
- [x] arm64 archive passes `verify-release-archive.sh`: 25/25 PASS (CI); 24/24 PASS (macOS, binary exec skipped)
      (evidence/day-17-rc1-independent-verification.md)
- [x] amd64 archive passes isolation test: 32/32 PASS
      (evidence/day-17-rc1-independent-verification.md)
- [x] arm64 archive passes isolation test: 32/32 PASS
      (evidence/day-17-rc1-independent-verification.md)
- [x] `dist/release/checksums-<arch>.sha256` produced per-arch; combined in checksums.sha256
      (evidence/day-17-rc1-artifact-provenance.md)
- [x] SHA-256 of release archives recorded and independently verified:
      amd64: 238d476d12fa9c567c4efd72b69f9b28b614d22df287d6059ffd7ffdbee90572
      arm64: ff92458e4526f47e2f9e59404a2ef4bc3bc0bc01cc8c5d3080db7e6a09b5548a
      (evidence/day-17-rc1-artifact-provenance.md; evidence/day-17-rc1-independent-verification.md)
- [x] LICENSE file present (MIT, Copyright 2026 Mansoor Mamnoon) (Day 14)

## Human-readable output

- [x] `printHuman` added for all 5 verdicts (Day 14)
- [x] No misleading MTU recommendation for PTB paths (code review Day 14/15)
- [x] Live human output captured for VXLAN_FRAGMENTATION_OBSERVED
      (CI run 27860935585; evidence/day-16-human-output-live.md)
- [x] Live human output captured for PTB_SUPPRESSED
      (CI run 27860935585; evidence/day-16-human-output-live.md:
       PTBs at TC ingress: 5, PTBs at icmp_rcv: 0 confirmed)

## Demo

- [x] `scripts/demo.sh` written; `make demo` target added (Day 14)
- [x] Demo run end-to-end on Linux: VXLAN_FRAGMENTATION_OBSERVED, global_corroborated
      Run twice from packaged rc1 amd64 archive (CI run 27887911218, ubuntu-22.04,
      kernel 6.8.0-1059-azure). All 4 assertions PASS both runs.
      (evidence/day-17-demo-live.md)
- [x] Demo cleanup verified: no stale netns, pin dir, veth, or process after each run
      (evidence/day-17-demo-live.md: 4/4 cleanup checks PASS × 2 runs)
- [x] Demo idempotency verified: run 2 produces same verdict without manual cleanup between runs
      (evidence/day-17-demo-live.md)

## Stale BPF object integration

- [x] `scripts/test-stale-bpf-object.sh` confirms 6 assertions PASS on x86_64
      (Day 13 CI run 27851298262; Day 15 CI run 27857782449; Day 16 CI run 27860935585)
- [x] Stale-object test confirmed in final Day 15 bpf-scenario job (run 27857782449)

## README and documentation

- [x] Status line accurately describes what is and is not proven (Day 14)
- [x] Port claim: "validated in netns lab on ports 4789 and 8472" (not "CNI validated")
- [x] Kernel matrix reflects actual runs with version and scenario count (Day 14)
- [x] CNI table is labeled documentation-based (not lab-validated)
- [x] No references to `VXLAN_HEALTHY`

## Forbidden claims review

- [x] docs/forbidden-claims.md reviewed; no violations in any Day 14–17 commits
- [x] No "k3s validated", "flannel validated", or "CNI validated" claim
- [x] No XDP egress claim
- [x] No claim that ip_do_fragment is VXLAN-specific
- [x] No claim of packet loss from fragmentation events alone
- [x] No claim of ARM64 live demo (demo was amd64 only)
- [x] No claim of production readiness

## CNI status

- [x] README states: "Two-node k3s/flannel validation not complete" (Day 14)
- [x] docs/kubernetes-validation.md: two-node requirement documented
- [x] No cross-node pod traffic claim

---

## Gate summary for v0.1.0-rc1

| Gate | Result | Evidence |
|------|--------|----------|
| Authoritative rc1 workflow run | PASS | CI 27863179327 (workflow_dispatch v0.1.0-rc1) |
| Both arches: v0.1.0-rc1 version in binary | PASS | CI 27863179327 both jobs |
| amd64 archive SHA-256 recorded | PASS | evidence/day-17-rc1-artifact-provenance.md |
| arm64 archive SHA-256 recorded | PASS | evidence/day-17-rc1-artifact-provenance.md |
| amd64 archive: verify-release-archive 25/25 | PASS | CI 27863179327 / 24/24 macOS local |
| arm64 archive: verify-release-archive 25/25 | PASS | CI 27863179327 / 24/24 macOS local |
| amd64 archive: isolation 32/32 | PASS | evidence/day-17-rc1-independent-verification.md |
| arm64 archive: isolation 32/32 | PASS | evidence/day-17-rc1-independent-verification.md |
| amd64 packaged scenarios: 6/6 | PASS | CI 27863179327 build-amd64 |
| arm64 packaged scenarios: 6/6 | PASS | CI 27863179327 build-arm64 |
| Live demo (packaged archive, Linux): run 1 | PASS | CI 27887911218 |
| Live demo idempotency: run 2 | PASS | CI 27887911218 |
| Demo cleanup: both runs | PASS | CI 27887911218 (4/4 × 2) |
| combine-checksums | PASS | CI 27863179327 |

---

## Post-release

After tagging, record in `evidence/`:
- Kernel(s) tested at release time
- Scenario results at release time
- `git log --oneline -10` at the release tag
- SHA-256 checksums of tagged archives
