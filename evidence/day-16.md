# evidence/day-16.md

Day 16 — v0.1.0-rc1 release qualification.

All statements below reflect what was done on 2026-06-20. No results are fabricated.

---

## Commits

| Commit | Message | Key change |
|--------|---------|------------|
| 10c57ca | evidence: record completed Day 15 CI results | evidence/day-15*.md |
| 696acec | pkg: add inject_ptb.py and cleanup-bpf.sh to release archives | Makefile, scripts/ |
| 5320b72 | scripts: add test-release-package-isolation.sh | scripts/ |
| 7ec8723 | scripts: extend verify-release-archive.sh with stronger checks | scripts/ |
| 65c043f | docs: correct historical validation matrix | Makefile, evidence/ |
| 62af2f3 | ci: add packaged scenario runs and fix human-output bpffs setup | .github/workflows/ |
| bbce9bf | ci: fix PTB_SUPPRESSED topology and isolation test false positive | .github/workflows/, scripts/ |
| 8fbc6f7 | ci: fix PTB_SUPPRESSED human-output test setup | .github/workflows/ |
| be9b23e | fix combine-checksums artifact path; add package and human-output evidence | .github/workflows/, evidence/ |
| 913d08f | fix release-package artifact upload/download path mismatch | .github/workflows/ |

All commits pushed to origin/main.

---

## Problems found and fixed in Day 16

| Problem | Fix |
|---------|-----|
| inject_ptb.py absent from archives | Moved to scripts/; Makefile packages it; run-scenarios.sh updated |
| cleanup-bpf.sh absent from archives | Added to Makefile package target |
| run-scenarios.sh referenced spikes/inject_ptb.py | Updated to $(dirname "$0")/inject_ptb.py |
| human-output CI job: binary load failure (bpffs pin dir absent) | Added mkdir -p before binary runs |
| human-output CI job: [FAIL] didn't fail the job | Replaced echo with exit-1 assertions |
| PTB_SUPPRESSED test produced VXLAN_MTU_MISCONFIGURATION | Replaced custom topology with setup-netns.sh two-netns topology |
| Package isolation test false positive (inject_ptb.py docstring) | Checked only *.sh files; updated docstring |
| MANIFEST.txt: 6.10.14-linuxkit claimed 6/6 scenarios | Corrected to 5/5 (scenario 6 added after those runs) |
| evidence/day-15-demo.md: "Scenario 1" for fragmentation | Corrected to Scenario 2 |
| verify-release-archive.sh: missing deps and weak checks | Extended with arch/BPF-target/checksum/syntax checks |
| combine-checksums: artifact LCA broken by /tmp/ path in upload | Separated scenario log into distinct artifact; restored LCA to dist/release/ |

---

## Gate status

| Gate | Status | Evidence |
|------|--------|----------|
| inject_ptb.py in archive | PASS | CI 27860935576 verify-release-archive 25/25 |
| cleanup-bpf.sh in archive | PASS | CI 27860935576 verify-release-archive 25/25 |
| Package isolation test (amd64) | PASS | CI 27860935576 build-amd64: 32/32 PASS |
| Package isolation test (arm64) | PASS | CI 27860935576 build-arm64: 32/32 PASS |
| 6-scenario from amd64 packaged archive | PASS | CI 27860935576 build-amd64: Results: 6 passed, 0 failed |
| 6-scenario from arm64 packaged archive | PASS | CI 27860935576 build-arm64: Results: 6 passed, 0 failed |
| Human output: Verdict: captured live | PASS | CI 27860935585 human-output: [PASS] contains Verdict: |
| Human output: Evidence: captured live | PASS | CI 27860935585 human-output: [PASS] contains Evidence: |
| PTB_SUPPRESSED: Verdict: captured live | PASS | CI 27860935585 human-output: PTBs at TC ingress: 5, at icmp_rcv: 0 |
| Stale-object integration: 6 assertions PASS | PASS | CI 27860935585 bpf-scenario: Results: 6 passed, 0 failed |
| 6-scenario source-tree 6/6 PASS | PASS | CI 27860935585 bpf-scenario: Results: 6 passed, 0 failed |
| combine-checksums: all three jobs PASS | PASS | CI 27862917754: build-amd64 ✓ build-arm64 ✓ combine-checksums ✓ |
| Historical matrix corrected (linuxkit 5/5) | PASS | commit 65c043f |
| Demo scenario number corrected (→ Scenario 2) | PASS | commit 65c043f |
| VERSION=v0.1.0-rc1 in --version output | PASS | CI 27863179327 (workflow_dispatch version=v0.1.0-rc1): both arches produce vxlan-tracer v0.1.0-rc1 (commit 74cf2d7) |
| Demo: VXLAN_FRAGMENTATION_OBSERVED live | NOT DONE | requires Linux + make demo |
| Demo: global_corroborated live | NOT DONE | requires Linux + make demo |
| Demo: cleanup verified (no stale maps/filters) | NOT DONE | requires Linux + make demo |

---

## v0.1.0-rc1 release decision

### NOT READY FOR v0.1.0-rc1 TAG

**All package qualification gates are PASS.** Both archives are self-contained and run
correctly from extracted directories on their matching architectures. Human-readable
output (Verdict:/Evidence:/Recommendation:/Scope:) is confirmed live for
VXLAN_FRAGMENTATION_OBSERVED and PTB_SUPPRESSED.

**Remaining gates before tag:**

1. **Demo not run** — `make demo` has not been run on Linux. Scenario 2
   (VXLAN_FRAGMENTATION_OBSERVED with global_corroborated) must complete live.

VERSION=v0.1.0-rc1 is now confirmed: both amd64 and arm64 archives from CI 27863179327
(workflow_dispatch) report `vxlan-tracer v0.1.0-rc1 (commit 74cf2d7)`. All other gates
PASS. Only the live demo remains.

---

## Evidence files

- evidence/day-15.md (updated Day 16 — CI actuals recorded)
- evidence/day-15-stale-object-integration.md (updated Day 16 — CI actuals recorded)
- evidence/day-15-human-output.md (updated Day 16 — root cause documented)
- evidence/day-15-demo.md (Scenario 2 correction applied Day 16)
- evidence/day-16-amd64-package.md (PASS — CI 27860935576)
- evidence/day-16-arm64-package.md (PASS — CI 27860935576)
- evidence/day-16-human-output-live.md (PASS — CI 27860935585, both verdicts confirmed)
- evidence/day-16-demo-live.md (PENDING — not yet run)
- evidence/day-16.md (this file)
