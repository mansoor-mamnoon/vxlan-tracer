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

func TestDiagnoseFragmentationRisk(t *testing.T) {
	d := Diagnose(Observation{
		PTBIngressTotal: 0,
		ICMPRcvTotal:    0,
		MaxOuterIPLen:   1438,
		UnderlayMTU:     1400,
	})
	if d.Verdict != VerdictFragmentationRisk {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictFragmentationRisk)
	}
	if !strings.Contains(d.Message, "1438") || !strings.Contains(d.Message, "1400") {
		t.Errorf("Message does not mention observed lengths: %s", d.Message)
	}
}

func TestDiagnoseMTUMisconfiguration(t *testing.T) {
	d := Diagnose(Observation{
		PTBIngressTotal: 0,
		ICMPRcvTotal:    0,
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

func TestDiagnoseNoPTBObserved(t *testing.T) {
	d := Diagnose(Observation{})
	if d.Verdict != VerdictNoPTBObserved {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictNoPTBObserved)
	}
}

func TestDiagnoseNoPTBObservedWithCorrectMTU(t *testing.T) {
	d := Diagnose(Observation{
		UnderlayMTU: 1400,
		OverlayMTU:  1350, // correctly sized for the underlay
	})
	if d.Verdict != VerdictNoPTBObserved {
		t.Errorf("Verdict = %s, want %s", d.Verdict, VerdictNoPTBObserved)
	}
}

func TestDiagnosePTBObservedTakesPrecedenceOverMTU(t *testing.T) {
	// Even with a misconfigured MTU on paper, an actually-observed PTB is
	// the higher-confidence signal and should win.
	d := Diagnose(Observation{
		PTBIngressTotal: 2,
		ICMPRcvTotal:    0,
		UnderlayMTU:     1400,
		OverlayMTU:      1450,
	})
	if d.Verdict != VerdictPTBSuppressed {
		t.Errorf("Verdict = %s, want %s (PTB evidence should take precedence over static MTU check)", d.Verdict, VerdictPTBSuppressed)
	}
}
