# guiosoft-k3s-lab

Laboratório pessoal para estudar Kubernetes com K3s em um servidor Debian 13 existente, migrando serviços gradualmente e mantendo toda a infraestrutura reproduzível.

## Objetivos

- instalar e operar um cluster K3s em hardware próprio;
- migrar serviços atuais sem big-bang;
- publicar aplicações por subdomínios de `guiosoft.info` usando Cloudflare Tunnel quando exposição pública for necessária;
- preferir acesso LAN-only para workloads consumidos exclusivamente dentro da rede local;
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
  ├── workloads públicos quando necessário
  ├── workloads LAN-only via DNS interno
  ├── observabilidade
  └── GitOps
```

A publicação externa deixa de ser requisito universal. Cada workload é classificado conforme seus consumidores; serviços exclusivamente locais devem preferencialmente permanecer fora da Internet.

## Estado atual

O cluster single-node K3s está operacional. Traefik, CoreDNS, metrics-server e local-path-provisioner estão funcionando, o acesso administrativo com `kubectl` já funciona sem `sudo`, e o caminho externo Cloudflare -> Tunnel -> Traefik -> Ingress -> Service -> Pod foi validado.

A limpeza pré-K3s foi concluída: Tailscale foi removido, OpenShip deixou de ter publicação Cloudflare e não possui container/unidade systemd local, e os registros DNS explícitos legados `git.guiosoft.info` e `git-ssh.guiosoft.info` foram removidos. O wildcard `*.guiosoft.info` continua sendo a rota padrão para o Tunnel.

O hardening do host já eliminou listeners sem consumidor real antes da criação do firewall: NFS/RPC, PCP e Cockpit foram desabilitados de forma reversível e o bootstrap Ansible preserva esse estado. A rota pública do Cockpit também foi removida do Cloudflare. Avahi foi deliberadamente mantido enquanto a estratégia de descoberta/DNS interno é consolidada.

O MikroTik RouterOS da LAN passou a fornecer resolução interna determinística para `firecrawl.guiosoft.info -> 192.168.88.9`, e o DHCP foi ajustado para que o cliente validado use somente o resolvedor local `192.168.88.1`. `dig`, `getent` e HTTP direto ao hostname confirmaram que o tráfego chega ao Traefik/Firecrawl pela LAN sem passar pelo Cloudflare.

A nova rota LAN-only também foi validada pelos dois consumidores reais: Hermes executou Firecrawl com sucesso pela resolução interna e OpenCode executou Firecrawl via MCP após configuração no objeto `mcp` de `~/.config/opencode/opencode.jsonc`. Isso elimina a necessidade funcional do fork planejado do Hermes apenas para injetar headers do Cloudflare Access. A retirada definitiva da publicação/Access Cloudflare será feita somente depois de remover declarativamente esses recursos do Terraform e validar ausência de regressão.

Hostnames desconhecidos sob o wildcard `*.guiosoft.info` chegam ao Traefik, mas recebem HTTP 404 quando não existe um Ingress explícito.

O acesso `kubectl` a partir de outra máquina da LAN também foi validado usando `make kubeconfig-external`, que renderiza o kubeconfig administrativo com o `InternalIP` do servidor em vez de loopback. A API continua destinada somente à rede administrativa.

O layout persistente em `/srv/k3s` foi validado no host. Novos volumes `local-path` foram reprovisionados e confirmados fisicamente abaixo de `/mnt/store1/k3s/local-path`. No perfil atual do `local-path`, a capacidade declarada de um PVC não pré-aloca nem reserva fisicamente todo esse espaço no ext4 do host e também não funciona como quota rígida por diretório; por isso o espaço livre real de `/mnt/store1` deve ser monitorado independentemente da soma nominal dos PVCs.

A infraestrutura Cloudflare está declarada em Terraform usando o provider v5. O Tunnel existente, sua configuração remota e o wildcard DNS foram importados para o state local e o `terraform plan` foi validado com `No changes`. A aplicação Cloudflare Access do Firecrawl e dois Service Tokens independentes para Hermes e OpenCode ainda existem no Terraform durante a transição LAN-only; não são mais necessários pelos clientes locais validados e serão removidos de forma controlada.

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

A Fase 4 usa o **Firecrawl como primeiro workload real**. A versão K3s foi implantada com os cinco componentes Ready, scrape funcional real validado e imagens pinadas por digest. PostgreSQL/NuQ, Redis e RabbitMQ foram deliberadamente classificados como efêmeros e usam `emptyDir`, sem PVCs Firecrawl. Uma corrida de startup com RabbitMQ foi corrigida com `initContainer`, e o novo Pod da API foi validado com `RESTARTS=0`.

O Firecrawl foi inicialmente protegido publicamente por Cloudflare Access Service Auth, com tokens separados para Hermes e OpenCode. Depois, o requisito foi simplificado: ambos os consumidores estão na LAN, então `firecrawl.guiosoft.info` passou a resolver internamente para o servidor K3s e foi validado com Hermes e OpenCode/MCP sem os headers Cloudflare. O Docker Compose antigo continua parado e seus containers/volumes permanecem preservados apenas para rollback.

## Divisão de responsabilidades

```text
Terraform
├── Cloudflare
│   ├── DNS
│   ├── Tunnel
│   ├── Access / Service Tokens quando necessários
│   ├── rotas/public hostnames
│   └── bucket R2 de backup
└── infraestrutura externa futura

Ansible
├── preparação do Debian
├── instalação/configuração do K3s
├── diretórios e storage do host
├── ferramentas de IaC, secrets, backup e Helm
├── automação de backup local + off-host
├── hardening de serviços do host
├── firewall
└── bootstrap do cluster

Kubernetes / Helm / GitOps
├── cloudflared
├── Traefik
├── namespaces
├── Prometheus / Alertmanager / Grafana
├── OpenTelemetry Collector / Tempo
├── Loki / Alloy
└── workloads
```
