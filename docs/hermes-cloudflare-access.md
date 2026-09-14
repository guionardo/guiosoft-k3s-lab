# Hermes + Cloudflare Access — trabalho futuro

## Contexto

O Firecrawl self-hosted está publicado em `https://firecrawl.guiosoft.info` e protegido por Cloudflare Access com autenticação machine-to-machine via Service Tokens.

O desenho atual usa um Service Token independente por consumidor:

- `firecrawl-hermes`;
- `firecrawl-opencode`.

O Cloudflare Access espera os headers:

```http
CF-Access-Client-Id: <client-id>
CF-Access-Client-Secret: <client-secret>
```

O Hermes atualmente aceita `FIRECRAWL_API_URL` e `FIRECRAWL_API_KEY`, mas não possui suporte nativo para injetar os dois headers do Cloudflare Access nas chamadas ao Firecrawl.

Por isso, a integração direta Hermes -> Firecrawl protegido por Access fica registrada como trabalho futuro. Não será introduzido proxy intermediário apenas para contornar essa limitação enquanto uma alteração pequena no Hermes puder resolver o problema de forma genérica.

## Implementação proposta

Adicionar ao Hermes duas variáveis opcionais:

```dotenv
FIRECRAWL_CF_ACCESS_CLIENT_ID=...
FIRECRAWL_CF_ACCESS_CLIENT_SECRET=...
```

Quando ambas estiverem presentes, toda chamada destinada ao `FIRECRAWL_API_URL` deverá incluir:

```http
CF-Access-Client-Id: <FIRECRAWL_CF_ACCESS_CLIENT_ID>
CF-Access-Client-Secret: <FIRECRAWL_CF_ACCESS_CLIENT_SECRET>
```

Quando ausentes, o comportamento atual deve permanecer inalterado.

`FIRECRAWL_API_KEY` deve continuar com sua semântica normal e não deve ser reutilizada para credenciais do Cloudflare Access. Isso mantém as camadas independentes:

```text
Hermes
  |
  |-- CF-Access-Client-* ------> Cloudflare Access
  |
  `-- Authorization: Bearer --> autenticação nativa Firecrawl, se usada no futuro
```

No perfil atual do homelab, `USE_DB_AUTHENTICATION=false`, portanto a autenticação autoritativa permanece no Cloudflare Access.

## Requisitos da alteração upstream

A implementação futura deve:

1. localizar todos os caminhos do Hermes que fazem requests ao Firecrawl, incluindo ferramentas web e browser quando aplicável;
2. centralizar a construção dos headers para evitar comportamento inconsistente entre ferramentas;
3. adicionar as novas variáveis à configuração/whitelist de environment variables do Hermes;
4. nunca registrar o Client Secret em logs;
5. manter compatibilidade retroativa quando as variáveis não estiverem definidas;
6. adicionar testes unitários para presença, ausência e configuração parcial das credenciais;
7. validar a integração real contra `firecrawl.guiosoft.info`;
8. preparar a alteração como contribuição upstream ao `NousResearch/hermes-agent`, evitando um fork permanente.

## Casos de teste esperados

```text
sem client id / sem secret -> nenhum header Cloudflare
client id + secret         -> envia os dois headers
somente client id          -> não envia autenticação parcial
somente secret             -> não envia autenticação parcial
credenciais válidas        -> request Firecrawl autenticado com sucesso
credenciais ausentes       -> Cloudflare Access responde HTTP 401
```

## Configuração futura do Hermes

O arquivo `~/.hermes/.env` deverá ficar conceitualmente assim:

```dotenv
FIRECRAWL_API_URL=https://firecrawl.guiosoft.info
FIRECRAWL_CF_ACCESS_CLIENT_ID=<client-id-do-hermes>
FIRECRAWL_CF_ACCESS_CLIENT_SECRET=<client-secret-do-hermes>
```

Não versionar nem copiar o Client Secret para este repositório.

## Decisão arquitetural

Por enquanto, manter Cloudflare Access em vez de substituir a proteção por autenticação nativa do Firecrawl ou por um proxy/ForwardAuth adicional.

Motivos:

- o Access já está provisionado e validado;
- os consumidores são machine-to-machine;
- Service Tokens separados permitem revogação e rotação por agente;
- ativar autenticação nativa completa do Firecrawl self-hosted adicionaria dependências e complexidade operacional desnecessárias ao objetivo atual;
- a lacuna está no cliente Hermes e pode ser resolvida com uma extensão pequena e reutilizável.

A decisão deve ser reavaliada se o Firecrawl self-hosted passar a oferecer autenticação simples por API key sem dependências adicionais, ou se o Hermes incorporar suporte equivalente upstream.

## Fontes

- Hermes Agent: https://github.com/NousResearch/hermes-agent
- Firecrawl self-hosting: https://github.com/firecrawl/firecrawl/blob/main/SELF_HOST.md
- Cloudflare Access Service Tokens: https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/
