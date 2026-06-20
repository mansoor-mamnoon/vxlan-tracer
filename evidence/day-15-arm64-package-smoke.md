# evidence/day-15-arm64-package-smoke.md

Smoke test for the v0.1.0-rc1 arm64 release archive on aarch64 Linux.

---

## Package identification

Archive: `vxlan-tracer-linux-arm64.tar.gz`
Built by: CI workflow `release-package.yml`, job `build-arm64` (ubuntu-22.04-arm)
BPF target: `__TARGET_ARCH_arm64`
Architecture: aarch64

---

## Required files (per verify-release-archive.sh)

- `vxlan-tracer-linux-arm64/vxlan-tracer` (ELF ARM aarch64, executable)
- `vxlan-tracer-linux-arm64/bpf/tc_ingress_eth0.bpf.o`
- `vxlan-tracer-linux-arm64/bpf/tc_egress_vxlan0.bpf.o`
- `vxlan-tracer-linux-arm64/bpf/kprobes.bpf.o` (compiled with `__TARGET_ARCH_arm64`)
- `vxlan-tracer-linux-arm64/bpf/frag_kprobes.bpf.o` (compiled with `__TARGET_ARCH_arm64`)
- `vxlan-tracer-linux-arm64/scripts/preflight.sh`
- `vxlan-tracer-linux-arm64/scripts/run-scenarios.sh`
- `vxlan-tracer-linux-arm64/scripts/demo.sh`
- `vxlan-tracer-linux-arm64/scripts/setup-bpf-fs.sh`
- `vxlan-tracer-linux-arm64/README.md`
- `vxlan-tracer-linux-arm64/LICENSE`
- `vxlan-tracer-linux-arm64/MANIFEST.txt`

---

## Smoke test procedure

```sh
# Extract
tar -xzf vxlan-tracer-linux-arm64.tar.gz
cd vxlan-tracer-linux-arm64

# Verify contents
bash ../scripts/verify-release-archive.sh ../vxlan-tracer-linux-arm64.tar.gz

# Check version metadata (on aarch64)
./vxlan-tracer --version
# Expected: vxlan-tracer v0.1.0-rc1 (commit <sha>, built unknown)

# Preflight (root)
sudo bash scripts/preflight.sh

# Run scenarios from PACKAGED files (not repository source)
sudo BINARY=./vxlan-tracer BPF_DIR=./bpf DURATION=15s \
    bash scripts/run-scenarios.sh
```

---

## CI validation

The `release-package.yml` workflow's `build-arm64` job (ubuntu-22.04-arm) runs:
1. `make package` → produces archive
2. `bash scripts/verify-release-archive.sh` → checks all required files
3. "Verify packaged binary version" → runs `./vxlan-tracer --version` natively on aarch64

A full scenario run from the packaged archive is not automated in the current CI.

**Status at time of writing:** CI in progress (commit `9dabe2b` and subsequent).
ubuntu-22.04-arm runner availability on this repository depends on GitHub's arm64
runner pool for public repos.

---

## Prior aarch64 evidence

- 6/6 scenarios pass on 5.15.0-181-generic aarch64 (Lima VM, Day 9 and Day 12-13)
- 5/5 scenarios pass on 6.10.14-linuxkit aarch64 (Docker Desktop, Day 7-8)
- PT_REGS_PARM1 confirmed on aarch64: ctx->regs[0] (ARM64 x0 register)
- BPF objects compiled with `__TARGET_ARCH_arm64` confirmed correct on 5.15.0-181-generic

## What remains unproven

- arm64 package archive not yet built (depends on CI ubuntu-22.04-arm runner)
- `./vxlan-tracer --version` with `VERSION=v0.1.0-rc1` not captured from aarch64
- Scenario run from extracted arm64 archive not performed
- ubuntu-22.04-arm runner availability not confirmed for this repository
