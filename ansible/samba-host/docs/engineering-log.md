# Diário de engenharia — Samba no Debian 13 com K3s

## 2026-10-09 — Identificação de discos e preflight

**Objetivo:** preparar sete compartilhamentos sem afetar K3s e dados existentes.

**Observações:**
- Dispositivos identificados por UUID usando `blkid`.
- `findmnt --mountpoint` confirmou quatro montagens ativas e três históricos desmontados.
- Os três caminhos históricos não existem; portanto, a inspeção de conteúdo foi corretamente ignorada.
- `/etc/fstab` já contém as três entradas NTFS ativas e não contém os três históricos.
- Plano de montagem ajustado para `ro` nos históricos.
- Resultado do último teste fornecido: `ok=14 changed=0 unreachable=0 failed=0 skipped=1`.

**Problema encontrado:** primeira versão da chamada `findmnt` precisava passar `SOURCE,FSTYPE` como um único argumento. Corrigido e validado em execução posterior.

**Mudanças no repositório:** preflight de diretórios, plano NTFS e transação de `fstab` preparada, ainda desconectada do playbook principal.

**Pendências:** testes da transação/rollback, verificação do driver NTFS, diretórios e montagens históricas, permissões SMB, autenticação e firewall.

## Critério para publicação do artigo

Distinguir rigorosamente resultados **observados em execução** de **comportamentos planejados**. Só declarar rollback e montagem como testados após evidências reais.

## 2026-10-10 — diagnóstico dos volumes históricos

O operador executou o diagnóstico em `guiosoft-info` e reportou `ok=18 changed=0 unreachable=0 failed=0 skipped=1`. Os três dispositivos foram identificados por UUID e tipo NTFS: Fotos `/dev/sde6` (`8CE4EC1DE4EC0AF2`), BackupAntigo `/dev/sde1` (`964C33BF4C3398C7`) e ProjetosAntigos `/dev/sde3` (`DA087AB8087A92ED`). Os três permaneciam desmontados, com mountpoints inexistentes e sem entradas correspondentes no fstab. Nenhuma alteração foi aplicada. Próxima verificação: disponibilidade de ntfs-3g e ferramentas, sem instalação nem montagem.

## 2026-10-10 — preflight NTFS confirmado

O operador reportou `ok=21 changed=0 unreachable=0 failed=0 skipped=1` em `guiosoft-info`. Executáveis presentes: `ntfs-3g` em `/usr/bin/ntfs-3g`, `mount.ntfs-3g` em `/usr/sbin/mount.ntfs-3g`, `findmnt` em `/usr/bin/findmnt`, `blkid` em `/usr/sbin/blkid`. Fotos, BackupAntigo e ProjetosAntigos permanecem desmontados, com pontos de montagem inexistentes e sem entradas no fstab. O comando `cd ansible/samba-host` falhou porque o operador já estava nesse diretório; o playbook prosseguiu com sucesso. Não houve instalação, montagem ou mudança de configuração. Próximo gate: planejar ensaio somente leitura de Fotos, sem executá-lo até autorização explícita.

## 2026-10-10 — ensaio manual de Fotos somente leitura

Com aprovação explícita do operador, o volume Fotos (`UUID=8CE4EC1DE4EC0AF2`, `/dev/sde6`, NTFS) foi montado temporariamente em `/mnt/fotos-ro-test` com `ntfs-3g` e opções efetivas `ro,nosuid,nodev,noexec` (`fuseblk`). Listagem superficial da raiz e dos nomes de entradas foi bem-sucedida; nenhum teste de escrita ou varredura recursiva foi feito. Os diretórios no volume apareceram com `root:root` e modo `0777`, exigindo avaliação de mapeamento de permissões antes do Samba. `fuser -vm` mostrou somente `root kernel mount`; `sudo umount /mnt/fotos-ro-test` concluiu sem erro; `findmnt --mountpoint` não retornou montagem e `ls -la` mostrou diretório temporário vazio (`0700`, root). **Remoção do diretório ainda não confirmada**: comando `sudo rmdir /mnt/fotos-ro-test` recomendado ao operador, aguardando saída. Nenhuma alteração no fstab, Samba ou K3s.

**Encerramento confirmado pelo operador:** o diretório temporário `/mnt/fotos-ro-test` foi removido após a desmontagem e a conferência de que estava vazio. Ensaio de Fotos finalizado.
