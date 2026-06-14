// Package diag implements VXLAN MTU arithmetic and diagnosis logic.
// It is pure Go with no BPF or kernel dependencies; fully testable on any OS.
package diag

// MTU terminology used throughout this package:
//
//   inner IP packet   — the packet produced by the inner socket (overlayMTU defines its max size)
//   outer IP packet   — inner ETH (14) + inner IP + VXLAN hdr (8) + outer UDP (8) + outer IP hdr (20)
//   wire frame        — outer ETH (14) + outer IP packet
//
// The kernel MTU comparison uses outer IP packet length vs underlay interface MTU.
// The outer Ethernet header (14 bytes) is NOT included in the MTU comparison.
//
// For inner IP = 1500 bytes:
//   outer IP packet = 1500 + 14 (inner ETH) + 8 (VXLAN) + 8 (outer UDP) + 20 (outer IP) = 1550
//   wire frame      = 14 (outer ETH) + 1550 = 1564
//   excess          = 1550 - 1500 (underlay MTU) = 50 bytes
//   → ip_do_fragment fires (DF=0) or outer packet dropped (DF=1)

const (
	// VXLANOverheadBytes is the overhead added to the inner IP packet length
	// to obtain the outer IP packet length. The underlay MTU is compared against
	// the outer IP packet length (not the wire frame).
	//
	// Breakdown: inner ETH(14) + outer IP hdr(20) + outer UDP(8) + VXLAN hdr(8) = 50
	VXLANOverheadBytes = 50

	// VXLANWireFrameOverhead is the total overhead over the inner IP packet
	// as seen on the wire (outer ETH included).
	//
	// Breakdown: outer ETH(14) + inner ETH(14) + outer IP(20) + outer UDP(8) + VXLAN hdr(8) = 64
	VXLANWireFrameOverhead = 64
)

// MTUCheck holds the result of an MTU configuration check.
type MTUCheck struct {
	OverlayMTU  int
	UnderlayMTU int
	SafeOverlay int // max overlay MTU that keeps outer IP packet within underlay MTU
	// ExcessBytes is the excess of the outer IP packet over the underlay MTU.
	// 0 if correctly configured; positive if overlay MTU is too high.
	// Does NOT include the outer Ethernet header (14 bytes).
	ExcessBytes int
	Correct     bool
}

// CheckMTU computes whether the overlay MTU is safe given the underlay MTU.
//
// "Safe" means the outer IP packet fits within the underlay MTU:
//   outer IP packet = overlayMTU + VXLANOverheadBytes ≤ underlayMTU
//
// ExcessBytes is the number of bytes by which the outer IP packet exceeds
// the underlay MTU. This is what the kernel observes when deciding whether
// to fragment (DF=0) or drop+PTB (DF=1).
func CheckMTU(overlayMTU, underlayMTU int) MTUCheck {
	safe := underlayMTU - VXLANOverheadBytes
	outerIPLen := overlayMTU + VXLANOverheadBytes
	excess := outerIPLen - underlayMTU
	if excess < 0 {
		excess = 0
	}
	return MTUCheck{
		OverlayMTU:  overlayMTU,
		UnderlayMTU: underlayMTU,
		SafeOverlay: safe,
		ExcessBytes: excess,
		Correct:     overlayMTU <= safe,
	}
}

// ProjectedOuterIPLen returns the outer IP packet length for a given inner IP
// packet length. This is the value the kernel compares against the underlay MTU.
//
//   outer IP = innerIPLen + VXLANOverheadBytes
//
// For innerIPLen=1500: outer IP = 1550 (50 bytes over a 1500-byte underlay MTU).
func ProjectedOuterIPLen(innerIPLen int) int {
	return innerIPLen + VXLANOverheadBytes
}

// ProjectedWireFrameLen returns the Ethernet wire frame length for a given
// inner IP packet length. This includes the outer Ethernet header (14 bytes)
// and is provided for informational purposes only — the kernel MTU comparison
// uses ProjectedOuterIPLen, not the wire frame.
//
//   wire frame = innerIPLen + VXLANWireFrameOverhead
//
// For innerIPLen=1500: wire frame = 1564 bytes.
func ProjectedWireFrameLen(innerIPLen int) int {
	return innerIPLen + VXLANWireFrameOverhead
}

// MaxSafeInnerIPLen returns the largest inner IP packet that keeps the outer
// IP packet within the underlay MTU without fragmentation or PTB.
//
//   max outer IP = underlayMTU
//   max inner IP = underlayMTU - VXLANOverheadBytes
//
// For underlayMTU=1500: max inner IP = 1450.
// The overlay interface MTU should be set to this value.
func MaxSafeInnerIPLen(underlayMTU int) int {
	return underlayMTU - VXLANOverheadBytes
}
