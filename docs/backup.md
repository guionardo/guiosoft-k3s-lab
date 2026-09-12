# Backup and restore

## Escopo atual

O cluster atual é single-node e usa o datastore SQLite padrão do K3s. A estratégia desta fase cobre o backup do estado do control plane e do server token, com validação de integridade, agendamento via systemd e retenção local conservadora.

O staging local usa:

```text
/srv/k3s/backups/k3s
```

que aponta para o disco físico de backup local já reservado no layout de storage.

## O que precisa ser preservado

Para K3s com SQLite, a documentação oficial orienta copiar o diretório:

```text
/var/lib/rancher/k3s/server/db/
```

Além do datastore, o token do servidor também deve ser preservado:

```text
/var/lib/rancher/k3s/server/token
```

O mesmo token é necessário no restore porque ele participa da proteção de dados confidenciais mantidos no datastore.

## Backup local

O script:

```text
scripts/k3s-backup.sh
```

é deliberadamente conservador. Ele:

1. exige execução como root;
2. confirma a presença de `server/db/state.db`;
3. aborta se detectar embedded etcd;
4. recusa continuar se não encontrar o server token;
5. copia o diretório do datastore e o token para staging temporário;
6. gera um arquivo `metadata.txt` sem secrets;
7. cria um `tar.gz` protegido com modo `0600`;
8. cria SHA-256 portátil, referenciando apenas o nome do arquivo para continuar válido após cópia off-host;
9. valida a leitura do tar e o checksum antes de reportar sucesso.

Execute manualmente:

```bash
make backup-create
make backup-list
```

O arquivo de backup contém o server token e portanto deve ser tratado como secret. Ele nunca deve ser adicionado ao Git.

## Restore rehearsal não destrutivo

O fluxo foi validado no host com:

```bash
make backup-verify
```

Por padrão ele seleciona o backup local mais recente. Também é possível informar um arquivo específico:

```bash
make backup-verify FILE=/srv/k3s/backups/k3s/k3s-host-TIMESTAMP.tar.gz
```

O script `scripts/k3s-backup-verify.sh`:

1. valida o SHA-256 sem depender do caminho original do backup;
2. extrai o arquivo em um diretório temporário isolado;
3. confirma `server/db/state.db`;
4. confirma que não há embedded etcd inesperado;
5. confirma a presença de um server token não vazio;
6. valida `metadata.txt` como `datastore=sqlite`;
7. abre a cópia restaurada do SQLite em modo somente leitura;
8. executa `PRAGMA integrity_check` e exige resultado `ok`;
9. remove o staging temporário automaticamente.

Esse teste **não modifica** `/var/lib/rancher/k3s`, não para o serviço K3s e não substitui o teste completo de disaster recovery. Ele prova que o artefato pode ser reidratado, que o token necessário está presente e que a cópia SQLite restaurada é estruturalmente íntegra.

## Agendamento via systemd

O agendamento foi instalado e validado no host com:

```bash
make backup-install
make backup-status
make backup-run
```

O playbook `ansible/playbooks/backup.yml` instala o role `backup`, que:

- valida que o disco de backup continua montado antes de configurar qualquer automação;
- instala os scripts em `/usr/local/sbin`;
- cria `k3s-backup.service` como `oneshot`;
- cria e habilita `k3s-backup.timer`;
- executa o prune somente depois de um backup ter sido criado com sucesso;
- mantém o diretório de backup em modo `0700`.

A política padrão está em `ansible/inventory/group_vars/all.yml`:

```yaml
k3s_backup_dir: /srv/k3s/backups/k3s
k3s_backup_keep: 14
k3s_backup_on_calendar: "*-*-* 03:15:00"
k3s_backup_randomized_delay: 15m
```

O horário segue o timezone local do servidor. `Persistent=true` faz o systemd executar uma ocorrência perdida após o host voltar a ficar disponível. O atraso aleatório reduz a necessidade de um horário rígido e evita concentrar futuras rotinas exatamente no mesmo minuto.

## Retenção local

O script `scripts/k3s-backup-prune.sh` mantém, por padrão, os 14 archives mais recentes.

A retenção possui proteções intencionais:

- exige execução como root;
- exige `K3S_BACKUP_KEEP >= 2`;
- ordena os archives por data de modificação;
- remove archive e checksum como um par;
- **não remove** um archive antigo que esteja sem seu `.sha256`, deixando-o para inspeção manual.

A existência de retenção local não transforma `/srv/k3s/backups` em backup definitivo: o disco continua no mesmo servidor físico.

## Preparação para backup off-host com restic

O próximo nível de proteção usa `restic` como camada de transporte, criptografia e retenção no destino externo. O role Ansible `restic` instala a ferramenta junto com `make tools`.

Antes de configurar qualquer destino externo, existe um smoke test totalmente local:

```bash
make tools
make restic-test
```

O `scripts/restic-smoke-test.sh` cria um repositório temporário, gera uma senha aleatória descartável, envia o backup K3s mais recente para esse repositório, executa `restic check`, restaura o snapshot e compara o archive restaurado byte a byte com o original. Todo o repositório temporário e a senha são removidos ao final.

Esse teste não é backup off-host. Ele apenas valida que a cadeia restic funciona corretamente no servidor antes de introduzir credenciais ou um destino externo.

O restic suporta, entre outros backends, repositórios SFTP. Para automação, a documentação recomenda fornecer o repositório por `RESTIC_REPOSITORY`/`RESTIC_REPOSITORY_FILE` e a senha por `RESTIC_PASSWORD_FILE` ou mecanismo equivalente, evitando colocar a senha diretamente na linha de comando.

O destino off-host ainda precisa ser escolhido. Critérios mínimos:

- estar fisicamente fora deste servidor;
- usar criptografia do próprio restic;
- credenciais fora do Git e com permissões restritas;
- permitir restore independente do disco local de `/mnt/store2`;
- ter retenção e `restic check` periódicos;
- ser validado com um restore real de pelo menos um archive K3s.

## Restore real do K3s

O restore completo do SQLite exige restaurar o conteúdo de `server/db/` e o mesmo server token. Como isso altera o estado ativo do control plane, o teste deve ser executado em uma janela explícita de disaster recovery, idealmente em um host limpo ou após termos uma forma segura de reconstruir o servidor.

Não automatizamos ainda essa substituição do datastore no host ativo.

## O que este backup ainda não resolve

Esse backup cobre o datastore de controle do K3s. Ele **não** substitui backups dos dados das aplicações.

PVCs, bancos de dados, uploads e outros dados persistentes precisam de políticas próprias. Para bancos de dados, a preferência será por backups nativos/lógicos consistentes com o mecanismo usado por cada workload, em vez de simplesmente arquivar arquivos de banco em execução.

Também permanecem pendentes:

- destino off-host real;
- credenciais do backend protegidas com SOPS/age ou arquivos root-only;
- retenção remota;
- restore completo do K3s em ambiente reconstruído;
- restore de dados de aplicações;
- testes periódicos de restore completo.

## Política de evolução

A sequência adotada é:

```text
backup manual verificável
    ↓
restore rehearsal não destrutivo
    ↓
agendamento systemd
    ↓
retenção local
    ↓
restic local round-trip
    ↓
restic off-host
    ↓
restore completo em ambiente reconstruído
    ↓
testes periódicos de restore
```

## Futuro multi-node

O script atual aborta quando encontra embedded etcd. Quando o laboratório evoluir para múltiplos servidores K3s, a estratégia deverá mudar para `k3s etcd-snapshot` e seguir o fluxo de snapshot/restore do datastore embedded etcd.

## Fontes

- K3s — Backup and Restore: https://docs.k3s.io/datastore/backup-restore
- K3s — Cluster Datastore: https://docs.k3s.io/datastore
- K3s — High Availability Embedded etcd: https://docs.k3s.io/datastore/ha-embedded
- restic — Preparing a new repository: https://restic.readthedocs.io/en/latest/030_preparing_a_new_repo.html
- restic — Installation: https://restic.readthedocs.io/en/latest/020_installation.html
- systemd.timer — https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html
