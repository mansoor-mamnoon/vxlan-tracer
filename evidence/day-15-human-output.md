# evidence/day-15-human-output.md

Record of structured human-readable output validation for v0.1.0-rc1.

---

## What `printHuman` produces

Added in commit `692151b` (Day 14). Replaces bare `fmt.Printf("verdict: %s\n")`.

For `VXLAN_FRAGMENTATION_OBSERVED` (global_corroborated scope):
```
Verdict:  VXLAN_FRAGMENTATION_OBSERVED
Evidence:
  ip_do_fragment events:   6
  largest outer IP seen:   1438 B
  underlay MTU:            1400 B  (outer packet exceeded by 38 B)
Recommendation:
  set overlay MTU to 1350 B or lower
  (VXLAN overhead is 50 B; safe overlay MTU = underlay MTU − 50)
Scope:
  global fragmentation counter corroborated by VXLAN TC egress
  (both ip_do_fragment and oversized outer packets observed)
  See docs/fragmentation-scoping.md for limitations.
```

For `PTB_SUPPRESSED`:
```
Verdict:  PTB_SUPPRESSED
Evidence:
  PTBs at TC ingress (pre-netfilter): 5
  PTBs at icmp_rcv  (post-netfilter): 0  ← dropped before kernel
Recommendation:
  PTBs are being dropped between the NIC and icmp_rcv.
  Check:  iptables/nftables INPUT chain for ICMP type 3 code 4 DROP rules.
  Fix:    allow ICMP fragmentation-needed (type 3 code 4) through your firewall.
```

For `NO_ISSUE_OBSERVED`:
```
Verdict:  NO_ISSUE_OBSERVED
Evidence:
  No PTBs, fragmentation events, or oversized traffic observed.
Note:
  This does not prove the path is healthy.
  Run with larger traffic and a longer --duration for higher confidence.
```

For `VXLAN_MTU_MISCONFIGURATION`:
```
Verdict:  VXLAN_MTU_MISCONFIGURATION
Evidence:
  overlay MTU:   1500 B (current)
  underlay MTU:  1400 B
  excess:        150 B (overlay exceeds safe value by this much)
Note:
  No active fragmentation or PTBs observed — this is a static risk.
  Traffic large enough to use the full overlay MTU will trigger fragmentation
  or a PTB, depending on the DF bit.
Recommendation:
  set overlay MTU to 1350 B or lower
```

For `PTB_DELIVERED`:
```
Verdict:  PTB_DELIVERED
Evidence:
  PTBs at TC ingress (pre-netfilter): 5
  PTBs at icmp_rcv  (post-netfilter): 5  ← kernel received them
Interpretation:
  PTBs are not being suppressed. The kernel can act on them for PMTUD.
  If large requests still fail, check that the application respects PTBs
  and that the overlay MTU is correctly configured.
```

---

## CI validation via x86-smoke.yml

The restructured `human-output` CI job (added commit `10b40f6`) runs two scenarios
and asserts `Verdict:` and `Evidence:` sections are present in stdout, then uploads
`human-frag.log` and `human-ptb.log` as artifacts.

**Status at time of writing:** CI in progress (commit `10b40f6` push 2026-06-19).
Artifact `human-output-logs-x86_64` will contain the actual captured output.

---

## Static analysis (what can be verified without Linux)

`go vet ./...` passes on macOS (verified in Day 14 and Day 15 session).
All 5 verdict cases in `printHuman` are covered by a `switch` statement with a
`default` for `NO_ISSUE_OBSERVED`. Verified by code review.

Assertion: `printHuman` contains no misleading recommendation for PTB paths.
- `PTB_DELIVERED`: shows "Interpretation:" section (no overlay MTU recommendation,
  since the PTB delivery itself is not the problem)
- `PTB_SUPPRESSED`: shows firewall fix recommendation (not overlay MTU recommendation)
- Only fragmentation/MTU verdicts show "set overlay MTU to N B" recommendation

---

## What is proven

- `printHuman` compiles correctly and passes `go vet` (verified macOS)
- All 5 verdict cases covered in code (code review)
- No misleading MTU recommendation for PTB delivery/suppression paths (code review)
- JSON output path unchanged and verified by prior CI (Days 7-13)

## What remains unproven

- Live captured output from actual binary runs (CI in progress)
- `VXLAN_MTU_RISK` path output not captured live (requires overlay MTU > underlay MTU
  with no fragmentation events — unusual test setup)
- `global_unscoped` scope output not captured live
