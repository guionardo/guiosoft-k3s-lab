# Propriedade efetiva dos volumes NTFS — decisão 2026-10-09

O operador prefere que os volumes NTFS compartilhados pelo Samba sejam apresentados como pertencentes ao usuário/grupo `guionardo` (UID/GID 1000), em vez de `root:root`.

## Implementação futura (não aplicada)

- Para NTFS montado com `ntfs-3g`, avaliar opções explícitas `uid=1000,gid=1000` e máscara de permissões restritiva, após testar a semântica de permissões e compatibilidade com arquivos existentes.
- **Não** executar `chown -R` ou `chmod -R` nos volumes existentes.
- Não alterar propriedade de volumes K3s, bancos de dados, `/mnt/store1`, `/mnt/store2` ou outros diretórios de sistema.
- `/mnt/dev` já é ext4 e seu diretório raiz pertence a `guionardo:guionardo`; não há motivo para mudar sua propriedade.
- O modelo multiusuário futuro exigirá grupos e autorização SMB próprios; UID/GID 1000 na montagem não equivale a ACLs individuais.
- A configuração atual `auto nofail` em fstab requer inspeção antes de migração para tipo/opções explícitos.
- Antes de qualquer remontagem: confirmar UUID, fstype, opções atuais, ausência de processos utilizando o volume, saúde do NTFS e plano de rollback. Uma mudança de opções de montagem pode interromper serviços que usam o disco.
- Não considerar um mountpoint vazio como disco válido: verificar a origem por UUID e falhar fechado.
- Credenciais SMB e autorização continuam independentes das opções de montagem.

## Diagnóstico adicional somente leitura

```bash
findmnt -T /mnt/hd500/sdf1 -o SOURCE,TARGET,FSTYPE,OPTIONS
findmnt -T /mnt/hd500/sdf2 -o SOURCE,TARGET,FSTYPE,OPTIONS
findmnt -T /mnt/hd500/sdf3 -o SOURCE,TARGET,FSTYPE,OPTIONS
id guionardo
```

O Ansible continua em modo diagnóstico e aplicação bloqueada.
