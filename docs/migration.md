# Estratégia de migração

## Princípio

A migração será incremental. Instalar K3s não implica remover ou alterar imediatamente nenhum serviço atual.

```text
ANTES
Cloudflare Tunnel -> serviço no host

DURANTE
Cloudflare Tunnel -> alguns serviços no host
                  -> alguns serviços no K3s

DEPOIS
Cloudflare Tunnel -> K3s -> Traefik -> Services
```

## Matriz de migração

Após o discovery, preencheremos uma tabela como esta com dados reais:

| Serviço | Runtime atual | Porta | Dados | Hostname | Target namespace | Persistência | Risco | Rollback |
|---|---|---:|---|---|---|---|---|---|
| TBD | TBD | TBD | TBD | TBD.guiosoft.info | TBD | TBD | TBD | rota antiga |

## Critérios antes de migrar um serviço

- runtime e versão conhecidos;
- dependências conhecidas;
- caminhos de dados conhecidos;
- backup disponível quando houver estado persistente;
- health check definido;
- requests/limits iniciais definidos;
- Service Kubernetes funcional;
- Ingress funcional;
- logs observáveis;
- procedimento de rollback documentado.

## Cutover

O cutover preferencial consiste em alterar apenas a rota/public hostname do Cloudflare Tunnel depois que a versão Kubernetes estiver validada.

A instalação antiga deve permanecer disponível durante a janela inicial de observação quando isso não causar conflito de dados.

Serviços stateful exigirão procedimento específico para impedir escrita simultânea nas duas instâncias.

## Rollback

Rollback ideal:

```text
hostname -> destino Kubernetes
          ↓ problema
hostname -> destino antigo no host
```

O serviço antigo só será removido quando a nova implantação estiver considerada estável e os backups/restores necessários estiverem validados.
