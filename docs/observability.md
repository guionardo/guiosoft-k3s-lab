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
- OpenTelemetry Go: `1.46.0`;
- Prometheus Go client: `1.24.1`.

As versões são explícitas para manter rebuilds reproduzíveis.

## Estado validado

Já foram validados no cluster atual:

- Prometheus, Alertmanager, Grafana, Operator, kube-state-metrics e node-exporter em `Running`;
- PVC Prometheus de 10 GiB e Grafana de 2 GiB em `local-path`;
- Tempo e OpenTelemetry Collector em `Running`;
- PVC Tempo de 5 GiB em `local-path`;
- trace ponta a ponta `otel-go-demo -> Collector -> Tempo`, incluindo lookup automatizado pelo `trace_id`;
- trace distribuído real `otel-go-demo -> otel-go-downstream` com propagação W3C `traceparent` e os dois `service.name` no mesmo trace no Tempo;
- Loki + Grafana Alloy instalados no cluster;
- gateway Loki acessível pela API;
- coleta de logs do Pod `otel-go-demo` pelo Alloy;
- ingestão `Alloy -> Loki` validada com LogQL;
- correlação real entre log e trace usando o mesmo `trace_id`;
- provisioning e health dos datasources Prometheus, Tempo e Loki no Grafana;
- `make observability-validate` com 13/13 targets Prometheus `up`, query `up` com 13 séries, todos os Pods de monitoring Ready e todos os PVCs Bound;
- métricas customizadas `otel_demo_*` identificadas no Prometheus;
- kubeconfig externo e acesso `kubectl` a partir de outra máquina da LAN.

A validação de logs gerou o trace `44955206ae5e874899a7147290607951` e localizou no Loki uma linha do demo contendo exatamente esse mesmo ID.

## Métricas

```bash
make observability-install
make observability-validate
```

Prometheus usa retenção de 7 dias e PVC de 10 GiB. Grafana usa PVC de 2 GiB. O perfil mantém `kubeEtcd`, `kubeControllerManager` e `kubeScheduler` desabilitados porque o K3s atual usa SQLite e não expõe esses componentes como um cluster kubeadm tradicional.

A validação consolidada mais recente retornou:

```text
Prometheus active targets: 13 total, 13 up, 0 not-up
Prometheus query 'up': 13 series
prometheus health: OK
tempo health: OK
loki health: OK
Observability validation: OK
```

### Métricas customizadas do demo Go

Os dois serviços do demo expõem `/metrics` e são descobertos pelo Prometheus por meio de `ServiceMonitor`.

Principais famílias:

```text
otel_demo_http_requests_total
otel_demo_http_request_duration_seconds
otel_demo_requests_in_flight
otel_demo_downstream_requests_total
otel_demo_downstream_request_duration_seconds
otel_demo_downstream_errors_total
```

As labels foram mantidas deliberadamente com baixa cardinalidade (`service`, `method`, `path` e `status`). IDs de request, trace IDs e URLs arbitrárias não são usados como labels.

Validação:

```bash
make otel-go-demo-install
make otel-go-demo-metrics-test
```

O teste abre port-forwards temporários para a aplicação e Prometheus, gera tráfego em `/work` e exige que Prometheus retorne valores positivos para requests do frontend, buckets de latência, chamadas downstream e requests recebidas pelo segundo serviço.

As métricas customizadas já foram identificadas no Prometheus em runtime.

### Nota: métricas vetoriais são criadas sob demanda

Durante a primeira execução do teste apareceu um falso negativo:

```text
error: custom HTTP metric is not exposed by /metrics
```

A causa não era ausência do endpoint. Em `client_golang`, coletores como `CounterVec` e `HistogramVec` só passam a expor séries concretas depois que uma combinação de labels é observada pela primeira vez. Antes do primeiro request, portanto, a família customizada pode não aparecer no output de `/metrics`.

O teste foi corrigido para:

1. confirmar primeiro que `/metrics` é um endpoint Prometheus válido usando métricas padrão `go_*`;
2. gerar tráfego real;
3. consultar `/metrics` novamente e então exigir as famílias `otel_demo_*`;
4. esperar o próximo scrape do Prometheus;
5. validar as séries via PromQL.

Esse comportamento é importante para interpretar corretamente endpoints Prometheus e evitar diagnosticar como falha uma métrica vetorial ainda sem valores de labels materializados.

### Dashboard customizado

O demo possui agora um dashboard declarativo do Grafana chamado:

```text
OTel Go Demo - Application Metrics
```

Ele é entregue como `ConfigMap` no namespace `monitoring`, com label `grafana_dashboard: "1"`, permitindo que o sidecar do Grafana carregue a definição automaticamente.

Painéis iniciais:

- taxa de requests por serviço;
- latência HTTP p95 por serviço/path;
- taxa por status HTTP;
- requests em andamento;
- taxa de chamadas downstream;
- latência downstream p95;
- taxa de erros downstream.

PromQL de exemplo usado no dashboard:

```promql
sum by (service) (rate(otel_demo_http_requests_total[2m]))
```

```promql
histogram_quantile(
  0.95,
  sum by (le, service, path) (
    rate(otel_demo_http_request_duration_seconds_bucket[5m])
  )
)
```

### Alertas de aplicação

Foi adicionado um `PrometheusRule` com três regras didáticas:

- `OtelGoDemoHighErrorRate`: taxa de respostas 5xx acima de 5% por 5 minutos, exigindo também tráfego mínimo;
- `OtelGoDemoHighP95Latency`: p95 de `/work` acima de 500 ms por 5 minutos;
- `OtelGoDemoDownstreamErrors`: erros downstream contínuos por 5 minutos.

Esses thresholds não são tratados como SLOs universais. Eles servem como primeira experiência com alerting baseado em métricas reais da aplicação e devem ser ajustados conforme o workload.

`make otel-go-demo-metrics-test` agora também confirma que as três regras foram carregadas pela API do Prometheus e valida a estrutura do dashboard declarativo.

## Baseline de recursos

Com Prometheus, Alertmanager, Grafana, Loki, Alloy, Tempo e OpenTelemetry Collector ativos, `make observability-validate` registrou no node:

```text
CPU:    ~782m / 13%
Memory: ~8331 MiB / 52%
```

Maiores consumidores de memória observados nessa amostra:

```text
Grafana        ~440 MiB
Prometheus     ~337 MiB
Loki            ~94 MiB
Tempo           ~86 MiB
Loki rules SC   ~79 MiB
Grafana dashboard sidecar ~74 MiB
Grafana datasource sidecar ~73 MiB
Alloy           ~47 MiB
OTel Collector  ~30 MiB
```

Essa é apenas uma amostra pontual, útil como baseline inicial. A revisão de capacidade deve ser repetida depois de alguns dias de retenção e carga normal para observar crescimento de storage, cardinalidade e uso de memória.

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

O demo Go gera um span raiz e spans internos, retorna o `trace_id` e já teve o caminho real até o Tempo validado. O demo também foi expandido para dois processos e a propagação distribuída `otel-go-demo -> otel-go-downstream` foi validada em runtime no mesmo trace.

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

O primeiro target instala Loki e Alloy, reaplica o `kube-prometheus-stack`, reinicia o workload do Grafana para recarregar o provisioning de datasources e valida via API que Prometheus, Tempo e Loki existem.

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

## Correlação e datasources no Grafana

O Grafana recebe datasources declarativos para:

- Prometheus (`uid: prometheus`), criado pelo `kube-prometheus-stack`;
- Tempo (`uid: tempo`);
- Loki (`uid: loki`).

O datasource Loki contém um `derivedFields` para reconhecer:

```text
trace_id=([0-9a-f]{32})
```

e criar link interno para o datasource Tempo.

O datasource Tempo recebe `tracesToLogsV2` apontando para Loki, mapeando `service.name` para label `app` e filtrando pelo trace ID.

A navegação foi validada nos dois sentidos:

```text
Loki log -> TraceID -> Tempo trace
Tempo trace -> tracesToLogs -> Loki logs
```

Como datasources provisionados podem exigir reload/restart do Grafana após uma mudança na configuração, existem targets explícitos:

```bash
make observability-grafana-reload
make observability-grafana-datasources
```

`observability-grafana-reload` reinicia o StatefulSet/Deployment do Grafana e depois valida os datasources. `observability-grafana-datasources` consulta a API do Grafana via port-forward local e exige a presença dos UIDs `prometheus`, `tempo` e `loki`.

## Acesso ao Grafana

Grafana continua sem Ingress. Por padrão:

```bash
make observability-grafana
```

abre somente em:

```text
http://127.0.0.1:3000
```

Para acesso pela LAN administrativa:

```bash
make observability-grafana ADDRESS=192.168.88.9
```

Também é possível sobrescrever a porta:

```bash
make observability-grafana ADDRESS=192.168.88.9 PORT=3000
```

## Próximas etapas

1. executar novamente `make otel-go-demo-install` para aplicar dashboard e `PrometheusRule`;
2. executar `make otel-go-demo-metrics-test` para confirmar regras e dashboard declarativo;
3. abrir o dashboard `OTel Go Demo - Application Metrics` no Grafana e validar os painéis com tráfego real;
4. revisar dashboards padrão;
5. revisar alertas ruidosos/incompatíveis com K3s;
6. repetir a medição de capacidade após alguns dias de retenção e uso normal;
7. avaliar exemplars/span metrics quando fizer sentido;
8. somente depois avaliar publicação protegida do Grafana.

## Fontes

- https://github.com/prometheus/client_golang
- https://prometheus-operator.dev/docs/developer/getting-started/
- https://prometheus-operator.dev/docs/getting-started/design/
- https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/
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
- https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources
- https://grafana.com/docs/grafana-cloud/connect-externally-hosted/data-sources/tempo/configure-tempo-data-source/configure-trace-to-logs/
- https://grafana.com/docs/tempo/latest/
- https://opentelemetry.io/docs/collector/
- https://opentelemetry.io/docs/languages/go/
