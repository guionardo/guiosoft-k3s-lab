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
