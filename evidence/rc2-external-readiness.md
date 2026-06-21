# rc2 External Readiness Assessment

**Date:** 2026-06-21 (updated after lifecycle safety fixes)
**Scope:** Controlled external pilot only (3 contacts; not public announcement)
**Decision:** NOT READY FOR CONTROLLED EXTERNAL PILOT

---

## Gate table

| Gate | Status | Evidence |
|------|--------|---------|
| Arbitrary TC filter deletion removed | PASS | loader.go: attachTC() never deletes; collision error instead |
| TC slot collision check (code review) | PASS | attachTC() checks handle==0x7674_0001 AND prio==50000; fails if occupied |
| TC slot collision check (live test) | NOT RUN | loader_lifecycle_test.go: TestCollisionDetection needs compiled BPF |
| Exact filter identity stored post-install | PASS | attachTC() re-lists, records progID + filterName |
| Cleanup verifies identity before deleting | PASS | removeVerifiedFilter(): handle+prio+name+progID checked |
| Identity mismatch → warn, skip, continue | PASS | removeVerifiedFilter() prints warning, returns error, does not delete |
| Replacement-filter race (code review) | PASS | removeVerifiedFilter() logic: progID mismatch → skip |
| Replacement-filter race (live test) | NOT RUN | loader_lifecycle_test.go: TestReplacementFilterRace needs BPF prog |
| Partial clsact rollback (code review) | PASS | Attachment created after lock; underlayClsactCreated set before overlayClsact |
| Partial clsact rollback (live test) | PARTIAL | TestPartialClsactRollback: veth pair test runs on Linux but needs root |
| Close() idempotency (code review) | PASS | closed bool prevents re-execution; all fields nil'd after use |
| Close() idempotency (live test) | PARTIAL | TestDoubleCloseIdempotency: needs root on Linux |
| SIGINT cleanup (code review) | PASS | signal handler calls att.Close() |
| SIGINT cleanup (live test) | NOT RUN | no automated signal test yet |
| SIGTERM cleanup (code review) | PASS | same signal handler |
| SIGTERM cleanup (live test) | NOT RUN | no automated signal test yet |
| Concurrent-run protection (code review) | PASS | flock LOCK_EX|LOCK_NB on /run/vxlan-tracer.lock |
| Concurrent-run protection (live test) | NOT RUN | requires Linux + two concurrent processes |
| Unrelated ingress filter preservation (code review) | PASS | attachTC() only touches handle 0x7674_0001 |
| Unrelated ingress filter preservation (live test) | NOT RUN | scripts/test-tc-coexistence.sh Case A |
| Unrelated egress filter preservation (code review) | PASS | same |
| Unrelated egress filter preservation (live test) | NOT RUN | Case B |
| Map cleanup (code review) | PASS | Close() removes pinnedMapNames |
| Map cleanup (live test) | NOT RUN | all lifecycle cases require Linux |
| Pin-dir cleanup (code review) | PASS | Close() removes pinDir after maps |
| Pin-dir cleanup (live test) | NOT RUN | Linux required |
| Linux `interfaces` validation | NOT RUN | evidence/rc2-interfaces-linux.md: 10 cases |
| Inferred-underlay label (LIKELY UNDERLAY) | PASS | main.go: runInterfaces() updated |
| UnderlayInferred JSON field | PASS | vxlan.go: VXLANCandidate.UnderlayInferred |
| collect-environment scope correct | PASS | Command renamed; evidence corrected; implementation audited |
| collect-environment privacy review | PASS | No IPs, no secrets, no process cmdlines |
| collect-environment Linux integration | NOT RUN | evidence/rc2-support-live.md |
| GSO/GRO documented (limitations) | PASS | docs/gso-gro-limitations.md |
| GSO/GRO live tests | NOT RUN | evidence/rc2-gso-gro-live.md |
| PTB output: priority-50000 caveat | PASS | main.go: printHuman() updated |
| TC priority observation claim corrected in docs | PASS | hook-model.md, forbidden-claims.md |
| Public claims audit (overconfident language) | PASS | README, show-hn, outreach corrected |
| Outreach: no "definitively" or "pre-netfilter" claim | PASS | pilot-draft-{1,2,3}.md corrected |
| Package qualification amd64 | NOT RUN | No Linux build in this session |
| Package qualification arm64 | NOT RUN | No Linux build in this session |
| Regression suite (go test ./...) | PASS | macOS: unit tests pass; loader/lifecycle skipped |
| k3s/Flannel two-node validation | NOT RUN | evidence/rc2-k3s-flannel.md |
| Three pilot outreach drafts (conservative) | PASS | outreach/pilot-draft-{1,2,3}.md |

---

## Summary of gate results

| Category | PASS | PARTIAL | NOT RUN |
|----------|------|---------|---------|
| TC lifecycle code-level safety | 12 | 0 | 0 |
| TC lifecycle live tests | 0 | 2 | 10 |
| interfaces / underlay | 3 | 0 | 1 |
| collect-environment | 3 | 0 | 1 |
| GSO/GRO | 1 | 0 | 1 |
| Output claims | 2 | 0 | 0 |
| Documentation claims | 3 | 0 | 0 |
| Package builds | 0 | 0 | 2 |
| Regression suite | 1 | 0 | 0 |
| CNI validation | 0 | 0 | 1 |
| Outreach drafts | 1 | 0 | 0 |
| **Total** | **26** | **2** | **16** |

---

## Decision rationale

### NOT READY FOR CONTROLLED EXTERNAL PILOT

The TC ownership model is significantly improved:
- The collision check now prevents auto-deletion of any filter at the reserved slot.
- Cleanup now verifies the exact kernel-assigned program ID before deleting.
- Partial clsact rollback is fixed at the code level.
- Close() is idempotent.

However, none of the lifecycle integration tests have been run on a real Linux kernel.
The integration tests in `loader_lifecycle_test.go` cover the key paths but require
root on Linux and (for the collision and replacement-race tests) compiled BPF objects.

**The primary gate before external CNI outreach is:**
> All lifecycle integration tests must PASS on a real Linux host (kernel ≥ 5.15).
> Results must be recorded in `evidence/rc2-tc-coexistence-live.md`.

---

## Remaining blockers before any pilot

1. **Linux TC lifecycle tests** — Run `loader_lifecycle_test.go` and
   `scripts/test-tc-coexistence.sh` on Linux ≥ 5.15, root, compiled BPF objects.
   All tests must PASS. Record in `evidence/rc2-tc-coexistence-live.md`.

2. **Linux `interfaces` validation** — Run 10-case matrix from
   `evidence/rc2-interfaces-linux.md`. All cases must PASS.
   Record in `evidence/rc2-interfaces-linux-live.md`.

3. **Regression suite on Linux** — Run `go test ./...` and the six scenario suite
   on Linux to confirm lifecycle changes did not break any verdict path.

4. **amd64 + arm64 package builds** — Required before linking a binary in any message.

5. **(Flannel/k3s contacts only)** — Two-node cluster validation per
   `evidence/rc2-k3s-flannel.md`. Hold Flannel outreach if NOT RUN.

6. **GSO/GRO live tests** — Required before any PC06-class outreach.
   Record in `evidence/rc2-gso-gro-live.md`.

7. **Per-message explicit approval** — Each of the three pilot draft messages
   requires individual review and approval before sending.

---

## What READY FOR CONTROLLED EXTERNAL PILOT would look like

All blockers resolved, plus:
- `evidence/rc2-tc-coexistence-live.md` showing all lifecycle tests PASS
- `evidence/rc2-interfaces-linux-live.md` showing all interface cases PASS
- rc2 tagged (v0.1.0-rc2) and binaries published
- `docs/v0.1.0-rc2-release-notes.md` finalized with live test results

At that point the decision should be revisited. If CNI validation has NOT run,
the pilot must be restricted to:
> **Disposable or manually supervised environments only; no production CNI clusters.**

---

## What this assessment does NOT cover

- Public Show HN post (requires at least one successful external run result)
- LinkedIn/Reddit posts (requires at least one external result)
- Multiple simultaneous contacts (start with 1, wait for response)
- GSO/GRO-class outreach (blocked until `rc2-gso-gro-live.md` has results)
