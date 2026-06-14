# evidence/day-02-bpftrace.md

bpftrace probe execution attempts from Day 2.
Executed inside Docker ubuntu:22.04 (linuxkit 6.10.14-linuxkit aarch64).

## Summary

bpftrace 0.14.0 from the ubuntu:22.04 apt repository does not work on
Docker Desktop's linuxkit kernel. All probe attempts fail. The raw ftrace
interface (kprobe_events) is a working substitute for event counting.

---

## Attempt 1: bpftrace BEGIN probe

**Command:**
```sh
timeout 5 bpftrace -e 'BEGIN { printf("hello\n"); exit(); }'
```

**Actual output:**
```
/bpftrace/include/clang_workarounds.h:14:10: fatal error: 'linux/types.h' file not found
```

**Root cause:** The ubuntu:22.04 bpftrace 0.14.0 package embeds a private clang
include path (`/bpftrace/include/`) that depends on `linux/types.h` from kernel
headers. The `linux-headers-$(uname -r)` package (`linux-headers-6.10.14-linuxkit`)
does not exist in ubuntu:22.04 apt repositories — it is a linuxkit-specific kernel.

---

## Attempt 2: kprobe:ip_do_fragment

**Command:**
```sh
timeout 5 bpftrace -e 'kprobe:ip_do_fragment { printf("hit\n"); exit(); }'
```

**Actual output:**
```
/bpftrace/include/clang_workarounds.h:14:10: fatal error: 'linux/types.h' file not found
```

**Root cause:** Same as above. bpftrace clang compilation fails before the probe
can be attached. The kprobe attachment itself is not attempted.

---

## Attempt 3: list available tracepoints

**Command:**
```sh
bpftrace -l 'tracepoint:net:*'
```

**Actual output:**
```
terminate called after throwing an instance of 'std::runtime_error'
  what():  Could not read symbols from /sys/kernel/debug/tracing/available_events: No such file or directory
```

**Root cause:** bpftrace 0.14 reads available events from `/sys/kernel/debug/tracing/`
(the debugfs mount path). The linuxkit kernel exposes tracefs at `/sys/kernel/tracing/`
instead. Mounting debugfs manually:
```sh
mount -t debugfs debugfs /sys/kernel/debug
```
does not help because the kernel does not create a symlink from
`/sys/kernel/debug/tracing/` to the tracefs mount.

---

## Attempt 4: tracepoint:net:icmp_send

**Command:**
```sh
timeout 5 bpftrace -e 'tracepoint:net:icmp_send { printf("icmp_send hit\n"); exit(); }'
```

**Actual output:**
```
stdin:1:1-25: ERROR: tracepoint not found: net:icmp_send
tracepoint:net:icmp_send { printf("icmp_send hit\n"); exit(); }
```

**Root cause:** bpftrace 0.14 cannot find `available_events` (see Attempt 3),
so it cannot verify the tracepoint exists. The tracepoint DOES exist in the
kernel (confirmed: `__traceiter_icmp_send` is a T symbol in `/proc/kallsyms`)
but bpftrace cannot discover it.

---

## What was verified to work instead

Raw ftrace kprobe interface (see evidence/day-02-ftrace.md):
```
echo 'p:ip_do_frag ip_do_fragment' > /sys/kernel/tracing/kprobe_events
echo 1 > /sys/kernel/tracing/events/kprobes/ip_do_frag/enable
echo 1 > /sys/kernel/tracing/tracing_on
# ... generate traffic ...
grep ip_do_frag /sys/kernel/tracing/trace  →  20 events for 10 large pings
```

This confirms:
1. ip_do_fragment is kprobeable and fires as expected.
2. The kernel hook point is correct.
3. bpftrace failure is a tooling/packaging issue, not a kernel capability issue.

---

## Fix path

To run the spike probes in `spikes/bpftrace/`, one of the following is needed:

**Option A: Lima VM (recommended)**
```sh
brew install lima
limactl start --name=vxlan template://ubuntu-lts
limactl shell vxlan
sudo apt install -y bpftrace linux-tools-generic linux-headers-generic
bpftrace --version  # should show 0.19+ on Ubuntu 24.04 LTS
```

**Option B: Cloud VM**
```sh
# GCP f1-micro, Ubuntu 22.04 LTS
gcloud compute instances create vxlan-dev \
  --machine-type=f1-micro --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud
# then: apt install bpftrace linux-tools-$(uname -r)
```

**Option C: Vagrant**
```sh
vagrant init ubuntu/jammy64
vagrant up
vagrant ssh
# then: apt install bpftrace linux-tools-$(uname -r)
```

In all cases, `linux-headers-$(uname -r)` and `linux-tools-$(uname -r)` must match
the running kernel. On a standard Ubuntu 22.04 or 24.04 VM, these packages are
available and match.

---

## Expected output once bpftrace works

From `spikes/bpftrace/ip_do_fragment.bt` on a kernel where the probe runs:

```
ip_do_fragment probe active. Run 'make smoke-large' in another terminal.
Ctrl-C to stop.

[ip_do_fragment] outer_ip_len=1438 dev=veth1 dev_mtu=1400 ip_excess=38
[ip_do_fragment] outer_ip_len=1438 dev=veth1 dev_mtu=1400 ip_excess=38
...

--- 10s summary ---
  total fragmentation events (outer_len > 1400): 20
  @per_device[veth1]: 20
```

The `outer_ip_len` and `ip_excess` fields would be printed from `skb->len` and
`dev->mtu` fields at ip_do_fragment entry. This is deferred to Day 3.
