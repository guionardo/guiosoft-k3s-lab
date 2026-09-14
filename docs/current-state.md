# Estado atual e decisões de escopo

Atualizado em 2026-09-14 após a migração do Firecrawl para K3s, consolidação da observabilidade, hardening dos serviços do host, cutover LAN-only do Firecrawl e implantação controlada da política de firewall.

## Host

- Debian 13 (trixie)
- Intel Core i5-8500, 6 cores
- 16 GB RAM
- K3s `v1.36.4+k3s1` single-node operacional
- Docker preservado temporariamente para rollback de workloads antigos, sem Firecrawl ativo
- `cloudflared` ainda executando via systemd no host
- Tailscale removido
- NFS/RPC, PCP e Cockpit desabilitados
- Avahi mantido deliberadamente por enquanto
- política nftables dedicada `inet guiosoft_host` ativa

## Cluster K3s

O cluster está operacional com node `guiosoft-info` em estado `Ready`, CoreDNS, metrics-server, local-path-provisioner, Traefik/ServiceLB e todos os workloads atuais saudáveis.

O `kubectl` administrativo funciona sem `sudo`. O target `make kubeconfig-external` gera kubeconfig com o `InternalIP` do node (`192.168.88.9`) e o acesso a partir de outra máquina da LAN já foi validado.

O local-path provisioner grava fisicamente abaixo de:

```text
/mnt/store1/k3s/local-path
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

O `cloudflared` continua no host por enquanto. A rota geral é:

```text
*.guiosoft.info -> Cloudflare Tunnel -> http://127.0.0.1:80 -> Traefik
```

O wildcard permite que Ingresses Kubernetes publicados explicitamente sejam alcançados pelo Tunnel. Hostnames sem Ingress retornam 404 no Traefik.

Workloads classificados como LAN-only e cobertos pelo wildcard devem possuir regra explícita de bloqueio no Tunnel antes do wildcard, como já ocorre com o Firecrawl.

A infraestrutura Cloudflare relevante está sob Terraform.

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

O primeiro enforcement foi executado com rollback automático de cinco minutos. Após validação externa de SSH, kubeconfig/Kubernetes e Firecrawl, o rollback foi cancelado e a policy permaneceu ativa.

A persistência está configurada por `guiosoft-host-firewall.service`, separado do `nftables.service` global. O unit está habilitado para o boot e carrega somente `/etc/nftables.d/guiosoft-host.nft`. A validação definitiva dessa persistência após reboot ainda está pendente.

## Backup e DR

O K3s possui backup local verificável do SQLite + server token, timer systemd e retenção. A cadeia off-host usa Restic para Cloudflare R2, com `restic check` e rehearsal isolado de restore já validados.

O restore destrutivo possui guards explícitos e só é permitido em host marcado como alvo DR. Um teste completo em segundo host/VM continua adiado até existir recurso disponível.

## Secrets

SOPS + age estão configurados. A identidade privada age permanece fora do repositório e `.sops.yaml` contém somente o recipient público. O fluxo encrypt/decrypt e aplicação de Kubernetes Secret cifrado foi validado.

## Próximos passos

1. reiniciar o host e validar que `guiosoft-host-firewall.service` carrega a tabela antes do K3s/cloudflared sem perda de acesso;
2. migrar `cloudflared` do systemd do host para Kubernetes;
3. iniciar a fase GitOps, escolhendo Argo CD ou Flux;
4. avançar pendências de storage/DR conforme necessidade operacional.
