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

All commits pushed to origin/main. CI runs triggered: 27859148302 (x86-smoke), 27859148301 (release-package).

---

## Problems found and fixed in Day 16

| Problem | Fix |
|---------|-----|
| inject_ptb.py absent from archives | Moved to scripts/; Makefile packages it; run-scenarios.sh updated |
| cleanup-bpf.sh absent from archives | Added to Makefile package target |
| run-scenarios.sh referenced spikes/inject_ptb.py | Updated to $(dirname "$0")/inject_ptb.py |
| human-output CI job: binary load failure (bpffs pin dir absent) | Added mkdir -p before binary runs |
| human-output CI job: [FAIL] didn't fail the job | Replaced echo with exit-1 assertions |
| MANIFEST.txt: 6.10.14-linuxkit claimed 6/6 scenarios | Corrected to 5/5 (scenario 6 was added after those runs) |
| evidence/day-15-demo.md: "Scenario 1" for fragmentation | Corrected to Scenario 2 |
| verify-release-archive.sh: missing deps and weak checks | Extended with arch/BPF-target/checksum/syntax checks |

---

## Gate status

CI runs 27859148301 and 27859148302 triggered 2026-06-20T03:42Z.

| Gate | Status | Evidence |
|------|--------|----------|
| inject_ptb.py in archive | PENDING CI | commit 696acec; run 27859148301 |
| cleanup-bpf.sh in archive | PENDING CI | commit 696acec; run 27859148301 |
| Package isolation test (amd64) | PENDING CI | run 27859148301 build-amd64 |
| Package isolation test (arm64) | PENDING CI | run 27859148301 build-arm64 |
| 6-scenario from amd64 packaged archive | PENDING CI | run 27859148301 build-amd64 |
| 6-scenario from arm64 packaged archive | PENDING CI | run 27859148301 build-arm64 |
| Human output: Verdict: captured live | PENDING CI | run 27859148302 human-output job |
| Human output: Evidence: captured live | PENDING CI | run 27859148302 human-output job |
| VERSION=v0.1.0-rc1 in --version output | NOT DONE | requires workflow_dispatch with version=v0.1.0-rc1 |
| Demo: VXLAN_FRAGMENTATION_OBSERVED live | NOT DONE | requires Linux + demo run |
| Demo: global_corroborated live | NOT DONE | requires Linux + demo run |
| Demo: cleanup verified (no stale maps/filters) | NOT DONE | requires Linux + demo run |
| Stale-object 6/6 PASS (Day 16 CI) | PENDING CI | run 27859148302 bpf-scenario job |
| 6-scenario source-tree 6/6 PASS (Day 16 CI) | PENDING CI | run 27859148302 bpf-scenario job |
| Historical matrix corrected (linuxkit 5/5) | PASS | commit 65c043f |
| Demo scenario number corrected (→ Scenario 2) | PASS | commit 65c043f |

---

## v0.1.0-rc1 release decision

### NOT READY FOR v0.1.0-rc1 TAG

**Gates not yet passed:**

1. **Packaged scenario run not confirmed** — the CI step added in commit 62af2f3
   runs scenarios from extracted archive, but CI is in progress. If it fails, the
   archive still cannot be used standalone.

2. **Human output not confirmed** — the bpffs fix was applied in commit 62af2f3.
   Whether the binary now loads correctly and produces Verdict:/Evidence: output is
   pending CI run 27859148302.

3. **VERSION=v0.1.0-rc1 not used** — current CI uses VERSION=dev. The release
   workflow supports `workflow_dispatch` with a `version` input; this must be
   triggered manually with `version=v0.1.0-rc1` to produce correctly versioned archives.

4. **Demo not run** — `make demo` has not been run on Linux. Pending.

**What would change the decision to READY:**

- CI run 27859148301 build-amd64 and build-arm64: both "Run 6-scenario suite from
  packaged archive" steps PASS with "Results: 6 passed, 0 failed"
- CI run 27859148302 human-output job: both [PASS] for Verdict: and [PASS] for Evidence:
- Manual workflow_dispatch with version=v0.1.0-rc1 produces archives with correct
  --version output
- `make demo` run on Linux with VXLAN_FRAGMENTATION_OBSERVED and global_corroborated

---

## Evidence files

- evidence/day-15.md (updated Day 16)
- evidence/day-15-stale-object-integration.md (updated Day 16)
- evidence/day-15-human-output.md (updated Day 16)
- evidence/day-15-demo.md (Scenario 2 correction applied Day 16)
- evidence/day-16-amd64-package.md (PENDING — to be written after CI)
- evidence/day-16-arm64-package.md (PENDING — to be written after CI)
- evidence/day-16-demo-live.md (PENDING — to be written after demo run)
- evidence/day-16-human-output-live.md (PENDING — to be written after CI)
- evidence/day-16.md (this file)
