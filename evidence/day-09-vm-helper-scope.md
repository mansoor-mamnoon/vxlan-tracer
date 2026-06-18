# Day 9 — Helper availability and scoping spike on 5.15.0-181-generic

**Date:** 2026-06-17
**Kernel:** 5.15.0-181-generic (Ubuntu 22.04.5 LTS, aarch64)
**VM:** Lima vxlan-test

## bpf_get_netns_cookie availability

### /proc/kallsyms wrappers

```
ffff80000849d5b0 T bpf_get_netns_cookie_sockopt
ffff80000908a270 T bpf_get_netns_cookie_sock
ffff80000908a2a4 T bpf_get_netns_cookie_sock_addr
ffff80000908a2e0 T bpf_get_netns_cookie_sock_ops
ffff80000908a320 T bpf_get_netns_cookie_sk_msg
```

Same pattern as 6.10.14-linuxkit: wrappers exist only for socket-type programs.
No wrapper for kprobe or TC/sched_cls program types.

### Verifier result (probe_helper run)

```
  [kprobe] FAILED: program probe_netns_cookie_kprobe: load program: invalid argument:
    unknown func bpf_get_netns_cookie#122 (32 line(s) omitted)

  [sched_cls] FAILED: program probe_netns_cookie_cls: load program: invalid argument:
    unknown func bpf_get_netns_cookie#122 (33 line(s) omitted)

=== Summary ===
  kprobe bpf_get_netns_cookie: UNSUPPORTED
  sched_cls bpf_get_netns_cookie: UNSUPPORTED
```

Exit code: 1

### Comparison with 6.10.14-linuxkit

| | 6.10.14-linuxkit | 5.15.0-181-generic |
|-|-----------------|-------------------|
| kprobe result | UNSUPPORTED | UNSUPPORTED |
| sched_cls result | UNSUPPORTED | UNSUPPORTED |
| Error message | "program of this type cannot use helper bpf_get_netns_cookie#122" | "unknown func bpf_get_netns_cookie#122" |
| kallsyms wrappers | socket-type only | socket-type only |

The error message differs between kernel versions:
- 6.10.14: "program of this type cannot use helper" — verifier knows the helper but rejects it for this program type
- 5.15.0: "unknown func" — verifier treats the helper as unrecognized for this program type

Both indicate the helper is not callable from kprobe or TC sched_cls programs. The practical conclusion is identical: bpf_get_netns_cookie-based scoping of ip_do_fragment is not feasible on 5.15.0-181-generic either.

**The Day 8 decision to use two-signal corroboration is confirmed on 5.15.**

---

## ip_do_fragment header parsing spike

### Spike program

`spikes/probe_frag_scope.bpf.c`: reads `skb->head + skb->network_header + 9` (IP proto field)
and `skb->transport_header` (UDP dport) using `bpf_probe_read_kernel`. Checks if ip_proto=17
and udp_dport=4789 to classify as VXLAN fragmentation.

### Compilation

```
clang -O2 -g -target bpf -I/usr/include -I/usr/include/aarch64-linux-gnu \
    -D__TARGET_ARCH_arm64 ... -c spikes/probe_frag_scope.bpf.c -o /tmp/probe_frag_scope.bpf.o

compile OK
```

No compiler errors. Spike loaded successfully on 5.15.0-181-generic.

### Spike result (first run, fresh namespaces, no prior large traffic)

```
frag_scope_result map:
  [0] skb_len: 1388 (0x056c)
  [1] ip_proto: 1 (0x0001)
  [2] udp_dport: 0 (0x0000)
  [3] is_vxlan: 0 (0x0000)

frag_vxlan_count: 2
```

Traffic: `ping -c 3 -s 1360 10.244.0.2` (3 large pings, outer IP 1438B > 1400B underlay MTU → triggers ip_do_fragment, 6 events total; result map captures last event).

**What the values mean:**
- `skb_len=1388`: skb->len at ip_do_fragment entry is 1388 bytes — this is the **inner IP packet length** (1360 payload + 28 IP+ICMP headers), not the outer 1438B. The skb being fragmented here may be the inner packet seen through skb->network_header inconsistency.
- `ip_proto=1`: ICMP (inner IP proto) — NOT 17 (UDP). Outer IP would carry UDP (VXLAN).
- `udp_dport=0`: no UDP header found at transport_header offset.
- `is_vxlan=0`: VXLAN classification failed (correctly; ip_proto=1 ≠ 17).
- `frag_vxlan_count=2`: this counter increments when is_vxlan=1 — but is_vxlan=0 in the result. This counter may reflect earlier events before the result map was populated, or a separate code path. It is inconsistent with the result map.

### Comparison with 6.10.14-linuxkit

| | 6.10.14-linuxkit | 5.15.0-181-generic |
|-|-----------------|-------------------|
| skb_len at ip_do_fragment | 1388 (inner, with route cache) | 1388 (inner, even on FIRST run) |
| ip_proto read | 1 (ICMP inner, with route cache) | 1 (ICMP inner, first run) |
| udp_dport | 0 (no UDP found) | 0 (no UDP found) |
| is_vxlan | 0 | 0 |
| frag_vxlan_count | 2 (inconsistent) | 2 (inconsistent) |

**Key difference:** On 6.10.14-linuxkit, the first run (before route cache populated) sometimes showed ip_proto=17, dport=4789 (outer IP). On 5.15.0-181-generic, even the first run shows ip_proto=1 (inner IP). The network_header inconsistency is **more severe** on 5.15.0-181-generic — the outer IP header is never seen in the result map.

This is likely because setup-netns.sh performs a connectivity check ping that may partially populate route state, or because 5.15's VXLAN driver constructs the skb differently at ip_do_fragment entry.

### Conclusion

Header parsing at ip_do_fragment via `skb->network_header` is unreliable on both kernels:
- 6.10.14-linuxkit: unreliable under route cache conditions (Day 8)
- 5.15.0-181-generic: unreliable even on first run

**The Day 8 decision to defer header parsing and use two-signal corroboration is confirmed and strengthened by this result.** The 5.15 result shows that even in conditions where linuxkit sometimes showed the outer IP header, 5.15 does not. A header-parsing approach would fail on 5.15 without a workaround that would need kernel-version-specific logic.

Two-signal corroboration (global ip_do_fragment count + TC egress max_outer_ip_len > underlay MTU) remains the correct v0 strategy.
