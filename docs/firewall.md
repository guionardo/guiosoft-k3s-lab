# Firewall e exposição de portas

## Estado validado

O audit pós-K3s confirmou K3s, Docker daemon e `cloudflared` ativos, Kubernetes API e Traefik funcionais e UFW instalado porém inativo. O antigo Docker Compose do Firecrawl está parado e preservado somente para rollback; a porta 3002 do Docker não é mais um requisito.

Em 2026-09-14 o inventário foi reduzido antes de qualquer regra de firewall. NFS/RPC não possuía exports configurados, chamadas, conexões nem clientes; `nfs-server`, `rpcbind.service` e `rpcbind.socket` foram desabilitados sem remover os pacotes. PCP (`pmcd`, `pmlogger`, `pmproxy`) também foi desabilitado porque a observabilidade do host/cluster já é coberta pelo kube-prometheus-stack. Cockpit foi desabilitado após confirmar que o cluster permanecia normal, e sua rota explícita foi removida do Cloudflare Tunnel.

A política de bootstrap agora mantém esses serviços desabilitados de forma idempotente. Os pacotes continuam instalados nesta etapa para rollback simples.

## Serviços relevantes restantes

| Serviço / finalidade | Porta/protocolo | Escopo recomendado | Decisão |
|---|---:|---|---|
| SSH | 22/TCP | LAN administrativa | manter; preservar antes de qualquer default-deny |
| Kubernetes API | 6443/TCP | LAN administrativa + nós | não publicar na Internet |
| kubelet | 10250/TCP | cluster | necessário para componentes do cluster |
| node-exporter | 9100/TCP | cluster/monitoramento | manter; Prometheus o alcança no IP do host |
| Flannel VXLAN | 8472/UDP | nós K3s | nunca Internet |
| Avahi/mDNS | 5353/UDP | LAN multicast | manter por enquanto; não é mais requisito do Firecrawl |
| DHCP client | 68/UDP, 546/UDP | infraestrutura de rede | preservar respostas válidas via política stateful |
| cloudflared QUIC | UDP efêmero | saída | cliente outbound; não requer publicação inbound |
| Traefik/ServiceLB | 80/443 | K3s/networking | publicação de aplicações conforme Ingress/Tunnel |

Listeners exclusivamente em `127.0.0.1`/`::1` permanecem fora da exposição LAN direta.

## Serviços eliminados da superfície

### NFS/RPC

Antes da desativação, `rpcinfo -p` correlacionou 111/TCP+UDP, 2049/TCP e portas dinâmicas a `portmapper`, `mountd`, `status`, `nfs`, `nfs_acl` e `nlockmgr`. A investigação seguinte mostrou:

- nenhum export ativo em `exportfs -v`;
- nenhum export configurado em `/etc/exports` ou `/etc/exports.d`;
- `nfsstat -s` com zero chamadas;
- nenhuma conexão TCP 2049;
- nenhum cliente em `/proc/fs/nfsd/clients`;
- `rpcbind` servindo somente o stack NFS/RPC.

Decisão: desabilitar NFS/RPC inteiro em vez de criar regras para portas que não têm consumidor real. Os pacotes ficam instalados temporariamente para rollback.

### PCP

`pmcd`, `pmlogger` e `pmproxy` estavam ativos e publicavam 4330 e 44321-44323/TCP. O Cockpit instalado não dependia de `cockpit-pcp`; `/usr/share/cockpit/metrics` pertencia a `cockpit-system`. Como Prometheus/Grafana já fornecem a observabilidade necessária, os daemons PCP foram desabilitados sem remoção imediata dos pacotes.

### Cockpit

Cockpit publicava 9090/TCP e possuía rota explícita `cockpit.guiosoft.info -> localhost:9090` no Cloudflare Tunnel. O cluster foi validado após desabilitar Cockpit e permaneceu normal. A rota Cloudflare foi então removida. Administração do host passa a privilegiar SSH, Ansible e CLI, reduzindo interfaces administrativas privilegiadas.

## Firecrawl LAN-only e split-horizon DNS

A alternativa de usar `guiosoft-info.local` via Avahi/mDNS foi considerada, mas o desenho escolhido é split-horizon DNS com o mesmo hostname estável `firecrawl.guiosoft.info`.

O MikroTik RouterOS da LAN atua como resolvedor DNS em `192.168.88.1`. O DHCP foi ajustado para entregar somente esse resolvedor aos clientes, evitando que resolvers públicos secundários contornem o override local. O MikroTik continua encaminhando consultas externas para seus upstreams.

Foi criado um registro DNS local para:

```text
firecrawl.guiosoft.info -> 192.168.88.9
```

Validação em 2026-09-14:

- `dig @192.168.88.1 firecrawl.guiosoft.info A` retornou `192.168.88.9` com TTL 300;
- `/etc/resolv.conf` do servidor passou a conter somente `nameserver 192.168.88.1`;
- `getent ahostsv4 firecrawl.guiosoft.info` retornou `192.168.88.9`;
- `curl http://firecrawl.guiosoft.info/` chegou ao Traefik/Firecrawl pela LAN e retornou HTTP 200;
- o teste funcional do Firecrawl foi executado com sucesso pelo caminho LAN-only;
- Hermes foi testado com sucesso consumindo o Firecrawl por esse caminho interno, sem depender dos headers do Cloudflare Access;
- OpenCode foi testado com sucesso via MCP após adicionar a configuração Firecrawl ao objeto `mcp` de `~/.config/opencode/opencode.jsonc`.

Com isso, ambos os consumidores reais estão validados no caminho interno:

```text
Hermes / OpenCode
       |
       | DNS da LAN
       v
MikroTik 192.168.88.1
       |
       | firecrawl.guiosoft.info = 192.168.88.9
       v
Traefik -> Firecrawl K3s
```

A necessidade arquitetural de modificar/forkar Hermes apenas para adicionar os headers `CF-Access-Client-Id` e `CF-Access-Client-Secret` deixa de existir. OpenCode também opera sem depender da publicação Cloudflare do Firecrawl.

O gate funcional para a migração LAN-only está concluído. O próximo passo é remover a publicação pública/Cloudflare Access e os Service Tokens do Firecrawl e reconciliar o Terraform para que esses recursos não sejam recriados. Essa remoção deve preservar o registro DNS local do MikroTik e o Ingress Traefik, pois o mesmo hostname continuará sendo usado dentro da LAN.

Avahi permanece ativo por enquanto, mas deixou de ser requisito para o Firecrawl. Sua necessidade poderá ser reavaliada separadamente.

## Modelo de segurança desejado

Antes de firewall, reduzir a superfície removendo listeners sem consumidor real. Depois, classificar o que restar em loopback, LAN, cluster, Cloudflare Tunnel ou exceção Internet direta.

A política futura deve negar inbound não solicitado e liberar somente origens/portas necessárias. O role não deve tomar posse do ruleset inteiro porque Docker, K3s, Flannel e ServiceLB também manipulam nftables.

Princípios:

- preservar loopback e `established,related`;
- preservar SSH antes de qualquer `drop` default;
- não `flush` nem recriar chains/tabelas gerenciadas por K3s/Docker;
- restringir regras do host à interface/origem apropriada;
- tratar Pod CIDR `10.42.0.0/16` e Service CIDR `10.43.0.0/16` separadamente da LAN;
- manter 8472/UDP restrito aos nós quando houver múltiplos nós;
- manter 9100/TCP acessível somente ao caminho necessário ao Prometheus;
- validar Traefik, DNS, Kubernetes API, observabilidade e SSH após cada mudança;
- manter rollback local antes da primeira política default-deny.

## Pendências antes do enforcement

- remover publicação/Access Cloudflare do Firecrawl e reconciliar Terraform; Hermes e OpenCode já estão validados pela LAN;
- reavaliar se Avahi ainda possui consumidor real;
- verificar regras de port-forward/NAT no roteador;
- definir origens exatas para SSH, API 6443, kubelet 10250, node-exporter 9100 e Flannel 8472;
- implementar o role `firewall` incremental e validar rollback.

## Auditoria

Executar a qualquer momento:

```bash
make firewall-audit
```

O audit é read-only e não exige mais o antigo Firecrawl Docker em `127.0.0.1:3002`.

## Decisões de hardening registradas em 2026-09-14

O processo mostrou uma preferência explícita por eliminar serviços sem consumidor antes de escondê-los atrás de firewall. NFS/RPC, PCP e Cockpit foram retirados da superfície de rede por esse motivo. Para o Firecrawl, o split-DNS local foi validado até o serviço K3s e com os dois consumidores reais, Hermes e OpenCode, mantendo um hostname estável sem depender de mDNS ou Cloudflare Access. O gate funcional LAN-only está concluído; resta desmontar a exposição pública de forma declarativa.
