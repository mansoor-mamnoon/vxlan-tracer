# Day 13 — Port-configurable v0 release-safe

**Date:** 2026-06-19
**Kernel (local):** 5.15.0-181-generic aarch64 (Lima VM)
**Kernel (CI):** 6.8.0-1059-azure x86_64 (GitHub Actions ubuntu-22.04)

---

## What was done

### Commit 1: fail-closed loader

`writeVXLANPortToMaps` now returns an error when `vxlan_config` is absent
from the loaded BPF collection. Previously it returned nil silently, causing
the binary to attach with port 4789 hardcoded regardless of `--vxlan-port`.

Error message: `vxlan_config map missing from tc_ingress object — likely stale
BPF object; run: make clean-bpf && make bpf`

Two unit tests in `internal/loader/loader_vxlan_test.go` (`//go:build linux`)
verify the error path for both explicit port and auto-detect (port=0).

### Commit 2: build guard targets

`make clean-bpf`: removes `bpf/*.bpf.o`, forces recompile on next `make bpf`.
`make bpf-verify`: checks for the `vxlan_config` symbol in the ELF object via
`readelf -s` (symbol table). Initial implementation used `-S` (section headers) —
wrong; `vxlan_config` is a symbol within `.maps`, not a section itself. Fixed.

`scripts/preflight.sh` extended with the same freshness check.

### Commit 3: stale object removed + evidence

Root cause of the silent failure chain: `bpf/tc_ingress_eth0.bpf.o` (17,936
bytes, Jun 14) was present in the macOS working directory. `rsync` without
`--exclude='*.bpf.o'` would copy it to Lima, where `make bpf` saw a non-stale
object and skipped recompilation. The object predated the `vxlan_config` map
and had no `vxlan_config` symbol.

Deleted from macOS working directory. File was gitignored (`bpf/*.o`) and never
tracked; its presence was the only propagation vector.

### Commit 4: CI update

`.github/workflows/x86-smoke.yml` updated to:
- Run `sudo make clean-bpf` before `sudo make bpf` (prevents stale reuse in CI)
- Run `make bpf-verify` after compile
- Run 6-scenario suite (was 5-scenario)
- Retain artifacts for 7 days with `vxlan-lab-http.log`

### Commit 5: local 6/6 confirmation

All 6 scenarios pass on 5.15.0-181-generic aarch64 after all Day 13 changes.
Including scenario 6: `"verdict":"PTB_DELIVERED","vxlan_port":8472`.

### Commit 6: x86_64 CI result

GitHub Actions run 27851298262 (kernel 6.8.0-1059-azure x86_64): 6/6 pass,
including port 8472. Job conclusion: PASS. Preflight had 1 ENVIRONMENT failure
(`ip link add dummy` blocked on shared runner); this is expected and
`continue-on-error: true` is set on the preflight step. Scenarios ran and all
exited 0.

---

## What is now guaranteed

1. A stale BPF object (without `vxlan_config`) causes an immediate, clear
   loader error with fix instructions — not a silent wrong-port attach.

2. `make bpf-verify` confirms the fresh object has the `vxlan_config` symbol
   before any run. CI runs `clean-bpf` before compile, preventing stale reuse.

3. 6/6 scenarios pass on aarch64 5.15.0-181-generic and x86_64 6.8.0-1059-azure
   with the fail-closed loader in place. Scenario 6 (port 8472) confirmed on
   both architectures.

---

## What remains unproven

- CNI (k3s/flannel) validation: requires a real two-node cluster.
- ip_do_fragment VXLAN-specific scoping: still global on all kernels.
- Other kernel versions (5.10.x, 6.1.x, 6.5.x).
- Loader error path under actual stale-object load (unit test uses empty map,
  not a real BPF collection with missing symbol).
