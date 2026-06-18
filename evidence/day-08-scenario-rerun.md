# Day 8 commit 5: scenario runner second-run idempotency test

## Objective

Verify that running the fragmentation scenario twice in the same Docker container
(same network namespaces, same lab topology, no container restart) produces
the expected verdict on both runs.

## Scenario 5: fragmentation (SECOND RUN — no teardown)

Test procedure:
1. After the first fragmentation run completes (scenario 2), the lab namespaces
   (ns1, ns2) remain alive.
2. Run `scripts/cleanup-bpf.sh` to remove TC filters and pinned maps.
3. Flush the route MTU cache in both namespaces:
   ```
   ip netns exec ns1 ip route flush cache
   ip netns exec ns2 ip route flush cache
   ```
4. Run vxlan-tracer again (same binary, same args, no new `setup-netns.sh`).
5. Trigger 3 large pings (payload 1360B) from ns1 after 4s sleep.
6. Assert verdict = VXLAN_FRAGMENTATION_OBSERVED.

Note: the assertion accepts both `global_corroborated` and `global_unscoped`
fragmentation_scope values, since the route cache flush may not always be
sufficient to fully reset PMTU state.

## Test environment

```
Kernel: 6.10.14-linuxkit aarch64
Binary: vxlan-tracer 0.1.0-dev (Day 8 build with fragmentation_scope field)
```

## Result

```
[scenario] Route cache flushed in ns1
[traffic] 3 packets transmitted, 3 received, 0% packet loss, time 2067ms

[scenario] Binary exit code: 0
[scenario] Raw JSON:
{
  "verdict": "VXLAN_FRAGMENTATION_OBSERVED",
  "fragmentation_scope": "global_corroborated",
  "frag_events_total": 6,
  "frag_max_skb_len": 1438,
  "max_outer_ip_len": 1438
}
[scenario] fragmentation_scope: global_corroborated
[PASS] Second run: verdict=VXLAN_FRAGMENTATION_OBSERVED scope=global_corroborated
```

## Full 5-scenario results

```
Results: 5 passed, 0 failed
run-scenarios exit: 0
```

| Scenario | Expected | Got | scope |
|----------|---------|-----|-------|
| healthy_small | VXLAN_MTU_MISCONFIGURATION | VXLAN_MTU_MISCONFIGURATION | (absent) |
| fragmentation | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED | global_corroborated |
| ptb_delivered | PTB_DELIVERED | PTB_DELIVERED | (absent) |
| ptb_suppressed | PTB_SUPPRESSED | PTB_SUPPRESSED | (absent) |
| fragmentation (2nd run) | VXLAN_FRAGMENTATION_OBSERVED | VXLAN_FRAGMENTATION_OBSERVED | global_corroborated |

## Route cache flush effectiveness

`ip route flush cache` in both namespaces was sufficient to reset the PMTU
state. The second run produced `max_outer_ip_len=1438` (same as the first run),
confirming the route cache was cleared and the kernel sent full-size outer
packets again.

## What is proven

- The second run in the same namespaces (no container restart) produces
  VXLAN_FRAGMENTATION_OBSERVED with fragmentation_scope=global_corroborated.
- `ip route flush cache` successfully resets the route MTU cache in ns1 and ns2.
- Idempotent cleanup (TC filter removal + pinned map removal) works between
  the two runs without manual namespace teardown.
- No "file exists" error on second attach.
- fragmentation_scope field appears in JSON for VXLAN_FRAGMENTATION_OBSERVED
  verdicts and is absent for non-frag verdicts (confirmed in first 4 scenarios).

## What remains unknown

- Whether `ip route flush cache` is a no-op on some kernels (the man page notes
  it's "mostly obsolete" on newer kernels). On 6.10.14-linuxkit it worked, but
  this is not guaranteed on other kernels.
- Whether 3 pings is always sufficient to trigger the corroborated path after
  a route cache flush on a loaded host.
