# TC Lifecycle Audit — vxlan-tracer

**Date:** 2026-06-20
**Scope:** `internal/loader/loader.go` (304 lines), `internal/bpfmap/pinned.go`
**Status:** Pre-rc2. These issues must be resolved before external release on shared or
production-like hosts.

---

## Summary table

| ID     | Severity         | Component           | Short description                                               |
|--------|------------------|---------------------|-----------------------------------------------------------------|
| TC-01  | RELEASE BLOCKER  | `attachTC()`        | Deletes any priority-1 TC filter without ownership check        |
| TC-02  | RELEASE BLOCKER  | `Close()`           | TC filters not removed on exit; survive indefinitely            |
| TC-03  | RELEASE BLOCKER  | `Attachment` struct | No per-invocation ownership identity; cleanup is unsafe         |
| TC-04  | MAJOR            | `ensureClsact()`    | Pre-existing clsact not recorded; cleanup cannot omit it        |
| TC-05  | MAJOR            | `Close()`           | Pinned maps survive exit; accumulate across runs                |
| TC-06  | MAJOR            | `Attach()`          | Partial failure: clsact qdisc created, never removed            |
| TC-07  | MAJOR            | `Attach()`          | No concurrent-invocation protection; two runs conflict at prio 1|
| TC-08  | MODERATE         | `attachTC()`        | Filter name hardcoded; doesn't reflect actual interface name     |
| TC-09  | MODERATE         | Signal handling     | SIGKILL cannot clean TC filters; they persist indefinitely      |
| TC-10  | MINOR            | `loadPinned()`      | Second run re-opens pinned maps from first run (stale data)     |

---

## Detailed findings

### TC-01 — RELEASE BLOCKER: `attachTC()` destroys third-party TC filters

**File:** `internal/loader/loader.go:231–254`

**Current code:**
```go
func attachTC(l netlink.Link, parent uint32, prog *ebpf.Program, name string) error {
    if existing, err := netlink.FilterList(l, parent); err == nil {
        for _, f := range existing {
            if f.Attrs().Priority == 1 {
                _ = netlink.FilterDel(f)   // ← no ownership check
            }
        }
    }
    ...
}
```

**What goes wrong:** Cilium attaches BPF programs at TC priority 1 on every host interface
(typically eth0 ingress and egress). Calico does the same. Running vxlan-tracer on a host
with either CNI destroys those filters permanently before attaching its own. The CNI
filters do not auto-recover — Cilium will not re-attach them until its agent is restarted.
This can disrupt pod-to-pod traffic immediately and silently.

**Example scenario:** User runs `vxlan-tracer --overlay vxlan0 --underlay eth0` on a
Cilium node. vxlan-tracer lists all priority-1 filters on eth0 ingress, finds Cilium's
`cil_from_netdev` filter, deletes it, then adds its own. Cilium's datapath is now broken.

**Instances:** `attachTC()` is called twice in `Attach()`:
- Line 90: `attachTC(underlay, HANDLE_MIN_INGRESS, ...)` — destroys CNI filters on
  underlay ingress
- Line 101: `attachTC(overlay, HANDLE_MIN_EGRESS, ...)` — destroys CNI filters on
  overlay egress (less common, but VXLAN overlays can also carry CNI BPF programs)

**Fix required:** Reserve a priority that does not conflict with CNI tools and verify
ownership (priority + handle major) before deleting any filter. Never delete filters
at priorities used by CNIs.

---

### TC-02 — RELEASE BLOCKER: TC filters not removed by `Close()`

**File:** `internal/loader/loader.go:272–303`

**Current code (Close comment):**
```go
// TC filters survive Close, matching the existing shell-attach behavior documented
// in docs/map-lifecycle.md: TC filters persist on the qdisc once attached; only
// the kprobe links need an explicit owner to stay alive.
```

**What goes wrong:** After a vxlan-tracer run ends (normal exit, Ctrl-C, or crash), the
TC BPF filters remain permanently attached to the interfaces. The filters process every
packet on the underlay and overlay interfaces until the interface is removed or the
system is rebooted. This is acceptable in a netns lab (the netns is torn down after each
run), but on a shared or production host it means:

1. An unowned BPF program processes all traffic on eth0 indefinitely.
2. If the pin directory is later cleaned up by an operator, the BPF programs still run
   (TC filters hold a reference to the BPF FD internally; the pinned file is not needed
   for the program to continue executing).
3. A second vxlan-tracer run will hit TC-01: it will delete the leftover filter and add
   a fresh one — but only because it doesn't recognize it as its own.

**Fix required:** `Close()` must remove TC filters it created. See TC-03 for ownership
tracking.

---

### TC-03 — RELEASE BLOCKER: No per-invocation ownership identity

**File:** `internal/loader/loader.go:34–43`

**Current `Attachment` struct:**
```go
type Attachment struct {
    ingressColl    *ebpf.Collection
    egressColl     *ebpf.Collection
    kprobeColl     *ebpf.Collection
    kprobeLink     link.Link
    fragKprobeColl *ebpf.Collection
    fragKprobeLink link.Link
    underlay       netlink.Link
    overlay        netlink.Link
    // Missing: filter tracking, clsact ownership, pin dir
}
```

**What goes wrong:** The `Attachment` struct does not record:
- Which TC filters were created by this invocation (parent, handle, priority)
- Whether the clsact qdisc on underlay was pre-existing or created by us
- Whether the clsact qdisc on overlay was pre-existing or created by us
- The bpffs pin directory path (needed for map cleanup)

Without this information, `Close()` cannot safely identify which resources to remove.

**Fix required:** Add fields to `Attachment` for owned filter records, per-interface
qdisc-creation flags, and pin dir path. In `attachTC()`, reserve a vxlan-tracer-specific
priority and handle major (e.g., priority 50000, handle major `0x7674` = "vt" in ASCII),
and record each created filter in `a.ownedFilters`. Verify ownership on delete:
`priority == vxlanTracerPriority && handleMajor(handle) == vxlanTracerHandleMajor`.

---

### TC-04 — MAJOR: `ensureClsact()` does not record whether qdisc was pre-existing

**File:** `internal/loader/loader.go:177–195`

**Current code:**
```go
func ensureClsact(l netlink.Link) error {
    qdiscs, err := netlink.QdiscList(l)
    ...
    for _, q := range qdiscs {
        if q.Type() == "clsact" {
            return nil   // found pre-existing; return without recording
        }
    }
    return netlink.QdiscAdd(...)   // created new; not recorded in Attachment
}
```

**What goes wrong:** If vxlan-tracer creates the clsact qdisc and later calls `Close()`,
it cannot know whether to remove the qdisc. Removing it when pre-existing would destroy
all other TC filters on that qdisc (a superset of TC-01). Not removing it when we created
it leaves an orphan qdisc that may prevent the operator from changing the qdisc type.

**Fix required:** `ensureClsact()` must return a boolean indicating whether it created the
qdisc. The caller stores this in `Attachment`. `Close()` removes the qdisc only if:
(a) we created it, AND (b) the qdisc has no remaining filters (our filters were the only
ones).

---

### TC-05 — MAJOR: Pinned maps survive `Close()`

**File:** `internal/loader/loader.go:272`; `internal/bpfmap/pinned.go`

**Current behavior:** `loadPinned()` sets `ebpf.PinByName` on selected maps and passes
`PinPath: pinDir` to `NewCollectionWithOptions`. The maps are pinned to files under
`cfg.PinDir` (default `/sys/fs/bpf/vxlan-tracer/`). `Close()` closes the collection
file descriptors but does NOT remove the pinned files.

**What goes wrong:**
1. Pinned files accumulate across runs. On a host with restricted bpffs quotas, this
   can exhaust available pin slots.
2. A second run calls `loadPinned()` with `PinByName`, which re-opens the existing
   pinned maps rather than creating fresh ones. Without an explicit `ClearPinned()` call
   in main, the second run reads counters from the first run. `ClearPinned()` IS called
   in main, but only after `Attach()` succeeds — if `Attach()` fails, stale pins remain.
3. An external operator cannot distinguish vxlan-tracer's pins from other tools' pins
   without reading the source.

**What survives normal exit:**
- `ptb_ingress_total` (underlay ingress PTB counter)
- `icmp_rcv_total` (post-netfilter ICMP counter)
- `ptb_ingress_counts` (per-VTEP-pair PTB hash map)
- `flow_state` (per-inner-flow hash map)
- `frag_events_total` (fragmentation counter)

All five files remain under `/sys/fs/bpf/vxlan-tracer/` after exit.

**Fix required:** `Close()` must unpin all maps (remove the pinned files) and then attempt
to remove the pin directory. Map files must be tracked by path in `Attachment`.

---

### TC-06 — MAJOR: Partial attach failure leaves clsact qdisc and no TC filter

**File:** `internal/loader/loader.go:62–133`

**Sequence:**
1. `ensureClsact(underlay)` creates clsact on eth0 ← not tracked
2. `ensureClsact(overlay)` creates clsact on vxlan0 ← not tracked
3. `loadPinned(TCIngressObj)` succeeds, pins maps
4. `attachTC(underlay, INGRESS, ...)` attaches ingress filter
5. `loadPinned(TCEgressObj)` fails → `a.Close()` called
6. `Close()` closes kprobe collections (nil-safe no-ops here) and ingress collection
7. clsact qdiscs remain on both interfaces; ingress TC filter remains; map files remain

The `Close()` called on partial failure is the same `Close()` called on normal exit.
Since neither removes TC filters nor qdiscs, a failed attach leaves the host dirtier
than before the run.

**Fix required:** `Close()` must be safe to call at any stage of partial attachment.
This is automatically satisfied once TC-02/TC-03/TC-04/TC-05 are fixed: a deterministic
`Close()` removes exactly the resources that were recorded as created.

---

### TC-07 — MAJOR: No concurrent-invocation protection

**File:** `internal/loader/loader.go:231–254`

**What goes wrong:** Two simultaneous vxlan-tracer invocations on the same host targeting
the same interfaces:

1. Run A: `attachTC(eth0, INGRESS)` → deletes priority-1 filter (if any), adds its own
2. Run B: `attachTC(eth0, INGRESS)` → deletes Run A's filter, adds its own
3. Run A: reads `ptb_ingress_total` — the TC filter counting it is now Run B's, which
   may be writing to different pinned map file descriptors
4. Run B: may be writing to the same pinned map paths as Run A if pin dirs are the same

Result: counters from both runs intermix; Run A gets incorrect verdict; Run B may fail
with EEXIST or silently corrupt Run A's map data.

**Fix required:** Use a lock file (e.g., `/run/vxlan-tracer.lock`) acquired with
`flock(2)` at startup, released on `Close()`. One vxlan-tracer invocation at a time.
Alternatively, reserve a unique priority per invocation (but lock file is simpler and
safer).

---

### TC-08 — MODERATE: Filter name does not reflect actual interface name

**File:** `internal/loader/loader.go:241`

**Current code:**
```go
filter := &netlink.BpfFilter{
    ...
    Name: name,   // "tc_ingress_eth0" or "tc_egress_vxlan0"
}
```

**What goes wrong:** The `name` argument is a hardcoded string ("tc_ingress_eth0") passed
from `Attach()`. If the user specifies `--underlay ens3` or `--underlay bond0`, the filter
name remains "tc_ingress_eth0". An operator inspecting `tc filter show dev ens3 ingress`
will see a filter named `tc_ingress_eth0` — confusing and misleading.

**Fix required:** Construct the filter name from the actual link name:
`fmt.Sprintf("vt_in_%s", l.Attrs().Name)` (truncated to the 16-char kernel limit for BPF
program names via TC).

---

### TC-09 — MODERATE: SIGKILL leaves TC filters permanently

**Scope:** Runtime signal handling

**What goes wrong:** vxlan-tracer has no SIGTERM handler in the current `main.go` (the
loop runs `select {}` waiting for signals; `defer a.Close()` is called). On SIGTERM,
`defer a.Close()` runs. On SIGKILL, no defer runs.

After the TC-02 fix lands, SIGTERM will clean TC filters because `Close()` removes them.
But SIGKILL cannot be caught — TC filters will survive until an operator manually removes
them with `tc filter del`.

**This is an irreducible limitation of TC BPF filters** — unlike kprobe links (which die
with the owning FD), TC filters are not owned by a process. They persist until explicitly
deleted via netlink. There is no safe workaround.

**Documentation required:** The README, release notes, and any external instructions must
state clearly that `kill -9` or a kernel panic leaves TC filters on the interfaces. Provide
the manual removal command:
```
tc filter del dev <underlay> ingress prio 50000
tc filter del dev <overlay>  egress  prio 50000
```

---

### TC-10 — MINOR: `loadPinned()` re-opens prior run's pinned maps

**File:** `internal/loader/loader.go:200–222`

**Current behavior:** If `/sys/fs/bpf/vxlan-tracer/ptb_ingress_total` already exists from
a prior run, `NewCollectionWithOptions(..., PinByName)` opens the existing file rather than
creating a fresh map. The BPF programs will write to the same map as the prior run.

**Mitigation:** `main.go` calls `bpfmap.ClearPinned(cfg.PinDir)` after a successful
`Attach()`. This zeroes the maps before the measurement window.

**Residual risk:** If `Attach()` succeeds but `ClearPinned()` fails (e.g., map type
mismatch between old and new BPF object), the measurement starts with stale counters.
The verdict could be wrong (e.g., `VXLAN_FRAGMENTATION_OBSERVED` from a prior run
bleeds into the current run).

**Fix required:** Once TC-05 is fixed (maps are unpinned on exit), this residual risk
disappears because there are no leftover pinned files for the next run to re-open.

---

## What survives normal exit (current behavior)

| Resource | Survives? | Where |
|----------|-----------|-------|
| TC ingress filter on underlay | YES | qdisc, indefinitely |
| TC egress filter on overlay | YES | qdisc, indefinitely |
| clsact qdisc on underlay | YES | if created by us |
| clsact qdisc on overlay | YES | if created by us |
| Pinned map: `ptb_ingress_total` | YES | `/sys/fs/bpf/vxlan-tracer/` |
| Pinned map: `icmp_rcv_total` | YES | `/sys/fs/bpf/vxlan-tracer/` |
| Pinned map: `ptb_ingress_counts` | YES | `/sys/fs/bpf/vxlan-tracer/` |
| Pinned map: `flow_state` | YES | `/sys/fs/bpf/vxlan-tracer/` |
| Pinned map: `frag_events_total` | YES | `/sys/fs/bpf/vxlan-tracer/` |
| kprobe on `icmp_rcv` | NO | dies with FD close in `Close()` |
| kprobe on `ip_do_fragment` | NO | dies with FD close in `Close()` |

---

## What survives SIGINT/SIGTERM (current behavior)

`main.go` catches SIGINT and SIGTERM, calls `a.Close()`, then exits. `a.Close()` removes
only the kprobe links. Result: same as normal exit — TC filters and maps survive.

After the rc2 fix: `a.Close()` will also remove TC filters and unpin maps. SIGINT/SIGTERM
will leave the host clean. SIGKILL remains irreducible (see TC-09).

---

## What survives a partial attach failure (current behavior)

If `Attach()` returns an error at any stage:

| Stage where failure occurs | What is left behind |
|----------------------------|---------------------|
| After `ensureClsact(underlay)` | clsact qdisc on underlay |
| After `ensureClsact(overlay)` | clsact qdiscs on both |
| After `loadPinned(ingress)` + `writeVXLANConfig` | qdiscs + pinned ingress maps |
| After `attachTC(underlay, INGRESS)` | qdiscs + ingress maps + ingress TC filter |
| After `loadPinned(egress)` | qdiscs + ingress maps + ingress filter + egress pins |
| After `attachTC(overlay, EGRESS)` | all of the above + egress filter |
| After `loadPinned(kprobe)` | all TC resources + kprobe maps |

In all partial-failure cases, `a.Close()` is called, which removes kprobes (if attached)
but leaves TC filters and maps. After the rc2 fix, `Close()` will clean everything
recorded in `ownedFilters`, unpinning maps and removing empty qdiscs.

---

## Concurrent invocation interaction (current behavior)

Two simultaneous `vxlan-tracer` runs on the same node, same `--underlay eth0`:

1. Run A lists priority-1 filters on eth0 ingress: empty (first run). Adds filter at prio 1.
2. Run B lists priority-1 filters on eth0 ingress: finds Run A's filter. **Deletes it.**
   Adds its own at prio 1.
3. Run A: the BPF program counting PTBs is now Run B's. Run A's pinned map
   `ptb_ingress_total` is no longer being incremented. Run A gets a false `NO_ISSUE_OBSERVED`.
4. Run A exits: deletes Run B's filter (Run B no longer counts PTBs). Run B gets
   `NO_ISSUE_OBSERVED` for the remainder of its window.

After the rc2 fix (lock file + unique priority+handle): only one run at a time is
permitted. The second run fails immediately with a clear error message.

---

## Conflict with Cilium

Cilium attaches `cil_from_netdev` and `cil_to_netdev` at priority 1 on host-facing
interfaces (typically eth0) and `cil_from_overlay` / `cil_to_overlay` on the VXLAN
overlay interface (cilium_vxlan or similar).

**With current vxlan-tracer:** running `vxlan-tracer --underlay eth0` will delete
`cil_from_netdev` on eth0 ingress (it is at priority 1). Cilium does not automatically
re-attach it; the node's dataplane is broken until `cilium-agent` is restarted.

**After rc2 fix:** vxlan-tracer attaches at priority 50000 with handle major `0x7674`.
Cilium's priority-1 filters are untouched. Both coexist. vxlan-tracer sees PTBs at
priority 50000 (after Cilium's filter passes them at priority 1 with TC_ACT_OK, which is
Cilium's normal behavior for ICMP PTBs that it does not suppress).

---

## Conflict with Calico

Calico (eBPF dataplane) attaches TC programs at priority 1 on workload interfaces and the
host interface. The conflict and fix are the same as for Cilium above.

Calico (iptables dataplane) does not use TC BPF filters. There is no conflict in this mode.

---

## Conflict with tc flower / operator-created filters

An operator may attach custom `tc flower` classifiers at priority 1 for traffic shaping
or monitoring. The current `attachTC()` would delete these without warning.

After the rc2 fix, vxlan-tracer never touches filters at any priority other than 50000.

---

## Required changes for rc2

### `internal/loader/loader.go`

1. Add constants: `vxlanTracerPriority = 50000`, `vxlanTracerHandleMajor = 0x7674`.
2. Add to `Attachment`: `ownedFilters []ownedTCFilter`, `underlayClsactCreated bool`,
   `overlayClsactCreated bool`, `pinDir string`.
3. Rewrite `ensureClsact()` to return `(created bool, err error)`.
4. Rewrite `attachTC()` to:
   a. List existing filters.
   b. Delete ONLY filters where priority == vxlanTracerPriority AND
      handleMajor(handle) == vxlanTracerHandleMajor.
   c. Add new filter at priority 50000, handle `0x7674_0001`.
   d. Return `(handle uint32, err error)` so the caller can record the filter.
5. Rewrite `Close()` to:
   a. Remove kprobe links (existing).
   b. Delete owned TC filters by stored (parent, handle, priority).
   c. If clsact was created by us AND no remaining filters exist: remove qdisc.
   d. Unpin owned maps (remove files under `a.pinDir`).
   e. Remove pin directory if empty.
6. Add lock file acquisition at start of `Attach()` (released in `Close()`).

### `scripts/test-tc-coexistence.sh` (Phase 4)

Validate cases A–F: standalone run, Cilium-coexistence (simulated), concurrent run, etc.

### Documentation

- `docs/gso-gro-limitations.md` (Phase 9): GSO super-packet at TC egress
- Update `docs/map-lifecycle.md` to reflect new cleanup behavior
- Release notes must include SIGKILL warning and manual cleanup command
