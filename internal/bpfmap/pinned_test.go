package bpfmap

import (
	"testing"
	"unsafe"
)

// TestPinnedStructSizes guards against the Go struct layouts drifting from
// the C structs in bpf/maps.h. cilium/ebpf marshals these by raw memory
// layout (no JSON, no manual byte-order handling beyond IP fields), so a
// mismatched size or field order would silently corrupt every read from a
// pinned map rather than failing loudly.
func TestPinnedStructSizes(t *testing.T) {
	cases := []struct {
		name string
		got  uintptr
		want uintptr
	}{
		// struct ptb_key: __u32 + __u32 = 8 bytes.
		{"PinnedPTBKey", unsafe.Sizeof(PinnedPTBKey{}), 8},
		// struct ptb_val: __u64 + __u64 + __u32 + __u16 + __u16 = 24 bytes.
		{"PinnedPTBVal", unsafe.Sizeof(PinnedPTBVal{}), 24},
		// struct flow_key: __u32 + __u32 + __u16 + __u16 + __u8 + __u8[3] = 16 bytes.
		{"PinnedFlowKey", unsafe.Sizeof(PinnedFlowKey{}), 16},
		// struct flow_val: __u64 + __u32 + __u16 + __u16 = 16 bytes.
		{"PinnedFlowVal", unsafe.Sizeof(PinnedFlowVal{}), 16},
		// struct frag_val: __u64 + __u64 + __u32 + __u32 (pad) = 24 bytes.
		{"PinnedFragVal", unsafe.Sizeof(PinnedFragVal{}), 24},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("unsafe.Sizeof(%s{}) = %d, want %d (must match bpf/maps.h)", c.name, c.got, c.want)
		}
	}
}

func TestPinnedPTBKeyIPDecoding(t *testing.T) {
	// Same fixture values as TestLeU32ToIP / TestParsePTBCounts in
	// reader_test.go, exercised here through the pinned-map key type.
	k := PinnedPTBKey{PTBSrcIP: 40151232, PTBDstIP: 23374016}
	if got := k.SrcIP().String(); got != "192.168.100.2" {
		t.Errorf("SrcIP() = %q, want 192.168.100.2", got)
	}
	if got := k.DstIP().String(); got != "192.168.100.1" {
		t.Errorf("DstIP() = %q, want 192.168.100.1", got)
	}
}

func TestPinnedFlowKeyIPDecoding(t *testing.T) {
	k := PinnedFlowKey{SrcIP: 0x0100007f, DstIP: 0}
	if got := k.Src().String(); got != "127.0.0.1" {
		t.Errorf("Src() = %q, want 127.0.0.1", got)
	}
	if got := k.Dst().String(); got != "0.0.0.0" {
		t.Errorf("Dst() = %q, want 0.0.0.0", got)
	}
}
