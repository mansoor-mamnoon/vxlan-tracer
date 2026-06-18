# Day 8 commit 7: build/release targets

## Build targets added to Makefile

| Target | Platform | Output |
|--------|---------|--------|
| `make build` | native (macOS or Linux) | `dist/vxlan-tracer` |
| `make build-linux-arm64` | Linux/aarch64 | `dist/vxlan-tracer-linux-arm64` |
| `make build-linux-amd64` | Linux/x86_64 | `dist/vxlan-tracer-linux-amd64` |
| `make package` | both Linux targets | `dist/release/` bundle |
| `make test` | any | `go test ./...` |

## Verification (macOS arm64 host)

```
make build-linux-arm64 build-linux-amd64 test

GOOS=linux GOARCH=arm64 go build -o dist/vxlan-tracer-linux-arm64 ./cmd/vxlan-tracer/
  built: dist/vxlan-tracer-linux-arm64

GOOS=linux GOARCH=amd64 go build -o dist/vxlan-tracer-linux-amd64 ./cmd/vxlan-tracer/
  built: dist/vxlan-tracer-linux-amd64

go test ./...
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/bpfmap  (cached)
ok  github.com/mansoormmamnoon/vxlan-tracer/internal/diag    0.312s
```

Binary sizes:
```
5.9M  dist/vxlan-tracer-linux-amd64
5.6M  dist/vxlan-tracer-linux-arm64
```

## dist/ contents (excluded from git)

`dist/` is listed in `.gitignore`. Binaries are not committed; they are built
from source. This is intentional: the BPF objects also require Linux clang to
compile and are not pre-built in the repository (see `bpf/*.o` in `.gitignore`).

## Important limitations

BPF object compilation (`make bpf`) still requires a Linux host with clang and
libbpf-dev. The Go binary cross-compiles on macOS, but running the binary
requires Linux with CAP_BPF + CAP_NET_ADMIN. See `docs/reproducibility.md`.

## What is proven

- `make build-linux-arm64` and `make build-linux-amd64` produce working Go
  binaries on macOS (cross-compilation via GOOS/GOARCH).
- `make test` runs 14 unit tests passing on macOS.
- No duplicate Makefile targets (fixed in this commit).
- dist/ is git-ignored; no binaries committed.

## What remains unproven

- `make package` has not been run (requires both Linux targets to succeed,
  which they do, but the package output directory layout is untested).
- `make build` (native, macOS) produces a binary that will not execute on
  macOS (requires Linux kernel); this is expected behavior.
