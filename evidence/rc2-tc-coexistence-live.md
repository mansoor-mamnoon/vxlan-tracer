# TC Coexistence Live Test Results — rc2 Evidence

**Date:** 2026-06-21
**Host:** Lima VM `vxlan-test` — Ubuntu 22.04.5 LTS, kernel 5.15.0-181-generic, aarch64
**Binary:** `vxlan-tracer dev` (built from commit bf9c7c0 + MkdirAll fix, 2026-06-21)
**BPF objects:** compiled from same source tree via `make bpf` (clang 14)

---

## Lifecycle unit tests (`internal/loader/loader_lifecycle_test.go`)

Run as: `sudo go test -v -count=1 -run 'TestPartialClsactRollback|TestDoubleCloseIdempotency|TestCollisionDetection|TestReplacementFilterRace' ./internal/loader/...`

```
=== RUN   TestPartialClsactRollback
--- PASS: TestPartialClsactRollback (0.03s)
=== RUN   TestDoubleCloseIdempotency
--- PASS: TestDoubleCloseIdempotency (0.02s)
=== RUN   TestCollisionDetection
    loader_lifecycle_test.go:169: collision detection test: reserved handle=0x76740001 prio=50000 on vt-test-a ingress
    loader_lifecycle_test.go:172: NOTE: full collision test with real BPF prog requires compiled BPF objects.
    loader_lifecycle_test.go:173: Run scripts/test-tc-coexistence.sh Case C on Linux for live validation.
--- PASS: TestCollisionDetection (0.02s)
=== RUN   TestReplacementFilterRace
    loader_lifecycle_test.go:207: Phase 4 slot-empty no-op: PASS (no filter at slot → silent no-op)
    loader_lifecycle_test.go:208: NOTE: replacement-race test with real BPF prog requires compiled BPF objects.
    loader_lifecycle_test.go:209: Run scripts/test-tc-coexistence.sh Case for live validation.
--- PASS: TestReplacementFilterRace (0.02s)
PASS
ok  	github.com/mansoormmamnoon/vxlan-tracer/internal/loader	0.103s
```

**Result: 4/4 PASS**

---

## TC coexistence script (`scripts/test-tc-coexistence.sh`)

Run as: `sudo bash scripts/test-tc-coexistence.sh --bin ./vxlan-tracer --bpf-dir bpf --pin-dir /sys/fs/bpf/vxlan-tracer-coexist-test`

```
=== TC coexistence integration test ===
  INFO  underlay iface: vt-ulay-16465
  INFO  overlay iface:  vt-olay-16465
  INFO  vxlan-tracer:   ./vxlan-tracer
  INFO  bpf dir:        bpf
  INFO  pin dir:        /sys/fs/bpf/vxlan-tracer-coexist-test

=== Case A — unrelated ingress filter preserved ===
  INFO  sentinel filter added: dev vt-ulay-16465 ingress prio 100 handle 0x1a
  INFO  vxlan-tracer exit code: 0
  PASS  A: sentinel filter still present (prio 100 handle 0x1a)
  PASS  A: no vxlan-tracer filter remains (prio 50000 on vt-ulay-16465 ingress)
  PASS  A: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test

=== Case B — unrelated egress filter preserved ===
  INFO  sentinel filter added: dev vt-olay-16465 egress prio 100 handle 0x1a
  PASS  B: sentinel filter still present (prio 100 handle 0x1a)
  PASS  B: no vxlan-tracer filter remains (prio 50000 on vt-olay-16465 egress)
  PASS  B: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test

=== Case C — priority collision: non-owned filter at vt's priority ===
  INFO  collision filter added: dev vt-ulay-16465 ingress prio 50000 handle 0xc0de
  PASS  C: collision filter survived (handle 0xc0de not deleted)

=== Case D — partial attach failure rollback ===
  PASS  D: sentinel filter still present (prio 100 handle 0x1a)
  PASS  D: no vxlan-tracer filter remains (prio 50000 on vt-ulay-16465 ingress)
  PASS  D: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test

=== Case E — signal cleanup (SIGINT + SIGTERM) ===
  INFO  E1: launched vxlan-tracer PID 16550; sleeping 0.5s then sending SIGINT
  PASS  E1/SIGINT: sentinel filter still present (prio 100 handle 0x1a)
  PASS  E1/SIGINT: no vxlan-tracer filter remains (prio 50000 on vt-ulay-16465 ingress)
  PASS  E1/SIGINT: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test
  INFO  E2: launched vxlan-tracer PID 16573; sleeping 0.5s then sending SIGTERM
  PASS  E2/SIGTERM: sentinel filter still present (prio 100 handle 0x1a)
  PASS  E2/SIGTERM: no vxlan-tracer filter remains (prio 50000 on vt-ulay-16465 ingress)
  PASS  E2/SIGTERM: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test

=== Case F — repeated runs without manual cleanup ===
  INFO  run 1 exit code: 0
  INFO  run 2 exit code: 0
  PASS  F: both runs exited 0
  PASS  F/after-run2: no vxlan-tracer filter remains (prio 50000 on vt-ulay-16465 ingress)
  PASS  F/after-run2: no vxlan-tracer filter remains (prio 50000 on vt-olay-16465 egress)
  PASS  F/after-run2: no pinned maps remain under /sys/fs/bpf/vxlan-tracer-coexist-test

=== TC coexistence test summary ===
  PASS: 20
  FAIL: 0
  SKIP: 0

RESULT: PASS
```

**Result: 20/20 PASS**

---

## Fix required to reach PASS

Case F initially failed (exit code 2 on repeated run) because `Close()` removes the
pin dir with `os.Remove(a.pinDir)` after unpinning maps, and the next run's
`loadPinned()` call requires the directory to already exist.

Fix: added `os.MkdirAll(cfg.PinDir, 0700)` in `Attach()` immediately after
creating the `Attachment` struct (before any interface lookups). This ensures
each new run creates the pin dir if the previous run's cleanup removed it.

---

## Gate summary

| Gate | Status | Evidence |
|------|--------|---------|
| TestPartialClsactRollback | PASS | kernel 5.15.0-181-generic aarch64 |
| TestDoubleCloseIdempotency | PASS | same |
| TestCollisionDetection (veth pair portion) | PASS | handle+prio verified via netlink |
| TestReplacementFilterRace (slot-empty no-op) | PASS | same |
| Case A: unrelated ingress filter preserved | PASS | sentinel at prio 100 survived |
| Case B: unrelated egress filter preserved | PASS | sentinel at prio 100 survived |
| Case C: collision filter not deleted | PASS | handle 0xc0de at prio 50000 survived |
| Case D: partial attach rollback (bogus bpf-dir) | PASS | sentinel survived; no vt filter left |
| Case E1: SIGINT cleanup | PASS | sentinel survived; no vt filter left |
| Case E2: SIGTERM cleanup | PASS | sentinel survived; no vt filter left |
| Case F: repeated runs succeed | PASS | both runs exit 0 after MkdirAll fix |
| No TC resources leak after any case | PASS | all map/filter assertions green |
