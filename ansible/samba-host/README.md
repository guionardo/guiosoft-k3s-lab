# Samba no host guiosoft-info (preparação; NÃO implantado)

Esta área documenta a proposta de Samba no Debian 13 que hospeda o K3s. **Nenhum playbook deve aplicar alterações sem revisão.** O diagnóstico padrão é somente leitura.

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
