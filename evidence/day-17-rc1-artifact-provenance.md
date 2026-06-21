# evidence/day-17-rc1-artifact-provenance.md

Authoritative provenance record for the v0.1.0-rc1 release archives.

These are the proposed rc1 release artifacts. No rebuild, no local modification.
All data is taken directly from workflow run 27863179327 CI logs.

---

## Authoritative workflow run

| Field | Value |
|-------|-------|
| Run ID | 27863179327 |
| Workflow | Release package (amd64 + arm64) |
| Trigger | workflow_dispatch |
| Input: version | v0.1.0-rc1 |
| Branch | main |
| Git commit | 74cf2d7 (1740773 full SHA) |
| Build date | 2026-06-20T06:41Z – 06:43Z |
| Conclusion | success |

---

## amd64 archive

| Field | Value |
|-------|-------|
| Archive name | vxlan-tracer-linux-amd64.tar.gz |
| Archive size | 2954384 bytes |
| SHA-256 | `238d476d12fa9c567c4efd72b69f9b28b614d22df287d6059ffd7ffdbee90572` |
| Binary `--version` | `vxlan-tracer v0.1.0-rc1 (commit 74cf2d7, built unknown)` |
| Binary type | ELF 64-bit LSB executable, x86-64, version 1 (SYSV), dynamically linked |
| BPF target | `__TARGET_ARCH_x86` |
| Build runner | ubuntu-22.04 (x86_64), kernel 6.8.0-1059-azure |
| Go version | 1.21.13 |
| clang version | Ubuntu clang version 14.0.0-1ubuntu1.1 |
| Artifact name | vxlan-tracer-linux-amd64 (CI artifact) |

**BPF object sizes (from CI):**
```
bpf/tc_ingress_eth0.bpf.o   19192 bytes
bpf/tc_egress_vxlan0.bpf.o  17064 bytes
bpf/kprobes.bpf.o             8720 bytes
bpf/frag_kprobes.bpf.o        8584 bytes
```

**Verification results:**
- verify-release-archive.sh: PASS: 25, FAIL: 0 — RESULT: PASS
- package isolation test: PASS: 32, FAIL: 0 — RESULT: PASS
- packaged 6-scenario suite: Results: 6 passed, 0 failed

**Packaged scenario verdicts (amd64):**
```
[PASS] verdict=VXLAN_MTU_MISCONFIGURATION
[PASS] verdict=VXLAN_FRAGMENTATION_OBSERVED
[PASS] verdict=PTB_DELIVERED
[PASS] verdict=PTB_SUPPRESSED
[PASS] Second run: verdict=VXLAN_FRAGMENTATION_OBSERVED scope=global_corroborated
[PASS] verdict=PTB_DELIVERED  vxlan_port=8472
Results: 6 passed, 0 failed
```

---

## arm64 archive

| Field | Value |
|-------|-------|
| Archive name | vxlan-tracer-linux-arm64.tar.gz |
| Archive size | 2783317 bytes |
| SHA-256 | `ff92458e4526f47e2f9e59404a2ef4bc3bc0bc01cc8c5d3080db7e6a09b5548a` |
| Binary `--version` | `vxlan-tracer v0.1.0-rc1 (commit 74cf2d7, built unknown)` |
| Binary type | ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), dynamically linked |
| BPF target | `__TARGET_ARCH_arm64` |
| Build runner | ubuntu-22.04-arm (aarch64), kernel 6.8.0-1059-azure |
| Go version | 1.21.13 |
| clang version | Ubuntu clang version 14.0.0-1ubuntu1.1 |
| Artifact name | vxlan-tracer-linux-arm64 (CI artifact) |

**BPF object sizes (from CI):**
```
bpf/tc_ingress_eth0.bpf.o   19192 bytes
bpf/tc_egress_vxlan0.bpf.o  17064 bytes
bpf/kprobes.bpf.o             7792 bytes   ← arm64 (differs from amd64 8720)
bpf/frag_kprobes.bpf.o        7728 bytes   ← arm64 (differs from amd64 8584)
```

kprobes.bpf.o and frag_kprobes.bpf.o sizes differ between amd64 and arm64,
confirming architecture-specific compilation.

**Verification results:**
- verify-release-archive.sh: PASS: 25, FAIL: 0 — RESULT: PASS
- package isolation test: PASS: 32, FAIL: 0 — RESULT: PASS
- packaged 6-scenario suite: Results: 6 passed, 0 failed

**Packaged scenario verdicts (arm64):**
```
[PASS] verdict=VXLAN_MTU_MISCONFIGURATION
[PASS] verdict=VXLAN_FRAGMENTATION_OBSERVED
[PASS] verdict=PTB_DELIVERED
[PASS] verdict=PTB_SUPPRESSED
[PASS] Second run: verdict=VXLAN_FRAGMENTATION_OBSERVED scope=global_corroborated
[PASS] verdict=PTB_DELIVERED  vxlan_port=8472
Results: 6 passed, 0 failed
```

---

## Combined checksums (from combine-checksums job)

Produced by `sha256sum` from the same workflow run.
Verified by `sha256sum --check`: both archives OK.

```
238d476d12fa9c567c4efd72b69f9b28b614d22df287d6059ffd7ffdbee90572  vxlan-tracer-linux-amd64.tar.gz
ff92458e4526f47e2f9e59404a2ef4bc3bc0bc01cc8c5d3080db7e6a09b5548a  vxlan-tracer-linux-arm64.tar.gz
```

---

## Claim

These two archives are the proposed v0.1.0-rc1 release artifacts.
They were built, verified, and qualified in a single workflow run (27863179327)
from Git commit 74cf2d7 on branch main with version input v0.1.0-rc1.

No source-tree files are substituted during execution. No archives were rebuilt
outside this workflow run.
