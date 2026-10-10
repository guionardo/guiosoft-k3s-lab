# Proposta: ensaio temporário somente leitura — Fotos

**Estado:** procedimento documental; NÃO autorizado para execução. Nenhuma automação executa os comandos abaixo. O operador deve aprovar separadamente a criação do diretório, a montagem e a desmontagem. Não usar `samba_apply=true`.

## Evidência de 2026-10-10

O diagnóstico Ansible terminou com `ok=21 changed=0 failed=0`. Fotos foi identificado como `/dev/sde6`, UUID `8CE4EC1DE4EC0AF2`, `TYPE=ntfs`, desmontado, com `/mnt/fotos` inexistente e sem entrada no `/etc/fstab`. `ntfs-3g`, `mount.ntfs-3g`, `findmnt` e `blkid` estão disponíveis. Essas condições **precisam ser reconfirmadas imediatamente antes** de uma execução.

## Escopo e pré-condições

- Apenas Fotos; BackupAntigo e ProjetosAntigos permanecem intocados.
- Janela de manutenção e operador presentes; identificar serviços que possam acessar o dispositivo.
- Nenhum outro processo montando, modificando ou verificando o volume; garantir ausência de montagem do mesmo UUID em qualquer destino.
- O ensaio não usa `/etc/fstab`, `mount -a`, automount, reparo NTFS, `ntfsfix` ou mudança de permissões.
- Escolher diretório temporário dedicado e vazio, fora dos diretórios de aplicações. **Não utilizar `/mnt/fotos` antes de decisão explícita sobre seu uso definitivo.**
- A opção `ro` limita gravações pelo driver, mas não substitui proteção física nem prova que o dispositivo não está sendo alterado por outros processos. Se houver indício de volume NTFS hibernado, sujo ou inconsistente, interromper sem tentar reparar.

## Gate 1 — verificações somente leitura

Executar manualmente após autorização para diagnóstico, revisando a saída antes de prosseguir:

```bash
sudo blkid -o export "$(blkid -U 8CE4EC1DE4EC0AF2)"
findmnt --source UUID=8CE4EC1DE4EC0AF2
findmnt --mountpoint /mnt/fotos
command -v ntfs-3g
command -v mount.ntfs-3g
```

A ausência de saída em `findmnt` não basta isoladamente: conferir códigos de saída, aliases do dispositivo e outras montagens por dispositivo/UUID. Se a identificação ou o estado divergir, **parar**.

## Gate 2 — execução futura, somente com aprovação específica

A autorização deve indicar explicitamente o diretório temporário escolhido, a permissão de criá-lo e a permissão de montar/desmontar Fotos. Com a autorização, preparar comandos revisados para o estado observado naquele momento, usando `UUID` resolvido novamente e driver `ntfs-3g` com `ro` e `noexec,nosuid,nodev`. Não habilitar montagem automática nem gravação.

Após montar, verificar com `findmnt --mountpoint <destino> -o SOURCE,FSTYPE,OPTIONS` que a fonte é o UUID esperado e que as opções efetivas incluem `ro`. Fazer apenas leitura superficial dos nomes de arquivos; evitar varreduras extensas ou acessos de serviços. Se qualquer verificação falhar, parar e avaliar desmontagem controlada.

## Gate 3 — desmontagem e limpeza

Confirmar que nenhum processo usa o destino; desmontar apenas o destino temporário explicitamente autorizado, sem `umount -l` ou `umount -f`. Conferir ausência da montagem por destino **e** dispositivo. Remover o diretório temporário apenas se foi criado especificamente para o ensaio, continua vazio, não é mountpoint e a remoção foi aprovada.

## Critérios de interrupção e registro

Interromper em UUID divergente, origem já montada, diretório ocupado, driver indisponível, opções efetivas sem `ro`, NTFS inconsistente ou uso inesperado. Registrar data, comandos aprovados, identificador real do dispositivo, opções efetivas, resultado de leitura, desmontagem e incidentes. Não inferir autorização de execução a partir deste documento.
