# Firewall e exposição de portas

## Estado validado

Em 2026-09-14 a superfície do host foi reduzida e classificada antes da primeira política default-deny.

NFS/RPC, PCP (`pmcd`, `pmlogger`, `pmproxy`) e Cockpit foram desabilitados porque não possuem consumidor necessário no desenho atual. O Firecrawl antigo em Docker Compose foi parado e não publica mais `3002/TCP`; containers e volumes permanecem preservados somente durante a janela de rollback.

O MikroTik foi inspecionado e possui somente a regra padrão de `srcnat masquerade`. Não existe `dstnat`/port-forward direto para `192.168.88.9`, portanto as portas do host não são publicadas diretamente pela borda.

## Serviços relevantes restantes

| Serviço / finalidade | Porta/protocolo | Escopo atual |
|---|---:|---|
| SSH | 22/TCP | LAN administrativa |
| Kubernetes API | 6443/TCP | LAN administrativa + futuros nós |
| kubelet | 10250/TCP | cluster |
| node-exporter | 9100/TCP | cluster/monitoramento |
| Flannel VXLAN | 8472/UDP | nós K3s; nenhum peer remoto no single-node atual |
| Avahi/mDNS | 5353/UDP | LAN multicast, mantido por enquanto |
| DHCP client | 68/UDP, 546/UDP | infraestrutura de rede |
| cloudflared QUIC | UDP efêmero | saída |
| Traefik/ServiceLB | 80/443 | LAN/K3s; publicação externa ocorre pelo Tunnel |

Listeners exclusivamente em loopback permanecem fora da exposição LAN direta.

## Política implementada

O host não utiliza UFW para o enforcement atual. A política foi implementada diretamente em uma tabela nftables própria:

```text
table inet guiosoft_host
```

Princípios do desenho:

- possuir somente hook de `INPUT`;
- não executar `flush ruleset`;
- não controlar `FORWARD` ou `NAT`;
- não modificar tabelas/chains de Docker, K3s, Flannel ou ServiceLB;
- preservar loopback e `established,related`;
- manter SSH permitido antes do default-drop;
- limitar serviços administrativos à LAN;
- manter interfaces internas do cluster confiáveis no host;
- preparar 8472/UDP para ser explicitamente liberado por endereço de node quando o cluster ganhar novos nós.

Ruleset atual, em termos funcionais:

```text
loopback                                  accept
ct state established,related             accept
ct state invalid                         drop
ICMP / ICMPv6                            accept
DHCP replies na enp2s0                   accept
192.168.88.0/24 -> TCP 22,80,443,6443    accept
mDNS multicast -> UDP 5353               accept
cni0                                     accept
flannel.1                                accept
restante do INPUT                        drop
```

Enquanto o cluster permanecer single-node, `8472/UDP` não é liberado para a LAN inteira. Antes de adicionar outro node, os endereços IPv4 dos peers devem ser adicionados a `firewall_k3s_node_ipv4`.

## Processo de implantação seguro

A implantação foi feita em etapas.

### 1. Classificação read-only

`firewall-classify.yml` coletou interfaces, rotas, listeners TCP/UDP, nodes, services, ingresses, Docker networks e tamanho do ruleset existente. A classificação confirmou LAN `192.168.88.0/24`, node `192.168.88.9` e os listeners relevantes restantes.

### 2. Staging sem alteração live

O role `firewall` primeiro renderizou `/etc/nftables.d/guiosoft-host.nft` e executou:

```bash
nft --check --file /etc/nftables.d/guiosoft-host.nft
```

Nenhuma regra foi carregada enquanto `firewall_enforce=false`.

### 3. Trial com rollback automático

O primeiro enforcement armou um timer systemd de rollback por cinco minutos antes de carregar a tabela. O rollback removeria somente `table inet guiosoft_host` se a conectividade fosse perdida.

Após o apply foram validados:

- Kubernetes `/readyz` local;
- Traefik local;
- nova sessão SSH pela LAN;
- kubeconfig externo / `kubectl` pela LAN;
- Firecrawl via `http://firecrawl.guiosoft.info/`.

Com os testes aprovados, `firewall-confirm.yml` cancelou o rollback e manteve a tabela ativa.

### 4. Persistência

A persistência é fornecida por:

```text
guiosoft-host-firewall.service
```

O unit é separado do `nftables.service` global e carrega somente o arquivo versionado da policy. Ele está habilitado para o boot e ordenado antes de `k3s.service` e `cloudflared.service`.

A policy live foi validada com o cluster inteiro operacional e Firecrawl retornando HTTP 200. Falta apenas validar a execução do unit em um reboot real; até esse teste a persistência deve ser considerada configurada, porém ainda não comprovada pós-boot.

## Firecrawl LAN-only

O Firecrawl usa split-horizon DNS no MikroTik:

```text
firecrawl.guiosoft.info -> 192.168.88.9
```

Hermes e OpenCode/MCP foram validados pelo caminho interno. No Cloudflare Tunnel existe regra explícita anterior ao wildcard:

```text
firecrawl.guiosoft.info -> http_status:404
```

A aplicação Cloudflare Access e os dois Service Tokens antigos foram removidos declarativamente depois do bloqueio público. Assim, o mesmo hostname funciona internamente e é deliberadamente recusado na rota pública.

## Serviços eliminados da superfície

### NFS/RPC

Nenhum export, cliente, chamada ou conexão ativa foi encontrado. `nfs-server`, `rpcbind.service` e `rpcbind.socket` permanecem desabilitados.

### PCP

`pmcd`, `pmlogger` e `pmproxy` publicavam 4330 e 44321-44323/TCP. Como kube-prometheus-stack cobre a observabilidade necessária, foram desabilitados e posteriormente confirmados como `disabled` e `inactive`.

### Cockpit

Cockpit foi desabilitado e sua rota Cloudflare removida. Administração do host privilegia SSH, Ansible e CLI.

## Avahi

Avahi permanece ativo deliberadamente, embora não seja mais necessário para o Firecrawl. A exceção mDNS pode ser removida junto com o serviço quando não houver mais consumidor real.

## Auditoria e operação

Auditoria read-only:

```bash
make firewall-audit
```

Classificação detalhada:

```bash
cd ansible
ansible-playbook -K playbooks/firewall-classify.yml
```

Staging da policy:

```bash
cd ansible
ansible-playbook -K playbooks/firewall.yml
```

Trial live protegido por rollback:

```bash
cd ansible
ansible-playbook -K playbooks/firewall.yml -e firewall_enforce=true
```

Confirmação após testes externos:

```bash
cd ansible
ansible-playbook -K playbooks/firewall-confirm.yml
```

Configuração da persistência:

```bash
cd ansible
ansible-playbook -K playbooks/firewall-persist.yml
```

## Pendência final desta fase

Executar um reboot real e confirmar que:

- `guiosoft-host-firewall.service` fica `active (exited)`;
- `table inet guiosoft_host` existe após o boot;
- SSH novo pela LAN funciona;
- Kubernetes API/kubeconfig externo funcionam;
- todos os Pods retornam saudáveis;
- Firecrawl continua retornando HTTP 200 pela LAN;
- Cloudflare Tunnel e workloads públicos continuam operacionais.
