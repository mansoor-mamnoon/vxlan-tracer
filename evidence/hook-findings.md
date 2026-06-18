# evidence/hook-findings.md

Documents the hook placement investigation: what was tested, what was confirmed,
what remains unverified, and any corrections made to the original architecture.

## Correction 1: XDP egress does not exist

**Original claim:** "dual XDP on vxlan0 + eth0"
**Correct architecture:** TC egress on vxlan0; no XDP on egress path
**Reason:** XDP fires on the ingress (receive) path only, after NIC DMA. There
is no XDP egress hook. `XDP_TX` retransmits the current received packet back;
it is not an observation point for outgoing traffic.
**Status:** Corrected in docs/architecture.md and docs/hook-model.md.
**Source:** Kernel documentation + review of kernel/bpf/net code path.

## Correction 2: TC egress on eth0 misses DF=1 drops

**Original assumption:** TC egress on eth0 could observe oversized packet drops
**Correct behavior:** For DF=1 packets, the drop happens inside
`ip_finish_output2` before control returns to TC egress. TC egress fires on the
path to the NIC, after the drop decision has already been made. For DF=1
oversized packets, TC egress on eth0 sees no traffic at all.
**Implication:** TC egress on eth0 is only useful in DF=0 configurations for
confirming outer frame sizes. Marked optional/debug.
**Status:** Documented in docs/hook-model.md.

## Correction 3: DF=0 is the Linux VXLAN default

**Original assumption:** ICMP PTB would be generated for oversized outer packets
**Correct behavior:** Linux VXLAN defaults to DF=0 on the outer IP header.
Oversized outer packets are fragmented by `ip_do_fragment`, not dropped. No
ICMP PTB is generated. The ICMP PTB path only fires when `df set` is configured.
**Implication:** `ip_do_fragment` kprobe MUST be in V0. Without it, the tool
produces zero output on default Flannel/Calico VXLAN deployments.
**Status:** ip_do_fragment kprobe included in V0 scope (docs/roadmap.md).

## Correction 4: ICMP PTB does not contain inner 5-tuple

**Original assumption:** inner flow could be identified from ICMP PTB
**Correct behavior:** ICMP PTB payload contains:
  - 8 bytes ICMP header
  - 20 bytes embedded original outer IP header
  - 8 bytes embedded original outer UDP header (first 8 bytes = UDP header)
The inner IP header and inner TCP/UDP headers are NOT present.
**Implication:** Correlation from PTB to inner flows is at VTEP IP granularity
only. Output must say "active flows to vtep X" not "flow Y is affected."
**Status:** Documented in docs/architecture.md and docs/forbidden-claims.md.

## Correction 5: tcpdump AF_PACKET also fires before netfilter

**Original claim:** "tcpdump cannot see suppressed PTBs"
**Correct behavior:** tcpdump via AF_PACKET (libpcap raw socket) fires before
netfilter on ingress and CAN see incoming ICMP PTBs that iptables subsequently
drops.
**Correct differentiation:** The unique value of vxlan-tracer's TC ingress +
icmp_rcv pair is the COUNT COMPARISON — tcpdump shows PTBs arrive but cannot
measure whether icmp_rcv was subsequently invoked. vxlan-tracer provides both
numbers simultaneously.
**Status:** Documented in docs/forbidden-claims.md, claim #8.

## Day 2 findings (Docker linuxkit 6.10.14-linuxkit aarch64)

### Finding 1: ip_do_fragment IS a T symbol and fires as expected

```
ffff800080ff71d8 T ip_do_fragment
```

Raw ftrace kprobe confirmed: 20 ip_do_fragment events for 10 large pings.
0 events for small pings. The hook is reliable and non-inlined on this kernel.

### Finding 2: icmp_send is NOT a T symbol on kernel 6.10.14

icmp_send does not appear as a T symbol in /proc/kallsyms. Exists only as:
```
__traceiter_icmp_send  T
__probestub_icmp_send  T
__bpf_trace_icmp_send  t
```
Use `tracepoint:net:icmp_send` instead of `kprobe:icmp_send` on this kernel.
(tracepoint provides type+code but not next_hop_mtu — see icmp_send.bt comments)

### Finding 3: BTF is present on linuxkit

`/sys/kernel/btf/vmlinux` exists (6.2 MB). fentry programs are supported.

### Finding 4: locally-generated PTBs bypass netfilter INPUT

For the DF=1 scenario (kernel generating PTBs for its own packets), the ICMP
PTBs do not traverse the INPUT chain. iptables DROP rule shows 0 counter hits.
The suppression detection is designed for externally-arriving PTBs (cloud fabric).

### Finding 5: kernel 6.10+ enforces correct vxlan0 MTU at creation time

`ip link set vxlan0 mtu 1500` returns `RTNETLINK answers: Invalid argument` when
underlay MTU is 1500. Kernel enforces max vxlan0 MTU = underlay - overhead.
Alternative topology: reduce underlay MTU after vxlan0 creation.

## Updated hook confidence table (post-Day 2)

| Hook | Verified how | Confidence |
|------|-------------|------------|
| ip_do_fragment symbol present on 6.10.14 | /proc/kallsyms confirmed | **CONFIRMED** |
| ip_do_fragment fires for DF=0 oversized outer | ftrace kprobe: 20 events/10 pings | **CONFIRMED** |
| ip_do_fragment not inlined on 6.10.14 | ftrace fires at +0x0 | **CONFIRMED** |
| icmp_send NOT a T symbol on 6.10.14 | /proc/kallsyms negative | **CONFIRMED** |
| icmp_rcv IS a T symbol on 6.10.14 | /proc/kallsyms confirmed | **CONFIRMED** |
| BTF vmlinux present on linuxkit | file size 6.2MB confirmed | **CONFIRMED** |
| TC egress vxlan0 fires before VXLAN encap | flow_state map populated; pkt_count=6 for 6 pings | **CONFIRMED** |
| TC ingress eth0 fires before netfilter | ptb_count=5 after 5 synthetic PTBs from ns2 | **CONFIRMED** |
| icmp_rcv fires after netfilter INPUT | Kernel documentation | High (unrun) |
| bpftrace can read skb->dev->name in kprobe | Not verified (bpftrace broken on linuxkit) | Unknown |

## Day 3 findings (Docker linuxkit 6.10.14-linuxkit aarch64)

### Finding 6: TC egress on vxlan0 fires before VXLAN encapsulation

flow_state map populated after 6 ICMP echo packets (3 small + 3 large):
- max_inner_ip_len=1428 for 1400-byte payload pings ✓
- max_outer_ip_len=1478 (= 1428 + 50) ✓
Confirms the hook fires on inner packets before the kernel adds VXLAN headers.

### Finding 7: TC ingress on veth1 fires before netfilter

ptb_ingress_counts[{192.168.100.2 → 192.168.100.1}].ptb_count = 5 after
5 synthetic PTBs injected from ns2. ptb_ingress_total = 5. All pass TC_ACT_OK.

### Finding 8: scapy ICMP type=3 'unused' vs 'nexthopmtu' field layout

In scapy, ICMP type=3 defines two separate ShortFields:
- `unused` (bytes 4-5): maps to icmph->un.frag.__unused
- `nexthopmtu` (bytes 6-7): maps to icmph->un.frag.mtu ← what BPF reads

inject_ptb.py was using `unused=MTU` instead of `nexthopmtu=MTU`, resulting in
next_hop_mtu=0 in the BPF map. Fixed in Commit 6.

### Finding 9: bpftool binary location on ubuntu:22.04 arm64

`linux-tools-5.15.0-181-generic` installs bpftool to two paths:
- `/usr/lib/linux-tools-5.15.0-181/bpftool` (actual binary)
- `/usr/lib/linux-tools/5.15.0-181-generic/bpftool` (symlink or alternate path)
`/usr/sbin/bpftool` is a wrapper that checks running kernel version and fails
on kernel 6.10.14. Use the versioned path directly.

## Day 4 findings (Docker linuxkit 6.10.14-linuxkit aarch64)

### Finding 10: icmp_rcv IS a T symbol and attaches via kprobe

```
ffff800080xxxxxx T icmp_rcv   (confirmed in /proc/kallsyms Day 2)
```

libbpf probe_attach.c attached kprobe/icmp_rcv via `bpf_program__attach_kprobe`.
bpftool confirmed: `182: kprobe name kprobe_icmp_rcv jited 192B map_ids 87`.

### Finding 11: icmp_rcv fires AFTER netfilter INPUT — proven by counter experiment

Without iptables DROP: ptb_ingress_total=5, icmp_rcv_total=5 (both match).
With iptables DROP on icmptype 3 code 4: ptb_ingress_total=5, icmp_rcv_total=0.
The DROP rule in netfilter INPUT prevents icmp_rcv from being called.

This proves the hook ordering:
```
TC ingress (pre-nf) → netfilter INPUT → icmp_rcv (post-nf)
```

### Finding 12: CO-RE not needed for icmp_rcv kprobe counting

kprobes.bpf.c does not access any struct fields from the skb. It only
increments a counter. No vmlinux.h, no CO-RE annotations. Compiled without
`-D__TARGET_ARCH_arm64` or BTF-related flags. This keeps the BPF simpler.

Caveat: in production, the kprobe would need to parse the skb to filter for
ICMP type=3 code=4 only, which DOES require CO-RE or a manual offset table.
Deferred to Day 5.

### Finding 13: stale vxlan0 MTU persists after underlay MTU reduction

Kernel 6.10.14 sets vxlan0 MTU = min(underlay-50, requested) at creation time.
If the underlay MTU is later reduced (e.g., via `ip link set veth1 mtu 1400`),
the vxlan0 MTU is NOT automatically updated. The stale MTU remains at 1450.

This is the real-world VXLAN blackhole condition: containers see overlay MTU
as 1450, send packets that become 1438-byte outer packets, which exceed the
1400-byte underlay MTU and are silently fragmented (DF=0) or dropped (DF=1).

### Finding 14: ip_do_fragment fires in both namespaces for each oversized ping

The ftrace kprobe on ip_do_fragment is global (all namespaces). For a 3-ping
test with ns1→ns2: 3 events from ns1 (send path) + 3 events from ns2 (reply
path) = 6 events total. Both sides have underlay MTU=1400 and both fragment.

## Day 5 findings (Docker linuxkit 6.10.14-linuxkit aarch64)

### Finding 15: apt's libbpf0/libbpf-dev is too old to parse this kernel's BTF

The `icmp_rcv` CO-RE kprobe (filtering to ICMP type=3/code=4 via
`preserve_access_index` on a partial `sk_buff` struct) requires a libbpf new
enough to relocate CO-RE accesses against this kernel's `/sys/kernel/btf/vmlinux`
encoding. apt's `libbpf0`/`libbpf-dev` on ubuntu:22.04 is v0.5.0, which fails to
parse this kernel's BTF and aborts relocation at load time. **Fix:** built
libbpf v1.4.0 from source (`make -C src BUILD_STATIC_ONLY=y`) and linked against
that instead. This is a reusable finding for anyone doing CO-RE work against
recent kernels (6.x) from an ubuntu:22.04 base image — the distro libbpf is too
old and the failure mode (BTF parse error, not a missing-symbol error) is easy
to misattribute to the BPF program itself rather than the loader library.

### Finding 16: `ip netns exec` detaches the bpffs mount, breaking BPF_OBJ_PIN

`ip netns exec <ns> <cmd>` internally calls `unshare(CLONE_NEWNS)` and then
unmounts/remounts a fresh `sysfs` on `/sys` inside the child process, before
running `<cmd>`. This detaches any bpffs mount that exists in the parent mount
namespace (e.g. the `/sys/fs/bpf` mount created by `scripts/setup-bpf-fs.sh`),
even though the directory is still visible from the parent shell. Any `BPF_OBJ_PIN`
syscall made by `<cmd>` then fails with `ENOENT`, with an error message
(`pin map to /sys/fs/bpf/...: no such file or directory`) that looks like a
missing-directory bug rather than a mount-namespace interaction — `ls -la` from
the parent shell shows the directory exists, which is initially misleading.

**Fix:** use `nsenter --net=/var/run/netns/<ns> -- <cmd>` instead of
`ip netns exec <ns> <cmd>` whenever the command needs to both (a) resolve
interface names inside a network namespace and (b) interact with bpffs.
`nsenter` only joins the namespaces explicitly passed as flags — with only
`--net` given, the mount namespace (and its bpffs mount) is left untouched,
while interface name lookups still resolve correctly inside the target netns.
This is a generally reusable finding beyond this project: any BPF tool that
pins maps while also needing netns-scoped interface resolution should prefer
`nsenter --net=...` over `ip netns exec` for exactly this reason.

### Finding 17: ELF program names are the C function name after SEC(), not the object file name

cilium/ebpf's `coll.Programs[name]` lookup is keyed by the actual C function
name following the `SEC("tc")` / `SEC("kprobe/...")` annotation in the BPF
source — not the `.bpf.o` file's base name. The Go loader's first attach
attempt used object-file-derived names (`tc_ingress_eth0`, `tc_egress_vxlan0`)
and failed with `program "tc_ingress_eth0" not found in object`. The actual
function names in `bpf/tc_ingress_eth0.bpf.c` / `bpf/tc_egress_vxlan0.bpf.c` /
`bpf/kprobes.bpf.c` are `tc_ingress_count_ptb`, `tc_egress_track_flow`, and
`kprobe_icmp_rcv` respectively (the kprobe name happened to already match).
**Fix:** read the actual `SEC(...)` function names from the BPF source rather
than assuming they match the file name, and use those in the loader's
`coll.Programs[...]` lookups.

## Updated hook confidence table (post-Day 5)

| Hook | Verified how | Confidence |
|------|-------------|------------|
| ip_do_fragment symbol present on 6.10.14 | /proc/kallsyms confirmed | **CONFIRMED** |
| ip_do_fragment fires for DF=0 oversized outer | ftrace kprobe: 20 events/10 pings | **CONFIRMED** |
| ip_do_fragment fires for stale-MTU scenario | ftrace kprobe: 6 events/3 pings | **CONFIRMED** |
| ip_do_fragment not inlined on 6.10.14 | ftrace fires at +0x0 | **CONFIRMED** |
| icmp_send NOT a T symbol on 6.10.14 | /proc/kallsyms negative | **CONFIRMED** |
| icmp_rcv IS a T symbol on 6.10.14 | /proc/kallsyms confirmed Day 2 | **CONFIRMED** |
| icmp_rcv attaches via libbpf kprobe | bpftool: id 182, jited 192B | **CONFIRMED** |
| icmp_rcv fires AFTER netfilter INPUT | counter experiment: unsuppressed=5/5 | **CONFIRMED** |
| iptables DROP before icmp_rcv | counter experiment: suppressed=5/0, drops=5 | **CONFIRMED** |
| PTB suppression detectable: TC>0 + icmp_rcv==0 | both probes running; lab proven | **CONFIRMED** |
| BTF vmlinux present on linuxkit | file size 6.2MB confirmed | **CONFIRMED** |
| TC egress vxlan0 fires before VXLAN encap | flow_state populated; max_outer_ip_len=1478 | **CONFIRMED** |
| TC ingress eth0 fires before netfilter | ptb_count=5 after 5 synthetic PTBs | **CONFIRMED** |
| icmp_rcv kprobe filters type=3 code=4 only | CO-RE skb parse; 0/5 for ping/PTB resp. | **CONFIRMED** (Day 5) |
| Go loader can attach TC ingress/egress + kprobe + pin maps | live attach, `tc filter show`, `ls /sys/fs/bpf/...` | **CONFIRMED** (Day 5) |
| Go CLI reads pinned maps and prints correct verdict | PTB_DELIVERED and PTB_SUPPRESSED both proven live | **CONFIRMED** (Day 5) |
| bpftrace can read skb->dev->name in kprobe | Not verified (bpftrace broken on linuxkit) | Unknown |

## Day 6 findings (Docker linuxkit 6.10.14-linuxkit aarch64)

### Finding 18: ip_do_fragment attaches via cilium/ebpf link.Kprobe() on kernel 6.10.14

`link.Kprobe("ip_do_fragment", prog)` returns a valid link with no error. The symbol
was already confirmed as T (kprobeable) in Day 2 via /proc/kallsyms; Day 6 confirms
the full loader path works end-to-end: load BPF object → get program by name → attach
kprobe → pin map → read map from Go. No libbpf version mismatch needed (cilium/ebpf
handles BTF relocation internally).

### Finding 19: -D__TARGET_ARCH_arm64 is required for any frag_kprobes.bpf.c that uses PT_REGS_PARM*

When `frag_kprobes.bpf.c` uses `PT_REGS_PARM3(ctx)` (to read the skb argument),
clang requires `-D__TARGET_ARCH_arm64` on aarch64 to resolve the macro. Without it:
```
bpf/frag_kprobes.bpf.c:93:42: error: Must specify a BPF target arch via __TARGET_ARCH_xxx
```
The count-only version (commit 2) compiled without this flag because it did not use any
`PT_REGS_PARM*` macros. As soon as argument access was added (commit 7), the flag became
mandatory. Lesson: add `-D__TARGET_ARCH_arm64` to any BPF compile command that may
acquire argument access in the future; it is harmless when the macros are not used.

### Finding 20: CO-RE sk_buff.len relocation resolves correctly from linuxkit BTF

`BPF_CORE_READ(skb, len)` with a partial `struct sk_buff { unsigned int len; }
__attribute__((preserve_access_index))` resolves successfully at load time from
`/sys/kernel/btf/vmlinux` on kernel 6.10.14-linuxkit. The program loaded without
CO-RE relocation error (evidenced by the binary printing a verdict rather than an
error). This confirms that the same CO-RE pattern used in kprobes.bpf.c (sk_buff
type=3/code=4 filtering, Day 5) also works for ip_do_fragment skb->len reading.

### Finding 21: ip_do_fragment fires in both the sending and receiving namespace

For each large VXLAN ping, ip_do_fragment is called once in the sending netns
(outer packet exceeds underlay MTU → fragment before forwarding) and once in the
receiving netns (ICMP echo reply also exceeds underlay MTU on the return path).
3 large pings from ns1 to ns2 produced 6 ip_do_fragment events total (3 send + 3
reply). The kprobe is global (not namespace-scoped), so this behavior is inherent.
The verdict message correctly says "at least one outgoing IP packet" rather than
claiming to count per-flow or per-direction.

### Finding 22: TC filter "file exists" error when binary is restarted in same container

When the Go binary exits, it detaches kprobes (`att.Close()` calls `fragKprobeLink.Close()`
and `kprobeLink.Close()`) but deliberately leaves TC filters in place. If the binary is
invoked a second time in the same container without tearing down the network namespace,
the second attempt to add a TC clsact qdisc/filter on veth1/vxlan0 fails with:
```
attach tc ingress on veth1: file exists
```
This is by design (TC filter persistence allows map reading after binary exit), but
it means sequential test runs in the same container require either: (a) explicit
teardown/setup of the netns between runs, or (b) use of separate Docker containers
(as done for the commit 9 JSON tests). Documented; not a bug.

## Updated hook confidence table (post-Day 6)

| Hook | Verified how | Confidence |
|------|-------------|------------|
| ip_do_fragment symbol present on 6.10.14 | /proc/kallsyms confirmed | **CONFIRMED** |
| ip_do_fragment fires for DF=0 oversized outer | ftrace kprobe: 20 events/10 pings (Day 2) | **CONFIRMED** |
| ip_do_fragment fires for stale-MTU scenario | ftrace kprobe: 6 events/3 pings (Day 2/5) | **CONFIRMED** |
| ip_do_fragment not inlined on 6.10.14 | ftrace fires at +0x0 | **CONFIRMED** |
| ip_do_fragment kprobe via cilium/ebpf loader | link.Kprobe() success; map pinned | **CONFIRMED** (Day 6) |
| ip_do_fragment kprobe counter increments for large traffic | frag_events_total=6 for 3 large pings | **CONFIRMED** (Day 6) |
| ip_do_fragment CO-RE skb->len read resolves from linuxkit BTF | binary loaded without CO-RE error; correct verdict | **CONFIRMED** (Day 6) |
| icmp_send NOT a T symbol on 6.10.14 | /proc/kallsyms negative | **CONFIRMED** |
| icmp_rcv IS a T symbol on 6.10.14 | /proc/kallsyms confirmed Day 2 | **CONFIRMED** |
| icmp_rcv attaches via libbpf kprobe | bpftool: id 182, jited 192B | **CONFIRMED** |
| icmp_rcv fires AFTER netfilter INPUT | counter experiment: unsuppressed=5/5 | **CONFIRMED** |
| iptables DROP before icmp_rcv | counter experiment: suppressed=5/0, drops=5 | **CONFIRMED** |
| PTB suppression detectable: TC>0 + icmp_rcv==0 | both probes running; lab proven | **CONFIRMED** |
| BTF vmlinux present on linuxkit | file size 6.2MB confirmed | **CONFIRMED** |
| TC egress vxlan0 fires before VXLAN encap | flow_state populated; max_outer_ip_len=1478 | **CONFIRMED** |
| TC ingress eth0 fires before netfilter | ptb_count=5 after 5 synthetic PTBs | **CONFIRMED** |
| icmp_rcv kprobe filters type=3 code=4 only | CO-RE skb parse; 0/5 for ping/PTB resp. | **CONFIRMED** (Day 5) |
| Go loader can attach TC ingress/egress + kprobe + pin maps | live attach, tc filter show, ls bpffs | **CONFIRMED** (Day 5) |
| Go CLI reads pinned maps and prints correct verdict | PTB_DELIVERED and PTB_SUPPRESSED proven live | **CONFIRMED** (Day 5) |
| VXLAN_FRAGMENTATION_OBSERVED verdict driven by BPF counter | frag_events_total=6, verdict correct | **CONFIRMED** (Day 6) |
| JSON output correct for both frag and PTB paths | two separate Docker containers; exit 0 | **CONFIRMED** (Day 6) |
| bpftrace can read skb->dev->name in kprobe | Not verified (bpftrace broken on linuxkit) | Unknown |

## Day 8 findings (Docker linuxkit 6.10.14-linuxkit aarch64)

### Finding 23: bpf_get_netns_cookie NOT available for BPF_PROG_TYPE_KPROBE or BPF_PROG_TYPE_SCHED_CLS

Verifier error (cilium/ebpf loader, BPF object compiled and loaded):
```
program probe_netns_cookie_kprobe: load program: invalid argument:
  program of this type cannot use helper bpf_get_netns_cookie#122
```
Same error for SCHED_CLS. /proc/kallsyms shows wrappers only for socket-type
programs (sk_msg, sock, sock_addr, sock_ops, sockopt). This is a kernel design
decision: the helper's allowed_prog_types does not include kprobe or TC.
Netns-cookie-based scoping of ip_do_fragment is not feasible on any kernel
where this restriction holds (6.10.14 and likely all current mainline).

### Finding 24: bpf_probe_read_kernel is permitted in kprobe programs

spikes/probe_frag_scope.bpf.c compiled and loaded without verifier rejection.
bpf_probe_read_kernel is available in BPF_PROG_TYPE_KPROBE (expected behavior;
it's the standard way to read kernel memory from kprobe programs).

### Finding 25: skb->network_header at ip_do_fragment does not consistently point to outer IP header

spikes/probe_frag_scope.bpf.c reads head + network_header + 9 (IP proto field).
With route MTU cache active: ip_proto=1 (ICMP), skb->len=1388 → points to inner
IP header. Without cache (first run): 2 calls saw ip_proto=17 (UDP), dport=4789.
The inconsistency is caused by the VXLAN driver's skb construction varying with
route cache state. Header parsing at ip_do_fragment is not reliable for VXLAN
scoping; two-signal corroboration (Option 5) is the v0 strategy.

### Finding 26: ip route flush cache is effective on 6.10.14-linuxkit

After fragmentation: `ip route show cache` shows `mtu 1350` for vxlan0 routes.
After `ip route flush cache`: cache is empty (confirmed with ip route show cache).
Next large pings retrigger full-size outer packets (1438B); fragmentation_scope
returns to global_corroborated. The man page warning about flush being "mostly
obsolete" does not apply on 6.10.14-linuxkit — flush is effective.

## Updated hook confidence table (post-Day 8)

| Hook | Verified how | Confidence |
|------|-------------|------------|
| ip_do_fragment symbol present on 6.10.14 | /proc/kallsyms confirmed | **CONFIRMED** |
| ip_do_fragment fires for DF=0 oversized outer | ftrace kprobe: 20 events/10 pings | **CONFIRMED** |
| ip_do_fragment fires for stale-MTU scenario | ftrace kprobe: 6 events/3 pings | **CONFIRMED** |
| ip_do_fragment kprobe via cilium/ebpf loader | link.Kprobe() success; map pinned | **CONFIRMED** |
| ip_do_fragment CO-RE skb->len read resolves | binary loaded without CO-RE error | **CONFIRMED** |
| bpf_get_netns_cookie in kprobe: NOT available | verifier: "cannot use helper" #122 | **CONFIRMED (Day 8)** |
| bpf_get_netns_cookie in sched_cls: NOT available | same verifier error | **CONFIRMED (Day 8)** |
| bpf_probe_read_kernel in kprobe: available | probe_frag_scope compiled + loaded | **CONFIRMED (Day 8)** |
| skb->network_header at ip_do_fragment: inconsistent | sometimes inner, sometimes outer IP header | **CONFIRMED (Day 8)** |
| Two-signal corroboration: 5/5 scenarios pass | automated scenario runner, 2 runs | **CONFIRMED (Day 8)** |
| ip route flush cache: clears PMTU on 6.10.14 | cache empty after flush; large pings retrigger | **CONFIRMED (Day 8)** |
| icmp_rcv IS a T symbol on 6.10.14 | /proc/kallsyms confirmed | **CONFIRMED** |
| icmp_rcv fires AFTER netfilter INPUT | counter experiment | **CONFIRMED** |
| iptables DROP before icmp_rcv | counter experiment | **CONFIRMED** |
| bpftrace can read skb->dev->name in kprobe | Not verified (bpftrace broken on linuxkit) | Unknown |

## Day 9 findings (Lima VM — Ubuntu 22.04 5.15.0-181-generic aarch64)

### Finding 27: All five verdict scenarios pass on 5.15.0-181-generic

First validation on a non-linuxkit kernel. 5/5 scenarios pass with identical
JSON field values to 6.10.14-linuxkit:
- frag_events_total=6, frag_max_skb_len=1438, max_outer_ip_len=1438 (same)
- fragmentation_scope=global_corroborated (same)
- ptb_ingress_total=5, icmp_rcv_total=5 (delivered) and 0 (suppressed) (same)
BPF verifier accepted all four objects. CO-RE BTF resolved correctly.
Evidence: evidence/day-09-vm-scenarios.md

### Finding 28: bpf_get_netns_cookie UNSUPPORTED on 5.15.0-181-generic kprobe/sched_cls

Same practical result as 6.10.14-linuxkit; error message differs:
- 5.15.0: "unknown func bpf_get_netns_cookie#122" (helper unrecognized for this prog type)
- 6.10.14: "program of this type cannot use helper bpf_get_netns_cookie#122"
/proc/kallsyms: same pattern — wrappers exist only for socket-type programs.
Two-signal corroboration strategy confirmed applicable to 5.15.
Evidence: evidence/day-09-vm-helper-scope.md

### Finding 29: skb->network_header at ip_do_fragment MORE severely inconsistent on 5.15.0

On 6.10.14-linuxkit: first run (before route cache) sometimes showed ip_proto=17/dport=4789 (outer IP).
On 5.15.0-181-generic: even first run shows ip_proto=1 (ICMP), udp_dport=0 — inner IP.
The outer VXLAN IP header is never visible via network_header on 5.15 in this test.
This strengthens the Day 8 decision to defer header parsing and use two-signal corroboration.
Evidence: evidence/day-09-vm-helper-scope.md

### Finding 30: ip route flush cache effective on 5.15.0-181-generic

Second-run scenario (scenario 5) passed with fragmentation_scope=global_corroborated
after ip route flush cache in both namespaces. Same behavior as 6.10.14-linuxkit.
Evidence: evidence/day-09-vm-scenarios.md (scenario 5 result)

### Finding 31: bpftool is kernel-matched on Ubuntu 22.04 VM

`/usr/lib/linux-tools/5.15.0-181-generic/bpftool v5.15.199` — matches running kernel.
On linuxkit, bpftool was a mismatched wrapper (v5.15.199 on kernel 6.10.14).
Ubuntu's `linux-tools-$(uname -r)` package provides the kernel-matched bpftool.
No functional impact on vxlan-tracer (does not use bpftool at runtime) but useful
for map inspection during debugging.

## Updated hook confidence table (post-Day 9)

| Hook | Verified how | Confidence |
|------|-------------|------------|
| ip_do_fragment symbol present | 6.10.14 and 5.15.0 /proc/kallsyms | **CONFIRMED (both kernels)** |
| ip_do_fragment fires for DF=0 oversized outer | 5/5 scenario pass on both kernels | **CONFIRMED (both kernels)** |
| ip_do_fragment kprobe via cilium/ebpf loader | scenario run on both kernels | **CONFIRMED (both kernels)** |
| ip_do_fragment CO-RE skb->len resolves | frag_max_skb_len=1438 on both kernels | **CONFIRMED (both kernels)** |
| bpf_get_netns_cookie in kprobe: NOT available | "unknown func" on 5.15; "cannot use" on 6.10 | **CONFIRMED (both kernels)** |
| bpf_get_netns_cookie in sched_cls: NOT available | same errors | **CONFIRMED (both kernels)** |
| skb->network_header at ip_do_fragment: inconsistent | inner IP seen on both; worse on 5.15 | **CONFIRMED (both kernels)** |
| Two-signal corroboration: 5/5 pass | scenario runner on both kernels | **CONFIRMED (both kernels)** |
| ip route flush cache: clears PMTU | second-run scenario pass on both kernels | **CONFIRMED (both kernels)** |
| icmp_rcv IS a T symbol | 6.10.14 and 5.15.0 /proc/kallsyms | **CONFIRMED (both kernels)** |
| icmp_rcv fires AFTER netfilter INPUT | counter experiment + PTB scenarios | **CONFIRMED (both kernels)** |
| bpftrace can read skb->dev->name in kprobe | Not verified (bpftrace broken on linuxkit; not tried on 5.15) | Unknown |
