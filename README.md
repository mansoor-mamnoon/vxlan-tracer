# vxlan-tracer

An eBPF-based diagnostic tool for VXLAN MTU blackholes.

**Status: spike / prototype — the BPF programs are not yet implemented.**

---

## What it diagnoses

In Kubernetes and other VXLAN-based overlay networks, VXLAN encapsulation adds
50 bytes of overhead to every packet (outer ETH 14 + IP 20 + UDP 8 + VXLAN
header 8). If the overlay interface MTU is left at 1500 (same as the underlay),
inner packets up to 1500 bytes produce outer frames up to 1564 bytes — 64 bytes
over the typical underlay MTU of 1500.

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
| CLI skeleton | done (exits with error — BPF not implemented) |
| Lab topology scripts | done (Linux-only) |
| bpftrace spike probes | done (Linux-only) |
| TC egress BPF (C) | not started |
| TC ingress BPF (C) | not started |
| ip_do_fragment kprobe (C) | not started |
| icmp_rcv fentry (C) | not started |
| Go controller (map polling) | not started |
| Diagnosis output | not started |
| CI test suite | not started |

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
