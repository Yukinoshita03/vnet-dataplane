# vnet-agent CLI Plan

## Goal

`vnet-agent` is the unified CLI entry point for `vnet-dataplane`.

It will centralize environment checks, virtualized path discovery, and benchmark entrypoints for the Linux acceleration module. The first stage is read-only only: no automatic eBPF attach, no network mutation, and no acceleration enablement.

## v1 Scope

The first version will implement the following commands:

```bash
vnet-agent --help
vnet-agent status
vnet-agent probe
vnet-agent bench virt-path
```

Output language is English only in v1.

Out of scope for v1:

- `--lang` or localized output
- JSON output
- daemon mode
- Prometheus export
- config files
- automatic attach
- automatic acceleration

## Command Design

`status` checks the local runtime environment, including OS/kernel information, root access, `tc`, `clang`, `bpftool`, `ovs-vsctl`, and the presence of expected `linux_accel/build` artifacts.

`probe` directly invokes `linux_accel/bench/openstack_path_probe.sh` in v1.

`bench virt-path` directly invokes `linux_accel/bench/virt_path_bench.sh` in v1.

Windows builds are allowed, but `probe` and `bench` must report a Linux-only error at runtime.

## Implementation Steps

1. Add a single-file CLI skeleton in `agent/src/main.cpp`.
2. Implement `PrintUsage()`, command dispatch, and unknown-command handling.
3. Implement `RunStatus()`.
4. Implement `RunProbe()` and `RunBenchVirtPath()` by shelling out to the existing scripts.
5. Update `agent/CMakeLists.txt` to build the `vnet-agent` executable.
6. After the CLI is stable, connect `agent/` to the top-level `CMakeLists.txt` and CI.

## Future Roadmap

- v2: add `status --json`, `probe --json`, and `diagnose`
- v3: add `monitor --dev <iface>` and unify DNS/gRPC monitor entrypoints
- v4: add Prometheus exporter, systemd service, and Kubernetes DaemonSet support
- v5: add explicit acceleration commands such as `accel dns --enable`

## Test Plan

The first version should be validated with the following cases:

- `vnet-agent --help` prints an English usage message
- `vnet-agent status` runs on both Windows and Linux
- `vnet-agent probe` prints a Linux-only message on Windows and calls `openstack_path_probe.sh` on Linux
- `vnet-agent bench virt-path` prints a Linux-only message on Windows and calls `virt_path_bench.sh` on Linux
- unknown commands return a non-zero exit code and a clear error message
- missing arguments print usage
- CMake builds `vnet-agent` without breaking the existing userspace, kernel, or `linux_accel` CI

## Assumptions

- The plan document lives at `agent/PLAN.md`
- v1 uses English-only output
- `std::system()` is acceptable for shelling out to the existing scripts in v1
- v1 does not implement daemon mode, automatic eBPF attach, or network mutation
- `agent/` already exists as a skeleton, but it should not be wired into the top-level build until the minimal CLI is compilable
