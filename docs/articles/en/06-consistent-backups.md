# The problem of consistent backups in Kubernetes

After three Disaster Recovery rehearsals in my K3s homelab, I could rebuild the control plane, restore PersistentVolumes, load OCI images without Internet access, and start workloads on another machine.

But one conceptual problem remained.

I had a control-plane backup and a volume backup.

**That did not mean I had a consistent system state.**

## Two correct backups can produce an incorrect restore

Imagine:

```text
10:00 control-plane backup
10:10 application keeps writing
10:20 volume backup
```

Both backups may be technically valid, yet represent different moments. Depending on the application, Kubernetes may describe one state while persistent storage contains another.

In my lab this became tangible when Tempo had to deal with an incomplete WAL block during an earlier restore. The workload recovered, but that was enough evidence to stop treating a filesystem copy as automatically application-consistent.

## The idea: a bounded-consistency recovery set

I did not need a perfect atomic distributed snapshot for this lab. I needed something simpler and verifiable:

1. temporarily stop persistent writers;
2. capture control plane and PVs while writers remain stopped;
3. record exactly which snapshots belong together;
4. restore writers immediately;
5. independently verify the artifacts.

I call this a **bounded-consistency recovery set**.

“Bounded” matters. I am not claiming distributed atomicity. I am claiming that I know and can measure the interval during which writers remained quiesced while both sides of the backup were captured.

## Quiescing without fighting operators

Grafana, Tempo, and Loki are StatefulSets that can be scaled down in a controlled way.

Prometheus adds a nuance: its StatefulSet is managed by the Prometheus Operator. Scaling the generated StatefulSet directly would mean fighting its reconciler.

The solution was to temporarily change `spec.replicas` on the Prometheus resource and let the Operator create the desired state.

That small distinction captures an important Kubernetes rule: **when a controller owns a resource, talk to the controller, not to the effect it generated.**

The process is fail-closed. I do not force-delete production writer Pods to obtain a backup. If graceful quiesce does not complete within the limit, the consistent backup fails.

## Fail before interrupting writers

Predictable failures are checked before the interruption window. The orchestrator validates the K3s API, required tools, and especially the Restic/R2 repository before quiescing anything.

If off-host storage is unavailable or the repository has a known problem, there is no reason to stop applications only to discover that later.

Expensive retention, prune, and integrity operations also happen after writers are restored. The critical window contains only work that actually requires consistency.

## Exact artifact identity

One of the most important changes was abandoning “restore the latest backup.”

The recovery set records exact IDs and timestamps.

For the control plane, the script creates a new SQLite/token archive, verifies it locally, uploads exactly that file and checksum to R2, and resolves the Restic snapshot containing that specific archive.

For PVs, the Restic snapshot created during the same window also has its exact ID and timestamp recorded.

The first complete set was:

```text
backup_set_id=20260916T114220Z
quiesced_at=2026-09-16T11:42:34Z

control_plane_snapshot=
6709a96774a79ded9e3435591074d9445d9f814127b0b1a4ba3041d6a39f3882

pv_snapshot=
1830fedfe1c6f293cef2eb971f390f28fd761ba1e929c75b9e06c2a007da190e

completed_backup_window_at=2026-09-16T11:43:38Z
consistency_window_seconds=64
writers_restored_at=2026-09-16T11:44:21Z
result=PASS
```

The measured interval from quiesce until both captures completed was **64 seconds**.

## Verify the verifier

The orchestrator reporting `PASS` was still not enough evidence.

I built an independent verifier that reopens the off-host repository and checks the recovery-set metadata, both exact snapshot IDs, actual snapshot timestamps, presence of the recorded control-plane archive in the correct snapshot, the expected PV root in the PV snapshot, and whether both timestamps fall inside the recorded window.

That independent verification passed as well.

The distinction is subtle but important: the same process that creates an artifact should not be the only authority claiming that the artifact is correct.

## Backup concurrency is state too

The server still runs its normal daily backup. The consistent recovery set is weekly because it introduces a small quiesce window.

Both workflows share:

```text
/run/lock/guiosoft-k3s-backup.lock
```

The weekly wrapper keeps the lock through capture, verification, and later Restic maintenance so another backup process cannot enter the repository halfway through the sequence and change the context being verified.

## From recovery set to portable bundle

Once the control-plane/PV pair had a formal identity, the DR bundle had to change too.

A builder that independently selected a recent control-plane snapshot and a recent PV snapshot would reintroduce the exact problem I had just solved.

Bundle v2 is therefore built from a specific `backup_set_id`. The materializer restores the exact snapshot IDs, verifies timestamps, cross-binds PV metadata to the same set, and only then assembles an offline artifact containing:

```text
control plane
persistent volumes
offline OCI images
recovery tooling
recovery-set metadata
checksums
```

The first portable v2 bundle was built from the 64-second recovery set and passed full verification.

## What changed in my definition of backup

At the beginning of the project, backup meant roughly:

```text
file exists outside the server
```

After the rehearsals, the definition became much stricter:

```text
artifact exists
+ checksum matches
+ exact snapshot is known
+ timestamp is known
+ CP/PV relationship is known
+ restore has been exercised
+ images are available offline
+ tooling is available offline
+ secrets have independent recovery
+ postconditions are verified
```

That is more work, but it turns backup from hope into a testable system property.

## Where the project stands now

The homelab that started with “let's install K3s” now has Ansible-declared host infrastructure, Terraform-managed external resources, Flux-reconciled workloads, SOPS + age encrypted secrets, correlated metrics/logs/traces, Restic/R2 off-host backup, full rehearsals on a second machine, offline OCI recovery, measured RTO, bounded and measured recovery sets, a portable DR bundle tied to exact snapshots, fail-closed destructive-operation guards, and declarative production/DR separation.

There is still more to improve, and future rehearsals will certainly discover more incorrect assumptions.

I now consider that a feature of the project, not a flaw.

The most interesting part of the lab is no longer Kubernetes itself. It is using a small environment to exercise questions that also appear in much larger systems:

**Is the state declared? Is it observable? Is it recoverable? Can we prove it?**

That last question is the criterion I intend to keep using for the next stages.

---

Project: `guionardo/guiosoft-k3s-lab`.
