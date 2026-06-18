# Day 12 synthesis — Non-4789 VXLAN port end-to-end validation

**Date:** 2026-06-18
**Primary goal:** Prove VXLAN port configurability end-to-end on a real Linux kernel.
**Environment:** Lima VM, Ubuntu 22.04.5 LTS, 5.15.0-181-generic aarch64

---

## Primary success condition: MET

Three required proofs, all confirmed:

1. **4789 regression:** existing 5-scenario suite passes after `vxlan_config` BPF map addition.
2. **8472 end-to-end:** PTB_DELIVERED and PTB_SUPPRESSED correct with port-8472 VXLAN.
3. **Auto-detect:** `DetectVXLAN` reads 8472 and VNI=42 from a real kernel interface.

All evidence is recorded. Nothing fabricated.

---

## What Day 12 achieved

### 1. Stale BPF object resolved

The Lima VM `/tmp/vxlan-tracer` copy had a stale pre-Day 11 `tc_ingress_eth0.bpf.o`
(17.9K, no `vxlan_config` section). `make bpf` skipped recompilation due to equal
timestamps. Fixed with `sudo rm -f bpf/tc_ingress_eth0.bpf.o && sudo make bpf`.
New object: 19K, includes the `vxlan_config` ARRAY map section.

### 2. BPF verifier acceptance on 5.15.0-181-generic

The `vxlan_config` map lookup pattern:
```c
struct vxlan_cfg *cfg = bpf_map_lookup_elem(&vxlan_config, &cfg_k);
__be16 vxlan_port = (cfg && cfg->vxlan_dport) ? cfg->vxlan_dport : bpf_htons(4789);
```
was accepted by the BPF verifier on 5.15.0-181-generic aarch64. The null check
satisfies the verifier's pointer dereference requirement. ARRAY maps always return
non-null for key 0 in practice, but the check is required for verifier satisfaction.

### 3. 5/5 regression: original scenarios unaffected

Full 5-scenario suite run after the `vxlan_config` map addition:
- All five verdicts produced correctly.
- BPF map with default zero value → falls back to `bpf_htons(4789)` → behavior
  identical to the hardcoded pre-Day 11 program.

See `evidence/day-12-port-regression-4789.md`.

### 4. Port-8472 VXLAN lab

`VXLAN_PORT=8472 bash scripts/setup-netns.sh` creates `vxlan0` with `dstport 8472`.
Confirmed via `ip -d link show vxlan0` in ns1:
```
vxlan id 42 remote 192.168.100.2 local 192.168.100.1 dev veth1
srcport 0 0 dstport 8472 ...
```
See `evidence/day-12-netns-8472-setup.md`.

### 5. Auto-detect confirmed

`DetectVXLAN("vxlan0")` inside ns1 returned Port=8472, VNI=42.
Startup log: `vxlan port: 8472 (auto-detected)`.
The Go loader wrote portNBO=bpf_htons(8472) into the vxlan_config map.
See `evidence/day-12-vxlan-autodetect.md`.

### 6. PTB_DELIVERED with port 8472

```json
{
  "verdict": "PTB_DELIVERED",
  "vxlan_port": 8472,
  "vxlan_vni": 42,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 5
}
```
TC ingress BPF counted 5 PTBs with embedded `dstport=8472`. With the old hardcoded
4789, all 5 would have been silently discarded. See `evidence/day-12-ptb-delivered-8472.md`.

### 7. PTB_SUPPRESSED with port 8472

```json
{
  "verdict": "PTB_SUPPRESSED",
  "vxlan_port": 8472,
  "vxlan_vni": 42,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 0
}
```
iptables DROP rule in ns1; 5 PTBs counted at TC ingress, 0 at icmp_rcv.
See `evidence/day-12-ptb-suppressed-8472.md`.

### 8. 6/6 scenario suite

`scripts/run-scenarios.sh` extended with `_run_port_ptb_delivered 8472` as scenario 6.
The function:
- Creates a fresh VXLAN lab with dstport=8472
- Runs vxlan-tracer with auto-detect (no `--vxlan-port`)
- Injects PTBs with `--vxlan-port 8472`
- Asserts both `verdict==PTB_DELIVERED` AND `vxlan_port==8472` in JSON

Full run result: `Results: 6 passed, 0 failed`.
See `evidence/day-12-scenarios-8472.md`.

### 9. k3s two-node: NOT RUN

`k3s` is not installed in the Lima VM or on the macOS host. The kubectl context
points to an unreachable cluster. No two-node cluster is available.
See `evidence/day-12-k3s-env.md` and `evidence/day-12-k3s-baseline.md`.

---

## Commits

| # | Hash | Summary |
|---|------|---------|
| 1 | 2f204fa | 5/5 PASS on 5.15-generic after vxlan_config BPF map |
| 2 | dd348ec | setup-netns.sh and run-scenarios.sh accept VXLAN_PORT env var |
| 3 | 0b40aa7 | auto-detect confirmed on 8472 VXLAN interface |
| 4 | e3f4662 | PTB_DELIVERED confirmed with VXLAN port 8472 |
| 5 | 16b1b95 | PTB_SUPPRESSED confirmed with VXLAN port 8472 |
| 6 | d285531 | 6/6 scenario suite passes including port-8472 end-to-end |
| 7 | 04abeb9 | k3s two-node validation NOT RUN — no cluster available |
| 8 | 3474d69 | update docs and test-results for port-8472 validation |
| 9 | (next)  | Day 12 synthesis |

---

## What is now proven (after Day 12)

Everything proven in Days 1–11, plus:

14. `vxlan_config` BPF ARRAY map accepted by BPF verifier on 5.15.0-181-generic aarch64.
15. Byte order conversion portHost→portNBO is correct: port 8472 stored correctly in map;
    BPF filter matches PTBs with embedded `dstport=8472`.
16. `DetectVXLAN` reads the correct port and VNI from a real kernel VXLAN interface via rtnetlink.
17. PTB_DELIVERED verdict works with port 8472: `ptb_ingress_total=5, icmp_rcv_total=5`.
18. PTB_SUPPRESSED verdict works with port 8472: `ptb_ingress_total=5, icmp_rcv_total=0`.
19. Original 5-scenario suite is unaffected by the `vxlan_config` map addition.
20. Scenario runner extended to 6 scenarios with port assertion in JSON.

---

## What remains unproven

- Real CNI validation: two-node k3s/flannel cluster not available. Primary gap after Day 12.
- Non-4789 scenario on x86_64 kernel (only tested on aarch64 5.15.0-181-generic).
- flannel.1 auto-detect on a real k3s node.
- x86_64 kernel versions other than 6.8.0-1052-azure.

---

## Day 12 answers to the primary questions

**Q: Is VXLAN port configurability proven on a real Linux kernel?**
A: Yes. Port 4789 (regression) and port 8472 (new) both confirmed on 5.15.0-181-generic.
   Both PTB_DELIVERED and PTB_SUPPRESSED work with non-default ports.

**Q: Is auto-detect correct?**
A: Yes. `DetectVXLAN` reads port and VNI correctly from a real kernel interface.
   The byte order conversion is confirmed by the fact that PTBs with `dstport=8472`
   are counted (if the conversion were wrong, `ptb_ingress_total` would be 0).

**Q: Is the tool ready for k3s/flannel validation?**
A: Technically yes — the port configurability is proven at the netns level.
   The missing piece is a two-node k3s cluster, which is outside the scope of
   a macOS development environment.

**Q: Why was the Day 12 stale BPF object a risk?**
A: When `cp -r` copied source to `/tmp/vxlan-tracer`, it preserved the old
   `tc_ingress_eth0.bpf.o` with no `vxlan_config` section. `make bpf` saw equal
   timestamps and skipped recompilation. The binary would have loaded successfully
   — the Go loader's `coll.Maps["vxlan_config"]` lookup returns `nil` for missing
   maps, and `writeVXLANConfig` returns nil (skips silently). This means port 8472
   would silently fall back to 4789, and the test would have passed for the wrong
   reason. Forcing recompilation was essential.
