# Inspeção de armazenamento — 2026-10-09

Dados fornecidos pelo operador, coletados no host `guiosoft-info` sem alterações.

| Caminho | Proprietário | Modo | Observação |
|---|---|---|---|
| `/mnt/dev` | `guionardo:guionardo` | `755` | ext4, montado |
| `/mnt/hd500/sdf1` | `root:root` | `777` | NTFS montado |
| `/mnt/hd500/sdf2` | `root:root` | `777` | NTFS montado |
| `/mnt/hd500/sdf3` | `root:root` | `777` | NTFS montado |
| `/mnt/fotos` | sem saída do stat | — | não inferir existência nem montar sem validação |
| `/mnt/backup-antigo` | sem saída do stat | — | idem |
| `/mnt/projetos-antigos` | sem saída do stat | — | idem |

`df -h /mnt/dev`: `/dev/nvme0n1p1`, 916G total, 235G usados, 635G disponíveis, 28% utilizado.

## Implicações

- Propor `/mnt/dev/immich-input` como diretório novo, isolado e opcional, sem alterar a raiz `/mnt/dev`; confirmar espaço e política de retenção antes de ativar.
- Nunca executar alterações recursivas de ownership/permissões em volumes existentes.
- O modo `777` em NTFS não deve ser tomado como ACL POSIX funcional; validar ntfs-3g, opções de montagem e autenticação antes de permitir escrita.
- Para os três discos desmontados, verificar UUID e mountpoint antes de expor por Samba; impedir que um diretório vazio seja compartilhado acidentalmente.
- O `stat` sem saída com stderr suprimido não distingue diretório ausente de erro de acesso. Confirmar explicitamente na próxima inspeção.
- Manter `samba_apply: false` e `FotosEntrada` desabilitado até implantação revisada.
