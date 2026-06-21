# evidence/day-18.md — Day 18: v0.1.0-rc1 release publication

Date: 2026-06-21
Purpose: Execute the full release provenance chain for v0.1.0-rc1.

This evidence commit occurs AFTER the tagged release commit (049d4e2f) and is not
part of the released source snapshot.

---

## Summary

v0.1.0-rc1 was published as a GitHub prerelease at:
https://github.com/mansoor-mamnoon/vxlan-tracer/releases/tag/v0.1.0-rc1

Tag `v0.1.0-rc1` is annotated and points to commit
`049d4e2f761935a5f36eececc6f85c87b3fda1fe`.

The tag, workflow headSha, packaged binary commit metadata, and release artifacts
all correspond to the same commit.

---

## Phase sequence completed

| Phase | Action | Result |
|-------|--------|--------|
| 1 | Repository state audit | clean; no existing tag or release |
| 2A | Documentation audit | fixed "8 required gate jobs" → "all required jobs and qualification steps" |
| 2B | Release notes | rewritten for public release; stale CI IDs removed; packaged demo command added |
| 2C | README | packaged archive quick-start section added |
| 2D | demo.yml | run_id made required; stale default removed |
| 2E | Static checks | go test, go vet, bash -n, py_compile: all PASS |
| 2 commit | `release: finalize v0.1.0-rc1 qualification` | SHA `049d4e2f` |
| 3 | Authoritative workflow dispatch | run 27888450228; all 3 jobs PASS |
| 3 SHA assert | headSha == RELEASE_SHA | VERIFIED |
| 4 | Artifact download | all artifacts downloaded to VERIFY_DIR |
| 5 | SHA-256 verification | both archives OK against checksums.sha256 |
| 5 | verify-release-archive.sh | amd64: 23/23, arm64: 23/23 PASS (macOS) |
| 5 | test-release-package-isolation.sh | amd64: 32/32, arm64: 32/32 PASS |
| 5 | MANIFEST commit check | both arches: Commit 049d4e2, Version v0.1.0-rc1 |
| 5 | CI: packaged 6-scenario suite | amd64: 6/6, arm64: 6/6 PASS |
| 5 | CI: binary --version | both arches: `v0.1.0-rc1 (commit 049d4e2)` |
| 6 | Packaged demo (run 27888597060) | run 1 + run 2 PASS; cleanup 4/4 × 2 PASS |
| 7 | Qualification summary | all fields concrete; no placeholders |
| 8 | Annotated tag v0.1.0-rc1 | created on 049d4e2f; pushed; remote verified |
| 9 | GitHub prerelease | published; 3 assets attached; prerelease=true |
| 9 | Published asset verification | gh release download + shasum -c: both OK |
| 10 | Post-release evidence commit | this commit |

---

## Detailed results — see evidence/v0.1.0-rc1-release.md
