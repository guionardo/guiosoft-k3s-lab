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

O layout persistente em `/srv/k3s` foi validado no host. Novos volumes `local-path` foram reprovisionados e confirmados fisicamente abaixo de `/mnt/store1/k3s/local-path`. No perfil atual do `local-path`, a capacidade declarada de um PVC não pré-aloca nem reserva fisicamente todo esse espaço no ext4 do host e também não funciona como quota rígida por diretório; por isso o espaço livre real de `/mnt/store1` deve ser monitorado independentemente da soma nominal dos PVCs.

A infraestrutura Cloudflare está declarada em Terraform usando o provider v5. O Tunnel existente, sua configuração remota e o wildcard DNS foram importados para o state local e o `terraform plan` foi validado com `No changes`.

SOPS + age estão instalados via Ansible. A identidade age é criada de forma idempotente somente quando ausente, a configuração pública do recipient está versionada em `.sops.yaml`, e o fluxo de encrypt/decrypt e de Kubernetes Secrets cifrados foi validado.

O backup do K3s foi validado manualmente, por restore rehearsal não destrutivo e pelo mesmo serviço usado no timer systemd. O timer diário, a retenção local e a cadeia automática de envio off-host estão operacionais.

A camada off-host usa Restic sobre Cloudflare R2. O bucket `guiosoft-k3s-backups` é gerenciado por uma stack Terraform separada, as credenciais runtime ficam cifradas com SOPS + age, o round-trip real Restic -> R2 -> restore foi validado por SHA-256 e o `k3s-backup.service` foi validado executando a cadeia completa local -> Restic -> R2 com `restic check` remoto.

O Disaster Recovery já possui readiness check, restore rehearsal isolado via R2 e um fluxo guardado para restore destrutivo em outro host. O teste completo em uma VM/segundo host ficou adiado até existir uma máquina disponível; o servidor atual não será usado como alvo destrutivo.

A fundação de observabilidade está operacional. O `kube-prometheus-stack`, Tempo, OpenTelemetry Collector, Loki e Grafana Alloy estão ativos; Prometheus, Tempo e Loki estão provisionados no Grafana e com health `OK`.

`make observability-validate` foi validado no cluster atual com 15/15 scrape targets Prometheus `up`, query `up` retornando 15 séries, Pods Ready e todos os PVCs Bound. A investigação de `CPUThrottlingHigh` identificou throttling artificial no node-exporter causado pelo antigo hard CPU limit de `200m`; após remover apenas esse limite, o throttling e o alerta desapareceram sem impacto nos demais workloads. A auditoria dos 26 dashboards Grafana também passou sem referências quebradas; dashboards AIX/MacOS foram apenas classificados como não aplicáveis ao host Linux.

O demo OpenTelemetry também foi validado em modo distribuído: `otel-go-demo` propaga W3C `traceparent` para `otel-go-downstream`, e o teste confirma os dois `service.name` dentro do mesmo trace no Tempo. A navegação visual Loki -> Tempo e Tempo -> Loki também foi validada no Grafana.

O mesmo demo expõe métricas Prometheus customizadas de requests, latência, requests em andamento, chamadas downstream e erros. Um `ServiceMonitor` seleciona os dois Services do namespace `lab`, e as séries `otel_demo_*` já foram identificadas no Prometheus em runtime.

O dashboard declarativo `OTel Go Demo - Application Metrics` e as regras `OtelGoDemoHighErrorRate`, `OtelGoDemoHighP95Latency` e `OtelGoDemoDownstreamErrors` também foram carregados e validados no Prometheus/Grafana.

O controlled incident drill também foi validado em runtime. O target `make otel-go-demo-incident-test` reduziu temporariamente o downstream descartável para zero replicas, produziu HTTP 502 preservando o `trace_id`, confirmou a detecção nas métricas e no alerta, localizou o mesmo incidente no Loki e no Tempo, restaurou automaticamente a escala original e confirmou a recuperação da chamada frontend -> downstream.

A Fase 4 começou com o **Firecrawl como primeiro workload real**. O stack Docker Compose atual foi auditado sem expor secrets: cinco containers, rede privada `firecrawl_backend`, API publicada em `3002`, volumes identificados e imagens efetivas pinadas por digest no scaffold Kubernetes. Para a primeira versão K3s, PostgreSQL/NuQ, Redis e RabbitMQ foram deliberadamente classificados como efêmeros e usam `emptyDir`, sem PVCs Firecrawl. A API será publicada por Traefik em `firecrawl.guiosoft.info`, aproveitando o wildcard Cloudflare Tunnel já existente; os backends permanecem somente em `ClusterIP`. O Docker Compose atual continua disponível durante a validação inicial.

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
make observability-grafana-dashboard-audit
make observability-grafana
make otel-go-demo-install
make otel-go-demo-test
make otel-go-demo-metrics-test
make otel-go-demo-incident-test
make firecrawl-migration-audit
make firecrawl-k8s-validate
make firecrawl-k8s-status
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

Ela verifica Pods/PVCs, targets e query `up` do Prometheus, auditoria de alertas, health dos datasources Grafana e uso atual de recursos quando o metrics-server estiver disponível. No cluster atual o teste passou com 15/15 targets `up`; Prometheus, Tempo e Loki estão com health `OK` e o único alerta sintético ativo na última validação foi `Watchdog`, como esperado.

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

As métricas de aplicação ficam em `/metrics` e são coletadas por `ServiceMonitor`. Para validar o caminho aplicação -> Prometheus e os artefatos de dashboard/alerta:

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

Para testar investigação de incidente de forma controlada:

```bash
make otel-go-demo-incident-test
```

O experimento afeta somente os workloads descartáveis do demo. Ele reduz `otel-go-downstream` temporariamente para zero replicas, exige falhas HTTP 502 no frontend, valida métricas no Prometheus, estado `pending`/`firing` do alerta downstream, o mesmo `trace_id` no Loki e Tempo, restaura a escala original e confirma a recuperação. Como as regras reais usam `for: 5m`, o estado `pending` já é considerado evidência de detecção no teste rápido. Esse fluxo foi validado no cluster atual.

Grafana continua sem Ingress nesta fase. Para acesso local:

```bash
make observability-grafana
```

Para acesso temporário pela LAN administrativa:

```bash
make observability-grafana ADDRESS=192.168.88.9
```

Detalhes em [`docs/observability.md`](docs/observability.md), [`docs/otel-go-demo.md`](docs/otel-go-demo.md), [`docs/alert-audit.md`](docs/alert-audit.md) e [`docs/grafana-dashboard-audit.md`](docs/grafana-dashboard-audit.md).

## Firecrawl

O primeiro workload real escolhido para migração é o Firecrawl, atualmente executado por Docker Compose no mesmo host.

O perfil Kubernetes atual tomou duas decisões explícitas:

- `firecrawl-api` terá Ingress público em `https://firecrawl.guiosoft.info`;
- PostgreSQL/NuQ, Redis e RabbitMQ são efêmeros nesta etapa e usam `emptyDir`, sem PVCs.

Todas as imagens estão pinadas pelos digests observados no runtime Docker atual. O Ingress publica somente a API; PostgreSQL, Redis, RabbitMQ e Playwright continuam internos ao namespace.

Operações atuais:

```bash
make firecrawl-migration-audit
make firecrawl-k8s-validate
make firecrawl-k8s-status
```

`make firecrawl-k8s-validate` é read-only: renderiza Kustomize, executa dry-run client-side, exige o Ingress `firecrawl.guiosoft.info`, confirma que as imagens estão pinadas por digest e que não existem PVCs Firecrawl neste perfil.

A configuração não sensível fica em ConfigMap. Para gerar o Secret cifrado diretamente do `.env` local sem imprimir valores:

```bash
bash scripts/firecrawl-secret-from-env.sh /caminho/do/firecrawl/.env
make secret-validate FILE=kubernetes/apps/firecrawl/firecrawl-secrets.sops.yaml
make secret-apply FILE=kubernetes/apps/firecrawl/firecrawl-secrets.sops.yaml
```

O `.env` real nunca deve ser versionado. O Ingress não adiciona autenticação por si só; se a API Firecrawl não exigir credencial de cliente, o endpoint será publicamente utilizável e poderá consumir os recursos/integrações configurados.

Detalhes em [`docs/firecrawl-migration.md`](docs/firecrawl-migration.md) e a semântica de PVC/local-path em [`docs/storage.md`](docs/storage.md).

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
- validação real de 15/15 targets Prometheus `up`, auditoria dos alertas e health dos datasources Prometheus/Tempo/Loki;
- validação real da remoção do hard CPU limit do node-exporter com desaparecimento de throttling e `CPUThrottlingHigh`;
- auditoria read-only de 26 dashboards Grafana com carregamento válido e classificação K3s/Linux;
- validação real de tracing distribuído `otel-go-demo -> otel-go-downstream` com W3C Trace Context;
- validação real de logs `otel-go-demo -> Alloy -> Loki`, correlação pelo mesmo `trace_id` e navegação visual no Grafana;
- validação real das métricas customizadas `otel_demo_*` e das regras customizadas no Prometheus;
- validação real do controlled incident drill cobrindo HTTP 502, métricas, alerta, Loki, Tempo e recuperação do downstream;
- auditoria read-only do Docker Compose Firecrawl, identificação de volumes/digests e preparação do perfil K3s efêmero com Ingress público;
- Prometheus Go client `v1.24.1` para métricas customizadas;
- documentação oficial do Prometheus Operator sobre `ServiceMonitor` e `PrometheusRule`;
- documentação oficial do Prometheus sobre alerting rules;
- documentação oficial do Grafana sobre dashboards;
- documentação oficial do OpenTelemetry sobre propagação de contexto e W3C Trace Context;
- documentação oficial do K3s para cluster access, storage, datastore e backup/restore;
- documentação oficial do Kubernetes sobre kubeconfig, `kubectl`, Persistent Volumes e `emptyDir`;
- documentação oficial do Grafana Loki, Alloy, Tempo e provisioning de datasources;
- documentação oficial do Firecrawl para self-hosting e configuração de ambiente;
- documentação oficial do Restic, Cloudflare R2, SOPS, age, Helm e systemd.

Referências relevantes:

- https://github.com/prometheus/client_golang/releases
- https://prometheus-operator.dev/docs/developer/getting-started/
- https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/
- https://opentelemetry.io/docs/concepts/context-propagation/
- https://www.w3.org/TR/trace-context/
- https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources
- https://grafana.com/docs/loki/latest/setup/install/helm/
- https://grafana.com/docs/alloy/latest/collect/logs-in-kubernetes/
- https://grafana.com/docs/tempo/latest/
- https://github.com/firecrawl/firecrawl/blob/main/SELF_HOST.md
- https://github.com/firecrawl/firecrawl/blob/main/apps/api/.env.example
- https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- https://kubernetes.io/docs/concepts/storage/volumes/#emptydir
- https://docs.k3s.io/add-ons/storage

Nenhum dado persistente existente foi movido e nenhum secret plaintext deve ser mantido no Git.
