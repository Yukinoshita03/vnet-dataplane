# Repository Agent Guide

## Agent skills

### Issue tracker

Issues and PRDs are tracked in GitHub Issues for
`Yukinoshita03/vnet-dataplane`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the canonical labels `needs-triage`, `needs-info`,
`ready-for-agent`, `ready-for-human`, and `wontfix`.
See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repository. Read the root `CONTEXT.md` and relevant
ADRs under `docs/adr/` when they exist. See `docs/agents/domain.md`.

## Current execution goal

Complete these workstreams in dependency order:

1. Commit only the current `linux_accel` TC coexistence fixes, regression
   tests, benchmark automation, and verified five-experiment results. Exclude
   unrelated worktree files.
2. Implement a metrics-driven DNS/gRPC dual-end cache policy controller with
   `BYPASS`, `SERVER_CACHE`, `CLIENT_CACHE`, and `DUAL_CACHE` states. It must
   use sliding windows, hysteresis, cooldown, atomic publication, and failure
   rollback.
3. Compare the dynamic policy against fixed policies in OpenStack using five
   rounds each of stable, burst, hot-key, shifting-hot-key, and low-hit-rate
   workloads. Retain raw evidence and cleanup audits.
4. Implement an independent data-plane agent that discovers Neutron/OVS
   VM-facing interfaces and attaches, detaches, and restores TC/XDP programs
   across VM lifecycle and migration events.
5. Add a third protocol adapter or materially strengthen the gRPC kernel fast
   path. Also repair and validate the `compute2` to `master` reverse live
   migration path before using cyclic migration results.

## Evidence and safety rules

- Do not describe attach smoke, host-netns fallback, mocks, or userspace
  serving as guest in-kernel acceleration.
- Keep DNS, gRPC, TC/XDP, OpenStack, and migration evidence separately
  attributable.
- Use scoped staging and commits. Never include unrelated user files.
- Validate Linux builds, eBPF loading/verifier behavior, five formal rounds,
  and post-run cleanup before marking a workstream complete.
- Preserve raw failed-run evidence, but exclude invalid runs from aggregates.
- Do not publish private patent material or private artifacts.
