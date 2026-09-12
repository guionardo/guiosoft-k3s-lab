# guiosoft-k3s-lab

Laboratório pessoal para estudar Kubernetes com K3s em um servidor Debian 13 existente, migrando serviços gradualmente e mantendo toda a infraestrutura reproduzível.

## Objetivos

- instalar e operar um cluster K3s em hardware próprio;
- migrar serviços atuais sem big-bang;
- publicar aplicações por subdomínios de `guiosoft.info` usando Cloudflare Tunnel;
- aprender os principais conceitos de Kubernetes com workloads reais;
- manter infraestrutura e configuração em código;
- possibilitar reconstrução do ambiente após falha do disco do sistema;
- separar claramente infraestrutura reconstruível de dados persistentes;
- ao final, consolidar todo o processo, decisões, trade-offs, problemas e validações em material de estudo detalhado e em artigos publicáveis para blog e LinkedIn.

## Arquitetura alvo

```text
Internet
   |
Cloudflare / guiosoft.info
   |
Cloudflare Tunnel
   |
K3s
  ├── cloudflared
  ├── Traefik
  ├── namespaces
  ├── workloads
  ├── observabilidade
  └── GitOps
```

Durante a migração, os serviços atuais continuarão rodando no host Debian. Cada serviço será movido individualmente para o K3s e o hostname correspondente será redirecionado apenas após validação.

## Estado atual

O cluster single-node K3s está operacional. Traefik, CoreDNS, metrics-server e local-path-provisioner estão funcionando, o acesso administrativo com `kubectl` já funciona sem `sudo`, e o caminho externo Cloudflare -> Tunnel -> Traefik -> Ingress -> Service -> Pod foi validado.

Hostnames desconhecidos sob o wildcard `*.guiosoft.info` chegam ao Traefik, mas recebem HTTP 404 quando não existe um Ingress explícito.

O acesso `kubectl` a partir de outra máquina da LAN também foi validado usando `make kubeconfig-external`, que renderiza o kubeconfig administrativo com o `InternalIP` do servidor em vez de loopback. A API continua destinada somente à rede administrativa.

O layout persistente em `/srv/k3s` foi validado no host. Novos volumes `local-path` foram reprovisionados e confirmados fisicamente abaixo de `/mnt/store1/k3s/local-path`.

A infraestrutura Cloudflare está declarada em Terraform usando o provider v5. O Tunnel existente, sua configuração remota e o wildcard DNS foram importados para o state local e o `terraform plan` foi validado com `No changes`.

SOPS + age estão instalados via Ansible. A identidade age é criada de forma idempotente somente quando ausente, a configuração pública do recipient está versionada em `.sops.yaml`, e o fluxo de encrypt/decrypt e de Kubernetes Secrets cifrados foi validado.

O backup do K3s foi validado manualmente, por restore rehearsal não destrutivo e pelo mesmo serviço usado no timer systemd. O timer diário, a retenção local e a cadeia automática de envio off-host estão operacionais.

A camada off-host usa Restic sobre Cloudflare R2. O bucket `guiosoft-k3s-backups` é gerenciado por uma stack Terraform separada, as credenciais runtime ficam cifradas com SOPS + age, o round-trip real Restic -> R2 -> restore foi validado por SHA-256 e o `k3s-backup.service` foi validado executando a cadeia completa local -> Restic -> R2 com `restic check` remoto.

O Disaster Recovery já possui readiness check, restore rehearsal isolado via R2 e um fluxo guardado para restore destrutivo em outro host. O teste completo em uma VM/segundo host ficou adiado até existir uma máquina disponível; o servidor atual não será usado como alvo destrutivo.

A fundação de observabilidade está operacional. O `kube-prometheus-stack`, Tempo, OpenTelemetry Collector, Loki e Grafana Alloy estão ativos; Prometheus, Tempo e Loki estão provisionados no Grafana e com health `OK`.

`make observability-validate` foi validado no cluster atual com 13/13 scrape targets Prometheus `up`, query `up` retornando 13 séries, Pods Ready e todos os PVCs Bound. Na mesma amostra, o node estava em aproximadamente 782m CPU (13%) e 8331 MiB de RAM (52%); Grafana (~440 MiB) e Prometheus (~337 MiB) eram os maiores consumidores de memória da stack.

O demo OpenTelemetry também foi validado em modo distribuído: `otel-go-demo` propaga W3C `traceparent` para `otel-go-downstream`, e o teste confirma os dois `service.name` dentro do mesmo trace no Tempo. A navegação visual Loki -> Tempo e Tempo -> Loki também foi validada no Grafana.

O mesmo demo agora expõe métricas Prometheus customizadas de requests, latência, requests em andamento, chamadas downstream e erros. Um `ServiceMonitor` seleciona os dois Services do namespace `lab`, e o target `make otel-go-demo-metrics-test` gera tráfego e confirma a ingestão dessas métricas pela API do Prometheus.

## Divisão de responsabilidades

```text
Terraform
├── Cloudflare
│   ├── DNS
│   ├── Tunnel
│   ├── rotas/public hostnames
│   └── bucket R2 de backup
└── infraestrutura externa futura

Ansible
├── preparação do Debian
├── instalação/configuração do K3s
├── diretórios e storage do host
├── ferramentas de IaC, secrets, backup e Helm
├── automação de backup local + off-host
├── firewall
└── bootstrap do cluster

Kubernetes / Helm / GitOps
├── cloudflared
├── Traefik
├── namespaces
├── Prometheus / Alertmanager / Grafana
├── OpenTelemetry Collector / Tempo
├── Loki / Grafana Alloy
└── aplicações
```

## Operações principais

```bash
make preflight
make bootstrap
make tools
make storage
make k3s
make kubeconfig-external
make cluster-status
make firewall-audit
make secrets-test
make backup-run
make dr-readiness
make dr-r2-rehearsal
make observability-install
make observability-validate
make observability-tracing-install
make observability-tracing-status
make observability-logging-install
make observability-logging-status
make observability-logging-test
make observability-grafana-datasources
make observability-grafana-reload
make observability-grafana
make otel-go-demo-install
make otel-go-demo-test
make otel-go-demo-metrics-test
make tf-cloudflare-plan
make tf-r2-plan
```

O `Makefile` é a interface operacional preferida. Os scripts continuam sendo a implementação de baixo nível, mas operações normais do laboratório devem ser expostas por targets `make`.

## Acesso remoto com kubectl

Para exibir um kubeconfig administrativo adequado a outra máquina da mesma LAN:

```bash
make kubeconfig-external
```

O target descobre o `InternalIP` do node e substitui apenas o `server:` do kubeconfig, preservando CA, certificados e chaves. O fluxo foi validado com `kubectl` executado a partir de outra máquina da LAN.

Para gravar o resultado com permissões restritas:

```bash
umask 077
make kubeconfig-external > k3s-guiosoft.yaml
```

Esse kubeconfig contém credenciais administrativas e nunca deve ser versionado. A porta `6443` não deve ser publicada na Internet nem pelo Cloudflare Tunnel.

Detalhes em [`docs/remote-kubectl.md`](docs/remote-kubectl.md).

## Observabilidade

A arquitetura atual cobre os três sinais principais:

```text
Metrics -> Prometheus
Logs    -> Grafana Alloy -> Loki
Traces  -> OpenTelemetry Collector -> Tempo
UI      -> Grafana
```

A validação consolidada está disponível em:

```bash
make observability-validate
```

Ela verifica Pods/PVCs, targets e query `up` do Prometheus, health dos datasources Grafana e uso atual de recursos quando o metrics-server estiver disponível. No cluster atual o teste passou com 13/13 targets `up` e Prometheus, Tempo e Loki com health `OK`.

O demo distribuído usa:

```text
client
  |
  v
otel-go-demo
  |
  | W3C traceparent
  v
otel-go-downstream
  |
  +--> ambos enviam OTLP --> Collector --> Tempo
```

Para construir, instalar e validar essa propagação:

```bash
make otel-go-demo-install
make otel-go-demo-test
```

As métricas de aplicação ficam em `/metrics` e são coletadas por `ServiceMonitor`. Para validar o caminho aplicação -> Prometheus:

```bash
make otel-go-demo-metrics-test
```

As principais séries são:

```text
otel_demo_http_requests_total
otel_demo_http_request_duration_seconds
otel_demo_requests_in_flight
otel_demo_downstream_requests_total
otel_demo_downstream_request_duration_seconds
otel_demo_downstream_errors_total
```

Exemplo de PromQL:

```promql
rate(otel_demo_http_requests_total[5m])
```

Grafana continua sem Ingress nesta fase. Para acesso local:

```bash
make observability-grafana
```

Para acesso temporário pela LAN administrativa:

```bash
make observability-grafana ADDRESS=192.168.88.9
```

Detalhes em [`docs/observability.md`](docs/observability.md) e [`docs/otel-go-demo.md`](docs/otel-go-demo.md).

## Documentação final

Além da documentação operacional mantida durante a implementação, o roadmap reserva uma etapa final específica para transformar o projeto em material de estudo e publicação. Essa etapa deverá reconstruir a jornada completa, incluindo decisões, alternativas descartadas, trade-offs, erros, troubleshooting, evidências de validação e fontes oficiais.

Os entregáveis finais previstos são:

- guia técnico detalhado e reproduzível;
- material de estudo sobre K3s/Kubernetes, IaC, storage, backup, Cloudflare e observabilidade;
- artigo técnico completo para blog;
- versão condensada para LinkedIn.

A publicação deverá passar por revisão explícita para remover secrets, identificadores desnecessários e detalhes sensíveis do ambiente.

## Disaster Recovery

O objetivo operacional continua sendo reconstruir o ambiente em outro host sem depender do disco raiz original. As validações não destrutivas já estão concluídas:

```bash
make dr-readiness
make dr-r2-rehearsal
```

O teste destrutivo completo permanece deliberadamente adiado até existir uma VM ou segundo host isolado disponível.

Detalhes em [`docs/disaster-recovery.md`](docs/disaster-recovery.md).

## Segurança

Este repositório é público. Nunca versionar:

- tokens do Cloudflare;
- credenciais R2 em plaintext;
- senha do repositório Restic;
- kubeconfig real;
- chaves SSH ou identidade privada age;
- senhas;
- arquivos `.env` com credenciais;
- Secrets Kubernetes em texto puro;
- backups ou dumps de banco de dados;
- relatórios de discovery sem revisão.

SOPS + age são usados para secrets declarativos que precisam permanecer no Git. O recipient público pode ser versionado; a identidade privada permanece fora do repositório e precisa de cópia de recuperação off-host.

## Domínio

Domínio principal do laboratório: `guiosoft.info`.

## Fontes e evidências desta etapa

A evolução atual foi baseada em:

- validações reais do cluster K3s, Traefik, Cloudflare Tunnel, `kubectl`, PVC/local-path, SOPS + age e backup/restore executadas no próprio servidor;
- validação real do kubeconfig remoto a partir de outra máquina da LAN;
- validação real do `kube-prometheus-stack`, Tempo, OpenTelemetry Collector, Loki e Alloy no cluster atual;
- validação real de 13/13 targets Prometheus `up` e health dos datasources Prometheus/Tempo/Loki;
- validação real de tracing distribuído `otel-go-demo -> otel-go-downstream` com W3C Trace Context;
- validação real de logs `otel-go-demo -> Alloy -> Loki`, correlação pelo mesmo `trace_id` e navegação visual no Grafana;
- Prometheus Go client `v1.24.1` para métricas customizadas;
- documentação oficial do Prometheus Operator sobre `ServiceMonitor`;
- documentação oficial do OpenTelemetry sobre propagação de contexto e W3C Trace Context;
- documentação oficial do K3s para cluster access, storage, datastore e backup/restore;
- documentação oficial do Kubernetes sobre kubeconfig e `kubectl`;
- documentação oficial do Grafana Loki, Alloy, Tempo e provisioning de datasources;
- documentação oficial do Restic, Cloudflare R2, SOPS, age, Helm e systemd.

Referências relevantes:

- https://github.com/prometheus/client_golang/releases
- https://prometheus-operator.dev/docs/developer/getting-started/
- https://opentelemetry.io/docs/concepts/context-propagation/
- https://www.w3.org/TR/trace-context/
- https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources
- https://grafana.com/docs/loki/latest/setup/install/helm/
- https://grafana.com/docs/alloy/latest/collect/logs-in-kubernetes/
- https://grafana.com/docs/tempo/latest/

Nenhum dado persistente existente foi movido e nenhum secret plaintext deve ser mantido no Git.
