//go:build linux

package loader

import (
	"strings"
	"testing"

	"github.com/cilium/ebpf"
)

// TestWriteVXLANPortToMapsMissing verifies that writeVXLANPortToMaps returns
// a clear error when the vxlan_config map is not present in the collection.
// This is the fail-closed guard against stale BPF objects.
func TestWriteVXLANPortToMapsMissing(t *testing.T) {
	err := writeVXLANPortToMaps(map[string]*ebpf.Map{}, 4789)
	if err == nil {
		t.Fatal("expected error when vxlan_config map is absent, got nil")
	}
	if !strings.Contains(err.Error(), "vxlan_config map missing from tc_ingress object") {
		t.Fatalf("error message should mention map name, got: %v", err)
	}
	if !strings.Contains(err.Error(), "make clean-bpf") {
		t.Fatalf("error message should mention make clean-bpf, got: %v", err)
	}
}

// TestWriteVXLANPortToMapsMissingPort0 verifies the same error for port 0
// (auto-detect path) when the map is absent — port 0 must not silently skip.
func TestWriteVXLANPortToMapsMissingPort0(t *testing.T) {
	err := writeVXLANPortToMaps(map[string]*ebpf.Map{}, 0)
	if err == nil {
		t.Fatal("expected error for port=0 when vxlan_config map is absent, got nil")
	}
	if !strings.Contains(err.Error(), "vxlan_config map missing from tc_ingress object") {
		t.Fatalf("unexpected error: %v", err)
	}
}
