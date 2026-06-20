# evidence/day-14.md

Day 14 — v0.1.0 release-candidate work.

All statements below reflect what was done in this repository on 2026-06-19.
No evidence in this file has been fabricated.

---

## What was done

### Commit 1 — stale BPF fixture (tests/fixtures/tc_ingress_missing_config.bpf.c)

Already existed from Day 13. Minimal TC BPF program with the correct program name
(`tc_ingress_count_ptb`) but no `vxlan_config`, `ptb_ingress_counts`, or
`ptb_ingress_total` maps. Used exclusively by the integration test.

### Commit 2 — stale BPF integration test (scripts/test-stale-bpf-object.sh)

Already existed from Day 13. Integration test that:
1. Compiles the stale fixture with clang
2. Creates a veth pair inside a temporary network namespace (`sl-test-ns`)
3. Runs the binary with `--bpf-dir` pointing at the stale object
4. Asserts: binary exits non-zero; stderr contains "vxlan_config map missing from tc_ingress object";
   stderr contains "make clean-bpf"; no TC filters on underlay interface after failure

Added to `x86-smoke.yml` CI workflow. Exit code 77 = graceful skip; exit 1 = assertion failure.

### Commit 3 — preflight dummy-interface WARN (scripts/preflight.sh)

Already existed from Day 13. Changed the global-namespace dummy-interface probe from
`_fail "ENVIRONMENT"` to `_warn`. Root cause: GitHub-hosted runners block `ip link add dummy`
in the global namespace even as root. vxlan-tracer uses veth pairs inside netns, so this
probe is not a hard requirement. See comment in preflight.sh for rationale.

### Commit 5 (Day 14) — make demo target + scripts/demo.sh

Added `scripts/demo.sh`: self-contained stale-MTU VXLAN fragmentation demo. Creates two
namespaces (`demo-ns1`, `demo-ns2`), a veth pair, VXLAN devices (VNI 42, port 4789),
sets overlay MTU 1450 and underlay MTU 1400 (stale-MTU scenario), runs the binary for 15 s
in JSON mode, generates oversized ping traffic (`ping -c 5 -s 1360`, outer IP ~1438 B >
1400 B underlay), and prints JSON + summary.

Added `demo` target to Makefile. `make demo` requires Linux + root + compiled binary +
BPF objects.

### Commit 6 (Day 14) — structured human-readable output (printHuman)

Replaced bare `fmt.Printf("verdict: %s\n")` and `fmt.Printf("%s\n", verdict.Message)` with
`printHuman(verdict, obs)`. The function produces labelled sections for each verdict:

```
Verdict:  VXLAN_FRAGMENTATION_OBSERVED
Evidence:
  ip_do_fragment events:   6
  largest outer IP seen:   1438 B
  underlay MTU:            1400 B  (outer packet exceeded by 38 B)
Recommendation:
  set overlay MTU to 1350 B or lower
  (VXLAN overhead is 50 B; safe overlay MTU = underlay MTU − 50)
Scope:
  global fragmentation counter corroborated by VXLAN TC egress
  (both ip_do_fragment and oversized outer packets observed)
  See docs/fragmentation-scoping.md for limitations.
```

`go vet ./...` passes. JSON output path (`--json` flag) is unchanged.

### Commit 7 (Day 14) — LICENSE and per-arch release packages

Added `LICENSE` (MIT, copyright 2026 Mansoor Mamnoon).

Rewrote `make package` to produce per-arch tarballs:
- `dist/release/vxlan-tracer-linux-amd64.tar.gz`
- `dist/release/vxlan-tracer-linux-arm64.tar.gz`
- `dist/release/checksums.sha256`

Each tarball contains: `vxlan-tracer` binary, `scripts/` (preflight, run-scenarios, demo,
setup-bpf-fs, setup-netns, teardown-netns), `README.md`, `LICENSE`, and `bpf/*.bpf.o`
objects if compiled.

`make package` verified on macOS (cross-compiles Go binaries; BPF objects absent on macOS,
included only if compiled on Linux).

### Commit 8 (Day 14) — version metadata via -ldflags

Changed `const version = "0.1.0-dev"` to:
```go
var (
    version   = "dev"
    commit    = "none"
    buildDate = "unknown"
)
```

`--version` now prints: `vxlan-tracer dev (commit <sha>, built unknown)`

Makefile wires `VERSION` and `COMMIT` into `-ldflags` for all three build targets.
`BUILDDATE` not embedded by default (reproducibility). Release override:
`VERSION=v0.1.0 make package`.

Verified:
```
dist/vxlan-tracer --version
vxlan-tracer dev (commit 0294fab, built unknown)
```

### Commit 9 (Day 14) — README polish

- Added plain-English symptom opening ("small requests work, large silently stall")
- Added Quick demo section with expected `printHuman` output
- Added Build and install section with `VERSION` ldflags usage and `--version` example
- Updated development status table to mark CI, human output, demo, stale BPF test as done
- Retained all existing proven-claim language; no new claims added

---

## What is proven (as of Day 14)

- `go vet ./...` passes on macOS (cross-platform)
- `go test ./...` passes on macOS (unit tests; BPF-dependent tests skipped on macOS)
- `make build` produces correct binary with commit hash embedded
- `make package` produces per-arch tarballs (amd64 + arm64) with SHA-256 checksums
- Archive contents verified: binary, scripts/, README.md, LICENSE
- `--version` output correct: version/commit/buildDate all rendered
- `printHuman` function compiles and runs; all 5 verdict cases covered
- scripts/demo.sh written; `make demo` target wired
- LICENSE file present (MIT)
- README accurately describes: symptom, demo, build, validation scope, limitations

## What remains unproven

- `scripts/demo.sh` not run end-to-end (requires Linux + root + BPF objects)
- Stale BPF integration test (`make test-stale-bpf`) not run on this session (requires Linux)
- `printHuman` output not captured from a live run (requires Linux)
- CI run for Day 14 commits (commits 085ae8c, 726b49d, 0294fab, 692151b, 3e034a4)
  not yet completed — push to origin/main pending
- BPF objects not compiled in this session (macOS)
- `VERSION=v0.1.0 make package` not tested (same code path, only the variable differs)

---

## rc1 readiness decision

The repository satisfies the v0.1.0-rc1 gate items that can be verified without a
Linux runner:

- [x] 6/6 scenarios on 4 kernels (existing evidence, Days 7–13)
- [x] Stale BPF integration test (committed Day 13, CI-confirmed Day 13)
- [x] Preflight false-negative fixed (dummy WARN not FAIL, committed Day 13)
- [x] Structured human-readable output (committed Day 14)
- [x] Demo command (committed Day 14)
- [x] Per-arch release packages with checksums (committed Day 14)
- [x] Version metadata via ldflags (committed Day 14)
- [x] LICENSE (committed Day 14)
- [x] README accurate (no k3s/CNI claims, no production-ready claims)
- [ ] Two-node k3s/flannel validation — NOT done; not required for rc1

**Assessment:** ready for v0.1.0-rc1 tag once Day 14 CI run confirms the new commits
pass the x86-smoke.yml workflow. The Day 14 commits add no BPF changes, no new verdicts,
and no new scenario requirements — all Linux-side behavior was validated in Day 13 CI.

---

## Day 15 recommendation

1. Push Day 14 commits to origin/main and confirm CI passes
2. Tag v0.1.0-rc1 after CI confirms green
3. Capture `--version` output and `printHuman` output from a live Linux run
4. Capture `make demo` output as evidence
5. Consider: two-node k3s validation (V1 scope, not rc1 blocker)
