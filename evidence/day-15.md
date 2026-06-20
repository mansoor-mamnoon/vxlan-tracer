# evidence/day-15.md

Day 15 — v0.1.0-rc1 artifact qualification.

All statements below reflect what was done on 2026-06-19. No results are fabricated.

---

## Commits

| Commit | Message | Key change |
|--------|---------|------------|
| f9530b7 | build: hard-fail make package on missing BPF objects | Makefile + verify-release-archive.sh |
| ec8e2a4 | ci: add release-package.yml with amd64+arm64 build matrix | .github/workflows/release-package.yml |
| 9dabe2b | feat: archive verification includes binary --version check | verify-release-archive.sh + release-package.yml |
| 10b40f6 | ci: restructure x86-smoke.yml into three separated jobs | .github/workflows/x86-smoke.yml |
| 3dc7642 | evidence: day-15-stale-object-integration.md | evidence/ |
| 4e81b16 | evidence: day-15-demo.md and day-15-human-output.md | evidence/ |
| cd56a1d | build+evidence: package-rc1 target + smoke test evidence files | Makefile + evidence/ |
| (this)  | docs: Day 15 synthesis | evidence/ + docs/ |

All commits pushed to origin/main. CI triggered by push to bc37c9b..HEAD.

---

## Gate status: PASS / FAIL / PENDING

| Gate | Status | Evidence |
|------|--------|----------|
| Latest CI run | PENDING | CI triggered 2026-06-19, run in progress |
| Stale ELF integration test | PASS (prior) | Day 13 CI run 27851298262, x86_64 6.8.0-1059-azure |
| Day 15 stale-object step | PENDING | bpf-scenario job artifact stale-bpf-test.log |
| Deterministic demo | PENDING | make demo requires Linux; not run Day 15 |
| Live human output | PENDING | human-output CI job artifacts |
| 6-scenario source-tree suite | PASS (prior) | Day 13 CI run 27851298262, 6/6 PASS |
| Day 15 6-scenario step | PENDING | bpf-scenario job artifact scenario-results.log |
| amd64 archive completeness | PENDING | release-package.yml build-amd64 job |
| arm64 archive completeness | PENDING | release-package.yml build-arm64 job |
| amd64 packaged smoke test | PENDING | No CI step yet for scenario-from-archive |
| arm64 packaged smoke test | PENDING | ubuntu-22.04-arm runner availability unknown |
| v0.1.0-rc1 version metadata | PENDING | package-rc1 requires Linux CI |
| SHA-256 verification | PENDING | combine-checksums job |

**Currently proven:**
- `go vet ./...` passes on macOS (all Day 14/15 code)
- `go test ./...` passes on macOS (unit tests)
- `make package` hard-fails on missing BPF objects (verified macOS)
- `make package` correctly rejects non-Linux host (verified macOS, correct error + guidance)
- `make package-rc1` delegates correctly (verified macOS, correct error)
- verify-release-archive.sh written and exits with clear pass/fail
- CI workflows written: release-package.yml (new), x86-smoke.yml (restructured)
- All 5 verdict paths covered in printHuman (code review)
- No misleading MTU recommendation for PTB paths (code review)
- MANIFEST.txt generated with correct fields (code review + macOS build test)

**Not yet proven in Day 15 (requires CI/Linux):**
- Architecture-correct BPF objects in release archives
- verify-release-archive.sh PASS on amd64 archive
- verify-release-archive.sh PASS on arm64 archive
- `./vxlan-tracer --version` from extracted v0.1.0-rc1 package
- Live human output (Verdict: + Evidence: sections) from actual binary run
- `make demo` end-to-end (setup, traffic, verdict, cleanup)
- Day 15 CI run conclusion

---

## v0.1.0-rc1 release decision

### NOT READY FOR v0.1.0-rc1 TAG

**Required gates not yet passed:**

1. **amd64 archive completeness** — release-package.yml CI must confirm the archive
   contains all 4 BPF objects compiled with `__TARGET_ARCH_x86`. CI in progress.

2. **arm64 archive completeness** — requires ubuntu-22.04-arm runner (availability
   unconfirmed for this repository). If arm64 CI is unavailable, the arm64 archive
   can be built on the Lima VM (aarch64) using `make package-rc1`.

3. **Packaged binary smoke test** — neither archive has been extracted and used to
   run even one scenario on the matching architecture. This is a hard requirement:
   the packaged binary + packaged BPF objects must work together, not just the
   source-tree binary with source-tree BPF objects.

4. **Demo not run** — `make demo` has not completed on Linux in Day 15.

5. **Human output not captured live** — the human-output CI job may produce evidence,
   but that job runs on the same CI that is still in progress.

**What would change the decision to READY:**

- CI run completes with all three x86-smoke.yml jobs PASS
- release-package.yml build-amd64 job PASS (archive verified, --version confirmed)
- release-package.yml build-arm64 job PASS or Lima VM package built and verified
- At least one scenario run from the extracted amd64 archive on x86_64 Linux
- At least one scenario run from the extracted arm64 archive on aarch64 Linux
- `make demo` completed with `VXLAN_FRAGMENTATION_OBSERVED` verdict

Two-node Kubernetes validation remains out of scope for rc1 and must remain listed
as unproven.

---

## Day 16 recommendation

1. Check CI run results for commit 10b40f6 / 9dabe2b push
2. If release-package.yml arm64 job fails (runner unavailable): build arm64 package
   on Lima VM using `make package-rc1`, verify with `verify-release-archive.sh`
3. Extract each archive and run at minimum: `--version`, `preflight.sh`, one scenario
4. Update this file with CI run IDs and actual output
5. If all gates pass: tag v0.1.0-rc1
6. Run `make demo` on available Linux host and update evidence/day-15-demo.md

---

## Day 15 evidence files

- evidence/day-15-stale-object-integration.md
- evidence/day-15-demo.md
- evidence/day-15-human-output.md
- evidence/day-15-amd64-package-smoke.md
- evidence/day-15-arm64-package-smoke.md
- evidence/day-15.md (this file)
