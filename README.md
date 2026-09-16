# guiosoft-k3s-lab

Infrastructure-as-code and operational tooling for the `guiosoft.info` self-hosted K3s platform.

## Current platform

- Debian 13 single-node K3s production cluster.
- Traefik ingress behind Cloudflare Tunnel.
- Flux GitOps with SOPS + age secret decryption.
- Firecrawl running LAN-only in K3s.
- Observability with Prometheus, Alertmanager, Grafana, Loki, Tempo, Alloy and OpenTelemetry Collector.
- K3s SQLite control-plane backups and off-host Restic backups in Cloudflare R2.
- Persistent local-path volume backup and disaster-recovery tooling.
- Verified bounded-consistency recovery sets pairing control-plane and persistent-volume Restic snapshots while persistent writers are quiesced.

## Disaster recovery

Two recovery levels are maintained:

1. **Control-plane DR** — SQLite datastore + K3s server token reconstruct Kubernetes state.
2. **Full DR** — control-plane + local-path persistent volumes + offline OCI images reconstruct runnable workloads.

A full recovery rehearsal was successfully performed in September 2026 on a separate Debian 13 host while production remained operational. The recovered cluster was WAN-isolated, its local PVs were remapped to the replacement node, and Grafana, Tempo, Loki and Prometheus successfully consumed their restored persistent data.

The first independently verified bounded-consistency production recovery set was created on 2026-09-16. Persistent writers were quiesced for the backup window; the exact control-plane and PV Restic snapshots were recorded and independently verified in R2. The measured consistency window was **64 seconds**.

Key safety/tooling components:

- `scripts/dr-target-init.sh` — mark a machine as an isolated DR target.
- `scripts/dr-network-isolation.sh` — independent nftables WAN barrier.
- `scripts/dr-preflight.sh` — consolidated safety/readiness checks.
- `scripts/dr-restore-k3s.sh` — guarded SQLite/token restore with bootstrap-state handling.
- `scripts/k3s-consistent-backup.sh` — orchestrate a bounded-consistency control-plane + PV recovery set with fail-closed writer restoration.
- `scripts/k3s-consistent-backup-verify.sh` — independently verify a completed recovery set against its exact R2 snapshots.
- `scripts/k3s-pv-backup-r2.sh` — consistent persistent-volume backup after writers are stopped.
- `scripts/k3s-pv-export-r2.sh` — portable snapshot staging from R2.
- `scripts/dr-pv-import.sh` — guarded local PV archive import.
- `scripts/dr-pv-remap.sh` — transactional PV/PVC recreation for a replacement node.
- `scripts/dr-oci-kit-build.sh` — build an offline, checksummed OCI recovery kit.
- `scripts/dr-oci-preload.sh` — install OCI archives through the K3s native air-gap preload path.
- `scripts/dr-rehearsal-status.sh` — preflight/status plus RTO/RPO timing report.

See [`docs/disaster-recovery.md`](docs/disaster-recovery.md) for the recovery model, safety rules, tested procedure, and findings from the full rehearsal.

## Recovery metrics

For future rehearsals, start timing immediately before beginning the recovery procedure:

```bash
sudo scripts/dr-rehearsal-status.sh start
```

After the agreed service-recovery criterion is reached, record the recovered backup timestamp and finish:

```bash
sudo env DR_RECOVERED_BACKUP_TIME='2026-09-15T20:45:39-03:00' \
  scripts/dr-rehearsal-status.sh finish
```

The report records measured RTO and, when a backup timestamp is supplied, effective RPO. RTO is measured rather than estimated; RPO is derived from the age of the recovered recovery point at rehearsal start.

## Safety

Never commit plaintext Cloudflare tokens, R2 credentials, Restic passwords, age private identities, SSH credentials, or other runtime secrets. The private age identity and encrypted Restic/R2 recovery material must also exist in an independent off-host DR kit.
