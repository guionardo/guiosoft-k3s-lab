# Estado atual e decisões de escopo

Atualizado após o primeiro discovery do host `guiosoft-info`.

## Host

- Debian 13 (trixie)
- Intel Core i5-8500, 6 cores
- 16 GB RAM
- Docker/containerd ativos
- Cloudflare Tunnel ativo via systemd
- Tailscale instalado e ativo
- K3s ainda não instalado

## Serviços encontrados

O discovery identificou, entre outros, os seguintes stacks Docker Compose:

- `escoteirando-suite`
- `firecrawl`
- `gitea`

### Decisões

#### escoteirando-suite

Fora do escopo deste laboratório. Não será migrado para K3s e não deve influenciar o desenho do cluster.

#### gitea

Fora do escopo deste laboratório. Não será migrado para K3s.

#### firecrawl

Permanece relevante para o estado atual do servidor e deve ser preservado durante a implantação do K3s. Qualquer migração futura será uma decisão separada.

#### OpenShip

Situação pendente de confirmação. Não remover configuração nem hostname relacionado até decisão explícita.

## Tailscale

Foi decidido remover Tailscale do servidor. A remoção deve ser feita como uma etapa explícita e verificável antes do bootstrap do K3s.

Antes da remoção, confirmar que:

- nenhum acesso administrativo depende exclusivamente do Tailscale;
- não há serviços consumindo o IP `100.x` do host;
- nenhum DNS interno necessário depende do MagicDNS;
- `/etc/resolv.conf` voltará a ser gerenciado corretamente pela configuração normal do host após a remoção.

## Cloudflare

Os seguintes hostnames encontrados no histórico/configuração não são mais necessários e podem ser removidos do Cloudflare:

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
