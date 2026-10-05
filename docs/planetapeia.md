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
- Validar: `make secret-validate FILE=...`; reconciliar: `make planetapeia-...` → `kubectl annotate gitrepository flux-system -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite`.

## Backup e restore

- Backup manual (imediato):
  `kubectl -n planetapeia create job --from=cronjob/planetapeia-db-backup planetapeia-db-backup-manual`
- Listar: `kubectl -n planetapeia exec planetapeia-db-0 -- ls -lh /backups` (via pod de backup: `kubectl -n planetapeia run backups-view --rm -it --image=mariadb:11.8 --overrides='{"spec":{"containers":[{"name":"c","image":"mariadb:11.8","command":["ls","-lh","/backups"],"volumeMounts":[{"name":"b","mountPath":"/backups"}]}],"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"planetapeia-backups"}}]}}'`)
- Restore (a partir de um dump):
  ```bash
  kubectl -n planetapeia exec -i planetapeia-db-0 -- sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot planetapeia' < dump.sql
  ```

## Cutover e rollback

- Cutover: trocar o host do Ingress para `planetapeia.guiosoft.info`, aplicar `redirect 301` no cPanel e validar smoke.
- Rollback: remover o redirect do cPanel (o Render continua intacto durante a janela de observação).

## Troubleshooting

- `kubectl -n planetapeia get pods,svc,ingress`; logs: `kubectl -n planetapeia logs deploy/planetapeia-api`.
- Teste local do Ingress: `curl -H 'Host: planetapeia-preview.guiosoft.info' http://192.168.88.9/api/healthz`.
- ImagePullBackOff: verificar `ghcr-pull` e o PAT.
- PVC `planetapeia-backups` fica `Pending` (WaitForFirstConsumer) até o primeiro job às 03:15; a Kustomization `planetapeia` usa `healthCheckExprs` para aguardar apenas falha real (`Lost`), sem bloquear o health check.
