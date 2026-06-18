package diag

import "fmt"

// Verdict is one of the five outcomes vxlan-tracer can report for a single
// observation window. Wording on every Diagnosis.Message is deliberately
// conservative — see docs/forbidden-claims.md, in particular claim #2
// (no inner 5-tuple from a PTB) and claim #5 (this tool does not detect all
// VXLAN blackholes, only the local fragmentation/PTB-suppression case).
type Verdict string

const (
	// VerdictNoIssueObserved: nothing of diagnostic interest was observed.
	// Does not prove the path is healthy.
	VerdictNoIssueObserved Verdict = "NO_ISSUE_OBSERVED"

	// VerdictPTBDelivered: PTBs were observed at TC ingress and the same (or
	// more) reached icmp_rcv — the kernel's ICMP handling path is receiving
	// them, i.e. they are not being suppressed before icmp_rcv.
	VerdictPTBDelivered Verdict = "PTB_DELIVERED"

	// VerdictPTBSuppressed: PTBs were observed at TC ingress but none reached
	// icmp_rcv. Something between the NIC and icmp_rcv — commonly a
	// netfilter/iptables DROP rule — is suppressing them.
	VerdictPTBSuppressed Verdict = "PTB_SUPPRESSED"

	// VerdictFragmentationObserved: ip_do_fragment fired at least once while
	// vxlan-tracer was attached, and no PTBs were observed. This is direct
	// BPF evidence that the kernel fragmented an outgoing IP packet. In the
	// stale-MTU VXLAN scenario, this means oversized outer packets are being
	// fragmented rather than dropped. Fragmented VXLAN UDP is commonly dropped
	// silently by cloud fabric (AWS/GCP/Azure VPC); in a local lab, fragments
	// may reassemble successfully — fragmentation ≠ packet loss in all cases.
	// See docs/forbidden-claims.md.
	VerdictFragmentationObserved Verdict = "VXLAN_FRAGMENTATION_OBSERVED"

	// VerdictMTURisk: no PTB and no ip_do_fragment event was observed, but
	// real traffic was seen whose outer IP packet length exceeds the underlay
	// MTU (from flow_state.max_outer_ip_len). This is consistent with the
	// kernel fragmenting (DF=0), but ip_do_fragment did not fire during the
	// observation window — or the fragmentation counter was not accessible.
	VerdictMTURisk Verdict = "VXLAN_MTU_RISK"

	// VerdictMTUMisconfiguration: no PTB, no fragmentation event, and no
	// oversized traffic was observed, but the overlay MTU is configured higher
	// than is safe for the underlay MTU. Static configuration risk only.
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
	// NOTE: ip_do_fragment is a global kernel function — this counter fires for
	// ALL outgoing IP fragmentation on the host, not only VXLAN outer packets.
	// Use alongside MaxOuterIPLen > UnderlayMTU for stronger VXLAN attribution.
	FragEventsTotal uint64

	// FragMaxSKBLen is the maximum skb->len recorded by the ip_do_fragment
	// kprobe (frag_events_total.max_skb_len). 0 means no fragmentation was
	// observed or the CO-RE read returned zero.
	FragMaxSKBLen uint32
}

// FragmentationScope classifies the scoping confidence of a VXLAN_FRAGMENTATION_OBSERVED
// verdict. Included in the Diagnosis and surfaced in JSON output.
type FragmentationScope string

const (
	// FragScopeGlobalCorroborated: ip_do_fragment fired AND TC egress confirmed
	// oversized VXLAN outer packets (max_outer_ip_len > underlay_mtu). Both
	// signals are present; fragmentation is consistent with VXLAN causation but
	// the kprobe counter is still global (not VXLAN-specific).
	FragScopeGlobalCorroborated FragmentationScope = "global_corroborated"

	// FragScopeGlobalUnscoped: ip_do_fragment fired but TC egress did NOT
	// confirm oversized VXLAN outer packets. The fragmentation may or may not
	// be VXLAN-related; treat as weak evidence only.
	FragScopeGlobalUnscoped FragmentationScope = "global_unscoped"
)

// Diagnosis is the result of Diagnose: a verdict plus the explanation that
// should accompany it.
type Diagnosis struct {
	Verdict            Verdict
	Message            string
	FragmentationScope FragmentationScope // non-empty only when verdict is VerdictFragmentationObserved
}

// Diagnose maps an Observation to one of the five verdicts.
//
// Precedence (most specific, highest-confidence signal first):
//
//  1. PTB observed at TC ingress (PTBIngressTotal > 0): direct packet evidence
//     takes priority over everything else. Whether icmp_rcv received the PTB
//     decides PTB_SUPPRESSED vs PTB_DELIVERED.
//
//  2. ip_do_fragment fired (FragEventsTotal > 0) and no PTB was observed:
//     VXLAN_FRAGMENTATION_OBSERVED. Direct BPF evidence from the fragmentation
//     kprobe — the kernel fragmented at least one packet. Fragmentation ≠
//     packet loss in all environments (fragments reassemble in a local lab),
//     so the verdict name avoids "blackhole" or "loss."
//
//  3. No fragmentation event, but flow_state shows an oversized packet
//     (MaxOuterIPLen > UnderlayMTU): VXLAN_MTU_RISK. Indirect evidence from
//     the TC egress map — a packet large enough to trigger fragmentation was
//     observed but ip_do_fragment did not register it during this window (or
//     was not accessible). DF=0 means no PTB is generated, so its absence is
//     not suppression.
//
//  4. No PTB, no fragmentation event, no oversized traffic, but static MTU
//     check fails: VXLAN_MTU_MISCONFIGURATION. Config risk not yet triggered.
//
//  5. Otherwise: NO_ISSUE_OBSERVED.
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

	if obs.FragEventsTotal > 0 {
		if obs.UnderlayMTU > 0 && obs.MaxOuterIPLen > obs.UnderlayMTU {
			// Both ip_do_fragment counter and VXLAN flow size evidence are present.
			// This is the corroborated case: fragmentation was observed while
			// oversized VXLAN traffic was in flight. Neither signal alone is VXLAN-
			// specific (ip_do_fragment fires globally; flow_state may record brief
			// spikes), but both together are strong evidence for the stale-MTU scenario.
			return Diagnosis{
				Verdict:            VerdictFragmentationObserved,
				FragmentationScope: FragScopeGlobalCorroborated,
				Message: fmt.Sprintf(
					"%d ip_do_fragment invocation(s) were observed while vxlan-tracer was attached; "+
						"concurrently, the TC egress hook recorded an outer packet length of %d bytes, "+
						"%d bytes over the underlay MTU (%d). "+
						"Fragmentation was observed while oversized VXLAN traffic was present — "+
						"these two signals together are consistent with VXLAN outer packets triggering "+
						"ip_do_fragment. Note: ip_do_fragment is a global kernel function and may "+
						"include non-VXLAN fragmentation events on a busy host. "+
						"Fragmented VXLAN UDP is commonly dropped silently by cloud fabric; "+
						"in a local lab fragments may reassemble — "+
						"fragmentation observed here does not by itself confirm packet loss.",
					obs.FragEventsTotal, obs.MaxOuterIPLen,
					obs.MaxOuterIPLen-obs.UnderlayMTU, obs.UnderlayMTU),
			}
		}
		// Fragmentation events observed but no VXLAN-sized flow corroboration.
		// ip_do_fragment is global; treat this as a weak indicator only.
		return Diagnosis{
			Verdict:            VerdictFragmentationObserved,
			FragmentationScope: FragScopeGlobalUnscoped,
			Message: fmt.Sprintf(
				"%d ip_do_fragment invocation(s) were observed while vxlan-tracer was attached. "+
					"Note: ip_do_fragment is a global kernel function — the counter fires for ALL "+
					"outgoing IP fragmentation on this host, not only VXLAN outer packets. "+
					"No oversized VXLAN outer packet was confirmed by the TC egress flow map "+
					"during this window; treat this as a weak indicator that fragmentation "+
					"occurred on this host, not as direct VXLAN blackhole evidence.",
				obs.FragEventsTotal),
		}
	}

	if obs.UnderlayMTU > 0 && obs.MaxOuterIPLen > obs.UnderlayMTU {
		return Diagnosis{
			Verdict: VerdictMTURisk,
			Message: fmt.Sprintf(
				"No PTBs or fragmentation events were observed, but a flow's outer IP packet length (%d) "+
					"exceeded the underlay MTU (%d). This is consistent with the kernel fragmenting the "+
					"outer packet (DF=0) rather than dropping it and generating a PTB (DF=1); no PTB is "+
					"expected in that case. The ip_do_fragment counter did not register this during the "+
					"observation window.",
				obs.MaxOuterIPLen, obs.UnderlayMTU),
		}
	}

	if obs.UnderlayMTU > 0 && obs.OverlayMTU > 0 {
		mtu := CheckMTU(obs.OverlayMTU, obs.UnderlayMTU)
		if !mtu.Correct {
			return Diagnosis{
				Verdict: VerdictMTUMisconfiguration,
				Message: fmt.Sprintf(
					"No PTBs, fragmentation events, or oversized traffic were observed during this run, "+
						"but the overlay MTU (%d) exceeds the safe value for the underlay MTU (%d) by "+
						"%d byte(s). This is a static configuration risk: traffic large enough to use "+
						"the full overlay MTU would trigger either fragmentation or a PTB, depending on the DF bit.",
					mtu.OverlayMTU, mtu.UnderlayMTU, mtu.ExcessBytes),
			}
		}
	}

	return Diagnosis{
		Verdict: VerdictNoIssueObserved,
		Message: "No ICMP type=3/code=4 packets, no ip_do_fragment events, no oversized traffic, and no " +
			"MTU misconfiguration were detected during this run. This does not prove the path is " +
			"healthy — it only means nothing relevant was observed while vxlan-tracer was attached.",
	}
}
