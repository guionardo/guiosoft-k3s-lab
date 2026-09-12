# Estado atual e decisões de escopo

Atualizado após o primeiro discovery, a limpeza manual inicial e a validação pós-limpeza do host `guiosoft-info`.

## Host

- Debian 13 (trixie)
- Intel Core i5-8500, 6 cores
- 16 GB RAM
- Docker/containerd ativos
- Cloudflare Tunnel ativo via systemd
- Tailscale removido
- K3s ainda não instalado

## Validação pós-limpeza

A validação manual confirmou:

- `/etc/resolv.conf` voltou a ser gerenciado pelo `dhcpcd` da interface `enp2s0`;
- DNS configurado com gateway LAN e resolvers públicos;
- resolução de `deb.debian.org` funcionando;
- rota default via `192.168.88.1` pela interface `enp2s0`;
- endereço LAN do host `192.168.88.9` preservado;
- apenas o stack Firecrawl permanece ativo no Docker entre os workloads relevantes;
- portas TCP 80 e 443 estão livres;
- Tailscale não aparece mais entre interfaces/rotas/serviços observados.

## Serviços atuais

Após a limpeza manual, apenas o stack `firecrawl` permanece entre os containers relevantes para este laboratório.

### firecrawl

Deve ser preservado durante a implantação do K3s. Atualmente utiliza externamente a porta TCP `3002`; PostgreSQL, Redis, RabbitMQ e Playwright permanecem internos à rede Docker.

Qualquer migração futura será uma decisão separada.

### escoteirando-suite

Removido do host e fora do escopo deste laboratório.

### gitea

Removido do host e fora do escopo deste laboratório.

### OpenShip

Situação pendente de confirmação. Não remover configuração nem hostname relacionado até decisão explícita.

## Tailscale

Tailscale já foi desinstalado manualmente e a rede/DNS foram validados após a remoção.

## Cloudflare

Os seguintes hostnames não são mais necessários e podem ser removidos do Cloudflare:

- `traefik.guiosoft.info`
- `git.guiosoft.info`
- `git-ssh.guiosoft.info`

O hostname relacionado ao OpenShip deve permanecer até confirmação.

A remoção dos hostnames deve ser feita inicialmente no painel/configuração atual do Cloudflare e posteriormente refletida no Terraform quando o gerenciamento do Cloudflare for trazido para Infrastructure as Code.

## Diretriz para o primeiro workload K3s

Não reutilizar `traefik.guiosoft.info` como hostname de teste. O Traefik será um componente interno do cluster, não um serviço que precise ser publicado diretamente na Internet.

Quando chegarmos ao teste externo, criaremos um hostname dedicado e descartável, por exemplo:

```text
k3s-test.guiosoft.info
```

O fluxo esperado será:

```text
Cloudflare Tunnel atual
        ↓
Traefik no K3s
        ↓
Ingress
        ↓
Service
        ↓
Pod de teste
```

## Próximo passo

Executar o preflight Ansible com `become`, depois o bootstrap base e somente então instalar K3s, preservando Docker/Firecrawl e o Cloudflare Tunnel atual.
