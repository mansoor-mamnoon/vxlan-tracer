# User Acquisition Sprint Report

**Sprint period:** 2026-06-20
**Goal:** Acquire the first real external users of vxlan-tracer.
**Status:** Preparation complete. No outreach sent yet — pending explicit approval.

---

## What was prepared

### Phase 1 — External user experience audit

`docs/external-user-audit.md` — A skeptical platform engineer's first-encounter audit identifying 11 friction points ranked from BLOCKER to MINOR. Key findings:

- **B1 (BLOCKER):** No interface discovery command. Users don't know `--overlay`/`--underlay` values.
- **B2 (BLOCKER):** Release archive buried below build instructions. Users assume they need to build from source.
- **M1 (MAJOR):** No issue templates for structured feedback.
- **M2 (MAJOR):** No diagnostic bundle command.
- **M3 (MAJOR):** Preflight scapy check is FAIL even when scapy isn't needed for the fragmentation demo.

---

### Phase 2 — `vxlan-tracer interfaces` subcommand

Implemented in `internal/netlink/ListVXLAN()` (Linux build) and `cmd/vxlan-tracer/main.go`.

```
$ vxlan-tracer interfaces
VXLAN interfaces on this host:

  NAME        VNI    PORT    MTU     UNDERLAY
  flannel.1   1      8472    1450    eth0

Suggested invocations:
  sudo vxlan-tracer --overlay flannel.1 --underlay eth0
```

- No root required
- JSON output via `--json`
- Unit tests in `internal/netlink/list_test.go`
- Fixes B1 from audit

---

### Phase 3 — `vxlan-tracer collect-support` subcommand

Implemented in `cmd/vxlan-tracer/main.go`.

```
$ vxlan-tracer collect-support --dry-run
Would collect:
  system-info.txt          Linux kernel version and architecture
  vxlan-interfaces.txt     VXLAN interfaces: names, VNIs, ports, MTUs
  btf-status.txt           BTF vmlinux file availability and size
  bpf-mounts.txt           BPF filesystem mount entries from /proc/mounts
  kernel-symbols.txt       ip_do_fragment and icmp_rcv symbol availability
  vxlan-tracer-version.txt vxlan-tracer version string
  CONTENTS.txt             manifest of included files
  PRIVACY.txt              privacy notice
```

- Privacy-safe (no IP addresses, no route tables, no firewall rules)
- PRIVACY.txt describes exactly what is and is not included
- Fixes M2 from audit

---

### Phase 4 — GitHub issue templates

Created `.github/ISSUE_TEMPLATE/external-run-report.md` and `.github/ISSUE_TEMPLATE/compatibility-problem.md`.

Fixes M1 from audit. The external-run-report template requests:
- Kernel version, arch, distro, CNI, cloud/hardware
- vxlan-tracer version
- Verdict and full output
- Preflight output (optional)
- collect-support bundle (optional, but encouraged)

---

### Phase 5 — "Looking for design partners" README section

Added to `README.md` before the Lab setup section. 118 words. Invites engineers with VXLAN environments to run the tool on a staging node and file a run report.

---

### Phase 6 — Lead list

`outreach/lead-list.md` — 35 qualified leads from GitHub issues across Cilium (14), Calico (9), Flannel (3), Rancher (3), k3s (1), KubeVirt (2), Kubernetes core (2), and Tailscale (1).

All leads are real GitHub issues with real public URLs. 14 are high-confidence (direct symptom match, active issue).

---

### Phase 7 — Priority contacts

`outreach/priority-contacts.md` — 15 ranked contacts scored on symptom match, recency, likelihood of response, and environment novelty.

Top 5:
1. Cilium/KubeVirt egress gateway fragmentation (12/12)
2. Calico random veth MTU 1500 (11/12)
3. Cilium eBPF masquerade drops PTB (11/12)
4. KubeVirt slow 80 Mbit/s throughput (10/12)
5. Cilium + Tailscale stacked overlay MTU (10/12)

---

### Phase 8 — Message templates + 15 personalized drafts

`outreach/message-templates.md` — 3 context templates (PTB_SUPPRESSED, VXLAN_MTU_MISCONFIGURATION, VXLAN_FRAGMENTATION_OBSERVED) + 15 personalized issue reply drafts, one per priority contact.

Every draft is personalized: references the specific symptom, environment, error message, or MTU boundary from the target issue. No generic "have you tried my tool" messages.

---

### Phase 9 — Technical post

`outreach/technical-post.md` — A technical article for Hacker News / dev.to explaining:
- The VXLAN MTU blackhole mechanism (DF=0 fragmentation vs. PTB suppression)
- Why standard tools (tcpdump, iptables inspection) don't catch it
- The eBPF approach (TC hooks + kprobes, counter split)
- Limitations (global ip_do_fragment scope, no per-VNI attribution)

---

### Phase 10 — Platform launch drafts

- `outreach/show-hn.md` — Show HN post (~350 words, technical, explicit about prerelease status)
- `outreach/linkedin.md` — LinkedIn post (~200 words, practitioner-focused)
- `outreach/reddit.md` — r/kubernetes and r/sysadmin drafts
- `outreach/kubernetes-forum.md` — discuss.kubernetes.io post + Kubernetes Slack context message

---

### Phase 11 — Demo recording plan

`outreach/demo-recording-plan.md` — 45-second 3-scene terminal recording plan:
1. `vxlan-tracer interfaces` (0:00–0:08, no root)
2. Full diagnostic with VXLAN_FRAGMENTATION_OBSERVED verdict (0:08–0:40)
3. JSON output (0:40–0:45)

Includes recording tool recommendations and caption text for social posts.

---

### Phase 12 — User acquisition tracker

- `outreach/user-tracker.csv` — 15 rows (one per priority contact), all in "not yet contacted" state
- `outreach/metrics.md` — baseline metrics dashboard (all zeros), target metrics for 90 days, kernel matrix progress tracking

---

### Phase 13 — External feedback playbook

`docs/external-feedback-playbook.md` — Covers:
- Response timelines (48h for run reports, 24h for compatibility problems)
- Triage criteria for new kernel entries, wrong verdicts, crashes
- Standard ask sequence (what to request in what order)
- How to convert a run report to a matrix entry
- What to say in common scenarios

---

### Phase 14 — Telemetry proposal

`docs/telemetry-proposal.md` — Documents what telemetry *could* be collected and how, with privacy requirements. **No implementation.** Recommendation: use GitHub issue templates (already implemented) until manual submissions reach 10+.

---

## What was NOT done (pending approval)

| Action | Reason |
|--------|--------|
| Sending any of the 15 personalized drafts | Requires explicit approval |
| Posting Show HN | Requires explicit approval |
| Posting on LinkedIn | Requires explicit approval |
| Posting on Reddit | Requires explicit approval |
| Posting on discuss.kubernetes.io | Requires explicit approval |
| Creating GitHub labels | Can be done without approval, but not done yet |
| Recording the demo | Requires a Linux environment and explicit approval |

---

## Recommended next steps (in priority order)

1. **Review and approve 2–3 outreach drafts** from `outreach/message-templates.md`. The highest-value targets are PC01 (Cilium/KubeVirt, 12/12 score) and PC02 (Calico random MTU, 11/12 score).

2. **Fix M3 from the audit:** Change the scapy preflight check from FAIL to WARN. This is a one-line change in `scripts/preflight.sh`. It reduces the first-run friction for any external user who runs preflight before the diagnostic.

3. **Create GitHub labels** for the issue templates: `external-run`, `compatibility`, `bug`. These make it easier to filter and triage incoming reports.

4. **Record the demo.** The 45-second recording plan is in `outreach/demo-recording-plan.md`. Requires a Linux node and ~15 minutes of setup time.

5. **Decide on Show HN timing.** The Show HN post is most effective when filed Monday–Thursday between 7am–10am PT. Wait until at least one outreach contact has replied to have a "first external run" to mention.

---

## Code changes made during this sprint

| Change | File | Phase |
|--------|------|-------|
| `ListVXLAN()` + `VXLANCandidate` | `internal/netlink/vxlan.go` | 2 |
| `VXLANCandidate` stub + `ListVXLAN()` stub | `internal/netlink/vxlan_other.go` | 2 |
| Unit tests for ListVXLAN | `internal/netlink/list_test.go` | 2 |
| Subcommand routing in `main()` | `cmd/vxlan-tracer/main.go` | 2 |
| `runInterfaces()` function | `cmd/vxlan-tracer/main.go` | 2 |
| `runCollectSupport()` function + privacy notice | `cmd/vxlan-tracer/main.go` | 3 |
| Issue template: external run report | `.github/ISSUE_TEMPLATE/external-run-report.md` | 4 |
| Issue template: compatibility problem | `.github/ISSUE_TEMPLATE/compatibility-problem.md` | 4 |
| "Looking for design partners" section | `README.md` | 5 |

All changes compile cleanly (`go build ./...`, `go vet ./...`, unit tests pass on macOS).
