# Cloudflare com Terraform

Esta pasta coloca gradualmente o estado já existente da Cloudflare sob Terraform sem recriar recursos em produção.

## Recursos inicialmente declarados

- Cloudflare Tunnel existente;
- configuração remota do Tunnel;
- wildcard DNS `*.guiosoft.info` apontando para o Tunnel;
- Cloudflare Access para proteger `firecrawl.guiosoft.info` com autenticação machine-to-machine;
- Service Tokens separados para Hermes e OpenCode.

A configuração do Tunnel preserva o fluxo validado:

```text
cockpit.guiosoft.info -> http://localhost:9090
*.guiosoft.info       -> http://127.0.0.1:80
fallback               -> http_status:404
```

O Firecrawl continua chegando pelo wildcard já existente, mas o hostname `firecrawl.guiosoft.info` passa a ser protegido pelo Cloudflare Access antes de alcançar o Tunnel.

## Segurança

Nunca grave o API token em `.tf`, `.tfvars` ou no repositório. Exporte-o somente no ambiente:

```bash
export CLOUDFLARE_API_TOKEN='...'
```

O token usado para import/plan deve ter somente as permissões necessárias para os recursos administrados. Para o estado atual isso inclui DNS, Cloudflare Tunnel e também permissões de Access para Applications/Policies e Service Tokens.

`terraform.tfvars`, state e diretórios `.terraform` já são ignorados pelo `.gitignore` do repositório.

### Token temporário para bootstrap/reconstrução completa

Quando este laboratório precisar ser reconstruído do zero, é mais simples criar um único **API Token temporário de bootstrap** com todas as permissões exigidas pelo Terraform Cloudflare deste projeto, em vez de descobrir permissões incrementalmente durante a recuperação.

Esse token é deliberadamente mais poderoso que um token operacional de longa duração. Portanto:

> **Crie-o somente para a janela de instalação/reconstrução, configure TTL de no máximo 2 dias e revogue-o assim que o Terraform e as validações terminarem. Não reutilize esse token como credencial permanente.**

No Cloudflare Dashboard, crie um **Custom API Token** e restrinja os recursos ao account e à zone usados pelo homelab. Para o escopo atualmente gerenciado pelo projeto, conceda:

```text
Account permissions
  Cloudflare Tunnel              Edit/Write
  Access: Apps and Policies      Edit/Write
  Access: Service Tokens         Edit/Write

Zone permissions
  DNS                            Edit/Write

Account resources
  Include -> somente o account do homelab

Zone resources
  Include -> somente guiosoft.info

TTL
  início -> momento do bootstrap
  expiração -> no máximo 2 dias depois
```

A nomenclatura `Edit`/`Write` pode variar conforme a versão da UI/API da Cloudflare; a intenção é conceder capacidade de leitura e escrita para esses quatro grupos durante o bootstrap.

Se o bootstrap for executado a partir de um endereço público estável, também é recomendável restringir o token por **Client IP Address Filtering**. Não faça essa restrição quando o IP de saída puder mudar durante a recuperação, pois isso pode bloquear o próprio procedimento de DR.

Depois de criar o token, mantenha-o apenas na sessão de shell:

```bash
export CLOUDFLARE_API_TOKEN='...'
```

Antes do Terraform, valide a credencial sem imprimir o segredo:

```bash
test -n "${CLOUDFLARE_API_TOKEN:-}" || {
  echo "CLOUDFLARE_API_TOKEN não definido" >&2
  exit 1
}

curl -fsS \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  https://api.cloudflare.com/client/v4/user/tokens/verify
```

Então execute normalmente `terraform init`, `terraform plan` e, somente depois de revisar o plano, `terraform apply`.

Ao final da reconstrução:

1. valide Tunnel, DNS e aplicações Access;
2. valide os clientes protegidos, como Hermes/OpenCode no Firecrawl;
3. remova a variável da sessão com `unset CLOUDFLARE_API_TOKEN`;
4. revogue/delete o API Token temporário no Cloudflare Dashboard, mesmo que ainda reste tempo no TTL.

O TTL de 2 dias é uma **proteção adicional**, não substitui a revogação explícita após o trabalho.

Essa política aplica-se ao **API Token de IaC/bootstrap**. Ela não altera o token de execução de um Tunnel remotamente gerenciado nem os Cloudflare Access Service Tokens usados pelos agentes; são credenciais com finalidades e ciclos de vida diferentes.

### Estado Terraform passa a ser sensível

Os recursos `cloudflare_zero_trust_access_service_token` retornam o `client_secret` somente no fluxo de criação/rotação. Embora os outputs correspondentes sejam marcados como `sensitive`, os valores continuam fazendo parte do Terraform state.

Consequências:

- nunca versionar `terraform.tfstate`, backups de state ou planos que possam conter valores sensíveis;
- manter o state local com permissões restritas;
- tratar qualquer cópia/backup desse state como segredo;
- usar um Service Token diferente para cada consumidor, permitindo revogação/rotação independente.

## Preparação

```bash
cd terraform/cloudflare
cp terraform.tfvars.example terraform.tfvars
```

Preencha no arquivo local:

- `cloudflare_account_id`;
- `cloudflare_zone_id`;
- `cloudflare_tunnel_id`;
- `cloudflare_tunnel_name`;
- `cloudflare_wildcard_record_id`.

O ID do registro DNS é o ID do recurso na API, não o hostname.

## Regra principal de migração

**Nunca execute `terraform apply` antes de importar os recursos existentes e revisar um `terraform plan`.**

Terraform deve primeiro aprender que os recursos declarados correspondem aos recursos que já existem.

## Inicialização

```bash
terraform init
terraform fmt -check
terraform validate
```

## Import do Tunnel existente

```bash
terraform import \
  cloudflare_zero_trust_tunnel_cloudflared.homelab \
  "${CLOUDFLARE_ACCOUNT_ID}/${CLOUDFLARE_TUNNEL_ID}"
```

Ou substitua as variáveis shell pelos valores locais presentes em `terraform.tfvars`.

## Import da configuração remota do Tunnel

```bash
terraform import \
  cloudflare_zero_trust_tunnel_cloudflared_config.homelab \
  "${CLOUDFLARE_ACCOUNT_ID}/${CLOUDFLARE_TUNNEL_ID}"
```

## Import do wildcard DNS

```bash
terraform import \
  cloudflare_dns_record.wildcard \
  "${CLOUDFLARE_ZONE_ID}/${CLOUDFLARE_WILDCARD_RECORD_ID}"
```

## Validação

Depois dos três imports:

```bash
terraform plan
```

O objetivo inicial é chegar a **zero mudanças inesperadas** para os recursos já importados.

Se o plano mostrar alteração de nome do Tunnel, configuração de ingress, conteúdo do wildcard, proxy ou TTL, não aplique. Ajuste primeiro a configuração Terraform para refletir o estado real desejado.

Os recursos existentes possuem `prevent_destroy = true` como proteção adicional contra destruição acidental nesta fase.

## Firecrawl: autenticação machine-to-machine

O Firecrawl é consumido pelos agentes Hermes e OpenCode, sem necessidade de login humano. O desenho adotado é:

```text
Hermes   -- Service Token próprio --\
                                     +--> Cloudflare Access --> Tunnel --> Traefik --> Firecrawl
OpenCode -- Service Token próprio --/
```

`terraform/cloudflare/access-firecrawl.tf` cria:

- aplicação Access `Firecrawl Agents` para `firecrawl.guiosoft.info`;
- policy inline de Service Auth usando `decision = "non_identity"`;
- Service Token `firecrawl-hermes`;
- Service Token `firecrawl-opencode`.

Na UI/documentação do Cloudflare, essa ação é apresentada como **Service Auth**. No provider/API atuais, o valor correto da decisão é `non_identity`; `service_auth` não é um valor válido no schema do provider v5.24.

Os tokens usam validade explícita de 1 ano (`8760h`). A aplicação responde com HTTP 401 quando uma requisição protegida não satisfaz a policy Service Auth.

Clientes autorizados devem enviar os headers padrão:

```http
CF-Access-Client-Id: <client-id>
CF-Access-Client-Secret: <client-secret>
```

O header `Authorization` permanece livre para futura autenticação nativa do Firecrawl.

### Aplicação e captura inicial das credenciais

Primeiro revise:

```bash
terraform fmt -check
terraform validate
terraform plan
```

O plano esperado deve adicionar somente a aplicação Access e os dois Service Tokens, sem alterar Tunnel/DNS existentes.

Depois de revisar explicitamente o plano:

```bash
terraform apply
```

Capture cada credencial diretamente do state/output local, sem colar em Git ou documentação:

```bash
terraform output -raw firecrawl_hermes_client_id
terraform output -raw firecrawl_hermes_client_secret
terraform output -raw firecrawl_opencode_client_id
terraform output -raw firecrawl_opencode_client_secret
```

Os secrets devem então ser configurados somente nos runtimes de Hermes/OpenCode.

### Critério de validação

Depois do apply:

1. request público sem Service Token deve ser bloqueado pelo Access (HTTP 401 esperado);
2. request com o token do Hermes deve conseguir executar `POST /v1/scrape`;
3. request com o token do OpenCode deve conseguir executar `POST /v1/scrape`;
4. nenhum secret deve aparecer no Git ou nos logs de automação.

O warning interno do Firecrawl `You're bypassing authentication` continuará esperado enquanto `USE_DB_AUTHENTICATION=false`: a decisão arquitetural é confiar na autenticação feita pela borda Cloudflare para este perfil.

## Próximos recursos

Outros registros DNS específicos podem ser importados individualmente. Não devemos importar toda a zona de uma vez; a migração continuará incremental para manter rollback simples.

## Fontes

- Cloudflare API Tokens / criação, TTL e Client IP filtering: https://developers.cloudflare.com/fundamentals/api/get-started/create-token/
- Cloudflare API token permissions: https://developers.cloudflare.com/fundamentals/api/reference/permissions/
- Cloudflare Tunnel via API / permissões: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel-api/
- Cloudflare Tunnel tokens e permissões: https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/
- Cloudflare Terraform Provider v5.24: https://developers.cloudflare.com/api/terraform/
- Cloudflare Access common policies / Service Auth (`decision = "non_identity"`): https://developers.cloudflare.com/cloudflare-one/access-controls/policies/common-policies/
- Cloudflare Access Service Tokens: https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/
- Cloudflare provider `cloudflare_zero_trust_access_service_token`: https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_service_token
- Cloudflare provider `cloudflare_zero_trust_access_application`: https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/resources/zero_trust_access_application
- Migração provider v5 / policies inline: https://registry.terraform.io/providers/cloudflare/cloudflare/latest/docs/guides/version-5-migration
