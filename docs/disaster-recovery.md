# Disaster recovery

The project distinguishes two recovery levels:

- **Control-plane DR**: restore the K3s SQLite datastore and server token on an isolated replacement host.
- **Full DR**: control-plane DR plus persistent local-path volumes and offline OCI image availability, resulting in runnable recovered workloads.

## Safety model

A destructive rehearsal target must have the marker created by `scripts/dr-target-init.sh`, must not match the production hostname/IP guards, and must have the independent nftables WAN barrier enabled before datastore restore:

```bash
sudo scripts/dr-target-init.sh
sudo scripts/dr-network-isolation.sh enable
sudo scripts/dr-network-isolation.sh status
```

The isolation table permits loopback, established traffic, the configured LAN, pod CIDR, and service CIDR, and rejects other IPv4/IPv6 output and forwarding. Keep it enabled while restored workloads are being inspected. Disable it only after the recovered cluster has been deliberately neutralized.

Record formal T0 **before K3s bootstrap** so RTO includes bootstrap and operator/debug time:

```bash
sudo scripts/dr-rehearsal-start.sh /path/to/dr-bundle
```

`dr-rehearsal-report.sh` prefers this full-rehearsal timer and falls back to the older recovery-transaction timer only for compatibility.

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
5. detect restored/orphaned Terminating pods that still reference the PVCs; force-delete only those explicitly identified pods rather than removing PVC/PV protection finalizers;
6. delete the PVC objects;
7. allow the old PV objects to finish deletion;
8. recreate PVs with the same names/capacities, node affinity for the **future DR node hostname**, and local paths rewritten from the production root to the DR storage root; omit the entire old `claimRef` because its UID belongs to the destroyed production PVC;
9. recreate PVCs pre-bound through `volumeName`, allowing the binding controller to write a fresh claimRef/UID;
10. verify every PV/PVC is `Bound`, the new PVC UID matches the PV claimRef UID, each PV path is below the target storage root, and the physical directory exists;
11. activate the K3s agent, wait for the DR node to register/Ready, then start and validate recovered workloads one at a time.

The remapper intentionally does **not** require the target Node object to exist. During the isolated datastore restore `disable-agent:true` is mandatory, so only the restored production Node may exist in the API. Kubernetes may store nodeAffinity for the future DR hostname before that Node registers.

The remapper defaults are:

```text
DR_PV_SOURCE_ROOT=/mnt/store1/k3s/local-path
DR_PV_TARGET_ROOT=/var/lib/rancher/k3s/storage
DR_PV_TARGET_NODE=$(hostname -s)
```

Override them explicitly when the production or recovery host uses a different layout.

## Bounded-consistency production recovery sets

`scripts/k3s-consistent-backup.sh` closes the historical RPO gap between independently scheduled control-plane and persistent-volume backups. It first validates the K3s API and the off-host Restic/R2 repository, then records original writer replica counts, gracefully quiesces Grafana, Tempo and Loki StatefulSets, and changes Prometheus through its operator-managed Prometheus CR rather than fighting the generated StatefulSet. It never force-deletes production writer pods.

While writers remain quiesced, the orchestrator creates and locally verifies a new SQLite/token archive, uploads that exact archive and checksum to R2, resolves the exact Restic snapshot by archive content, creates the PV Restic snapshot, runs repository integrity checking, records both exact snapshot IDs/timestamps, and finally restores the original writer state through a safety trap. Repository/lock failures are checked before quiescing so known off-host failures do not unnecessarily interrupt writers.

The first complete production recovery set passed on 2026-09-16:

```text
backup_set_id=20260916T114220Z
quiesced_at=2026-09-16T11:42:34Z
control_plane_snapshot=6709a96774a79ded9e3435591074d9445d9f814127b0b1a4ba3041d6a39f3882
control_plane_snapshot_time=2026-09-16T08:42:39.504576398-03:00
pv_snapshot=1830fedfe1c6f293cef2eb971f390f28fd761ba1e929c75b9e06c2a007da190e
pv_snapshot_time=2026-09-16T08:43:00.7110975-03:00
completed_backup_window_at=2026-09-16T11:43:38Z
consistency_window_seconds=64
writers_restored_at=2026-09-16T11:44:21Z
result=PASS
```

`scripts/k3s-consistent-backup-verify.sh` independently re-opened the R2 repository and verified that the metadata is PASS, both exact snapshots exist, the control-plane snapshot contains the recorded archive, the PV snapshot contains the expected local-path root, and both snapshot timestamps fall inside the recorded bounded-consistency window. The independent verification result was `PASS`.

This is a bounded-consistency recovery set rather than an atomic distributed snapshot: the applications are quiesced for the entire capture interval, and the measured interval between quiesce and completion of both backup captures was **64 seconds**. The writers were subsequently restored successfully.

## Neutralization and reset invariants

`dr-neutralize.sh` must fail closed. It now verifies from the API that Flux GitRepositories/Kustomizations/HelmReleases are suspended and that cloudflare/firecrawl/lab/monitoring Deployments plus monitoring StatefulSets have `spec.replicas=0` before announcing success.

`dr-target-reset.sh` removes K3s data/config plus the current recovery checkpoints/timers and verifies the K3s paths are gone. Historical evidence that must be retained should be copied outside the current-state directories before reset. This prevents a later orchestrator from skipping steps because of stale `.done` files.

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

### Rehearsal #2

The second full rehearsal used a formal timer that intentionally included tooling/debugging time:

```text
T0: 2026-09-16T02:11:56Z (epoch 1789524716)
T1: 2026-09-16T03:19:05Z (epoch 1789528745)
Observed RTO: 4029 seconds = 1h 07m 09s
```

At T1 all four persistent workloads were Ready with zero restarts, all four PV/PVC pairs were Bound to `guionote-hp`, all PV paths were under `/var/lib/rancher/k3s/storage`, Flux's Git source remained suspended, cloudflared remained at zero replicas, and the nftables WAN isolation barrier remained active.

### Rehearsal #3

The third full rehearsal used the offline bundle and again included bootstrap, operator intervention and debugging in the externally recorded timer:

```text
Observed RTO: 2823 seconds = 00h 47m 03s
Rehearsal #2 baseline: 4029 seconds = 01h 07m 09s
Delta: -1206 seconds = -00h 20m 06s
Improvement: approximately 29.9%
```

Despite deliberately counting issues discovered during execution, the recovered end state was healthy: `guionote-hp` Ready, Tempo 1/1, Loki 2/2, Prometheus 2/2 and Grafana 3/3 Running with zero restarts, four PV/PVC pairs Bound with DR-local paths and affinity to `guionote-hp`, all nine offline OCI archives installed in the K3s native preload directory, Flux suspended, cloudflared at zero replicas, and WAN isolation active.

The third rehearsal exposed and drove fixes for three important recovery invariants:

- neutralization must verify postconditions instead of trusting successful `kubectl scale` exits;
- PV remap must allow affinity to the future DR hostname while the cluster is intentionally agentless;
- reset must remove current recovery checkpoints/timers and verify K3s data/config removal so a new rehearsal starts from a deterministic state.

The rehearsal also reconfirmed that restored Terminating pods referencing protected PVCs must be explicitly identified and force-deleted before the immutable PV/PVC recreation transaction.

RPO must be recorded per backup set rather than collapsed into one number. For these rehearsals the restored control-plane artifact was created at `2026-09-15T06:26:46Z`. The persistent-volume Restic snapshot used by rehearsal #3 was snapshot `151de422`, taken at `2026-09-15 20:45:39` production-local time; the later archive materialization timestamp is not the snapshot time. Future exporter metadata must preserve the Restic snapshot timestamp and timezone unambiguously.

These rehearsals validate the project's **Full DR** model: control plane + persistent volumes + offline image availability can produce runnable workloads on a separate K3s host while production remains operational and the recovery target remains WAN-isolated.
