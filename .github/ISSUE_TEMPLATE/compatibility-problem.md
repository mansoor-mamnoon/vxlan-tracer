---
name: Compatibility problem
about: Wrong verdict, crash, BPF load failure, or unexpected output
labels: bug, compatibility
---

## Problem summary

<!-- One sentence: what went wrong? e.g. "BPF load fails on kernel 5.10 with verifier error" -->

## Expected behavior

<!-- What did you expect vxlan-tracer to do? -->

## Actual behavior

<!-- What did it do instead? -->

## Environment

**Kernel version** (`uname -r`):

**Architecture** (`uname -m`):

**Linux distro**:

**CNI / overlay** (interface name and type):

**vxlan-tracer version** (`./vxlan-tracer --version`):

**Ran from**: packaged release archive / built from source

## Invocation

```sh
sudo vxlan-tracer --overlay <iface> --underlay <iface> [--flags]
```

## Error output

<!-- Paste stderr and stdout. Include the full error, not a summary. -->

```
<paste here>
```

## Preflight output

<!-- If preflight.sh ran, paste its output — it often identifies the root cause. -->

<details>
<summary>preflight.sh output</summary>

```
<paste here>
```

</details>

## collect-support bundle

<!-- Run `vxlan-tracer collect-support` and attach the .tar.gz — it's the fastest path to a diagnosis. -->

## Additional context

<!-- Anything else? Prior working state, recent kernel upgrade, specific workload, etc. -->
