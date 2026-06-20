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
Final commit on this chain: `0ef3385`.

---

## Gate status: PASS / FAIL / PENDING

CI runs confirmed complete 2026-06-20:
- Run **27857782449** ("x86_64 validation suite"), commit `0ef3385`, 2026-06-20T02:42Z
- Run **27857782452** ("Release package amd64+arm64"), commit `0ef3385`, 2026-06-20T02:42Z

| Gate | Status | Evidence |
|------|--------|----------|
| Latest CI run (x86-smoke) | PASS | Run 27857782449, all 3 jobs success |
| Latest CI run (release-package) | PASS | Run 27857782452, all 3 jobs success |
| Stale ELF integration test | PASS | Day 13 CI run 27851298262 + Day 15 run 27857782449 |
| Day 15 stale-object step | PASS | 6/6, kernel 6.8.0-1059-azure (run 27857782449) |
| Deterministic demo | PENDING | make demo requires Linux; not run Day 15 |
| Live human output | FAIL | human-output job: binary load error; Verdict:/Evidence: not captured |
| 6-scenario source-tree suite | PASS | 6/6 PASS, kernel 6.8.0-1059-azure (run 27857782449) |
| amd64 archive completeness | PASS | run 27857782452 build-amd64; verify-release-archive.sh PASS |
| arm64 archive completeness | PASS | run 27857782452 build-arm64; ubuntu-22.04-arm runner confirmed |
| amd64 packaged smoke test | PENDING | No CI step runs scenario-from-archive |
| arm64 packaged smoke test | PENDING | No CI step runs scenario-from-archive on arm64 |
| v0.1.0-rc1 version metadata | PENDING | packages built with VERSION=dev (not rc1) |
| SHA-256 verification | PASS | sha256sum --check: both archives OK (run 27857782452) |

**Proven in Day 15 (source-tree + CI):**
- `go vet ./...` passes on macOS (all Day 14/15 code)
- `go test ./...`: 9 unit tests PASS, kernel 6.8.0-1059-azure (run 27857782449)
- `make package` hard-fails on missing BPF objects (macOS verified)
- `make package` correctly rejects non-Linux host (macOS verified)
- `make package-rc1` delegates correctly (macOS verified)
- verify-release-archive.sh: PASS on amd64 (run 27857782452)
- verify-release-archive.sh: PASS on arm64 (run 27857782452)
- amd64 archive: all required files present; sha256 `0aa54ee4...`
- arm64 archive: all required files present; sha256 `fcac1b61...`; ubuntu-22.04-arm confirmed
- sha256sum --check: both archives OK (run 27857782452)
- Stale-object integration test: 6/6 PASS on 6.8.0-1059-azure (run 27857782449)
- 6-scenario source-tree suite: 6/6 PASS on 6.8.0-1059-azure (run 27857782449)
- `./vxlan-tracer --version`: `vxlan-tracer dev (commit 0ef3385, built unknown)` (both arches)
- All 5 verdict paths covered in printHuman (code review)
- No misleading MTU recommendation for PTB paths (code review)
- MANIFEST.txt in each archive (code review + CI log confirmation)

**Not yet proven after Day 15 CI:**
- `inject_ptb.py` absent from both archives — PTB scenarios cannot run from packaged files
- `VERSION=v0.1.0-rc1` package not built — both archives show `dev` not `v0.1.0-rc1`
- Live human output (Verdict: + Evidence:) not captured — human-output CI job failed load
- `make demo` not run on Linux — pending
- Scenario run from extracted archive on native arch — pending (packaged smoke test)

---

## v0.1.0-rc1 release decision

### NOT READY FOR v0.1.0-rc1 TAG

**Required gates not yet passed (updated after CI completion):**

1. **inject_ptb.py missing from archives** — `run-scenarios.sh` invokes
   `spikes/inject_ptb.py` for PTB injection; `spikes/` is not packaged.
   Scenarios 3 (PTB_DELIVERED) and 4 (PTB_SUPPRESSED) cannot run from the
   extracted archive without falling back to the source tree.

2. **Version metadata** — both archives contain `vxlan-tracer dev` not
   `vxlan-tracer v0.1.0-rc1`. The `VERSION=v0.1.0-rc1 make package` step
   must be run to produce correctly versioned archives.

3. **Packaged binary smoke test** — neither archive has been extracted and used
   to run even one scenario on the matching architecture.

4. **Demo not run** — `make demo` has not completed on Linux.

5. **Human output not captured live** — the human-output CI job binary failed
   to load (missing bpffs pin directory). `Verdict:` and `Evidence:` sections
   not confirmed from an actual run.

**What would change the decision to READY:**

- inject_ptb.py moved to scripts/ and included in archives
- `VERSION=v0.1.0-rc1 make package` run on both amd64 and arm64
- At least one scenario run from the extracted amd64 archive on x86_64 Linux
- At least one scenario run from the extracted arm64 archive on aarch64 Linux
- `make demo` completed with `VXLAN_FRAGMENTATION_OBSERVED` verdict
- printHuman output captured live with Verdict: and Evidence: sections

Two-node Kubernetes validation remains out of scope for rc1 and must remain listed
as unproven.

---

## Day 16 recommendation

1. Move `spikes/inject_ptb.py` → `scripts/inject_ptb.py`; update all references;
   add to Makefile package target; add to verify-release-archive.sh
2. Fix the human-output CI job: add `mkdir -p /sys/fs/bpf/ho-test` (or mount bpffs)
   before running the binary
3. Run `VERSION=v0.1.0-rc1 make package` on x86_64 and aarch64 Linux
4. Extract each archive; run full scenario suite from packaged files only
5. Run `make demo` on Linux; capture full output including `VXLAN_FRAGMENTATION_OBSERVED`
6. Capture live printHuman output for at least 4 verdicts
7. If all gates pass: tag v0.1.0-rc1

---

## Day 15 evidence files

- evidence/day-15-stale-object-integration.md
- evidence/day-15-demo.md
- evidence/day-15-human-output.md
- evidence/day-15-amd64-package-smoke.md
- evidence/day-15-arm64-package-smoke.md
- evidence/day-15.md (this file)
