# Planetapéia no K3s

## Visão

- Namespace `planetapeia`; Flux reconcilia `kubernetes/apps/planetapeia` (cadeia: namespace → secrets → app).
- Hostnames: `planetapeia.guiosoft.info` (produção) e `planetapeia-preview.guiosoft.info` (validação pré-cutover).
- Banco: MariaDB 11.8 (StatefulSet `planetapeia-db`, PVC `data`, dump diário no PVC `planetapeia-backups`, retenção 14 dias).
- API: `planetapeia-api` (FastAPI, health `GET /healthz`), exposta em `/api` com `stripPrefix`.
- Web: `planetapeia-web` (nginx SPA).

## Imagens

- CI: `.github/workflows/build-push.yml` no repo `Planetapeia/planetapeia`.
- Tags: `ghcr.io/planetapeia/planetapeia-{api,web}:sha-<commit>` (privadas; pull via secret `ghcr-pull`).

### Bump de imagem

1. Merge do código no repo `planetapeia`; anote o sha do merge: `git rev-parse HEAD`.
2. Edite `kubernetes/apps/planetapeia/{api,web}.yaml` trocando `sha-<antigo>` por `sha-<novo>`.
3. `bash scripts/planetapeia.sh validate` → commit → merge na `main`.
4. Acompanhe: `kubectl -n planetapeia rollout status deploy/planetapeia-api` e `deploy/planetapeia-web`.

## Secrets

- `kubernetes/secrets/planetapeia/planetapeia-secrets.sops.yaml` e `ghcr-pull.sops.yaml`.
- Editar no nó (SOPS+age): `make secret-edit FILE=kubernetes/secrets/planetapeia/planetapeia-secrets.sops.yaml`.
- Validar: `make secret-validate FILE=...`; reconciliar: `kubectl -n flux-system annotate gitrepository flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`.

## Backup e restore

- Backup manual (imediato):
  `kubectl -n planetapeia create job --from=cronjob/planetapeia-db-backup planetapeia-db-backup-manual`
- Listar dumps (o PVC `planetapeia-backups` não é montado em `planetapeia-db-0`; use o pod auxiliar):

  ```bash
  kubectl -n planetapeia delete pod backups-read --ignore-not-found
  kubectl -n planetapeia run backups-read --restart=Never \
    --image=mariadb:11.8@sha256:6422478cb8e159f080fb1d8ccf65101e26fe51385787fde7d16c3b165a331f15 \
    --overrides='{"spec":{"containers":[{"name":"c","image":"mariadb:11.8@sha256:6422478cb8e159f080fb1d8ccf65101e26fe51385787fde7d16c3b165a331f15","command":["sleep","infinity"],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"planetapeia-backups"}}]}}'
  kubectl -n planetapeia wait --for=condition=Ready pod/backups-read --timeout=60s
  kubectl -n planetapeia exec backups-read -- ls -lh /backups
  kubectl -n planetapeia delete pod backups-read --ignore-not-found
  ```
- Semanal: conferir `kubectl -n planetapeia get cronjob planetapeia-db-backup -o jsonpath='{.status.lastSuccessfulTime}'` (não há alerta de falha de backup).
- Restore (a partir de um dump):
  ```bash
  kubectl -n planetapeia exec -i planetapeia-db-0 -- sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot planetapeia' < dump.sql
  ```

### Drill de restore (antes do cutover)

1. Dispara o job manual (removendo uma execução anterior, se houver): `kubectl -n planetapeia delete job planetapeia-db-backup-drill --ignore-not-found && kubectl -n planetapeia create job --from=cronjob/planetapeia-db-backup planetapeia-db-backup-drill`
2. Aguarda: `kubectl -n planetapeia wait --for=condition=complete job/planetapeia-db-backup-drill --timeout=180s`
3. Extrai o dump mais recente com pod persistente (NUNCA use `kubectl run --rm -i ... > arquivo`: o attach corre com o fim do pod e corrompe o stream mesmo com exit 0):

   ```bash
   kubectl -n planetapeia delete pod backups-read --ignore-not-found
   kubectl -n planetapeia run backups-read --restart=Never \
     --image=mariadb:11.8@sha256:6422478cb8e159f080fb1d8ccf65101e26fe51385787fde7d16c3b165a331f15 \
     --overrides='{"spec":{"containers":[{"name":"c","image":"mariadb:11.8@sha256:6422478cb8e159f080fb1d8ccf65101e26fe51385787fde7d16c3b165a331f15","command":["sleep","infinity"],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"planetapeia-backups"}}]}}'
   kubectl -n planetapeia wait --for=condition=Ready pod/backups-read --timeout=60s
   DUMP=$(kubectl -n planetapeia exec backups-read -- sh -c 'ls -t /backups/planetapeia-*.sql.gz | head -1')
   kubectl -n planetapeia exec backups-read -- cat "$DUMP" > /tmp/planetapeia-drill.sql.gz
   kubectl -n planetapeia delete pod backups-read --ignore-not-found
   gzip -t /tmp/planetapeia-drill.sql.gz && echo GZIP_OK
   ```
4. Restaura no banco de rascunho e confere a contagem:

   ```bash
   kubectl -n planetapeia exec planetapeia-db-0 -- sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -e "DROP DATABASE IF EXISTS planetapeia_drill; CREATE DATABASE planetapeia_drill CHARACTER SET utf8mb4"'
   gzip -dc /tmp/planetapeia-drill.sql.gz | kubectl -n planetapeia exec -i planetapeia-db-0 -- sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot planetapeia_drill'
   LIVE=$(kubectl -n planetapeia exec planetapeia-db-0 -- sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -N -e "SELECT COUNT(*) FROM planetapeia.participants"')
   DRILL=$(kubectl -n planetapeia exec planetapeia-db-0 -- sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -N -e "SELECT COUNT(*) FROM planetapeia_drill.participants"')
   [ "$LIVE" = "$DRILL" ] && echo "DRILL_OK ($DRILL)" || echo "DIVERGENCIA: live=$LIVE drill=$DRILL"
   kubectl -n planetapeia exec planetapeia-db-0 -- sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -e "DROP DATABASE planetapeia_drill"'
   rm -f /tmp/planetapeia-drill.sql.gz
   ```

## Agente de impressão

- Download: `planetapeia-print-agent.exe` da release `agent-v0.1.1` (GitHub releases do repo `Planetapeia/planetapeia`).
- Executar na máquina do check-in (Windows). O SmartScreen pode alertar (binário sem assinatura): "Mais informações" → "Executar assim mesmo"; considere adicionar ao autostart.
- Verificar: `curl http://127.0.0.1:17890/health` → `{"status":"ok"}`.
- **UAT antes do cutover:** executar com `PLANETAPEIA_PRINT_ORIGIN=https://planetapeia-preview.guiosoft.info` (o default permite só o host de produção):

  ```powershell
  $env:PLANETAPEIA_PRINT_ORIGIN="https://planetapeia-preview.guiosoft.info"; .\planetapeia-print-agent.exe
  ```
- Check-in: navegador em `https://planetapeia-preview.guiosoft.info/admin/checkin` (liberar uma data no preview antes, pois o dump restaurado não tem data liberada).

## Cutover e rollback

- Cutover: trocar o host do Ingress para `planetapeia.guiosoft.info`, aplicar `redirect 301` no cPanel e validar smoke.
- Rollback: remover o redirect do cPanel (o Render continua intacto durante a janela de observação).

## Troubleshooting

- `kubectl -n planetapeia get pods,svc,ingress`; logs: `kubectl -n planetapeia logs deploy/planetapeia-api`.
- Teste local do Ingress: `curl -H 'Host: planetapeia-preview.guiosoft.info' http://192.168.88.9/api/healthz`.
- ImagePullBackOff: verificar `ghcr-pull` e o PAT.
- PVC `planetapeia-backups` fica `Pending` (WaitForFirstConsumer) até o primeiro job às 03:15; a Kustomization `planetapeia` usa `healthCheckExprs` para aguardar apenas falha real (`Lost`), sem bloquear o health check.
