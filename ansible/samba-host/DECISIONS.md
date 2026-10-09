# Decisões técnicas — Samba no host K3s

> Registro de decisões do projeto, atualizado em 2026-10-09. Distingue decisões adotadas de hipóteses e trabalho ainda não validado. Consulte também [README](README.md) e [documentação detalhada](docs/architecture-and-decisions.md).

## Contexto

O servidor Debian 13 `guiosoft-info` executa K3s. O objetivo é compartilhar volumes existentes na LAN `192.168.88.0/24` via Samba, sem comprometer o cluster, sem expor volumes de dados internos de aplicações e sem modificar conteúdo dos discos.

## Decisões adotadas

| ID | Decisão | Justificativa e consequência | Estado |
|---|---|---|---|
| D-001 | Diagnóstico Ansible é somente leitura por padrão (`samba_apply: false`) | Evitar alteração acidental em servidor K3s em uso. A execução padrão deve retornar `changed=0`. | Implementada e observada |
| D-002 | Identificar volumes por UUID, não por nomes `/dev/sdX` | A enumeração dos discos pode variar. Confirmar também tipo do sistema de arquivos. | Implementada e observada |
| D-003 | Não tocar `/mnt/store1`, `/mnt/store2` nem volumes fora do inventário | Preservar armazenamento do K3s e dados não relacionados. | Escopo definido |
| D-004 | Compartilhar `Fotos`, `BackupAntigo` e `ProjetosAntigos` somente leitura | Proteger arquivos históricos. Exigir `ro` na montagem, além de `read only` no Samba futuro. | Plano validado, não aplicado |
| D-005 | Não desmontar ou remontar `Documentos`, `Temporarios` e `DevBin` automaticamente | Há volumes NTFS já em uso; preservar o estado atual. | Restrição operacional |
| D-006 | Rejeitar mountpoints históricos existentes que sejam symlinks ou diretórios não vazios | Evitar ocultar dados sob um novo filesystem. | Preflight implementado e observado |
| D-007 | Separar preparação de `fstab`, criação de diretórios, montagem e ativação do Samba | Reduzir o raio de impacto e permitir aprovação e rollback por etapa. | Arquitetura adotada |
| D-008 | Usar `noauto,nofail` nas novas entradas históricas na primeira fase | Evitar montagem automática antes dos testes. | Código preliminar, não aplicado |
| D-009 | Não compartilhar diretórios internos gerenciados pelo Immich nem seu PostgreSQL | Evitar corrupção, conflitos de indexação e acoplamento ao armazenamento interno. `FotosEntrada` poderá ser uma pasta de ingestão independente, inicialmente desabilitada. | Decisão de arquitetura |
| D-010 | Samba autenticado, limitado à LAN, sem SMB1 | Reduzir exposição. Credenciais deverão ser tratadas com Ansible Vault. | Planejado, não implementado |
| D-011 | Preservar o firewall existente do host e regras do K3s | Não usar `nft flush ruleset`; não recarregar o serviço customizado sem mecanismo seguro de rollback. | Restrição operacional |
| D-012 | Documentar decisões, testes e falhas para publicação técnica posterior | Manter rastreabilidade entre evidências, decisões e artigo. | Em andamento |

## Inventário confirmado no diagnóstico

| Volume | Caminho | UUID | Tipo | Estado observado em 2026-10-09 |
|---|---|---|---|---|
| Documentos | `/mnt/hd500/sdf2` | `01D36FD6673F4300` | NTFS | Montado |
| Desenvolvimento | `/mnt/dev` | `3ed56e92-ab85-4b9a-8993-d2f1cda6a62e` | ext4 | Montado |
| Fotos | `/mnt/fotos` | `8CE4EC1DE4EC0AF2` | NTFS | Desmontado; diretório ausente |
| BackupAntigo | `/mnt/backup-antigo` | `964C33BF4C3398C7` | NTFS | Desmontado; diretório ausente |
| ProjetosAntigos | `/mnt/projetos-antigos` | `DA087AB8087A92ED` | NTFS | Desmontado; diretório ausente |
| Temporarios | `/mnt/hd500/sdf3` | `1068AFBC68AF9ECA` | NTFS | Montado |
| DevBin | `/mnt/hd500/sdf1` | `01D36FD612953850` | NTFS | Montado |

## Implementação e evidências

- Diagnóstico Ansible de 2026-10-09: `ok=14 changed=0 unreachable=0 failed=0 skipped=1`.
- `roles/samba_host/tasks/ntfs_fstab_plan.yml`: proposta de entradas sem escrita.
- `roles/samba_host/tasks/historical_mount_preflight.yml`: inspeção não destrutiva dos pontos de montagem.
- `roles/samba_host/tasks/historical_fstab_apply.yml`: transação **preliminar, não importada no playbook principal**, com backup, verificação e tentativa de rollback. **Não foi testada em host nem autorizada para aplicação.**
- `roles/samba_host/tasks/main.yml`: mantém bloqueio explícito da aplicação.

## Questões abertas / critérios de liberação

1. Testar a transação de `fstab` em ambiente isolado, incluindo conflitos, falhas intermediárias, rollback e repetição idempotente.
2. Confirmar presença e comportamento de `ntfs-3g`, `findmnt --verify` e suporte a mountpoints ainda ausentes.
3. Verificar permissões NTFS, UID/GID e efeitos de possíveis metadados Windows; nunca aplicar `chown -R` ou `chmod -R`.
4. Definir fluxo separado de criação de diretórios e montagem individual, com verificação posterior de `ro` e UUID.
5. Definir autenticação Samba, controle de acesso e política de firewall persistente sem interferir no K3s.
6. Aprovar explicitamente cada operação com efeitos no servidor.

## Política de atualização

A cada nova etapa: registrar data, evidência reproduzível, decisão, alternativas, riscos, resultado de teste e rollback. Nunca descrever uma proposta como se já estivesse implantada.
