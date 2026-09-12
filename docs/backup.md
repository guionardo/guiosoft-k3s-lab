# Backup and restore

## Escopo atual

O cluster atual é single-node e usa o datastore SQLite padrão do K3s. A estratégia desta fase cobre:

- backup local verificável do datastore e do server token;
- restore rehearsal não destrutivo;
- agendamento via systemd;
- retenção local;
- cópia off-host cifrada com Restic para Cloudflare R2;
- retenção remota gerenciada pelo próprio Restic.

O staging local usa:

```text
/srv/k3s/backups/k3s
```

que aponta para o disco físico de backup local já reservado no layout de storage.

## Backup local

Para K3s com SQLite, preservamos:

```text
/var/lib/rancher/k3s/server/db/
/var/lib/rancher/k3s/server/token
```

O script `scripts/k3s-backup.sh` exige root, confirma SQLite, aborta se detectar embedded etcd, inclui o server token, gera archive `0600`, cria SHA-256 portátil e valida tar + checksum antes de reportar sucesso.

Operações:

```bash
make backup-create
make backup-list
make backup-verify
```

O restore rehearsal foi validado no host. Ele extrai em staging temporário, verifica token, metadata, SHA-256 e executa `PRAGMA integrity_check` em modo somente leitura sem alterar o K3s ativo.

## Agendamento local

O role Ansible `backup` instala:

```text
/usr/local/sbin/k3s-backup
/usr/local/sbin/k3s-backup-prune
/usr/local/sbin/restic-r2-sync
/etc/systemd/system/k3s-backup.service
/etc/systemd/system/k3s-backup.timer
```

A política padrão é:

```yaml
k3s_backup_keep: 14
k3s_backup_on_calendar: "*-*-* 03:15:00"
k3s_backup_randomized_delay: 15m
```

O timer usa `Persistent=true` e já foi validado no host.

## Cloudflare R2 + Restic

O bucket R2 é criado por uma stack Terraform separada em `terraform/r2/`. A separação evita misturar permissões administrativas do R2 com a stack Cloudflare de DNS/Tunnel.

O bucket usado atualmente é:

```text
guiosoft-k3s-backups
```

O Restic usa o endpoint S3-compatible do R2. A credencial de runtime é `Object Read & Write`, restrita ao bucket.

As credenciais R2 e a senha do repositório Restic ficam em:

```text
secrets/restic-r2.sops.yaml
```

somente em formato SOPS + age. O plaintext runtime é instalado como `root:root` e `0600` em:

```text
/etc/k3s-backup/restic.repository
/etc/k3s-backup/restic.password
/etc/k3s-backup/r2.env
```

Fluxo operacional:

```bash
make restic-r2-secret
make restic-r2-install
make restic-r2-test
```

O round-trip real Restic -> R2 -> restore foi validado com comparação SHA-256 byte a byte.

## Automação off-host

`scripts/restic-r2-sync.sh` é chamado pelo mesmo `k3s-backup.service` depois do backup local e do prune local.

Sequência:

```text
k3s-backup.timer
      ↓
k3s-backup.service
      ↓
cria backup SQLite + token
      ↓
valida archive/checksum
      ↓
retém os 14 archives locais mais recentes
      ↓
Restic envia archive + .sha256 para Cloudflare R2
      ↓
Restic aplica retenção remota e prune
```

A retenção remota padrão é:

```yaml
restic_r2_keep_daily: 14
restic_r2_keep_weekly: 8
restic_r2_keep_monthly: 12
```

O prune remoto é feito pelo Restic, não por lifecycle arbitrário do bucket R2. Isso evita apagar objetos internos ainda referenciados por snapshots válidos.

Targets operacionais:

```bash
make restic-r2-sync
make restic-r2-status
make restic-r2-check
```

O target `make backup-install` agora exige que a configuração runtime do Restic R2 já esteja instalada quando `restic_r2_enabled: true`. Isso impede habilitar silenciosamente um timer que não conseguiria produzir backup off-host.

## Validação pendente desta etapa

A implementação já está pronta. Falta validar no host o fluxo completo usando exatamente o serviço agendado:

```bash
make backup-install
make backup-run
make restic-r2-status
make backup-status
```

Essa validação deve comprovar que uma única execução do `k3s-backup.service` cria o backup local e também produz o snapshot R2.

## Restore real do K3s

O restore completo do SQLite exige restaurar o conteúdo de `server/db/` e o mesmo server token. Como isso altera o estado ativo do control plane, o teste deve ser executado em uma janela explícita de disaster recovery, idealmente em um host limpo ou reconstruído.

Ainda não automatizamos uma substituição destrutiva do datastore no host ativo.

## Dados de aplicações

O backup atual cobre o control plane K3s. Ele não substitui backups próprios de:

- PVCs;
- bancos de dados;
- uploads;
- repositórios;
- outros dados persistentes de workloads.

Para bancos de dados, a preferência continua sendo backup nativo/lógico consistente com cada engine.

## Futuro multi-node

O script atual aborta quando encontra embedded etcd. Quando o laboratório evoluir para múltiplos servidores K3s, a estratégia deverá mudar para `k3s etcd-snapshot` e o fluxo oficial de snapshot/restore do embedded etcd.

## Fontes

- K3s — Backup and Restore: https://docs.k3s.io/datastore/backup-restore
- K3s — Cluster Datastore: https://docs.k3s.io/datastore
- K3s — High Availability Embedded etcd: https://docs.k3s.io/datastore/ha-embedded
- restic — Preparing a new repository: https://restic.readthedocs.io/en/latest/030_preparing_a_new_repo.html
- restic — Removing backup snapshots: https://restic.readthedocs.io/en/latest/060_forget.html
- Cloudflare R2 — S3-compatible API: https://developers.cloudflare.com/r2/api/s3/api/
- Cloudflare R2 — API tokens: https://developers.cloudflare.com/r2/api/tokens/
- systemd.timer — https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
