# rc2 Priority Contacts — Re-Scored for Controlled Pilot

**Date:** 2026-06-21
**Status:** Drafts only. Do not contact without explicit approval.
**Source:** Re-scored from `outreach/priority-contacts.md` (15 contacts) and
`outreach/lead-list.md` (35 leads) after applying rc2 eligibility gates.

---

## Re-scoring gates (applied to all 35 leads)

The following contacts were removed or downgraded:

| Removal reason | Leads removed |
|---------------|--------------|
| WireGuard-only, not VXLAN | PC08 (k3s/WireGuard Azure), PC09 (k3s/WireGuard ARM) |
| Resolved or stale (no recent activity, issue closed) | 3 leads from 2019–2021 |
| Requires per-pod/per-flow attribution (tool lacks this) | 1 lead (per-pod veth race condition, primary diagnostic is veth MTU not VXLAN overlay) |
| GRO/GSO class — characterization not complete | PC06 (Calico GRO/GSO, see docs/gso-gro-limitations.md) |
| Tool is IPIP mode only, not VXLAN | 2 Calico IPIP-mode leads |
| k3s/Flannel: two-node validation not yet run | Downgraded (contact only after rc2-k3s-flannel.md is filled) |

**Remaining credible leads after re-scoring: 22 out of 35.**

---

## Tier 1: Safe to contact in controlled pilot (3 contacts)

These contacts pass all rc2 safety gates:
- Tool is VXLAN (not WireGuard, not IPIP)
- Issue is still open or recently active
- Tool capability matches the observed symptom
- Message makes no claim about per-pod attribution or GRO/GSO
- Outreach message uses corrected language (experimental, not definitive)

### RC2-PC01 — Cilium KubeVirt egress gateway fragmentation
- **Original score:** 12/12
- **rc2 score:** 12/12 (unchanged — no re-scoring reason applies)
- **Issue:** https://github.com/cilium/cilium/issues/38828
- **Why first:** Exact VXLAN_FRAGMENTATION_OBSERVED / PTB_SUPPRESSED scenario.
  Cilium's TC filters at priority 1 will not be disturbed by rc2 (we use prio 50000).
  KubeVirt is a novel environment not in the matrix.
- **Draft:** `outreach/pilot-draft-1.md`
- **Gates remaining before sending:** TC coexistence tests A–F must PASS

---

### RC2-PC02 — Cilium eBPF masquerade drops PTB (July 2024)
- **Original score (PC03):** 11/12
- **rc2 score:** 11/12
- **Issue:** https://github.com/cilium/cilium/issues/33844
- **Why second:** PTB_SUPPRESSED scenario with direct symptom match. The Cilium
  SNAT/masquerade path runs between the TC hook and icmp_rcv, which is exactly the
  observation window. rc2's priority 50000 attachment does not conflict with Cilium's
  priority-1 filters.
- **Draft:** `outreach/pilot-draft-2.md`
- **Gates remaining before sending:** TC coexistence tests A–F must PASS

---

### RC2-PC03 — PTB suppression in a non-Cilium/Calico environment
- **Original score (PC10–PC15 range):** 8/12
- **rc2 score:** 9/12 (bumped: any non-CNI VXLAN environment is more valuable now
  given we lack real CNI validation)
- **Why third:** A VXLAN PTB suppression issue without a specific CNI is lower risk
  (no CNI TC filter to conflict with) and validates the basic PTB_SUPPRESSED path
  in a real environment. Any issue from the lead-list that describes "ICMP fragmentation
  needed not reaching pods" without a specific CNI (or with iptables as the stated
  cause) is the cleanest first pilot.
- **Candidate issues:** L010, L028, L031 (see outreach/lead-list.md) — all describe
  PTB suppression by firewall rules, not CNI-specific eBPF policies.
- **Draft:** `outreach/pilot-draft-3.md`
- **Gates remaining before sending:** TC coexistence tests A–F must PASS

---

## Tier 2: Contact after k3s/Flannel validation passes

These are valid Flannel or k3s VXLAN issues where the tool is relevant, but the
k3s/Flannel two-node validation (`evidence/rc2-k3s-flannel.md`) must pass first.

- PC04 (KubeVirt slow throughput) — VXLAN relevant but novel; need k3s result first
- Flannel-specific leads (L001, L003, L007)

---

## Tier 3: Hold until GSO/GRO is characterized

Issues where the primary symptom could be explained by GSO super-packets rather than
actual MTU misconfiguration:

- PC06 (Calico eBPF GRO/GSO) — held per docs/gso-gro-limitations.md
- Any issue describing "large packet size reported by tool but no actual fragmentation"
- Any issue where GSO is explicitly mentioned

---

## Tier 4: Removed from pilot scope

| Contact | Reason |
|---------|--------|
| PC08, PC09 | WireGuard tunnels, not VXLAN |
| L011, L012 | Issue closed/resolved |
| L016 | GRO/GSO — held |
| L017, L023 | IPIP mode, not VXLAN |
| L018 | Primary symptom is per-pod veth MTU; tool does not enumerate veth interfaces |

---

## Outreach rules for rc2 pilot

Every message must:
1. Say "experimental prerelease, not yet tested against a real [CNI] cluster"
2. Recommend staging or non-production node only
3. Not claim the tool will definitively identify the root cause
4. Not claim PTB_SUPPRESSED proves which specific code path dropped the PTB
5. Not use "commonly dropped by cloud fabric" language
6. Not claim `interfaces` enumerates pod veth MTUs
7. Link to rc2 release (once tagged) — do not link to rc1 if rc2 exists
8. Offer direct help if the tool fails to load or produces an unexpected verdict
9. Ask for the collect-support bundle or issue template report, not GitHub stars
