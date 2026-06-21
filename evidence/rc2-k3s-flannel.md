# k3s/Flannel Two-Node Validation — rc2 Evidence

**Date:** 2026-06-21
**Status:** NOT RUN
**Gate:** Required before any external outreach to Flannel/k3s users

---

## Why this is a release gate

vxlan-tracer has been validated only in a controlled single-host netns lab. A two-node
k3s/Flannel cluster exercises a qualitatively different scenario:

1. Real VXLAN traffic between actual pods on different nodes (not simulated)
2. Flannel's specific overlay: `flannel.1` at port 8472 (Flannel default, not 4789)
3. Real CNI-managed TC filters (Flannel may not use TC BPF, but node-local CNI plugins might)
4. Real kube-proxy or eBPF policy rules
5. Underlay inference via `vxlan-tracer interfaces` on a real Flannel interface

The TC coexistence suite (`scripts/test-tc-coexistence.sh`) validates coexistence with
simulated filters on dummy interfaces. A real CNI deployment may have additional TC state
not covered by the coexistence suite.

---

## Target environment

- Two-node k3s cluster (disposable VMs, non-production)
- Flannel CNI with VXLAN backend
- Port 8472 (Flannel default)
- Overlay interface: `flannel.1`
- Kernel: 5.15 or 6.8 (already in the matrix)

---

## Required test sequence

If the two-node environment is available, run these checks in order:

1. `vxlan-tracer interfaces` on each node → must detect `flannel.1`, show port 8472
2. `sudo bash scripts/preflight.sh` on each node → must pass
3. `vxlan-tracer --overlay flannel.1 --underlay <eth> --duration 30s` during cross-node pod traffic → note verdict
4. Check no Flannel TC filters were disturbed (if any exist): `tc filter show dev flannel.1` before vs. after
5. Intentionally reduce overlay MTU to create safe MTU mismatch: `ip link set flannel.1 mtu 1500` (if underlay MTU is 1450, this creates a real `VXLAN_MTU_MISCONFIGURATION`)
6. Run tracer → must report `VXLAN_MTU_MISCONFIGURATION`
7. Restore MTU: `ip link set flannel.1 mtu 1450`
8. Confirm cluster networking recovers (cross-node ping works again)
9. Confirm tracer cleanup: `tc filter show dev flannel.1 ingress` → no filter at prio 50000; `ls /sys/fs/bpf/vxlan-tracer` → empty or missing

---

## Actual result

**NOT RUN** — a disposable two-node k3s/Flannel environment was not available during
the rc2 preparation window (2026-06-20 — 2026-06-21).

This is a **release gate for external Flannel/k3s outreach**. The following leads in
`outreach/rc2-priority-contacts.md` must NOT be contacted until this gate passes:

- Any contact with a Flannel or k3s VXLAN environment

Contacts with Cilium or Calico environments may be contacted after the TC coexistence
tests pass and the Cilium-specific note about TC priority coexistence is included in the
outreach message.

---

## Alternative: document the gap

If two-node validation is not run before the pilot, the external readiness assessment
(`evidence/rc2-external-readiness.md`) must record this as a remaining gap and the
outreach messages must explicitly state:

> "vxlan-tracer has not yet been tested against a real k3s/Flannel environment — your
> run would be the first. This is why it matters: any result (including a load failure)
> is genuinely useful data."

This framing is honest and appropriate for a controlled pilot. It is not appropriate
for a broad announcement or Show HN post.
