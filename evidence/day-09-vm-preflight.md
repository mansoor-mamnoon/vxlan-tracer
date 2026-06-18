# Day 9 — VM preflight check output

**Date:** 2026-06-17
**VM:** Lima vxlan-test (macOS VZ hypervisor)
**Kernel:** 5.15.0-181-generic (Ubuntu 22.04.5 LTS aarch64)

This is the first preflight run on a non-linuxkit kernel.

## Command

```sh
sudo bash scripts/preflight.sh
```

Run from `/tmp/vxlan-tracer` inside the Lima VM.

## Output

```
=== vxlan-tracer preflight check ===

-- OS / Kernel --
  INFO  Linux lima-vxlan-test 5.15.0-181-generic #191-Ubuntu SMP Fri May 22 19:27:05 UTC 2026 aarch64 aarch64 aarch64 GNU/Linux
  PASS  Linux
  PASS  Kernel 5.15.0-181-generic >= 5.15 (CO-RE/BTF required minimum)

-- Privileges --
  PASS  Running as root

-- BTF (CO-RE prerequisite) --
  PASS  /sys/kernel/btf/vmlinux exists (5996068 bytes)

-- bpffs --
  PASS  bpffs mounted (/sys/fs/bpf)

-- Required commands --
  PASS  ip (/usr/sbin/ip)
  PASS  iptables (/usr/sbin/iptables)
  PASS  python3 (/usr/bin/python3)
  PASS  nsenter (/usr/bin/nsenter)

-- Build tools --
  PASS  clang (Ubuntu clang version 14.0.0-1ubuntu1.1)
  PASS  go (go version go1.21.13 linux/arm64)
  PASS  make (GNU Make 4.3)

-- Optional tools --
  PASS  bpftool (/usr/lib/linux-tools/5.15.0-181-generic/bpftool v5.15.199)
  PASS  ping (/usr/bin/ping)

-- Python scapy (PTB injection) --
  PASS  scapy 2.7.0

-- libbpf headers (BPF compilation) --
  PASS  /usr/include/bpf/bpf_helpers.h found
  PASS  /usr/include/linux/bpf.h found

-- Kernel symbols (kprobe targets) --
  PASS  ip_do_fragment is a T symbol (kprobeable)
  PASS  icmp_rcv is a T symbol (kprobeable)

-- Network namespace support --
  PASS  ip netns works

===================================
Preflight summary:
  PASS: 20
  WARN: 0
  FAIL: 0
===================================
RESULT: PASS — all checks passed.
```

## Findings

- **ip_do_fragment** is a kprobeable T symbol on 5.15.0-181-generic — same as 6.10.14-linuxkit.
- **icmp_rcv** is a kprobeable T symbol — same as 6.10.14-linuxkit.
- **BTF** is present and large (5.8 MB). Ubuntu 22.04 ships with CONFIG_DEBUG_INFO_BTF=y.
- **bpftool** is available and kernel-matched (v5.15.199 for kernel 5.15.0-181).
  On linuxkit, bpftool was a wrapper that did not match the running kernel.
- **bpffs** is already mounted by the Ubuntu 22.04 default systemd setup.
- All 20 checks PASS. Environment is ready for BPF compilation and scenario run.
