# Day 7 — Repeatable, idempotent, VXLAN-scoped diagnostic prototype

**Date:** 2026-06-13 through 2026-06-16
**Environment:** Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64, --privileged
**Primary goal:** Turn the proven v0 into a repeatable, idempotent, VXLAN-scoped
diagnostic prototype. Second run in same container must not fail with "file exists"
or stale map counters. Fragmentation verdict must be VXLAN-relevant or explicitly
marked as global/unscoped with conservative wording.

---

## Summary of work done

### Commit 1 (936971c): idempotent cleanup script (scripts/cleanup-bpf.sh)

New script that removes TC filters and pinned maps without touching network
namespaces or kprobe links. Accepts NETNS/OVERLAY/UNDERLAY/PIN_DIR env vars.
Idempotent: runs cleanly whether or not the artefacts exist. Proven in Docker:
first run removes artefacts; second run (already clean) exits 0.

### Commit 2 (9b6932b): idempotent TC attach in loader

Changed `attachTC` in `internal/loader/loader.go` to call `netlink.FilterList`
and `netlink.FilterDel` for priority-1 filters before `netlink.FilterAdd`.
Eliminates "file exists" (EEXIST) on binary rerun without manual cleanup.
TC qdisc from prior run is reused; the brief delete+add window is microseconds.

### Commit 3 (ef8126a): ClearPinned — fresh baseline per run

Added `bpfmap.ClearPinned(pinDir)` in `internal/bpfmap/pinned.go`:
- Zeros ARRAY maps at key 0 (ptb_ingress_total, icmp_rcv_total, frag_events_total)
- Flushes HASH maps by collect-all-keys-then-delete (ptb_ingress_counts, flow_state)

Called at the start of each binary run, after Attach(). A `--no-clear` flag
skips clearing. Proven in Docker: Run A (frag=6) → Run C (no traffic, clear)
correctly returns frag=0, not stale 6.

Changed all `os.Exit(1)` for tool errors to `os.Exit(2)` to distinguish tool
failure from diagnostic outcomes (both exit 0).

### Commits 4–5 (7dc029b): frag_max_skb_len in JSON + two-signal verdict

Added `FragMaxSKBLen uint32` to `Observation` struct and `frag_max_skb_len`
JSON field (omitted when 0).

Updated `Diagnose()` to use two-signal fragmentation corroboration:
- **Corroborated path**: FragEventsTotal > 0 AND MaxOuterIPLen > UnderlayMTU →
  "these two signals together are consistent with VXLAN outer packets triggering
  ip_do_fragment"
- **Conservative path**: FragEventsTotal > 0 but MaxOuterIPLen ≤ UnderlayMTU →
  "ip_do_fragment is a global kernel function — the counter fires for ALL
  outgoing IP fragmentation on this host, not only VXLAN outer packets"

VXLAN ifindex scoping deferred: in fresh Linux namespaces, ns1/veth1 and
ns2/veth2 both get ifindex=2, making per-device scoping unreliable across
namespaces.

Unit tests: 12 pass (11 original + 1 new TestDiagnoseFragmentationObservedGlobalOnly).

### Commit 6 (d0fc6db): automated scenario runner (scripts/run-scenarios.sh)

Runs four diagnostic scenarios in a single Docker invocation:
1. healthy_small → VXLAN_MTU_MISCONFIGURATION (small pings; static MTU fault)
2. fragmentation → VXLAN_FRAGMENTATION_OBSERVED (large pings; ip_do_fragment + TC egress)
3. ptb_delivered → PTB_DELIVERED (synthetic PTBs, no iptables DROP)
4. ptb_suppressed → PTB_SUPPRESSED (synthetic PTBs, iptables DROP active)

Each scenario: cleanup → setup → run binary → trigger traffic → assert verdict.
Result: **4/4 PASS**, exit 0.

### Commit 7 (aa5c14f): exit-code contract documentation (docs/exit-codes.md)

Documents: 0 = verdict produced (any verdict), 2 = tool/runtime error.
Explains why exit 0 covers adverse verdicts; automation example for
parsing --json output; history of exit(1)→exit(2) change.

### Commit 8 (75e628b): README demo section

Added Demo section with actual PTB_SUPPRESSED and VXLAN_FRAGMENTATION_OBSERVED
JSON outputs from Docker runs. Added "What is proven" and "What is not proven"
lists. No fabricated outputs.

### Commit 9 (1654e66): reproducibility docs + make scenarios/cleanup-bpf

docs/reproducibility.md: Docker quickstart, required capabilities (CAP_BPF /
CAP_NET_ADMIN / CAP_NET_RAW), why macOS cannot run kernel tests, known
kernel-dependent behavior (route MTU cache, skb->len variance).

Makefile: `make scenarios` (Docker end-to-end runner); `make cleanup-bpf`
(idempotent artefact removal).

---

## What is proven (as of Day 7)

1. **Idempotent TC attach**: binary can be run twice in the same container
   without "file exists" error. Proven on kernel 6.10.14-linuxkit.

2. **Idempotent map clearing**: `ClearPinned` resets ARRAY counters and flushes
   HASH map entries. Stale counter false positives eliminated.

3. **All four active verdicts in one automated run**: `scripts/run-scenarios.sh`
   4/4 pass in Docker; each scenario performs its own idempotent cleanup.

4. **Two-signal fragmentation corroboration**: corroborated verdict requires
   both ip_do_fragment fires AND TC egress confirms oversized VXLAN packets.
   Conservative verdict fires (with global-scope disclaimer) when only
   ip_do_fragment fires without TC egress corroboration.

5. **frag_max_skb_len in JSON**: surfaced from BPF map; value is
   kernel-dependent (outer or inner IP length depending on route cache state).

6. **Exit code contract**: 0 = verdict produced; 2 = tool error. Documented.

7. **12 unit tests pass** on macOS (verdict logic, MTU arithmetic, suppression).

---

## What remains unproven

1. **ip_do_fragment VXLAN scoping**: the kprobe counter is global. On a busy
   host with non-VXLAN fragmentation, frag_events_total is inflated. Ifindex
   scoping deferred to Day 8 (needs BPF netns helpers or per-netns BPF config
   map).

2. **Route MTU cache effect on fragmentation verdict**: after repeated runs in
   the same namespaces WITHOUT full cleanup (namespace recreation), max_outer_ip_len
   may drop below underlay MTU, triggering the conservative verdict instead of
   corroborated. The scenario runner works around this by recreating namespaces
   (full cleanup). Bare-metal reruns without namespace recreation are unproven.

3. **x86_64 kernel**: all tests on aarch64 only (Docker linuxkit on Apple Silicon).

4. **Kernel version matrix**: only 6.10.14-linuxkit tested. ip_do_fragment and
   icmp_rcv kprobability, CO-RE relocations, and TC clsact behavior on 5.15 or
   6.1 LTS kernels not tested.

5. **Concurrent writes during ClearPinned**: race between ClearPinned and live
   BPF writes is theoretically possible. Benign for a diagnostic tool (counter
   may be slightly inaccurate for ~microseconds) but not formally proven safe.

---

## Is vxlan-tracer now a repeatable v0 prototype?

**Yes, with caveats.**

The primary Day 7 goal is met: the same Docker container can run all four
scenarios twice without manual cleanup and without stale counter false positives.
The scenario runner is the reference for "does a rerun work?"

The caveats: ip_do_fragment scoping is global (not VXLAN-specific), and the
route MTU cache effect can cause the fragmentation verdict to differ between
fresh and reused namespace runs. Both are documented and disclosed.

---

## Evidence files created/updated (Day 7)

- `evidence/day-07.md` (this file)
- `evidence/day-07-cleanup.md` — cleanup script test results (commit 1)
- `evidence/day-07-rerun-idempotency.md` — TC filter idempotency (commit 2)
- `evidence/day-07-map-clear.md` — ClearPinned test results (commit 3)
- `evidence/day-07-frag-scoping.md` — fragmentation scoping + two-signal verdict (commits 4–5)
- `evidence/day-07-scenarios.md` — automated scenario runner results (commit 6)
- `evidence/test-results.md` — appended Day 7 scenario results
- `docs/exit-codes.md` — exit-code contract (commit 7)
- `docs/reproducibility.md` — reproducibility guide (commit 9)
- `docs/roadmap.md` — V0 checklist updated
- `docs/forbidden-claims.md` — claims 13–15 added
- `README.md` — demo section + proven/unproven claims

---

## Next 10 commits for Day 8

Day 8 goal: scope ip_do_fragment to VXLAN traffic; harden the scenario runner;
begin kernel version matrix.

1. **BPF netns-aware scoping** — add a BPF config map (PIN_DIR/config) with the
   `network_namespace_id` (bpf_get_netns_cookie or skb->sk->sk_net). In the
   kprobe, filter events to the namespace of the underlay interface.

2. **Go: pass netns cookie to BPF config map** — populate the config map from Go
   using `netlink.LinkByName` + `nl.GenlFamilyList` or `/proc/self/ns/net` to
   get the netns inode; write it to the BPF map before the observation window.

3. **Update two-signal verdict for netns-scoped frag** — once scoping is added,
   update the verdict message to say "ip_do_fragment in the underlay network
   namespace" rather than "global kernel function."

4. **verdict_test.go: scoped frag test** — add a test with the scoped kprobe
   logic and a fake netns cookie match.

5. **Scenario runner: second-run idempotency sub-test** — add a fifth scenario
   that runs the `fragmentation` scenario twice in the same Docker container
   (same namespaces, no teardown between runs) and asserts both produce
   VXLAN_FRAGMENTATION_OBSERVED with corroborated verdict.

6. **Route MTU cache workaround** — add `ip route flush cache` call to
   `scripts/cleanup-bpf.sh` (or a dedicated step) to reset PMTU state between
   runs in the same namespace.

7. **Kernel version test: 6.1 LTS** — build a Docker test image on kernel 6.1
   (ubuntu:22.04 with linux-image-6.1* or a Debian bookworm image) and run the
   scenario runner. Document any difference in ip_do_fragment BTF relocation or
   TC clsact behavior.

8. **Unit test: ClearPinned concurrent safety** — add a race detector test
   (`go test -race`) that writes to a fake map concurrently with ClearPinned.

9. **docs/day-08-plan.md** — capture ifindex vs. netns scoping decision,
   route cache workaround approach, and kernel matrix plan.

10. **Day 8 synthesis** — `evidence/day-08.md`, updated `docs/roadmap.md` V0
    checklist, `evidence/test-results.md` entries for kernel version matrix runs.
