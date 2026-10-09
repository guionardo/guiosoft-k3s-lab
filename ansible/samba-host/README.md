# Samba no host guiosoft-info (preparação; NÃO implantado)

Esta área documenta a proposta de Samba no Debian 13 que hospeda o K3s. **Nenhum playbook deve aplicar alterações sem revisão.** O diagnóstico padrão é somente leitura.

## Documentação do projeto

- [Arquitetura, inventário e decisões (ADRs)](docs/architecture-and-decisions.md)
- [Procedimentos operacionais e recuperação](docs/operations-and-recovery.md)
- [Diário de engenharia e evidências](docs/engineering-log.md)

O material para um artigo técnico será derivado dessas evidências **após** os testes de montagem, rollback, Samba e firewall. A documentação distingue o que já foi observado do que ainda é proposta.

## Decisão Immich

Não compartilhar o diretório interno de uploads nem o PostgreSQL do Immich. Manter uma pasta SMB independente `FotosEntrada` para receber arquivos, com um importador futuro responsável por verificar conclusão de transferências, deduplicar, registrar falhas, importar e reter originais até backup confirmado. A pasta é opcional e está **desabilitada**. O acervo `Fotos` existente começa somente leitura.

## Volumes

- Documentos: /mnt/hd500/sdf2, NTFS, UUID 01D36FD6673F4300
- Desenvolvimento: /mnt/dev, ext4, UUID 3ed56e92-ab85-4b9a-8993-d2f1cda6a62e
- Fotos: /mnt/fotos, NTFS, UUID 8CE4EC1DE4EC0AF2 (desmontado na inspeção)
- BackupAntigo: /mnt/backup-antigo, NTFS, UUID 964C33BF4C3398C7 (desmontado)
- ProjetosAntigos: /mnt/projetos-antigos, NTFS, UUID DA087AB8087A92ED (desmontado)
- Temporarios: /mnt/hd500/sdf3, NTFS, UUID 1068AFBC68AF9ECA
- DevBin: /mnt/hd500/sdf1, NTFS, UUID 01D36FD612953850

## Pendências bloqueantes

Montagens por UUID e validação de NTFS, senhas SMB por Vault, política persistente nftables, testes de permissões Unix, retenção/importador Immich, rollback e avaliação de exposição da raiz /mnt/dev. Não executar `samba_apply=true` em produção. Não alterar dados nem permissões recursivamente. K3s /mnt/store1 e /mnt/store2 permanecem fora do escopo.

## Diagnóstico

```bash
ansible-playbook -i inventory/hosts.ini playbooks/site.yml --ask-become-pass
```

O diagnóstico verifica UUIDs e montagens, mas não instala nem configura serviços. O modo de aplicação existente é deliberadamente incompleto e **não deve ser usado**.

## Plano NTFS em modo somente leitura (2026-10-09)

O playbook inclui `roles/samba_host/tasks/ntfs_fstab_plan.yml`, que lê `/etc/fstab` com `slurp`, mostra uma proposta por UUID e rejeita UUIDs duplicados. **Não escreve em fstab nem monta/desmonta volumes.** A configuração candidata usa `ntfs-3g ro,uid=1000,gid=1000,umask=027,nofail` nos históricos somente leitura (e sem `ro` nos volumes de escrita), sujeita a revisão de permissões e testes antes da implantação.

Após atualizar o repositório:

```bash
cd ansible/samba-host
ansible-playbook -i inventory/hosts.ini playbooks/site.yml --ask-become-pass
```

Resultado esperado: `changed=0`, sem falhas e com uma linha de proposta para cada volume NTFS. Envie a saída para revisão antes de implementar qualquer escrita no `/etc/fstab`.

### Preflight de diretórios históricos (2026-10-09)

Antes de qualquer alteração, o diagnóstico agora verifica `/mnt/fotos`, `/mnt/backup-antigo` e `/mnt/projetos-antigos` sem criar diretórios. Se algum caminho existir, ele deve ser diretório real (não symlink) e estar vazio, incluindo arquivos ocultos. Um caminho inexistente é permitido nesta fase, mas precisará ser criado em uma etapa de aplicação explicitamente autorizada.

**Gate operacional:** o playbook principal não contém tarefas que escrevam no `/etc/fstab`, instalem Samba ou montem volumes. `samba_apply=true` continua falhando intencionalmente. O próximo estágio será uma transação separada, com backup datado de `/etc/fstab`, verificação de configuração e rollback, somente depois de revisão e autorização. Os três volumes NTFS já montados não serão remontados automaticamente.

### Transação fstab preparada, ainda não habilitada

O arquivo `roles/samba_host/tasks/historical_fstab_apply.yml` contém um estágio **não importado pelo playbook principal**. Ele exige três confirmações, verifica conflitos de UUID e destino, cria backup de `/etc/fstab`, insere somente os três volumes históricos e tenta validar com `findmnt --verify`; em falha, restaura o backup. As entradas usam `ro,nofail,noauto` para não montar automaticamente nem no momento da edição nem no boot.

**Não executar esse arquivo isoladamente.** Antes de integrá-lo, precisamos validar em ambiente de teste o comportamento de `findmnt --verify` com diretórios ainda inexistentes, conferir os requisitos do driver NTFS e revisar a restauração em falhas intermediárias. A criação dos diretórios e as montagens serão etapas separadas. O playbook principal continua sem tarefas de escrita e `samba_apply=true` continua bloqueado.

## Revisão da transação de fstab (2026-10-09)

A transação preliminar foi substituída por um auxiliar isolado em `scripts/historical_fstab_transaction.py`, com preview padrão, candidato validado antes da substituição e testes de unidade usando arquivos temporários. O estágio Ansible continua **não importado** e foi alterado para **preview seguido de bloqueio explícito**: não faz escrita em `/etc/fstab`. Oito testes de unidade passaram em ambiente isolado (`0,008 s`), com `findmnt` simulado; a execução no servidor e a validação real do `findmnt` ainda não foram realizadas.

Veja [revisão, riscos e procedimentos de teste](docs/fstab-transaction-review-2026-10-09.md). Para executar os testes isolados:

```bash
python3 -m unittest discover -s ansible/samba-host/tests -p 'test_*.py' -v
```

**Não executar `--apply` contra `/etc/fstab` nem habilitar o estágio no playbook.** Criação de diretórios e montagem individual continuam dependentes de autorização separada.
