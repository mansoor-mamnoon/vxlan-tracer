# External Feedback Playbook

How to handle feedback from external users of vxlan-tracer. This document covers response timelines, triage criteria, what to ask for, and how to convert a feedback report into a matrix entry or code fix.

---

## Response timelines

| Scenario | Target response time |
|---------|---------------------|
| External run report (any result) | 48 hours |
| Compatibility problem (crash, wrong verdict, BPF load failure) | 24 hours |
| Follow-up questions from an engaged reporter | 48 hours |
| No response needed (passive report, no open question) | — |

---

## Triage criteria

### Is this a new kernel/CNI entry?

If the report includes a kernel version and CNI not yet in the matrix, and the verdict is `PASS` (any valid verdict produced, no crash):

1. Ask for the full JSON output and `--version` output if not provided
2. Verify the kernel is in the supported range (5.15+)
3. Add to `docs/kernel-matrix.md` with evidence reference
4. Thank the reporter and explain what was added

### Is this a wrong verdict?

A wrong verdict is one of:
- Tool reports `NO_ISSUE_OBSERVED` but the user has confirmed packet loss from a VXLAN MTU issue (by other means)
- Tool reports `VXLAN_FRAGMENTATION_OBSERVED` but the user has confirmed no VXLAN fragmentation is occurring
- Tool reports `PTB_SUPPRESSED` but PTBs are definitely reaching the pod
- Tool reports `PTB_DELIVERED` but PMTUD is confirmed broken

**Immediate ask:** run `vxlan-tracer collect-environment` and attach the bundle. This gives kernel version, symbol availability, BTF status, and BPF filesystem status — the most common root causes of wrong verdicts.

**Common causes:**
- `ip_do_fragment` not a T symbol on this kernel (inlined) → false negative for fragmentation
- BPF programs loaded but attached to wrong interface (user specified wrong `--overlay` or `--underlay`)
- Duration too short (events occurred before or after the measurement window)
- Non-VXLAN fragmentation inflating the counter (global scope, not per-VXLAN)

### Is this a crash or BPF load failure?

**Immediate ask:** full stderr output + `sudo bash scripts/preflight.sh` output.

If the preflight shows kernel symbol missing: add to known limitations, consider a graceful error path.
If BTF is missing: add a clear error message to `loader.Attach()` for this case.
If CAP_BPF is missing: already handled in preflight.

### Is this a feature request?

Log it. If it aligns with V1 roadmap (per-VNI attribution, per-namespace scoping), link to `docs/roadmap.md`. If it's out of scope, explain why with a reference to `docs/forbidden-claims.md` or the V2 section.

---

## Standard ask sequence

When a user files a compatibility problem without enough information, ask for these in order (don't ask for everything at once):

**First reply — always ask for:**
1. `./vxlan-tracer --version` output
2. `uname -r` and `uname -m`
3. The exact invocation command used
4. The full stderr output (not just the last line)

**If still unclear:**
5. `vxlan-tracer collect-environment` bundle
6. `sudo bash scripts/preflight.sh` output

**If verdict is wrong:**
7. How they confirmed the ground truth (tcpdump evidence? packet loss test? CNI logs?)
8. Whether they were in a netns or the host network namespace
9. Whether any iptables/nftables rules block ICMP type 3 code 4

---

## Converting a run report to a matrix entry

**Criteria for adding to kernel matrix:**

- Kernel version ≥ 5.15
- At least one valid verdict produced (not just "no issue observed" — needs at least one active scenario or confirmation that the BPF programs loaded)
- `--version` output confirms the correct binary was run
- JSON output present with at least `frag_events_total`, `ptb_ingress_total`, and `icmp_rcv_total` fields

**What to add:**

In `docs/kernel-matrix.md`:
- Kernel version
- Distro / arch / environment
- Scenario count (if a full scenario run was done) or "1 verdict observed" if only one scenario
- CNI (if applicable; "netns lab" if not)
- Link to the issue as evidence

**What NOT to add:**
- A kernel that only shows `NO_ISSUE_OBSERVED` without any BPF load confirmation
- A kernel where the user reports `--version` output but no diagnostic run

---

## When to escalate a report to a code change

| Condition | Action |
|-----------|--------|
| Preflight check gives misleading guidance | Fix the preflight check |
| Wrong verdict confirmed by packet capture | Root cause analysis → code fix |
| BPF verifier rejects a program on a supported kernel | BPF program fix |
| `ip_do_fragment` not found as T symbol | Add warning + fallback documentation |
| User can't find their interface names | Already fixed by `interfaces` subcommand |
| collect-support missing important field | Add field to collect-support bundle |

---

## What to say when a report is unhelpful

If a report has too little information to act on:

> Thank you for trying vxlan-tracer. To help diagnose what happened, could you share:
> 1. The output of `./vxlan-tracer --version`
> 2. `uname -r` and `uname -m`
> 3. The exact command you ran (with flags)
> 4. The full stderr output
>
> Alternatively, `vxlan-tracer collect-environment` packages all of the above into a single file you can attach here.

---

## What to say when a report is helpful but the verdict is correct

If the verdict matches the symptom and the user is just asking for confirmation:

> Based on your output, vxlan-tracer correctly identified [verdict]. [Explanation of what the verdict means for their environment]. The recommended fix is [action from Recommendation section], which should bring the overlay MTU to [value] — safe for a [underlay MTU] underlay with 50 bytes of VXLAN overhead.
>
> This is the first time we've seen this verdict on [kernel + CNI] — I'll add your environment to the validated matrix with a reference to this issue.

---

## Tracking

Log every external run report and compatibility problem in `outreach/user-tracker.csv` with:
- Contact ID (linked to priority-contacts.md or a new ID for inbound contacts)
- Date of response
- Verdict reported by user
- Kernel and CNI
- Whether it resulted in a matrix addition, code change, or documentation update
