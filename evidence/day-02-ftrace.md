# evidence/day-02-ftrace.md

Raw ftrace kprobe output from ip_do_fragment during large traffic test.
Captured 2026-06-14 on Docker linuxkit 6.10.14-linuxkit aarch64.

## Setup

```
vxlan0 MTU = 1450 (stale; was correct for underlay 1500)
underlay veth MTU = 1400
max safe inner IP = 1350 (underlay 1400 - VXLAN overhead 50)
```

## Commands used to capture

```sh
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null || true
echo > /sys/kernel/tracing/trace
echo 'p:ip_do_frag ip_do_fragment' > /sys/kernel/tracing/kprobe_events
echo 1 > /sys/kernel/tracing/events/kprobes/ip_do_frag/enable
echo 1 > /sys/kernel/tracing/tracing_on

# generate 10 oversized pings (inner IP 1388B → outer IP 1438B > MTU 1400)
ip netns exec ns1 ping -c 10 -s 1360 -q 10.244.0.2

echo 0 > /sys/kernel/tracing/tracing_on
grep ip_do_frag /sys/kernel/tracing/trace | wc -l
grep ip_do_frag /sys/kernel/tracing/trace | head -20
```

## Actual output

**Event count:**
```
20
```

**First 20 events (full ring buffer):**
```
            ping-54795   [009] D.... 166350.859507: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] D.s1. 166350.859558: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] d.... 166351.877854: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] D.s1. 166351.877984: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] d.... 166352.901010: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] D.s1. 166352.901155: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] d.... 166353.927014: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] D.s1. 166353.927218: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] d.... 166354.952047: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] D.s1. 166354.952296: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] d.... 166355.978001: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] D.s1. 166355.978152: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] d.... 166357.003547: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] D.s1. 166357.003732: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] d.... 166358.028501: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] D.s1. 166358.028618: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] d.... 166359.054018: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] D.s1. 166359.054151: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] d.... 166360.080039: ip_do_frag: (ip_do_fragment+0x0/0x508)
            ping-54795   [009] D.s1. 166360.080194: ip_do_frag: (ip_do_fragment+0x0/0x508)
```

## Interpretation

- **20 events for 10 pings = 2 ip_do_fragment calls per oversized packet.**

  The outer IP packet (1438 bytes) is split into two fragments:
  - Fragment 1: 1400 bytes (fills the underlay MTU)
  - Fragment 2: 38 bytes remainder + IP header overhead

  ip_do_fragment is called once per fragment in the fragmentation chain.
  Two calls = two fragments = consistent with 1438B packet through 1400B MTU.

- **Alternating irq-off flags (D.... vs D.s1.):**
  The `D.s1.` flag indicates softirq context. The second ip_do_fragment call
  happens inside the tx path triggered by the first fragment transmission.

- **Timestamp spacing ~1 second between ping pairs:**
  Consistent with ping sending one packet per second. Each pair of consecutive
  timestamps (e.g., 166350.859507 and 166350.859558) is the two ip_do_fragment
  calls for a single ping packet. The ~50µs gap between the two calls is the
  time to process the first fragment through the tx queue.

- **Probe address: ip_do_fragment+0x0/0x508:**
  Probe fires at the function entry point (+0x0). Function size is 0x508 = 1288 bytes
  of compiled machine code — a substantial function, consistent with it being
  non-inlined and kprobeable.

## Conclusion

`ip_do_fragment` fires reliably and consistently when oversized outer VXLAN packets
encounter the underlay MTU limit. The raw ftrace interface confirms the hook point
is viable. The bpftrace probe (spikes/bpftrace/ip_do_fragment.bt) targets this same
symbol. When bpftrace 0.16+ is available, it will provide skb->len and dev->mtu
values in addition to the raw event count.
