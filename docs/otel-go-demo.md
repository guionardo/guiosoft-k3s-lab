# OpenTelemetry Go demo

## Objetivo

Validar tracing ponta a ponta no cluster usando uma aplicação Go pequena e totalmente descartável:

```text
HTTP request
   |
   v
otel-go-demo (Go)
   |
   | OTLP gRPC
   v
OpenTelemetry Collector
   |
   v
Tempo
   |
   v
Grafana Explore
```

A aplicação gera um span HTTP raiz e spans filhos artificiais para representar validação, consulta a banco, processamento de negócio e chamada externa. O endpoint `/work` devolve o `trace_id` gerado para permitir validação determinística no Tempo.

## Versões

- Go toolchain da imagem de build: `1.27.1`;
- OpenTelemetry Go API/SDK/exporter: `1.46.0`.

As dependências são pinadas em `kubernetes/apps/otel-go-demo/app/go.mod`.

## Por que a imagem é local

O laboratório ainda não depende de registry para workloads experimentais. O fluxo usa o Docker já existente no host apenas para construir a imagem e depois importa o resultado diretamente no containerd interno do K3s:

```text
Docker build
   |
Docker save
   |
   v
sudo k3s ctr images import
   |
   v
K3s Pod (imagePullPolicy: Never)
```

Isso mantém o teste independente de Docker Hub/GHCR e evita adicionar credenciais de registry apenas para o workload didático.

## Operação

Instalar/rebuildar:

```bash
make otel-go-demo-install
```

O target:

1. constrói `guiosoft/otel-go-demo:dev`;
2. importa a imagem no containerd do K3s;
3. aplica Deployment e Service no namespace `lab`;
4. aguarda rollout.

Status:

```bash
make otel-go-demo-status
```

Validar trace ponta a ponta:

```bash
make otel-go-demo-test
```

A validação não publica nenhum endpoint externamente. Ela abre dois `kubectl port-forward` temporários somente em loopback:

- aplicação: `127.0.0.1:18080`;
- Tempo: `127.0.0.1:13200`.

Em seguida chama `/work`, extrai o `trace_id` da resposta e consulta `/api/traces/<trace_id>` diretamente no Tempo. O teste somente termina com sucesso quando o trace reaparece no backend.

Saída esperada:

```text
Trace generated: <32 hex chars>
Tempo trace lookup: OK
Trace ID: <same trace id>
Open Grafana -> Explore -> Tempo and search this trace ID.
```

Remover o workload:

```bash
make otel-go-demo-delete
```

## Segurança e exposição

- não existe Ingress;
- Service é apenas `ClusterIP`;
- OTLP é enviado somente ao Collector interno;
- port-forwards usados pelo teste escutam apenas em loopback por padrão;
- nenhum token ou secret é necessário para o demo.

## Próximos passos

Depois do primeiro trace validado:

1. visualizar o trace no Grafana Explore;
2. validar a árvore de spans e tempos artificiais;
3. adicionar propagação entre dois serviços para demonstrar trace distribuído real;
4. posteriormente correlacionar `trace_id` com Loki;
5. avaliar exemplars Prometheus -> Tempo.

## Fontes

- OpenTelemetry Go: https://opentelemetry.io/docs/languages/go/
- OpenTelemetry Go packages: https://pkg.go.dev/go.opentelemetry.io/otel
- OTLP exporter for Go: https://pkg.go.dev/go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc
- Go releases: https://go.dev/doc/devel/release
- Tempo HTTP API: https://grafana.com/docs/tempo/latest/api_docs/
- K3s embedded containerd CLI: https://docs.k3s.io/advanced#using-docker-as-the-container-runtime
