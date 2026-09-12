# Firewall e exposição de portas

## Estado validado

O audit pós-K3s confirmou que o host continua funcional após a instalação do cluster:

- K3s ativo;
- Docker ativo;
- `cloudflared` ativo;
- Kubernetes API respondendo;
- Firecrawl preservado;
- Traefik respondendo corretamente;
- UFW instalado, porém **inativo**.

O host possui diversos listeners vinculados a `0.0.0.0`, `::` ou `*`, portanto acessíveis pelas interfaces do host salvo bloqueio por firewall externo, roteador ou outra regra nftables.

Entre os listeners relevantes observados estão:

- SSH: TCP 22;
- RPC/rpcbind: TCP 111 e portas dinâmicas;
- NFS: TCP 2049 e portas auxiliares de `rpc.mountd`/`rpc.statd`;
- Firecrawl: TCP 3002;
- PCP (`pmlogger`, `pmcd`, `pmproxy`): TCP 4330 e 44321-44323;
- Kubernetes API: TCP 6443;
- kubelet: TCP 10250;
- Cockpit: TCP 9090.

Portas vinculadas apenas a `127.0.0.1` não são consideradas exposição LAN direta.

## Decisão atual

Não habilitar UFW automaticamente neste estágio.

K3s, Docker e ServiceLB manipulam regras de rede/nftables. Ativar um firewall genérico sem uma política previamente definida pode interromper:

- tráfego de Pods e Services;
- ServiceLB/Traefik;
- Docker/Firecrawl;
- NFS;
- acesso administrativo SSH;
- acesso de ferramentas de monitoramento.

Portanto o projeto mantém, por enquanto, apenas auditoria read-only e documentação do estado observado.

## Modelo de segurança desejado

A publicação HTTP/HTTPS de aplicações deve ocorrer preferencialmente por Cloudflare Tunnel, que é outbound-only. Isso evita a necessidade de encaminhar portas 80/443 no roteador para o servidor.

Antes de criar um role Ansible que aplique firewall, classificar cada serviço em uma das categorias abaixo:

1. **loopback somente** — acessível apenas no próprio host;
2. **LAN** — acessível somente pela rede local confiável;
3. **cluster** — necessário entre nós/pods do Kubernetes;
4. **Cloudflare Tunnel** — publicado externamente sem inbound direto;
5. **Internet direto** — exceção explícita e documentada.

A política padrão futura deve ser negar inbound não solicitado e liberar somente portas e origens necessárias.

## Pendências antes de ativar firewall

- confirmar quais serviços precisam permanecer acessíveis pela LAN;
- confirmar se NFS continua necessário e quais clientes/sub-redes o utilizam;
- decidir se Firecrawl TCP 3002 precisa de acesso LAN ou apenas local;
- decidir se Cockpit TCP 9090 deve ficar LAN-only ou protegido por Cloudflare Access;
- avaliar necessidade dos listeners PCP na LAN;
- definir política para Kubernetes API TCP 6443 e kubelet TCP 10250;
- verificar regras de port-forward/NAT no roteador;
- somente então implementar e testar o role `firewall` de forma incremental.

## Auditoria

Executar novamente a qualquer momento:

```bash
make firewall-audit
```

O audit deve continuar sem alterar regras do host.
