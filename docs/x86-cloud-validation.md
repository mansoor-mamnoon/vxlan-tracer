# x86_64 Cloud VM Validation Guide

Use this guide to validate vxlan-tracer on a real x86_64 Linux kernel when
GitHub Actions cannot reach the scenario suite (e.g., privilege restrictions
block BPF load or netns creation in a shared runner environment).

## Recommended providers

All three options give a suitable kernel (5.15+ with BTF) on x86_64 amd64.

| Provider | Machine type | OS | Monthly cost |
|----------|--------------|----|--------------|
| AWS | t3.small (2 vCPU, 2GB) | Ubuntu 22.04 | ~$17 |
| GCP | e2-small (2 vCPU, 2GB) | Ubuntu 22.04 | ~$14 |
| Azure | B1s (1 vCPU, 1GB) | Ubuntu 22.04 | ~$8 |

A spot/preemptible instance cuts cost by 60–80%. The session runs in under
30 minutes, so even on-demand cost is trivial.

## AWS step-by-step

```sh
# 1. Launch a t3.small with Ubuntu 22.04
aws ec2 run-instances \
  --image-id ami-0c7217cdde317cfec \     # Ubuntu 22.04 us-east-1 (check current AMI)
  --instance-type t3.small \
  --key-name YOUR_KEY_PAIR \
  --security-group-ids sg-XXXXXXXX \    # allow SSH (22) inbound
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=vxlan-tracer-x86}]'

# 2. SSH in
ssh -i YOUR_KEY.pem ubuntu@<PUBLIC_IP>

# 3. Install dependencies
sudo apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  clang llvm libbpf-dev linux-tools-generic linux-tools-$(uname -r) \
  iproute2 iputils-ping iptables python3 python3-pip \
  make gcc build-essential gcc-multilib git
sudo pip3 install scapy
# Install Go 1.21+
curl -LO https://go.dev/dl/go1.21.13.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.13.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc && source ~/.bashrc

# 4. Clone and build
git clone https://github.com/mansoor-mamnoon/vxlan-tracer.git
cd vxlan-tracer
sudo make preflight
sudo make bpf
make build

# 5. Run scenarios
sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s bash scripts/run-scenarios.sh

# 6. Capture evidence
uname -a > /tmp/x86-uname.txt
sudo make preflight 2>&1 > /tmp/x86-preflight.txt
sudo make bpf 2>&1 > /tmp/x86-bpf-compile.txt
make test 2>&1 > /tmp/x86-unit-tests.txt
sudo BINARY=dist/vxlan-tracer BPF_DIR=bpf DURATION=15s \
  bash scripts/run-scenarios.sh 2>&1 | tee /tmp/x86-scenarios.txt
```

## GCP step-by-step

```sh
# 1. Create instance
gcloud compute instances create vxlan-tracer-x86 \
  --machine-type=e2-small \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --zone=us-central1-a \
  --boot-disk-size=20GB

# 2. SSH
gcloud compute ssh vxlan-tracer-x86 --zone=us-central1-a

# 3. Then follow AWS steps 3-6 above (same OS, same commands)
```

## Azure step-by-step

```sh
# 1. Create VM
az vm create \
  --resource-group myRG \
  --name vxlan-tracer-x86 \
  --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts:latest \
  --size Standard_B1s \
  --admin-username ubuntu \
  --generate-ssh-keys

# 2. Open SSH
az vm open-port --port 22 --resource-group myRG --name vxlan-tracer-x86

# 3. SSH
ssh ubuntu@$(az vm show -g myRG -n vxlan-tracer-x86 -d --query publicIps -o tsv)

# 4. Then follow AWS steps 3-6 above
```

## Evidence template

After running on the cloud VM, fill in this template for `evidence/day-10-x86-vm-scenarios.md`:

```
uname -a: <output>
Architecture: x86_64
Distro: Ubuntu 22.04.x LTS
Kernel: <version>
BTF: /sys/kernel/btf/vmlinux <size> bytes

make preflight: PASS/FAIL (N/N checks)
make bpf: PASS/FAIL (4 objects compiled)
make test: PASS/FAIL (N tests)
run-scenarios.sh: PASS/FAIL (N/5 scenarios)

Scenario 1 (NO_ISSUE_OBSERVED): <verdict>
Scenario 2 (PTB_DELIVERED): <verdict>
Scenario 3 (PTB_SUPPRESSED): <verdict>
Scenario 4 (VXLAN_FRAGMENTATION_OBSERVED): <verdict>
Scenario 5 (second-run idempotency): <verdict>
```

## Security group / firewall notes

The lab runs entirely in network namespaces on the VM itself — no external
traffic is generated. You only need:
- SSH (port 22) inbound from your IP

The lab does NOT need:
- Any other inbound ports
- Internet egress beyond package installation

## Cleanup

After capturing evidence, terminate the instance:

```sh
# AWS
aws ec2 terminate-instances --instance-ids i-XXXXXXXXXXXXXXXXX

# GCP
gcloud compute instances delete vxlan-tracer-x86 --zone=us-central1-a

# Azure
az vm delete --resource-group myRG --name vxlan-tracer-x86 --yes
```

## Why GitHub Actions may not be sufficient

GitHub-hosted `ubuntu-22.04` runners provide real x86_64 kernels with BTF
and root/sudo access. However, as of Day 10 they use an Azure infrastructure
kernel (`6.8.0-1052-azure`), not the canonical Ubuntu 22.04 LTS kernel.
If the runner restricts `ip netns add`, `ip link add dummy`, or BPF program
loading in future runner image versions, the scenario suite will fail even
with correct code. A cloud VM provides a stable, fully-privileged environment
for reproducible x86_64 validation.
