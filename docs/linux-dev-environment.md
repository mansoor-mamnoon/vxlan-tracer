# docs/linux-dev-environment.md

Development environment strategy and Linux host constraints.

## Problem

vxlan-tracer requires Linux for all kernel work: network namespaces, BPF programs,
bpftrace probes, `/proc/kallsyms`, and `/sys/kernel/btf/vmlinux`. The primary development
machine is macOS (Darwin arm64). A bare-metal Linux host is not currently available.

## Solution: Docker Desktop as Linux host

Docker Desktop 28.3.2 on macOS provides a Linux VM running kernel 6.10.14-linuxkit
(aarch64). Privileged containers (`--privileged`) give access to:

- `/proc/kallsyms` (kernel symbol table)
- `/sys/kernel/btf/vmlinux` (BTF type information)
- `/sys/kernel/tracing/` (tracefs; raw ftrace interface)
- `ip netns` (network namespaces)
- BPF syscall (BPF_MAP_CREATE, etc.)

### What works in Docker linuxkit

| Capability | Status | Notes |
|------------|--------|-------|
| `/proc/kallsyms` | WORKS | 65,551 symbols visible |
| `/sys/kernel/btf/vmlinux` | WORKS | 6.2 MB |
| `ip netns` | WORKS | ns creation and deletion confirmed |
| Raw ftrace kprobes | WORKS | ip_do_fragment confirmed firing |
| BPF syscall | WORKS | BPF_MAP_CREATE returns valid fd |
| VXLAN encapsulation | WORKS | vxlan0 creation and ICMP confirmed |
| iptables | WORKS | INPUT DROP rule for ICMP PTB tested |
| bpftrace 0.14.0 | BROKEN | see below |
| clang BPF compilation | NOT TESTED | linux-headers missing from ubuntu:22.04 default |

### What does NOT work in Docker linuxkit

**bpftrace 0.14.0 on ubuntu:22.04 package:**

The ubuntu:22.04 bpftrace package (0.14.0) fails because:
1. It was compiled expecting `linux/types.h` in `/bpftrace/include/` — not present.
2. It reads `available_events` from `/sys/kernel/debug/tracing/` (debugfs) but the
   linuxkit kernel exposes tracefs at `/sys/kernel/tracing/` instead.
3. Even after mounting both debugfs and tracefs, the `BEGIN_trigger` symbol resolution
   fails on kernel 6.10.x — a known incompatibility with bpftrace < 0.16.

Workarounds explored:
- `mount -t debugfs debugfs /sys/kernel/debug` — does not fix BEGIN_trigger issue
- `mount -t tracefs tracefs /sys/kernel/tracing` — tracefs already mounted; bpftrace
  still cannot find `available_events` in the expected location
- Installing kernel headers — would require `linux-headers-6.10.14-linuxkit` which is
  not available in ubuntu:22.04 apt repositories

**Required fix (deferred to Day 3):** Use a Lima VM with Ubuntu 22.04 or 24.04 on the
native kernel, where bpftrace >= 0.16 and matching kernel headers can be installed.
Alternatively, use a Vagrant box or a cloud VM (e.g., GCP e2-micro free tier with
Ubuntu 22.04 LTS) where kernel headers match the running kernel.

## icmp_send: tracepoint-only on kernel 6.10.14

`icmp_send` is not an exported kernel symbol (`T`) on 6.10.14-linuxkit:

```
$ grep -E '^[0-9a-f]+ T icmp_send$' /proc/kallsyms
(no output)
```

It exists only as tracepoint infrastructure:
```
ffff8000810402d8 T __traceiter_icmp_send
ffff800081040350 T __probestub_icmp_send
ffff800081040590 t __bpf_trace_icmp_send
```

This means `kprobe:icmp_send` in bpftrace will fail even on a working bpftrace install.

**Fix applied:** `spikes/bpftrace/icmp_send.bt` updated to use `tracepoint:net:icmp_send`
as the primary probe. The kprobe version is kept as a comment for older kernels where
`icmp_send` is a T symbol (typically kernel < 5.15 or some distro kernels).

**Note on tracepoint args:** The `tracepoint:net:icmp_send` exposes only `type` and `code`,
not the `info` field (next_hop_mtu). To read next_hop_mtu, use `kprobe:__traceiter_icmp_send`
and read arg2 which is the `info` parameter — but the arg layout differs from the raw
`icmp_send` signature. See `spikes/bpftrace/icmp_send.bt` comments.

## Recommended Day 3 Linux environment

For full bpftrace probe execution, use one of:

1. **Lima VM** (`brew install lima && limactl start --name=vxlan template://ubuntu-lts`):
   - Provides Ubuntu 22.04 or 24.04 LTS with matching kernel headers
   - bpftrace >= 0.19 available via apt on Ubuntu 24.04
   - Shares files with macOS host via 9p filesystem

2. **GCP f1-micro** (Ubuntu 22.04 LTS):
   - Free tier eligible
   - `apt install linux-tools-$(uname -r) bpftrace` works correctly
   - Kernel headers match running kernel

3. **Vagrant + libvirt/VirtualBox**:
   - `vagrant up ubuntu/jammy64` then `vagrant ssh`
   - Works on macOS with VirtualBox provider

For the BPF C program compilation work (Day 3 primary goal), clang and kernel headers
must be installed on the same machine running the target kernel.

## Raw ftrace as bpftrace fallback

When bpftrace is unavailable, the raw ftrace kprobe interface provides equivalent
event counting with less overhead:

```sh
# register kprobe
echo 'p:ip_do_frag ip_do_fragment' > /sys/kernel/tracing/kprobe_events

# enable event collection
echo 1 > /sys/kernel/tracing/events/kprobes/ip_do_frag/enable
echo 1 > /sys/kernel/tracing/tracing_on

# generate traffic
ip netns exec ns1 ping -c 10 -s 1360 -q 10.244.0.2

# read events
cat /sys/kernel/tracing/trace | grep ip_do_frag

# disable and clean up
echo 0 > /sys/kernel/tracing/tracing_on
echo > /sys/kernel/tracing/trace
echo '-:ip_do_frag' > /sys/kernel/tracing/kprobe_events
```

This approach was used on Day 2 to confirm ip_do_fragment fires as expected.
See evidence/day-02-traffic.md for actual output.
