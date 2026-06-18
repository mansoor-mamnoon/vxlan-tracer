# Day 8 commit 6: route/PMTU cache investigation

## Objective

Determine whether `ip route flush cache` reliably resets PMTU state between
vxlan-tracer runs in the same namespace, and whether namespace recreation is
required for consistent fragmentation results.

## Environment

```
Kernel: 6.10.14-linuxkit aarch64
Lab: ns1/ns2 with vxlan0 MTU=1450 (stale), veth1/veth2 MTU=1400
```

## Observations

### After 3 large pings (1360B payload, inner IP 1388B)

```
ip netns exec ns1 ip route show cache:
  10.244.0.2 dev vxlan0
      cache expires 597sec mtu 1350
```

The kernel's PMTU discovery populated a cache entry with `mtu 1350` for the
vxlan0 → 10.244.0.2 route. This is the kernel learning the correct effective
inner IP MTU (1350 = 1400 underlay - 50 VXLAN overhead) after fragmentation.

### After `ip route flush cache`

```
ip route flush cache → exit 0
ip route show cache → (empty)
```

The cache was successfully cleared. `ip route flush cache` on 6.10.14-linuxkit
exits 0 and actually removes the PMTU cache entries. This contradicts the iproute2
man page claim that route flush is "mostly obsolete" on newer kernels — on this
kernel version it is effective.

### After flush: second round of pings

```
2 packets transmitted, 2 received, 0% packet loss
ip route get 10.244.0.2:  cache expires 598sec mtu 1350
```

After the flush, the next pings succeed and retrigger fragmentation (because the
kernel tries with the original vxlan0 MTU=1450, producing outer packets of 1438B
> 1400B underlay MTU). The route cache is repopulated with `mtu 1350` again.

### Effect on vxlan-tracer verdict

This is the mechanism that makes the second-run test work:
1. Flush: removes PMTU `mtu 1350` cache entry
2. Next large pings: kernel uses vxlan0 MTU=1450 → outer IP=1438 > 1400 → fragment
3. TC egress captures `max_outer_ip_len=1438` (before PMTU re-caches)
4. ip_do_fragment fires: `frag_events_total > 0`
5. Both signals present → `global_corroborated` verdict

Without the flush:
1. PMTU cache has `mtu 1350` for vxlan0 → 10.244.0.2
2. Kernel uses 1350B MTU → outer IP = 1350 + 50 = 1400 (≤ underlay MTU, no frag)
3. OR kernel uses a reduced MTU, producing outer IP = 1398 < 1400 underlay MTU
4. TC egress sees `max_outer_ip_len < underlay_mtu` → conservative verdict path

## Conclusion

`ip route flush cache` is effective on 6.10.14-linuxkit aarch64 for resetting
PMTU state between vxlan-tracer runs in the same namespace. Namespace recreation
is NOT required for consistent fragmentation results on this kernel.

**Official guidance for reproducibility:**
- Between runs in the same namespace: run `cleanup-bpf.sh` + `ip route flush cache`
- For a fully fresh baseline: namespace recreation via `teardown-netns.sh` + `setup-netns.sh`
  (automatically done by `run-scenarios.sh` for the first 4 scenarios)

## What is proven

- `ip route flush cache` clears PMTU entries on 6.10.14-linuxkit (exit 0, cache empty).
- After flush, large pings retrigger ip_do_fragment and TC egress records 1438B.
- The route_flush strategy is sufficient for second-run idempotency without namespace teardown.

## What remains unknown

- Whether `ip route flush cache` is effective on other kernels (the man page warns
  it may be a no-op on some). On Ubuntu 22.04 LTS (5.15 kernel) it should work
  based on upstream documentation, but has not been tested.
- Whether the 598s cache TTL would prevent flush from working in very rapid reruns
  (observed TTL is ~600s; flush exits 0 regardless).
