# Backup and restore

## Escopo atual

O cluster atual é single-node e usa o datastore SQLite padrão do K3s. Nesta fase, o objetivo é estabelecer primeiro um backup local verificável do estado do cluster antes de adicionar retenção automática, cópia off-host ou testes destrutivos de restore.

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
8. cria SHA-256 do arquivo;
9. valida a leitura do tar e o checksum antes de reportar sucesso.

Execute:

```bash
make backup-create
make backup-list
```

O arquivo de backup contém o server token e portanto deve ser tratado como secret. Ele nunca deve ser adicionado ao Git.

## O que este backup ainda não resolve

Esse backup cobre o datastore de controle do K3s. Ele **não** substitui backups dos dados das aplicações.

PVCs, bancos de dados, uploads e outros dados persistentes precisam de políticas próprias. Para bancos de dados, a preferência será por backups nativos/lógicos consistentes com o mecanismo usado por cada workload, em vez de simplesmente arquivar arquivos de banco em execução.

Também permanecem pendentes:

- retenção automatizada;
- execução agendada;
- cópia off-host;
- proteção/criptografia do destino off-host;
- validação real de restore do K3s;
- restore de dados de aplicações.

## Política de evolução

A sequência adotada é:

```text
backup manual verificável
    ↓
restore testado
    ↓
automação/agendamento
    ↓
retenção
    ↓
off-host
    ↓
testes periódicos de restore
```

Não habilitaremos remoção automática de backups antigos antes de termos confirmado o fluxo de criação e restauração.

## Futuro multi-node

O script atual aborta quando encontra embedded etcd. Quando o laboratório evoluir para múltiplos servidores K3s, a estratégia deverá mudar para `k3s etcd-snapshot` e seguir o fluxo de snapshot/restore do datastore embedded etcd.

## Fontes

- K3s — Backup and Restore: https://docs.k3s.io/datastore/backup-restore
- K3s — Cluster Datastore: https://docs.k3s.io/datastore
- K3s — High Availability Embedded etcd: https://docs.k3s.io/datastore/ha-embedded
