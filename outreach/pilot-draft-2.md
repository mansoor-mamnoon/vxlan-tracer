# Pilot Draft 2 — Cilium eBPF Masquerade Drops PTB

**Target issue:** https://github.com/cilium/cilium/issues/33844
**Contact category:** RC2-PC02 (Cilium PTB suppression, 11/12)
**Status:** DO NOT SEND — draft only. Requires TC coexistence test gate.

---

## Before sending: one manual check to suggest first

> Can you confirm whether `iptables -t filter -L INPUT -n -v | grep icmp` or
> `iptables -t mangle -L PREROUTING -n -v | grep icmp` shows any DROP rules for
> ICMP type 3 code 4 on the affected node? That would give us a baseline before
> trying a BPF diagnostic.

---

## Draft message (GitHub issue comment)

> The ICMP fragmentation-needed suppression you're describing — where the eBPF masquerade
> path appears to intercept or rewrite PTBs before they reach the pod — is exactly the
> observation window that [vxlan-tracer](https://github.com/mansoor-mamnoon/vxlan-tracer)
> was designed to measure.
>
> The tool attaches two observation points simultaneously:
> 1. A TC sched_cls hook on the underlay ingress **before netfilter** (counts PTBs
>    arriving at the NIC)
> 2. A kprobe on `icmp_rcv` **after netfilter** (counts PTBs that the kernel's ICMP
>    handler processes)
>
> If point (1) shows PTBs arriving but point (2) shows none, the tool reports
> `PTB_SUPPRESSED`. The signal is consistent with a drop somewhere between those
> two observation points — the netfilter/eBPF masquerade layer runs in that window.
>
> I want to be clear about what the tool can and cannot tell you:
> - It CAN tell you whether PTBs are present at the NIC and absent at icmp_rcv.
> - It CANNOT identify which specific eBPF program or netfilter rule is responsible.
>   That narrowing would still require Cilium-level debugging (bpftrace, Cilium monitor).
>
> This is an experimental prerelease, not yet tested against a real Cilium cluster.
> On Cilium coexistence: rc2 attaches at TC priority 50000, not priority 1, so
> Cilium's existing filters are not disturbed.
>
> If you're able to try it on a staging Cilium node with masquerade enabled:
>
> ```bash
> # Discover interfaces (suggested underlay: the node's primary NIC)
> vxlan-tracer interfaces
>
> # Run during traffic that would normally trigger a PTB
> sudo vxlan-tracer --overlay <cilium_vxlan> --underlay <eth0> --duration 60s
> ```
>
> If the load fails or you get an unexpected verdict, `vxlan-tracer collect-support`
> creates a privacy-safe bundle you can attach here. That alone is useful for the
> kernel matrix even if the verdict isn't what we expect.
>
> Happy to help interpret the result.

---

## Notes for review

- Does NOT say "definitively proves" — says "consistent with"
- Explicitly states what tool cannot do (identify specific code path)
- Says "experimental prerelease, not yet tested against Cilium"
- Explains coexistence (priority 50000)
- Asks for support bundle on failure
- Does not ask for stars
