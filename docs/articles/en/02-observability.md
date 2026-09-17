# Real observability in a small Kubernetes cluster

During the first stage of my Kubernetes homelab, getting a set of Pods into `Running` felt like enough of a victory.

It did not take long for the question to change: **does Running mean healthy?**

And when something becomes slow, how do I discover whether the problem is in the application, cluster, storage, or a downstream call?

That is when the project moved from basic monitoring toward three observability signals: metrics, logs, and traces.

## The architecture

Conceptually, the stack became:

```text
Metrics -> Prometheus
Logs    -> Grafana Alloy -> Loki
Traces  -> OpenTelemetry Collector -> Tempo
UI      -> Grafana
```

I used `kube-prometheus-stack` for Prometheus, Alertmanager, Grafana, the Operator, kube-state-metrics, and node-exporter. Tempo receives traces, Loki stores logs, Alloy collects Pod logs, and OpenTelemetry Collector handles trace ingestion.

All of this runs on one server. That matters: observability also consumes the resources it observes.

## I did not want merely installed components

One project rule is not to consider a stage complete just because Helm returned success.

I created a small Go workload instrumented with OpenTelemetry and Prometheus metrics. It later evolved into two services:

```text
otel-go-demo
     |
     | HTTP + W3C traceparent
     v
otel-go-downstream
```

The application itself was intentionally uninteresting. Its purpose was to produce a signal I could follow through the infrastructure.

For tracing, I validated the full path:

```text
Go application
     |
     | OTLP
     v
OpenTelemetry Collector
     |
     v
Tempo
     |
     v
Grafana
```

The test generates a request, captures its `trace_id`, and looks up that exact trace in Tempo. The demo then grew into two processes so I could verify W3C context propagation and both `service.name` values in the same distributed trace.

That is very different from checking whether the OTLP port is open.

## Logs and traces need to talk to each other

The next step was to put the same `trace_id` in application logs. Alloy collects Pod logs through the Kubernetes API and sends them to Loki. The automated test generates a request, captures the trace ID, queries Loki through LogQL, and succeeds only when it finds a log line containing exactly that ID.

Grafana datasources were then configured for navigation in both directions:

```text
Loki log -> trace_id -> Tempo
Tempo trace -> related logs -> Loki
```

At that point metrics, logs, and traces started to feel like one investigation system instead of three products installed next to each other.

## A small Prometheus metrics discovery

One test initially failed with:

```text
error: custom HTTP metric is not exposed by /metrics
```

The endpoint existed and the collector was registered. The test's expectation was wrong.

Vector metrics such as `CounterVec` and `HistogramVec` do not need to materialize a concrete series before a label combination has been observed. I was looking for the custom family before generating the first request.

The test was changed to first verify that `/metrics` is a valid Prometheus endpoint, generate traffic, and only then require the `otel_demo_*` series.

It was a small fix, but exactly the kind of learning I wanted from the lab: understand behavior, not merely install software.

## Cardinality is also part of design

The demo deliberately limits labels to values such as `service`, `method`, `path`, and `status`. Request IDs, trace IDs, and arbitrary URLs are not metric labels.

Those values are excellent in logs and traces, but can turn Prometheus cardinality into a problem quickly. A small lab is a good place to learn a rule that also applies to large systems: **not every useful piece of information is a good metric label.**

## Dashboards and alerts as code

The application dashboard is declarative. It tracks request rate, p95 latency, HTTP status, in-flight requests, downstream calls, downstream latency, and errors.

I also added alert rules for 5xx rate, elevated p95, and persistent downstream errors. Their thresholds are didactic, not universal SLOs; the purpose is to validate the complete mechanism and then tune it against real workload behavior.

## Observability has a cost

With Prometheus, Alertmanager, Grafana, Loki, Alloy, Tempo, and OpenTelemetry Collector active, one node measurement showed approximately:

```text
CPU:    782m / 13%
Memory: 8331 MiB / 52%
```

This is not a benchmark, only an initial baseline. Still, it makes one point explicit: on a single node, retention, cardinality, caches, and component count are not abstract decisions.

The initial profile is therefore modest: seven days of Prometheus retention, 72 hours for Tempo, and monolithic filesystem-backed Loki with seven days of retention.

## Why Alloy instead of Promtail?

During implementation, Promtail had reached end of life in March 2026. Rather than introduce a new dependency on a retired tool, I adopted Grafana Alloy for log collection.

In this small cluster Alloy collects Pod logs through the Kubernetes API, avoiding privileged `/var/log` mounts.

## The result that mattered

The final validation stopped being:

```text
Did Grafana open? Yes.
```

It became closer to:

```text
request
  |-- metric -> Prometheus
  |-- trace  -> OTel Collector -> Tempo
  `-- log    -> Alloy -> Loki

trace_id connects logs and traces
Grafana queries all three signals
```

Automated tests verify Prometheus targets, component health, PVCs, custom metrics, distributed traces, and log correlation.

Once this worked, a new problem became visible: much of the infrastructure had originally been created operationally. I could observe it, but I also wanted to reconstruct it.

That led the project into GitOps, SOPS, and a stricter separation between declarative configuration and secrets—the subject of the next article.

---

Project: `guionardo/guiosoft-k3s-lab`.
