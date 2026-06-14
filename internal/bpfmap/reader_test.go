package bpfmap

import (
	"testing"
)

// Fixture is the exact bpftool JSON from the day-03 PTB injection test.
// next_hop_mtu=0 is the known bug in the original inject_ptb.py (used 'unused='
// instead of 'nexthopmtu='); the fixture is preserved verbatim.
var ptbCountsFixture = []byte(`[{
    "key": {"ptb_src_ip": 40151232, "ptb_dst_ip": 23374016},
    "value": {
        "first_seen_ns": 170701520558656,
        "last_seen_ns": 170701824738739,
        "ptb_count": 5,
        "next_hop_mtu": 0,
        "pad": 0
    }
}]`)

func TestParsePTBCounts(t *testing.T) {
	entries, err := ParsePTBCounts(ptbCountsFixture)
	if err != nil {
		t.Fatalf("ParsePTBCounts: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("len = %d, want 1", len(entries))
	}
	e := entries[0]

	if got := e.Key.SrcIP().String(); got != "192.168.100.2" {
		t.Errorf("SrcIP = %q, want 192.168.100.2", got)
	}
	if got := e.Key.DstIP().String(); got != "192.168.100.1" {
		t.Errorf("DstIP = %q, want 192.168.100.1", got)
	}
	if e.Value.PTBCount != 5 {
		t.Errorf("PTBCount = %d, want 5", e.Value.PTBCount)
	}
	if e.Value.FirstSeenNS == 0 {
		t.Error("FirstSeenNS is zero")
	}
	if e.Value.LastSeenNS < e.Value.FirstSeenNS {
		t.Errorf("LastSeenNS %d < FirstSeenNS %d", e.Value.LastSeenNS, e.Value.FirstSeenNS)
	}
}

func TestParsePTBCountsEmpty(t *testing.T) {
	entries, err := ParsePTBCounts([]byte("[]"))
	if err != nil {
		t.Fatalf("ParsePTBCounts empty: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("len = %d, want 0", len(entries))
	}
}

func TestParsePTBCountsBadJSON(t *testing.T) {
	_, err := ParsePTBCounts([]byte("{not json}"))
	if err == nil {
		t.Fatal("expected error for bad JSON, got nil")
	}
}

func TestParsePTBTotal(t *testing.T) {
	raw := []byte(`[{"key": 0, "value": 5}]`)
	total, err := ParsePTBTotal(raw)
	if err != nil {
		t.Fatalf("ParsePTBTotal: %v", err)
	}
	if total != 5 {
		t.Errorf("total = %d, want 5", total)
	}
}

func TestParsePTBTotalZero(t *testing.T) {
	raw := []byte(`[{"key": 0, "value": 0}]`)
	total, err := ParsePTBTotal(raw)
	if err != nil {
		t.Fatalf("ParsePTBTotal: %v", err)
	}
	if total != 0 {
		t.Errorf("total = %d, want 0", total)
	}
}

func TestLeU32ToIP(t *testing.T) {
	// 40151232 = 0x0264A8C0; LE bytes = [C0 A8 64 02] = 192.168.100.2
	// 23374016 = 0x0164A8C0; LE bytes = [C0 A8 64 01] = 192.168.100.1
	cases := []struct {
		val  uint32
		want string
	}{
		{40151232, "192.168.100.2"},
		{23374016, "192.168.100.1"},
		{0x0100007f, "127.0.0.1"},
		{0, "0.0.0.0"},
	}
	for _, tc := range cases {
		got := leU32ToIP(tc.val).String()
		if got != tc.want {
			t.Errorf("leU32ToIP(%d) = %q, want %q", tc.val, got, tc.want)
		}
	}
}
