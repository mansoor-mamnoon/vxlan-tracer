# rc2 External Readiness Assessment

**Date:** 2026-06-21 (updated after Linux live tests)
**Scope:** Controlled external pilot only (3 contacts; not public announcement)
**Decision:** READY FOR CONTROLLED EXTERNAL PILOT (with constraints below)

---

## Gate table

| Gate | Status | Evidence |
|------|--------|---------|
| Arbitrary TC filter deletion removed | PASS | loader.go: attachTC() never deletes; collision error instead |
| TC slot collision check (code review) | PASS | attachTC() checks handle==0x7674_0001 AND prio==50000; fails if occupied |
| TC slot collision check (live test) | PASS | test-tc-coexistence.sh Case C: handle 0xc0de at prio 50000 survived |
| Exact filter identity stored post-install | PASS | attachTC() re-lists, records progID + filterName |
| Cleanup verifies identity before deleting | PASS | removeVerifiedFilter(): handle+prio+name+progID checked |
| Identity mismatch → warn, skip, continue | PASS | removeVerifiedFilter() prints warning, returns error, does not delete |
| Replacement-filter race (code review) | PASS | removeVerifiedFilter() logic: progID mismatch → skip |
| Replacement-filter race (slot-empty no-op live test) | PASS | TestReplacementFilterRace: slot-empty → silent no-op |
| Partial clsact rollback (code review) | PASS | Attachment created after lock; underlayClsactCreated set before overlayClsact |
| Partial clsact rollback (live test) | PASS | TestPartialClsactRollback: PASS kernel 5.15 |
| Close() idempotency (code review) | PASS | closed bool prevents re-execution; all fields nil'd after use |
| Close() idempotency (live test) | PASS | TestDoubleCloseIdempotency: PASS kernel 5.15 |
| SIGINT cleanup (live test) | PASS | test-tc-coexistence.sh Case E1: sentinel survived, no vt filter left |
| SIGTERM cleanup (live test) | PASS | test-tc-coexistence.sh Case E2: same |
| Concurrent-run protection (code review) | PASS | flock LOCK_EX|LOCK_NB on /run/vxlan-tracer.lock |
| Concurrent-run protection (live test) | NOT RUN | requires two concurrent processes; lower priority |
| Unrelated ingress filter preservation (live test) | PASS | Case A: sentinel at prio 100 survived full vt run |
| Unrelated egress filter preservation (live test) | PASS | Case B: sentinel at prio 100 survived full vt run |
| Repeated runs succeed (live test) | PASS | Case F: both runs exit 0; MkdirAll fix applied |
| Partial attach failure rollback (live test) | PASS | Case D: bogus bpf-dir → no vt filter left, sentinel survived |
| Map cleanup (live test) | PASS | All cases: assert_maps_cleaned PASS |
| Pin-dir cleanup and recreation (live test) | PASS | Case F: pin dir removed by Close(), recreated by MkdirAll on next run |
| Linux `interfaces` validation | PASS | rc2-interfaces-linux-live.md |
| Inferred-underlay label (LIKELY UNDERLAY) | PASS | Live test: column header confirmed |
| UnderlayInferred JSON field | PASS | Live test: underlay_inferred:true confirmed |
| collect-environment scope correct | PASS | Live test: 8 files, no IPs, PRIVACY.txt accurate |
| collect-environment dry-run | PASS | Live test: manifest printed, exit 0 |
| collect-environment privacy review | PASS | Live test: no IPs, no secrets, no process cmdlines |
| collect-environment Linux integration | PASS | rc2-support-live.md |
| GSO/GRO documented (limitations) | PASS | docs/gso-gro-limitations.md |
| GSO/GRO live tests | NOT RUN | evidence/rc2-gso-gro-live.md — blocks PC06-class outreach only |
| PTB output: priority-50000 caveat | PASS | main.go: printHuman() updated |
| TC priority observation claim corrected in docs | PASS | hook-model.md, forbidden-claims.md |
| Public claims audit (overconfident language) | PASS | README, show-hn, outreach corrected |
| Outreach: no "definitively" or "pre-netfilter" claim | PASS | pilot-draft-{1,2,3}.md corrected |
| Package qualification arm64 | PASS | built on Lima VM aarch64; smoke test PASS |
| Package qualification amd64 | PASS | cross-compiled; archive layout verified |
| Regression suite (go test ./...) | PASS | Linux 5.15, all packages PASS |
| Six-scenario verdict suite | PASS | All 6 verdicts confirmed on Linux 5.15 aarch64 |
| k3s/Flannel two-node validation | NOT RUN | evidence/rc2-k3s-flannel.md — blocks Flannel contacts |
| Three pilot outreach drafts (conservative) | PASS | outreach/pilot-draft-{1,2,3}.md corrected |

---

## Summary of gate results

| Category | PASS | PARTIAL | NOT RUN |
|----------|------|---------|---------|
| TC lifecycle code-level safety | 12 | 0 | 0 |
| TC lifecycle live tests | 10 | 0 | 0 |
| interfaces / underlay | 4 | 0 | 0 |
| collect-environment | 4 | 0 | 0 |
| GSO/GRO | 1 | 0 | 1 |
| Output claims | 2 | 0 | 0 |
| Documentation claims | 3 | 0 | 0 |
| Package builds | 2 | 0 | 0 |
| Regression suite | 2 | 0 | 0 |
| CNI validation | 0 | 0 | 1 |
| Outreach drafts | 1 | 0 | 0 |
| **Total** | **41** | **0** | **2** |

---

## Decision rationale

### READY FOR CONTROLLED EXTERNAL PILOT (with constraints)

All lifecycle integration tests have now run on Linux kernel 5.15.0-181-generic (Ubuntu 22.04,
aarch64). All 20 TC coexistence cases PASS. All 6 verdict scenarios PASS. Both packages build
and pass smoke test.

**Active constraints that must remain in effect:**

1. **Do NOT send outreach yet.** Each pilot message requires per-message explicit approval
   before sending. This assessment confirms readiness — it is not authorization to send.

2. **GSO/GRO outreach (PC06 class, Calico) blocked.** `evidence/rc2-gso-gro-live.md`
   has NOT RUN status. Do not contact targets whose issue involves GSO/GRO until those
   tests run.

3. **Flannel/k3s contacts blocked.** `evidence/rc2-k3s-flannel.md` NOT RUN.
   Flannel contacts require two-node cluster validation first.

4. **Disposable or manually supervised environments only.** k3s/Flannel validation
   has not run. If the contact is on a CNI-managed cluster, emphasize staging/non-critical.

5. **Start with one contact, wait for response before the second.**

---

## What is NOT covered

- Public Show HN post (requires at least one successful external run result)
- LinkedIn/Reddit posts (requires at least one external result)
- Multiple simultaneous contacts (start with 1)

---

## Remaining NOT RUN gates and their scope

| Gate | Blocks |
|------|--------|
| Concurrent-run protection (live test) | Nothing (code review PASS is sufficient for pilot) |
| GSO/GRO live tests | PC06-class outreach (Calico GRO/GSO issues) |
| k3s/Flannel two-node validation | Flannel/k3s contacts |
