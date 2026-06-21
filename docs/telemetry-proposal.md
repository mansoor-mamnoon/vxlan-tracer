# Telemetry Proposal

**Status:** Proposal only — NO implementation. This document describes what telemetry *could* be collected and how, for future consideration. Nothing in this proposal is implemented or will be implemented without explicit user approval and a privacy review.

---

## Motivation

vxlan-tracer's validated kernel matrix currently covers 4 kernels across 2 architectures, all from a single controlled lab environment. To understand whether the tool produces correct verdicts in real production environments, we need signal from real runs.

The questions we can't answer without external data:
- Does `ip_do_fragment` appear as a T symbol on kernels we haven't tested?
- Are there distributions where BTF is present but kprobe attachment still fails?
- What fraction of users see `NO_ISSUE_OBSERVED` vs. an actionable verdict?
- How often is the tool run on the wrong interface (overlay/underlay swapped)?

---

## Proposed telemetry events

**Event 1 — Run started**

Triggered when `loader.Attach()` succeeds.

```json
{
  "event": "run_started",
  "kernel": "6.8.0-1059-azure",
  "arch": "x86_64",
  "vxlan_tracer_version": "v0.1.0-rc1",
  "vxlan_port": 4789
}
```

**Not included:** Interface names, IP addresses, PID, hostname, user, or any identifying information.

---

**Event 2 — Verdict produced**

Triggered on successful diagnosis.

```json
{
  "event": "verdict",
  "kernel": "6.8.0-1059-azure",
  "arch": "x86_64",
  "vxlan_tracer_version": "v0.1.0-rc1",
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "fragmentation_scope": "global_corroborated",
  "duration_seconds": 30
}
```

**Not included:** MTU values (could identify specific network configurations), counter values, overlay/underlay names.

---

**Event 3 — BPF load failure**

Triggered when `loader.Attach()` fails.

```json
{
  "event": "bpf_load_failed",
  "kernel": "6.8.0-1059-azure",
  "arch": "x86_64",
  "vxlan_tracer_version": "v0.1.0-rc1",
  "error_category": "verifier_error"
}
```

**Error categories (not raw error messages):** `verifier_error`, `symbol_not_found`, `btf_missing`, `permission_denied`, `unknown`.

---

## Privacy requirements

Any telemetry implementation MUST:

1. **Opt-in only.** Telemetry is disabled by default. The user must explicitly enable it with a flag (`--telemetry`) or config file entry.
2. **No identifying information.** No hostname, username, IP address, interface name, MAC address, or any other identifier that could link the event to a specific machine or organization.
3. **No payload data.** No packet contents, no BPF map values beyond what's listed above.
4. **Disclosed prominently.** If telemetry is enabled, the binary must print a notice to stderr before running. The notice must describe what is sent and where.
5. **Deletable.** A `--telemetry-disable` or equivalent must clear any stored consent.
6. **No third-party analytics services.** Data must go to infrastructure controlled by this project, not Google Analytics, Amplitude, Sentry, or similar.

---

## Implementation options (not implemented — evaluation only)

### Option A — Periodic batch upload to a project-controlled endpoint

The binary collects events during the run and sends a batch POST to `telemetry.vxlan-tracer.example.com` (hypothetical) on exit, only if `--telemetry` is set.

Pros: Simple, low overhead.
Cons: Requires infrastructure; HTTPS from arbitrary nodes; may be blocked by corporate firewalls.

### Option B — User-initiated upload via `vxlan-tracer report`

A new subcommand that creates a JSON file with the last run's anonymized events and prints a `curl` command the user can run manually to submit.

Pros: User sees exactly what's being sent; no automatic network calls.
Cons: Low compliance rate; most users won't run the extra step.

### Option C — No automated telemetry; GitHub issue templates instead

The `external-run-report` issue template is the telemetry. Users manually file reports. No code changes needed; privacy is inherent.

Pros: Zero privacy risk; highest trust; already implemented.
Cons: Low data volume; selection bias toward users who hit problems.

---

## Recommendation

**Option C (manual issue templates) for v0.1 and v0.2.**

The overhead of designing, implementing, and maintaining privacy-safe telemetry infrastructure is not justified until the tool has at least 100 external users. The external-run-report template already collects the key fields (kernel, arch, CNI, verdict). When manual submissions reach 10+, the pattern will be clear enough to decide whether automated telemetry adds enough value to justify the work.

If automated telemetry is adopted later, it MUST go through an explicit privacy review and be presented to users clearly before any data is collected.

---

## NOT in scope for this proposal

- Any form of usage tracking that does not require explicit opt-in
- Collection of interface names, IP addresses, or any network topology data
- Integration with commercial analytics or error-tracking services
- Telemetry from the `collect-support` bundle (that bundle is user-initiated and user-controlled)
