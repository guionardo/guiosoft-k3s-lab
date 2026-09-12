# OpenTelemetry Go demo

## Objetivo

Validar tracing distribuído, logs correlacionados e métricas customizadas no cluster com dois serviços Go descartáveis:

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
```

O serviço `otel-go-demo` recebe `/work`, cria o span servidor raiz, executa etapas internas e chama `otel-go-downstream` em `/process`. Antes da chamada HTTP ele injeta o contexto W3C `traceparent`; o downstream extrai esse contexto e cria seu próprio span servidor no mesmo trace.

Os dois serviços enviam spans ao OpenTelemetry Collector, escrevem o mesmo `trace_id` nos logs e expõem métricas Prometheus em `/metrics`.

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

O `ServiceMonitor/otel-go-demo`, no namespace `monitoring`, seleciona os Services `otel-go-demo` e `otel-go-downstream` no namespace `lab` e faz scrape de `/metrics` a cada 30 segundos. Esse padrão segue o modelo do Prometheus Operator, no qual um `ServiceMonitor` seleciona Services e gera a configuração de scrape para o Prometheus.

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

O target aplica também o `ServiceMonitor` das métricas.

Status:

```bash
make otel-go-demo-status
```

Validar trace distribuído:

```bash
make otel-go-demo-test
```

A validação só passa quando o Tempo encontra o mesmo trace contendo `service.name=otel-go-demo` e `service.name=otel-go-downstream`.

Validar métricas customizadas:

```bash
make otel-go-demo-metrics-test
```

Esse teste:

1. confirma `/metrics` no frontend;
2. gera várias chamadas `/work`;
3. aguarda o próximo scrape;
4. consulta a API do Prometheus;
5. exige valores positivos para contador HTTP, buckets do histograma, chamadas downstream bem-sucedidas e requests recebidas pelo downstream.

Ele valida explicitamente:

```promql
sum(otel_demo_http_requests_total{service="otel-go-demo",path="/work"})
count(otel_demo_http_request_duration_seconds_bucket{service="otel-go-demo",path="/work"})
sum(otel_demo_downstream_requests_total{service="otel-go-demo",status="ok"})
sum(otel_demo_http_requests_total{service="otel-go-downstream",path="/process"})
```

## Logs e correlação

Os dois serviços escrevem `trace_id` nos logs. Alloy coleta esses logs e Loki os indexa. Assim o mesmo trace pode ser navegado entre Tempo e Loki.

## Segurança e exposição

- não existe Ingress;
- Services são apenas `ClusterIP`;
- `/metrics` só é consumido internamente pelo Prometheus;
- a chamada frontend -> downstream permanece dentro do cluster;
- OTLP é enviado somente ao Collector interno;
- port-forwards usados pelos testes escutam apenas em loopback por padrão;
- nenhum token ou Secret é necessário para o demo.

## Próximos passos

1. validar `make otel-go-demo-metrics-test` em runtime;
2. criar um dashboard Grafana simples com throughput, p95 e erros downstream;
3. criar um alerta didático para erro/latência;
4. avaliar exemplars Prometheus -> Tempo para saltar de uma amostra de latência diretamente para o trace correspondente.

## Fontes

- Prometheus Go client releases: https://github.com/prometheus/client_golang/releases
- Prometheus Operator / ServiceMonitor: https://prometheus-operator.dev/docs/developer/getting-started/
- OpenTelemetry Go: https://opentelemetry.io/docs/languages/go/
- OpenTelemetry context propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- W3C Trace Context: https://www.w3.org/TR/trace-context/
- Tempo HTTP API: https://grafana.com/docs/tempo/latest/api_docs/
- K3s embedded containerd CLI: https://docs.k3s.io/advanced#using-docker-as-the-container-runtime
