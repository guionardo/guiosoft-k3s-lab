# Estado atual e decisões de escopo

Atualizado após o primeiro discovery e a limpeza manual inicial do host `guiosoft-info`.

## Host

- Debian 13 (trixie)
- Intel Core i5-8500, 6 cores
- 16 GB RAM
- Docker/containerd ativos
- Cloudflare Tunnel ativo via systemd
- Tailscale removido
- K3s ainda não instalado

## Serviços atuais

Após a limpeza manual, apenas o stack `firecrawl` permanece entre os containers relevantes para este laboratório.

### firecrawl

Deve ser preservado durante a implantação do K3s. Qualquer migração futura será uma decisão separada.

### escoteirando-suite

Removido do host e fora do escopo deste laboratório.

### gitea

Removido do host e fora do escopo deste laboratório.

### OpenShip

Situação pendente de confirmação. Não remover configuração nem hostname relacionado até decisão explícita.

## Tailscale

Tailscale já foi desinstalado manualmente.

Antes do bootstrap do K3s, validar:

- `/etc/resolv.conf` não referencia mais os resolvers do Tailscale;
- resolução DNS externa funciona normalmente;
- rota default e IP LAN permanecem corretos;
- acesso SSH administrativo funciona sem depender de Tailscale.

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

Validar o estado pós-limpeza do host e então iniciar o bootstrap Ansible para preparação do Debian e instalação do K3s, preservando Docker/Firecrawl e o Cloudflare Tunnel atual.
