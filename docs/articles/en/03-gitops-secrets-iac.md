# GitOps, secrets, and reproducible infrastructure

After putting applications and observability into my K3s cluster, one question started bothering me:

**How much of this environment exists because it is declared—and how much exists only because I remember the commands I ran?**

The difference is small while the server is healthy. During a rebuild, it is enormous.

The next stage of the homelab was therefore not another application. It was reducing the number of decisions that existed only in the current machine state.

## Three layers, three responsibilities

The project adopted a simple ownership model:

```text
Ansible
  -> Debian and K3s host state

Terraform
  -> external resources

Flux / Kubernetes / Helm
  -> cluster-internal state
```

I did not want Terraform installing K3s on the physical server or Flux configuring Debian. Tools can overlap in capability without overlapping in ownership.

For me, reproducible infrastructure begins when it is clear **who owns each piece of state**.

## Why Flux?

I chose Flux because the repository already contained Kubernetes manifests and Helm configuration, and I had already adopted SOPS + age for secrets.

Native SOPS decryption in the Flux `kustomize-controller` made that combination particularly simple. The pull-based model also fit the lab: after bootstrap, the cluster reads the repository and reconciles itself without requiring a separate CD server.

Other tools remain valid. Argo CD, for example, is an excellent alternative when UI and visual Application workflows are priorities. Flux simply fit the project's existing state better.

## Start with the least dangerous workload

The first workload placed under Flux ownership was `cloudflared`: small, stateless, declarative, and easy to roll back.

Its dependency chain became explicit:

```text
namespace
   |
SOPS secret
   |
cloudflared
```

After validating that chain I tested manual drift, a versioned change, Git rollback, and deliberate Secret deletion followed by reconstruction from the encrypted repository state.

GitOps without a reconstruction test can be little more than optimistic synchronization.

## Secrets in Git—but not plaintext

My rule is simple: no plaintext secret is versioned.

Sensitive manifests are encrypted with SOPS + age. The public recipient may live in the repository; the private identity may not.

The flow is roughly:

```text
Git
 |
 | SOPS-encrypted Secret
 v
Flux
 |
 | runtime age identity
 v
Kubernetes Secret
 |
 v
workload
```

Metadata remains readable while `data`/`stringData` are encrypted. The private age identity is installed at runtime in `flux-system`, but its source remains outside Git.

That has an important Disaster Recovery consequence: **Git alone cannot rebuild the cluster.** An independent copy of the private identity is also required. I later created that off-host backup and tested its recovery.

## Self-healing needs to be observed

After `cloudflared`, I moved Firecrawl under Flux ownership. To test reconciliation without reducing availability, I manually scaled its API from one replica to two. This was positive drift: extra capacity rather than removed capacity.

After reconciliation the Deployment returned to the single replica declared in Git and the endpoint continued responding.

The test was intended to prove this chain:

```text
declared Git state
       !=
manual cluster state
        |
        v
Flux reconciles
        |
        v
state returns to Git
```

## Adopting existing resources without recreating them

Observability was more interesting because Prometheus, Grafana, Loki, Tempo, Alloy, and OpenTelemetry Collector were already running before Flux took ownership.

I did not want GitOps adoption to become a stack reinstall.

The HelmReleases were declared with `releaseName`, `targetNamespace`, and `storageNamespace` matching the existing releases, initially suspended, and then activated one by one in a conservative order:

```text
Alloy
  -> OpenTelemetry Collector
  -> Tempo
  -> Loki
  -> kube-prometheus-stack
```

At every stage I validated HelmRelease readiness, deployed runtime releases, Pods, PVCs, and the functional metrics/logs/traces paths.

GitOps adoption became an ownership migration rather than a blind redeployment.

## GitOps does not replace rollback

I wanted to preserve the ability to stop automation. If reconciliation causes a problem, the first response does not need to be removing Flux. The affected Kustomization or HelmRelease can be suspended, the Git state corrected, and reconciliation resumed.

The same principle appears throughout this project: automation is useful when it also has a clear interruption and rollback path.

## Idempotency as evidence

Ansible participates in rebuilding the SOPS runtime. Re-running the playbook that installs/updates the age identity in `flux-system` after the Secret already existed ended with:

```text
ok=8
changed=0
failed=0
```

More recently I split Ansible variables explicitly into common, production, and DR groups. The production dry-run after that change returned:

```text
ok=16
changed=0
failed=0
```

The DR inventory, meanwhile, defaults consistent backup, R2, and `cloudflared` to `false`.

This is not merely YAML organization. It reduces blast radius: a recovery host must not silently inherit production operating policies.

## What can Git reconstruct?

After this stage the repository represented much more of the system:

```text
Git -> Flux -> Kubernetes
Encrypted Git -> SOPS/age -> Secrets
Ansible -> host/K3s
Terraform -> external resources
```

But the reconstruction question was still unanswered.

I had declarative configuration, encrypted secrets, and backups. Then came the question that changed the direction of the project:

**If the server disappears, can I actually restore everything on another machine?**

Having backups and being able to perform Disaster Recovery are different things. I learned that by doing the restore for real.

That is the next article.

---

Project: `guionardo/guiosoft-k3s-lab`.
