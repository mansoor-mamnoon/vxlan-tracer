# vxlan-tracer

An eBPF-based diagnostic tool for VXLAN MTU blackholes.

**Status: repeatable lab prototype — all five verdicts proven end-to-end via an
automated scenario runner (Day 7). Binary reruns in the same container are
idempotent (no manual cleanup required). Not production-validated.**

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

## Usage (target)

```sh
# requires root / CAP_BPF + CAP_NET_ADMIN
sudo vxlan-tracer --overlay vxlan0 --underlay eth0

# run for 30 seconds then print diagnosis
sudo vxlan-tracer --overlay vxlan0 --underlay eth0 --duration 30s

# JSON output for structured parsing
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
| CI test suite | not started |

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
  "max_outer_ip_len": 1438
}
```

`frag_max_skb_len` appears only when fragmentation is observed. Its value at
ip_do_fragment entry is kernel-dependent (may be the outer or inner IP length
depending on kernel version and route MTU cache state).

### What is proven (as of Day 7)

- All four active verdict paths execute in a single automated Docker run via
  `scripts/run-scenarios.sh` (4/4 pass, exit 0).
- Binary reruns in the same container are idempotent: no "file exists" error,
  no stale counter false positives.
- PTB suppression detection works end-to-end: TC ingress count vs. icmp_rcv
  count correctly captures the iptables DROP delta.
- Fragmentation verdict uses two-signal corroboration: both ip_do_fragment
  kprobe and TC egress max packet size must agree for the strongest verdict.
- Exit code 0 = verdict produced; exit code 2 = tool/runtime error.

### What is not proven

- ip_do_fragment events are not scoped to VXLAN traffic (the kprobe is global).
  On a busy host with non-VXLAN fragmentation, `frag_events_total` will be
  inflated. The verdict message says so explicitly.
- Production Kubernetes environments are not tested. Only a two-namespace
  veth pair lab on a linuxkit ARM64 kernel is proven.
- x86_64 kernels are not tested.

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
