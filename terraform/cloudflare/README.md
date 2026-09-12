# Cloudflare com Terraform

Esta pasta coloca gradualmente o estado já existente da Cloudflare sob Terraform sem recriar recursos em produção.

## Recursos inicialmente declarados

- Cloudflare Tunnel existente;
- configuração remota do Tunnel;
- wildcard DNS `*.guiosoft.info` apontando para o Tunnel.

A configuração do Tunnel preserva o fluxo validado:

```text
cockpit.guiosoft.info -> http://localhost:9090
*.guiosoft.info       -> http://127.0.0.1:80
fallback               -> http_status:404
```

## Segurança

Nunca grave o API token em `.tf`, `.tfvars` ou no repositório. Exporte-o somente no ambiente:

```bash
export CLOUDFLARE_API_TOKEN='...'
```

O token usado para import/plan deve ter somente as permissões necessárias para os recursos administrados, especialmente DNS e Cloudflare Tunnel.

`terraform.tfvars`, state e diretórios `.terraform` já são ignorados pelo `.gitignore` do repositório.

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

O objetivo inicial é chegar a **zero mudanças inesperadas**.

Se o plano mostrar alteração de nome do Tunnel, configuração de ingress, conteúdo do wildcard, proxy ou TTL, não aplique. Ajuste primeiro a configuração Terraform para refletir o estado real desejado.

Os recursos possuem `prevent_destroy = true` como proteção adicional contra destruição acidental nesta fase.

## Próximos recursos

Depois que o primeiro `plan` estiver estável, outros registros DNS específicos podem ser importados individualmente. Não devemos importar toda a zona de uma vez; a migração continuará incremental para manter rollback simples.
