// Package diag implements VXLAN MTU arithmetic and diagnosis logic.
// It is pure Go with no BPF or kernel dependencies; fully testable on any OS.
package diag

const (
	VXLANOverheadBytes = 50 // outer ETH(14) + IP(20) + UDP(8) + VXLAN hdr(8)
)

// MTUCheck holds the result of an MTU configuration check.
type MTUCheck struct {
	OverlayMTU   int
	UnderlayMTU  int
	SafeOverlay  int  // UnderlayMTU - VXLANOverheadBytes
	ExcessBytes  int  // 0 if correct; positive if overlay MTU is too high
	Correct      bool
}

// CheckMTU computes whether the overlay MTU is safe given the underlay MTU.
// Safe means: overlayMTU + VXLANOverheadBytes <= underlayMTU.
func CheckMTU(overlayMTU, underlayMTU int) MTUCheck {
	safe := underlayMTU - VXLANOverheadBytes
	// outer frame = inner IP (overlayMTU) + inner ETH (14) + VXLAN overhead (50)
	// but inner ETH is not included in overlayMTU (MTU is the IP layer limit)
	// outer frame = overlayMTU + VXLANOverheadBytes + 14 (outer ETH)
	// we check: overlayMTU + VXLANOverheadBytes <= underlayMTU
	excess := (overlayMTU + VXLANOverheadBytes) - underlayMTU
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

// ProjectedOuterFrame returns the size of the outer Ethernet frame
// for an inner IP packet of innerIPLen bytes.
// outer = innerIPLen + inner ETH (14) + VXLAN overhead (50) = innerIPLen + 64
func ProjectedOuterFrame(innerIPLen int) int {
	return innerIPLen + 14 + VXLANOverheadBytes
}

// MaxSafeInnerIPLen returns the largest inner IP packet that fits in
// the underlay MTU without fragmentation or PTB.
// underlay_mtu >= inner_ip_len + 14 (outer ETH) + 50 (VXLAN overhead)
// inner_ip_len_max = underlay_mtu - 64
func MaxSafeInnerIPLen(underlayMTU int) int {
	return underlayMTU - 14 - VXLANOverheadBytes
}
