# evidence/day-02-linux-env.md

Linux environment check results from Day 2.
Executed inside a Docker privileged container (Docker Desktop 28.3.2 on macOS arm64).
This is the nearest available Linux host; see docs/linux-dev-environment.md for rationale.

## Environment

| Item | Value |
|------|-------|
| Container image | ubuntu:22.04 |
| Host kernel | 6.10.14-linuxkit #1 SMP Thu Aug 14 19:26:13 UTC 2025 |
| Architecture | aarch64 |
| Docker version | 28.3.2 |
| Privilege mode | --privileged |
| Date | 2026-06-14 |

## Full `uname -a` output

```
Linux 726e37ab0e2f 6.10.14-linuxkit #1 SMP Thu Aug 14 19:26:13 UTC 2025 aarch64 aarch64 aarch64 GNU/Linux
```

## Kernel symbol check

```
# grep -E '^[0-9a-f]+ [Tt] ip_do_fragment$' /proc/kallsyms
ffff800080ff71d8 T ip_do_fragment

# grep -E '^[0-9a-f]+ [Tt] __ip_finish_output$' /proc/kallsyms
ffff800080ff77a0 t __ip_finish_output

# grep -E '^[0-9a-f]+ [Tt] icmp_send$' /proc/kallsyms
(no output — icmp_send is NOT a T symbol on this kernel)

# grep -E '^[0-9a-f]+ [Tt] icmp_rcv$' /proc/kallsyms
ffff8000810425 T icmp_rcv

# grep 'icmp_send' /proc/kallsyms | grep -v '__'
(no output)

# grep '__traceiter_icmp_send\|__bpf_trace_icmp_send\|__probestub_icmp_send' /proc/kallsyms
ffff8000810402d8 T __traceiter_icmp_send
ffff800081040350 T __probestub_icmp_send
ffff800081040590 t __bpf_trace_icmp_send
```

### Symbol findings

| Symbol | Found | Type | Notes |
|--------|-------|------|-------|
| `ip_do_fragment` | YES | `T` (exported) | kprobeable; confirmed firing via ftrace |
| `__ip_finish_output` | YES | `t` (local) | fallback; lowercase = not exported |
| `icmp_send` | NO | — | exists only as tracepoint infrastructure |
| `icmp_rcv` | YES | `T` (exported) | kprobeable |
| `__traceiter_icmp_send` | YES | `T` | tracepoint iterator; see docs/linux-dev-environment.md |

**Key finding:** `icmp_send` is NOT an exported kprobeable function on kernel 6.10.14-linuxkit.
It exists only as tracepoint infrastructure. `spikes/bpftrace/icmp_send.bt` must use
`tracepoint:net:icmp_send` rather than `kprobe:icmp_send` on this kernel.

## BTF

```
-r--r--r-- 1 root root 6237148 ... /sys/kernel/btf/vmlinux
```

BTF is present (6.2 MB). fentry programs should be supported. bpftrace 0.14 still
fails on this kernel despite BTF being available (packaging issue; see below).

## Tool versions

```
bpftrace v0.14.0
Ubuntu clang version 14.0.0-1ubuntu1.1
ip utility, iproute2-5.15.0, libbpf 0.5.0
Python 3.10.12
scapy 2.7.0
```

## Network namespace support

```
ip netns list  →  exit 0  (confirmed working)
ip netns add ns1  →  success
```

## BPF syscall

The BPF syscall is available. Confirmed by earlier session: `BPF_MAP_CREATE` returned
valid fd via Python ctypes (using correct aarch64 syscall number 280).

## linux-env-check.sh results (Docker container)

Ran `scripts/linux-env-check.sh` inside a ubuntu:22.04 privileged container.
Summary:

```
=== Summary ===
  PASS : 14
  WARN : 4
  FAIL : 0
```

WARN items:
- `icmp_send` not found as T symbol (expected: use tracepoint instead)
- bpftrace version: 0.14.0 installed, probe script requires 0.16+
- `linux/types.h` missing: bpftrace fails with header not found (packaging issue)
- `__ip_finish_output` found as `t` (lowercase), not exported

FAIL items: None (all required symbols present or have documented workarounds).

## bpftrace failures

```
$ bpftrace -e 'BEGIN { printf("hello\n"); exit(); }'
/bpftrace/include/clang_workarounds.h:14:10: fatal error: 'linux/types.h' file not found

$ bpftrace -l 'tracepoint:net:*'
terminate called after throwing an instance of 'std::runtime_error'
  what():  Could not read symbols from /sys/kernel/debug/tracing/available_events: No such file or directory

$ bpftrace -e 'tracepoint:net:icmp_send { printf("hit\n"); exit(); }'
stdin:1:1-25: ERROR: tracepoint not found: net:icmp_send
```

bpftrace 0.14.0 fails on linuxkit because:
1. The ubuntu:22.04 package was compiled without `linux/types.h` in the include path.
2. bpftrace 0.14 looks for events in `/sys/kernel/debug/tracing/` (debugfs mount) but
   the kernel only exposes tracefs at `/sys/kernel/tracing/`.
3. Even after mounting debugfs, `BEGIN_trigger` symbol resolution fails on 6.10.x.

**Workaround used:** raw ftrace kprobe_events interface via `/sys/kernel/tracing/kprobe_events`.
This is demonstrated in evidence/day-02-traffic.md and confirmed to work.

## ip_do_fragment confirmed in ftrace available_filter_functions

```
# grep -c ip_do_fragment /sys/kernel/tracing/available_filter_functions
1
```

ip_do_fragment is listed in `available_filter_functions`, confirming it is kprobeable
via the raw ftrace interface even though bpftrace 0.14 cannot attach to it.
