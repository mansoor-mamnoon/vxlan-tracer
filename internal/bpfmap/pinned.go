// Pinned-map reading for vxlan-tracer.
//
// Unlike reader.go (which parses bpftool's JSON map dump), this file reads
// the four pinned maps directly via cilium/ebpf, by path under the bpffs
// pin directory created by scripts/setup-bpf-fs.sh and populated by
// internal/loader.Attach. No bpftool or shell subprocess involved.
//
// Struct layouts below mirror bpf/maps.h field-for-field. cilium/ebpf
// marshals fixed-size Go structs by raw memory layout (the same bytes the
// kernel sees), so field order and sizes must match the C structs exactly;
// pinned_test.go asserts the sizes to catch drift.
package bpfmap

import (
	"fmt"
	"net"
	"path/filepath"

	"github.com/cilium/ebpf"
)

// PinnedPTBKey mirrors struct ptb_key from bpf/maps.h.
type PinnedPTBKey struct {
	PTBSrcIP uint32
	PTBDstIP uint32
}

// SrcIP returns the source underlay address in dotted-decimal notation.
func (k PinnedPTBKey) SrcIP() net.IP { return leU32ToIP(k.PTBSrcIP) }

// DstIP returns the destination underlay address in dotted-decimal notation.
func (k PinnedPTBKey) DstIP() net.IP { return leU32ToIP(k.PTBDstIP) }

// PinnedPTBVal mirrors struct ptb_val from bpf/maps.h.
type PinnedPTBVal struct {
	FirstSeenNS uint64
	LastSeenNS  uint64
	PTBCount    uint32
	NextHopMTU  uint16
	Pad         uint16
}

// PinnedPTBEntry is one element of ptb_ingress_counts.
type PinnedPTBEntry struct {
	Key   PinnedPTBKey
	Value PinnedPTBVal
}

// PinnedFlowKey mirrors struct flow_key from bpf/maps.h.
type PinnedFlowKey struct {
	SrcIP   uint32
	DstIP   uint32
	SrcPort uint16
	DstPort uint16
	Proto   uint8
	Pad     [3]uint8
}

// Src returns the inner flow source address in dotted-decimal notation.
func (k PinnedFlowKey) Src() net.IP { return leU32ToIP(k.SrcIP) }

// Dst returns the inner flow destination address in dotted-decimal notation.
func (k PinnedFlowKey) Dst() net.IP { return leU32ToIP(k.DstIP) }

// PinnedFlowVal mirrors struct flow_val from bpf/maps.h.
type PinnedFlowVal struct {
	LastSeenNS    uint64
	PktCount      uint32
	MaxInnerIPLen uint16
	MaxOuterIPLen uint16
}

// PinnedFlowEntry is one element of flow_state.
type PinnedFlowEntry struct {
	Key   PinnedFlowKey
	Value PinnedFlowVal
}

// PinnedReader holds open handles to the four pinned vxlan-tracer maps.
// It does not attach or create anything; the maps must already be pinned
// by a prior internal/loader.Attach call (see scripts/setup-bpf-fs.sh and
// docs/map-lifecycle.md).
type PinnedReader struct {
	ptbTotal     *ebpf.Map
	icmpRcvTotal *ebpf.Map
	ptbCounts    *ebpf.Map
	flowState    *ebpf.Map
}

// OpenPinned opens all four pinned vxlan-tracer maps under pinDir
// (e.g. /sys/fs/bpf/vxlan-tracer). If any map fails to open, the maps
// already opened in this call are closed before returning the error.
func OpenPinned(pinDir string) (*PinnedReader, error) {
	opened := make([]*ebpf.Map, 0, 4)
	closeOpened := func() {
		for _, m := range opened {
			m.Close()
		}
	}

	open := func(name string) (*ebpf.Map, error) {
		m, err := ebpf.LoadPinnedMap(filepath.Join(pinDir, name), nil)
		if err != nil {
			closeOpened()
			return nil, fmt.Errorf("open pinned map %s: %w", name, err)
		}
		opened = append(opened, m)
		return m, nil
	}

	ptbTotal, err := open("ptb_ingress_total")
	if err != nil {
		return nil, err
	}
	icmpRcvTotal, err := open("icmp_rcv_total")
	if err != nil {
		return nil, err
	}
	ptbCounts, err := open("ptb_ingress_counts")
	if err != nil {
		return nil, err
	}
	flowState, err := open("flow_state")
	if err != nil {
		return nil, err
	}

	return &PinnedReader{
		ptbTotal:     ptbTotal,
		icmpRcvTotal: icmpRcvTotal,
		ptbCounts:    ptbCounts,
		flowState:    flowState,
	}, nil
}

// PTBIngressTotal reads the single-entry ARRAY counter (key 0) from
// ptb_ingress_total: total PTBs observed at TC ingress, before netfilter.
func (r *PinnedReader) PTBIngressTotal() (uint64, error) {
	return readArrayCounter(r.ptbTotal, "ptb_ingress_total")
}

// ICMPRcvTotal reads the single-entry ARRAY counter (key 0) from
// icmp_rcv_total: total ICMP type=3/code=4 packets that reached icmp_rcv,
// i.e. survived netfilter. See bpf/kprobes.bpf.c.
func (r *PinnedReader) ICMPRcvTotal() (uint64, error) {
	return readArrayCounter(r.icmpRcvTotal, "icmp_rcv_total")
}

func readArrayCounter(m *ebpf.Map, name string) (uint64, error) {
	var val uint64
	if err := m.Lookup(uint32(0), &val); err != nil {
		return 0, fmt.Errorf("lookup %s key 0: %w", name, err)
	}
	return val, nil
}

// PTBIngressCounts iterates the per-VTEP-pair HASH map.
func (r *PinnedReader) PTBIngressCounts() ([]PinnedPTBEntry, error) {
	var entries []PinnedPTBEntry
	var key PinnedPTBKey
	var val PinnedPTBVal
	it := r.ptbCounts.Iterate()
	for it.Next(&key, &val) {
		entries = append(entries, PinnedPTBEntry{Key: key, Value: val})
	}
	if err := it.Err(); err != nil {
		return nil, fmt.Errorf("iterate ptb_ingress_counts: %w", err)
	}
	return entries, nil
}

// FlowState iterates the per-inner-flow HASH map.
func (r *PinnedReader) FlowState() ([]PinnedFlowEntry, error) {
	var entries []PinnedFlowEntry
	var key PinnedFlowKey
	var val PinnedFlowVal
	it := r.flowState.Iterate()
	for it.Next(&key, &val) {
		entries = append(entries, PinnedFlowEntry{Key: key, Value: val})
	}
	if err := it.Err(); err != nil {
		return nil, fmt.Errorf("iterate flow_state: %w", err)
	}
	return entries, nil
}

// Close closes all four map file descriptors. It does not unpin them —
// the pinned files under pinDir remain, owned by the bpffs, not by this
// reader.
func (r *PinnedReader) Close() {
	r.ptbTotal.Close()
	r.icmpRcvTotal.Close()
	r.ptbCounts.Close()
	r.flowState.Close()
}
