# Shared Yoga deployment bundle

This directory contains placeholders only. Do not commit a rendered bundle,
live UUIDs, guest addresses, host keys, credentials, or preflight evidence.

`topology.json.example` contains two deliberately separate inputs:

- `inventory` is the exact read-only preflight inventory. The renderer calls
  the preflight validator and hashes its canonical normalized form as
  `inventory_sha256`.
- `hosts`, `interfaces`, and `guests` describe deployment routing. Nova host
  names are separate from SSH destinations so a transport address cannot be
  mistaken for a Nova scheduling identity.

Replace every `REPLACE_...` value in a private runtime copy. The source host is
`compute2`; the target host is `compute3`. Keep the target tap allowlist empty
before the first migration unless the target already owns an experiment tap.
Interface names must come from OVS/Agent observation; the renderer never
synthesizes them from a port UUID. The target names must equal the source
names because Neutron port tap names are expected to remain stable across this
compute-to-compute migration; the post-migration gate must observe the same
`iface-id` binding before target-side evidence is accepted.

The inventory must bind the two servers and their two ports to one exact
project UUID and a dedicated `vnet-dataplane-owner-*` tag. Each port also has
one expected RFC1918 fixed IPv4 and one lowercase unicast MAC. The guest
records must repeat those exact IP/MAC values. An extra port attached to either
owned server, a duplicate `iface-id`, or a tap missing from `br-int` blocks the
preflight.

Render only after a Linux build has produced every required binary and BPF
object beneath the artifact root:

```sh
python3 linux_accel/bench/render_openstack_shared_bundle.py \
  --topology /private/run/topology.json \
  --artifact-root /private/run/vnet-dataplane-linux-build \
  --output /private/run/shared-yoga-bundle
```

The output contains a three-host `bundle-manifest.json` for the roles
`controller`, `source`, and `target`. Guest endpoint files are kept in the
separate `guest_files` inventory and are not part of host staging. Every staged
file has an expected target, mode, and SHA-256 digest. Missing artifacts,
symlinks, unsafe identities, public guest addresses, or an existing output
directory fail closed.

Bundle publication is no-replace: a directory or dangling path created by a
concurrent process is preserved and rendering fails. Compute endpoint configs
use schema version `2` and contain an exact non-empty `port_ids` allowlist for
each server. The Agent refuses all attachment for that server if Neutron shows
an undeclared ACTIVE local OVS port.

The renderer does not create a known-hosts file. Populate the declared path
only from independently verified Ed25519 host keys. It also emits root-owned
argument-validating wrappers and a narrow sudoers fragment; the wrappers limit
the wildcard portion of sudo rules to the two declared ports and observed log
paths. `visudo -cf` is run automatically when `visudo` is available locally.

The shared units are staged disabled and contain `RefuseManualStart=yes`.
Rendering and staging do not authorize starting services, attaching TC/XDP,
creating VMs, or migrating instances. Those actions require a separate,
resource-specific approval after a passing preflight report is bound to the
same `inventory_sha256`.

Staging writes a separate recovery receipt before its first remote inspection.
Keep that file outside the repository: it remains sufficient for rollback if
the final stage receipt cannot be published. Staging and rollback deliberately
do not call `systemctl daemon-reload`; manager reload belongs to the separately
authorized activation transaction.

Create the recovery receipt's parent directory before invoking stage. The
stager rejects a missing parent or a symlink anywhere in that directory chain,
and synchronizes the existing chain before the first SSH operation.

The sudoers fragment is syntax-checked but staged only as a root-readable
`.pending` file below `/etc/vnet-dataplane-shared`. It is not installed in
`/etc/sudoers.d` until a future activation transaction is explicitly authorized.

The staging command must receive the same private topology and immutable Linux
artifact root used for rendering. It reproduces the bundle independently and
requires a byte-for-byte manifest match before any host write is attempted.
Preflight performs a bounded end-of-collection confirmation pass, and staging
rechecks that snapshot after all inspections and before every node write. If
the evidence expires between nodes, already staged nodes are rolled back in
reverse order.

Two compatibility exceptions remain because the application validators enforce
them: policy lock files stay below `/run/vnet-dataplane-policy`, and the pinned
known-hosts file remains a direct child of `/etc/vnet-dataplane-agent`.
