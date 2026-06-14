# evidence/day-04-ptb-suppression.md

PTB suppression detection proof: TC ingress > 0, icmp_rcv == 0 with iptables DROP.
Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.

---

## Setup

- `tc_ingress_eth0` attached to veth1 ingress in ns1 (TC sched_cls, jited)
- kprobe/icmp_rcv attached globally via probe_attach (jited 192B, map icmp_rcv_total)
- iptables DROP rule active in ns1 for ICMP type 3 code 4

### Programs attached

```
TC ingress: veth1 ingress → tc_ingress_eth0.bpf.o:[tc]  direct-action  jited
kprobe:     kernel icmp_rcv → kprobe_icmp_rcv            jited 192B
```

### Maps active

```
89: hash   ptb_ingress_cou  (TC ingress per-VTEP-pair counts)
90: array  ptb_ingress_tot  (TC ingress global total)
91: array  icmp_rcv_total   (kprobe/icmp_rcv global total)
```

---

## iptables rule in ns1 BEFORE injection

```
Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
num   pkts bytes target  prot opt  in  out  source       destination
1        0     0 DROP    icmp --   *   *    0.0.0.0/0    0.0.0.0/0    icmptype 3 code 4
```

Rule 1: DROP all ICMP fragmentation-needed (type=3 code=4) packets. Counter starts at 0/0.

---

## Map state BEFORE injection

```
ptb_ingress_total:  {"key": 0, "value": 0}
icmp_rcv_total:     {"key": 0, "value": 0}
```

---

## Injection

```sh
ip netns exec ns2 python3 spikes/inject_ptb.py \
  --src 192.168.100.2 --dst 192.168.100.1 \
  --dev veth2 --next-hop-mtu 1400 --count 5
# 5 PTBs sent from ns2 to ns1
```

---

## iptables counters AFTER injection

```
Chain INPUT (policy ACCEPT 0 packets, 0 bytes)
num   pkts bytes target  prot opt  in  out  source       destination
1        5   280 DROP    icmp --   *   *    0.0.0.0/0    0.0.0.0/0    icmptype 3 code 4
```

**5 packets, 280 bytes dropped** by the iptables rule. The rule matched all 5 injected
PTBs (each ~56 bytes). The DROP action discards the packet before it reaches `icmp_rcv`.

---

## Map state AFTER injection (suppressed)

### ptb_ingress_total (TC ingress, PRE-netfilter)

```json
[{"key": 0, "value": 5}]
```

TC ingress BPF counted 5 PTBs arriving at veth1 BEFORE netfilter INPUT.

### ptb_ingress_counts (per VTEP pair, PRE-netfilter)

```json
[{
    "key": {
        "ptb_src_ip": 40151232,
        "ptb_dst_ip": 23374016
    },
    "value": {
        "first_seen_ns": 172863927125433,
        "last_seen_ns": 172864497844475,
        "ptb_count": 5,
        "next_hop_mtu": 1400,
        "pad": 0
    }
}]
```

- VTEP pair: 192.168.100.2 → 192.168.100.1 (ns2 → ns1)
- ptb_count: 5 ✓
- next_hop_mtu: 1400 ✓

### icmp_rcv_total (POST-netfilter, kprobe)

```json
[{"key": 0, "value": 0}]
```

**icmp_rcv_total = 0**. The kprobe on `icmp_rcv` never fired. The 5 PTBs were
dropped by iptables before `icmp_rcv` could process them.

---

## Suppression verdict

```
ptb_ingress_total = 5   (TC ingress: PTBs arrived before netfilter)
icmp_rcv_total    = 0   (kprobe: no PTBs reached icmp_rcv)
iptables drops    = 5   (all 5 matched the DROP rule)

RESULT: PTB SUPPRESSED — TC ingress > 0, icmp_rcv == 0
```

This is the core diagnostic claim of vxlan-tracer, proven in a lab environment.

---

## Combined evidence table (both test runs)

| Scenario | ptb_ingress_total | icmp_rcv_total | iptables drops | Verdict |
|----------|-------------------|----------------|----------------|---------|
| No DROP rule (Commit 5) | 5 | 5 | 0 | NOT suppressed |
| DROP rule active (Commit 6) | 5 | 0 | 5 | **SUPPRESSED** |

The two runs together prove:
1. When iptables is clean, PTBs reach `icmp_rcv` (no suppression, count matches)
2. When iptables drops ICMP fragmentation-needed, `icmp_rcv` never fires
3. The delta (`ptb_ingress_total - icmp_rcv_total`) is the suppression count

---

## What this confirms about the kernel path

```
NIC → TC ingress (clsact) → ip_rcv → netfilter INPUT → icmp_rcv
                 ↑                          ↓
        BPF hook: sees PTBs        iptables DROP rule fires here
        before netfilter           before icmp_rcv is called
```

The TC ingress hook fires before `ip_rcv` and before `netfilter INPUT`. Any
iptables rule in the INPUT chain is evaluated AFTER TC ingress but BEFORE
`icmp_rcv`. Packets dropped by iptables never reach `icmp_rcv`.

---

## What remains to be proven in production

This test uses synthetic PTBs injected from a controlled namespace (ns2) with
full control over the packet stream. In production:

- PTBs arrive from cloud fabric routers (real external PTBs)
- The TC ingress hook runs on the actual underlay interface (not veth1)
- iptables rules suppressing PTBs are typically installed by kube-proxy or
  network policy controllers
- The detection signal is the same; the mechanism is proven here

The inner 5-tuple of the affected flow is NOT available from the ICMP PTB payload
(PTB contains only outer IP+UDP headers). vxlan-tracer reports at VTEP granularity
only. See docs/forbidden-claims.md, claim #4.
