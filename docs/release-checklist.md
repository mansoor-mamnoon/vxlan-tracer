# Release readiness checklist

This checklist must be satisfied before tagging any release (v0.x or later).
All items must be individually verified and recorded in `evidence/`.

---

## BPF objects

- [ ] No stale BPF objects in the working directory (`ls bpf/*.bpf.o` or absent)
- [ ] `make clean-bpf && make bpf` produces a fresh compile with no errors
- [ ] `make bpf-verify` reports PASS (confirms `vxlan_config` symbol present)
- [ ] BPF object size is consistent with recent builds (regression guard)

## Go build and tests

- [x] `go vet ./...` passes with no warnings (macOS; Day 14)
- [ ] `go test ./...` passes on Linux (all packages including `internal/loader`)
- [ ] `make build` produces a valid ELF binary (`file dist/vxlan-tracer` shows ELF x86-64 or ARM64)
- [x] Binary links correctly — `make build` produces binary with commit hash via -ldflags (Day 14)
- [x] `--version` prints version, commit, and buildDate fields (Day 14)

## Scenario suite (local)

- [ ] 6/6 scenarios pass on at least one aarch64 kernel (Lima VM or Docker Desktop)
- [ ] 6/6 scenarios pass on at least one x86_64 kernel (GitHub Actions or x86_64 VM)
- [ ] Scenario 6 (port 8472) passes: `vxlan_port=8472` confirmed in JSON output
- [ ] `scripts/preflight.sh` passes with 0 FAIL (ENVIRONMENT failures on CI are acceptable)

## CI

- [ ] `x86_64 scenario probe` workflow shows job conclusion PASS on a recent push to main
- [ ] BPF compile and `bpf-verify` steps pass in CI
- [ ] Go unit tests pass in CI
- [ ] Scenario runner output shows "Results: 6 passed, 0 failed" in CI log

## Release package

- [x] `make package` produces vxlan-tracer-linux-amd64.tar.gz and vxlan-tracer-linux-arm64.tar.gz (Day 14)
- [x] `dist/release/checksums.sha256` produced alongside tarballs (Day 14)
- [x] Each tarball contains: binary, scripts/, README.md, LICENSE (verified via tar -tzf) (Day 14)
- [x] LICENSE file present (MIT, Copyright 2026 Mansoor Mamnoon) (Day 14)

## README and documentation accuracy

- [x] Status line accurately describes what is and is not proven (Day 14)
- [x] Port claim says "validated in netns lab on ports 4789 and 8472" (not "CNI validated") (Day 14)
- [ ] Kernel matrix reflects actual runs with kernel version and scenario count
- [x] CNI table is labeled as documentation-based (not lab-validated)
- [x] No references to `VXLAN_HEALTHY` (not a real verdict; use `NO_ISSUE_OBSERVED`)

## Forbidden claims review

- [ ] `docs/forbidden-claims.md` reviewed; no claim in README, release notes, or commit messages violates it
- [ ] No claim of "k3s validated", "flannel validated", or "CNI validated"
- [ ] No claim of XDP egress
- [ ] No claim that ip_do_fragment is VXLAN-specific
- [ ] No claim of packet loss from fragmentation events alone

## CNI status

- [ ] README accurately states: "k3s/flannel CNI validation requires a real two-node cluster and is not yet complete"
- [ ] `docs/kubernetes-validation.md` checklist is up to date with any completed items
- [ ] No claim of cross-node pod traffic without two-node lab evidence

---

## Post-release

After tagging, record in `evidence/`:
- Kernel(s) tested at release time
- Scenario results at release time
- `git log --oneline -10` at the release tag
