# Bootstrap com Ansible

Esta primeira versão é deliberadamente conservadora: prepara o Debian e instala K3s sem remover Docker, Firecrawl ou o `cloudflared` atual.

## Versão do K3s

O cluster está fixado em `v1.36.4+k3s1` para tornar rebuilds reproduzíveis. A versão só deve ser alterada conscientemente em `ansible/group_vars/all.yml`.

## Rede do cluster

As redes padrão escolhidas são:

- Pods: `10.42.0.0/16`
- Services: `10.43.0.0/16`

Elas não colidem com as bridges Docker observadas no discovery (`172.17.0.0/16` a `172.21.0.0/16`).

## Execução

No próprio servidor:

```bash
git pull
make ansible-deps
make preflight
make bootstrap
make k3s
make cluster-status
```

### `make preflight`

Valida antes da primeira instalação:

- resolução DNS;
- ausência da interface `tailscale0`;
- portas 80/443 livres para Traefik/ServiceLB;
- Docker ativo, porque Firecrawl deve ser preservado;
- `cloudflared` ativo durante a implantação inicial.

Depois que K3s já estiver instalado, a checagem de 80/443 deixa de bloquear reexecuções do bootstrap.

### `make bootstrap`

- instala pacotes base;
- carrega `overlay` e `br_netfilter`;
- persiste os módulos;
- configura forwarding e bridge netfilter;
- cria `/etc/rancher/k3s`.

Não instala K3s e não altera containers Docker existentes.

### `make k3s`

- grava `/etc/rancher/k3s/config.yaml`;
- baixa o instalador oficial;
- instala a versão fixada;
- ativa o serviço `k3s`;
- espera `/readyz` responder;
- mostra o estado do node.

O datastore inicial é o SQLite padrão do K3s e o data-dir permanece em `/var/lib/rancher/k3s` no SSD do sistema. Isso é suficiente para o laboratório single-node; a estratégia definitiva de storage será tratada em fase posterior.

## Idempotência

Os playbooks podem ser reexecutados. A instalação do K3s só é refeita quando a versão instalada não corresponde à versão fixada.

## O que esta etapa não faz

- não remove Docker;
- não modifica Firecrawl;
- não move `cloudflared` para Kubernetes;
- não configura DNS/Cloudflare;
- não cria aplicações Kubernetes;
- não configura backup;
- não instala observabilidade;
- não altera o OpenShip.

Esses itens serão tratados em etapas separadas para manter rollback simples.
