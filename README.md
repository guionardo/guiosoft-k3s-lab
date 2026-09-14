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

A política nftables dedicada do host também foi validada após reboot real. O serviço `guiosoft-host-firewall.service` carrega apenas a tabela `inet guiosoft_host`, sem tomar posse do ruleset global do K3s/Docker, e o reboot preservou SSH pela LAN, kubeconfig externo, K3s, workloads e publicação Cloudflare.

O MikroTik RouterOS da LAN fornece resolução interna determinística para `firecrawl.guiosoft.info -> 192.168.88.9`, e o DHCP foi ajustado para que o cliente validado use somente o resolvedor local `192.168.88.1`. `dig`, `getent` e HTTP direto ao hostname confirmaram que o tráfego chega ao Traefik/Firecrawl pela LAN sem passar pelo Cloudflare.

A rota LAN-only foi validada pelos dois consumidores reais: Hermes executou Firecrawl com sucesso pela resolução interna e OpenCode executou Firecrawl via MCP após configuração no objeto `mcp` de `~/.config/opencode/opencode.jsonc`. Isso eliminou a necessidade funcional do fork planejado do Hermes apenas para injetar headers do Cloudflare Access.

O cutover LAN-only do Firecrawl foi concluído. Antes de retirar o Access, o Terraform recebeu uma regra explícita e prioritária no Cloudflare Tunnel para `firecrawl.guiosoft.info -> http_status:404`, impedindo que o hostname alcance o Traefik através do wildcard público `*.guiosoft.info`. Após validar simultaneamente o acesso HTTP pela LAN e o bloqueio HTTPS pela rota pública, a aplicação Cloudflare Access e os dois Service Tokens de Hermes/OpenCode foram destruídos declarativamente. O Firecrawl permanece acessível pela LAN via split-DNS e explicitamente bloqueado no caminho público.

Hostnames desconhecidos sob o wildcard `*.guiosoft.info` chegam ao Traefik, mas recebem HTTP 404 quando não existe um Ingress explícito. O Firecrawl é uma exceção deliberada: seu hostname é interceptado pelo Tunnel antes do wildcard e recebe 404 sem alcançar o Traefik.

O `cloudflared` também foi migrado do systemd do host para o próprio K3s. Para permitir o cutover sem indisponibilidade deliberada, o origin remoto do wildcard foi alterado de `http://127.0.0.1:80` para `http://192.168.88.9:80`, endereço alcançável simultaneamente pelo connector antigo e pelos Pods. O connector Kubernetes foi iniciado em paralelo, recebeu a configuração remota do Tunnel, estabeleceu conexões QUIC saudáveis e passou nos connectivity pre-checks antes de o serviço systemd ser parado e desabilitado. O Deployment agora possui duas réplicas, readiness/liveness em `/ready`, métricas em `:2000` e `ServiceMonitor`. A instalação systemd antiga permanece temporariamente preservada apenas como rollback durante a janela de observação.

Após o cutover exclusivo para os connectors Kubernetes foram validados repetidamente `k3s-test.guiosoft.info -> HTTP 200`, Firecrawl pela rota pública -> `HTTP 404` e Firecrawl pela LAN -> `HTTP 200`. As duas réplicas aumentam a disponibilidade contra falha/restart de Pod, mas o ambiente continua sem redundância contra falha do único node físico.

O acesso `kubectl` a partir de outra máquina da LAN também foi validado usando `make kubeconfig-external`, que renderiza o kubeconfig administrativo com o `InternalIP` do servidor em vez de loopback. A API continua destinada somente à rede administrativa.

O layout persistente em `/srv/k3s` foi validado no host. Novos volumes `local-path` foram reprovisionados e confirmados fisicamente abaixo de `/mnt/store1/k3s/local-path`. No perfil atual do `local-path`, a capacidade declarada de um PVC não pré-aloca nem reserva fisicamente todo esse espaço no ext4 do host e também não funciona como quota rígida por diretório; por isso o espaço livre real de `/mnt/store1` deve ser monitorado independentemente da soma nominal dos PVCs.

A infraestrutura Cloudflare está declarada em Terraform usando o provider v5. O Tunnel existente, sua configuração remota e o wildcard DNS estão sob gerenciamento declarativo. Para workloads LAN-only cobertos pelo wildcard DNS público, o Tunnel deve conter uma negação explícita antes da regra wildcard; o Firecrawl é a primeira aplicação usando esse padrão.

SOPS + age estão instalados via Ansible. A identidade age é criada de forma idempotente somente quando ausente, a configuração pública do recipient está versionada em `.sops.yaml`, e o fluxo de encrypt/decrypt e de Kubernetes Secrets cifrados foi validado. O token do Cloudflare Tunnel segue o mesmo padrão: plaintext não é versionado, apenas o Secret cifrado com SOPS.

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

O Firecrawl foi inicialmente protegido publicamente por Cloudflare Access Service Auth, com tokens separados para Hermes e OpenCode. Depois, ambos os consumidores foram classificados como LAN-only. O Access e os tokens já foram retirados, o hostname resolve internamente para o servidor K3s e a rota pública é bloqueada explicitamente antes do wildcard do Tunnel. O Docker Compose antigo continua parado e seus containers/volumes permanecem preservados apenas para rollback.

A Fase 7 de GitOps está operacional com Flux. O bootstrap usa SSH/deploy key no runtime e SOPS + age para secrets cifrados. `cloudflared` e Firecrawl estão sob reconciliação declarativa, com recuperação de Secret e self-healing de drift já validados.

A observabilidade também foi adotada pelo Flux sem recriar os releases Helm existentes. A migração foi feita release por release na ordem Alloy -> OpenTelemetry Collector -> Tempo -> Loki -> kube-prometheus-stack. Os cinco HelmReleases estão ativos e `Ready`, preservando versões, workloads e PVCs, e os testes funcionais de traces, logs e métricas continuam válidos após a adoção.

As principais pendências GitOps agora são tornar reproduzível o bootstrap runtime do Secret `sops-age` após a instalação do Flux e manter uma cópia off-host independente da identidade privada age para Disaster Recovery.

## Divisão de responsabilidades

```text
Terraform
├── Cloudflare
│   ├── DNS
│   ├── Tunnel
│   ├── Access / Service Tokens quando necessários
│   ├── bloqueios explícitos para hostnames LAN-only cobertos pelo wildcard
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
