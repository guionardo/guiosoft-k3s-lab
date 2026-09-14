# Disaster recovery

## Objetivo

Provar que o laboratório pode ser reconstruído a partir de um Debian limpo usando somente:

1. o repositório Git;
2. a identidade privada `age` recuperada de uma cópia externa;
3. as credenciais R2 protegidas no Git com SOPS + age;
4. o backup do control plane armazenado no Cloudflare R2;
5. os backups específicos de aplicações, quando existirem.

O teste de disaster recovery deve ser executado em um host/VM separado. O servidor ativo não será usado como alvo de restore destrutivo.

## O que já está comprovado

No host atual já foram validados:

- instalação reproduzível de K3s por Ansible;
- storage local dedicado para novos PVCs;
- backup SQLite + server token;
- restore rehearsal não destrutivo com `PRAGMA integrity_check`;
- backup automático por systemd;
- retenção local;
- Restic sobre Cloudflare R2;
- retenção remota;
- `restic check`;
- restore R2 -> local com comparação SHA-256 byte a byte;
- readiness check de DR com todos os pré-requisitos atuais acessíveis;
- rehearsal isolado usando exclusivamente o snapshot remoto do R2 como fonte;
- bootstrap idempotente de `flux-system/sops-age` a partir da identidade age local, com segunda execução `changed=0` e `failed=0`.

Isso prova a qualidade e recuperabilidade do artefato de backup e que a identidade age recuperada pode ser reinjetada no Flux declarativamente. O passo que ainda falta é subir um K3s separado usando esse datastore restaurado.

## Dependências que não podem depender do servidor perdido

Uma recuperação real exige que os itens abaixo existam fora do host original:

- acesso ao repositório GitHub;
- identidade privada `age` usada pelo SOPS;
- acesso à conta Cloudflare/R2;
- arquivo SOPS cifrado com credenciais Restic/R2 versionado no Git;
- senha/segredo necessário para acessar o repositório Restic, recuperável via SOPS;
- documentação deste repositório.

A identidade privada `age` é especialmente crítica: o recipient público versionado no Git não permite descriptografar os secrets. A identidade privada precisa ter uma cópia externa independente e protegida.

## Backup independente da identidade age

O backup da identidade privada age **não deve depender do próprio SOPS**, nem das credenciais Restic que são recuperadas com essa mesma identidade. Isso criaria uma dependência circular no cenário de perda total do host.

O helper abaixo cria uma cópia cifrada com AES-256-CBC/PBKDF2 usando uma senha de DR independente:

```bash
AGE_BACKUP_DEST=/caminho/montado/off-host \
  bash scripts/age-identity-backup.sh
```

O destino deve ser explicitamente off-host, por exemplo um pendrive, disco removível ou filesystem de NAS montado no servidor. O script recusa destinos evidentemente locais sob `/home`, `/root`, `/tmp` e `/var`.

O fluxo é:

```text
~/.config/sops/age/keys.txt
        ↓
cópia temporária mode 0600
        ↓
AES-256-CBC + PBKDF2 (200000 iterações)
        ↓
arquivo .enc no destino off-host
        ↓
descriptografia temporária de verificação
        ↓
comparação SHA-256 com a identidade original
        ↓
checksum do arquivo cifrado
```

A senha usada para esse backup deve ser guardada independentemente do servidor, do Git, dos secrets SOPS e do repositório Restic. Não use a senha Restic como senha desse backup.

Também é possível fornecer a senha por arquivo local temporário fora do Git:

```bash
AGE_BACKUP_DEST=/mnt/nas/dr \
AGE_BACKUP_PASSPHRASE_FILE=/run/user/$UID/age-dr-passphrase \
  bash scripts/age-identity-backup.sh
```

O arquivo de senha não deve ser versionado nem armazenado junto ao backup cifrado.

### Rehearsal de restore da identidade age

O restore deve ser ensaiado para um caminho isolado, nunca sobrescrevendo a identidade ativa:

```bash
AGE_RESTORE_TARGET=/tmp/age-dr-test/keys.txt \
  bash scripts/age-identity-restore.sh /mnt/nas/dr/age-identity-HOST-TIMESTAMP.enc
```

O helper:

- valida primeiro o `.sha256` do backup cifrado;
- descriptografa para arquivo temporário protegido;
- exige que o resultado tenha formato de identidade age;
- recusa sobrescrever qualquer target já existente;
- instala o arquivo restaurado com mode `0600`.

Depois valide o recipient e um Secret SOPS conhecido:

```bash
age-keygen -y /tmp/age-dr-test/keys.txt
SOPS_AGE_KEY_FILE=/tmp/age-dr-test/keys.txt \
  sops -d kubernetes/secrets/cloudflare/cloudflared-token.sops.yaml >/dev/null
```

Somente depois de executar backup real em mídia/off-host e um restore isolado bem-sucedido a pendência de cópia externa da identidade age deve ser considerada concluída.

## Readiness check

Antes de preparar um ambiente destrutivo, execute no servidor atual:

```bash
make dr-readiness
```

O check é somente leitura. Ele valida ferramentas, checkout Git, artefatos IaC, descriptografia SOPS, configuração runtime, acesso ao R2, snapshot remoto, backup local e restore rehearsal.

Esse check já foi validado com sucesso no host atual.

## Rehearsal isolado a partir do R2

A etapa intermediária usa **somente o snapshot remoto** como fonte:

```bash
make dr-r2-rehearsal
```

O fluxo:

```text
Cloudflare R2 / Restic
        ↓
restore do snapshot k3s-control-plane
        ↓
staging temporário isolado
        ↓
archive + .sha256 restaurados
        ↓
SHA-256
        ↓
server token presente
        ↓
metadata SQLite
        ↓
PRAGMA integrity_check
        ↓
limpeza automática do staging
```

Esse fluxo já foi validado com sucesso. O script não usa os archives locais como fonte, não escreve em `/var/lib/rancher/k3s` e não altera o cluster.

## Exportar um artefato para o alvo de DR

Para transferir um backup verificado para uma VM/host separado:

```bash
make dr-r2-export DEST=/secure/dr-export
```

O target restaura o snapshot mais recente do R2 em staging temporário, executa o mesmo verificador usado nos rehearsals e só depois grava no destino informado:

```text
k3s-<host>-<timestamp>.tar.gz
k3s-<host>-<timestamp>.tar.gz.sha256
```

O archive contém o server token e deve ser tratado como secret. O target recusa exportar diretamente para `/var/lib/rancher/k3s`.

## Alvo isolado de rehearsal

O restore destrutivo foi implementado com múltiplas barreiras para impedir uso acidental no servidor ativo.

No host/VM de DR, após instalar o K3s de teste, execute:

```bash
make dr-target-init
```

Esse comando cria:

```text
/etc/guiosoft-k3s-lab/dr-rehearsal-target
```

Ele **recusa** marcar um host cujo hostname seja `guiosoft-info` ou que possua o IP de produção `192.168.88.9`.

Existe também um inventário de exemplo em:

```text
ansible/inventory/dr.example.yml
```

Copie-o para um inventário local não versionado e ajuste endereço, usuário e node name do alvo.

## Restore destrutivo somente no alvo marcado

Depois de copiar o par archive/checksum para o host isolado:

```bash
make dr-restore FILE=/secure/dr/k3s-guiosoft-info-TIMESTAMP.tar.gz
```

O target chama `scripts/dr-restore-k3s.sh`, que só continua quando todas estas condições são verdadeiras:

- execução como root;
- marker `dr-rehearsal-target` válido;
- hostname diferente do host de produção;
- IP de produção ausente;
- confirmação explícita `DR_RESTORE_CONFIRM=restore-isolated-k3s`;
- archive e `.sha256` presentes;
- restore rehearsal do archive aprovado;
- K3s instalado no alvo.

A sequência destrutiva é limitada ao host marcado:

```text
validar archive
    ↓
parar K3s
    ↓
preservar db/token atuais do alvo em dr-pre-restore-<timestamp>
    ↓
substituir server/db e server/token
    ↓
iniciar K3s
    ↓
aguardar /readyz
    ↓
mostrar nodes restaurados
```

O backup de segurança do estado inicial da VM é mantido sob o próprio `K3S_DATA_DIR`. Isso não é um rollback de produção; é apenas uma proteção adicional do ambiente descartável de rehearsal.

## Sequência do primeiro restore completo

```text
VM/host Debian isolado
   ↓
git clone guiosoft-k3s-lab
   ↓
restaurar identidade age fora do Git
   ↓
make ansible-deps
   ↓
bootstrap/tooling/K3s no alvo usando inventário DR
   ↓
recriar flux-system/sops-age via ansible/playbooks/flux-sops-age.yml
   ↓
make dr-target-init
   ↓
copiar archive + checksum exportados do R2
   ↓
make dr-restore FILE=...
   ↓
validar node, namespaces, Services, Ingress e objetos do cluster
```

Não execute `make dr-target-init` ou `make dr-restore` no servidor ativo.

## Critérios de sucesso do primeiro teste completo

O rehearsal será considerado aprovado quando, em um ambiente separado:

- o K3s iniciar com o datastore restaurado;
- `kubectl get nodes` responder normalmente;
- os objetos esperados do cluster reaparecerem;
- Traefik/CoreDNS/local-path estiverem saudáveis;
- o workload de laboratório puder ser validado;
- nenhuma dependência do disco raiz original tiver sido necessária;
- RTO e RPO observados forem registrados.

## Dados de aplicações

Atualmente o cluster possui PVCs da stack de observabilidade (Prometheus, Grafana e Tempo). O Firecrawl atual mantém PostgreSQL/NuQ, Redis e RabbitMQ deliberadamente efêmeros via `emptyDir`.

Cada workload stateful real precisa ser classificado e protegido separadamente:

- **file-oriented**: backup consistente do filesystem;
- **database**: dump/snapshot nativo da engine como fonte primária de restore;
- **external**: procedimento específico do provedor;
- **stateless/reproducible**: reconstruído por Git/IaC, sem backup de dados.

O restore do control plane K3s não substitui o restore desses dados.

## Segurança

Nunca versionar:

- identidade privada `age`;
- senha do backup independente da identidade age;
- credenciais R2 em plaintext;
- senha Restic em plaintext;
- server token extraído do backup;
- archives restaurados do K3s;
- kubeconfig real.

## Fontes

- K3s — Backup and Restore: https://docs.k3s.io/datastore/backup-restore
- K3s — Cluster Datastore: https://docs.k3s.io/datastore
- SOPS — age key management: https://getsops.io/docs/usage/key-management/
- OpenSSL `enc`: https://docs.openssl.org/master/man1/openssl-enc/
- Restic — Restoring from backup: https://restic.readthedocs.io/en/stable/050_restore.html
- Restic — Checking integrity: https://restic.readthedocs.io/en/stable/045_working_with_repos.html
