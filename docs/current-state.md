# Estado atual e decisões de escopo

Atualizado em 2026-09-14 após a validação do firewall em reboot real e a migração do Cloudflare Tunnel connector do systemd do host para o K3s.

## Host

- Debian 13 (trixie)
- Intel Core i5-8500, 6 cores
- 16 GB RAM
- K3s `v1.36.4+k3s1` single-node operacional
- Docker preservado temporariamente para rollback de workloads antigos, sem Firecrawl ativo
- `cloudflared.service` parado e desabilitado após cutover para Kubernetes; instalação/configuração local preservadas temporariamente como rollback
- Tailscale removido
- NFS/RPC, PCP e Cockpit desabilitados
- Avahi mantido deliberadamente por enquanto
- política nftables dedicada `inet guiosoft_host` ativa e validada após reboot real

## Cluster K3s

O cluster está operacional com node `guiosoft-info` em estado `Ready`, CoreDNS, metrics-server, local-path-provisioner, Traefik/ServiceLB e os workloads atuais saudáveis.

O `kubectl` administrativo funciona sem `sudo`. O target `make kubeconfig-external` gera kubeconfig com o `InternalIP` do node (`192.168.88.9`) e o acesso a partir de outra máquina da LAN já foi validado.

O local-path provisioner grava fisicamente abaixo de:

```text
/mnt/store1/k3s/local-path
```

## Cloudflare Tunnel no Kubernetes

O connector do Cloudflare Tunnel foi migrado do host para o namespace `cloudflare` no K3s.

Estado atual:

- Deployment `cloudflared` com 2 réplicas;
- imagem `cloudflare/cloudflared:2026.9.1`;
- token do Tunnel armazenado como Kubernetes Secret cifrado no Git com SOPS + age;
- `/ready` usado por readiness/liveness probes;
- endpoint `/metrics` exposto por Service `cloudflared-metrics` e selecionado por `ServiceMonitor`;
- ServiceAccount token não é montado no Pod;
- filesystem do container é read-only, sem privilege escalation e com capabilities removidas;
- duas réplicas fornecem redundância de processo/Pod, mas não de node enquanto o cluster permanecer single-node.

Durante o cutover, o origin remoto do wildcard deixou de usar loopback e passou a ser acessível tanto pelo connector antigo do host quanto pelos Pods:

```text
*.guiosoft.info -> Cloudflare Tunnel -> http://192.168.88.9:80 -> Traefik
```

A mudança foi aplicada isoladamente via Terraform e validada ainda com o connector systemd ativo. Em seguida, o connector Kubernetes foi iniciado em paralelo, registrou quatro conexões QUIC saudáveis, recebeu a configuração remota e passou nos connectivity pre-checks. Só então o serviço systemd foi parado/desabilitado.

Após o cutover exclusivo para Kubernetes foram validados repetidamente:

```text
k3s-test público     -> HTTP 200
Firecrawl público    -> HTTP 404
Firecrawl LAN        -> HTTP 200
```

A unidade/configuração antiga do host não foi removida ainda. O rollback imediato durante a janela de observação é:

```bash
sudo systemctl enable --now cloudflared
```

## Workloads

### Firecrawl

O Firecrawl é o primeiro workload real migrado para K3s. Os cinco componentes estão em execução:

- API;
- PostgreSQL/NuQ;
- Playwright;
- RabbitMQ;
- Redis.

As imagens estão pinadas por digest. No perfil atual PostgreSQL/NuQ, Redis e RabbitMQ são deliberadamente efêmeros via `emptyDir` e não existem PVCs Firecrawl.

A antiga stack Docker Compose está parada; containers e volumes foram preservados apenas durante a janela de rollback.

O acesso é LAN-only via split-horizon DNS no MikroTik:

```text
firecrawl.guiosoft.info -> 192.168.88.9
```

Hermes e OpenCode/MCP foram validados consumindo esse caminho interno.

No Cloudflare Tunnel existe uma regra explícita anterior ao wildcard:

```text
firecrawl.guiosoft.info -> http_status:404
```

Assim, o hostname continua utilizável na LAN, mas é bloqueado na rota pública. A antiga aplicação Cloudflare Access e os Service Tokens Hermes/OpenCode foram removidos declarativamente.

### Lab e observabilidade

O namespace `lab` mantém o workload `k3s-test` e a aplicação Go instrumentada com OpenTelemetry.

A observabilidade inclui:

- Prometheus / Alertmanager / Grafana;
- Tempo;
- OpenTelemetry Collector;
- Loki;
- Grafana Alloy;
- node-exporter;
- métricas customizadas, traces distribuídos, logs correlacionados e alertas validados.

Um incident drill controlado já confirmou o fluxo de detecção, correlação e recuperação.

## Cloudflare

A infraestrutura Cloudflare relevante está sob Terraform. O Tunnel é remotamente gerenciado e sua regra geral atual é:

```text
*.guiosoft.info -> http://192.168.88.9:80
```

O wildcard permite que Ingresses Kubernetes publicados explicitamente sejam alcançados pelo Tunnel. Hostnames sem Ingress retornam 404 no Traefik.

Workloads classificados como LAN-only e cobertos pelo wildcard devem possuir regra explícita de bloqueio no Tunnel antes do wildcard, como já ocorre com o Firecrawl.

## Firewall e hardening

A superfície do host foi classificada antes de aplicar qualquer default-deny. O MikroTik possui somente a regra padrão de `srcnat masquerade` e nenhum `dstnat`/port-forward direto para `192.168.88.9`.

A política do host usa uma tabela nftables isolada:

```text
table inet guiosoft_host
```

Ela possui hook apenas em `INPUT`, não executa `flush ruleset` e não toma posse das chains/tabelas de FORWARD/NAT gerenciadas por K3s, Flannel ou Docker.

A política atual:

- aceita loopback;
- aceita conexões `established,related`;
- descarta estado inválido;
- preserva ICMP/ICMPv6 e DHCP;
- permite `22`, `80`, `443` e `6443/TCP` pela LAN `192.168.88.0/24`;
- mantém mDNS 5353 para Avahi;
- confia nas interfaces `cni0` e `flannel.1` para tráfego local do cluster;
- mantém 8472/UDP fechado para a LAN enquanto o cluster for single-node;
- aplica `policy drop` ao restante do INPUT.

A persistência usa `guiosoft-host-firewall.service`, separado do `nftables.service` global. Um reboot real confirmou carregamento correto da policy e preservação de SSH LAN, kubeconfig externo, K3s, workloads, Firecrawl e Cloudflare Tunnel.

## Backup e DR

O K3s possui backup local verificável do SQLite + server token, timer systemd e retenção. A cadeia off-host usa Restic para Cloudflare R2, com `restic check` e rehearsal isolado de restore já validados.

O restore destrutivo possui guards explícitos e só é permitido em host marcado como alvo DR. Um teste completo em segundo host/VM continua adiado até existir recurso disponível.

## Secrets

SOPS + age estão configurados. A identidade privada age permanece fora do repositório e `.sops.yaml` contém somente o recipient público. O fluxo encrypt/decrypt e aplicação de Kubernetes Secret cifrado foi validado.

O token do Cloudflare Tunnel segue o mesmo padrão: plaintext não é versionado; somente o Secret SOPS pode entrar no Git.

## Próximos passos

1. iniciar a fase GitOps, escolhendo Argo CD ou Flux;
2. integrar os manifests e Secrets SOPS ao fluxo de reconciliação;
3. remover o runtime antigo do Firecrawl somente após encerrar sua janela de rollback;
4. pinçar `cloudflared` também por digest após registrar o `imageID` validado em runtime;
5. avançar pendências de storage/DR conforme necessidade operacional.
