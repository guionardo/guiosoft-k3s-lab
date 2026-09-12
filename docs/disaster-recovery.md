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
- rehearsal isolado usando exclusivamente o snapshot remoto do R2 como fonte.

Isso prova a qualidade e recuperabilidade do artefato de backup. O passo que ainda falta é subir um K3s separado usando esse datastore restaurado.

## Dependências que não podem depender do servidor perdido

Uma recuperação real exige que os itens abaixo existam fora do host original:

- acesso ao repositório GitHub;
- identidade privada `age` usada pelo SOPS;
- acesso à conta Cloudflare/R2;
- arquivo SOPS cifrado com credenciais Restic/R2 versionado no Git;
- senha/segredo necessário para acessar o repositório Restic, recuperável via SOPS;
- documentação deste repositório.

A identidade privada `age` é especialmente crítica: o recipient público versionado no Git não permite descriptografar os secrets. A identidade privada precisa ter uma cópia externa independente e protegida.

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

Atualmente o cluster não possui PVC real de aplicação. O único PVC existente é o workload descartável `lab/persistence-test`.

Quando workloads stateful reais forem adicionados, cada um precisará ser classificado e protegido separadamente:

- **file-oriented**: backup consistente do filesystem;
- **database**: dump/snapshot nativo da engine como fonte primária de restore;
- **external**: procedimento específico do provedor;
- **stateless/reproducible**: reconstruído por Git/IaC, sem backup de dados.

O restore do control plane K3s não substitui o restore desses dados.

## Segurança

Nunca versionar:

- identidade privada `age`;
- credenciais R2 em plaintext;
- senha Restic em plaintext;
- server token extraído do backup;
- archives restaurados do K3s;
- kubeconfig real.

## Fontes

- K3s — Backup and Restore: https://docs.k3s.io/datastore/backup-restore
- K3s — Cluster Datastore: https://docs.k3s.io/datastore
- SOPS — age key management: https://getsops.io/docs/usage/key-management/
- Restic — Restoring from backup: https://restic.readthedocs.io/en/stable/050_restore.html
- Restic — Checking integrity: https://restic.readthedocs.io/en/stable/045_working_with_repos.html
