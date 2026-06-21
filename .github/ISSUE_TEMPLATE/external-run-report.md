---
name: External run report
about: Share results from running vxlan-tracer on your environment (any outcome is useful)
labels: external-run, compatibility
---

<!--
Thank you for running vxlan-tracer on a real environment.
Even a "no issue observed" result or a partial run is valuable — it tells us
what kernels and CNIs the tool encounters in the wild.
-->

## Environment

**Kernel version** (`uname -r`):

**Architecture** (`uname -m`):

**Linux distro** (e.g. Ubuntu 22.04, RHEL 8.6, Alpine 3.18):

**CNI / overlay** (e.g. k3s/Flannel 8472, Calico VXLAN 4789, manual vxlan0, none):

**Cloud / hardware** (e.g. AWS EC2, GCP GKE node, bare metal, Hetzner, Azure AKS):

**vxlan-tracer version** (`./vxlan-tracer --version`):

## How you ran it

<!-- Describe the invocation. Remove flags you didn't use. -->

```sh
sudo vxlan-tracer --overlay <iface> --underlay <iface> --duration <time>
```

**Did you run from the packaged release archive or from source?** (archive / source)

## Result

**Verdict** (from JSON `verdict` field or human output `Verdict:` line):

<!-- Paste the full JSON output here, or the human-readable output. -->
<details>
<summary>Output</summary>

```
<paste output here>
```

</details>

## Preflight result (if run)

<!-- Optional: paste the result of `sudo bash scripts/preflight.sh` -->

<details>
<summary>preflight.sh output</summary>

```
<paste here>
```

</details>

## collect-support bundle

<!-- Optional but very helpful: run `vxlan-tracer collect-support` and attach the .tar.gz here. -->

## Notes

<!-- Anything unexpected? Did the verdict match what you expected from your environment? -->
