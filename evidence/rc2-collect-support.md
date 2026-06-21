# `vxlan-tracer collect-environment` Validation — rc2 Evidence

**Date:** 2026-06-21 (updated after rename from collect-support)
**Status:** PARTIAL — static collection code validated on macOS; Linux integration NOT RUN
**Note:** The command was renamed from `collect-support` to `collect-environment` to
accurately reflect its scope. The old name is kept as a deprecated alias.

---

## What the command actually does (v0.1.0-rc2)

`vxlan-tracer collect-environment` collects **static system environment information only**.
It does NOT run the tracer, capture live TC filter state, execute preflight checks,
or produce any diagnostic output.

| File | Content | Collected how |
|------|---------|---------------|
| `system-info.txt` | `/proc/version` content (kernel version string) | `os.ReadFile("/proc/version")` |
| `vxlan-interfaces.txt` | VXLAN interface table (name, VNI, port, MTU, inferred underlay — no IPs) | `inetlink.ListVXLAN()` |
| `btf-status.txt` | BTF vmlinux presence/size | `os.Stat("/sys/kernel/btf/vmlinux")` |
| `bpf-mounts.txt` | BPF filesystem mount entries from `/proc/mounts` | scan `/proc/mounts` for "bpf" |
| `kernel-symbols.txt` | Whether `ip_do_fragment` and `icmp_rcv` appear as `T` symbols | scan `/proc/kallsyms` |
| `vxlan-tracer-version.txt` | Binary version, commit, build date | embedded variables |
| `CONTENTS.txt` | Manifest + collection timestamp | generated |
| `PRIVACY.txt` | Privacy disclosure | static text |

**What the command does NOT collect:**
- `hostname` — not included
- `ip link` output — not included
- `ip route` output — not included
- `ip addr` output — not included
- `sysctl -a` output — not included
- `dmesg` — not included
- `lsmod` — not included
- Preflight script output — not included
- Tracer stdout/stderr/JSON — not included
- TC filter state before/after — not included
- Pinned map state before/after — not included
- Exit codes — not included
- IP addresses of any interface — not included (by design)

Any previous evidence that claimed the bundle includes `hostname`, `ip link`, `ip route`,
`ip addr`, `sysctl -a`, `dmesg`, or `lsmod` was incorrect and has been retracted.

---

## Evidence corrections applied

The prior version of this file listed items as if they were collected by commands that
are not in the implementation. The corrected manifest above reflects what the code
actually executes. Every entry in the table above can be verified by reading
`cmd/vxlan-tracer/main.go:runCollectEnvironment()`.

---

## macOS build-host validation

The command is tested for non-crash behaviour on macOS (no `/proc`, no VXLAN interfaces).

```
$ go run ./cmd/vxlan-tracer collect-environment --dry-run
Dry-run: no filters will be removed.    [shows manifest]
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

**Result:** PASS — dry-run manifest printed, no archive created, exit 0.

Note: on macOS the `/proc` and `/sys` lookups fail gracefully. On Linux they return real data.

---

## Privacy requirements (static collection only)

| Requirement | Status |
|-------------|--------|
| No packet payloads | PASS — no packet capture code |
| No packet capture | PASS |
| No process command lines | PASS |
| No environment variables | PASS |
| No kubeconfig or Kubernetes secrets | PASS |
| No full firewall dump | PASS |
| No IP addresses by default | PASS — vxlan-interfaces.txt: names/VNI/port/MTU only |
| Full /proc/kallsyms not included | PASS — only presence indicator for two symbols |
| Interface names disclosed | PASS/ACCEPTED — required for diagnostic utility |

---

## Required Linux validation (NOT RUN)

On a Linux host with root:

```bash
# Build binary
make && cp build/vxlan-tracer-linux-amd64 /tmp/vt

# Test 1: dry-run without root
/tmp/vt collect-environment --dry-run
# Expected: manifest printed, no file created, exit 0

# Test 2: static collection without root
/tmp/vt collect-environment --out /tmp/vt-env-test.tar.gz
tar tzf /tmp/vt-env-test.tar.gz
# Expected: exactly 8 files listed

# Test 3: verify contents are real Linux data (not error messages)
tar xzf /tmp/vt-env-test.tar.gz -C /tmp/vt-env-bundle
cat /tmp/vt-env-bundle/system-info.txt     # should show kernel version
cat /tmp/vt-env-bundle/btf-status.txt      # should show real BTF status
cat /tmp/vt-env-bundle/kernel-symbols.txt  # should show T/not-found for ip_do_fragment

# Test 4: no unexpected files in archive
tar tzf /tmp/vt-env-test.tar.gz | grep -vE \
  '^(system-info|vxlan-interfaces|btf-status|bpf-mounts|kernel-symbols|vxlan-tracer-version|CONTENTS|PRIVACY)\.txt$'
# Expected: no output
```

Save output to: `evidence/rc2-support-live.md`

---

## Future work (NOT in rc2)

For a full diagnostic bundle that includes tracer run data, the command needs:
- `--overlay` / `--underlay` / `--duration` flags
- Subprocess execution of the tracer
- TC filter state capture before/after
- Preflight output capture
- Map pin directory listing

This work is tracked separately. It is blocked behind TC lifecycle safety gate.
