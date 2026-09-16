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

## Persistent volumes

Persistent local-path data is a separate backup set from the control-plane archive. Use a dedicated Restic tag such as `k3s-persistent-volumes`. A consistent snapshot requires the relevant writers to be stopped/suspended for the backup window and restored immediately afterward on production.

A recovered PV with local node affinity cannot be patched to a new hostname because PV node affinity is immutable. The tested transaction is:

1. keep recovered writers at zero replicas;
2. verify the DR marker, WAN isolation, recovered data, and expected bind/path mapping;
3. back up PV and PVC manifests;
4. change all affected PV reclaim policies to `Retain`;
5. delete the PVC objects; do not force-remove `pv-protection` finalizers;
6. allow the old PV objects to finish deletion;
7. recreate PVs with the same names/local paths/capacities but node affinity for the DR node, omitting the old `claimRef.uid`;
8. recreate PVCs pre-bound through `volumeName`;
9. verify every PV/PVC is `Bound` and that the new PVC UID matches the PV claimRef UID;
10. start and validate recovered workloads one at a time.

## Offline OCI images

Do not treat the production containerd content store as an image backup. During the 2026-09 DR rehearsal multiple running/listed images could not be exported because referenced blobs were absent. Build the DR OCI kit ahead of an incident from registries or another complete source.

The kit must be platform-specific (currently `linux/amd64`), include runtime infrastructure images such as `docker.io/rancher/mirrored-pause:3.10.2`, include application/sidecar/init images, and contain SHA-256 checksums. Every generated TAR must be validated before its checksum is accepted.

On the DR node use the K3s native air-gap image preload rather than relying only on manual `ctr images import`:

```bash
sudo scripts/dr-oci-preload.sh /path/to/oci-kit
```

This copies validated TARs into `/var/lib/rancher/k3s/agent/images/`, where K3s imports them through its native image mechanism. Validate critical images through the CRI (`k3s crictl inspecti`), not only `ctr images list`.

## 2026-09 full rehearsal result

A separate Debian 13 host (`guionote-hp`) reconstructed the production SQLite control plane while WAN-isolated. Four local-path PV/PVC pairs were restored and remapped to the DR node. Recovered workloads were then started individually:

- Grafana opened its restored SQLite database and became healthy.
- Tempo replayed its recovered state and became Ready; a non-fatal `unowned file entry ignored during wal replay file=blocks` warning was observed.
- Loki recovered checkpoint and WAL with `errors=false`, loaded local indices, and processed recovered streams.
- Prometheus reported recovered TSDB blocks as healthy, replayed mmap chunks/checkpoint/WAL, reached `TSDB started`, and subsequently wrote a new block and WAL checkpoint.

This validates the project's **Full DR** model: control plane + persistent volumes + offline image availability can produce runnable workloads on a separate K3s host while production remains operational.
