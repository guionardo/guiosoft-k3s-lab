---
created: 2026-10-16T19:14:17.656Z
title: Self-hosted GitHub runner for cross-platform test matrix
area: infrastructure
severity: major
files:
  - .github/workflows/articles.yml
  - .planning/todos/pending/2026-10-16-disposable-windows-10-11-test-vm-on-guiosoft-info.md
  - ansible/roles/
---

## Problem

Some projects need to be verified on **Linux, macOS and Windows** before they can be called working. Today there is no way to run that matrix locally on demand — tests are run manually, per machine, ad hoc.

The requirement is not just "have a runner" but **disposable and recreated on demand**: a clean environment per run, with no accumulated state, so results do not drift between runs.

A self-hosted GitHub Actions runner is the same machine as the disposable Windows VM captured separately — both want "throw away and rebuild for each job". GitHub supports **ephemeral runners** that register, execute a single job and deregister; combined with a btrfs subvolume per run, a clean environment costs about a second to create and nothing to delete.

## Relationship to other work

- Extends `2026-10-16-disposable-windows-10-11-test-vm-on-guiosoft-info` — the Windows leg of this matrix is that VM. The golden base image becomes the runner image.
- Shares the storage-layout project: btrfs subvolume-per-run is the same isolation primitive used for per-customer and per-tenant separation.
- Connects to **Ariadne**, which already integrates GitHub and needs reproducible, isolated execution contexts.

## The central design tension

The natural host — `guiosoft-info` — is also the production K3s box. A self-hosted runner executes code pulled straight out of a repository, with network reach to everything on the host. On this machine that means proximity to:

- SOPS/age key material and the decrypted `clusters/guiosoft-info/*-secrets.yaml` workloads (cloudflare, planetapeia, firecrawl)
- the K3s datastore at `/var/lib/rancher/k3s` and local-path PVs under `/mnt/store1`, `/mnt/store2`
- Immich uploads and its PostgreSQL
- production monitoring (Grafana, Prometheus, Loki, Tempo)

btrfs subvolumes constrain the *filesystem* blast radius but do nothing for network reach or secret access. This needs a deliberate answer, not a default.

## Solution (hints — design not yet decided)

- **Ephemeral over persistent.** Register with `--ephemeral`, `--labels`, `--no-default-labels`, and JIT configuration for `runs-on: [self-hosted, windows, x64]` so the workflow triggers the runner rather than the runner waiting for work.
- **Isolation per job:** one btrfs subvolume per run, created on demand and deleted after. For the Windows leg, a qcow2 overlay on a golden image, or the subvolume directly.
- **Secrets hygiene:** jobs must not run with production SOPS/age material reachable. Either a dedicated runner host, a network-restricted runner, or an explicit statement that fork/PR workflows never run here.

## Open questions

1. Does the matrix need a **macOS** leg, and if so where does it run? It cannot be virtualised on this Linux host — a self-hosted runner on one of the Macs, or GitHub's macOS runners (which cost roughly 10x the Linux multiplier).
2. Should the Linux leg run **on `guiosoft-info` itself**, given that is the production K3s box, or on a separate VM with the same btrfs-subvolume-per-run mechanism?
3. Which repositories are in scope — private only, or public ones where fork PRs are a real code-execution vector?
4. What is the acceptable job timeout and concurrency, given 15Gi RAM with only ~5.7Gi available and k3s/Immich/monitoring already resident?

## Known constraint

Memory, not disk, is the binding limit: 15Gi total, ~5.7Gi available. A Windows VM wants 4–8GB and will contend with K3s. More RAM is a cheap upgrade and likely worth more than any storage change.