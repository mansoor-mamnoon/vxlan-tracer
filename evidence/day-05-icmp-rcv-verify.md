# evidence/day-05-icmp-rcv-verify.md

Day 5 Commit 2: live verification of the filtered `icmp_rcv` counter
(`bpf/kprobes.bpf.c`, Commit 1) — confirms normal ICMP traffic does NOT
increment it, and that injected ICMP PTBs (type=3 code=4) DO.

Environment: Docker ubuntu:22.04, kernel 6.10.14-linuxkit aarch64.
Loader: `spikes/probe_attach.c` linked against libbpf v1.4.0 (built from
source per `evidence/day-05-icmp-rcv-filter.md`), modified to poll and
print `icmp_rcv_total` every 2 seconds instead of a single before/after read.

---

## Test sequence

1. Build libbpf v1.4.0, compile `bpf/kprobes.bpf.o`, compile
   `probe_attach_new` against the new libbpf. All exit 0.
2. `bash scripts/setup-netns.sh` — standard ns1/ns2/vxlan0 lab topology
   (underlay 192.168.100.1/192.168.100.2, vxlan0 10.244.0.1/10.244.0.2).
3. Attach the filtered kprobe in the background, polling every 2s for 36s.
4. At t≈3s: send 5 normal ICMP echo requests, `ns1 → ns2` underlay
   (`ip netns exec ns1 ping -c 5 192.168.100.2`).
5. At t≈11s: inject 5 synthetic ICMP PTBs (type=3 code=4),
   `ns2 → ns1` underlay, no iptables DROP rule active.
6. Let the loader finish its full 36s window, then tear down the lab.

---

## Result: normal ping does NOT increment the filtered counter

```
probe_attach: kprobe/icmp_rcv attached to kernel icmp_rcv
probe_attach: icmp_rcv_total at attach = 0
probe_attach: polling every 2s for 36 seconds (inject traffic from another shell)...
probe_attach: t=2s icmp_rcv_total = 0
```

```
$ ip netns exec ns1 ping -c 5 -W 2 192.168.100.2
PING 192.168.100.2 (192.168.100.2) 56(84) bytes of data.
64 bytes from 192.168.100.2: icmp_seq=1 ttl=64 time=0.117 ms
64 bytes from 192.168.100.2: icmp_seq=2 ttl=64 time=0.156 ms
64 bytes from 192.168.100.2: icmp_seq=3 ttl=64 time=0.156 ms
64 bytes from 192.168.100.2: icmp_seq=4 ttl=64 time=0.159 ms
64 bytes from 192.168.100.2: icmp_seq=5 ttl=64 time=0.044 ms
5 packets transmitted, 5 received, 0% packet loss, time 4122ms
```

Counter after the 5 pings completed (which generate both ICMP echo request
AND echo reply traffic through `icmp_rcv`, type 8 and type 0 — neither is
type 3 code 4):

```
probe_attach: t=4s icmp_rcv_total = 0
probe_attach: t=6s icmp_rcv_total = 0
probe_attach: t=8s icmp_rcv_total = 0
probe_attach: t=10s icmp_rcv_total = 0
```

Counter stayed at **0** through 10 seconds covering all 5 ping round trips.
This is the behavior the Day 4 unfiltered counter could NOT exhibit — Day 4
would have counted these echo/reply calls as if they were PTBs.

---

## Result: 5 injected PTBs increment the counter to exactly 5

```
$ ip netns exec ns2 python3 spikes/inject_ptb.py \
    --src 192.168.100.2 --dst 192.168.100.1 --dev veth2 \
    --next-hop-mtu 1400 --count 5
Injecting 5 synthetic ICMP PTB(s):
  src=192.168.100.2 → dst=192.168.100.1
  next_hop_mtu=1400
  embedded: 192.168.100.1→192.168.100.2 UDP dport=4789 (outer IP len=1438 DF=1)
  interface: veth2
  sent 1/5
  sent 2/5
  sent 3/5
  sent 4/5
  sent 5/5
Done. Sent 5 ICMP PTB(s).
```

```
probe_attach: t=12s icmp_rcv_total = 5
probe_attach: t=14s icmp_rcv_total = 5
probe_attach: t=16s icmp_rcv_total = 5
...
probe_attach: t=36s icmp_rcv_total = 5
probe_attach: icmp_rcv_total at detach = 5
```

The counter jumped from 0 to exactly 5 within the first 2-second poll
interval after injection (t=10s → t=12s), then stayed at 5 for the
remaining ~24 seconds of the run — no drift, no double-counting, no
iptables DROP rule active so every injected PTB reached `icmp_rcv`.

---

## Full raw log

See `evidence/day-05-icmp-rcv-verify.log` for the complete, unedited
terminal output of this test run (setup, attach, ping, injection, teardown).

---

## What is proven

1. The CO-RE field relocation for `skb->data` resolves correctly at load
   time against kernel 6.10.14-linuxkit, using libbpf v1.4.0.
2. The type==3/code==4 filter is correct: 5 ICMP echo requests + 5 ICMP
   echo replies (10 icmp_rcv invocations of non-PTB types) produced ZERO
   increments.
3. The filter correctly counts real PTBs: 5 injected type=3/code=4 packets
   produced exactly 5 increments, with no drop and no overcount.
4. `icmp_rcv_total` is now a meaningful post-netfilter PTB counter, not a
   lab-only all-ICMP counter. The Day 4 caveat ("valid only in isolated lab
   traffic") no longer applies.

## What remains unproven

- Suppression detection (TC ingress > 0 while filtered icmp_rcv == 0) has
  not yet been re-run with this filtered counter and an iptables DROP rule.
  Day 4 proved this with the unfiltered counter; re-proving it with the
  filtered counter is implied by this result (DROP still removes the
  packet before icmp_rcv regardless of what the kprobe does with the
  bytes it never sees) but has not been independently re-tested this day.
- Map pinning, Go loader, Go reader, and diagnosis verdicts: all later
  commits.
