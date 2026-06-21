//go:build linux

package netlink

import "testing"

// TestListVXLANNilFreeSlice verifies that ListVXLAN always returns a non-nil
// slice, even when no VXLAN interfaces are present (as in CI runners).
func TestListVXLANNilFreeSlice(t *testing.T) {
	candidates, err := ListVXLAN()
	if err != nil {
		t.Fatalf("ListVXLAN() error: %v", err)
	}
	if candidates == nil {
		t.Error("ListVXLAN() returned nil; want non-nil empty slice so JSON marshaling produces [] not null")
	}
}

// TestListVXLANCandidateFieldsValid verifies that any VXLAN interfaces found
// have valid Name, Port (≥ 1), and MTU (> 0). The test passes harmlessly when
// no VXLAN interfaces are present on the host (e.g., plain CI runner).
func TestListVXLANCandidateFieldsValid(t *testing.T) {
	candidates, err := ListVXLAN()
	if err != nil {
		t.Fatalf("ListVXLAN() error: %v", err)
	}
	for _, c := range candidates {
		if c.Name == "" {
			t.Error("candidate has empty Name")
		}
		if c.Port == 0 {
			t.Errorf("candidate %s has Port 0; ListVXLAN must default to 4789 when the kernel returns 0", c.Name)
		}
		if c.MTU <= 0 {
			t.Errorf("candidate %s has MTU %d; want > 0", c.Name, c.MTU)
		}
	}
}
