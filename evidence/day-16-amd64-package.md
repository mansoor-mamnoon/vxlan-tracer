# evidence/day-16-amd64-package.md

amd64 release archive qualification — CI run 27860935576, build-amd64 job, 2026-06-20.

---

## Environment

```
Runner:  ubuntu-22.04 (x86_64)
Kernel:  6.8.0-1059-azure
Arch:    x86_64 → __TARGET_ARCH_x86
Commit:  8fbc6f7
```

## Archive

```
File:  dist/release/vxlan-tracer-linux-amd64.tar.gz
Size:  2954349 bytes
SHA256: (in dist/release/checksums-amd64.sha256)
```

## verify-release-archive.sh

```
=== verify-release-archive: dist/release/vxlan-tracer-linux-amd64.tar.gz ===
  INFO  size: 2954349 bytes
  INFO  root directory: vxlan-tracer-linux-amd64

-- Binary --
  PASS  vxlan-tracer: present and executable
  PASS  vxlan-tracer: ELF binary
        (ELF 64-bit LSB executable, x86-64, version 1 (SYSV), dynamically linked)

-- Required BPF objects --
  PASS  bpf/tc_ingress_eth0.bpf.o  (19192 bytes)
  PASS  bpf/tc_egress_vxlan0.bpf.o  (17064 bytes)
  PASS  bpf/kprobes.bpf.o  (8720 bytes)
  PASS  bpf/frag_kprobes.bpf.o  (8584 bytes)

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

-- Manifest arch check --
  BPF target: __TARGET_ARCH_x86 (matches archive name amd64)

-- Script executability --
  PASS  scripts/preflight.sh: executable
  PASS  scripts/run-scenarios.sh: executable
  PASS  scripts/demo.sh: executable
  PASS  scripts/setup-bpf-fs.sh: executable
  PASS  scripts/setup-netns.sh: executable
  PASS  scripts/teardown-netns.sh: executable
  PASS  scripts/teardown-netns.sh: executable

-- Python syntax check --
  PASS  scripts/inject_ptb.py: python3 syntax OK

-- SHA-256 checksum --
  PASS  SHA-256 checksum verified: checksums-amd64.sha256

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
binary: /tmp/tmp.7BM0EMuJVr/vxlan-tracer-linux-amd64/vxlan-tracer
bpf:    /tmp/tmp.7BM0EMuJVr/vxlan-tracer-linux-amd64/bpf

[PASS] verdict=VXLAN_MTU_MISCONFIGURATION
[PASS] verdict=VXLAN_FRAGMENTATION_OBSERVED
[PASS] verdict=PTB_DELIVERED
[PASS] verdict=PTB_SUPPRESSED
[PASS] Second run: verdict=VXLAN_FRAGMENTATION_OBSERVED scope=global_corroborated
[PASS] verdict=PTB_DELIVERED  vxlan_port=8472

Results: 6 passed, 0 failed
```

## Conclusion

The amd64 release archive is self-contained and executes correctly on x86_64 linux
(kernel 6.8.0-1059-azure) without reference to the source tree.

All 6 verdict scenarios pass from packaged files only.
verify-release-archive.sh: 25/25 PASS.
test-release-package-isolation.sh: 32/32 PASS.
