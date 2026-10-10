# Procedimento de mudança controlada — fstab histórico (PROPOSTA)

**Estado:** não autorizado, não executável como runbook de produção. O playbook principal permanece somente diagnóstico; o CLI recusa `--apply` no `/etc/fstab` real. Esta página serve para revisão e futura aprovação separada.

## Escopo e limites

Somente as entradas de `Fotos`, `BackupAntigo` e `ProjetosAntigos` (NTFS histórico), por UUID, com `ro,uid=1000,gid=1000,umask=027,nofail,noauto`. Não instalar Samba, montar volumes, criar mountpoints, editar outros itens do fstab, reiniciar serviços, mexer em firewall, modificar permissões recursivamente ou tocar nos volumes do K3s.

## Gates prévios (todos obrigatórios)

1. Autorização humana **explícita e específica** para editar `/etc/fstab` em janela combinada, depois de apresentar o diff exato e o plano de recuperação. Aprovação de testes ou diagnóstico não equivale a aprovação de aplicação.
2. Confirmar inventário atualizado de `blkid`, `findmnt`, `lsblk` e conteúdo/hash do `/etc/fstab`; não inferir estado atual a partir de logs antigos. Conferir origem, tipo NTFS e duplicidade de UUIDs; inspecionar mountpoints sem criá-los.
3. Confirmar ausência de automações concorrentes (Ansible, cloud-init, ferramentas de configuração, administradores) durante a janela. O `flock` do utilitário **não impede escritores externos**; teste existente demonstra perda de edição concorrente. Se não houver coordenação confiável, **abortar**.
4. Revisar owner/group/mode, atributos estendidos, ACLs, labels e comportamento de troca de inode no host. Se não for possível preservar os metadados necessários, **abortar**.
5. Testar procedimento de restauração e conferir espaço livre/permissões para backup no mesmo filesystem; garantir console/SSH de contingência. Registrar responsável, início/fim e critérios de sucesso.

## Sequência proposta (não executar ainda)

- Congelar mudanças concorrentes por procedimento operacional aprovado; capturar evidências e backup externo verificável, incluindo hash e metadados.
- Gerar candidato isolado, comparar diff e executar `findmnt --verify --tab-file` no candidato. Warnings sobre UUID/mountpoint não equivalem a aprovação do estado do disco.
- Revalidar identidade e metadados do alvo imediatamente antes da substituição. **Persistirá uma janela de corrida residual**; só proceder com exclusividade operacional garantida.
- Após substituição, verificar hash, conteúdo, metadados e `findmnt` do arquivo real; não montar dispositivos automaticamente.
- Se houver falha **antes** de `os.replace`, manter arquivo original e abortar. Se falhar a confirmação de persistência **depois** da troca, classificar `APPLIED_DURABILITY_UNCERTAIN`, preservar backup e inspecionar manualmente antes de qualquer nova tentativa.
- Uma eventual restauração só pode ocorrer após verificar o estado atual e obter decisão humana específica; **nunca** sobrescrever automaticamente edições posteriores.
- Registrar evidências de mudança, saída dos validadores, hashes, incidentes e conclusão. Montagem e compartilhamento Samba exigem aprovações e etapas independentes.

## Critérios de aborto

UUID/tipo divergente; entradas duplicadas ou alteradas; mountpoint inesperado; fstab com metadados não preserváveis; `findmnt` com erro; ausência de backup íntegro; concorrência não controlada; qualquer diferença entre candidato aprovado e candidato final; falha de acesso administrativo.

## Estado das evidências

Até 2026-10-10, o operador informou **21 testes aprovados** (`Ran 21 tests in 0.016s; OK`), incluindo teste que **reproduz** a perda de edição externa durante a troca. Esses testes não autorizam aplicação, não validam discos NTFS reais e não eliminam a janela de corrida. O helper de produção continua bloqueado.
