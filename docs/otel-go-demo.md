# OpenTelemetry Go demo

## Objetivo

Validar tracing distribuído, logs correlacionados, métricas customizadas, alertas e investigação de incidente no cluster com dois serviços Go descartáveis.

```text
HTTP request
   |
   v
otel-go-demo
   |
   | W3C tracecontext
   v
otel-go-downstream
   |
   +--------------------+
                        |
              OTLP gRPC para ambos
                        |
                        v
          OpenTelemetry Collector
                        |
                        v
                      Tempo

/metrics dos dois serviços
          |
          v
     ServiceMonitor
          |
          v
      Prometheus
          |
          +--> PrometheusRule / alert state
          |
          v
        Grafana

Pod logs -> Grafana Alloy -> Loki
```

O serviço `otel-go-demo` recebe `/work`, cria o span servidor raiz, executa etapas internas e chama `otel-go-downstream` em `/process`. Antes da chamada HTTP ele injeta o contexto W3C `traceparent`; o downstream extrai esse contexto e cria seu próprio span servidor no mesmo trace.

Os dois serviços enviam spans ao OpenTelemetry Collector, escrevem `trace_id` nos logs e expõem métricas Prometheus em `/metrics`.

Quando a chamada downstream falha, o frontend também preserva o `trace_id` na resposta HTTP e no log de erro, marca os spans como erro e retorna JSON com HTTP 502. Isso permite investigar uma falha real atravessando métricas, alertas, logs e traces.

## Versões

- Go toolchain: `1.27.1`;
- OpenTelemetry Go API/SDK/exporter: `1.46.0`;
- Prometheus Go client: `1.24.1`.

As dependências são pinadas em `kubernetes/apps/otel-go-demo/app/go.mod`.

## Componentes

A mesma imagem local é reutilizada com configurações diferentes:

```text
otel-go-demo
  SERVICE_NAME=otel-go-demo
  DOWNSTREAM_URL=http://otel-go-downstream.lab.svc.cluster.local:8080/process

otel-go-downstream
  SERVICE_NAME=otel-go-downstream
```

O downstream permanece somente como `ClusterIP` e não possui Ingress.

## Métricas customizadas

A aplicação expõe:

```text
otel_demo_http_requests_total
otel_demo_http_request_duration_seconds
otel_demo_requests_in_flight
otel_demo_downstream_requests_total
otel_demo_downstream_request_duration_seconds
otel_demo_downstream_errors_total
```

As labels foram mantidas deliberadamente de baixa cardinalidade: `service`, `method`, `path`, `status`.

O `ServiceMonitor/otel-go-demo`, no namespace `monitoring`, seleciona os Services `otel-go-demo` e `otel-go-downstream` no namespace `lab` e faz scrape de `/metrics` a cada 30 segundos.

Consultas úteis:

```promql
rate(otel_demo_http_requests_total[5m])
```

```promql
histogram_quantile(
  0.95,
  sum by (le) (
    rate(otel_demo_http_request_duration_seconds_bucket[5m])
  )
)
```

```promql
sum(rate(otel_demo_downstream_errors_total[5m]))
/
sum(rate(otel_demo_downstream_requests_total[5m]))
```

## Dashboard e alertas

O dashboard `OTel Go Demo - Application Metrics` mostra throughput, p95, status HTTP, requests em andamento, chamadas downstream, latência downstream e erros downstream.

As regras didáticas são:

```text
OtelGoDemoHighErrorRate
OtelGoDemoHighP95Latency
OtelGoDemoDownstreamErrors
```

Os thresholds foram escolhidos para o laboratório e não representam SLOs de produção.

## Por que a imagem é local

O laboratório ainda não depende de registry para workloads experimentais. O fluxo usa o Docker do host para construir a imagem e importa o resultado diretamente no containerd interno do K3s:

```text
Docker build
   |
Docker save
   |
   v
sudo k3s ctr images import
   |
   v
K3s Pods (imagePullPolicy: Never)
```

Como a tag local `:dev` é reutilizada, o script força rollout dos dois Deployments após cada import para garantir que o binário recém-construído seja realmente executado.

## Operação

Instalar/rebuildar:

```bash
make otel-go-demo-install
```

Status:

```bash
make otel-go-demo-status
```

Validar trace distribuído:

```bash
make otel-go-demo-test
```

A validação só passa quando o Tempo encontra o mesmo trace contendo `service.name=otel-go-demo` e `service.name=otel-go-downstream`.

Validar métricas customizadas, regras e definição do dashboard:

```bash
make otel-go-demo-metrics-test
```

O teste gera tráfego, espera o scrape e consulta a API do Prometheus.

## Controlled incident drill

O target:

```bash
make otel-go-demo-incident-test
```

executa um experimento controlado exclusivamente nos workloads descartáveis do demo:

1. registra o número atual de replicas do `otel-go-downstream`;
2. escala temporariamente o downstream para `0`;
3. gera uma sequência de requests em `/work` e exige HTTP `502`;
4. captura o `trace_id` de uma requisição com falha;
5. espera Prometheus observar `otel_demo_downstream_errors_total` e HTTP 502;
6. exige que `OtelGoDemoDownstreamErrors` fique `pending` ou `firing`;
7. procura o mesmo `trace_id` no Loki;
8. procura o mesmo trace no Tempo;
9. restaura automaticamente o número original de replicas do downstream;
10. faz uma chamada final e exige recuperação com `downstream=ok`.

Fluxo esperado:

```text
Downstream indisponível
        |
        v
/work -> HTTP 502
        |
        +--> metric -> Prometheus -> alert pending/firing
        |
        +--> log com trace_id -> Alloy -> Loki
        |
        +--> span error -> OTel Collector -> Tempo
        |
        v
Downstream restaurado -> /work volta a responder normalmente
```

O script possui `trap` de limpeza para restaurar o downstream mesmo se uma validação falhar. Ele não altera PVCs, storage, Cloudflare, secrets ou serviços fora do demo.

Importante: as regras reais usam `for: 5m`. O drill padrão considera `pending` uma evidência suficiente de que a condição foi detectada; não espera cinco minutos apenas para transformar o estado em `firing`.

## Logs e correlação

Os dois serviços escrevem `trace_id` nos logs. Alloy coleta esses logs e Loki os indexa. Assim o mesmo trace pode ser navegado entre Tempo e Loki. Em falhas downstream, o frontend escreve uma linha `request failed` preservando o mesmo `trace_id` retornado ao cliente.

## Segurança e exposição

- não existe Ingress;
- Services são apenas `ClusterIP`;
- `/metrics` só é consumido internamente pelo Prometheus;
- a chamada frontend -> downstream permanece dentro do cluster;
- OTLP é enviado somente ao Collector interno;
- port-forwards usados pelos testes escutam apenas em loopback por padrão;
- nenhum token ou Secret é necessário para o demo;
- o incident drill modifica somente a escala do Deployment descartável `otel-go-downstream` e restaura o valor original.

## Lições registradas

- `CounterVec` e `HistogramVec` criam séries concretas sob demanda; validar famílias vetoriais antes do primeiro tráfego pode produzir falso negativo;
- recursos `PrometheusRule` são reconciliados de forma assíncrona pelo Prometheus Operator; testes devem aguardar a regra aparecer na API do Prometheus;
- um erro observável é mais útil quando o mesmo identificador de trace é preservado na resposta, no log e no trace distribuído;
- alertas com `for` devem ser testados considerando o estado `pending` antes de `firing`.

## Próximos passos

1. validar `make otel-go-demo-incident-test` em runtime;
2. revisar visualmente no Grafana o mesmo incidente em dashboard, Loki e Tempo;
3. avaliar exemplars Prometheus -> Tempo para saltar de uma amostra de latência diretamente para um trace;
4. revisar quais alertas e dashboards devem permanecer quando aplicações reais entrarem no cluster.

## Fontes

- Prometheus Go client releases: https://github.com/prometheus/client_golang/releases
- Prometheus Operator / ServiceMonitor: https://prometheus-operator.dev/docs/developer/getting-started/
- Prometheus alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- OpenTelemetry Go: https://opentelemetry.io/docs/languages/go/
- OpenTelemetry context propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- W3C Trace Context: https://www.w3.org/TR/trace-context/
- Tempo HTTP API: https://grafana.com/docs/tempo/latest/api_docs/
- K3s embedded containerd CLI: https://docs.k3s.io/advanced#using-docker-as-the-container-runtime
