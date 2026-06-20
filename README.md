# vxlan-tracer

An eBPF-based diagnostic tool for VXLAN MTU blackholes.

**Symptom:** small requests work (ping, tiny HTTP), but large requests silently stall
or fragment (file transfers, kubectl cp, large API payloads). No error is logged.

**Status:** lab-validated prototype — 6/6 scenario variants pass on aarch64
(5.15.0-181-generic) and x86_64 (6.8.0-1059-azure); ports 4789 and 8472 confirmed.
Not tested against a real k3s/flannel cluster; lab-only veth topology.

---

## Quick demo (Linux + root + compiled binary + BPF objects)

```sh
make bpf          # compile BPF objects (Linux only)
make demo         # ~25 s self-contained stale-MTU lab demo
```

Expected output:

```
Verdict:  VXLAN_FRAGMENTATION_OBSERVED
Evidence:
  ip_do_fragment events:   6
  largest outer IP seen:   1438 B
  underlay MTU:            1400 B  (outer packet exceeded by 38 B)
Recommendation:
  set overlay MTU to 1350 B or lower
  (VXLAN overhead is 50 B; safe overlay MTU = underlay MTU − 50)
Scope:
  global fragmentation counter corroborated by VXLAN TC egress
  (both ip_do_fragment and oversized outer packets observed)
  See docs/fragmentation-scoping.md for limitations.
```

---

## What it diagnoses

In Kubernetes and other VXLAN-based overlay networks, VXLAN encapsulation adds
50 bytes of overhead to every packet (outer ETH 14 + IP 20 + UDP 8 + VXLAN
header 8). If the overlay interface MTU is left at 1500 (same as the underlay),
inner IP packets up to 1500 bytes produce outer IP packets up to 1550 bytes —
50 bytes over the typical underlay IP MTU of 1500 (the wire frame is 1564 bytes
including the outer Ethernet header, but the kernel MTU check is at the IP layer).

The result is a silent blackhole:

- Small traffic (ping, small HTTP responses): passes.
- Large traffic (file transfers, kubectl cp, large API payloads): silently stalls
  after a few kilobytes.

No error is logged. No obvious signal is visible in application logs.

vxlan-tracer attaches eBPF programs to the VXLAN overlay egress path and the
underlay ingress path to detect and diagnose this condition without modifying
any configuration.

## How it works (target architecture)

```
vxlan0 (overlay)
  └─ TC egress BPF      ← reads inner IP 5-tuple + pkt size before VXLAN encap

eth0 / underlay (physical)
  ├─ TC ingress BPF     ← counts ICMP PTBs arriving before netfilter (iptables)
  └─ kprobe icmp_rcv    ← counts PTBs after netfilter (suppression = delta > 0)

Kernel functions:
  ├─ kprobe ip_do_fragment  ← detects outer-packet fragmentation (DF=0 default)
  └─ kprobe icmp_send       ← detects locally-generated PTBs (DF=1 configured)
```

Linux VXLAN defaults to DF=0 on the outer IP header, so oversized outer packets
are fragmented rather than PTB-signaled. Fragmented VXLAN UDP is typically
silently dropped by cloud provider fabric and AWS/GCP/Azure VPC routing.
`ip_do_fragment` detection is therefore required for the tool to be useful on
default Flannel/Calico VXLAN deployments.

## What this tool is NOT

See [docs/forbidden-claims.md](docs/forbidden-claims.md) for the full list.
Short version:

- Not XDP-powered. TC egress and kprobes are the correct hooks.
- Not zero-config. Requires `--overlay` and `--underlay` interface names, plus
  `CAP_BPF` and `CAP_NET_ADMIN` (or root).
- Not production-validated. Lab-tested only.
- Not able to extract inner flow 5-tuple from ICMP PTB. The PTB payload
  contains only the outer IP + outer UDP header.
- Not a replacement for tcpdump (which can see pre-netfilter PTBs via
  AF_PACKET). The unique value is automated diagnosis and in-kernel count
  comparison across two hooks.

## Requirements

| Requirement      | Minimum version |
|-----------------|-----------------|
| Linux kernel    | 5.15+ (fentry/BTF required) |
| clang/llvm      | 12+             |
| bpftool         | kernel-matched  |
| Go              | 1.21+           |
| CAP_BPF + CAP_NET_ADMIN | or root |

This tool runs on **Linux only**. It cannot run on macOS or Windows.

## Build and install

```sh
# Build native binary (any platform; BPF objects compiled separately on Linux)
make build

# Cross-compile Linux binaries + per-arch release tarballs with checksums
make package                       # VERSION=dev (untagged)
VERSION=v0.1.0 make package        # embed a release version tag

# Install to /usr/local/bin (Linux only)
sudo make install

# Check version
dist/vxlan-tracer --version
# vxlan-tracer v0.1.0 (commit abc1234, built unknown)
```

## Usage

```sh
# Requires root / CAP_BPF + CAP_NET_ADMIN
sudo vxlan-tracer --overlay vxlan0 --underlay eth0

# VXLAN port auto-detected from overlay interface (default)
# For k3s/Flannel (port 8472): rtnetlink reads it from flannel.1
sudo vxlan-tracer --overlay flannel.1 --underlay eth0 --duration 30s

# Explicit port override (e.g. non-VXLAN interface in a test lab)
sudo vxlan-tracer --overlay vxlan0 --underlay eth0 --vxlan-port 4789

# JSON output for structured parsing or further processing
sudo vxlan-tracer --overlay vxlan0 --underlay eth0 --json
```

## Development status

| Component | Status |
|-----------|--------|
| CLI skeleton | done — attaches BPF, pins maps, reads them, prints a verdict |
| Lab topology scripts | done (Linux-only) |
| bpftrace spike probes | done (Linux-only) |
| TC egress BPF (C) | done — `tc_egress_track_flow`, pinned `flow_state` map |
| TC ingress BPF (C) | done — `tc_ingress_count_ptb`, pinned `ptb_ingress_*` maps |
| icmp_rcv kprobe (C) | done — CO-RE filtered to ICMP type=3/code=4, pinned `icmp_rcv_total` |
| ip_do_fragment kprobe (C) | done — CO-RE skb->len read; `frag_events_total` map (Day 6) |
| Go controller (attach + pin + read) | done — `internal/loader`, `internal/bpfmap` |
| Diagnosis engine | done — `internal/diag/verdict.go`, 5-verdict precedence logic |
| Structured (JSON) output | done — `--json` flag; proven for frag and PTB paths (Day 6) |
| Human-readable output | done — labelled sections per verdict (Verdict/Evidence/Recommendation/Scope) |
| Demo script | done — `make demo` runs a ~25 s stale-MTU lab end-to-end |
| Stale BPF integration test | done — `make test-stale-bpf`; CI step in x86-smoke.yml |
| CI test suite | done — x86-smoke.yml + arm-smoke.yml on GitHub Actions |

All five verdicts (PTB_DELIVERED, PTB_SUPPRESSED, VXLAN_FRAGMENTATION_OBSERVED,
VXLAN_MTU_MISCONFIGURATION, NO_ISSUE_OBSERVED) are reachable through the actual
Go binary. PTB paths proven in Day 5; DF=0 fragmentation path proven in Day 6;
automated scenario runner (4/4 pass, idempotent reruns) proven in Day 7 —
see `evidence/` directory.

## Demo: proven JSON outputs

The following outputs were captured from a running Docker container
(ubuntu:22.04, kernel 6.10.14-linuxkit, aarch64). They are not fabricated.

### PTB_SUPPRESSED — iptables DROP rule active

```json
{
  "verdict": "PTB_SUPPRESSED",
  "message": "5 ICMP type=3/code=4 packet(s) were observed at TC ingress, but 0 reached icmp_rcv: something between the NIC and icmp_rcv — commonly a netfilter/iptables DROP rule — is suppressing PTBs before the kernel can act on them.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 0,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

### VXLAN_FRAGMENTATION_OBSERVED — oversized VXLAN traffic (DF=0 default)

```json
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "message": "6 ip_do_fragment invocation(s) were observed while vxlan-tracer was attached; concurrently, the TC egress hook recorded an outer packet length of 1438 bytes, 38 bytes over the underlay MTU (1400). Fragmentation was observed while oversized VXLAN traffic was present — these two signals together are consistent with VXLAN outer packets triggering ip_do_fragment. Note: ip_do_fragment is a global kernel function and may include non-VXLAN fragmentation events on a busy host. Fragmented VXLAN UDP is commonly dropped silently by cloud fabric; in a local lab fragments may reassemble — fragmentation observed here does not by itself confirm packet loss.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 0,
  "icmp_rcv_total": 0,
  "frag_events_total": 6,
  "frag_max_skb_len": 1438,
  "max_outer_ip_len": 1438,
  "fragmentation_scope": "global_corroborated"
}
```

`frag_max_skb_len` appears only when fragmentation is observed. Its value at
ip_do_fragment entry is kernel-dependent (may be the outer or inner IP length
depending on kernel version and route MTU cache state).

### PTB_DELIVERED — port 8472 (k3s/Flannel default)

```json
{
  "verdict": "PTB_DELIVERED",
  "message": "5 ICMP type=3/code=4 packet(s) were observed at TC ingress and 5 reached icmp_rcv: PTBs are reaching the kernel's ICMP handling path, not being suppressed.",
  "overlay": "vxlan0",
  "underlay": "veth1",
  "vxlan_port": 8472,
  "vxlan_vni": 42,
  "overlay_mtu": 1450,
  "underlay_mtu": 1400,
  "recommended_overlay_mtu": 1350,
  "ptb_ingress_total": 5,
  "icmp_rcv_total": 5,
  "frag_events_total": 0,
  "max_outer_ip_len": 0
}
```

Captured from a netns lab with `vxlan0` created as `ip link add vxlan0 type vxlan dstport 8472`.
Not captured from a real k3s/flannel node; `ip -d link` on a real cluster is the authoritative
source of the port in use.

`fragmentation_scope` is present only for fragmentation verdicts:
- `global_corroborated`: both ip_do_fragment fired AND TC egress saw outer packets over the underlay MTU — the two signals agree.
- `global_unscoped`: ip_do_fragment fired but TC egress did not corroborate an oversized VXLAN outer packet. The counter may include non-VXLAN fragmentation.

See `docs/fragmentation-scoping.md` for the five scoping options considered and why `bpf_get_netns_cookie`-based scoping is not feasible on this kernel.

### What is proven (as of Day 13)

**Kernel and architecture coverage:**
- 6.10.14-linuxkit aarch64 (Docker Desktop): 5/5 scenarios pass (Day 7–8)
- 5.15.0-181-generic aarch64 (Ubuntu 22.04 Lima VM): 6/6 scenarios pass including port-8472 (Day 9, 12–13)
- 6.8.0-1052-azure x86_64 (GitHub Actions ubuntu-22.04): 5/5 scenarios pass (Day 10)
- 6.8.0-1059-azure x86_64 (GitHub Actions ubuntu-22.04): 6/6 scenarios pass including port-8472 (Day 13)
- All three kernels produce identical verdicts and JSON field values

**BPF / kprobe / CO-RE:**
- All five verdict paths execute end-to-end via `scripts/run-scenarios.sh` on all 3 kernels
- BPF verifier accepts all four programs on all 3 kernels
- CO-RE BTF relocation resolves `skb->len` correctly on all 3 kernels
- ip_do_fragment kprobe attaches and counts correctly on all 3 kernels
- icmp_rcv kprobe filters correctly to ICMP type=3/code=4 on all 3 kernels
- TC sched_cls ingress and egress attach and count correctly on all 3 kernels
- PT_REGS_PARM1 confirmed on both architectures:
  - aarch64: `ctx->regs[0]` (ARM64 ABI x0 register) — Day 7-9
  - x86_64: `ctx->di` (System V AMD64 ABI rdi register) — Day 10

**Scoping and corroboration:**
- `bpf_get_netns_cookie` NOT available for kprobe/sched_cls on aarch64 kernels:
  - 6.10.14: "program of this type cannot use helper bpf_get_netns_cookie#122"
  - 5.15.0: "unknown func bpf_get_netns_cookie#122"
- ip_do_fragment header parsing via `skb->network_header` unreliable on all kernels
- Two-signal corroboration (`global_corroborated`) fires correctly on all 3 kernels
- `ip route flush cache` effective on all 3 kernels for PMTU reset between runs

**Idempotency:**
- Binary reruns in the same container/VM are idempotent after route cache flush
- Exit code 0 = verdict produced; exit code 2 = tool/runtime error

### CNI port reference (documentation-based; no two-node cluster tested)

| CNI | VXLAN port | Auto-detect | Notes |
|-----|-----------|-------------|-------|
| k3s/Flannel ≥ 0.9 | 8472 | Yes (via rtnetlink) | k3s bundles Flannel; uses 8472 by default |
| Flannel standalone ≥ 0.9 | 4789 | Yes | Switched to IANA port after 0.9 |
| Flannel standalone < 0.9 | 8472 | Yes | Legacy non-IANA default |
| Calico (VXLAN mode) | 4789 | Yes | Interface: vxlan.calico |
| Cilium (VXLAN mode) | 4789 | Yes | Interface: cilium_vxlan |

None of the above have been validated with a real two-node cluster. The
table reflects the VXLAN port used by each CNI per its documentation and
source code. See `docs/kubernetes-validation.md` for the strict definition
of what constitutes a validated CNI entry.

### What is not proven

- ip_do_fragment events are not scoped to VXLAN traffic (the kprobe is global).
  On a busy host with non-VXLAN fragmentation, `frag_events_total` will be
  inflated. The verdict message says so explicitly. VXLAN-specific scoping is not
  feasible on any tested kernel; see `docs/fragmentation-scoping.md`.
- Production Kubernetes environments are not tested. Lab-only, two-namespace veth topology.
  See `docs/kubernetes-validation.md` for the two-node requirement.
- VXLAN port auto-detect (rtnetlink) proven on 5.15.0-181-generic aarch64 with both 4789
  and 8472 VXLAN interfaces. `DetectVXLAN` reads `IFLA_VXLAN_PORT` correctly via
  `vishvananda/netlink.Vxlan.Port`. Not tested against a real CNI node (k3s/flannel.1).
- Other kernel versions: 5.10.x, 6.1.x, 6.5.x not tested.
- `bpf_get_netns_cookie` not retested on x86_64 (expected same UNSUPPORTED result).

### Validated kernel matrix (as of Day 13)

| Kernel | Distro | Arch | Environment | Scenarios |
|--------|--------|------|-------------|-----------|
| 6.10.14-linuxkit | Docker Desktop | aarch64 | Docker `--privileged` | 5/5 PASS |
| 5.15.0-181-generic | Ubuntu 22.04.5 LTS | aarch64 | Lima VM (macOS VZ) | 6/6 PASS (incl. port 8472) |
| 6.8.0-1052-azure | Ubuntu 22.04.5 LTS | x86_64 | GitHub Actions | 5/5 PASS |
| 6.8.0-1059-azure | Ubuntu 22.04.5 LTS | x86_64 | GitHub Actions | 6/6 PASS (incl. port 8472) |

All results from netns lab (single-host veth topology). No two-node CNI cluster tested.

## Lab setup

See [docs/lab-topology.md](docs/lab-topology.md) and the scripts in `scripts/`.

```sh
sudo make lab-up
make smoke-small
make smoke-large
sudo make lab-down
```

## Project structure

```
bpf/              BPF C programs (to be written)
cmd/vxlan-tracer/ Go entrypoint
docs/             Architecture and design docs
evidence/         Command logs and test results
internal/         Go packages (diag, netlink, output)
scripts/          Lab setup and smoke test scripts
spikes/bpftrace/  bpftrace prototype probes (Linux-only)
```

## License

MIT
