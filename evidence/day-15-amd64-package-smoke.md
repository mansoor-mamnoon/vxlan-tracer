# evidence/day-15-amd64-package-smoke.md

Smoke test for the v0.1.0-rc1 amd64 release archive on x86_64 Linux.

---

## Package identification

Archive: `vxlan-tracer-linux-amd64.tar.gz`
Built by: CI workflow `release-package.yml`, job `build-amd64` (ubuntu-22.04)
BPF target: `__TARGET_ARCH_x86`
Architecture: x86_64

---

## Required files (per verify-release-archive.sh)

- `vxlan-tracer-linux-amd64/vxlan-tracer` (ELF x86-64, executable)
- `vxlan-tracer-linux-amd64/bpf/tc_ingress_eth0.bpf.o`
- `vxlan-tracer-linux-amd64/bpf/tc_egress_vxlan0.bpf.o`
- `vxlan-tracer-linux-amd64/bpf/kprobes.bpf.o` (compiled with `__TARGET_ARCH_x86`)
- `vxlan-tracer-linux-amd64/bpf/frag_kprobes.bpf.o` (compiled with `__TARGET_ARCH_x86`)
- `vxlan-tracer-linux-amd64/scripts/preflight.sh`
- `vxlan-tracer-linux-amd64/scripts/run-scenarios.sh`
- `vxlan-tracer-linux-amd64/scripts/demo.sh`
- `vxlan-tracer-linux-amd64/scripts/setup-bpf-fs.sh`
- `vxlan-tracer-linux-amd64/README.md`
- `vxlan-tracer-linux-amd64/LICENSE`
- `vxlan-tracer-linux-amd64/MANIFEST.txt`

---

## Smoke test procedure

```sh
# Extract
tar -xzf vxlan-tracer-linux-amd64.tar.gz
cd vxlan-tracer-linux-amd64

# Verify contents
bash ../scripts/verify-release-archive.sh ../vxlan-tracer-linux-amd64.tar.gz

# Check version metadata
./vxlan-tracer --version
# Expected: vxlan-tracer v0.1.0-rc1 (commit <sha>, built unknown)

# Preflight (root)
sudo bash scripts/preflight.sh

# Run one scenario (root, using PACKAGED BPF objects)
sudo BINARY=./vxlan-tracer BPF_DIR=./bpf DURATION=15s \
    bash scripts/run-scenarios.sh
```

Note: smoke test must use `BINARY=./vxlan-tracer` and `BPF_DIR=./bpf` (packaged files),
NOT repository source files.

---

## CI validation

The `release-package.yml` workflow's `build-amd64` job runs:
1. `make package` → produces archive
2. `bash scripts/verify-release-archive.sh` → checks all required files
3. "Verify packaged binary version" step → runs `./vxlan-tracer --version`, confirms output

A full scenario run from the packaged archive is NOT automated in the current CI
(the 6-scenario suite in x86-smoke.yml uses source-tree files, not the packaged archive).

**Status at time of writing:** CI in progress (commit `10b40f6`/`9dabe2b`/subsequent pushes).

---

## What is proven

- verify-release-archive.sh validates archive structure (script review + macOS test of error path)
- 6/6 scenarios pass on x86_64 6.8.0-1059-azure using source-tree binary+BPF (Day 13 CI)
- Binary builds correctly for amd64 from source (multiple CI runs Days 10-13)

## What remains unproven

- Full package (with BPF objects from CI) not yet extracted and smoke-tested
- `./vxlan-tracer --version` with `VERSION=v0.1.0-rc1` not captured live
- Scenario run from extracted archive (not source tree) not performed
- `--help` from packaged binary not captured
