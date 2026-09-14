# Firewall e exposição de portas

## Estado validado

O audit pós-K3s confirmou que o host continua funcional após a instalação do cluster:

- K3s ativo;
- Docker daemon ativo;
- `cloudflared` ativo;
- Kubernetes API respondendo;
- Traefik respondendo corretamente;
- UFW instalado, porém **inativo**.

O antigo Docker Compose do Firecrawl está **parado** e preservado somente para rollback. Portanto, a porta TCP 3002 não deve mais ser considerada um listener obrigatório do host. A variável `preserve_docker` significa preservar o daemon Docker durante o bootstrap, e não manter workloads Docker específicos em execução.

O host possui diversos listeners vinculados a `0.0.0.0`, `::` ou `*`, portanto acessíveis pelas interfaces do host salvo bloqueio por firewall externo, roteador ou outra regra nftables.

Portas vinculadas apenas a `127.0.0.1`/`::1` não são consideradas exposição LAN direta.

## Inventário pós-cutover — 2026-09-14

A auditoria executada depois da parada do Docker Compose legado passou com:

```text
K3s: active
Docker daemon: active
cloudflared: active
Kubernetes API: ok
UFW: inactive
nftables: 1363 linhas no ruleset atual
```

### Classificação inicial dos listeners

| Serviço / finalidade | Porta/protocolo | Bind observado | Escopo recomendado | Observação |
|---|---:|---|---|---|
| SSH | 22/TCP | `0.0.0.0`, `::` | LAN administrativa | manter acesso antes de qualquer política default-deny |
| Kubernetes API | 6443/TCP | `*` | LAN administrativa + nós do cluster | kubeconfig remoto LAN já foi validado; não publicar na Internet |
| kubelet | 10250/TCP | `*` | cluster | necessário para componentes como metrics-server; não expor à LAN inteira/Internet sem necessidade |
| Flannel VXLAN | 8472/UDP | `0.0.0.0` | nós do cluster | reservar para comunicação K3s entre nós; nunca Internet |
| node-exporter | 9100/TCP | `*` | cluster/monitoramento | Prometheus precisa alcançar o exporter; não há motivo para publicação externa |
| Cockpit | 9090/TCP | `*` | Cloudflare Tunnel e, opcionalmente, LAN administrativa | o Tunnel já possui rota explícita para `localhost:9090`; acesso LAN direto pode ser removido se não for usado |
| NFS | 2049/TCP | `0.0.0.0`, `::` | LAN confiável | restringir à sub-rede/clientes que realmente montam exports |
| rpcbind | 111/TCP+UDP | `0.0.0.0`, `::` | LAN confiável somente se exigido pelo perfil NFS | não deve ficar disponível fora da LAN |
| rpc.mountd | TCP 60823/43449/38483; UDP 58268/51611/41179 | `0.0.0.0`, `::` | LAN confiável somente se clientes NFSv3 precisarem | portas dinâmicas por versão RPC; forte candidato a eliminação do firewall se todos os clientes usarem NFSv4 |
| rpc.statd | 36343/TCP, 50988/UDP | `0.0.0.0`, `::` | LAN confiável somente se NFSv3/locking legado exigir | não abrir genericamente |
| nlockmgr | 38205/TCP, 35280/UDP | `0.0.0.0`, `::` | LAN confiável somente se NFSv3 exigir | não abrir genericamente |
| PCP `pmlogger` | 4330/TCP | `0.0.0.0`, `::` | host/LAN somente se houver consumidor remoto | não há evidência atual de necessidade Internet |
| PCP `pmcd` | 44321/TCP | `0.0.0.0`, `::` | host/LAN somente se houver consumidor remoto | revisar relação com Cockpit/monitoramento |
| PCP `pmproxy` | 44322-44323/TCP | `0.0.0.0`, `::` | host/LAN somente se houver consumidor remoto | candidato a bloqueio de ingress LAN se uso for apenas local |
| Avahi/mDNS | 5353/UDP | `0.0.0.0`, `::` | LAN multicast | manter apenas se descoberta mDNS for desejada |
| DHCP client | 68/UDP, 546/UDP | interface LAN | infraestrutura de rede | tráfego de cliente; política stateful deve preservar respostas válidas |
| cloudflared QUIC | portas UDP efêmeras | `*` | saída estabelecida | sockets UDP do cliente outbound; não são serviços que precisem ser publicados inbound |
| Postfix local | 25/TCP | `127.0.0.1`, `::1` | loopback | nenhuma regra LAN necessária |
| K3s internos | 6444, 10248, 10249, 10256-10259/TCP | loopback | loopback | não expostos diretamente à LAN |
| cloudflared metrics/local | 20241/TCP | `127.0.0.1` | loopback | não exposto diretamente à LAN |
| processos de desenvolvimento (`kubectl`, Electron/Code etc.) | portas altas | loopback | loopback | fora do escopo do firewall LAN |

## NFS/RPC — correlação validada

O `rpcinfo -p` confirmou que as portas altas vistas no `ss` pertencem ao stack NFS/RPC e não devem ser liberadas como um range genérico:

```text
rpcbind     111/TCP+UDP
nfs         2049/TCP (v3 e v4)
nfs_acl     2049/TCP
mountd      60823/43449/38483 TCP
mountd      58268/51611/41179 UDP
status      36343/TCP, 50988/UDP
nlockmgr    38205/TCP, 35280/UDP
```

A presença de `mountd`, `status` e `nlockmgr` expostos confirma compatibilidade NFSv3 ativa. Se os clientes reais já puderem operar somente com NFSv4, a política de firewall pode ficar substancialmente menor: em geral o tráfego de dados fica concentrado em TCP 2049, enquanto dependências clássicas de mountd/statd/nlockmgr deixam de ser necessárias para o caminho de cliente v4.

Não alterar o servidor para NFSv4-only antes de identificar quais clientes montam exports e qual versão eles negociam. A próxima decisão deve ser baseada no uso real, não apenas no que o servidor oferece.

## Decisão atual

Não habilitar UFW automaticamente neste estágio.

K3s, Docker e ServiceLB manipulam regras de rede/nftables. Ativar um firewall genérico sem uma política previamente definida pode interromper:

- tráfego de Pods e Services;
- ServiceLB/Traefik;
- Docker;
- NFS;
- acesso administrativo SSH;
- acesso de ferramentas de monitoramento.

Portanto o projeto mantém, por enquanto, apenas auditoria read-only e documentação do estado observado.

O playbook de auditoria coleta TCP, UDP e uma leitura do ruleset nftables, mas não altera nenhuma regra. Ele também não testa mais `127.0.0.1:3002`, porque o Firecrawl passou pelo cutover para K3s e o Compose antigo está parado.

## Modelo de segurança desejado

A publicação HTTP/HTTPS de aplicações deve ocorrer preferencialmente por Cloudflare Tunnel, que é outbound-only. Isso evita a necessidade de encaminhar portas 80/443 no roteador para o servidor.

Antes de criar um role Ansible que aplique firewall, classificar cada serviço em uma das categorias abaixo:

1. **loopback somente** — acessível apenas no próprio host;
2. **LAN** — acessível somente pela rede local confiável;
3. **cluster** — necessário entre nós/pods do Kubernetes;
4. **Cloudflare Tunnel** — publicado externamente sem inbound direto;
5. **Internet direto** — exceção explícita e documentada.

A política padrão futura deve ser negar inbound não solicitado e liberar somente portas e origens necessárias.

### Princípios para o role futuro

O role de firewall deve ser incremental e não tomar posse do ruleset completo:

- preservar explicitamente loopback e conexões `established,related`;
- preservar SSH administrativo antes de qualquer `drop` default;
- não apagar, `flush` ou recriar tabelas/chains gerenciadas por K3s, Flannel, kube-proxy/ServiceLB ou Docker;
- não assumir que `ufw enable` é seguro apenas porque o pacote está instalado;
- restringir regras do host à interface LAN e aos serviços classificados;
- tratar CIDRs de Pods (`10.42.0.0/16`) e Services (`10.43.0.0/16`) separadamente de clientes LAN;
- manter UDP 8472 restrito aos nós K3s quando houver mais de um nó;
- não liberar portas RPC dinâmicas para `any`; preferir NFSv4-only quando compatível ou, se NFSv3 for realmente necessário, fixar portas RPC antes do enforcement;
- validar Traefik, DNS, Kubernetes API, observabilidade, NFS e SSH após cada mudança;
- manter um caminho de rollback local antes da primeira política default-deny.

## Pendências antes de ativar firewall

- identificar os clientes NFS reais e as versões/protocolos que estão usando;
- decidir se o servidor pode ser simplificado para NFSv4-only ou se NFSv3 precisa ser mantido;
- decidir se Cockpit TCP 9090 continuará acessível diretamente pela LAN ou somente pelo Cloudflare Tunnel/local;
- confirmar se existe algum consumidor remoto de PCP (`pmcd`, `pmproxy`, `pmlogger`);
- verificar regras de port-forward/NAT no roteador;
- somente então implementar e testar o role `firewall` de forma incremental.

## Auditoria

Executar novamente a qualquer momento:

```bash
make firewall-audit
```

O audit deve continuar sem alterar regras do host. Depois do cutover do Firecrawl, a ausência de listener em `127.0.0.1:3002` é esperada e não deve causar falha.

Para classificar o bloco NFS/RPC sem modificar o host, executar também:

```bash
rpcinfo -p
```

Para identificar clientes NFS ativos e a versão negociada antes de qualquer mudança do servidor, usar ferramentas read-only como `ss`, `nfsstat` e inspeção dos mounts dos clientes.

## Evidências desta revisão

Em 2026-09-14, a auditoria anterior falhou exclusivamente porque ainda tentava validar o endpoint Docker legado do Firecrawl em `127.0.0.1:3002`. O Compose já estava parado intencionalmente; K3s, Docker daemon, `cloudflared`, Traefik e Kubernetes API haviam passado nas verificações anteriores. O playbook foi ajustado para refletir essa nova responsabilidade operacional.

A auditoria seguinte passou e registrou o inventário TCP/UDP pós-cutover descrito acima. A classificação permanece deliberadamente conservadora: nenhum listener foi bloqueado ou reconfigurado nesta etapa.

O `rpcinfo -p` executado em 2026-09-14 correlacionou as portas altas a `mountd`, `status` e `nlockmgr`, além de confirmar NFS v3 e v4 em TCP 2049. Isso fecha a identificação das portas RPC, mas ainda não autoriza removê-las: falta confirmar quais versões os clientes realmente usam.