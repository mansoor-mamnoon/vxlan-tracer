# Day 13 — Stale BPF object guard

**Date:** 2026-06-19
**Kernel:** 5.15.0-181-generic aarch64
**Environment:** Lima VM (Ubuntu 22.04.5 LTS)

---

## The stale object chain (root cause)

The macOS working directory (`bpf/tc_ingress_eth0.bpf.o`) contained a
pre-Day-11 compiled object (17,936 bytes, Jun 14 04:16). This object was
compiled before `vxlan_config` was added to the BPF program and has no
`vxlan_config` symbol in its `.maps` section (only `ptb_ingress_counts`
and `ptb_ingress_total`).

When syncing source to the Lima VM with `cp -r` or `rsync` without
`--exclude='*.bpf.o'`, this stale object was copied to
`/tmp/vxlan-tracer/bpf/`. `make bpf` then saw the object as non-stale
(timestamps equal or object newer than source) and skipped recompilation.

The silent failure path (pre-Commit 1):
1. Stale object copied to Lima → no `vxlan_config` map in ELF
2. `writeVXLANConfig` checked `coll.Maps["vxlan_config"]` → absent → returned nil
3. Binary attached successfully with BPF port hardcoded to 4789
4. For the 8472 scenario: PTBs with embedded dport=8472 would be missed
   (`ptb_ingress_total=0`), but the scenario might still "pass" with different
   traffic or timing

---

## Fix 1: fail-closed loader (Commit 1)

`writeVXLANPortToMaps` now returns an error when `vxlan_config` is absent:

```
vxlan_config map missing from tc_ingress object — likely stale BPF object;
run: make clean-bpf && make bpf
```

Unit tests confirm the error path:

```
=== RUN   TestWriteVXLANPortToMapsMissing
--- PASS: TestWriteVXLANPortToMapsMissing (0.00s)
=== RUN   TestWriteVXLANPortToMapsMissingPort0
--- PASS: TestWriteVXLANPortToMapsMissingPort0 (0.00s)
PASS  ok  github.com/mansoormmamnoon/vxlan-tracer/internal/loader  0.002s
```

---

## Fix 2: make bpf-verify (Commit 2)

Checks the `vxlan_config` symbol in the BPF object's symbol table:

```bash
# fresh 19K object (19112 bytes, Jun 19):
$ make bpf-verify
  PASS  bpf/tc_ingress_eth0.bpf.o contains vxlan_config map section
```

Note: initial implementation checked section headers (`readelf -S`), which
is wrong — `vxlan_config` is a symbol within the `.maps` section, not a
section itself. Fixed to use `readelf -s` (symbol table) and `nm`.

---

## Fix 3: remove stale macOS object (Commit 3)

`bpf/tc_ingress_eth0.bpf.o` deleted from the macOS working directory.
The file is in `.gitignore` (`bpf/*.o`) and was never tracked by git,
but its presence in the directory caused it to be copied to Linux VMs.

After deletion, syncing source to Lima produces no stale BPF objects.
`make clean-bpf && make bpf` is now the required path after every sync.

---

## Clean rebuild confirmation

```
$ sudo make clean-bpf
rm -f bpf/*.bpf.o
BPF objects removed.  Run 'make bpf' to recompile.

$ sudo make bpf
  prereqs OK  clang=Ubuntu clang version 14.0.0-1ubuntu1.1  arch=aarch64
  CC  bpf/tc_ingress_eth0.bpf.o    (19K, Jun 19)
  CC  bpf/tc_egress_vxlan0.bpf.o   (17K)
  CC  bpf/kprobes.bpf.o             (7.6K)
  CC  bpf/frag_kprobes.bpf.o        (7.5K)
BPF build complete.

$ make bpf-verify
  PASS  bpf/tc_ingress_eth0.bpf.o contains vxlan_config map section

$ go test ./...
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/loader  0.002s
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap  (cached)
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/diag    (cached)
```

---

## What this proves

1. **Fail-closed is unit-tested.** Two tests verify the "vxlan_config map missing"
   error path for both explicit and auto-detect (port=0) scenarios.

2. **`make bpf-verify` works correctly.** Uses `readelf -s` (symbol table),
   not `-S` (section headers). PASS on fresh 19K object; FAIL if symbol absent.

3. **Root cause removed.** Stale macOS object deleted; `rsync --exclude='*.bpf.o'`
   prevents re-introduction. The Lima VM only gets fresh-compiled objects.

4. **A stale object now causes an immediate, clear error** instead of silently
   attaching with the wrong port filter.
