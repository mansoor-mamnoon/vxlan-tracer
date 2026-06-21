# rc2 External Readiness Assessment

**Date:** 2026-06-21
**Scope:** Controlled external pilot only (3 contacts; not public announcement)
**Decision:** NOT READY FOR CONTROLLED EXTERNAL PILOT

---

## Gate table

| Gate | Status | Evidence |
|------|--------|---------|
| Arbitrary TC filter deletion removed | PASS | loader.go uses prio 50000 / handle 0x7674 exclusively |
| Unrelated ingress filter preserved (code review) | PASS | attachTC() only deletes at our reserved prio+handle |
| Unrelated egress filter preserved (code review) | PASS | same logic for overlay egress |
| Unrelated ingress filter preserved (integration test) | NOT RUN | scripts/test-tc-coexistence.sh Case A requires Linux |
| Unrelated egress filter preserved (integration test) | NOT RUN | Case B requires Linux |
| Priority collision safe (code review) | PASS | handleMajor check prevents foreign-handle deletion |
| Priority collision safe (integration test) | NOT RUN | Case C requires Linux |
| SIGINT cleanup (code review) | PASS | signal handler calls att.Close() |
| SIGINT cleanup (integration test) | NOT RUN | Case E requires Linux |
| SIGTERM cleanup (code review) | PASS | signal handler calls att.Close() |
| SIGTERM cleanup (integration test) | NOT RUN | Case E requires Linux |
| Failure rollback (code review) | PASS | Close() safe at any stage; uses ownedFilters |
| Failure rollback (integration test) | NOT RUN | Case D requires Linux |
| Map cleanup (code review) | PASS | Close() removes pinnedMapNames and pinDir |
| Map cleanup (integration test) | NOT RUN | Cases A–F all verify maps cleaned |
| Concurrent-run behavior (code review) | PASS | flock on /run/vxlan-tracer.lock |
| Concurrent-run behavior (integration test) | NOT RUN | Case F (repeated runs) requires Linux |
| Linux `interfaces` validation | NOT RUN | evidence/rc2-interfaces-linux.md: 10 cases needed |
| Support-bundle dry-run | PASS | `collect-support --dry-run` works on macOS |
| Support-bundle Linux integration | NOT RUN | evidence/rc2-collect-support.md |
| GSO/GRO documented | PASS | docs/gso-gro-limitations.md written |
| GSO/GRO qualification implemented | NOT DONE | Conservative text only; no code-level check |
| Package qualification amd64 | NOT RUN | No Linux build host in this window |
| Package qualification arm64 | NOT RUN | No Linux build host in this window |
| Real k3s/Flannel validation | NOT RUN | evidence/rc2-k3s-flannel.md |
| Public claims audit complete | PASS | All "commonly dropped", "definitively", "five verdicts" corrected |
| Three rewritten pilot messages | PASS | outreach/pilot-draft-{1,2,3}.md |

---

## Summary of gate results

| Category | PASS | NOT RUN | NOT DONE |
|----------|------|---------|---------|
| Code-level safety (loader.go) | 8 | 0 | 0 |
| Integration tests (Linux) | 0 | 12 | 0 |
| Documentation | 3 | 0 | 0 |
| Package builds | 0 | 2 | 0 |
| Real CNI validation | 0 | 1 | 0 |
| GSO/GRO implementation | 0 | 0 | 1 |
| Outreach drafts | 1 | 0 | 0 |
| **Total** | **12** | **15** | **1** |

---

## Decision rationale

### NOT READY FOR CONTROLLED EXTERNAL PILOT

The TC ownership model is sound at the code-review level: the new `attachTC()` function
exclusively uses priority 50000 / handle 0x7674_0001 and verifies both the priority AND
the handle major before deleting any existing filter. This is a significant improvement
over rc1.

However, the integration test suite (`scripts/test-tc-coexistence.sh`) has not been run
on a Linux host. The tests cover six specific coexistence cases (Cases A–F) that verify
the code behavior in actual kernel TC state, not just in a code review. Until these tests
pass on Linux, there is a non-zero risk that the ownership check has a bug that only
manifests in real kernel TC operations.

The primary gate before external CNI outreach is:

**TC coexistence test Cases A–F must all PASS on a Linux host with kernel ≥ 5.15.**

Once that gate passes, the controlled pilot (3 contacts maximum, staging nodes only)
may proceed, with the following additional constraints:

1. RC2-PC01 and RC2-PC02 involve Cilium hosts. Contact only after Cases A–F pass on
   a host that has pre-existing TC BPF filters (or equivalent simulated state).
2. k3s/Flannel outreach requires `evidence/rc2-k3s-flannel.md` to be filled with an
   actual result — positive or negative.
3. The pilot messages (pilot-draft-1.md, pilot-draft-2.md, pilot-draft-3.md) require
   review and explicit send approval for each message individually.

---

## Remaining blockers before pilot

1. **Linux TC coexistence tests** — Run `scripts/test-tc-coexistence.sh` on a Linux
   host (kernel ≥ 5.15, root, compiled BPF objects). All 18 sub-cases must PASS.

2. **Linux `interfaces` validation** — Run 10 test cases from
   `evidence/rc2-interfaces-linux.md` on Linux. All cases must PASS.

3. **(For Flannel/k3s contacts only)** — Attempt two-node k3s/Flannel validation per
   `evidence/rc2-k3s-flannel.md`. State NOT RUN if environment unavailable; hold
   Flannel/k3s outreach.

4. **amd64 + arm64 package builds** — Run `make release` or equivalent, verify
   archive layout, compute checksums. Required before linking a release in any message.

5. **Explicit send approval** — Each of the three pilot draft messages requires
   individual review and explicit approval before sending.

---

## What READY FOR CONTROLLED EXTERNAL PILOT would look like

All of the above blockers resolved, plus:
- `evidence/rc2-tc-coexistence.md` updated with actual Linux test output showing
  all cases PASS
- `evidence/rc2-interfaces-linux.md` updated with actual Linux test output
- rc2 tagged (v0.1.0-rc2) and binaries published
- `docs/v0.1.0-rc2-release-notes.md` finalized

At that point, the decision should be revisited and may change to:
**READY FOR CONTROLLED EXTERNAL PILOT (3 contacts, staging nodes only)**

---

## What this assessment does NOT cover

- Public Show HN post (requires at least one successful external run result)
- LinkedIn/Reddit posts (requires at least one successful external run result)
- Multiple simultaneous outreach contacts (start with 1, wait for response)
- Outreach to GRO/GSO-related issues (PC06 class) — held until docs/gso-gro-limitations.md
  results in a code-level fix or clear qualification
