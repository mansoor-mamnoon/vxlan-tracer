# Day 11 — vxlan-tracer baseline on port-configurable BPF

**Date:** 2026-06-18
**Goal:** Confirm the existing 5-scenario test suite still passes after the
         vxlan_config BPF map addition (port configurability changes).

---

## What was verified locally (macOS, non-Linux)

The macOS development environment cannot execute BPF programs.
Local verification confirms:

```
$ go build ./...
(no output — clean build)

$ go vet ./...
(no output — no issues)

$ go test ./...
?   github.com/mansoormmamnoon/vxlan-tracer/cmd/vxlan-tracer     [no test files]
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap      (cached)
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/diag        (cached)
?   github.com/mansoormmamnoon/vxlan-tracer/internal/loader      [no test files]
?   github.com/mansoormmamnoon/vxlan-tracer/internal/netlink     [no test files]
?   github.com/mansoormmamnoon/vxlan-tracer/internal/output      [no test files]
?   github.com/mansoormmamnoon/vxlan-tracer/spikes/probe_frag_scope [no test files]
?   github.com/mansoormmamnoon/vxlan-tracer/spikes/probe_helper  [no test files]
```

All existing unit tests (MTU arithmetic, verdict logic) continue to pass.

---

## BPF change analysis — regression risk assessment

The Day 11 BPF change to `tc_ingress_eth0.bpf.c`:

```
Before:
  #define VXLAN_UDP_PORT_NBO  bpf_htons(4789)
  ...
  if (orig_udph->dest != VXLAN_UDP_PORT_NBO) return TC_ACT_OK;

After:
  struct { ... } vxlan_config SEC(".maps");
  ...
  __u32 cfg_k = 0;
  struct vxlan_cfg *cfg = bpf_map_lookup_elem(&vxlan_config, &cfg_k);
  __be16 vxlan_port = (cfg && cfg->vxlan_dport) ? cfg->vxlan_dport
                                                 : bpf_htons(4789);
  if (orig_udph->dest != vxlan_port) return TC_ACT_OK;
```

**Default behavior unchanged:** When the Go loader writes portNBO=0xB512
(bpf_htons(4789)) into the map, the comparison is identical to the
pre-change `#define`. When the map has a zero value (edge case: loader
fails silently), the fallback `bpf_htons(4789)` is used.

**New map:** `vxlan_config` is a BPF_MAP_TYPE_ARRAY with 1 entry.
ARRAY maps always zero-initialize, and key 0 always exists. The BPF
verifier must track the pointer returned by `bpf_map_lookup_elem` as
potentially null (it doesn't know the map type at verify time). The null
check `(cfg && cfg->vxlan_dport)` satisfies the verifier.

**Variables after goto:** `cfg_k`, `cfg`, `vxlan_port` are declared after
two `goto update_map` sites at lines 112 and 126. Both gotos jump forward
to `update_map:` at line 145. The declared variables are not used after
`update_map:`. This is valid C99 and follows the same pattern as the
existing `struct udphdr *orig_udph` declaration (which is also after a
`goto update_map` site and compiles without issues on all three tested
kernels).

**BPF verifier concern:** The ternary expression on a map-lookup result
requires the verifier to prove that the dereference of `cfg->vxlan_dport`
is safe. Since we check `cfg &&` first, the verifier has sufficient
information. This pattern (null-check before dereference of bpf_map_lookup_elem
result) is used extensively in BPF programs and is accepted by the verifier
on all kernel versions ≥ 5.10.

**Risk: LOW.** The existing pattern of `bpf_map_lookup_elem` + null check +
dereference is proven across 3 kernels. The new map is simpler than the
existing `ptb_ingress_counts` (ARRAY vs. HASH).

---

## CI regression test (pending — next push to origin)

The existing `.github/workflows/x86-smoke.yml` will run the full 5-scenario
suite on x86_64 6.8.0-1052-azure when the commits are pushed:

```
sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s \
    bash scripts/run-scenarios.sh
```

Expected result: 5/5 PASS (same as Day 10 run 2).

The workflow compiles `tc_ingress_eth0.bpf.c` (which now includes the
`vxlan_config` map), loads it, and runs all 5 scenarios with the default
port (4789). The Go loader writes portNBO=0xB512 into the map. The
scenario suite exercises:

1. VXLAN_MTU_MISCONFIGURATION — no PTBs, no frag; map read irrelevant
2. VXLAN_FRAGMENTATION_OBSERVED — frag kprobe fires; map read: 0 PTB match
3. PTB_DELIVERED — PTBs injected with dport=4789; map must match → count > 0
4. PTB_SUPPRESSED — PTBs injected + iptables drop; map must match → TC count > 0, icmp_rcv == 0
5. Second FRAG run — same as scenario 2

Scenarios 3 and 4 are the critical tests for the port config change:
they inject PTBs with dport=4789 and expect the BPF program to count them.
If the map write fails or byte order is wrong, ptb_ingress_total stays 0
and the verdict would be VXLAN_MTU_MISCONFIGURATION or NO_ISSUE_OBSERVED
instead of PTB_DELIVERED/PTB_SUPPRESSED.

---

## Pending CNI baseline

A real CNI baseline (vxlan-tracer attached to flannel.1, cross-node pod
traffic observed) is not available for Day 11. See `evidence/day-11-k8s-env.md`
for the infrastructure assessment.

The CI run on push-to-origin serves as the regression baseline for the
port configurability change on the existing 5-scenario suite.
