# TC Coexistence Test — rc2 Evidence

**Date:** 2026-06-21
**Test script:** `scripts/test-tc-coexistence.sh`
**Environment:** macOS (build host) — test REQUIRES Linux with root + BPF; not run here
**Status:** NOT RUN — Linux-only root test; run on a kernel ≥ 5.15 Linux host

---

## Test design

Six coexistence cases covering the complete ownership-safety contract:

| Case | Description | Observable outcome |
|------|-------------|-------------------|
| A | Unrelated ingress filter (matchall, prio 100) on underlay | Survives vxlan-tracer run and cleanup |
| B | Unrelated egress filter (matchall, prio 100) on overlay | Survives vxlan-tracer run and cleanup |
| C | Non-vt filter at prio 50000, different handle | Not deleted by vxlan-tracer |
| D | Partial attach failure (missing BPF objects) | No TC state left behind; sentinels intact |
| E | SIGINT + SIGTERM | Owned filters cleaned; sentinels intact |
| F | Repeated runs without manual cleanup | Both succeed; no stale filters or maps |

---

## How to run

On a Linux host with root and compiled BPF objects:

```bash
# Build vxlan-tracer for Linux
make && cp build/vxlan-tracer-linux-amd64 /tmp/vxlan-tracer

# Compile BPF objects
make bpf

# Run tests
sudo bash scripts/test-tc-coexistence.sh \
    --bin /tmp/vxlan-tracer \
    --bpf-dir bpf \
    --pin-dir /sys/fs/bpf/vxlan-tracer-coexist-test
```

---

## Expected output (on Linux, when all cases pass)

```
=== TC coexistence integration test ===
  INFO  underlay iface: vt-ulay-<pid>
  INFO  overlay iface:  vt-olay-<pid>
  INFO  vxlan-tracer:   /tmp/vxlan-tracer
  INFO  bpf dir:        bpf
  INFO  pin dir:        /sys/fs/bpf/vxlan-tracer-coexist-test

=== Case A — unrelated ingress filter preserved ===
  INFO  sentinel filter added: dev vt-ulay-<pid> ingress prio 100 handle 0x1a
  INFO  vxlan-tracer exit code: 0
  PASS  A: sentinel filter still present (prio 100 handle 0x1a)
  PASS  A: no vxlan-tracer filter remains (prio 50000 on vt-ulay-<pid> ingress)
  PASS  A: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test

=== Case B — unrelated egress filter preserved ===
  INFO  sentinel filter added: dev vt-olay-<pid> egress prio 100 handle 0x1a
  PASS  B: sentinel filter still present (prio 100 handle 0x1a)
  PASS  B: no vxlan-tracer filter remains (prio 50000 on vt-olay-<pid> egress)
  PASS  B: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test

=== Case C — priority collision: non-owned filter at vt's priority ===
  INFO  collision filter added: dev vt-ulay-<pid> ingress prio 50000 handle 0xc0de
  PASS  C: collision filter survived (handle 0xc0de not deleted)

=== Case D — partial attach failure rollback ===
  PASS  D: sentinel filter still present (prio 100 handle 0x1a)
  PASS  D: no vxlan-tracer filter remains (prio 50000 on vt-ulay-<pid> ingress)
  PASS  D: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test

=== Case E — signal cleanup (SIGINT + SIGTERM) ===
  INFO  E1: launched vxlan-tracer PID <n>; sleeping 0.5s then sending SIGINT
  PASS  E1/SIGINT: sentinel filter still present (prio 100 handle 0x1a)
  PASS  E1/SIGINT: no vxlan-tracer filter remains (prio 50000 on vt-ulay-<pid> ingress)
  PASS  E1/SIGINT: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test
  INFO  E2: launched vxlan-tracer PID <n>; sleeping 0.5s then sending SIGTERM
  PASS  E2/SIGTERM: sentinel filter still present (prio 100 handle 0x1a)
  PASS  E2/SIGTERM: no vxlan-tracer filter remains (prio 50000 on vt-ulay-<pid> ingress)
  PASS  E2/SIGTERM: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test

=== Case F — repeated runs without manual cleanup ===
  INFO  run 1 exit code: 0
  INFO  run 2 exit code: 0
  PASS  F: both runs exited 0
  PASS  F/after-run2: no vxlan-tracer filter remains (prio 50000 on vt-ulay-<pid> ingress)
  PASS  F/after-run2: no vxlan-tracer filter remains (prio 50000 on vt-olay-<pid> egress)
  PASS  F/after-run2: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test

=== TC coexistence test summary ===
  PASS: 18
  FAIL: 0
  SKIP: 0

RESULT: PASS
```

---

## Actual result

**NOT RUN** — this test requires a Linux host with root, kernel ≥ 5.15, compiled BPF
objects, and a bpffs mount. The build host (macOS) cannot execute this test.

This is a release gate for external CNI outreach. Run on the next available Linux VM
before publishing any outreach to Cilium, Calico, or Flannel users.

---

## Ownership model verified by tests

| Ownership invariant | Case | How tested |
|---------------------|------|------------|
| prio 50000, handle 0x76740001 = vt-owned | A, B, F | After normal exit, filter at prio 50000 is gone |
| Other priorities never deleted | A, B | Filter at prio 100 survives |
| Other handles at prio 50000 never deleted | C | Filter with handle 0xc0de survives |
| Cleanup idempotent across runs | F | Run 2 succeeds even after run 1 cleaned up |
| Cleanup runs on SIGINT | E1 | Filter gone after SIGINT + wait |
| Cleanup runs on SIGTERM | E2 | Filter gone after SIGTERM + wait |
| Failed attach leaves no state | D | Failed run (no BPF objects) → no TC filter left |
| Maps cleaned on exit | A, B, D, E, F | Pin dir empty after every normal or signal exit |

---

## Known limitation: SIGKILL cannot clean TC filters

If the process is killed with `kill -9`, TC filters at priority 50000 remain attached.
This is an irreducible property of Linux TC — TC filters have no owning process; they
persist until explicitly deleted via netlink.

**Manual removal after SIGKILL:**
```bash
tc filter del dev <underlay> ingress prio 50000
tc filter del dev <overlay>  egress  prio 50000
```

This limitation is documented in `docs/tc-lifecycle-audit.md` (TC-09) and will be noted
in the release notes and README.
