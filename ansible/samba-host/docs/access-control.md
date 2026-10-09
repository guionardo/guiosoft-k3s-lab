# Modelo de acesso Samba — decisão 2026-10-09

**Estado:** desenho aprovado conceitualmente; não aplicado no host.

## Contas

- Primeira conta: `guionardo` (usuário Linux já existente).
- Futuro: uma conta individual por pessoa, com senha Samba própria.
- Não habilitar convidados nem compartilhar credenciais.
- Credenciais protegidas por Ansible Vault ou provisionamento interativo seguro; nunca versionar senhas em claro.
- Contas futuras devem ser explicitamente declaradas e autorizadas antes de serem provisionadas.

## Autorização

- Projetar grupos Linux de acesso por compartilhamento, distinguindo leitura e escrita quando necessário.
- O acesso SMB precisa respeitar **ambas** as camadas: `valid users`/regras do Samba e permissões do filesystem.
- Não aplicar `chown -R`, `chmod -R` ou ACLs indiscriminadamente em diretórios existentes.
- NTFS via ntfs-3g pode usar uid/gid/umask na montagem e não tem a mesma semântica de ACL POSIX que ext4; validar opções antes de habilitar escrita multiusuário.
- `/mnt/dev` contém dados existentes; qualquer mudança de permissões exige escopo restrito a um subdiretório novo.

## Immich

- `FotosEntrada` será uma área SMB separada, opcional e inicialmente desabilitada.
- Nunca disponibilizar por SMB o diretório interno de uploads, dados do PostgreSQL ou PVCs internos do Immich.
- Importação futura deverá lidar com arquivos incompletos, deduplicação, erros, auditoria e retenção dos originais.
- O acervo histórico `Fotos` começa somente leitura.

## Política inicial proposta

- Habilitar somente `guionardo` no Samba.
- Compartilhamentos existentes em modo somente leitura até validar ownership, mounts e requisitos de escrita individualmente.
- A implantação permanece bloqueada no playbook até concluir credenciais, montagens, firewall seguro e rollback.

## Próximos passos

1. Verificar o estado dos diretórios, uid/gid efetivos, espaço e opções de montagem.
2. Implementar variáveis de usuários e grupos sem provisionar contas automaticamente por padrão.
3. Adicionar verificações de permissão, testes de idempotência e aplicação controlada.
