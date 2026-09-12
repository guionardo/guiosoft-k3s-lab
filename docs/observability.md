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
- trace distribuído real `otel-go-demo -> otel-go-downstream` com propagação W3C `traceparent` e os dois `service.name` no mesmo trace no Tempo;
- Loki + Grafana Alloy instalados no cluster;
- gateway Loki acessível pela API;
- coleta de logs do Pod `otel-go-demo` pelo Alloy;
- ingestão `Alloy -> Loki` validada com LogQL;
- correlação real entre log e trace usando o mesmo `trace_id`;
- provisioning e health dos datasources Prometheus, Tempo e Loki no Grafana;
- `make observability-validate` com 13/13 targets Prometheus `up`, query `up` com 13 séries, todos os Pods de monitoring Ready e todos os PVCs Bound;
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

A meta é navegar nos dois sentidos:

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

A correlação no backend e o health dos três datasources estão validados; falta somente validar visualmente os links no Grafana Explore.

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

1. abrir Grafana e validar visualmente Loki -> TraceID -> Tempo;
2. validar também Tempo -> tracesToLogs -> Loki;
3. revisar dashboards padrão;
4. revisar alertas ruidosos/incompatíveis com K3s;
5. repetir a medição de capacidade após alguns dias de retenção e uso normal;
6. adicionar dashboards/alertas customizados essenciais;
7. avaliar exemplars/span metrics quando fizer sentido;
8. somente depois avaliar publicação protegida do Grafana.

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
- https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources
- https://grafana.com/docs/grafana-cloud/connect-externally-hosted/data-sources/tempo/configure-tempo-data-source/configure-trace-to-logs/
- https://grafana.com/docs/tempo/latest/
- https://opentelemetry.io/docs/collector/
- https://opentelemetry.io/docs/languages/go/
