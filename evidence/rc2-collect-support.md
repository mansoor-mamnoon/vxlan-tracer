# `vxlan-tracer collect-support` Validation — rc2 Evidence

**Date:** 2026-06-21
**Status:** PARTIAL — static collection validated on macOS build host; tracer-run integration NOT RUN (Linux only)
**Gate:** Linux integration test required before recommending collect-support in any external outreach

---

## Current implementation scope (v0.1.0-rc2)

`vxlan-tracer collect-support` in rc2 collects **static system information only**:

| File | What it contains | Tested on macOS? |
|------|-----------------|-----------------|
| `system-info.txt` | `/proc/version` — kernel version string | No (no /proc on macOS) |
| `vxlan-interfaces.txt` | VXLAN interface table (name/VNI/port/MTU/inferred-underlay) | No (ListVXLAN errors gracefully) |
| `btf-status.txt` | BTF vmlinux presence and size | No (no /sys/kernel/btf/vmlinux) |
| `bpf-mounts.txt` | BPF filesystem mount entries from /proc/mounts | No (no /proc/mounts) |
| `kernel-symbols.txt` | ip_do_fragment + icmp_rcv kprobeable (presence only) | No (no /proc/kallsyms) |
| `vxlan-tracer-version.txt` | Binary version string | Yes (outputs "dev / none / unknown") |
| `CONTENTS.txt` | Manifest + collection timestamp | Yes |
| `PRIVACY.txt` | Privacy disclosure | Yes |

**What is NOT yet implemented in rc2 collect-support:**
- Tracer diagnostic run (requires --overlay, --underlay)
- TC filter summary before/after
- Pinned map summary before/after
- Preflight script output
- Selected overlay/underlay MTUs
- VXLAN port/VNI from selected interface
- Cleanup result record
- Distro metadata (os-release)

These are tracked as Phase 7 work items for rc2+ or a follow-up patch.

---

## Static collection dry-run test (macOS build host)

```
$ ./vxlan-tracer collect-support --dry-run
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

**Result:** PASS — dry-run output matches expected manifest, exit code 0.

---

## Privacy requirements compliance (static collection)

| Requirement | Status |
|-------------|--------|
| No packet payloads | PASS — no packet capture code |
| No packet capture | PASS |
| No process command lines | PASS — no /proc/<pid>/cmdline |
| No environment variables | PASS |
| No kubeconfig | PASS |
| No Kubernetes Secrets | PASS |
| No application logs | PASS |
| No full firewall dump | PASS — no iptables/nftables |
| No IP addresses (default) | PASS — vxlan-interfaces.txt contains names, VNI, port, MTU only; no IPs |
| No hostnames by default | PASS — hostname not included |
| Full /proc/kallsyms not included | PASS — only ip_do_fragment/icmp_rcv presence indicator |
| --dry-run shows all commands | PASS |

---

## Required Linux validation (NOT RUN)

On a Linux host with root:

```bash
# Build
make && cp build/vxlan-tracer-linux-amd64 /tmp/vt

# Test 1: dry-run
/tmp/vt collect-support --dry-run
# Expected: manifest printed, no file created, exit 0

# Test 2: static collection
/tmp/vt collect-support --out /tmp/vt-support-test.tar.gz
tar tzf /tmp/vt-support-test.tar.gz
# Expected: all 8 files present

# Test 3: archive contents verification
tar xzf /tmp/vt-support-test.tar.gz -C /tmp/vt-bundle
cat /tmp/vt-bundle/CONTENTS.txt
cat /tmp/vt-bundle/btf-status.txt
cat /tmp/vt-bundle/kernel-symbols.txt
# Expected: real kernel data, not error messages

# Test 4: no sensitive files
tar tzf /tmp/vt-support-test.tar.gz | grep -Ev '^(system-info|vxlan-interfaces|btf-status|bpf-mounts|kernel-symbols|vxlan-tracer-version|CONTENTS|PRIVACY)'
# Expected: no output (no unexpected files in archive)
```

---

## Phase 7 enhancement tracking

The following enhancements are required per the rc2 spec but not yet implemented.
They are gated behind explicit user approval to avoid scope creep before the TC
safety story is complete.

| Enhancement | Complexity | Gate |
|-------------|-----------|------|
| Add --overlay/--underlay/--duration flags to collect-support | Medium | TC safety gates must pass first |
| Run tracer as subprocess, capture stdout/stderr/JSON | Medium | Requires Linux + BPF objects |
| TC filter summary (tc filter show dev before/after) | Low | Linux only |
| Pinned map summary (ls /sys/fs/bpf/vxlan-tracer) | Low | Linux only |
| Preflight output capture (bash scripts/preflight.sh) | Low | Linux only |
| distro metadata (/etc/os-release) | Low | Linux only |
| Cleanup result capture | Low | Requires tracer run |

These will be addressed in a follow-up commit or rc2+ before any external outreach
that references collect-support as a support workflow tool.
