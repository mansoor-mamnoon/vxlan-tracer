# evidence/day-15-stale-object-integration.md

Authoritative record of the stale BPF object integration test for v0.1.0-rc1 qualification.

---

## Test definition

Script: `scripts/test-stale-bpf-object.sh`
Fixture: `tests/fixtures/tc_ingress_missing_config.bpf.c`

Assertions (6):
1. Stale fixture compiles without error
2. veth pair created inside `sl-test-ns` network namespace
3. Binary exits non-zero when loaded with stale BPF dir
4. stderr contains: `vxlan_config map missing from tc_ingress object`
5. stderr contains: `make clean-bpf`
6. No TC filters on `sl-test-b` ingress after failure

Exit codes: 0 = all pass, 1 = assertion failure, 77 = skipped (env restriction).

---

## Prior CI evidence (Day 13)

The stale-object integration test was added in commit `0e897ab` (Day 13) and ran in
the x86-smoke.yml CI workflow for commit `a63474a`. GitHub Actions run ID: 27851298262
(referenced in evidence/day-13-x86-8472-result.md).

The `Stale BPF object integration test` step in that run completed without failure
(the job conclusion was PASS). The assertions were correct at that time.

---

## Day 15 CI status

CI triggered by commit `10b40f6` (push 2026-06-19). The `bpf-scenario` job in the
restructured x86-smoke.yml includes the stale-object test step. Log artifact:
`scenario-logs-x86_64/stale-bpf-test.log`.

**Status at time of writing this file:** CI in progress — artifact not yet available.
This file will be updated with the actual CI run ID and log excerpt once the workflow
completes.

---

## Expected output (based on Day 13 CI and local script review)

```
=== Stale BPF object integration test ===
binary:  dist/vxlan-tracer
fixture: tests/fixtures/tc_ingress_missing_config.bpf.c

[1] Compiling stale fixture...
  PASS  stale fixture compiled: /tmp/stale-bpf-test-<PID>/tc_ingress_eth0.bpf.o
[2] Creating test network namespace and veth pair...
  PASS  test namespace and veth pair ready (sl-test-a ↔ sl-test-b in sl-test-ns)
[3] Running binary with stale TC ingress object...
  INFO  binary exit code: 2
  INFO  binary output:    <stderr from binary>
[4] Checking exit code...
  PASS  binary exited non-zero (2) as expected
[5] Checking error message...
  PASS  stderr contains: vxlan_config map missing from tc_ingress object
  PASS  stderr contains fix hint: make clean-bpf
[6] Checking TC filters after failed load...
  PASS  no TC filters on sl-test-b ingress (loader rolled back correctly)

=== Results: 6 passed, 0 failed ===
```

---

## What is proven

- Loader fails-closed when BPF object lacks `vxlan_config` map (Unit test: Day 13)
- No TC filters left after stale-object failure (Unit test + integration, Day 13)
- Script compiles fixture and runs binary with correct assertions (Day 13 CI)
- amd64 (x86_64 6.8.0-1059-azure): PASS in Day 13 CI run 27851298262

## What remains unproven

- Day 15 CI run result for commit 10b40f6 (CI in progress at time of writing)
- aarch64 run not performed in this CI session (Lima VM not available from macOS)
- Pinned maps assertion: the script does not yet check for stale pinned maps
  under /sys/fs/bpf after failure (the binary errors before creating any maps)
