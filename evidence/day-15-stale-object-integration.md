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

## Day 15 CI result

CI run: **27857782449** ("x86_64 validation suite"), commit `0ef3385`, 2026-06-20T02:42Z.
Workflow: x86-smoke.yml, job "BPF compile + stale-object test + 6-scenario suite".
Runner: ubuntu-22.04, kernel 6.8.0-1059-azure #65~22.04.1 x86_64, Ubuntu 22.04.5 LTS.
Job conclusion: **success**.

---

## Actual CI output (captured 2026-06-20)

```
=== Stale BPF object integration test ===
binary:  dist/vxlan-tracer
fixture: tests/fixtures/tc_ingress_missing_config.bpf.c

[1] Compiling stale fixture...
  PASS  stale fixture compiled: /tmp/stale-bpf-test-3234/tc_ingress_eth0.bpf.o
[2] Creating test network namespace and veth pair...
  PASS  test namespace and veth pair ready (sl-test-a ↔ sl-test-b in sl-test-ns)
[3] Running binary with stale TC ingress object...
  INFO  binary exit code: 2
  INFO  binary output:    vxlan auto-detect: "sl-test-a" is type "veth", not vxlan — using default port 4789
vxlan-tracer dev
overlay:    sl-test-a
underlay:   sl-test-b
vxlan port: 4789 (auto-detected)
pin dir:    /sys/fs/bpf
bpf dir:    /tmp/stale-bpf-test-3234
error: attach failed: write vxlan config map: vxlan_config map missing from tc_ingress object — likely stale BPF object; run: make clean-bpf && make bpf
[4] Checking exit code...
  PASS  binary exited non-zero (2) as expected
[5] Checking error message...
  PASS  stderr contains: vxlan_config map missing from tc_ingress object
  PASS  stderr contains fix hint: make clean-bpf
[6] Checking TC filters after failed load...
  PASS  no TC filters on sl-test-b ingress (loader rolled back correctly)

=== Results: 6 passed, 0 failed ===
Exit: 0
```

---

## What is proven

- Loader fails-closed when BPF object lacks `vxlan_config` map (Unit test: Day 13)
- No TC filters left after stale-object failure (Unit test + integration, Day 13)
- Script compiles fixture and runs binary with correct assertions (Day 13 CI)
- amd64 (x86_64 6.8.0-1052-azure): PASS in Day 13 CI run 27851298262
- amd64 (x86_64 6.8.0-1059-azure): PASS in Day 15 CI run 27857782449 — **6/6 PASS**

## What remains unproven

- aarch64 stale-object run not performed in CI (ubuntu-22.04-arm runner does not
  run the x86-smoke.yml jobs; would require a separate arm64 workflow step)
- Pinned maps assertion: the script does not check for stale pinned maps
  under /sys/fs/bpf after failure (the binary errors before creating any maps)
