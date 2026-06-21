# `vxlan-tracer interfaces` Linux Validation — rc2 Evidence

**Date:** 2026-06-21
**Status:** NOT RUN — Linux-only rtnetlink operation; build host is macOS
**Gate:** required before mentioning `interfaces` in any external outreach

---

## Command contract

`vxlan-tracer interfaces` enumerates **VXLAN-type interfaces only** — it does NOT:

- scan pod veth interfaces or container network namespaces,
- audit per-pod MTU values,
- require BPF loading or root privileges (in typical configurations),
- make any inference about which pod is responsible for a given flow.

The "UNDERLAY" column is a **best-effort inference** from the `VtepDevIndex` field
returned by rtnetlink for VXLAN links that have an explicit physical device configured.
When the VXLAN interface has no explicit VTEP device (common in Flannel and Calico), the
column shows `(unknown)`. Outreach and docs must label this "inferred" or "suggested",
not "authoritative".

---

## Test matrix (10 cases — target for Linux validation run)

| # | Setup | Expected output |
|---|-------|----------------|
| 1 | No VXLAN interfaces | "No VXLAN interfaces found" + guidance message |
| 2 | One VXLAN interface, port 4789 | Table row with correct VNI/PORT/MTU |
| 3 | One VXLAN interface, port 8472 | Table row shows port 8472 |
| 4 | Multiple VXLAN interfaces | All rows present, correct per-interface values |
| 5 | VXLAN with explicit physical device (`ip link add vxlan0 ... dev eth0`) | UNDERLAY = eth0 |
| 6 | VXLAN with no explicit device (Flannel-style: `ip link add vxlan0 ...`) | UNDERLAY = (unknown) |
| 7 | Run inside a network namespace (`ip netns exec <ns> vxlan-tracer interfaces`) | Sees only interfaces in that netns |
| 8 | JSON output (`--json`) | Valid JSON array; all fields present; empty array when no interfaces |
| 9 | Human output (default) | Formatted table; suggested invocations; no IP addresses |
| 10 | Non-root execution | Succeeds if rtnetlink permits (typical kernel config allows) |

---

## How to run validation on Linux

```bash
# Build
make && cp build/vxlan-tracer-linux-amd64 /tmp/vt

# Case 1: no VXLAN interfaces
/tmp/vt interfaces

# Case 2: one VXLAN, port 4789
sudo ip link add vxlan-test0 type vxlan id 42 dstport 4789 dev eth0
sudo ip link set vxlan-test0 mtu 1450
/tmp/vt interfaces

# Case 3: port 8472
sudo ip link add vxlan-test1 type vxlan id 100 dstport 8472 dev eth0
/tmp/vt interfaces

# Case 5: explicit physical device
# (vxlan-test0 above was created with "dev eth0" — UNDERLAY should show eth0)

# Case 6: no explicit device
sudo ip link add vxlan-nodev type vxlan id 200 dstport 4789
/tmp/vt interfaces
# expect: UNDERLAY = (unknown)

# Case 7: netns
sudo ip netns add test-ns
sudo ip link add vxlan-ns type vxlan id 300 dstport 4789 netns test-ns
sudo ip netns exec test-ns /tmp/vt interfaces

# Case 8: JSON
/tmp/vt interfaces --json

# Case 10: non-root
# Run as non-root user (if rtnetlink permits)
sudo -u nobody /tmp/vt interfaces 2>&1 || echo "non-root failed (may require config)"

# Cleanup
sudo ip link del vxlan-test0 2>/dev/null
sudo ip link del vxlan-test1 2>/dev/null
sudo ip link del vxlan-nodev 2>/dev/null
sudo ip netns del test-ns 2>/dev/null
```

---

## Actual result

**NOT RUN** — Linux host required.

This test must be run before `vxlan-tracer interfaces` is mentioned in any external
outreach message or public post. The command has been validated by code review and
build verification only.

---

## Outreach copy corrections made as part of Phase 6

The following claims in `outreach/` files incorrectly described `interfaces` as
enumerating pod veth MTUs. These have been corrected:

| File | Original claim | Corrected claim |
|------|---------------|----------------|
| `outreach/priority-contacts.md:34` | "enumerate which pods have misconfigured veth MTU" | "enumerate VXLAN overlay interfaces and their MTU — does not scan pod veth interfaces" |
| `outreach/lead-list.md:289` | "run per-pod to check which pods have wrong MTU" | Removed (tool does not support per-pod scans) |
| `outreach/lead-list.md:293` | "run per-pod to check which pods have veth MTU" | Removed |
| `outreach/lead-list.md:405` | "scan your veth interface MTU" | "enumerate VXLAN overlay interfaces and check overlay MTU" |
| `outreach/message-templates.md:69` | context implies veth MTU auditing | Clarified to "VXLAN overlay interfaces only" |

See commit following this evidence file for the actual changes to outreach files.
