# Observability

## Objetivo

Construir uma stack de observabilidade completa para o homelab cobrindo métricas, logs e traces sem expor endpoints publicamente e sem consumir recursos excessivos do host single-node atual.

Arquitetura alvo:

```text
Applications
   |
   | OTLP
   v
OpenTelemetry Collector
   |
   v
Tempo
   |
   +----------------------+
                          |
Prometheus  <-------------+  exemplars / future span metrics
   |
Loki      <---------------+  future trace_id correlation
   |
   v
Grafana
```

A stack base usa `kube-prometheus-stack`, que reúne Prometheus Operator, Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter, dashboards e regras padrão. Logs serão adicionados com Loki e tracing usa Grafana Tempo com OpenTelemetry Collector como ponto central de ingestão.

## Versões pinadas

- Helm: `v4.3.0`;
- kube-prometheus-stack: `89.2.0`;
- Grafana Tempo single-binary chart: `2.2.3`;
- OpenTelemetry Collector Helm chart: `0.172.1`.

As versões são explícitas para manter rebuilds reproduzíveis. Atualizações devem ser feitas de forma consciente, revisando notas de upgrade e CRDs.

## Estado validado no host

A instalação do `kube-prometheus-stack` foi executada com sucesso no cluster K3s atual. Foram observados em `Running`:

- Prometheus;
- Alertmanager;
- Grafana;
- Prometheus Operator;
- kube-state-metrics;
- node-exporter.

Os CRs de Prometheus e Alertmanager estavam reconciliados e disponíveis. Também foram confirmados dois PVCs `Bound` usando `local-path`:

- Prometheus: 10 GiB;
- Grafana: 2 GiB.

Essa validação comprova que a stack foi instalada e que os componentes principais e seus volumes persistentes estão operacionais. A saúde dos scrape targets e os dashboards ainda são validados separadamente.

## Métricas

```bash
make tools
make observability-install
```

O `make tools` instala Helm via Ansible. `make observability-install` cria o namespace `monitoring` e executa `helm upgrade --install` usando:

```text
kubernetes/observability/kube-prometheus-stack-values.yaml
```

O perfil inicial foi ajustado para o servidor single-node atual:

- Prometheus com retenção de 7 dias e limite aproximado de 6 GB;
- PVC Prometheus de 10 GiB usando `local-path`;
- Grafana com PVC de 2 GiB;
- Alertmanager single-replica;
- `kubeEtcd`, `kubeControllerManager` e `kubeScheduler` desabilitados porque o K3s atual usa SQLite e esses componentes não são expostos como em um cluster kubeadm tradicional;
- requests/limits conservadores para evitar competição desnecessária com os workloads existentes.

Métricas são importantes operacionalmente, mas os dados históricos de Prometheus/Grafana ainda não são classificados como dados críticos de negócio. A política de backup de PVCs continua separada.

### Validação de métricas e targets

Depois da instalação, execute:

```bash
make observability-validate
```

O target é somente leitura. Ele:

- aguarda os Pods do namespace `monitoring` ficarem Ready;
- confirma que os PVCs estão `Bound`;
- consulta a API do Prometheus através do proxy autenticado do Kubernetes API server, sem expor porta externa;
- verifica que existe pelo menos um scrape target ativo;
- falha se algum target ativo estiver com health diferente de `up`;
- executa a query Prometheus `up` e confirma que existem séries retornadas;
- mostra `kubectl top` para node e containers do namespace quando metrics-server estiver disponível.

## Tracing: Tempo + OpenTelemetry Collector

Para o homelab, Tempo usa modo **single-binary** em vez do modo distribuído. Isso reduz a quantidade de componentes e é suficiente para um cluster single-node de laboratório.

O Collector é deliberadamente colocado entre as aplicações e o backend:

```text
Go / Java / Node / .NET app
        |
        | OTLP gRPC :4317
        | OTLP HTTP :4318
        v
OpenTelemetry Collector
        |
        | OTLP gRPC interno
        v
      Tempo
        |
        v
     Grafana
```

As aplicações não precisam conhecer detalhes do Tempo. Elas enviam OTLP para o Collector; isso permite alterar backend, sampling, batching e roteamento posteriormente sem reconfigurar todos os serviços.

Arquivos:

```text
kubernetes/observability/tempo-values.yaml
kubernetes/observability/opentelemetry-collector-values.yaml
scripts/tracing-install.sh
```

Instalação:

```bash
make observability-tracing-install
```

O target instala/atualiza:

- `grafana-community/tempo` em single-binary mode;
- `open-telemetry/opentelemetry-collector` como Deployment;
- depois reaplica o `kube-prometheus-stack` para provisionar o datasource Tempo no Grafana.

Estado:

```bash
make observability-tracing-status
```

Configuração inicial:

- Tempo com PVC `local-path` de 5 GiB;
- retenção de traces de 72 horas;
- OTLP gRPC e HTTP habilitados;
- Collector com um único pipeline de traces;
- logs e métricas no Collector desabilitados nessa primeira etapa para não duplicar responsabilidades;
- nenhum Ingress para Tempo ou Collector;
- datasource Tempo provisionado no Grafana com node graph habilitado.

Endpoints internos planejados:

```text
OTLP gRPC: otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4317
OTLP HTTP: http://otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4318
Tempo query: http://tempo.monitoring.svc.cluster.local:3200
```

O próximo passo após validar a infraestrutura é instrumentar um workload simples em Go e confirmar um trace end-to-end no Grafana.

## Logs: Loki

Loki continua planejado como backend de logs. A implementação será feita depois da validação de Prometheus/Grafana e da fundação de tracing.

A correlação alvo é:

```text
metric spike -> exemplar/trace_id -> Tempo trace -> trace_id -> Loki logs
```

Quando Loki entrar, o datasource do Grafana e os campos `tracesToLogs`/`logsToTraces` serão configurados explicitamente.

## Acesso ao Grafana

Nenhum Ingress é criado nesta primeira etapa. Isso evita publicar Grafana automaticamente pelo wildcard Cloudflare.

Para acesso local:

```bash
make observability-grafana
```

O target mostra a senha administrativa gerada pelo chart e inicia um port-forward local para:

```text
http://127.0.0.1:3000
```

O password não é versionado no Git.

## Estado e diagnóstico

```bash
make observability-status
make observability-tracing-status
```

## Próximas etapas

1. validar targets Prometheus com `make observability-validate`;
2. abrir Grafana localmente e validar dashboards padrão;
3. instalar e validar Tempo + OpenTelemetry Collector;
4. instrumentar um workload Go de laboratório e validar OTLP -> Collector -> Tempo -> Grafana;
5. revisar consumo de CPU/memória/storage após estabilização;
6. revisar alertas ruidosos ou incompatíveis com K3s;
7. adicionar Loki;
8. configurar correlação metrics -> traces -> logs;
9. adicionar dashboards e alertas customizados;
10. somente depois avaliar publicação protegida do Grafana via Cloudflare.

## Fontes

- kube-prometheus-stack chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- Artifact Hub kube-prometheus-stack: https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack
- Prometheus Operator: https://prometheus-operator.dev/
- Prometheus HTTP API: https://prometheus.io/docs/prometheus/latest/querying/api/
- Kubernetes API service proxy: https://kubernetes.io/docs/tasks/access-application-cluster/access-cluster-services/
- Helm install docs: https://helm.sh/docs/intro/install/
- Helm releases: https://github.com/helm/helm/releases
- Grafana Tempo Helm charts: https://grafana.com/docs/tempo/latest/setup/helm-chart/
- Grafana Community Helm repository: https://grafana-community.github.io/helm-charts/
- Tempo package: https://artifacthub.io/packages/helm/grafana-community/tempo
- OpenTelemetry Collector: https://opentelemetry.io/docs/collector/
- OpenTelemetry Collector Helm chart: https://opentelemetry.io/docs/platforms/kubernetes/helm/collector/
- OpenTelemetry Helm chart releases: https://github.com/open-telemetry/opentelemetry-helm-charts/releases
