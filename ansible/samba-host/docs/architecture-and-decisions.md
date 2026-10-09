# Arquitetura e decisões — Samba no host K3s

## Contexto e objetivo

Servidor Debian 13 `guiosoft-info`, executando K3s e serviços de armazenamento. Objetivo: disponibilizar diretórios selecionados na rede local por Samba, sem compartilhar os volumes de dados internos do Kubernetes.

## Fronteiras de segurança

- `/mnt/store1` e `/mnt/store2` pertencem ao ambiente K3s e ficam fora do escopo.
- Não compartilhar o PostgreSQL, uploads internos ou biblioteca gerenciada do Immich.
- `Fotos`, `BackupAntigo` e `ProjetosAntigos` serão inicialmente somente leitura tanto no NTFS quanto no Samba.
- Não executar `chown -R`, `chmod -R`, `mount -a`, remontagem de volumes ativos ou `nft flush ruleset`.
- O firewall atual é gerenciado por serviço próprio, não por `nftables.service`; seu reload pode deixar a tabela ausente caso falhe. A abertura da porta 445 requer plano de troca atômica e rollback.
- Samba ainda não está instalado nem configurado. Autenticação SMB, Vault e permissões serão etapas posteriores.

## Inventário observado (2026-10-09)

| Compartilhamento | UUID | FS | Caminho | Estado |
|---|---|---|---|---|
| Documentos | 01D36FD6673F4300 | NTFS | /mnt/hd500/sdf2 | montado |
| Desenvolvimento | 3ed56e92-ab85-4b9a-8993-d2f1cda6a62e | ext4 | /mnt/dev | montado |
| Fotos | 8CE4EC1DE4EC0AF2 | NTFS | /mnt/fotos | desmontado; diretório ausente |
| BackupAntigo | 964C33BF4C3398C7 | NTFS | /mnt/backup-antigo | desmontado; diretório ausente |
| ProjetosAntigos | DA087AB8087A92ED | NTFS | /mnt/projetos-antigos | desmontado; diretório ausente |
| Temporarios | 1068AFBC68AF9ECA | NTFS | /mnt/hd500/sdf3 | montado |
| DevBin | 01D36FD612953850 | NTFS | /mnt/hd500/sdf1 | montado |

Identificação deve ser sempre por UUID, não pelo nome mutável `/dev/sdX`.

## Decisões registradas

### ADR-001: diagnóstico como operação padrão
**Decisão:** `samba_apply: false`; o playbook principal coleta evidências e não escreve no host. **Motivo:** o servidor executa cargas K3s e contém dados históricos.

### ADR-002: montar históricos como somente leitura
**Decisão:** candidatos NTFS com `ro,uid=1000,gid=1000,umask=027,nofail,noauto`. **Motivo:** reduzir risco de escrita acidental e evitar montagens automáticas antes da validação. **Pendente:** testar suporte e comportamento do driver, e validar permissões efetivas.

### ADR-003: separar transação de fstab e montagem
**Decisão:** preparar alterações em `/etc/fstab` separadamente da criação de diretórios e das montagens. **Motivo:** facilitar inspeção e recuperação. **Estado:** transação preliminar não importada; não aprovada para execução.

### ADR-004: isolar Immich do compartilhamento
**Decisão:** `FotosEntrada` opcional e desabilitada; futuro importador com deduplicação, verificação de transferência e confirmação de backup antes da exclusão da origem. **Motivo:** não expor o armazenamento gerenciado pelo Immich.

## Riscos ainda abertos

1. Sem validação de laboratório para rollback em falha parcial de `fstab`.
2. `findmnt --verify` pode ter comportamento dependente da existência dos pontos de montagem e da versão do utilitário.
3. Regras de permissão NTFS e SMB precisam ser verificadas com usuários reais.
4. Compartilhar toda a raiz de `/mnt/dev` amplia a superfície de exposição; revisar subdiretórios.
5. A configuração de firewall persistente exige procedimento que preserve regras K3s.
