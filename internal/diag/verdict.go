package diag

import "fmt"

// Verdict is one of the five outcomes vxlan-tracer can report for a single
// observation window. Wording on every Diagnosis.Message is deliberately
// conservative — see docs/forbidden-claims.md, in particular claim #2
// (no inner 5-tuple from a PTB) and claim #5 (this tool does not detect all
// VXLAN blackholes, only the local fragmentation/PTB-suppression case).
type Verdict string

const (
	// VerdictNoPTBObserved: no PTB crossed TC ingress during the window, and
	// no MTU misconfiguration or oversized traffic was detected either. This
	// does not prove the path is healthy — only that nothing was observed.
	VerdictNoPTBObserved Verdict = "NO_PTB_OBSERVED"

	// VerdictPTBDelivered: PTBs were observed at TC ingress and the same (or
	// more) reached icmp_rcv — the kernel's ICMP handling path is receiving
	// them, i.e. they are not being suppressed before icmp_rcv.
	VerdictPTBDelivered Verdict = "PTB_DELIVERED"

	// VerdictPTBSuppressed: PTBs were observed at TC ingress but none reached
	// icmp_rcv. Something between the NIC and icmp_rcv — commonly a
	// netfilter/iptables DROP rule — is suppressing them.
	VerdictPTBSuppressed Verdict = "PTB_SUPPRESSED"

	// VerdictFragmentationRisk: no PTB was observed, but real traffic was
	// seen whose outer IP packet length exceeds the underlay MTU. This is
	// consistent with the kernel silently fragmenting (DF=0) rather than
	// dropping and generating a PTB (DF=1) — no PTB is expected in that case,
	// so its absence here is not by itself suppression.
	VerdictFragmentationRisk Verdict = "VXLAN_FRAGMENTATION_RISK"

	// VerdictMTUMisconfiguration: no PTB and no oversized traffic was
	// observed, but the overlay MTU is configured higher than is safe for
	// the underlay MTU. This is a static configuration risk, not an observed
	// packet event — it describes what would happen if traffic large enough
	// to trigger it were sent.
	VerdictMTUMisconfiguration Verdict = "VXLAN_MTU_MISCONFIGURATION"
)

// Observation is the counter/config snapshot a Diagnosis is computed from.
// Zero values for MaxOuterIPLen, UnderlayMTU, or OverlayMTU mean "no data
// available" (e.g. flow_state was empty, or MTU was not supplied) rather
// than a real measurement of zero.
type Observation struct {
	// PTBIngressTotal is the TC-ingress count of ICMP type=3/code=4 packets,
	// observed before netfilter (ptb_ingress_total).
	PTBIngressTotal uint64

	// ICMPRcvTotal is the icmp_rcv-kprobe count of the same ICMP type=3/
	// code=4 packets, observed after netfilter (icmp_rcv_total). It is only
	// meaningful as a PTB count because the kprobe filters to type=3/code=4
	// (see bpf/kprobes.bpf.c, Day 5 commit 1) — an unfiltered icmp_rcv count
	// would include unrelated ICMP traffic such as ping.
	ICMPRcvTotal uint64

	// MaxOuterIPLen is the largest outer IP packet length observed across
	// all flows in flow_state (flow_val.max_outer_ip_len). 0 means no flow
	// data was available.
	MaxOuterIPLen int

	// UnderlayMTU and OverlayMTU are the configured MTUs of the underlay and
	// overlay interfaces. 0 means unknown / not supplied.
	UnderlayMTU int
	OverlayMTU  int

	// FragEventsTotal is the count from the ip_do_fragment kprobe map
	// (frag_events_total.total). A value > 0 means the kernel fragmented at
	// least one outgoing IP packet while vxlan-tracer was attached. In the
	// stale-MTU topology (vxlan0 MTU stale at 1450, underlay MTU 1400) any
	// large VXLAN packet triggers ip_do_fragment. 0 means nothing fragmented.
	// NOTE: this counter fires for all IP fragmentation on the host, not only
	// VXLAN outer packets — in production environments with other fragmented
	// traffic the count may be inflated.
	FragEventsTotal uint64
}

// Diagnosis is the result of Diagnose: a verdict plus the explanation that
// should accompany it.
type Diagnosis struct {
	Verdict Verdict
	Message string
}

// Diagnose maps an Observation to one of the five verdicts.
//
// Precedence (most specific, highest-confidence signal first):
//
//  1. A PTB was actually observed at TC ingress (PTBIngressTotal > 0): this
//     is direct evidence of a real PTB crossing the underlay, so it takes
//     priority over any static MTU check. Whether it reached icmp_rcv
//     decides PTB_DELIVERED vs PTB_SUPPRESSED.
//
//  2. No PTB was observed, but oversized real traffic was (MaxOuterIPLen >
//     UnderlayMTU): VXLAN_FRAGMENTATION_RISK. No PTB is expected here if the
//     traffic had DF=0, so its absence is not itself suppression.
//
//  3. No PTB and no oversized traffic was observed, but the static MTU
//     check shows the overlay MTU is unsafe for the underlay MTU:
//     VXLAN_MTU_MISCONFIGURATION — a configuration risk, not yet manifested
//     in observed traffic.
//
//  4. Otherwise: NO_PTB_OBSERVED.
func Diagnose(obs Observation) Diagnosis {
	if obs.PTBIngressTotal > 0 {
		if obs.ICMPRcvTotal > 0 {
			return Diagnosis{
				Verdict: VerdictPTBDelivered,
				Message: fmt.Sprintf(
					"%d ICMP type=3/code=4 packet(s) were observed at TC ingress and %d reached icmp_rcv: "+
						"PTBs are reaching the kernel's ICMP handling path, not being suppressed.",
					obs.PTBIngressTotal, obs.ICMPRcvTotal),
			}
		}
		return Diagnosis{
			Verdict: VerdictPTBSuppressed,
			Message: fmt.Sprintf(
				"%d ICMP type=3/code=4 packet(s) were observed at TC ingress, but 0 reached icmp_rcv: "+
					"something between the NIC and icmp_rcv — commonly a netfilter/iptables DROP rule — "+
					"is suppressing PTBs before the kernel can act on them.",
				obs.PTBIngressTotal),
		}
	}

	if obs.UnderlayMTU > 0 && obs.MaxOuterIPLen > obs.UnderlayMTU {
		return Diagnosis{
			Verdict: VerdictFragmentationRisk,
			Message: fmt.Sprintf(
				"No PTBs were observed, but a flow's outer IP packet length (%d) exceeded the underlay "+
					"MTU (%d). This is consistent with the kernel fragmenting the outer packet (DF=0) "+
					"rather than dropping it and generating a PTB (DF=1); no PTB is expected in that case.",
				obs.MaxOuterIPLen, obs.UnderlayMTU),
		}
	}

	if obs.UnderlayMTU > 0 && obs.OverlayMTU > 0 {
		mtu := CheckMTU(obs.OverlayMTU, obs.UnderlayMTU)
		if !mtu.Correct {
			return Diagnosis{
				Verdict: VerdictMTUMisconfiguration,
				Message: fmt.Sprintf(
					"No PTBs or oversized traffic were observed during this run, but the overlay MTU (%d) "+
						"exceeds the safe value for the underlay MTU (%d) by %d byte(s). This is a static "+
						"configuration risk: traffic large enough to use the full overlay MTU would trigger "+
						"either fragmentation or a PTB, depending on the DF bit.",
					mtu.OverlayMTU, mtu.UnderlayMTU, mtu.ExcessBytes),
			}
		}
	}

	return Diagnosis{
		Verdict: VerdictNoPTBObserved,
		Message: "No ICMP type=3/code=4 packets were observed at TC ingress during this run, and no " +
			"oversized traffic or MTU misconfiguration was detected. This does not prove the path is " +
			"healthy — it only means nothing relevant was observed while vxlan-tracer was attached.",
	}
}
