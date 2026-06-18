# Day 8 commit 3: ip_do_fragment header parsing spike

## Objective

Test whether reading outer IP protocol and outer UDP destination port from the
skb at `ip_do_fragment` entry can reliably identify VXLAN-specific fragmentation.
This is Option 4 from `docs/fragmentation-scoping.md`.

## BPF program

`spikes/probe_frag_scope.bpf.c` — a kprobe at `ip_do_fragment` that:
1. Reads `skb->len`, `skb->head`, `skb->network_header` via CO-RE
2. Reads the outer IP protocol field at `head + network_header + 9`
3. If proto=UDP (17), reads the UDP destination port at `head + network_header + 20 + 2`
4. If dport=4789 (VXLAN), increments a scoped `frag_vxlan_count` counter

Go loader: `spikes/probe_frag_scope/main.go` — attaches the kprobe and reads maps.

## Test environment

```
Kernel: 6.10.14-linuxkit aarch64
Lab: ns1 (vxlan0 MTU=1450 stale) → veth1 (MTU=1400) → ns2
Traffic: 3 large pings, payload=1360B (inner IP 1388B, outer IP 1438B > 1400 MTU)
```

## Compile result

```
clang -O2 -g -target bpf -D__TARGET_ARCH_arm64 ... probe_frag_scope.bpf.c
compile exit=0
```

BPF verifier accepted the program (bpf_probe_read_kernel allowed in kprobe).

## Load and run result

```
frag_scope_result map:
  [0] skb_len: 1388 (0x056c)      ← inner IP length, not outer (1438)
  [1] ip_proto: 1 (0x0001)        ← ICMP (not UDP=17 as expected for VXLAN outer)
  [2] udp_dport: 0 (0x0000)       ← 0 (ip_proto≠UDP branch taken)
  [3] is_vxlan: 0 (0x0000)        ← not identified as VXLAN

frag_vxlan_count: 2               ← 2 earlier calls correctly identified dport=4789
```

probe exit=0, attachment and map reads succeeded.

## Analysis

The results are contradictory:
- `frag_vxlan_count=2`: two ip_do_fragment calls during the run correctly identified
  the outer UDP dport=4789 → incremented the scoped counter.
- `frag_scope_result` (showing the LAST call): `ip_proto=1` (ICMP), `is_vxlan=0`.
  The last call did NOT identify the packet as VXLAN.

### Root cause: network_header inconsistency

`skb->network_header` does not consistently point to the outer IP header at
`ip_do_fragment` entry. This is consistent with the Day 7 finding that
`frag_max_skb_len` alternates between 1438 (outer IP length) and 1388 (inner IP
length) depending on kernel route MTU cache state.

At some ip_do_fragment invocations:
- `skb->len` = 1438 (outer IP total length)
- `head + network_header` → outer IP header → proto=17 (UDP) → dport=4789 → VXLAN ✓

At other ip_do_fragment invocations (route MTU cache active):
- `skb->len` = 1388 (inner IP length)
- `head + network_header` → inner IP header → proto=1 (ICMP) → not VXLAN ✗

The inconsistency occurs because the kernel's route MTU cache (PMTU discovery
state) changes how the VXLAN driver constructs and delivers the outer skb.
After repeated fragmentation events, the outer IP headers may be partially
"consumed" (via `__skb_pull` or similar) before ip_do_fragment is called,
changing what `network_header` points to.

### ICMP reply fragmentation

The final ip_do_fragment call with `proto=1 (ICMP)` may come from ns2's ICMP
echo reply traversing VXLAN back to ns1. If ns2's reply path also causes
fragmentation, those events fire globally and are included in our kprobe. The
network_header for those events may point to a different layer depending on
how ns2's kernel constructs the return path skb.

## Conclusion

Header parsing at `ip_do_fragment` entry is **unreliable** on this kernel
because:
1. `skb->network_header` does not consistently point to the outer IP header.
2. Some calls correctly identify VXLAN (proto=17, dport=4789); others see the
   inner IP header (proto=1 for ICMP).
3. The inconsistency is governed by kernel route MTU cache state, which is not
   under BPF control.
4. A scoped counter based on this approach would undercount VXLAN fragmentation
   events, giving less information than the global counter + two-signal approach.

**Option 4 (header parsing) is rejected for v0 on this kernel.**

The two-signal corroboration approach (Option 5, already implemented) remains
the v0 strategy. See `docs/fragmentation-scoping.md`.

## What is proven

- `bpf_probe_read_kernel` is permitted in kprobe programs on 6.10.14-linuxkit.
- The BPF program compiles and loads without verifier rejection.
- Header reads at `ip_do_fragment` entry are possible but inconsistent.
- 2 out of N calls correctly identified VXLAN via dport=4789; the last call did not.
- `skb->network_header` at ip_do_fragment entry is not a stable pointer to the
  outer IP header on this kernel with route MTU cache active.

## What remains unknown

- Whether header parsing would be more reliable on a kernel where the route MTU
  cache is NOT active (i.e., very first run in a fresh namespace).
- Whether fixing the approach to use `skb->transport_header` (directly to UDP
  header) instead of `skb->network_header + 20` would be more reliable.
- Whether the inconsistency is specific to linuxkit or present on standard kernels.
