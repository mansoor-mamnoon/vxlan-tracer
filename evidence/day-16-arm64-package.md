# evidence/day-16-arm64-package.md

arm64 release archive qualification — CI run 27860935576, build-arm64 job, 2026-06-20.

---

## Environment

```
Runner:  ubuntu-22.04-arm (aarch64)
Kernel:  6.8.0-1059-azure
Arch:    aarch64 → __TARGET_ARCH_arm64
Commit:  8fbc6f7
```

## Archive

```
File:  dist/release/vxlan-tracer-linux-arm64.tar.gz
Size:  ~2.66 MB
SHA256: (in dist/release/checksums-arm64.sha256)
```

## verify-release-archive.sh

```
=== verify-release-archive: dist/release/vxlan-tracer-linux-arm64.tar.gz ===
  INFO  root directory: vxlan-tracer-linux-arm64

-- Binary --
  PASS  vxlan-tracer: present and executable
  PASS  vxlan-tracer: ELF binary
        (ELF 64-bit LSB executable, ARM aarch64, version 1 (SYSV), dynamically linked)

-- Required BPF objects --
  PASS  bpf/tc_ingress_eth0.bpf.o  (19192 bytes)
  PASS  bpf/tc_egress_vxlan0.bpf.o  (17064 bytes)
  PASS  bpf/kprobes.bpf.o  (7792 bytes)
  PASS  bpf/frag_kprobes.bpf.o  (7728 bytes)

-- Required scripts --
  PASS  scripts/preflight.sh
  PASS  scripts/run-scenarios.sh
  PASS  scripts/demo.sh
  PASS  scripts/setup-bpf-fs.sh
  PASS  scripts/setup-netns.sh
  PASS  scripts/teardown-netns.sh
  PASS  scripts/cleanup-bpf.sh
  PASS  scripts/inject_ptb.py

-- Documentation --
  PASS  README.md
  PASS  LICENSE
  PASS  MANIFEST.txt

-- Manifest validated kernels --
  aarch64: 5.15.0-181-generic — 6/6 scenarios PASS
           6.10.14-linuxkit  — 5/5 scenarios PASS (tested before scenario 6 was added)
  x86_64:  6.8.0-1059-azure  (GitHub Actions ubuntu-22.04) — 6/6 scenarios PASS

-- SHA-256 checksum --
  PASS  SHA-256 checksum verified: checksums-arm64.sha256

-- Binary version check --
  PASS  binary --version: vxlan-tracer dev (commit 8fbc6f7, built unknown)

=== Verification summary ===
  PASS: 25
  FAIL: 0
  RESULT: PASS — archive is complete and valid
```

## Package isolation test (scripts/test-release-package-isolation.sh)

Extracted to temporary directory with no access to source tree.

```
=== Isolation test summary ===
  PASS: 32
  FAIL: 0
  RESULT: PASS — archive is self-contained (no source-tree dependencies found)
```

All 16 required files present. No `spikes/` references in packaged `.sh` files.
All relative `$(dirname "$0")/...` paths resolve from within the extracted archive.
inject_ptb.py passes `python3 -m py_compile`. All `.sh` files pass `bash -n`.

## 6-scenario suite from packaged archive

Binary and BPF objects taken exclusively from the extracted archive. Source tree not
present in the execution environment.

```
binary: /tmp/tmp.IslO6Z3UeW/vxlan-tracer-linux-arm64/vxlan-tracer
bpf:    /tmp/tmp.IslO6Z3UeW/vxlan-tracer-linux-arm64/bpf

[PASS] verdict=VXLAN_MTU_MISCONFIGURATION
[PASS] verdict=VXLAN_FRAGMENTATION_OBSERVED
[PASS] verdict=PTB_DELIVERED
[PASS] verdict=PTB_SUPPRESSED
[PASS] Second run: verdict=VXLAN_FRAGMENTATION_OBSERVED scope=global_corroborated
[PASS] verdict=PTB_DELIVERED  vxlan_port=8472

Results: 6 passed, 0 failed
```

## Conclusion

The arm64 release archive is self-contained and executes correctly on aarch64 linux
(kernel 6.8.0-1059-azure) without reference to the source tree.

All 6 verdict scenarios pass from packaged files only.
verify-release-archive.sh: 25/25 PASS.
test-release-package-isolation.sh: 32/32 PASS.

Note: BPF objects in this archive embed `__TARGET_ARCH_arm64`. The kprobes.bpf.o and
frag_kprobes.bpf.o are different sizes from the amd64 equivalents (7792 vs 8720 bytes
and 7728 vs 8584 bytes respectively), confirming arch-specific compilation.
