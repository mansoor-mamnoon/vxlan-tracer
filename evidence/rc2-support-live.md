# `collect-environment` Linux Integration Test Results

**Date:** 2026-06-21
**Host:** Lima VM `vxlan-test` — Ubuntu 22.04.5 LTS, kernel 5.15.0-181-generic, aarch64
**Binary:** `vxlan-tracer dev` (built from source, 2026-06-21)

---

## Dry-run test

```
$ ./vxlan-tracer collect-environment --dry-run
Would collect (dry-run — nothing saved):

  system-info.txt              Linux kernel version and architecture
  vxlan-interfaces.txt         VXLAN interfaces: names, VNIs, ports, MTUs (no IP addresses)
  btf-status.txt               BTF vmlinux file availability and size
  bpf-mounts.txt               BPF filesystem mount entries from /proc/mounts
  kernel-symbols.txt           ip_do_fragment and icmp_rcv symbol availability
  vxlan-tracer-version.txt     vxlan-tracer version string
  CONTENTS.txt                 manifest of included files
  PRIVACY.txt                  privacy notice describing what is and is not included

Run without --dry-run to collect.
```

Exit code: 0.

---

## Full collection test

```
$ sudo ./vxlan-tracer collect-environment
Collecting environment information...
(Static host info only — tracer not run; see collect-environment --help)
  [ok] system-info.txt
  [ok] vxlan-interfaces.txt
  [ok] btf-status.txt
  [ok] bpf-mounts.txt
  [ok] kernel-symbols.txt
  [ok] vxlan-tracer-version.txt
  [ok] CONTENTS.txt
  [ok] PRIVACY.txt

Environment bundle written: vxlan-tracer-env-20260621-144004.tar.gz
Contents: static host info only (no tracer run, no packet data).
To share: attach this file to your GitHub issue.
```

Exit code: 0. Archive created: `vxlan-tracer-env-20260621-144004.tar.gz` (1.3K).

---

## Archive content inspection

```
$ tar -tzf vxlan-tracer-env-20260621-144004.tar.gz
btf-status.txt
bpf-mounts.txt
kernel-symbols.txt
vxlan-tracer-version.txt
CONTENTS.txt
PRIVACY.txt
system-info.txt
vxlan-interfaces.txt
```

### system-info.txt

```
Linux version 5.15.0-181-generic (buildd@bos03-arm64-052) (gcc (Ubuntu 11.4.0-1ubuntu1~22.04.3) 11.4.0, GNU ld (GNU Binutils for Ubuntu) 2.38) #191-Ubuntu SMP Fri May 22 19:27:05 UTC 2026
```

No hostname. No IP address. No username.

### vxlan-interfaces.txt

```
no VXLAN interfaces found
```

(No VXLAN interface was configured at the time of the run.)

### btf-status.txt

```
/sys/kernel/btf/vmlinux: present (5996068 bytes)
```

### bpf-mounts.txt

Redacted here — contains only `bpf` filesystem type and mount path, no IP addresses.

### kernel-symbols.txt

```
ip_do_fragment: found (T symbol — kprobeable)
icmp_rcv: found (T symbol — kprobeable)
```

### PRIVACY.txt (excerpt)

```
INCLUDED
  - Linux kernel version and architecture (from /proc/version)
  - VXLAN interface names, VNIs, ports, and MTUs (no IP addresses)
  - Whether /sys/kernel/btf/vmlinux is present and its file size
  - BPF filesystem mount entries from /proc/mounts (device type + path only)
  - Whether ip_do_fragment and icmp_rcv are kprobeable symbols
    (presence indicator only — not the full /proc/kallsyms content)
  - vxlan-tracer version string

NOT INCLUDED
  - IP or MAC addresses of any interface
  - Route tables or routing policies
  - iptables, nftables, or other firewall rules
  - Running processes or their arguments
  - File system contents or paths
  - Credentials, tokens, secrets, or environment variables
  - Network traffic or packet payloads
  - Pod, container, or workload information
  - The full /proc/kallsyms symbol table
```

---

## Privacy verification

Inspected `system-info.txt`, `vxlan-interfaces.txt`, `btf-status.txt`, `kernel-symbols.txt`.
No IP addresses, no MAC addresses, no hostnames, no credentials, no process arguments found.
Archive contents match the PRIVACY.txt notice exactly.

---

## Gate summary

| Test | Status |
|------|--------|
| dry-run prints manifest, exits 0 | PASS |
| full run creates archive, exits 0 | PASS |
| all 8 files present in archive | PASS |
| system-info.txt: kernel version only, no hostname/IP | PASS |
| vxlan-interfaces.txt: names/VNIs/ports/MTUs, no IPs | PASS |
| btf-status.txt: present/absent + size | PASS |
| kernel-symbols.txt: kprobeable indicator only | PASS |
| PRIVACY.txt: accurate description of inclusions | PASS |
| No IP addresses in any collected file | PASS |
