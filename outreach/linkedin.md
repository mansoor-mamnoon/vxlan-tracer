# LinkedIn post draft

**Draft — do not post without approval.**

---

**Post:**

If you've ever watched `kubectl cp` hang silently while small requests work fine, you've probably hit a VXLAN MTU blackhole.

VXLAN adds 50 bytes of overhead per packet. If the overlay MTU isn't reduced to account for that, oversized packets may be fragmented or dropped — with no error in your application logs.

I built vxlan-tracer to diagnose this. It uses eBPF (TC sched_cls + kprobes) to count fragmentation events and PTB (ICMP "packet too big") suppression at the kernel level. In under a minute it tells you which of these is happening:

→ Fragmentation observed (ip_do_fragment firing, outer packets exceed underlay MTU)
→ PTBs suppressed (arriving at the NIC but dropped before reaching the kernel)
→ PTBs delivered (PMTUD is working correctly)
→ MTU misconfiguration detected (static risk, no active traffic needed)
→ No issue observed

New in this release: `vxlan-tracer interfaces` lists all VXLAN interfaces on your host with their VNI, port, MTU, and inferred underlay — no root required, useful as a quick sanity check before running the full diagnostic.

Currently an experimental prerelease — validated in a controlled lab on 5.15 through 6.10 kernels (aarch64 + x86_64), not yet tested against a real CNI cluster. If you run it on a staging node, I'd be interested to hear the result.

https://github.com/mansoor-mamnoon/vxlan-tracer

---

**Notes:**
- LinkedIn audience is more practitioner/DevOps than HN; keep it accessible
- The bullet list format works well on LinkedIn
- Avoid jargon like "TC sched_cls" in the main post body
- Emphasize the diagnostic angle, not the implementation
- Word count ~200 — appropriate for LinkedIn
