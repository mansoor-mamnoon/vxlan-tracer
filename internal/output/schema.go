// Package output defines the structured diagnosis output schema.
// Both human-readable and JSON output are derived from these types.
package output

// FindingType identifies the category of a diagnosis finding.
type FindingType string

const (
	FindingMTUMisconfiguration FindingType = "mtu_misconfiguration"
	FindingFragmentation       FindingType = "mtu_fragmentation"
	FindingPTBSuppression      FindingType = "ptb_suppression"
	FindingLocalPTBGenerated   FindingType = "local_ptb_generated"
	FindingNoIssue             FindingType = "no_issue"
)

// Finding is a single diagnostic conclusion produced by the controller.
type Finding struct {
	Type        FindingType `json:"type"`
	Severity    string      `json:"severity"`   // "error", "warning", "info"
	Overlay     string      `json:"overlay"`     // e.g. "vxlan0"
	Underlay    string      `json:"underlay"`    // e.g. "eth0"
	OverlayMTU  int         `json:"overlay_mtu"`
	UnderlayMTU int         `json:"underlay_mtu"`
	SafeMTU     int         `json:"safe_mtu"`
	ExcessBytes int         `json:"excess_bytes"`
	Detail      string      `json:"detail"`
	Fix         string      `json:"fix"`
}

// Snapshot is the complete state read from BPF maps at one polling interval.
// Not yet connected to real BPF maps — placeholder for implementation.
type Snapshot struct {
	TimestampNS      uint64
	OverlayMTU       int
	UnderlayMTU      int
	OversizedFlows   int
	FragmentEvents   uint32
	PTBsAtTCIngress  uint32
	PTBsAtIcmpRcv    uint64
}

// PTBSuppressed returns true if TC ingress saw PTBs but icmp_rcv did not.
func (s *Snapshot) PTBSuppressed() bool {
	return s.PTBsAtTCIngress > 0 && s.PTBsAtIcmpRcv == 0
}
