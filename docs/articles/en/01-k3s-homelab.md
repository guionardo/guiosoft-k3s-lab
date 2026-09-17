# From a Debian server to a Kubernetes platform at home

A few days ago I started a project that seemed relatively simple: turn a Debian server I have at home into a small Kubernetes environment.

The original idea was to install K3s and use it as a laboratory for topics I work with every day: containers, observability, GitOps, automation, and distributed applications.

But I added one rule: **the cluster would not be just a disposable lab. I would run real applications on it.**

That changed the decisions considerably.

Once there are applications I want to keep running, installing Kubernetes stops being the most interesting part of the problem.

Where does the data live? How do I administer the cluster from another machine? How do I publish an application without opening inbound ports on my network? Where do secrets live? What happens after a reboot? How do I reproduce the server configuration? And eventually a more uncomfortable question appears: if this server dies today, can I rebuild everything?

What started as a K3s installation became a platform-engineering exercise.

## Why K3s?

The initial environment is deliberately small: one physical server running Debian 13.

I did not want to start by building a large cluster merely to learn how to operate a large cluster. The goal was to reduce initial operational cost without giving up the Kubernetes primitives I wanted to study: Deployments, StatefulSets, Services, Ingress, PVCs, scheduling, observability, and GitOps.

So I started with single-node K3s.

There is an important limitation: two replicas of an application on the same server can protect against a process or Pod failure, but not against physical machine failure. From the host perspective, this is not high availability. In my case, that limitation is intentional and part of the lab.

## The server already existed

The Debian host did not start empty. Services were already running directly on it, and I did not want Kubernetes adoption to become a big-bang migration.

The initial architecture therefore had to support two worlds for a while:

```text
Internet
   |
Cloudflare
   |
Debian 13
   |-- services still on the host
   |
   `-- K3s
       |-- Traefik
       |-- Services
       `-- migrated workloads
```

Each application could move independently. Its public route would change only after the corresponding K3s workload had been validated. That gives migrations a property I value: **small rollback scope**.

## Networking: a simple decision that avoids future trouble

The host also ran Docker, so before installing the cluster I explicitly chose K3s networks:

```text
Pod CIDR:     10.42.0.0/16
Service CIDR: 10.43.0.0/16
```

The intent was to keep them away from the existing Docker bridges in the `172.x` ranges.

I also configured kubeconfig for administration from another machine on the LAN. The advertised address could not remain `127.0.0.1` or `localhost`: the cluster needed to be administered as infrastructure, not only from the server's local shell.

## Why keep Traefik when I already had Cloudflare Tunnel?

I already used Cloudflare Tunnel to publish services. Because the tunnel is established outbound, I do not need to open a router port for every application.

The target path became:

```text
Internet
   |
Cloudflare DNS / Tunnel
   |
cloudflared in K3s
   |
Traefik
   |
Ingress
   |
Service
   |
Pod
```

It would be technically possible to point `cloudflared` directly at some Services. I deliberately kept Traefik in the path because I want Ingress, middleware, and routing to remain Kubernetes responsibilities. Cloudflare is the external entry point; I do not want it to become a catalog of every application's internal topology.

Later, `cloudflared` itself moved from a host service into K3s with two replicas. The old host installation was preserved but disabled as a rollback path during the transition.

## Storage: reconstructable configuration is not persistent data

I started with K3s's `local-path` provisioner. For a single-node cluster it is simple and sufficient for learning PVCs and persistent workloads.

But one distinction became increasingly important: **manifests can be reconstructed; data cannot necessarily be reconstructed.**

K3s storage was organized so local volumes live in a known disk area, separating configuration, persistent data, and backups. That distinction later became essential when I started testing real Disaster Recovery.

## Infrastructure as Code, with separate responsibilities

I did not want one tool trying to control everything. I divided ownership:

```text
Ansible
  -> Debian
  -> packages
  -> K3s
  -> directories
  -> firewall
  -> host configuration

Terraform
  -> external resources
  -> Cloudflare
  -> off-host backup storage

Kubernetes / Helm / Flux
  -> resources inside the cluster
  -> applications
  -> observability
  -> declarative workload configuration
```

The physical host has a different lifecycle from a Kubernetes Deployment, and both differ from an external resource.

I later pushed this separation further in Ansible: common, production, and Disaster Recovery variables now belong to different groups. By default, the DR inventory does not inherit production off-host backup automation or `cloudflared`.

## Firewall and reducing host surface

Installing Kubernetes should not mean ignoring the operating system underneath it.

The host received a dedicated nftables policy, persisted through systemd and validated after reboot. Installed but unnecessary listeners such as NFS/RPC, PCP, and Cockpit were disabled reversibly.

The objective was not a generic hardening checklist. It was to reduce the actual surface found on that server without destroying rollback options.

## The first result

At this point the server was still a physical machine at home, but it had become a platform with single-node K3s, Traefik, Cloudflare Tunnel running inside the cluster, real workloads, known persistent storage, persistent firewall policy, Ansible-managed host configuration, Terraform-managed external resources, and remote LAN administration.

And exactly when everything started working, the next question appeared:

**How do I know all of this is working well?**

`kubectl get pods` is an excellent tool, but it is not an observability strategy.

In the next article I will show how this small cluster gained metrics, logs, and traces—and why installing Grafana was only a small part of the problem.

---

Project: `guionardo/guiosoft-k3s-lab`.
