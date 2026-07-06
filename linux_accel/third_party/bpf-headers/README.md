# BPF Header Shims

These headers exist only to make editors on macOS understand simple Linux eBPF
source files.

They are **not** a replacement for real Linux kernel UAPI headers or libbpf
headers. Real builds should happen in a Linux environment with proper packages
installed, such as:

- `linux-headers`
- `libbpf-dev`
- `clang`
- `llvm`
- `bpftool`

Do not include this directory in production Linux build commands unless you know
exactly why you need it.

