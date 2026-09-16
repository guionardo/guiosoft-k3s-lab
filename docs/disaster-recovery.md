# Disaster recovery

The project distinguishes two recovery levels:

- **Control-plane DR**: restore the K3s SQLite datastore and server token on an isolated replacement host.
- **Full DR**: control-plane DR plus persistent local-path volumes and offline OCI image availability, resulting in runnable recovered workloads.

## Safety model

A destructive rehearsal target must have the marker created by `scripts/dr-target-init.sh`, must not match the production hostname/IP guards, and must have the independent nftables WAN barrier enabled before datastore restore:

```bash
sudo scripts/dr-network-isolation.sh enable
sudo scripts/dr-network-isolation.sh status
```

The isolation table permits loopback, established traffic, the configured LAN, pod CIDR, and service CIDR, and rejects other IPv4/IPv6 output and forwarding. Keep it enabled while restored workloads are being inspected. Disable it only after the recovered cluster has been deliberately neutralized:

```bash
sudo scripts/dr-network-isolation.sh disable
```

## Control-plane restore

The restore script verifies the backup SHA-256, archive structure, SQLite metadata/integrity, DR marker, production guards, and WAN isolation. Before replacing the datastore it preserves the target's current database/token and moves the clean target's `server/tls` and `server/cred` into the safety directory. K3s then reconstructs bootstrap material from the restored datastore.

```bash
sudo env DR_RESTORE_CONFIRM=restore-isolated-k3s \
  scripts/dr-restore-k3s.sh /path/to/k3s-backup.tar.gz
```

On failed startup/readiness the script stops K3s, prints recent service logs, and leaves the pre-restore target state under `/var/lib/rancher/k3s/dr-pre-restore-*`.

The R2 export helper selects the newest tagged Restic snapshot by parsing `restic snapshots --json` and restores that exact snapshot ID. Do not use human-readable `--latest 1` output as a recovery selector.

## Persistent volumes

Persistent local-path data is a separate backup set from the control-plane archive. Use a dedicated Restic tag such as `k3s-persistent-volumes`. A consistent snapshot requires the relevant writers to be stopped/suspended for the backup window and restored immediately afterward on production.

A recovered PV with local node affinity cannot be patched to a new hostname because PV node affinity and `spec.local.path` are immutable. The tested transaction is:

1. keep recovered writers at zero replicas;
2. verify the DR marker, WAN isolation, recovered data, expected source path root, and target path root;
3. back up PV and PVC manifests;
4. change all affected PV reclaim policies to `Retain`;
5. detect restored/orphaned Terminating pods that still reference the PVCs; if their original production node is absent, force-delete only those explicitly identified pods rather than removing PVC/PV protection finalizers;
6. delete the PVC objects;
7. allow the old PV objects to finish deletion;
8. recreate PVs with the same names/capacities, node affinity for the DR node, and local paths rewritten from the production root to the DR storage root; omit the entire old `claimRef` because its UID belongs to the destroyed production PVC;
9. recreate PVCs pre-bound through `volumeName`, allowing the binding controller to write a fresh claimRef/UID;
10. verify every PV/PVC is `Bound`, the new PVC UID matches the PV claimRef UID, each PV path is below the target storage root, and the physical directory exists;
11. start and validate recovered workloads one at a time.

The remapper defaults are:

```text
DR_PV_SOURCE_ROOT=/mnt/store1/k3s/local-path
DR_PV_TARGET_ROOT=/var/lib/rancher/k3s/storage
DR_PV_TARGET_NODE=$(hostname -s)
```

Override them explicitly when the production or recovery host uses a different layout.

## Offline OCI images

Do not treat the production containerd content store as an image backup. During the 2026-09 DR rehearsal multiple running/listed images could not be exported because referenced blobs were absent. Build the DR OCI kit ahead of an incident from registries or another complete source.

The kit must be platform-specific (currently `linux/amd64`), include runtime infrastructure images such as `docker.io/rancher/mirrored-pause:3.10.2`, include application/sidecar/init images, and contain SHA-256 checksums created at the origin. Every generated TAR must be validated before its checksum is accepted; generating `SHA256SUMS` only after transport proves local consistency, not transport integrity.

On the DR node use the K3s native air-gap image preload rather than relying only on manual `ctr images import`:

```bash
sudo scripts/dr-oci-preload.sh /path/to/oci-kit
```

This copies validated TARs into `/var/lib/rancher/k3s/agent/images/`, where K3s imports them through its native image mechanism. Validate critical images through the CRI (`k3s crictl inspecti`), not only `ctr images list`.

## Recovery kit independence

Once WAN isolation is enabled, GitHub is deliberately unavailable. A real recovery therefore must not depend on cloning or fetching the repository during the isolated phase. The off-host DR kit must contain a versioned/self-contained copy of all scripts required for restore and verification, the origin-created OCI checksums/images, and encrypted recovery material. Never put the private age identity, Restic password, R2 credentials, K3s token, or other plaintext secrets in Git.

## 2026-09 full rehearsals

A separate Debian 13 host (`guionote-hp`) reconstructed the production SQLite control plane while WAN-isolated. Four local-path PV/PVC pairs were restored and remapped to the DR node. Recovered workloads were then started individually:

- Grafana opened its restored SQLite database and became healthy.
- Tempo replayed its recovered state and became Ready. During the second rehearsal it discarded one incomplete WAL block missing `meta.json`; this is evidence that a live filesystem copy is recoverable but is not automatically application-consistent.
- Loki recovered checkpoint and WAL with `errors=false`, loaded local indices, and processed recovered streams.
- Prometheus reported recovered TSDB blocks as healthy, replayed mmap chunks/checkpoint/WAL, reached `TSDB started`, and subsequently wrote a new block and WAL checkpoint.

The second full rehearsal used a formal timer that intentionally included tooling/debugging time:

```text
T0: 2026-09-16T02:11:56Z (epoch 1789524716)
T1: 2026-09-16T03:19:05Z (epoch 1789528745)
Observed RTO: 4029 seconds = 1h 07m 09s
```

At T1 all four persistent workloads were Ready with zero restarts, all four PV/PVC pairs were Bound to `guionote-hp`, all PV paths were under `/var/lib/rancher/k3s/storage`, Flux's Git source remained suspended, cloudflared remained at zero replicas, and the nftables WAN isolation barrier remained active.

RPO must be recorded per backup set rather than collapsed into one number. For this rehearsal the restored control-plane artifact was created at `2026-09-15T06:26:46Z`. The persistent-volume snapshot was taken later (`2026-09-15 20:45:39` at the production-local time recorded during the rehearsal). Preserve the timezone with future snapshot metadata so RPO can be calculated unambiguously.

These rehearsals validate the project's **Full DR** model: control plane + persistent volumes + offline image availability can produce runnable workloads on a separate K3s host while production remains operational and the recovery target remains WAN-isolated.
