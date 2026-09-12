# OpenTelemetry Go demo

## Objetivo

Validar tracing distribuído ponta a ponta no cluster com dois serviços Go descartáveis:

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
                        |
                        v
                 Grafana Explore
```

O serviço `otel-go-demo` recebe `/work`, cria o span servidor raiz, executa etapas internas e chama `otel-go-downstream` em `/process`. Antes da chamada HTTP ele injeta o contexto W3C `traceparent`; o downstream extrai esse contexto e cria seu próprio span servidor no mesmo trace.

Os dois serviços enviam spans ao OpenTelemetry Collector e escrevem o mesmo `trace_id` nos logs, permitindo validar simultaneamente tracing distribuído e correlação com Loki.

## Versões

- Go toolchain da imagem de build: `1.27.1`;
- OpenTelemetry Go API/SDK/exporter: `1.46.0`.

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

O target:

1. constrói `guiosoft/otel-go-demo:dev`;
2. importa a imagem no containerd do K3s;
3. aplica os Deployments/Services `otel-go-demo` e `otel-go-downstream`;
4. força rollout dos dois Deployments;
5. aguarda ambos ficarem disponíveis.

Status:

```bash
make otel-go-demo-status
```

Validar trace distribuído:

```bash
make otel-go-demo-test
```

A validação abre port-forwards temporários somente em loopback para o frontend e para Tempo. Em seguida:

1. chama `/work`;
2. exige que a resposta confirme `downstream=ok`;
3. extrai o `trace_id`;
4. consulta `/api/traces/<trace_id>` diretamente no Tempo;
5. só passa quando o trace contém recursos com `service.name=otel-go-demo` **e** `service.name=otel-go-downstream`.

Saída esperada:

```text
Distributed trace generated: <32 hex chars>
Tempo distributed trace lookup: OK
Trace ID: <same trace id>
Services in trace:
- otel-go-demo
- otel-go-downstream
```

Esse teste demonstra propagação real de contexto entre processos diferentes, não apenas spans filhos dentro do mesmo processo.

Remover os workloads:

```bash
make otel-go-demo-delete
```

## Logs e correlação

Os dois serviços escrevem `trace_id` nos logs. Alloy coleta esses logs e Loki os indexa. Assim o mesmo trace pode ser navegado entre:

```text
Tempo trace
   <-> trace_id <->
Loki logs de otel-go-demo e otel-go-downstream
```

## Segurança e exposição

- não existe Ingress;
- Services são apenas `ClusterIP`;
- a chamada frontend -> downstream permanece dentro do cluster;
- OTLP é enviado somente ao Collector interno;
- port-forwards usados pelo teste escutam apenas em loopback por padrão;
- nenhum token ou Secret é necessário para o demo.

## Próximos passos

1. validar em runtime o novo fluxo distribuído com `make otel-go-demo-install && make otel-go-demo-test`;
2. visualizar no Grafana Explore a árvore envolvendo os dois `service.name`;
3. revisar a navegação Tempo -> logs e Loki -> trace para ambos os serviços;
4. avaliar exemplars Prometheus -> Tempo;
5. adicionar métricas de aplicação quando houver benefício didático.

## Fontes

- OpenTelemetry Go: https://opentelemetry.io/docs/languages/go/
- OpenTelemetry context propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- W3C Trace Context: https://www.w3.org/TR/trace-context/
- OpenTelemetry Go packages: https://pkg.go.dev/go.opentelemetry.io/otel
- OTLP exporter for Go: https://pkg.go.dev/go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc
- Go releases: https://go.dev/doc/devel/release
- Tempo HTTP API: https://grafana.com/docs/tempo/latest/api_docs/
- K3s embedded containerd CLI: https://docs.k3s.io/advanced#using-docker-as-the-container-runtime
