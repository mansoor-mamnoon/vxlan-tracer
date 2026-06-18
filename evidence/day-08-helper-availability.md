# Day 8 commit 1: BPF helper availability probe — bpf_get_netns_cookie

## Objective

Determine whether `bpf_get_netns_cookie` can be called from:
1. `BPF_PROG_TYPE_KPROBE` (for scoping ip_do_fragment to a specific netns)
2. `BPF_PROG_TYPE_SCHED_CLS` (for scoping TC egress events)

If unavailable, ifindex/netns scoping of ip_do_fragment must use a different
approach or be deferred.

## Test environment

```
Kernel: 6.10.14-linuxkit #1 SMP Thu Aug 14 19:26:13 UTC 2025 aarch64
OS image: ubuntu:22.04 Docker container (--privileged)
clang: Ubuntu clang version 14.0.0-1ubuntu1.1
Go loader: cilium/ebpf v0.13.2 (spikes/probe_helper/main.go)
```

## BPF probe programs

Two minimal BPF programs were written and compiled:
- `spikes/probe_netns_cookie_kprobe.bpf.c` — calls `bpf_get_netns_cookie(NULL)`
  in a `SEC("kprobe/ip_do_fragment")` section
- `spikes/probe_netns_cookie_cls.bpf.c` — calls `bpf_get_netns_cookie(skb)`
  in a `SEC("tc")` section

Both compiled without error (clang exit=0).

## Load test results (cilium/ebpf Go loader)

```
  [kprobe] loading program "probe_netns_cookie_kprobe" (section "kprobe/ip_do_fragment")
  [kprobe] FAILED: program probe_netns_cookie_kprobe: load program: invalid argument:
           program of this type cannot use helper bpf_get_netns_cookie#122 (23 line(s) omitted)

  [sched_cls] loading program "probe_netns_cookie_cls" (section "tc")
  [sched_cls] FAILED: program probe_netns_cookie_cls: load program: invalid argument:
              program of this type cannot use helper bpf_get_netns_cookie#122 (23 line(s) omitted)
```

probe_helper exit=1 (both unsupported)

## /proc/kallsyms evidence

The kernel exports per-program-type wrapper functions only for the program types
that are permitted to call the helper:

```
bpf_get_netns_cookie_sk_msg
bpf_get_netns_cookie_sock
bpf_get_netns_cookie_sock_addr
bpf_get_netns_cookie_sock_ops
bpf_get_netns_cookie_sockopt
```

**NOT present:**
- `bpf_get_netns_cookie_kprobe` — BPF_PROG_TYPE_KPROBE not permitted
- `bpf_get_netns_cookie_sched_cls` or similar — BPF_PROG_TYPE_SCHED_CLS not permitted

The absence of these wrappers in kallsyms is consistent with the verifier error
and confirms the helper is not registered for these program types.

## Conclusion

`bpf_get_netns_cookie` is **not available** for `BPF_PROG_TYPE_KPROBE` or
`BPF_PROG_TYPE_SCHED_CLS` on kernel 6.10.14-linuxkit aarch64.

The verifier error is: `"program of this type cannot use helper bpf_get_netns_cookie#122"`

This is a kernel-level restriction: the helper's `allowed_prog_types` bitmask
in `kernel/bpf/helpers.c` does not include kprobe or TC programs. This is not
a bug or a kernel-version regression — the helper was designed for socket-type
programs (cgroup/sock_addr, sock_ops, sk_msg, setsockopt, etc.) where the
network namespace is naturally bound to the socket context.

## Impact on scoping strategy

netns-cookie-based scoping of `ip_do_fragment` is not feasible on this kernel
(and likely not feasible on any kernel where this restriction exists, which
includes current mainline as of 6.10). See `docs/fragmentation-scoping.md`
for the full option analysis and chosen v0 strategy.

## Files

- `spikes/probe_netns_cookie_kprobe.bpf.c` — kprobe probe program
- `spikes/probe_netns_cookie_cls.bpf.c` — sched_cls probe program
- `spikes/probe_helper/main.go` — Go loader for load tests
- `scripts/probe-bpf-helpers.sh` — reusable probe script

## What is proven

- `bpf_get_netns_cookie` is NOT usable in BPF_PROG_TYPE_KPROBE on 6.10.14-linuxkit.
- `bpf_get_netns_cookie` is NOT usable in BPF_PROG_TYPE_SCHED_CLS on 6.10.14-linuxkit.
- The verifier error is explicit: "program of this type cannot use helper".
- /proc/kallsyms corroborates: no kprobe or sched_cls wrappers registered.

## What remains unknown

- Whether `bpf_get_netns_cookie` is available in kprobe/sched_cls on a
  different kernel version. The restriction appears to be by design, not a
  version-specific limitation, but has not been tested on other kernels.
