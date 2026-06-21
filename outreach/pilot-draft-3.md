# Pilot Draft 3 — VXLAN PTB Suppression (non-CNI eBPF, firewall-level)

**Target issue category:** Issues where ICMP "fragmentation needed" is being dropped
by iptables or nftables INPUT rules (not CNI-specific eBPF policy).
**Contact category:** RC2-PC03 (generic PTB suppression, 9/12)
**Status:** DO NOT SEND — draft only. Requires TC coexistence test gate.
**Candidate issues:** L010, L028, L031 in outreach/lead-list.md

---

## Context

This draft is for issues where the reporter:
- Has confirmed ICMP type 3 code 4 packets are being dropped
- Suspects or has found an iptables/nftables INPUT rule
- Is on a VXLAN overlay (not necessarily a CNI-managed one)
- May not have a CNI with its own TC BPF filters

This is the cleanest first pilot: no CNI conflict risk, clear PTB suppression symptom,
tool is directly relevant.

---

## Before sending: suggest one manual check first

> Before anything else, can you run:
> ```bash
> iptables -t filter -L INPUT --line-numbers -n -v | grep -i icmp
> nft list ruleset | grep -i "icmp\|type 3\|type frag"
> ```
> This will tell us immediately if there's a DROP rule matching fragmentation-needed.

---

## Draft message (GitHub issue comment)

> The symptom you described — PTBs not reaching pods or sockets, large packets stalling
> indefinitely — is the primary use case for a tool I've been building:
> [vxlan-tracer](https://github.com/mansoor-mamnoon/vxlan-tracer).
>
> It measures the gap between two kernel observation points at the same time:
> - **TC ingress on the underlay NIC:** fires before netfilter (counts PTBs as they
>   arrive from the wire, regardless of any iptables/nftables rules)
> - **kprobe on `icmp_rcv`:** fires after netfilter (counts PTBs that survived and
>   reached the kernel's ICMP handler)
>
> If TC > 0 and icmp_rcv = 0, the verdict is `PTB_SUPPRESSED` — the signal is
> consistent with a drop between those two points. Combined with the `iptables` output
> above, that would strongly support the theory that a DROP rule is the cause.
>
> A few things to know before trying it:
> - It's an experimental prerelease, not yet tested in a production environment.
>   The lab validation covers 5.15–6.10 kernels on amd64 and arm64.
> - It does not modify any traffic — TC programs return TC_ACT_OK and the kprobe
>   is read-only.
> - Run it on a staging or non-critical node.
>
> Quick start (Linux, root required for BPF):
> ```bash
> # First: identify your VXLAN interface
> vxlan-tracer interfaces
>
> # Then: run during traffic that should be triggering PTBs
> sudo vxlan-tracer \
>   --overlay <your-vxlan-interface> \
>   --underlay <your-underlay-nic> \
>   --duration 60s
> ```
>
> If the tool fails to load (BPF verifier error, symbol not kprobeable), run
> `sudo bash scripts/preflight.sh` and share the output here — that's useful even
> without a diagnostic run. `vxlan-tracer collect-support` creates a privacy-safe
> bundle you can attach to this issue.
>
> Happy to help interpret whatever the tool reports.

---

## Notes for review

- Opens with a manual check suggestion (less disruptive than jumping straight to a BPF tool)
- Explains the two observation points clearly
- Says "consistent with" not "proves"
- Explicit about "experimental prerelease"
- Mentions staging/non-critical
- Asks for preflight output if load fails
- Does not ask for stars
- Does not mention any social posts or launches
