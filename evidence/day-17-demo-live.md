# evidence/day-17-demo-live.md

Live demo run of vxlan-tracer from the packaged rc1 amd64 archive.

CI run: 27887911218 ("Live demo (packaged rc1 archive)"), 2026-06-21T00:03Z
Job: Demo — amd64 packaged archive
Runner: ubuntu-22.04, kernel 6.8.0-1059-azure, x86_64
Archive: vxlan-tracer-linux-amd64.tar.gz (SHA-256 238d476d...)
Source: downloaded from CI run 27863179327 (authoritative rc1 build)
Binary: vxlan-tracer v0.1.0-rc1 (commit 74cf2d7, built unknown)
BPF objects: from packaged bpf/ directory (no source-tree recompile)

---

## Demo run 1

Script: `$PKG/scripts/demo.sh` from extracted packaged archive
Binary: `$PKG/vxlan-tracer` (x86-64 ELF, not from repository)
BPF dir: `$PKG/bpf/` (packaged BPF objects)
Duration: 15s

Setup:
- Created demo-ns1 (NETNS): vxlan0 (VNI 42, port 4789), demo-veth1 (underlay MTU 1400)
- Created demo-ns2: demo-veth2 (MTU 1400)
- Overlay MTU left at default (~1450, stale)
- vxlan0 MTU: 1450, demo-veth1 MTU: 1400

Traffic: 5 pings -s 1360 from ns1 to 10.244.0.2 (inner IP ~1388B → outer IP 1438B > 1400B underlay)

JSON output:
```json
{"verdict":"VXLAN_FRAGMENTATION_OBSERVED","message":"5 ip_do_fragment invocation(s) were observed while vxlan-tracer was attached; concurrently, the TC egress hook recorded an outer packet length of 1438 bytes, 38 bytes over the underlay MTU (1400). Fragmentation was observed while oversized VXLAN traffic was present — these two signals together are consistent with VXLAN outer packets triggering ip_do_fragment. Note: ip_do_fragment is a global kernel function and may include non-VXLAN fragmentation events on a busy host. Fragmented VXLAN UDP is commonly dropped silently by cloud fabric; in a local lab fragments may reassemble — fragmentation observed here does not by itself confirm packet loss.","fragmentation_scope":"global_corroborated","overlay":"vxlan0","underlay":"demo-veth1","vxlan_port":4789,"vxlan_vni":42,"overlay_mtu":1450,"underlay_mtu":1400,"recommended_overlay_mtu":1350,"ptb_ingress_total":0,"icmp_rcv_total":0,"frag_events_total":5,"frag_max_skb_len":1438,"max_outer_ip_len":1438}
```

Assertions:
```
[PASS] verdict=VXLAN_FRAGMENTATION_OBSERVED
[PASS] fragmentation_scope=global_corroborated
[PASS] max_outer_ip_len=1438 > underlay_mtu=1400
[PASS] recommended_overlay_mtu=1350 == underlay_mtu(1400) - 50
```

Exit status: 0

---

## Cleanup after demo run 1

```
[PASS] no demo netns remaining      (demo-ns1, demo-ns2 deleted by trap)
[PASS] /sys/fs/bpf/vxlan-tracer-demo absent  (pin dir removed by trap)
[PASS] demo-veth1 absent            (veth deleted when ns was deleted)
[PASS] no lingering vxlan-tracer process
```

---

## Demo run 2 (idempotency)

Second run without manual cleanup between runs.

JSON output:
```json
{"verdict":"VXLAN_FRAGMENTATION_OBSERVED","fragmentation_scope":"global_corroborated","overlay":"vxlan0","underlay":"demo-veth1","vxlan_port":4789,"vxlan_vni":42,"overlay_mtu":1450,"underlay_mtu":1400,"recommended_overlay_mtu":1350,"ptb_ingress_total":0,"icmp_rcv_total":0,"frag_events_total":5,"frag_max_skb_len":1438,"max_outer_ip_len":1438}
```

Assertions:
```
[PASS] run 2: verdict=VXLAN_FRAGMENTATION_OBSERVED
[PASS] run 2: fragmentation_scope=global_corroborated
```

No EEXIST, stale map, stale qdisc, or namespace errors observed.
Exit status: 0

---

## Cleanup after demo run 2

```
[PASS] no demo netns remaining
[PASS] /sys/fs/bpf/vxlan-tracer-demo absent
[PASS] demo-veth1 absent
[PASS] no lingering vxlan-tracer process
```

---

## Summary

| Check | Run 1 | Run 2 |
|-------|-------|-------|
| verdict=VXLAN_FRAGMENTATION_OBSERVED | PASS | PASS |
| fragmentation_scope=global_corroborated | PASS | PASS |
| max_outer_ip_len (1438) > underlay_mtu (1400) | PASS | PASS |
| recommended_overlay_mtu = underlay_mtu − 50 (1350) | PASS | — |
| demo exit status | 0 | 0 |
| netns cleanup | PASS | PASS |
| pin dir cleanup | PASS | PASS |
| veth cleanup | PASS | PASS |
| process cleanup | PASS | PASS |

Demo runs are repeatable with no residual state between runs.
All assertions pass on the packaged rc1 amd64 archive.
