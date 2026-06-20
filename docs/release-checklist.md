# Release readiness checklist

This checklist must be satisfied before tagging any release (v0.x or later).
All items must be individually verified and recorded in `evidence/`.

---

## BPF objects

- [ ] No stale BPF objects in the working directory (`ls bpf/*.bpf.o` or absent)
- [ ] `make clean-bpf && make bpf` produces a fresh compile with no errors
- [ ] `make bpf-verify` reports PASS (confirms `vxlan_config` symbol present)
- [ ] BPF object size is consistent with recent builds (regression guard)

## Go build and tests

- [x] `go vet ./...` passes with no warnings (macOS; Day 14/15)
- [ ] `go test ./...` passes on Linux (all packages; bpf-scenario CI job pending Day 15)
- [ ] `make build` produces a valid ELF binary
- [x] Binary links correctly with commit hash via -ldflags (Day 14)
- [x] `--version` prints version, commit, and buildDate fields (Day 14)

## Scenario suite

- [x] 6/6 scenarios pass on aarch64 5.15.0-181-generic (Day 12-13, Lima VM)
- [x] 6/6 scenarios pass on x86_64 6.8.0-1059-azure (Day 13, GitHub Actions run 27851298262)
- [x] Scenario 6 (port 8472): `vxlan_port=8472` confirmed in JSON on both archs (Day 12-13)
- [ ] `scripts/preflight.sh` passes with 0 FAIL on Day 15 CI run (pending)

## CI

- [x] `x86_64 validation suite` (restructured): unit-build + bpf-scenario jobs (Day 15 commit 10b40f6, pending)
- [ ] Day 15 CI run conclusion confirmed PASS (CI triggered 2026-06-19, pending)
- [x] BPF compile and `bpf-verify` steps confirmed PASS in prior Day 13 CI
- [x] Go unit tests confirmed PASS in prior Day 13 CI
- [x] Scenario runner: "Results: 6 passed, 0 failed" in Day 13 CI log

## Release package

- [x] `make package` hard-fails on missing BPF objects with clear error message (Day 15)
- [x] `make package` requires Linux and correctly rejects macOS (Day 15, verified)
- [x] Each archive includes MANIFEST.txt with version, commit, arch, BPF target, limitations (Day 15)
- [x] `scripts/verify-release-archive.sh` validates binary, 4 BPF objects, scripts, README, LICENSE, MANIFEST.txt (Day 15)
- [x] `package-rc1` convenience target added (Day 15)
- [ ] `VERSION=v0.1.0-rc1 make package` run on x86_64 Linux (CI in progress Day 15)
- [ ] `VERSION=v0.1.0-rc1 make package` run on aarch64 Linux (CI in progress Day 15)
- [x] `dist/release/checksums-<arch>.sha256` produced per-arch (Day 15)
- [ ] Both archives pass `verify-release-archive.sh` on native arch (CI in progress Day 15)
- [x] LICENSE file present (MIT, Copyright 2026 Mansoor Mamnoon) (Day 14)

## Human-readable output

- [x] `printHuman` added for all 5 verdicts (Day 14)
- [x] No misleading MTU recommendation for PTB paths (code review Day 14/15)
- [ ] Live human output captured for VXLAN_FRAGMENTATION_OBSERVED (CI in progress Day 15)
- [ ] Live human output captured for PTB_SUPPRESSED (CI in progress Day 15)

## Demo

- [x] `scripts/demo.sh` written; `make demo` target added (Day 14)
- [ ] `make demo` run end-to-end on Linux with VXLAN_FRAGMENTATION_OBSERVED result (not yet)

## Stale BPF object integration

- [x] `scripts/test-stale-bpf-object.sh` confirms 6/6 assertions PASS on x86_64 (Day 13 CI run 27851298262)
- [ ] Day 15 CI `bpf-scenario` job stale-object step confirmed (CI in progress)

## README and documentation

- [x] Status line accurately describes what is and is not proven (Day 14)
- [x] Port claim: "validated in netns lab on ports 4789 and 8472" (not "CNI validated")
- [x] Kernel matrix reflects actual runs with version and scenario count (Day 14)
- [x] CNI table is labeled documentation-based (not lab-validated)
- [x] No references to `VXLAN_HEALTHY`

## Forbidden claims review

- [x] docs/forbidden-claims.md reviewed; no violations in Day 14/15 commits
- [x] No "k3s validated", "flannel validated", or "CNI validated" claim
- [x] No XDP egress claim
- [x] No claim that ip_do_fragment is VXLAN-specific
- [x] No claim of packet loss from fragmentation events alone

## CNI status

- [x] README states: "Two-node k3s/flannel validation not complete" (Day 14)
- [x] docs/kubernetes-validation.md: two-node requirement documented
- [x] No cross-node pod traffic claim

---

## Post-release

After tagging, record in `evidence/`:
- Kernel(s) tested at release time
- Scenario results at release time
- `git log --oneline -10` at the release tag
- SHA-256 checksums of tagged archives
