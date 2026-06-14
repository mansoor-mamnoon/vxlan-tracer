# vxlan-tracer build system
# Targets that require Linux kernel headers/bpftool will fail on macOS.
# Build and run the full tool on a Linux host with kernel >= 5.15.

BINARY     := vxlan-tracer
BPF_SRC    := bpf/tc_egress_vxlan0.bpf.c bpf/tc_ingress_eth0.bpf.c bpf/kprobes.bpf.c
CLANG      := clang
CFLAGS_BPF := -O2 -g -target bpf -D__TARGET_ARCH_x86 \
              -I/usr/include/bpf \
              -Wall -Wno-unused-value -Wno-pointer-sign

.PHONY: all build bpf generate lint vet lab-up lab-down smoke-small smoke-large clean help

all: build

# --- Go userspace binary ---
build: generate
	go build -o dist/$(BINARY) ./cmd/vxlan-tracer/

generate:
	go generate ./...

vet:
	go vet ./...

lint:
	golangci-lint run ./... 2>/dev/null || echo "golangci-lint not installed; skipping"

# --- BPF objects (Linux only) ---
bpf: $(BPF_SRC)
	@echo "Compiling BPF programs (requires clang + Linux headers)"
	$(CLANG) $(CFLAGS_BPF) -c bpf/tc_egress_vxlan0.bpf.c  -o bpf/tc_egress_vxlan0.bpf.o
	$(CLANG) $(CFLAGS_BPF) -c bpf/tc_ingress_eth0.bpf.c   -o bpf/tc_ingress_eth0.bpf.o
	$(CLANG) $(CFLAGS_BPF) -c bpf/kprobes.bpf.c            -o bpf/kprobes.bpf.o

# --- Lab management ---
lab-up:
	sudo bash scripts/setup-netns.sh

lab-down:
	sudo bash scripts/teardown-netns.sh

smoke-small:
	bash scripts/smoke-small-traffic.sh

smoke-large:
	bash scripts/smoke-large-traffic.sh

# --- Symbol check (Linux only) ---
check-symbols:
	@echo "Checking required kernel symbols..."
	@grep -E " T ip_do_fragment$$| T icmp_send$$| T icmp_rcv$$" /proc/kallsyms \
		|| echo "WARNING: /proc/kallsyms not available or symbols not found"

clean:
	rm -rf dist/ bpf/*.o bpf/bpf_bpf*.go

help:
	@echo "Targets: all build generate vet lint bpf lab-up lab-down smoke-small smoke-large check-symbols clean"
