//go:build linux

// Package loader attaches the vxlan-tracer BPF programs (TC ingress on the
// underlay, TC egress on the VXLAN overlay, kprobe on icmp_rcv) and pins
// their maps under a bpffs directory.
//
// This package only builds on Linux: BPF program attachment requires Linux
// kernel facilities (netlink TC, kprobes, bpffs) that do not exist on other
// platforms. See loader_other.go for the non-Linux stub.
package loader

import (
	"fmt"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

// Config describes which interfaces and compiled BPF objects to attach.
type Config struct {
	Overlay      string // VXLAN overlay interface, e.g. vxlan0
	Underlay     string // Underlay physical interface, e.g. eth0
	PinDir       string // bpffs directory for pinned maps, e.g. /sys/fs/bpf/vxlan-tracer
	TCIngressObj string // compiled tc_ingress_eth0.bpf.o path
	TCEgressObj  string // compiled tc_egress_vxlan0.bpf.o path
	KprobeObj    string // compiled kprobes.bpf.o path
}

// Attachment holds everything attached by Attach, for cleanup via Close.
type Attachment struct {
	ingressColl *ebpf.Collection
	egressColl  *ebpf.Collection
	kprobeColl  *ebpf.Collection
	kprobeLink  link.Link
	underlay    netlink.Link
	overlay     netlink.Link
}

// pinnedMaps lists, per BPF object, which map names should be pinned under
// Config.PinDir. Maps not listed here are still created but not pinned.
var pinnedMaps = map[string][]string{
	"ingress": {"ptb_ingress_counts", "ptb_ingress_total"},
	"egress":  {"flow_state"},
	"kprobe":  {"icmp_rcv_total"},
}

// Attach loads the three compiled BPF objects, attaches them to the
// configured interfaces / kernel function, and pins their maps under
// cfg.PinDir. The TC clsact qdisc is created on each interface if missing.
//
// On failure, everything already attached in this call is torn down before
// returning the error (no half-attached state is left behind by a failed
// Attach call). Programs are pass-through (TC_ACT_OK) and the kprobe never
// affects packet delivery, so a failed attach has no traffic-path impact.
func Attach(cfg Config) (*Attachment, error) {
	underlay, err := netlink.LinkByName(cfg.Underlay)
	if err != nil {
		return nil, fmt.Errorf("lookup underlay %q: %w", cfg.Underlay, err)
	}
	overlay, err := netlink.LinkByName(cfg.Overlay)
	if err != nil {
		return nil, fmt.Errorf("lookup overlay %q: %w", cfg.Overlay, err)
	}

	if err := ensureClsact(underlay); err != nil {
		return nil, fmt.Errorf("ensure clsact qdisc on underlay %q: %w", cfg.Underlay, err)
	}
	if err := ensureClsact(overlay); err != nil {
		return nil, fmt.Errorf("ensure clsact qdisc on overlay %q: %w", cfg.Overlay, err)
	}

	a := &Attachment{underlay: underlay, overlay: overlay}

	ingressColl, ingressProg, err := loadPinned(cfg.TCIngressObj, "tc_ingress_count_ptb", cfg.PinDir, pinnedMaps["ingress"])
	if err != nil {
		return nil, fmt.Errorf("load tc ingress object %s: %w", cfg.TCIngressObj, err)
	}
	a.ingressColl = ingressColl
	if err := attachTC(underlay, netlink.HANDLE_MIN_INGRESS, ingressProg, "tc_ingress_eth0"); err != nil {
		a.Close()
		return nil, fmt.Errorf("attach tc ingress on %q: %w", cfg.Underlay, err)
	}

	egressColl, egressProg, err := loadPinned(cfg.TCEgressObj, "tc_egress_track_flow", cfg.PinDir, pinnedMaps["egress"])
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("load tc egress object %s: %w", cfg.TCEgressObj, err)
	}
	a.egressColl = egressColl
	if err := attachTC(overlay, netlink.HANDLE_MIN_EGRESS, egressProg, "tc_egress_vxlan0"); err != nil {
		a.Close()
		return nil, fmt.Errorf("attach tc egress on %q: %w", cfg.Overlay, err)
	}

	kprobeColl, kprobeProg, err := loadPinned(cfg.KprobeObj, "kprobe_icmp_rcv", cfg.PinDir, pinnedMaps["kprobe"])
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("load kprobe object %s: %w", cfg.KprobeObj, err)
	}
	a.kprobeColl = kprobeColl
	kp, err := link.Kprobe("icmp_rcv", kprobeProg, nil)
	if err != nil {
		a.Close()
		return nil, fmt.Errorf("attach kprobe icmp_rcv: %w", err)
	}
	a.kprobeLink = kp

	return a, nil
}

// ensureClsact creates a clsact qdisc on l if one does not already exist.
// clsact is required before TC BPF filters can be attached at ingress or
// egress.
func ensureClsact(l netlink.Link) error {
	qdiscs, err := netlink.QdiscList(l)
	if err != nil {
		return fmt.Errorf("list qdiscs: %w", err)
	}
	for _, q := range qdiscs {
		if q.Type() == "clsact" {
			return nil
		}
	}
	return netlink.QdiscAdd(&netlink.GenericQdisc{
		QdiscAttrs: netlink.QdiscAttrs{
			LinkIndex: l.Attrs().Index,
			Handle:    netlink.MakeHandle(0xffff, 0),
			Parent:    netlink.HANDLE_CLSACT,
		},
		QdiscType: "clsact",
	})
}

// loadPinned loads the BPF object at objPath, marks pinNames for pinning
// under pinDir, creates the collection (which performs the pinning), and
// returns the collection along with the named program.
func loadPinned(objPath, progName, pinDir string, pinNames []string) (*ebpf.Collection, *ebpf.Program, error) {
	spec, err := ebpf.LoadCollectionSpec(objPath)
	if err != nil {
		return nil, nil, fmt.Errorf("load spec: %w", err)
	}
	for _, name := range pinNames {
		if m, ok := spec.Maps[name]; ok {
			m.Pinning = ebpf.PinByName
		}
	}
	coll, err := ebpf.NewCollectionWithOptions(spec, ebpf.CollectionOptions{
		Maps: ebpf.MapOptions{PinPath: pinDir},
	})
	if err != nil {
		return nil, nil, fmt.Errorf("new collection: %w", err)
	}
	prog, ok := coll.Programs[progName]
	if !ok {
		coll.Close()
		return nil, nil, fmt.Errorf("program %q not found in object", progName)
	}
	return coll, prog, nil
}

// attachTC attaches prog as a direct-action TC BPF filter at the given
// clsact parent (HANDLE_MIN_INGRESS or HANDLE_MIN_EGRESS) on l.
func attachTC(l netlink.Link, parent uint32, prog *ebpf.Program, name string) error {
	filter := &netlink.BpfFilter{
		FilterAttrs: netlink.FilterAttrs{
			LinkIndex: l.Attrs().Index,
			Parent:    parent,
			Handle:    netlink.MakeHandle(0, 1),
			Protocol:  unix.ETH_P_ALL,
			Priority:  1,
		},
		Fd:           prog.FD(),
		Name:         name,
		DirectAction: true,
	}
	return netlink.FilterAdd(filter)
}

// MTUs returns the current overlay and underlay interface MTUs, re-read at
// call time (not cached from Attach), so callers see any change made after
// attachment (e.g. a stale overlay MTU left over from before the underlay
// MTU was reduced — the scenario this tool exists to diagnose).
func (a *Attachment) MTUs() (overlayMTU, underlayMTU int, err error) {
	u, err := netlink.LinkByIndex(a.underlay.Attrs().Index)
	if err != nil {
		return 0, 0, fmt.Errorf("re-read underlay MTU: %w", err)
	}
	o, err := netlink.LinkByIndex(a.overlay.Attrs().Index)
	if err != nil {
		return 0, 0, fmt.Errorf("re-read overlay MTU: %w", err)
	}
	return o.Attrs().MTU, u.Attrs().MTU, nil
}

// Close detaches the kprobe (which has no persistence outside this
// process) and closes all collection file descriptors. TC filters survive
// Close, matching the existing shell-attach behavior documented in
// docs/map-lifecycle.md: TC filters persist on the qdisc once attached;
// only the kprobe link needs an explicit owner to stay alive. Pinned maps
// are not removed — they are meant to outlive the loader process.
func (a *Attachment) Close() error {
	var firstErr error
	if a.kprobeLink != nil {
		if err := a.kprobeLink.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if a.kprobeColl != nil {
		a.kprobeColl.Close()
	}
	if a.egressColl != nil {
		a.egressColl.Close()
	}
	if a.ingressColl != nil {
		a.ingressColl.Close()
	}
	return firstErr
}
