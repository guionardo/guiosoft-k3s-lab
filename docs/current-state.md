# Estado atual e decisões de escopo

Atualizado após discovery, limpeza manual do host, instalação do K3s e validação do acesso externo via Cloudflare Tunnel.

## Host

- Debian 13 (trixie)
- Intel Core i5-8500, 6 cores
- 16 GB RAM
- Docker/containerd ativos
- Cloudflare Tunnel ativo via systemd
- Tailscale removido
- K3s `v1.36.4+k3s1` instalado e operacional

## Validação pós-limpeza

A validação manual confirmou:

- `/etc/resolv.conf` gerenciado pelo `dhcpcd` da interface `enp2s0`;
- resolução DNS externa funcionando;
- rota default pela interface LAN preservada;
- apenas o stack Firecrawl permanece ativo no Docker entre os workloads relevantes;
- Tailscale não aparece mais entre interfaces/rotas/serviços observados.

Após a instalação do K3s, as portas TCP 80 e 443 passaram a ser utilizadas pelo Traefik/ServiceLB, conforme esperado.

## Cluster K3s

O cluster single-node está operacional com:

- node em estado `Ready`;
- CoreDNS em execução;
- metrics-server em execução;
- local-path-provisioner em execução;
- Traefik em execução;
- ServiceLB do Traefik publicado no endereço LAN do host.

O namespace `lab` contém um workload de teste baseado em `traefik/whoami`, publicado por Service e Ingress no hostname:

```text
k3s-test.guiosoft.info
```

O caminho local foi validado com sucesso:

```text
127.0.0.1:80
    ↓
Traefik
    ↓
Ingress
    ↓
Service
    ↓
Pod
```

## Serviços atuais

### firecrawl

Deve ser preservado durante a evolução do laboratório. Atualmente utiliza externamente a porta TCP `3002`; PostgreSQL, Redis, RabbitMQ e Playwright permanecem internos à rede Docker.

Qualquer migração futura será uma decisão separada.

### escoteirando-suite

Removido do host e fora do escopo deste laboratório.

### gitea

Removido do host e fora do escopo deste laboratório.

### OpenShip

A publicação do OpenShip foi removida do Cloudflare. A situação local do serviço ainda pode ser verificada separadamente antes de qualquer limpeza adicional no host.

## Tailscale

Tailscale já foi desinstalado manualmente e a rede/DNS foram validados após a remoção.

## Cloudflare

O `cloudflared` atual continua executando no host durante esta fase da migração.

A configuração de ingress relevante do Tunnel utiliza:

```text
*.guiosoft.info -> http://127.0.0.1:80
```

O uso explícito de `127.0.0.1` é intencional. `localhost` resolvia primeiro para `::1`, onde não havia listener na porta 80, causando falha do origin no `cloudflared`.

O wildcard DNS `*.guiosoft.info`, que anteriormente apontava para um endereço IPv4 de origin legado, foi alterado para apontar para o Cloudflare Tunnel.

Hostnames com registros DNS específicos continuam podendo apontar para outros Tunnels e têm precedência sobre o wildcard.

Com isso, novos hostnames sem registro DNS específico podem chegar ao Traefik do K3s por meio do wildcard e ser roteados por Ingress.

O fluxo externo foi validado com HTTP 200:

```text
Internet
    ↓
Cloudflare
    ↓
Cloudflare Tunnel
    ↓
cloudflared no host
    ↓
127.0.0.1:80
    ↓
Traefik no K3s
    ↓
Ingress
    ↓
Service
    ↓
Pod
```

O teste `https://k3s-test.guiosoft.info/` retornou a resposta do workload `whoami`, incluindo os headers encaminhados pelo Cloudflare e pelo Traefik.

## Diretriz para publicação de novos workloads

Para aplicações públicas que sigam o caminho padrão do cluster, o objetivo é que a publicação exija principalmente um Ingress Kubernetes para um hostname `*.guiosoft.info`.

Antes de ampliar esse padrão para workloads reais, ainda devem ser definidos:

- comportamento para hostnames desconhecidos;
- padrão de Ingress;
- distinção entre aplicações públicas e privadas;
- estratégia de TLS/origin e headers confiáveis;
- gerenciamento gradual dos recursos Cloudflare por Terraform.

## Próximo passo

Com o caminho externo validado, os próximos itens de base são configurar `kubectl` administrativo sem depender de `sudo k3s kubectl`, documentar troubleshooting básico e definir o padrão de Ingress antes de iniciar a migração de workloads reais.
