# Pilot Draft 1 — Cilium/KubeVirt Egress Gateway Fragmentation

**Target issue:** https://github.com/cilium/cilium/issues/38828
**Contact category:** RC2-PC01 (Cilium KubeVirt, 12/12)
**Status:** DO NOT SEND — draft only. Requires TC coexistence test gate.

---

## Before sending: one manual check to suggest first

Before sharing the tool, suggest the reporter run this first to verify the symptom
is present before investing time in a BPF diagnostic:

> Before anything else: can you run `tc filter show dev cilium_vxlan egress` and
> `ip link show cilium_vxlan` on the egress gateway node? I want to see whether
> the outer packet MTU is already correct before suggesting a BPF diagnostic tool.

---

## Draft message (GitHub issue comment)

> The egress gateway fragmentation you're describing — large responses from KubeVirt VMs
> being fragmented as they exit through `cilium_vxlan` — is exactly what I've been
> building a diagnostic tool to detect.
>
> It's called [vxlan-tracer](https://github.com/mansoor-mamnoon/vxlan-tracer). It's an
> experimental prerelease (not yet tested against a real Cilium cluster). Here's what it
> does that's relevant to your issue:
>
> **For fragmentation (your likely case):** It attaches a kprobe on `ip_do_fragment` (the
> kernel function that fires when an IP packet is fragmented) and a TC egress hook on the
> VXLAN overlay. When both signal simultaneously — fragmentation events AND outer packets
> exceeding the underlay MTU — it reports `VXLAN_FRAGMENTATION_OBSERVED` with
> `fragmentation_scope: global_corroborated`. This is two independent signals pointing at
> the same location.
>
> **For PTB suppression:** It also measures whether any ICMP "packet too big" messages
> are arriving at the NIC (pre-netfilter) but not reaching `icmp_rcv` (post-netfilter).
> If there's an eBPF policy or netfilter rule between those two points suppressing PTBs,
> you'd see `PTB_SUPPRESSED`.
>
> **Important caveats:**
> - This is an experimental prerelease, not yet tested against a real Cilium or KubeVirt
>   environment. Your setup would be the first.
> - It does not identify which specific code path is responsible for the fragmentation or
>   suppression — only that a signal is present at those observation points.
> - Please run it on a non-critical or staging node only.
>
> **On Cilium coexistence:** rc2 attaches at TC priority 50000 (not priority 1), so
> Cilium's `cil_from_netdev` and `cil_to_netdev` filters at priority 1 are not touched.
>
> If you're able to try it:
> ```bash
> # Discover interfaces (no root required)
> vxlan-tracer interfaces
>
> # Run diagnostic during a large VM-to-VM transfer through the egress gateway
> # (30s window — start traffic before running)
> sudo vxlan-tracer --overlay cilium_vxlan --underlay eth0 --duration 30s
> ```
>
> If it fails to load (BPF verifier error, symbol not found), please share the full
> stderr and the output of `sudo bash scripts/preflight.sh`. That alone is useful data.
>
> Happy to help interpret the result or debug a load failure if you try it.

---

## Notes for review

- Does NOT say "definitively proves" or "identifies the Cilium code path"
- Says "experimental prerelease, not yet tested against Cilium"
- Recommends staging/non-critical node
- Explains Cilium coexistence (priority 50000 vs. priority 1)
- Asks for support bundle if it fails
- Does not ask for GitHub stars
- Does not mention Show HN or any launch
