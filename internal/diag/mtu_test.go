package diag

import "testing"

func TestCheckMTU(t *testing.T) {
	cases := []struct {
		name        string
		overlayMTU  int
		underlayMTU int
		wantSafe    int
		wantExcess  int // excess of outer IP packet over underlay MTU (IP-layer, excludes outer ETH)
		wantCorrect bool
	}{
		{
			name:        "correct: overlay 1450, underlay 1500",
			overlayMTU:  1450,
			underlayMTU: 1500,
			wantSafe:    1450,
			wantExcess:  0,
			wantCorrect: true,
		},
		{
			name:        "wrong: overlay 1500 (default), underlay 1500",
			overlayMTU:  1500,
			underlayMTU: 1500,
			// outer IP = 1500 + 50 = 1550; excess over MTU 1500 = 50
			wantSafe:    1450,
			wantExcess:  50,
			wantCorrect: false,
		},
		{
			name:        "cloud MTU 9000: overlay 8950, underlay 9000",
			overlayMTU:  8950,
			underlayMTU: 9000,
			wantSafe:    8950,
			wantExcess:  0,
			wantCorrect: true,
		},
		{
			name:        "cloud MTU 9000, overlay still 1500",
			overlayMTU:  1500,
			underlayMTU: 9000,
			wantSafe:    8950,
			wantExcess:  0,
			wantCorrect: true,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := CheckMTU(c.overlayMTU, c.underlayMTU)
			if got.SafeOverlay != c.wantSafe {
				t.Errorf("SafeOverlay: got %d, want %d", got.SafeOverlay, c.wantSafe)
			}
			if got.ExcessBytes != c.wantExcess {
				t.Errorf("ExcessBytes: got %d, want %d (IP-layer excess, no outer ETH)", got.ExcessBytes, c.wantExcess)
			}
			if got.Correct != c.wantCorrect {
				t.Errorf("Correct: got %v, want %v", got.Correct, c.wantCorrect)
			}
		})
	}
}

func TestProjectedOuterIPLen(t *testing.T) {
	// inner IP 1500 → outer IP = 1500 + 50 = 1550
	// This is what the kernel compares against the underlay MTU.
	got := ProjectedOuterIPLen(1500)
	if got != 1550 {
		t.Errorf("ProjectedOuterIPLen(1500) = %d, want 1550", got)
	}
	// inner IP 1450 (correct overlay MTU) → outer IP = 1450 + 50 = 1500 (exactly fits)
	got = ProjectedOuterIPLen(1450)
	if got != 1500 {
		t.Errorf("ProjectedOuterIPLen(1450) = %d, want 1500", got)
	}
}

func TestProjectedWireFrameLen(t *testing.T) {
	// inner IP 1500 → wire frame = 1500 + 64 = 1564
	// wire frame = outer ETH(14) + outer IP(1550) = 1564
	// Note: wire frame is informational; the kernel MTU comparison uses outer IP len.
	got := ProjectedWireFrameLen(1500)
	if got != 1564 {
		t.Errorf("ProjectedWireFrameLen(1500) = %d, want 1564", got)
	}
	// inner IP 1450 → wire frame = 1450 + 64 = 1514
	got = ProjectedWireFrameLen(1450)
	if got != 1514 {
		t.Errorf("ProjectedWireFrameLen(1450) = %d, want 1514", got)
	}
}

func TestMaxSafeInnerIPLen(t *testing.T) {
	// underlay 1500: max inner IP = 1500 - 50 = 1450
	// Outer IP at 1450 inner = 1450 + 50 = 1500 = exactly underlay MTU. Fits.
	// The outer Ethernet header (14 bytes) is NOT subtracted here —
	// MTU is defined at the IP layer, not the wire frame level.
	got := MaxSafeInnerIPLen(1500)
	if got != 1450 {
		t.Errorf("MaxSafeInnerIPLen(1500) = %d, want 1450", got)
	}
	// overlay interface MTU should be set to MaxSafeInnerIPLen
	// i.e. 'ip link set vxlan0 mtu 1450'
}

func TestVXLANConstants(t *testing.T) {
	// VXLANOverheadBytes: overhead added to inner IP to get outer IP
	// inner ETH(14) + outer IP hdr(20) + outer UDP(8) + VXLAN hdr(8) = 50
	if VXLANOverheadBytes != 50 {
		t.Errorf("VXLANOverheadBytes = %d, want 50", VXLANOverheadBytes)
	}
	// VXLANWireFrameOverhead: VXLANOverheadBytes + outer ETH(14) = 64
	if VXLANWireFrameOverhead != 64 {
		t.Errorf("VXLANWireFrameOverhead = %d, want 64", VXLANWireFrameOverhead)
	}
	// Verify relationship
	if VXLANWireFrameOverhead != VXLANOverheadBytes+14 {
		t.Errorf("VXLANWireFrameOverhead (%d) != VXLANOverheadBytes (%d) + 14", VXLANWireFrameOverhead, VXLANOverheadBytes)
	}
	// For the common 1500 MTU case, sanity-check the full chain
	underlayMTU := 1500
	innerIP := 1500
	outerIP := ProjectedOuterIPLen(innerIP)
	wireFrame := ProjectedWireFrameLen(innerIP)
	excess := outerIP - underlayMTU
	safeMTU := MaxSafeInnerIPLen(underlayMTU)
	if outerIP != 1550 {
		t.Errorf("outer IP for inner 1500: got %d, want 1550", outerIP)
	}
	if wireFrame != 1564 {
		t.Errorf("wire frame for inner 1500: got %d, want 1564", wireFrame)
	}
	if excess != 50 {
		t.Errorf("IP-layer excess: got %d, want 50", excess)
	}
	if safeMTU != 1450 {
		t.Errorf("safe overlay MTU: got %d, want 1450", safeMTU)
	}
}
