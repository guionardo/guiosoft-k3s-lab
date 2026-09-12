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
- restore R2 -> local com comparação SHA-256 byte a byte.

Isso prova a qualidade do artefato de backup, mas ainda não prova a reconstrução completa de um servidor perdido.

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

O check é somente leitura. Ele valida:

- ferramentas essenciais instaladas;
- checkout Git e artefatos IaC presentes;
- existência e descriptografia do secret SOPS de Restic/R2;
- configuração runtime de backup;
- acesso ao repositório Restic no R2;
- existência de snapshot `k3s-control-plane`;
- existência de backup local recente;
- restore rehearsal do backup local.

O comando não altera o cluster nem o repositório Restic.

## Rehearsal em ambiente separado

O primeiro restore completo deve usar uma VM ou outro servidor sem acesso de escrita aos discos do host de produção.

Fluxo planejado:

```text
Debian limpo
   ↓
git clone guiosoft-k3s-lab
   ↓
restaurar identidade age fora do Git
   ↓
make ansible-deps
   ↓
make bootstrap
   ↓
make tools
   ↓
make storage
   ↓
recuperar/decriptar configuração Restic R2
   ↓
restaurar archive K3s mais recente do R2
   ↓
validar archive/checksum/SQLite/token
   ↓
instalar K3s na versão documentada
   ↓
parar K3s no host de DR
   ↓
restaurar server/db + server/token
   ↓
iniciar K3s
   ↓
validar node, namespaces, Services, Ingress e objetos do cluster
```

A etapa que substitui `server/db` e `server/token` é deliberadamente destrutiva e ainda não é automatizada. Ela só será implementada para um alvo explicitamente identificado como ambiente de DR.

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
