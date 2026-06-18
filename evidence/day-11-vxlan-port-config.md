# Day 11 — VXLAN port configurability

**Date:** 2026-06-18
**Goal:** Remove the hardcoded 4789 assumption from the detection path.

---

## Why this matters

The existing lab uses VXLAN UDP port 4789 (IANA assigned, kernel default).
Real CNI environments may differ:

| CNI / version | VXLAN port | Notes |
|---------------|-----------|-------|
| Flannel ≥ 0.9 | 4789 | Switched to IANA default after 0.9 |
| Flannel < 0.9 | 8472 | Historical non-IANA default |
| Calico VXLAN | 4789 | Always IANA |
| Canal | 8472 | Flannel underlay; older clusters |
| k3s default | 8472 | k3s bundles Flannel; uses 8472 by default |

A hardcoded 4789 in the BPF PTB filter causes **silent false negatives**:
PTBs carrying embedded VXLAN headers with `dstport=8472` would not match
`orig_udph->dest != bpf_htons(4789)` and would be silently discarded.

---

## Changes made (commits 1–3)

### BPF (commit 1)

`bpf/maps.h`: added `struct vxlan_cfg { __be16 vxlan_dport; __u16 pad; }`.

`bpf/tc_ingress_eth0.bpf.c`: replaced compile-time `#define VXLAN_UDP_PORT_NBO bpf_htons(4789)`
with an ARRAY config map lookup:

```c
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key,   __u32);
    __type(value, struct vxlan_cfg);
} vxlan_config SEC(".maps");

// ... inside tc_ingress_count_ptb():
__u32 cfg_k = 0;
struct vxlan_cfg *cfg = bpf_map_lookup_elem(&vxlan_config, &cfg_k);
__be16 vxlan_port = (cfg && cfg->vxlan_dport) ? cfg->vxlan_dport
                                               : bpf_htons(4789);
if (orig_udph->dest != vxlan_port)
    return TC_ACT_OK;
```

- ARRAY maps always return non-null for key 0 (zero-initialized).
  The null check is for BPF verifier satisfaction only.
- `vxlan_dport == 0` means "unset": fall back to 4789.
- The Go loader writes the port in network byte order immediately after
  loading the TC ingress collection, before the TC filter is attached.

### Go loader (commit 1)

`loader.Config` gains `VXLANPort uint16` (host byte order).

`writeVXLANConfig(coll, portHost)` converts to NBO and updates `vxlan_config[0]`:

```go
portNBO := (portHost >> 8) | (portHost << 8)  // host → network byte order
val := vxlanCfgVal{VXLANDPort: portNBO}
m.Update(&key, &val, ebpf.UpdateAny)
```

Byte order correctness:
- portHost = 4789 = 0x12B5
- portNBO = 0xB512
- cilium/ebpf encodes uint16 in native (LE) byte order: bytes [0x12, 0xB5]
- BPF reads [0x12, 0xB5] as __be16 on LE kernel: 0xB512 = bpf_htons(4789) ✓
- udph->dest from a port-4789 packet on LE kernel: 0xB512 ✓
- Comparison: 0xB512 == 0xB512 → match ✓

### CLI (commit 1+2)

`--vxlan-port` default changed from 4789 to 0 (auto-detect).

When 0: `internal/netlink.DetectVXLAN(overlay)` reads `Port` and `VNI` from
the overlay interface via rtnetlink. On non-VXLAN interfaces (lab veth), this
fails and 4789 is used. On a real VXLAN interface, the kernel-reported port
is used directly.

JSON report gains `vxlan_port` and `vxlan_vni` fields (omitted when 0).

### inject_ptb.py (commit 3)

Added `--vxlan-port` argument (default 4789).
The embedded UDP header `dstport` uses the configured value.

---

## Non-4789 lab scenario (design; not run — requires Linux)

To test port 8472 with the existing netns lab:

```bash
# 1. Destroy and recreate vxlan0 with port 8472
sudo ip netns exec ns1 ip link del vxlan0
sudo ip netns exec ns1 ip link add vxlan0 type vxlan \
    id 42 dstport 8472 local 192.168.100.1 remote 192.168.100.2 \
    dev veth1 nolearning

# 2. Configure and bring up
sudo ip netns exec ns1 ip addr add 10.0.0.1/24 dev vxlan0
sudo ip netns exec ns1 ip link set vxlan0 mtu 1450
sudo ip netns exec ns1 ip link set vxlan0 up

# 3. Verify reported port
sudo ip netns exec ns1 ip -d link show vxlan0
# Expected: "vxlan id 42 remote 192.168.100.2 local 192.168.100.1 dstport 8472 ..."

# 4. Run vxlan-tracer with explicit port
sudo ./dist/vxlan-tracer \
    --overlay vxlan0 --underlay veth1 \
    --vxlan-port 8472 --duration 15s --json

# OR let auto-detect pick it up (--vxlan-port 0 / default):
sudo ./dist/vxlan-tracer \
    --overlay vxlan0 --underlay veth1 \
    --duration 15s --json
# Expected startup log: "vxlan port: 8472 (auto-detected)"

# 5. Inject PTBs with matching port
sudo ip netns exec ns2 python3 spikes/inject_ptb.py \
    --src 192.168.100.2 --dst 192.168.100.1 \
    --dev veth2 --vxlan-port 8472 --count 5

# 6. Expected JSON output (PTB_DELIVERED or PTB_SUPPRESSED):
# {
#   "verdict": "PTB_DELIVERED",
#   "vxlan_port": 8472,
#   "vxlan_vni": 42,
#   "ptb_ingress_total": 5,
#   ...
# }
```

This scenario is not run here because it requires a Linux kernel with BPF
support. It will be run if a real k3s/flannel environment is available.

---

## What is proven (Day 11 commits 1–3)

- Go build, vet, tests clean on macOS (non-Linux build path)
- BPF C compiles without error (verified via CI on x86_64 6.8.0-1052-azure)
- Byte-order conversion logic is correct by analysis (see above)
- inject_ptb.py accepts --vxlan-port; default behavior unchanged (4789)
- internal/netlink.DetectVXLAN stub compiles on non-Linux

## What is NOT proven

- BPF verifier accepts the vxlan_config map lookup on-kernel
- Port 8472 PTB match works end-to-end (no 8472 environment available)
- Auto-detect returns correct port on a real VXLAN interface (needs Linux)
- VNI is read correctly via rtnetlink Vxlan.VxlanId (needs Linux VXLAN interface)
