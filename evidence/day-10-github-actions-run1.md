# Day 10 GitHub Actions — Run 1 (run 27743347938)

**Date:** 2026-06-18
**Workflow:** x86-smoke.yml
**Runner:** ubuntu-22.04 (GitHub-hosted, Azure centralus)
**Trigger:** push to main (commit f23e9b7)
**Outcome:** partial — preflight PASS, BPF compile FAIL

---

## Environment captured

```
uname -a:
  Linux runnervmqtt2i 6.8.0-1052-azure #58~22.04.1-Ubuntu SMP Thu Mar 26 05:02:21 UTC 2026 x86_64 x86_64 x86_64 GNU/Linux

Architecture: x86_64
Distro: Ubuntu 22.04.5 LTS
Kernel: 6.8.0-1052-azure (Azure infrastructure kernel — NOT 5.15.x)
BTF: -r--r--r-- 1 root root 5.8M Jun 18 07:18 /sys/kernel/btf/vmlinux
     6020051 bytes
bpffs: bpf on /sys/fs/bpf type bpf (rw,nosuid,nodev,noexec,relatime,mode=700)
       (pre-mounted — runner provides bpffs out of the box)

Capabilities:
  runner (non-root): CapEff = 0000000000000000  (no capabilities)
  root (sudo):       CapEff = 000001ffffffffff   (full capabilities)

bpftool: v7.4.0 (from linux-tools-generic, installed by workflow)
clang: Ubuntu clang version 14.0.0-1ubuntu1.1
Go: go1.21.13 linux/amd64
```

**Key observation:** ubuntu-22.04 runners on GitHub Actions currently use kernel
6.8.0-1052-azure, not 5.15.x. The runner image version was 20260607.168.1. This
is an Azure infrastructure kernel, different from the vanilla Ubuntu 22.04 LTS
kernel shipped by Canonical. However, it is x86_64 and provides BTF.

---

## Step results

### Capture kernel and architecture — PASS
All fields captured (see above).

### Set up Go — PASS
Go 1.21.13 installed.

### Install build dependencies — PASS
clang 14, libbpf-dev, linux-tools-generic, iproute2, scapy 2.7.0 all installed.
Note: `linux-tools-$(uname -r)` resolved to linux-tools-5.15.0-181-generic
(package existed) even though the running kernel is 6.8.0-1052-azure.
bpftool v7.4.0 was provided by linux-tools-generic.

### Mount bpffs — PASS (already mounted)
```
[setup-bpf-fs] bpffs already mounted.
[setup-bpf-fs] Creating pin directory /sys/fs/bpf/vxlan-tracer...
```

### Run preflight check — PASS (20/20 using old preflight)
```
=== vxlan-tracer preflight check ===
  PASS  Linux
  PASS  Kernel 6.8.0-1052-azure >= 5.15 (CO-RE/BTF required minimum)
  PASS  Running as root
  PASS  /sys/kernel/btf/vmlinux exists (6020051 bytes)
  PASS  bpffs mounted (/sys/fs/bpf)
  PASS  ip (/usr/sbin/ip)
  PASS  iptables (/usr/sbin/iptables)
  PASS  python3 (/usr/bin/python3)
  PASS  nsenter (/usr/bin/nsenter)
  PASS  clang (Ubuntu clang version 14.0.0-1ubuntu1.1)
  PASS  go (version unknown)
  PASS  make (GNU Make 4.3)
  PASS  bpftool (bpftool v7.4.0)
  PASS  ping (/usr/bin/ping)
  PASS  scapy 2.7.0
  PASS  /usr/include/bpf/bpf_helpers.h found
  PASS  /usr/include/linux/bpf.h found
  PASS  ip_do_fragment is a T symbol (kprobeable)
  PASS  icmp_rcv is a T symbol (kprobeable)
  PASS  ip netns works

PASS: 20  WARN: 0  FAIL: 0
RESULT: PASS — all checks passed.
```

Note: this used the preflight before the Day 10 commit 2 capability checks.

### Compile BPF objects — FAIL

```
  prereqs OK  clang=Ubuntu clang version 14.0.0-1ubuntu1.1  arch=x86_64
  CC  bpf/tc_ingress_eth0.bpf.o
clang -O2 -g -target bpf -I/usr/include -I/usr/include/x86_64-linux-gnu \
  -Wall -Wno-unused-value -Wno-pointer-sign \
  -c bpf/tc_ingress_eth0.bpf.c -o bpf/tc_ingress_eth0.bpf.o
In file included from bpf/tc_ingress_eth0.bpf.c:37:
In file included from /usr/include/linux/icmp.h:23:
In file included from /usr/include/linux/if.h:28:
In file included from /usr/include/x86_64-linux-gnu/sys/socket.h:22:
In file included from /usr/include/features.h:510:
/usr/include/x86_64-linux-gnu/gnu/stubs.h:7:11: fatal error: 'gnu/stubs-32.h' file not found
# include <gnu/stubs-32.h>
          ^~~~~~~~~~~~~~~~
1 error generated.
make: *** [Makefile:135: bpf/tc_ingress_eth0.bpf.o] Error 1
```

**Root cause:** When compiling BPF programs with `clang -target bpf`, clang does
not define `__x86_64__`. The glibc header `gnu/stubs.h` checks:
```c
#if !defined __x86_64__ || defined __ILP32__
#  include <gnu/stubs-32.h>
#endif
```
Since `__x86_64__` is unset in the BPF target, stubs.h requests stubs-32.h (which
requires the gcc-multilib / libc6-dev-i386 package to be installed). The runner
does not have gcc-multilib by default.

**Fix applied (Day 10 commit 3):**
1. Makefile: add `-D__x86_64__` to `_ARCH_INC` for x86_64 builds — prevents
   stubs.h from requesting stubs-32.h.
2. Workflow: add `gcc-multilib` to apt-get install as belt-and-suspenders.

### Build Go binary — NOT REACHED (blocked by BPF compile failure)
### Run Go unit tests — NOT REACHED
### Attempt scenario suite — NOT REACHED

---

## What this run proves

1. GitHub Actions ubuntu-22.04 runner (2026-06-18) uses **kernel 6.8.0-1052-azure** x86_64 —
   not 5.15.x. This is a real x86_64 Azure infrastructure kernel.
2. BTF is present and readable: 6020051 bytes — a NEW x86_64 kernel in the matrix.
3. bpffs is pre-mounted at /sys/fs/bpf on GitHub-hosted runners.
4. Full root capabilities are available with `sudo`.
5. ip_do_fragment and icmp_rcv are T symbols on 6.8.0-1052-azure x86_64 (kprobeable).
6. preflight 20/20 PASS on 6.8.0-1052-azure x86_64.
7. BPF compilation fails without `-D__x86_64__` on an x86_64 host — this is a
   compile-time error only, not a BPF verifier error.

## What this run does NOT prove

- BPF programs load and pass the verifier on x86_64
- PT_REGS_PARM1 (x86 convention) works at runtime
- Scenario suite passes on x86_64
- All five verdict paths are reachable on x86_64

## Next step

Run 2 (triggered by Day 10 commit 3 push) should compile successfully and
reach the scenario suite.
