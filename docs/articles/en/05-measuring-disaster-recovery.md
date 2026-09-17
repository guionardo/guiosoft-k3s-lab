# Measuring Disaster Recovery: reducing RTO by 29.9%

After successfully restoring my K3s cluster on a second machine, I could have ended the stage with a comfortable statement:

> Disaster Recovery successfully tested.

But that hides an important question: **How long does recovery actually take?**

That is when I started treating rehearsals not only as functional tests, but as measurable experiments.

## The clock must start before the comfortable part

It is tempting to measure only the automated restore section. I chose a harder definition.

T0 is recorded before K3s bootstrap on the DR target. Observed RTO includes bootstrap, scripts, waiting, operator intervention, and time spent investigating problems discovered during the process.

That makes the number worse—and the information better.

If I need to understand a PV failure or incomplete workload neutralization during a real incident, that time is part of recovery.

## Rehearsal #2

The second full rehearsal produced:

```text
T0: 2026-09-16T02:11:56Z
T1: 2026-09-16T03:19:05Z

Observed RTO: 4029 seconds
              1h 07m 09s
```

At T1 all four persistent workloads were Ready, PV/PVC pairs were Bound to `guionote-hp`, local paths pointed to DR storage, Flux remained suspended, `cloudflared` stayed at zero replicas, and the nftables WAN barrier remained active.

T1 did not mean merely “K3s started.” It meant a recovered state I had defined as operationally verifiable.

## Automate what the rehearsal teaches

The second rehearsal exposed manual steps and fragile assumptions. Instead of only updating the runbook, I turned discoveries into code:

- stage-aware preflight;
- idempotent neutralization;
- restored-state assertions;
- safe PV remapping;
- OCI preload;
- controlled workload activation;
- recovery checkpoints;
- automatic rehearsal reporting;
- self-contained offline kit.

One rule kept repeating: **a command returning success does not prove its postcondition was reached.**

Neutralization, for example, now queries the API again and verifies that Flux is really suspended and relevant Deployments/StatefulSets are at zero replicas before reporting success.

## Rehearsal #3

The third rehearsal used the offline bundle and repeated the measurement while still counting issues discovered during execution:

```text
Rehearsal #2: 4029 s = 1h 07m 09s
Rehearsal #3: 2823 s =    47m 03s

Delta:       -1206 s =   -20m 06s
Improvement: approximately 29.9%
```

I did not remove debugging time from the clock just to produce a prettier number. Even so, observed RTO fell by roughly twenty minutes.

## What was healthy at the end?

At the end of rehearsal #3, `guionote-hp` was Ready and Tempo, Loki, Prometheus, and Grafana were Ready. All four PV/PVC pairs were Bound with DR-local paths and affinity to `guionote-hp`. Nine OCI images from the kit were installed through K3s's native preload mechanism. Flux was suspended, `cloudflared` was at zero replicas, and WAN isolation remained active.

Production remained operational throughout the exercise.

## Bugs found are part of the result

Rehearsal #3 still found problems, and that is useful. Three became explicit invariants.

**Neutralization must verify postconditions.** A successful `kubectl scale` is not enough.

**PV remapping must accept the future DR node.** During agentless restore the DR Node does not yet exist, but affinity can already target the hostname it will register later.

**Reset must remove stale checkpoints.** Old `.done` files can make an orchestrator believe a stage already ran. Reset now removes current recovery state and verifies K3s data/config removal.

The reset was later hardened further with destructive-path guards and `PREFLIGHT_ONLY`. Deliberate tests using `/` and a path outside the allowed namespace failed before stopping services; the valid preflight passed while keeping K3s active, WAN isolation enabled, and protected data mounted.

## RPO is not one number either

Another conceptual correction came from the exercise. Control-plane and persistent-volume backups had been captured at different times, so saying “the RPO is X” hid the difference between the artifacts.

I started recording each snapshot's actual timestamp separately.

That eventually led to a larger improvement: creating a formal control-plane + PV pair while persistent writers remain quiesced.

## Why measure?

Without measurement I might have written:

```text
restore automated and documented
```

With measurement I can say:

```text
observed RTO #2 = 1h07m09s
observed RTO #3 = 47m03s
improvement = ~29.9%
```

More importantly, I can explain **why** it improved.

This was not benchmark optimization. It was the conversion of operational discoveries into deterministic automation.

The largest uncertainty left after these tests was consistency between the control-plane backup and the persistent-volume backup. That led to the next stage: a recovery set with its own identity and a measured 64-second consistency window.

That is the next article.

---

Project: `guionardo/guiosoft-k3s-lab`.
