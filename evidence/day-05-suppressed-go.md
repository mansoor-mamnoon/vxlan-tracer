# Day 5: suppressed PTB test through the Go CLI (commit 9)

This is the first true CLI-level diagnostic proof: the Go binary attaches,
observes a PTB-suppression event live, reads its own pinned maps, and
prints the correct verdict — no shell script, no bpftool, no manual
counter comparison.

## Test setup

Same ns1/ns2/vxlan0 lab as commit 8, with one addition: before starting
the loader, installed an iptables DROP rule in ns1 for the exact ICMP
type/code the kprobe filters on:

```
ip netns exec ns1 iptables -A INPUT -p icmp --icmp-type 3/4 -j DROP
```

Confirmed installed via `iptables -L INPUT -v -n` (0 packets matched yet,
rule present).

Sequence:
1. Started `nsenter --net=/var/run/netns/ns1 -- vxlan-tracer-linux-arm64
   --overlay vxlan0 --underlay veth1 --pin-dir /sys/fs/bpf/vxlan-tracer
   --bpf-dir /tmp/bpfobjs --duration 20s` in the background.
2. Confirmed attach succeeded after a 3s settle.
3. From ns2: injected 5 synthetic ICMP type=3/code=4 packets toward ns1's
   underlay (`spikes/inject_ptb.py --src 192.168.100.2 --dst 192.168.100.1
   --dev veth2 --next-hop-mtu 1400 --count 5`).
4. Confirmed via `iptables -L INPUT -v -n` that the DROP rule's packet
   counter advanced from 0 to 5 (280 bytes) — independent, kernel-level
   confirmation that exactly 5 PTBs reached netfilter and were dropped
   there.
5. Waited for the Go process to finish its `--duration 20s` window.

## Result

```
attached: tc ingress, tc egress, kprobe/icmp_rcv; maps pinned under /sys/fs/bpf/vxlan-tracer
detached kprobe (TC filters remain attached; maps remain pinned)
verdict: PTB_SUPPRESSED
5 ICMP type=3/code=4 packet(s) were observed at TC ingress, but 0 reached icmp_rcv: something between the NIC and icmp_rcv — commonly a netfilter/iptables DROP rule — is suppressing PTBs before the kernel can act on them.
```

Exit code 0. The Go binary's own pinned-map read shows TC ingress count 5
(pre-netfilter) and icmp_rcv count 0 (post-netfilter) — matching the
independent iptables counter (5 packets, 280 bytes matched the DROP rule)
read directly from the kernel via a completely separate tool. Two
independent observation points (iptables accounting, vxlan-tracer's own
TC-ingress-vs-icmp_rcv delta) agree on what happened.

Raw log: `/tmp/day5-commit9-suppressed.log` (Docker run, exit code 0).

## What is proven

- The complete Go-driven diagnostic path — attach, observe a real
  suppression event live, read pinned maps, diagnose, print a verdict,
  detach — correctly identifies PTB suppression with no bpftool, no shell
  script, and no manual counter comparison. This is the project's headline
  scenario (Day 1's stated goal) now proven through the actual CLI binary,
  not a lab script.
- Combined with commit 8 (`PTB_DELIVERED` when not suppressed), the Day 5
  primary success condition is met: "NOT SUPPRESSED when ingress and
  icmp_rcv both increase, SUPPRESSED when ingress increases and icmp_rcv
  stays zero" — both branches confirmed live, through the Go reader, in
  this and the prior commit.
- The iptables packet counter is an independent confirmation mechanism:
  vxlan-tracer's verdict is not the only signal saying suppression
  occurred — the kernel's own netfilter accounting agrees.

## What remains unproven

- This test used a single iptables DROP rule as the suppression mechanism.
  Other suppression mechanisms (nftables, a different netfilter hook,
  conntrack state issues, security modules) have not been tested and are
  not claimed to be detected — the verdict logic only distinguishes
  "TC ingress > 0, icmp_rcv == 0" from the other cases; it does not
  identify the suppressing mechanism.
- No test has yet exercised reload/restart behavior while a suppression
  condition is ongoing (e.g. restarting vxlan-tracer mid-test and
  confirming the pinned counters are NOT reset, since maps persist
  independently of the loader process — this is implied by the pinning
  design proven in commit 5 but not explicitly re-verified here).
- As in commit 8, `bpftool` was unavailable in this container, so only one
  independent cross-check (iptables packet counters) was available, not
  two.
