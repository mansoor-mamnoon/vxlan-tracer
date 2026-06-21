# User Acquisition Metrics

**Baseline date:** 2026-06-20 (after v0.1.0-rc1 release)
**Review cadence:** Weekly

---

## Primary metrics

| Metric | Baseline | Week 1 | Week 2 | Week 4 | Target (90d) |
|--------|----------|--------|--------|--------|--------------|
| GitHub stars | 0 | — | — | — | 50 |
| GitHub forks | 0 | — | — | — | 5 |
| External run reports filed | 0 | — | — | — | 3 |
| Unique kernels in matrix | 4 | — | — | — | 6 |
| Unique CNIs validated | 0 | — | — | — | 1 |
| Issue replies sent | 0 | — | — | — | 10 |
| Positive replies received | 0 | — | — | — | 2 |
| Clones (GitHub traffic) | 0 | — | — | — | 100 |
| Release downloads | 0 | — | — | — | 50 |

---

## Acquisition funnel

| Stage | Definition | Count | Notes |
|-------|-----------|-------|-------|
| Aware | Saw the tool (star, clone, release download) | 0 | |
| Engaged | Opened an issue, replied to outreach | 0 | |
| Ran it | Filed an external run report | 0 | |
| Validated | Confirmed a new kernel/CNI in the matrix | 0 | |
| Returned | Filed a second issue or PR | 0 | |

---

## Outreach activity log

| Date | Channel | Action | Result |
|------|---------|--------|--------|
| (none yet) | | | |

---

## Kernel matrix progress

| Kernel | Arch | CNI | Status |
|--------|------|-----|--------|
| 6.8.0-1059-azure | x86_64 | (netns lab) | validated v0.1.0-rc1 |
| 6.8.0-1052-azure | x86_64 | (netns lab) | validated pre-rc1 |
| 5.15.0-181-generic | aarch64 | (netns lab) | validated pre-rc1 |
| 6.10.14-linuxkit | aarch64 | (netns lab) | validated pre-rc1 |
| — | — | k3s/Flannel | not yet |
| — | — | Calico VXLAN | not yet |
| — | — | Cilium VXLAN | not yet |

---

## Notes

- All metrics reset from 0 at v0.1.0-rc1 release (2026-06-21)
- "External run report" = GitHub issue using the external-run-report template
- "Validated" means the new kernel + CNI combination returns a correct verdict on a real cluster (not just a netns lab)
- Release downloads tracked via `gh api repos/mansoor-mamnoon/vxlan-tracer/releases` asset download counts
- Stars and forks tracked via GitHub repository insights
