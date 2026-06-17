package diag

import (
	"strings"
	"testing"
)

func TestDiagnosePTBDelivered(t *testing.T) {
	d := Diagnose(Observation{PTBIngressTotal: 5, ICMPRcvTotal: 5})
	if d.Verdict != VerdictPTBDelivered {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictPTBDelivered)
	}
	if !strings.Contains(d.Message, "5") {
		t.Errorf("Message does not mention counts: %s", d.Message)
	}
}

func TestDiagnosePTBDeliveredPartial(t *testing.T) {
	// icmp_rcv lagging behind ingress (e.g. read mid-burst) still counts as
	// "delivered", not suppressed — suppression means icmp_rcv stays at 0.
	d := Diagnose(Observation{PTBIngressTotal: 5, ICMPRcvTotal: 3})
	if d.Verdict != VerdictPTBDelivered {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictPTBDelivered)
	}
}

func TestDiagnosePTBSuppressed(t *testing.T) {
	d := Diagnose(Observation{PTBIngressTotal: 5, ICMPRcvTotal: 0})
	if d.Verdict != VerdictPTBSuppressed {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictPTBSuppressed)
	}
	if !strings.Contains(d.Message, "netfilter") {
		t.Errorf("Message does not mention netfilter: %s", d.Message)
	}
}

func TestDiagnoseFragmentationObserved(t *testing.T) {
	// Corroborated case: both ip_do_fragment events AND oversized VXLAN traffic.
	// This is the primary lab scenario (inner IP 1388B → outer IP 1438B > 1400B).
	d := Diagnose(Observation{
		PTBIngressTotal: 0,
		ICMPRcvTotal:    0,
		FragEventsTotal: 6,
		MaxOuterIPLen:   1438,
		UnderlayMTU:     1400,
	})
	if d.Verdict != VerdictFragmentationObserved {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictFragmentationObserved)
	}
	if !strings.Contains(d.Message, "6") {
		t.Errorf("Message does not mention frag count: %s", d.Message)
	}
	if !strings.Contains(d.Message, "1400") {
		t.Errorf("Message does not mention underlay MTU: %s", d.Message)
	}
	if !strings.Contains(d.Message, "1438") {
		t.Errorf("Message does not mention observed outer IP len: %s", d.Message)
	}
	// Must not CONFIRM packet loss — disclaiming is allowed and expected.
	if strings.Contains(d.Message, "confirms packet loss") || strings.Contains(d.Message, "blackhole confirmed") {
		t.Errorf("Message should not confirm packet loss or blackhole: %s", d.Message)
	}
}

func TestDiagnoseFragmentationObservedGlobalOnly(t *testing.T) {
	// Conservative case: ip_do_fragment fired but no VXLAN-sized flow corroboration.
	d := Diagnose(Observation{
		PTBIngressTotal: 0,
		ICMPRcvTotal:    0,
		FragEventsTotal: 3,
		MaxOuterIPLen:   0,
		UnderlayMTU:     1400,
	})
	if d.Verdict != VerdictFragmentationObserved {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictFragmentationObserved)
	}
	if !strings.Contains(d.Message, "global") {
		t.Errorf("Message should mention global scope: %s", d.Message)
	}
	if strings.Contains(d.Message, "VXLAN outer packets triggering") {
		t.Errorf("Message must not claim VXLAN causation without flow evidence: %s", d.Message)
	}
}

func TestDiagnoseMTURisk(t *testing.T) {
	// No frag events, but flow_state shows oversized outer packet
	d := Diagnose(Observation{
		PTBIngressTotal: 0,
		ICMPRcvTotal:    0,
		FragEventsTotal: 0,
		MaxOuterIPLen:   1438,
		UnderlayMTU:     1400,
	})
	if d.Verdict != VerdictMTURisk {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictMTURisk)
	}
	if !strings.Contains(d.Message, "1438") || !strings.Contains(d.Message, "1400") {
		t.Errorf("Message does not mention observed lengths: %s", d.Message)
	}
}

func TestDiagnoseMTUMisconfiguration(t *testing.T) {
	d := Diagnose(Observation{
		PTBIngressTotal: 0,
		ICMPRcvTotal:    0,
		FragEventsTotal: 0,
		MaxOuterIPLen:   0, // no oversized traffic observed yet
		UnderlayMTU:     1400,
		OverlayMTU:      1450, // stale; safe would be 1350
	})
	if d.Verdict != VerdictMTUMisconfiguration {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictMTUMisconfiguration)
	}
	if !strings.Contains(d.Message, "1450") || !strings.Contains(d.Message, "1400") {
		t.Errorf("Message does not mention configured MTUs: %s", d.Message)
	}
}

func TestDiagnoseNoIssueObserved(t *testing.T) {
	d := Diagnose(Observation{})
	if d.Verdict != VerdictNoIssueObserved {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictNoIssueObserved)
	}
}

func TestDiagnoseNoIssueObservedWithCorrectMTU(t *testing.T) {
	d := Diagnose(Observation{
		UnderlayMTU: 1400,
		OverlayMTU:  1350, // correctly sized for the underlay
	})
	if d.Verdict != VerdictNoIssueObserved {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictNoIssueObserved)
	}
}

func TestDiagnosePTBObservedTakesPrecedenceOverFrag(t *testing.T) {
	// Even with frag events, an actually-observed PTB is the higher-confidence
	// signal and should take precedence.
	d := Diagnose(Observation{
		PTBIngressTotal: 2,
		ICMPRcvTotal:    0,
		FragEventsTotal: 10,
		UnderlayMTU:     1400,
	})
	if d.Verdict != VerdictPTBSuppressed {
		t.Errorf("Verdict = %s, want %s (PTB evidence takes precedence over frag)", d.Verdict, VerdictPTBSuppressed)
	}
}

func TestDiagnoseFragTakesPrecedenceOverMTURisk(t *testing.T) {
	// Direct BPF fragmentation count outranks indirect flow_state evidence.
	d := Diagnose(Observation{
		PTBIngressTotal: 0,
		ICMPRcvTotal:    0,
		FragEventsTotal: 3,
		MaxOuterIPLen:   1438,
		UnderlayMTU:     1400,
	})
	if d.Verdict != VerdictFragmentationObserved {
		t.Errorf("Verdict = %s, want %s (frag event outranks MTU risk)", d.Verdict, VerdictFragmentationObserved)
	}
}

func TestDiagnoseFragTakesPrecedenceOverMTUMisconfiguration(t *testing.T) {
	d := Diagnose(Observation{
		PTBIngressTotal: 0,
		ICMPRcvTotal:    0,
		FragEventsTotal: 1,
		MaxOuterIPLen:   0,
		UnderlayMTU:     1400,
		OverlayMTU:      1450,
	})
	if d.Verdict != VerdictFragmentationObserved {
		t.Errorf("Verdict = %s, want %s (frag event outranks config check)", d.Verdict, VerdictFragmentationObserved)
	}
}
