# evidence/day-17-rc1-independent-verification.md

Independent verification of v0.1.0-rc1 archives downloaded from run 27863179327.

Performed on: 2026-06-20 on macOS (Darwin arm64, not a Linux build host).
Downloaded via: `gh run download 27863179327 --name vxlan-tracer-linux-{amd64,arm64}`
No local rebuild. No source-tree files used in verification.

---

## SHA-256 verification

Computed with `shasum -a 256` on downloaded files.

```
238d476d12fa9c567c4efd72b69f9b28b614d22df287d6059ffd7ffdbee90572  vxlan-tracer-linux-amd64.tar.gz
ff92458e4526f47e2f9e59404a2ef4bc3bc0bc01cc8c5d3080db7e6a09b5548a  vxlan-tracer-linux-arm64.tar.gz
```

Match provenance record: YES (both hashes identical to CI output).

Companion `.sha256` file verification (`shasum -a 256 -c`):
```
vxlan-tracer-linux-amd64.tar.gz: OK
vxlan-tracer-linux-arm64.tar.gz: OK
```

---

## verify-release-archive.sh — amd64

```
=== verify-release-archive: vxlan-tracer-linux-amd64.tar.gz ===
  INFO  size: 2954384 bytes
  INFO  root directory: vxlan-tracer-linux-amd64
  PASS  vxlan-tracer: present and executable
  PASS  vxlan-tracer: ELF binary (ELF 64-bit LSB executable, x86-64, dynamically linked)
        Go BuildID=0hBB1SvImJmuvWizs4CC/jaDkVawg-7IS7JDPJCgF/UU5TuKthIveG4NtYGPFh/6EOoQ0G2GcoB7qBouuqp
  PASS  bpf/tc_ingress_eth0.bpf.o  (19192 bytes)
  PASS  bpf/tc_egress_vxlan0.bpf.o  (17064 bytes)
  PASS  bpf/kprobes.bpf.o  (8720 bytes)
  PASS  bpf/frag_kprobes.bpf.o  (8584 bytes)
  PASS  scripts/preflight.sh ... scripts/inject_ptb.py
  PASS  README.md / LICENSE / MANIFEST.txt
  PASS  MANIFEST.txt Architecture: 'amd64' matches archive name
  PASS  BPF target '__TARGET_ARCH_x86' matches expected for amd64
  PASS  all scripts: executable
  PASS  scripts/inject_ptb.py: python3 syntax OK
  PASS  SHA-256 checksum verified: checksums-amd64.sha256
  INFO  skipping binary execution (host arch=arm64 ≠ binary arch x86-64 / macOS host)
  PASS: 24
  FAIL: 0
  RESULT: PASS — archive is complete and valid
```

Note: binary `--version` execution skipped on macOS arm64 host (x86-64 ELF cannot execute).
The binary was confirmed `vxlan-tracer v0.1.0-rc1 (commit 74cf2d7)` on x86-64 runner in CI.

---

## verify-release-archive.sh — arm64

```
=== verify-release-archive: vxlan-tracer-linux-arm64.tar.gz ===
  INFO  size: 2783317 bytes
  INFO  root directory: vxlan-tracer-linux-arm64
  PASS  vxlan-tracer: present and executable
  PASS  vxlan-tracer: ELF binary (ELF 64-bit LSB executable, ARM aarch64, dynamically linked)
        Go BuildID=WrtvHy10768rR8fNuYZY/Ud26Gr7q79KESWOwlb04/8HArhoIa63zSh6gKctgU/Isn33hJfic2kM4K8kYLs
  PASS  bpf/tc_ingress_eth0.bpf.o  (19192 bytes)
  PASS  bpf/tc_egress_vxlan0.bpf.o  (17064 bytes)
  PASS  bpf/kprobes.bpf.o  (7792 bytes)
  PASS  bpf/frag_kprobes.bpf.o  (7728 bytes)
  PASS  scripts/preflight.sh ... scripts/inject_ptb.py
  PASS  README.md / LICENSE / MANIFEST.txt
  PASS  MANIFEST.txt Architecture: 'arm64' matches archive name
  PASS  BPF target '__TARGET_ARCH_arm64' matches expected for arm64
  PASS  all scripts: executable
  PASS  scripts/inject_ptb.py: python3 syntax OK
  PASS  SHA-256 checksum verified: checksums-arm64.sha256
  INFO  skipping binary execution (Linux arm64 ELF cannot execute on macOS host)
  PASS: 24
  FAIL: 0
  RESULT: PASS — archive is complete and valid
```

Note: binary `--version` execution skipped (Linux arm64 ELF / macOS host).
Confirmed `vxlan-tracer v0.1.0-rc1 (commit 74cf2d7)` on aarch64 runner in CI.

---

## test-release-package-isolation.sh — amd64

```
  PASS: 32
  FAIL: 0
  RESULT: PASS — archive is self-contained (no source-tree dependencies found)
```

All 17 required files present. No spikes/ references in .sh files. All relative
$(dirname "$0")/... paths resolve. inject_ptb.py python3 syntax OK. All .sh bash -n OK.

---

## test-release-package-isolation.sh — arm64

```
  PASS: 32
  FAIL: 0
  RESULT: PASS — archive is self-contained (no source-tree dependencies found)
```

Identical result to amd64. All files present, all syntax checks pass.

---

## Conclusion

Downloaded archives are identical to what CI produced (SHA-256 match).
Structural verification and isolation checks pass locally.
Neither archive was rebuilt after download from run 27863179327.
Binary execution verification was performed in CI; cannot be repeated on macOS.
