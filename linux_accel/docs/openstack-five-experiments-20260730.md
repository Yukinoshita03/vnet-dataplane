# OpenStack Five-Experiment Results (2026-07-30)

## Scope

These results were collected from the Shuka1 three-Compute DevStack lab with
two Ubuntu 24.04 `ds2G` tenant VMs. The client and backend started on
`nova:master`; the migration experiment targeted `compute2`.

The formal runs used the TC coexistence fix in which DNS and gRPC observer or
learning classifiers return `TC_ACT_PIPE`, allowing the existing NetMig
classifier to continue processing the same packet.

## Results

| Experiment | Formal result |
| --- | --- |
| gRPC and NetMig coexistence | Five rounds; baseline mean `463.48 QPS`, fast-cache mean `671.23 QPS`, mean per-round speedup `1.4544x` |
| Concurrent DNS and gRPC | Five rounds; DNS mean `5882.01 QPS`, gRPC mean `763.18 QPS`, zero failed requests |
| gRPC runtime policy update | Five rounds; mean update time `403074.6 us`, mean `548.73 QPS`, zero failed requests |
| DNS path ablation | Five rounds; baseline `1675.27 QPS`, monitor-only `1468.36`, server-only `1951.03`, client-only `8547.24`, both `8453.70` |
| Service continuity during migration | Forward block live migration `master -> compute2` completed in `85969 ms`; DNS request success `99.3667%`, gRPC request success `100%` |

DNS speedups relative to the five-round baseline mean were:

- Server-only: `1.1646x`
- Client-only: `5.1014x`
- Both ends: `5.0462x`

The DNS TTL-expiry, untrusted-response, and NXDOMAIN fallback checks passed.
All five primary DNS scenarios completed without request failures.

## Migration Evidence

Nova migration `129` completed from `master` to `compute2`. During the
migration window:

- DNS completed `6000` requests in `300` batches. Two batches contained
  failures, for `38` failed requests in total.
- gRPC completed `8040` requests in `402` batches with no failures.
- After the forward migration, the guest still had the DNS generic-XDP program
  attached, the gRPC response map pinned, and ports `50051` and `50052`
  listening.

The reverse live-migration path `compute2 -> master` failed twice with a
libvirt EOF/I/O error. This is a lab recovery-path defect and is not included
as a successful migration result. The Nova cross-host SSH setup was repaired,
and a cold migration returned the backend to `master/ACTIVE`.

Final cleanup verification found:

- Client and backend both `ACTIVE` on `master`.
- All three `nova-compute` services enabled and up.
- No active migration.
- Only the NetMig TC filters left on the tenant taps.
- No guest test processes, temporary BPF pins, temporary security-group rules,
  or temporary build directories.

## Interpretation Boundaries

- `grpc_fast_cache` is a userspace serving path backed by guest eBPF pinned
  policy and response maps. It is not an in-kernel gRPC response generator.
- The runtime-policy experiment measures BPF map replacement and response
  behavior. It is not yet a workload-adaptive cache algorithm.
- TC attach success alone is not treated as VM-to-VM acceleration evidence.
- Failed setup attempts and runs with nonzero cleanup status are excluded from
  performance aggregates.

## Reproduction

The repository scripts used for the campaign are:

- `bench/openstack_existing_pair_campaign.sh`
- `bench/openstack_service_migration_probe.sh`
- `bench/openstack_dns_e2e.sh`
- `scripts/build_linux.sh`

Raw artifacts remain on the private Shuka1 controller and are intentionally not
published in this repository.
