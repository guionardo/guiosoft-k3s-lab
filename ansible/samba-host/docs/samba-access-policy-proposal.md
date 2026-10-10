# Proposta de política de acesso Samba — revisão, sem implantação

**Estado:** proposta. Não instalar, iniciar ou reconfigurar Samba; não criar contas/senhas; não abrir portas. O playbook diagnóstico continua sem alterações no host e `samba_apply=true` permanece bloqueado.

## Evidências e limitações

Em 2026-10-10, o operador montou Fotos (UUID `8CE4EC1DE4EC0AF2`) temporariamente em `/mnt/fotos-ro-test`, com opções efetivas `ro,nosuid,nodev,noexec`. Leitura superficial bem-sucedida. Diretórios apareceram `root:root` e modo `0777`; desmontagem e remoção do diretório foram confirmadas. Isso **não comprova** acesso como usuário não privilegiado ou proteção adequada dos demais volumes.

## Matriz proposta

| Compartilhamento | Origem | Escrita SMB | Montagem / condição |
| --- | --- | --- | --- |
| Documentos | /mnt/hd500/sdf2 | **Sim, provisoriamente** | NTFS ativo; preservar fstab e montagem |
| Desenvolvimento | /mnt/dev | **Sim, provisoriamente; alto risco** | ext4 ativo; revisão futura de subdiretórios e segredos |
| Fotos | /mnt/fotos | **Não** | NTFS histórico; ainda desmontado |
| BackupAntigo | /mnt/backup-antigo | **Não** | NTFS histórico; ainda desmontado |
| ProjetosAntigos | /mnt/projetos-antigos | **Não** | NTFS histórico; ainda desmontado |
| Temporarios | /mnt/hd500/sdf3 | **Sim, provisoriamente** | NTFS ativo; preservar montagem |
| DevBin | /mnt/hd500/sdf1 | A avaliar | NTFS ativo; preservar montagem |

Nenhum compartilhamento deve ser publicado quando seu caminho não for um mountpoint esperado: impedir exposição acidental de um diretório vazio do filesystem raiz.

## Política de autenticação e rede

- Somente SMB moderno (SMB2/SMB3); SMB1 desabilitado.
- `guest ok = no`, `map to guest = Never`, `usershare allow guests = no`.
- `valid users` deve ser uma lista explícita de contas SMB autorizadas, inicialmente proposta `guionardo`, **sujeita a confirmação do operador**. Não presumir que a conta local já tem credencial SMB.
- Vincular serviço e firewall à LAN autorizada `192.168.88.0/24`, com cautela em interfaces, IPv6 e políticas nftables já existentes. Não aplicar firewall antes de um plano de rollback e teste de conectividade.
- Para históricos: `read only = yes` e `writeable = no`; a montagem `ro` é defesa adicional independente.
- Não habilitar `follow symlinks` / `wide links` para atravessar diretórios de fora do compartilhamento.
- Senhas não devem aparecer em Git, logs ou argumentos de linha de comando; futura criação por Ansible Vault ou mecanismo equivalente com revisão.
- Não exportar diretórios internos do Immich, bancos de dados, diretórios de sistema ou volumes K3s.

## Trecho ilustrativo — não é smb.conf pronto para implantação

```ini
[global]
    server min protocol = SMB2_02
    map to guest = Never
    usershare allow guests = no

[Fotos]
    path = /mnt/fotos
    browseable = yes
    guest ok = no
    valid users = guionardo
    read only = yes
    writeable = no
    follow symlinks = no
    wide links = no
```

**Não copiar esse trecho diretamente para produção.** Antes, verificar `testparm`, regras de acesso por interfaces, autenticação real, permissões Unix, existência e montagem exata dos caminhos, integração com serviços existentes e procedimento de recuperação. A presença de `read only = yes` no Samba não substitui a montagem NTFS `ro`.

## Gates pendentes

1. Levantar, somente leitura, `id guionardo`, permissões dos mountpoints e estado atual de `smbd`, `testparm` e firewall. Não exibir hashes ou senhas.
2. **Decisão do operador em 2026-10-10:** permitir escrita SMB, provisoriamente, em Documentos, Desenvolvimento (todo `/mnt/dev`), Temporarios e DevBin; revisar posteriormente a granularidade de Desenvolvimento. Antes da implantação, verificar riscos de segredos, acesso Unix efetivo e autenticação; esta decisão não autoriza aplicar configuração.
3. Testar acesso autenticado, negação de convidado, negação de escrita nos históricos, resolução de nomes e ausência de exposição quando um disco estiver desmontado.
4. Planejar rollback da configuração Samba e das regras de firewall sem interromper SSH/K3s/Immich.
5. Só depois propor automação de aplicação com aprovação separada.

## Decisão de escopo provisório — 2026-10-10

O operador confirmou permissão de escrita, por enquanto, para os compartilhamentos ativos, incluindo `/mnt/dev` completo, com revisão posterior. A decisão não altera a política somente leitura de Fotos, BackupAntigo e ProjetosAntigos, nem constitui aprovação para implantar Samba, criar contas, modificar permissões ou abrir portas. Deve-se registrar o risco de exposição de arquivos sensíveis em `/mnt/dev` e revisar esse escopo antes de disponibilizar o serviço a outros usuários.
