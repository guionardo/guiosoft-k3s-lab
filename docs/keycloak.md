# Keycloak — OIDC broker

## Visão

- Namespace `keycloak`; Flux reconcilia `kubernetes/apps/keycloak` (cadeia: namespace → secrets → keycloak).
- Hostname: `auth.guiosoft.info` (LAN-only, HTTPS via cert mkcert, pinado ao entrypoint `websecure`).
- Banco: PostgreSQL 16 (`keycloak-postgres`, PVC `keycloak-postgres-data` de 5Gi, `local-path`).
- Imagem: `quay.io/keycloak/keycloak:26.0.7`.
- Realm: `guiosoft` (issuer: `https://auth.guiosoft.info/realms/guiosoft`).
- IdP upstream: Google (identity brokering).
- Clientes: `ariadne-explorer` (public, PKCE S256), `ariadne-cli` (public, PKCE S256 + device code), `ariadne-api` (bearer-only).

## Segredos

Os segredos são cifrados com SOPS + age e vivem em `kubernetes/secrets/keycloak/`:

| Arquivo | Conteúdo | No kustomization? |
|---|---|---|
| `keycloak-secrets.sops.yaml` | Credenciais de DB e admin (POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB, KC_BOOTSTRAP_ADMIN_USERNAME, KC_BOOTSTRAP_ADMIN_PASSWORD) | Sim |
| `keycloak-google-idp.sops.yaml` | Credenciais do Google OAuth (client_id, client_secret) | Não (backup/recovery only) |

O secret `auth-tls` (certificado mkcert) é aplicado via kubectl e não está no git (como `registry-tls`).

### Obter credenciais

```bash
# Admin password
ssh guionardo@192.168.88.9 'cd ~/guiosoft-k3s-lab && sops --decrypt kubernetes/secrets/keycloak/keycloak-secrets.sops.yaml' | grep KC_BOOTSTRAP_ADMIN_PASSWORD

# Google client secret
ssh guionardo@192.168.88.9 'cd ~/guiosoft-k3s-lab && sops --decrypt kubernetes/secrets/keycloak/keycloak-google-idp.sops.yaml' | grep google-client-secret
```

### Rotação de segredos

**Admin password:**
1. Gere nova senha: `openssl rand -hex 16`
2. Atualize o secret SOPS no host (re-cripte com sops) — mantém a senha sincronizada para disaster recovery
3. Aplique o secret: `kubectl apply -f <decrypted-secret>`
4. Obtenha token com a senha **antiga** (ainda funciona): `curl ... -d "password=<senha-antiga>"`
5. Obtenha o UUID do admin: `GET /admin/realms/master/users?username=admin&exact=true`
6. Atualize a senha via Admin API: `PUT /admin/realms/master/users/{uuid}/reset-password` com `{"type":"password","value":"<nova-senha>","temporary":false}`
7. Verifique: login com a nova senha deve funcionar; a senha antiga deve ser rejeitada

> **Nota**: o `KC_BOOTSTRAP_ADMIN_PASSWORD` só é usado na **primeira inicialização** (quando o usuário admin não existe). Após isso, a rotação é feita via Admin API. O secret SOPS mantém a senha sincronizada para recovery.

**Google client secret:**
1. Gere novo secret no Google Cloud Console
2. Atualize no Keycloak Admin Console: Identity Providers → google → Client Secret
3. Atualize o backup SOPS: `keycloak-google-idp.sops.yaml`
4. Commit e push

## Backup

### PostgreSQL (estado do Keycloak)

```bash
# Dump do banco
kubectl -n keycloak exec deploy/keycloak-postgres -- \
  pg_dump -U keycloak keycloak > keycloak-backup-$(date +%Y%m%d).sql

# Ou via port-forward (se preferir rodar do host)
kubectl -n keycloak port-forward svc/keycloak-postgres 5432:5432 &
pg_dump -h localhost -U keycloak keycloak > keycloak-backup-$(date +%Y%m%d).sql
```

### Export de realm (configuração)

```bash
# Via Keycloak Admin API (requer token)
TOKEN=$(curl -sk -X POST https://auth.guiosoft.info/realms/master/protocol/openid-connect/token \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=<ADMIN_PW>" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

curl -sk -H "Authorization: Bearer $TOKEN" \
  https://auth.guiosoft.info/admin/realms/guiosoft \
  -o gui osft-realm-$(date +%Y%m%d).json
```

### O que incluir no backup

- Dump do PostgreSQL (estado completo: usuários, sessões, configuração)
- Export do realm (configuração declarativa, sem segredos)
- Backup do secret SOPS (credenciais cifradas)
- Certificado TLS (mkcert: `registry.guiosoft.info.pem` + `-key.pem`)

## Restore

### PostgreSQL

```bash
# Restaurar dump
kubectl -n keycloak exec -i deploy/keycloak-postgres -- \
  psql -U keycloak keycloak < keycloak-backup-YYYYMMDD.sql
```

### Realm

```bash
# Importar realm via Admin API
curl -sk -X POST https://auth.guiosoft.info/admin/realms \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @guiosft-realm-YYYYMMDD.json
```

### Verificação pós-restore

```bash
# Verificar issuer
curl -sk https://auth.guiosoft.info/realms/guiosoft/.well-known/openid-configuration | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])'

# Verificar admin console
curl -sk -o /dev/null -w '%{http_code}\n' https://auth.guiosoft.info/admin/master/console/
```

## Adicionar novo provedor de identidade

Para adicionar um novo IdP (ex.: GitHub, Microsoft) sem alterar o Ariadne:

1. **No provedor externo**: criar OAuth app, obter client_id e client_secret, registrar redirect URI: `https://auth.guiosoft.info/realms/guiosoft/broker/<alias>/endpoint`

2. **No Keycloak Admin Console** (ou via API):
   - Identity Providers → Add provider → selecionar o tipo
   - Configurar clientId, clientSecret, scopes
   - Habilitar `trustEmail: true` (se o provedor for confiável)
   - Definir `firstBrokerLoginFlowAlias: first broker login`

3. **Armazenar credenciais** no SOPS (backup, não no kustomization):
   ```bash
   # Criar secret SOPS no host
   ssh guionardo@192.168.88.9 'cd ~/guiosoft-k3s-lab && ...'
   ```

4. **Mappers**: se o novo provedor enviar claims diferentes, adicionar mappers no realm ou no cliente.

5. **Testar**: login com o novo provedor, verificar token (issuer, audience, claims).

O Ariadne não precisa mudar — ele valida tokens contra o issuer do Keycloak, não contra o provedor upstream.

## Verificação de saúde

```bash
# Pod status
kubectl -n keycloak get pods

# Health endpoints (porta 9000/management)
kubectl -n keycloak port-forward svc/keycloak 9000:9000 &
curl -s http://localhost:9000/health/ready
curl -s http://localhost:9000/health/live
curl -s http://localhost:9000/metrics | head

# Issuer
curl -sk https://auth.guiosoft.info/realms/guiosoft/.well-known/openid-configuration | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])'

# Admin console
curl -sk -o /dev/null -w '%{http_code}\n' https://auth.guiosoft.info/admin/master/console/
```

## Troubleshooting

- **Profile page não carrega**: verificar se `KC_PROXY_HEADERS=xforwarded` está configurado (não `KC_PROXY=edge`, que é deprecated). Verificar se o Traefik envia `X-Forwarded-Proto: https`.
- **Issuer retorna HTTP em vez de HTTPS**: `KC_HOSTNAME` deve ser a URL completa (`https://auth.guiosoft.info`), não apenas o hostname.
- **Admin user temporário**: usar `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` (não os deprecated `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`).
- **403 no login-status-iframe**: geralmente relacionado ao proxy/forwarded headers. Verificar `KC_PROXY_HEADERS=xforwarded`.
- **Pod não fica ready**: health probe na porta 9000 (management), não 8080. Verificar se `KC_HEALTH_ENABLED=true`.
- **Banco não conecta**: verificar secret `keycloak-secrets` (POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB) e se o postgres está ready.