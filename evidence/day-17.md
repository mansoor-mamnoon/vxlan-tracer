# evidence/day-17.md — Day 17: Final v0.1.0-rc1 qualification

Date: 2026-06-20 (Days 17 session)
Purpose: Complete final v0.1.0-rc1 qualification using one authoritative artifact set and run the live demo.

---

## Work completed

### Commit 1 (19ef405): RC1 CI audit
Audited workflow run 27863179327 (workflow_dispatch, version=v0.1.0-rc1, commit 74cf2d7).
All required jobs and qualification steps confirmed PASS in a single run:
build-amd64, build-arm64, combine-checksums (3 jobs); within each build job:
verify-release-archive, isolation test, 6-scenario suite per arch.
Evidence: evidence/day-17-rc1-audit.md

### Commit 2 (a91952e): Artifact provenance record
SHA-256 checksums recorded from CI output:
  amd64: 238d476d12fa9c567c4efd72b69f9b28b614d22df287d6059ffd7ffdbee90572
  arm64: ff92458e4526f47e2f9e59404a2ef4bc3bc0bc01cc8c5d3080db7e6a09b5548a
BPF object sizes, binary --version, build environment documented.
Evidence: evidence/day-17-rc1-artifact-provenance.md

### Commit 3 (b71c4df): Independent verification
Archives downloaded locally via `gh run download 27863179327`.
SHA-256 verified locally (both match CI).
verify-release-archive.sh: 24/24 PASS both arches (binary exec skipped on macOS).
test-release-package-isolation.sh: 32/32 PASS both arches.
No local rebuild. Evidence: evidence/day-17-rc1-independent-verification.md

### Commits 4–6 (4e174ee): Live demo
CI run 27887911218, ubuntu-22.04, kernel 6.8.0-1059-azure, x86_64.
Demo run from packaged rc1 amd64 archive (not source tree).
Run 1: verdict=VXLAN_FRAGMENTATION_OBSERVED, fragmentation_scope=global_corroborated,
        max_outer_ip_len=1438 > underlay_mtu=1400, recommended_overlay_mtu=1350
Run 2 (idempotency): same verdict, same scope. No stale state.
Cleanup after each run: 4/4 checks PASS (netns, pin dir, veth, process).
Evidence: evidence/day-17-demo-live.md

### Commits 7–9 (abba841, ac33bd1, 2ec3f61): Documentation
- Evidence labels corrected (dev vs rc1 distinction, stale-object assertion wording)
- Release checklist updated with all PASS/FAIL results and CI run references
- Release notes written (docs/v0.1.0-rc1-release-notes.md)

---

## Gate summary

| Gate | Result | Evidence |
|------|--------|----------|
| Authoritative rc1 workflow run (27863179327) | PASS | evidence/day-17-rc1-audit.md |
| Both arches: version=v0.1.0-rc1 (commit 74cf2d7) | PASS | CI 27863179327 |
| amd64 archive SHA-256 recorded and independently verified | PASS | day-17-rc1-artifact-provenance.md, day-17-rc1-independent-verification.md |
| arm64 archive SHA-256 recorded and independently verified | PASS | day-17-rc1-artifact-provenance.md, day-17-rc1-independent-verification.md |
| amd64 verify-release-archive: 25/25 (CI); 24/24 (macOS, binary exec skipped) | PASS | day-17-rc1-independent-verification.md |
| arm64 verify-release-archive: 25/25 (CI); 24/24 (macOS, binary exec skipped) | PASS | day-17-rc1-independent-verification.md |
| amd64 isolation test: 32/32 | PASS | day-17-rc1-independent-verification.md |
| arm64 isolation test: 32/32 | PASS | day-17-rc1-independent-verification.md |
| amd64 packaged 6-scenario suite | PASS (6/6) | day-17-rc1-artifact-provenance.md |
| arm64 packaged 6-scenario suite | PASS (6/6) | day-17-rc1-artifact-provenance.md |
| Live demo from packaged amd64 archive: run 1 | PASS | day-17-demo-live.md |
| Live demo: run 2 (idempotency) | PASS | day-17-demo-live.md |
| Demo cleanup: both runs (4/4 checks × 2) | PASS | day-17-demo-live.md |
| combine-checksums | PASS | CI 27863179327 |
| Human output (VXLAN_FRAGMENTATION_OBSERVED, PTB_SUPPRESSED) | PASS | day-16-human-output-live.md |
| Stale-object integration: 6 assertions | PASS | day-15-stale-object-integration.md |

No remaining release-blocking inconsistencies. No stale labels or fabricated results.

---

## Qualification decision

### READY FOR v0.1.0-rc1 TAG

All qualifying conditions are met:

1. A single authoritative workflow run (27863179327) produced both release archives
   with `vxlan-tracer v0.1.0-rc1 (commit 74cf2d7)`.

2. The exact rc1 archives — and no other archives — passed all structural, isolation,
   and scenario gates:
   - verify-release-archive: 25/25 PASS per arch
   - isolation test: 32/32 PASS per arch
   - packaged 6-scenario suite: 6/6 PASS per arch

3. SHA-256 checksums are recorded in evidence and verified from two sources
   (CI output and local `shasum -a 256`).

4. The live demo (`scripts/demo.sh`) ran twice end-to-end from the packaged amd64
   archive on a Linux host (CI run 27887911218). Both runs produced
   `VXLAN_FRAGMENTATION_OBSERVED` with `fragmentation_scope=global_corroborated`.
   All 4 assertions and all 4 cleanup checks passed both times.

5. Human-readable output is confirmed for VXLAN_FRAGMENTATION_OBSERVED and
   PTB_SUPPRESSED (evidence/day-16-human-output-live.md).

6. No forbidden claims: no claim of production readiness, all-kernel compatibility,
   cloud-fragment loss confirmation, or Kubernetes validation.

Known unfinished items (not rc1 blocking):
- ARM64 live demo not run (arm64 archive passed all package gates; live demo is amd64 only)
- Real Kubernetes/CNI validation not done (documented V1 milestone)
- `--version` shows `built unknown` instead of a build timestamp (non-blocking cosmetic issue)
