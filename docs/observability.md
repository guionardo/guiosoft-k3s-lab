# Observability

## Objetivo

Construir uma stack de observabilidade completa para o homelab cobrindo métricas, logs e traces sem expor endpoints publicamente e sem consumir recursos excessivos do host single-node atual.

```text
Metrics -> Prometheus
Logs    -> Grafana Alloy -> Loki
Traces  -> OpenTelemetry Collector -> Tempo
UI      -> Grafana
```

## Versões pinadas

- Helm: `v4.3.0`;
- kube-prometheus-stack: `89.2.0`;
- Grafana Tempo chart: `2.2.3`;
- OpenTelemetry Collector chart: `0.172.1`;
- Grafana Loki community chart: `18.5.0` (Loki `3.7.3`);
- Grafana Alloy chart: `1.12.1` (Alloy `v1.19.2`);
- Go demo toolchain: `1.27.1`;
- OpenTelemetry Go: `1.46.0`.

As versões são explícitas para manter rebuilds reproduzíveis.

## Estado validado

Já foram validados no cluster atual:

- Prometheus, Alertmanager, Grafana, Operator, kube-state-metrics e node-exporter em `Running`;
- PVC Prometheus de 10 GiB e Grafana de 2 GiB em `local-path`;
- Tempo e OpenTelemetry Collector em `Running`;
- PVC Tempo de 5 GiB em `local-path`;
- trace ponta a ponta `otel-go-demo -> Collector -> Tempo`, incluindo lookup automatizado pelo `trace_id`;
- Loki + Grafana Alloy instalados no cluster;
- gateway Loki acessível pela API;
- coleta de logs do Pod `otel-go-demo` pelo Alloy;
- ingestão `Alloy -> Loki` validada com LogQL;
- correlação real entre log e trace usando o mesmo `trace_id`;
- kubeconfig externo e acesso `kubectl` a partir de outra máquina da LAN.

A validação de logs gerou o trace `44955206ae5e874899a7147290607951` e localizou no Loki uma linha do demo contendo exatamente esse mesmo ID.

## Métricas

```bash
make observability-install
make observability-validate
```

Prometheus usa retenção de 7 dias e PVC de 10 GiB. Grafana usa PVC de 2 GiB. O perfil mantém `kubeEtcd`, `kubeControllerManager` e `kubeScheduler` desabilitados porque o K3s atual usa SQLite e não expõe esses componentes como um cluster kubeadm tradicional.

## Tracing

```text
Application
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

Operação:

```bash
make observability-tracing-install
make observability-tracing-status
make otel-go-demo-install
make otel-go-demo-test
```

Tempo usa single-binary, PVC `local-path` de 5 GiB e retenção inicial de 72 horas. Collector usa somente pipeline de traces nessa primeira etapa.

O demo Go gera um span raiz e spans internos, retorna o `trace_id` e já teve o caminho real até o Tempo validado.

## Logs: Loki + Grafana Alloy

Promtail não é usado. Ele atingiu EOL em 2 de março de 2026 e a evolução de coleta de logs da Grafana passou para Alloy.

Arquitetura:

```text
Kubernetes Pods
      |
      | Kubernetes API
      v
Grafana Alloy
      |
      | Loki push API
      v
Loki gateway
      |
      v
Grafana
```

### Loki

O homelab usa o community chart atual, não o chart antigo do repositório Grafana/GEL. Desde março de 2026, o chart OSS é mantido em `grafana-community/helm-charts`.

Perfil inicial:

- `deploymentMode: Monolithic`;
- 1 replica;
- TSDB schema v13;
- filesystem object store;
- PVC `local-path` de 5 GiB;
- retenção `168h` (7 dias);
- caches distribuídos desabilitados para reduzir footprint;
- gateway interno `ClusterIP`;
- nenhum Ingress;
- MinIO desabilitado.

Filesystem é uma escolha deliberada para laboratório/baixo volume. Não é tratado como storage de produção e os logs históricos são considerados dados operacionais reconstruíveis.

### Alloy

Alloy é instalado como um Deployment single-replica. Para este cluster pequeno, ele coleta Pod logs via Kubernetes API usando `loki.source.kubernetes`, evitando mounts privilegiados de `/var/log`.

Labels mantidos:

```text
cluster
app (quando presente)
namespace
pod
container
```

Destino interno:

```text
http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push
```

### Instalação e status

```bash
make observability-logging-install
make observability-logging-status
```

O primeiro target instala Loki e Alloy e depois reaplica o `kube-prometheus-stack` para provisionar os datasources Grafana.

### Validação automática

O demo Go registra a linha:

```text
request completed service=otel-go-demo method=GET path=/work trace_id=<32 hex chars>
```

O target:

```bash
make observability-logging-test
```

executa:

1. port-forward temporário para Loki e para o demo;
2. chamada `/work`;
3. captura do `trace_id` retornado;
4. consulta LogQL ao Loki pelo mesmo `trace_id`;
5. sucesso apenas quando existe uma linha de log correspondente.

Esse fluxo foi validado no cluster atual:

```text
Trace generated for log correlation: 44955206ae5e874899a7147290607951
Loki log lookup: OK
Trace ID found in logs: 44955206ae5e874899a7147290607951
```

Logo, temos evidência real de:

```text
request
  ├── trace -> OTel Collector -> Tempo
  └── log   -> Alloy -> Loki
                 ^
                 |
            mesmo trace_id
```

## Correlação no Grafana

O Grafana recebe dois datasources declarativos:

- `Tempo` (`uid: tempo`);
- `Loki` (`uid: loki`).

O datasource Loki contém um `derivedFields` para reconhecer:

```text
trace_id=([0-9a-f]{32})
```

e criar link interno para o datasource Tempo.

O datasource Tempo recebe `tracesToLogsV2` apontando para Loki, mapeando `service.name` para label `app` e filtrando pelo trace ID.

A meta é navegar nos dois sentidos:

```text
Loki log -> TraceID -> Tempo trace
Tempo trace -> tracesToLogs -> Loki logs
```

A correlação no backend está validada; falta somente validar visualmente os links no Grafana Explore.

## Acesso ao Grafana

Grafana continua privado, sem Ingress:

```bash
make observability-grafana
```

Acesso local:

```text
http://127.0.0.1:3000
```

## Próximas etapas

1. executar/revisar `make observability-validate` para os scrape targets Prometheus;
2. abrir Grafana e validar visualmente Loki -> TraceID -> Tempo;
3. validar também Tempo -> tracesToLogs -> Loki;
4. revisar dashboards padrão e alertas ruidosos/incompatíveis com K3s;
5. revisar consumo de CPU/memória/storage da stack completa;
6. evoluir o demo para dois serviços com propagação distribuída;
7. adicionar exemplars/span metrics quando fizer sentido;
8. adicionar dashboards/alertas customizados essenciais;
9. somente depois avaliar publicação protegida do Grafana.

## Fontes

- https://grafana.com/docs/loki/latest/setup/install/helm/
- https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/
- https://grafana.com/docs/loki/latest/operations/storage/filesystem/
- https://grafana.com/docs/loki/latest/operations/storage/schema/
- https://artifacthub.io/packages/helm/grafana-community/loki
- https://grafana.com/docs/alloy/latest/set-up/install/kubernetes/
- https://grafana.com/docs/alloy/latest/collect/logs-in-kubernetes/
- https://artifacthub.io/packages/helm/grafana/alloy
- https://grafana.com/docs/loki/latest/send-data/promtail/
- https://grafana.com/docs/grafana/latest/datasources/loki/
- https://grafana.com/docs/grafana-cloud/connect-externally-hosted/data-sources/tempo/configure-tempo-data-source/configure-trace-to-logs/
- https://grafana.com/docs/tempo/latest/
- https://opentelemetry.io/docs/collector/
- https://opentelemetry.io/docs/languages/go/
