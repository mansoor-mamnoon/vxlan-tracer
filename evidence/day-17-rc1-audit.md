# evidence/day-17-rc1-audit.md

Audit of GitHub Actions workflow run 27863179327 — the proposed authoritative
v0.1.0-rc1 release qualification run.

Workflow: Release package (amd64 + arm64)
Trigger: workflow_dispatch (version=v0.1.0-rc1)
Branch: main
Commit: 74cf2d7
Triggered: 2026-06-20T06:41Z
Completed: 2026-06-20T06:43Z (success)

---

## Jobs

### Build arm64 package
- **Conclusion:** success
- **Runner:** ubuntu-22.04-arm (aarch64)
- **Kernel:** 6.8.0-1059-azure #65~22.04.1-Ubuntu SMP Thu May 28 17:04:31 UTC 2026
- **Arch:** aarch64 → `__TARGET_ARCH_arm64`
- **Go version:** 1.21.13
- **clang:** Ubuntu clang version 14.0.0-1ubuntu1.1
- **Commit built:** 74cf2d7
- **Version input:** v0.1.0-rc1
- **Archive name:** vxlan-tracer-linux-arm64.tar.gz
- **Artifact name:** vxlan-tracer-linux-arm64

Steps (all success):
- Set up job
- Checkout
- Capture environment
- Set up Go
- Install build dependencies
- Mount bpffs
- Run Go unit tests
- Compile BPF objects (arm64 — __TARGET_ARCH_arm64)
- Build arm64 package
- **Verify release archive** ✓
- Show archive contents
- Verify packaged binary version
- **Package isolation test** ✓
- Install scapy for scenario run
- **Run 6-scenario suite from packaged archive** ✓
- Upload arm64 package
- Upload arm64 scenario log

### Build amd64 package
- **Conclusion:** success
- **Runner:** ubuntu-22.04 (x86_64)
- **Kernel:** 6.8.0-1059-azure #65~22.04.1-Ubuntu SMP Thu May 28 16:59:19 UTC 2026
- **Arch:** x86_64 → `__TARGET_ARCH_x86`
- **Go version:** 1.21.13
- **clang:** Ubuntu clang version 14.0.0-1ubuntu1.1
- **Commit built:** 74cf2d7
- **Version input:** v0.1.0-rc1
- **Archive name:** vxlan-tracer-linux-amd64.tar.gz
- **Artifact name:** vxlan-tracer-linux-amd64

Steps (all success):
- Set up job
- Checkout
- Capture environment
- Set up Go
- Install build dependencies
- Mount bpffs
- Run Go unit tests
- Compile BPF objects (amd64 — __TARGET_ARCH_x86)
- Build amd64 package
- **Verify release archive** ✓
- Show archive contents
- Verify packaged binary version
- **Package isolation test** ✓
- Install scapy for scenario run
- **Run 6-scenario suite from packaged archive** ✓
- Upload amd64 package
- Upload amd64 scenario log

### Combine checksums
- **Conclusion:** success
- Steps (all success):
  - Download amd64 checksums
  - Download arm64 checksums
  - **Combine and verify checksums** ✓
  - **Verify checksums match archives** ✓
  - Upload combined checksums
  - Summary

---

## Required gate confirmation

| Required step | Ran | Result |
|---------------|-----|--------|
| verify-release-archive.sh (amd64) | YES | PASS: 25/25 |
| verify-release-archive.sh (arm64) | YES | PASS: 25/25 |
| Package isolation test (amd64) | YES | PASS: 32/32 |
| Package isolation test (arm64) | YES | PASS: 32/32 |
| Packaged 6-scenario suite (amd64) | YES | PASS: 6/6 |
| Packaged 6-scenario suite (arm64) | YES | PASS: 6/6 |
| Checksum generation (sha256sum) | YES | PASS: both OK |
| v0.1.0-rc1 version string | YES | PASS: both arches |

All required gates ran and passed in this single workflow run.
Run 27863179327 is the authoritative rc1 qualification run.
