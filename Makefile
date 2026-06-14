# vxlan-tracer build system
#
# BPF targets require Linux with clang, libbpf-dev, and linux-libc-dev.
# They will not work on macOS. The Go userspace binary builds on any platform.

BINARY := vxlan-tracer
CLANG  := clang

# Architecture-specific include path.
# On Ubuntu/Debian, asm/types.h lives under the arch triplet directory.
# clang (cross-compiling to BPF target) cannot locate it without -I.
# Confirmed required on aarch64 Docker linuxkit (June 2026).
_HOST_ARCH := $(shell uname -m 2>/dev/null || echo unknown)
ifeq ($(_HOST_ARCH),aarch64)
  _ARCH_INC := -I/usr/include/aarch64-linux-gnu
else ifeq ($(_HOST_ARCH),x86_64)
  _ARCH_INC := -I/usr/include/x86_64-linux-gnu
else
  _ARCH_INC :=
endif

# BPF compile flags.
# -D__TARGET_ARCH_* is intentionally absent: TC sched_cls programs access
# packet data via struct __sk_buff and do not use arch-specific kprobe/
# tracepoint context accessor helpers that require that define.
CFLAGS_BPF := -O2 -g -target bpf \
              -I/usr/include \
              $(_ARCH_INC) \
              -Wall -Wno-unused-value -Wno-pointer-sign

.PHONY: all build bpf bpf-check generate lint vet \
        lab-up lab-down smoke-small smoke-large \
        attach-bpf check-symbols clean help

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
# kprobes.bpf.c is not yet implemented; excluded until Day 4.
bpf: bpf-check bpf/tc_ingress_eth0.bpf.o bpf/tc_egress_vxlan0.bpf.o
	@echo "BPF build complete."
	@ls -lh bpf/*.bpf.o

bpf/tc_ingress_eth0.bpf.o: bpf/tc_ingress_eth0.bpf.c bpf/maps.h
	@echo "  CC  $@"
	$(CLANG) $(CFLAGS_BPF) -c $< -o $@

bpf/tc_egress_vxlan0.bpf.o: bpf/tc_egress_vxlan0.bpf.c bpf/maps.h
	@echo "  CC  $@"
	$(CLANG) $(CFLAGS_BPF) -c $< -o $@

bpf-check:
	@if [ "$$(uname -s)" = "Darwin" ]; then \
	    echo "ERROR: BPF compilation requires Linux. This host is macOS."; \
	    echo "       Run 'make bpf' inside a Linux container or VM."; \
	    echo "       See docs/linux-dev-environment.md for options."; \
	    exit 1; \
	fi
	@command -v $(CLANG) >/dev/null 2>&1 || \
	    { echo "ERROR: clang not found.  apt install clang"; exit 1; }
	@test -f /usr/include/bpf/bpf_helpers.h || \
	    { echo "ERROR: libbpf headers missing.  apt install libbpf-dev"; exit 1; }
	@test -f /usr/include/linux/bpf.h || \
	    { echo "ERROR: linux UAPI headers missing.  apt install linux-libc-dev"; exit 1; }
	@echo "  prereqs OK  clang=$$(clang --version 2>/dev/null | head -1)  arch=$(_HOST_ARCH)"

# --- TC BPF attach (Linux only, requires lab-up first) ---
attach-bpf: bpf
	@echo "Attaching TC BPF programs..."
	ip netns exec ns1 tc qdisc add dev veth1  clsact 2>/dev/null || true
	ip netns exec ns1 tc filter add dev veth1 ingress bpf da \
	    obj bpf/tc_ingress_eth0.bpf.o sec tc
	ip netns exec ns1 tc qdisc add dev vxlan0 clsact 2>/dev/null || true
	ip netns exec ns1 tc filter add dev vxlan0 egress bpf da \
	    obj bpf/tc_egress_vxlan0.bpf.o sec tc
	@echo "Verify: ip netns exec ns1 tc filter show dev veth1 ingress"

# --- Lab management ---
lab-up:
	sudo bash scripts/setup-netns.sh

lab-down:
	sudo bash scripts/teardown-netns.sh

smoke-small:
	bash scripts/smoke-small-traffic.sh

smoke-large:
	bash scripts/smoke-large-traffic.sh

# --- Kernel symbol check (Linux only) ---
check-symbols:
	@echo "Checking required kernel symbols..."
	@grep -E " T ip_do_fragment$$| T icmp_rcv$$" /proc/kallsyms \
	    || echo "WARNING: /proc/kallsyms not available or symbols not found"
	@echo "icmp_send (tracepoint-only on kernel 6.10+):"
	@grep -E "__traceiter_icmp_send" /proc/kallsyms | head -2 || echo "  not found"

clean:
	rm -rf dist/ bpf/*.o

help:
	@echo "Targets:"
	@echo "  build         Go binary (any platform)"
	@echo "  vet           go vet"
	@echo "  bpf           Compile BPF objects (Linux only)"
	@echo "  bpf-check     Check BPF build prerequisites"
	@echo "  attach-bpf    Attach BPF to lab interfaces (Linux, lab must be up)"
	@echo "  lab-up        Create netns + VXLAN lab topology"
	@echo "  lab-down      Tear down lab"
	@echo "  smoke-small   Small traffic test"
	@echo "  smoke-large   Large traffic test"
	@echo "  check-symbols Verify kernel symbols in /proc/kallsyms"
	@echo "  clean         Remove build artifacts"
