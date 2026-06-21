# External User Experience Audit

**Perspective:** Skeptical senior platform engineer / SRE at a company running k3s or self-managed Kubernetes.
**Scenario:** Production symptom — `kubectl cp` and large API responses stall intermittently.
Searched "VXLAN MTU fragmentation debug Linux". Found this repo. Evaluating whether to run it on a staging node.

---

## First impressions (README)

**What works:**
- Problem statement is precise ("small requests work, large stall silently") — matches my symptom immediately.
- VXLAN overhead math is correct and explained.
- "What it is NOT" section builds trust — correct observation that TC egress + kprobes are the right hooks.
- Status table shows what's done vs. in progress.
- The 5-verdict list is exactly what I want from a diagnostic.

**First friction (30 seconds in):**
The demo command is `sudo vxlan-tracer --overlay vxlan0 --underlay eth0` but I have no idea what my interface names are.
On k3s the overlay interface is `flannel.1`, not `vxlan0`. On Calico VXLAN it's `vxlan.calico`.
There is no command I can run to discover this. I'd need to run `ip link show` and manually grep for the type.

---

## Barrier ranking

### BLOCKER — B1: No interface discovery subcommand

**Finding:** `--overlay` and `--underlay` are required flags with no auto-detection or enumeration. A new user must know their CNI's interface naming convention before they can invoke the tool.

**Impact:** Nearly every external user will be stopped here. A platform engineer's first instinct is to type `vxlan-tracer interfaces` or similar to discover what's available — this fails with "flag provided but not defined".

**Fix:** Implement `vxlan-tracer interfaces` to enumerate VXLAN-type interfaces, their VNI, port, MTU, and inferred underlay. No root required.

---

### BLOCKER — B2: Release archive buried below build instructions

**Finding:** The README opens with "Quick demo from packaged release archive" (correct!), but immediately below is a longer "Quick demo from source" section. A reader scanning for how to get the binary finds `make bpf` first and assumes they need to build from source.

**Impact:** Staging and production nodes typically don't have `clang`, `bpftool`, `libbpf-dev`, or Go installed. If an engineer thinks they must install build deps to use this tool, they abandon before starting.

**Fix:** Move the release archive section above everything else; rename it "Install" or "Get started". Add direct download URL example with `curl`/`wget` + `tar`.

---

### MAJOR — M1: No issue templates or structured feedback path

**Finding:** GitHub Issues are blank. No labels, no templates. If I run this and it produces a wrong verdict, I have no way to file a structured report. The ask ("what kernel, what CNI, what verdict did you get") is unanswered.

**Impact:** Even motivated external users won't file a free-form bug report on a tool they just met. The friction between "it misbehaved" and "I filed a useful report" must be near zero.

**Fix:** Create at minimum two issue templates: "External run report" (compatibility + verdict) and "Compatibility problem" (wrong verdict, crash, failed load).

---

### MAJOR — M2: No diagnostic bundle / collect-support command

**Finding:** When something goes wrong during attachment or diagnosis, there's no single command to collect the relevant system state (kernel version, BTF availability, kallsyms check, BPF mount status, VXLAN interfaces) and package it for sharing.

**Impact:** Debugging a remote user's environment over issue comments without structured data is slow. The user doesn't know which system facts are relevant.

**Fix:** Implement `vxlan-tracer collect-support [--dry-run]` that produces a privacy-safe `.tar.gz` with system-info.txt, vxlan-interfaces.txt, btf-status.txt, bpf-mounts.txt, kernel-symbols.txt, and a CONTENTS.txt + PRIVACY.txt.

---

### MAJOR — M3: Scapy dependency for demo is a non-starter on most nodes

**Finding:** `scripts/demo.sh` and `scripts/preflight.sh` both require `scapy` (via `python3 -c "import scapy"`). Most Kubernetes nodes don't have scapy installed. The preflight script shows a FAIL for this.

**Impact:** An engineer who extracts the release archive and runs `sudo bash scripts/preflight.sh` will see a FAIL for scapy before any BPF check runs. Scapy is only used for PTB injection (`inject_ptb.py`) — the fragmentation demo (`demo.sh`) does NOT actually call scapy. The preflight check is misleading.

**Fix (quick):** Make the scapy check a WARN (not FAIL) and note it is only required for PTB injection scenarios, not for the standard fragmentation demo or diagnostic run.

---

### MAJOR — M4: No CONTRIBUTING.md or SECURITY.md

**Finding:** There's no `CONTRIBUTING.md`. If I find a bug or want to report that it works on a new kernel, there's no documented process. There's no `SECURITY.md` for responsible disclosure.

**Impact:** Reduces trust from engineers who care about project professionalism. Specific ask: where do I send kernel matrix additions? Can I PR them?

**Fix:** Minimal CONTRIBUTING.md (≤ 30 lines): how to file an issue, how to contribute a kernel matrix entry, DCO or CLA policy (none, given MIT), how to report security issues.

---

### MODERATE — Mo1: Troubleshooting section absent

**Finding:** The README has no troubleshooting guide. Common failure modes during early external use:
- Binary attaches but returns `NO_ISSUE_OBSERVED` because `--duration` was too short or traffic is small
- `ip_do_fragment not found as T symbol` in preflight (kernel inlines it)
- `bpffs not mounted` on minimal nodes (busybox, Alpine)
- `CAP_BPF missing` in non-root container

**Impact:** Engineers give up or file vague issues.

**Fix:** Add a `docs/troubleshooting.md` with the 5 most common failure modes and their fixes. Link from README.

---

### MODERATE — Mo2: Release archive quick-start doesn't show how to verify the download

**Finding:** README shows `tar -xzf vxlan-tracer-linux-amd64.tar.gz` without showing the `sha256sum -c checksums.sha256` step that proves the archive wasn't corrupted in transit.

**Impact:** Platform engineers at security-conscious organizations will not run an unverified binary from an unknown release page.

**Fix:** Add checksum verification step before `tar -xzf` in the README quick-start.

---

### MODERATE — Mo3: "Two-node k3s validation not complete" — no clear path to external validation

**Finding:** The README correctly states validation gaps. But there's no invitation to help fill them. An engineer who has a k3s cluster and wants to contribute a validation report doesn't know this is valued or how to do it.

**Fix:** Add a "Looking for design partners" section that explicitly invites engineers with VXLAN environments to run the tool and report back.

---

### MINOR — mi1: `exit 0` for all verdicts feels odd without documentation

**Finding:** The tool exits 0 for all 5 verdicts (including `VXLAN_FRAGMENTATION_OBSERVED`), and exits 2 for errors. This is documented in `docs/exit-codes.md` but not in README or `--help`. An operator piping the output to a CI check will be surprised that `fragmentation observed` returns 0.

**Fix:** Add a one-line exit-code note in the Usage section of README.

---

### MINOR — mi2: Build toolchain not listed with versions in README

**Finding:** Requirements table lists clang 12+ but not which Ubuntu/Debian packages provide it, or whether `apt-get install clang` is sufficient. On Ubuntu 22.04, the default clang is 14 (fine); on 20.04 it's 10 (too old).

**Fix:** Add a `make deps` or installation example: `apt-get install clang llvm libbpf-dev linux-tools-$(uname -r) linux-libc-dev`.

---

## Security and privacy assessment

| Concern | Assessment |
|---------|------------|
| Root requirement | Expected for eBPF; documented; acceptable |
| BPF programs attach to named interface egress/ingress | Risk: wrong interface causes missed events, not crash or leak; low risk |
| TC filters remain after `Ctrl-C` | Expected behavior (documented); filters are stateless counters, not data processors |
| BPF programs read IP headers only (no payload) | Verified in BPF C source — good |
| No telemetry, no phone-home | Confirmed — no network calls from the binary |
| `collect-support` output | Does NOT include route tables, iptables rules, or IP addresses — see PRIVACY.txt |
| Release archive checksums | Provided; not shown in README quick-start (M02 above) |
| MIT license | Clean; no GPL or copyleft |

**Verdict on safety:** Acceptable for a staging/non-critical node. Would not run on a production node without a longer soak in a lab first. The BPF verifier acceptance across 4 kernels is the strongest safety signal.

---

## Audit summary table

| ID | Category | Summary | Priority |
|----|----------|---------|----------|
| B1 | UX | No interface discovery subcommand | BLOCKER |
| B2 | UX | Release archive buried; build deps assumed | BLOCKER |
| M1 | Community | No issue templates | MAJOR |
| M2 | UX | No collect-support / diagnostic bundle | MAJOR |
| M3 | UX | Scapy preflight FAIL misleads (not needed for demo) | MAJOR |
| M4 | Community | No CONTRIBUTING.md or SECURITY.md | MAJOR |
| Mo1 | Docs | No troubleshooting section | MODERATE |
| Mo2 | Docs | Checksum verification not shown in quick-start | MODERATE |
| Mo3 | Community | No invitation for external validation contributions | MODERATE |
| mi1 | Docs | exit-code behavior not in README | MINOR |
| mi2 | Docs | Build toolchain install commands missing | MINOR |

---

## Phase-to-fix mapping

| Phase | Fixes |
|-------|-------|
| Phase 2 (`interfaces` subcommand) | B1 |
| Phase 3 (`collect-support` subcommand) | M2 |
| Phase 4 (issue templates) | M1 |
| Phase 5 (design partners section) | Mo3 |
| preflight.sh scapy → WARN | M3 |
| docs/troubleshooting.md | Mo1 |
| README checksum step | Mo2 |
| README exit-code note | mi1 |
| README build toolchain | mi2 |
| CONTRIBUTING.md | M4 |
