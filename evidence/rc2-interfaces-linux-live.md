# `interfaces` Subcommand — Linux Live Test Results

**Date:** 2026-06-21
**Host:** Lima VM `vxlan-test` — Ubuntu 22.04.5 LTS, kernel 5.15.0-181-generic, aarch64
**Binary:** `vxlan-tracer dev` (built from source, 2026-06-21)

---

## Case 1: No VXLAN interfaces

```
$ ./vxlan-tracer interfaces
No VXLAN interfaces found on this host.

vxlan-tracer requires a VXLAN overlay interface.
Common names: flannel.1 (k3s/Flannel), vxlan.calico (Calico), cilium_vxlan (Cilium), vxlan0 (manual)

If your overlay is in a different network namespace, re-run via nsenter.
```

Exit code: 0. No panic, no noise.

---

## Case 2: VXLAN interface with inferred underlay (human)

Setup: `ip link add dummy-eth0 type dummy; ip link add vxlan0 type vxlan id 42 dstport 4789 dev dummy-eth0`

```
$ ./vxlan-tracer interfaces
VXLAN interfaces on this host:

  NAME              VNI     PORT    MTU     LIKELY UNDERLAY
  vxlan0            42      4789    1450    dummy-eth0

Underlay is inferred from the VXLAN device's configured VTEP link.
Verify it before running the privileged diagnostic.

Suggested invocation (verify interfaces first):
  sudo vxlan-tracer --overlay vxlan0 --underlay dummy-eth0
```

- Column header is `LIKELY UNDERLAY` (not `UNDERLAY`).
- Inference note present.
- Suggested invocation says "verify interfaces first".
- Kernel auto-set vxlan0 MTU to 1450 (1500 - 50 VXLAN overhead).

---

## Case 3: VXLAN interface with inferred underlay (JSON)

```
$ ./vxlan-tracer interfaces --json
[{"name":"vxlan0","vni":42,"port":4789,"mtu":1450,"underlay":"dummy-eth0","underlay_inferred":true}]
```

- `underlay_inferred: true` present.
- No IP addresses in output.

---

## Gate summary

| Test | Status | Notes |
|------|--------|-------|
| No VXLAN → clean message, exit 0 | PASS | No panic |
| VXLAN with VtepDevIndex → LIKELY UNDERLAY column | PASS | kernel 5.15 |
| Inference note printed | PASS | "Underlay is inferred from..." |
| Suggested invocation says "verify first" | PASS | Correct wording |
| `underlay_inferred: true` in JSON | PASS | Field present and correct |
| No IP addresses in any output | PASS | Privacy requirement met |
