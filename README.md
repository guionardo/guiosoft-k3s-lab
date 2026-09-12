# guiosoft-k3s-lab

Laboratório pessoal para estudar Kubernetes com K3s em um servidor Debian 13 existente, migrando serviços gradualmente e mantendo toda a infraestrutura reproduzível.

## Objetivos

- instalar e operar um cluster K3s em hardware próprio;
- migrar serviços atuais sem big-bang;
- publicar aplicações por subdomínios de `guiosoft.info` usando Cloudflare Tunnel;
- aprender os principais conceitos de Kubernetes com workloads reais;
- manter infraestrutura e configuração em código;
- possibilitar reconstrução do ambiente após falha do disco do sistema;
- separar claramente infraestrutura reconstruível de dados persistentes.

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

A frente ativa agora é observabilidade. O `kube-prometheus-stack` está instalado e saudável com Prometheus, Alertmanager, Grafana, kube-state-metrics e node-exporter. Tempo `2.2.3` e OpenTelemetry Collector chart `0.172.1` também foram instalados e validados em `Running`, com PVC Tempo de 5 GiB em `local-path`. Grafana, Tempo e Collector permanecem sem Ingress público.

O workload Go instrumentado com OpenTelemetry foi validado ponta a ponta: uma requisição gera `trace_id`, o trace atravessa aplicação -> Collector -> Tempo e o teste automatizado consegue recuperá-lo diretamente pela API do Tempo.

A fundação de logs também está operacional. Loki community chart `18.5.0` roda em modo `Monolithic`, Grafana Alloy chart `1.12.1` coleta logs dos Pods pela Kubernetes API e envia ao Loki, e `make observability-logging-test` já confirmou uma linha de log contendo exatamente o mesmo `trace_id` da requisição. A correlação de backend logs <-> traces está, portanto, validada; resta revisar a navegação visual no Grafana.

O Grafana agora tem provisioning validado para os três datasources principais: Prometheus, Tempo e Loki. O fluxo de reload + validação consulta a API do Grafana sem expor credenciais e confirma os UIDs esperados. O `make observability-validate` também passa a incluir essa checagem de datasources além dos scrape targets Prometheus.

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

Tracing e logging já foram validados em runtime com o demo Go. O fluxo de logs/traces comprovado é:

```text
request
  ├── trace -> OpenTelemetry Collector -> Tempo
  └── log   -> Grafana Alloy -> Loki
                 ^
                 |
            mesmo trace_id
```

O teste automatizado:

```bash
make observability-logging-test
```

gera uma requisição, obtém o `trace_id` e consulta o Loki até localizar uma linha contendo exatamente o mesmo ID. O teste passou no cluster atual.

O Grafana recebe Prometheus, Tempo e Loki por provisioning declarativo. Os datasources Tempo e Loki também carregam a correlação bidirecional `TraceID`/`tracesToLogsV2`. O reload/provisioning dos três datasources já foi validado em runtime.

Para validar apenas os datasources:

```bash
make observability-grafana-datasources
```

Para forçar reload do provisioning e validar novamente:

```bash
make observability-grafana-reload
```

O próximo bloco operacional é revisar métricas e saúde da stack completa:

```bash
make observability-validate
```

Esse target agora verifica Pods/PVCs, scrape targets e query `up` do Prometheus, provisioning dos datasources Grafana e uso atual de recursos quando `metrics-server` estiver disponível.

Depois, revisar visualmente no Grafana:

```text
Loki log -> TraceID -> Tempo trace
Tempo trace -> tracesToLogs -> Loki logs
```

Grafana continua sem Ingress nesta fase. Para acesso local:

```bash
make observability-grafana
```

Para acesso temporário pela LAN administrativa:

```bash
make observability-grafana ADDRESS=192.168.88.9
```

Detalhes em [`docs/observability.md`](docs/observability.md).

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
- validação real do `kube-prometheus-stack`, Tempo e OpenTelemetry Collector no cluster atual;
- validação real de um trace OpenTelemetry ponta a ponta aplicação -> Collector -> Tempo;
- validação real de logs `otel-go-demo -> Alloy -> Loki` e correlação pelo mesmo `trace_id`;
- validação real do provisioning Prometheus/Tempo/Loki pela API do Grafana;
- documentação oficial do K3s para cluster access, storage, datastore e backup/restore;
- documentação oficial do Kubernetes sobre kubeconfig e `kubectl`;
- documentação oficial do Grafana Loki para Helm, modo Monolithic, TSDB, filesystem e retenção;
- Artifact Hub do chart community `grafana-community/loki`;
- documentação oficial do Grafana Alloy para Kubernetes e coleta de Pod logs;
- documentação oficial do Grafana sobre provisioning de datasources, datasource Loki, derived fields e trace-to-logs;
- documentação oficial do Promtail registrando EOL em 2 de março de 2026;
- documentação oficial do Grafana Tempo e OpenTelemetry Collector;
- documentação oficial do Restic, Cloudflare R2, SOPS, age, Helm e systemd.

Referências relevantes:

- https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources
- https://grafana.com/docs/loki/latest/setup/install/helm/
- https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/
- https://grafana.com/docs/loki/latest/operations/storage/filesystem/
- https://artifacthub.io/packages/helm/grafana-community/loki
- https://grafana.com/docs/alloy/latest/set-up/install/kubernetes/
- https://grafana.com/docs/alloy/latest/collect/logs-in-kubernetes/
- https://artifacthub.io/packages/helm/grafana/alloy
- https://grafana.com/docs/loki/latest/send-data/promtail/
- https://grafana.com/docs/grafana/latest/datasources/loki/

Nenhum dado persistente existente foi movido e nenhum secret plaintext deve ser mantido no Git.
