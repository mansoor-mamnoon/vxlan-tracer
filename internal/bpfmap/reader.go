// Package bpfmap parses bpftool JSON map dump output for vxlan-tracer BPF maps.
//
// bpftool map dump produces JSON arrays of {"key": ..., "value": ...} objects.
// Struct field names in the JSON match the BTF field names from bpf/maps.h.
// IP address fields are __u32 stored in network byte order; bpftool reports
// them as native-endian uint32 decimals on the host that ran bpftool.
package bpfmap

import (
	"encoding/json"
	"fmt"
	"net"
)

// PTBKey mirrors struct ptb_key from bpf/maps.h.
type PTBKey struct {
	PTBSrcIP uint32 `json:"ptb_src_ip"`
	PTBDstIP uint32 `json:"ptb_dst_ip"`
}

// SrcIP returns the source underlay address in dotted-decimal notation.
func (k PTBKey) SrcIP() net.IP {
	return leU32ToIP(k.PTBSrcIP)
}

// DstIP returns the destination underlay address in dotted-decimal notation.
func (k PTBKey) DstIP() net.IP {
	return leU32ToIP(k.PTBDstIP)
}

// PTBVal mirrors struct ptb_val from bpf/maps.h.
type PTBVal struct {
	FirstSeenNS uint64 `json:"first_seen_ns"`
	LastSeenNS  uint64 `json:"last_seen_ns"`
	PTBCount    uint32 `json:"ptb_count"`
	NextHopMTU  uint16 `json:"next_hop_mtu"`
	Pad         uint16 `json:"pad"`
}

// PTBEntry is one element from a bpftool dump of ptb_ingress_counts.
type PTBEntry struct {
	Key   PTBKey `json:"key"`
	Value PTBVal `json:"value"`
}

// ParsePTBCounts parses the JSON output of:
//
//	bpftool map dump id <ptb_ingress_counts id>
func ParsePTBCounts(data []byte) ([]PTBEntry, error) {
	var entries []PTBEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return nil, fmt.Errorf("parse ptb_ingress_counts: %w", err)
	}
	return entries, nil
}

// TotalEntry is one element from a bpftool dump of ptb_ingress_total (ARRAY map).
type TotalEntry struct {
	Key   uint32 `json:"key"`
	Value uint64 `json:"value"`
}

// ParsePTBTotal parses the JSON output of:
//
//	bpftool map dump id <ptb_ingress_total id>
//
// Returns the counter value at key 0.
func ParsePTBTotal(data []byte) (uint64, error) {
	var entries []TotalEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return 0, fmt.Errorf("parse ptb_ingress_total: %w", err)
	}
	for _, e := range entries {
		if e.Key == 0 {
			return e.Value, nil
		}
	}
	return 0, nil
}

// leU32ToIP converts a network-byte-order IPv4 address stored as a LE uint32
// (as reported by bpftool on a little-endian host) to net.IP.
//
// The __u32 fields in BPF structs hold addresses in network byte order.
// On a LE host, bpftool reads them as native uint32, so the bytes appear
// reversed relative to standard big-endian dotted-decimal notation.
// Unpacking byte-by-byte restores the correct address.
func leU32ToIP(v uint32) net.IP {
	return net.IP{byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24)}
}
