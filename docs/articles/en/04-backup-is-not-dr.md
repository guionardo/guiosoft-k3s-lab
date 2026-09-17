# Backup does not mean Disaster Recovery

I had backups of my Kubernetes cluster.

Then I asked the question that is usually easy to postpone:

**Can I actually restore them?**

The short answer was: not as easily as it seemed.

This may have been the most valuable stage of my K3s homelab so far, because the exercise stopped being about creating backups and became about producing a runnable system on another machine.

## Two recovery levels

I split the problem into two levels. The first is control-plane recovery: restore the K3s SQLite datastore and server token.

The second is what I call Full DR:

```text
control plane
+ persistent volumes
+ OCI images available offline
+ runnable workloads
```

A cluster backup is not one thing.

## A DR target must be dangerous by design—and safe by control

I used a second Debian 13 machine, `guionote-hp`, as the recovery target while production continued running on `guiosoft-info`.

Restoring production state elsewhere carries an important risk: recovered workloads may believe they are in production and try to reach external services.

The target therefore receives an independent nftables WAN barrier before restore. Loopback, LAN, and Kubernetes internal networks are allowed; other IPv4/IPv6 outbound and forwarding traffic is rejected.

I want the recovered cluster functional enough to inspect, but unable to talk to the Internet.

Destructive scripts also require a DR marker, reject the production hostname/IP, and require explicit confirmations. The target reset later gained a non-destructive preflight mode; running the guarded script against production was deliberately tested and refused before making changes.

## First problem: the datastore does not live alone

One early discovery was that restoring only the database and token while keeping TLS/credential material from the clean target could create bootstrap incompatibilities.

The restore strategy changed: preserve the target material in a safety area, restore the datastore, and allow K3s to reconstruct bootstrap material from the recovered state.

That is exactly the kind of detail an existing backup file cannot reveal. It appears only when someone tries to boot the restored system.

## Second problem: local PersistentVolumes remember the old server

My single-node cluster uses `local-path`.

After restoring the physical volume data on the DR host, the Kubernetes PVs still had node affinity for the production hostname and local paths pointing to production storage.

Those fields cannot simply be fixed with a normal patch.

The working transaction was to keep recovered writers at zero replicas, switch reclaim policies to `Retain`, preserve manifests, remove the old PVC/PV objects in the correct order, recreate PVs with DR paths and affinity to the future DR hostname, recreate PVCs pre-bound through `volumeName`, verify fresh UIDs/claimRefs and `Bound` state, and only then activate the node and workloads.

Recovered `Terminating` Pods could also keep references to protected PVCs. The safe solution was not to rip out finalizers indiscriminately, but to identify and remove only the Pods blocking the transaction.

## Third problem: the recovered cluster starts without the DR node

During isolated restore K3s must start agentless (`disable-agent:true`). At that point the API may contain only the restored production Node; the new DR Node does not exist yet.

PV remapping therefore needs to accept node affinity for a **future hostname**. The Node object is registered only when the agent is enabled later.

One of my scripts initially assumed otherwise. The rehearsal found the assumption and turned it into an explicit automation invariant.

## Fourth problem: an image being listed does not make it a backup

I also learned not to treat the production containerd content store as an image backup. During rehearsal, some images that appeared available/running could not be exported because referenced blobs were not present as expected.

The solution was to build a platform-specific `linux/amd64` OCI kit ahead of time, containing required images and origin-generated checksums.

On DR, those images are placed in K3s's native preload directory:

```text
/var/lib/rancher/k3s/agent/images/
```

Validation happens through the CRI, not merely `ctr` output. Recovery is therefore independent of external registries, which is mandatory because the target remains offline.

## GitHub disappears during the disaster too

If the DR security strategy blocks Internet access, the runbook cannot say “now run git pull.”

The recovery kit therefore carries a self-contained, versioned copy of required scripts, checksums, OCI images, and encrypted recovery material. The private age key and other credentials remain outside Git and require independent recovery.

That changed how I think about GitOps: **Git is an excellent source of truth, but it should not be the only medium required to recover the system.**

## And the workloads?

In the full rehearsal, four persistent observability workloads were recovered. Grafana opened its restored SQLite database. Loki recovered checkpoint/WAL and local indexes. Prometheus opened TSDB blocks, replayed WAL/checkpoints, and resumed writing. Tempo became Ready as well.

In one rehearsal Tempo discarded an incomplete WAL block missing `meta.json`. That was another warning: a filesystem copy can be recoverable without being an application-consistent snapshot.

That observation later led to a bounded, measured consistency recovery set.

## The main lesson

Before testing, I had backups. After testing, I had a list of assumptions that had been wrong:

```text
datastore backup != runnable cluster
PV data != usable PV on another node
image in containerd != reliable OCI backup
Git available today != Git available during DR
script exited 0 != postcondition actually satisfied
```

Backup is an artifact. Disaster Recovery is a capability that must be exercised.

Once I could recover the environment, the next question was: **How long does it take?**

In the next article I measure RTO including bootstrap, manual intervention, and problems discovered during rehearsal—and show how the observed time fell from 1h07m09s to 47m03s.

---

Project: `guionardo/guiosoft-k3s-lab`.
