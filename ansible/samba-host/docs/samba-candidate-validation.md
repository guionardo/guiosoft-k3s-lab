# Validação offline do candidato Samba

**Somente preparação.** Não executar como root, não sobrescrever `/etc/samba/smb.conf`, não iniciar `smbd`, não abrir firewall. O template está em `templates/smb.conf.candidate.j2` e usa os defaults da role. Renderizar com Ansible local em etapa futura, após verificar dependências e variáveis. `testparm` valida sintaxe/semântica, **não** confirma permissões reais, montagem, credenciais nem isolamento de rede.

## Checklist pré-implantação

1. Confirmar estado de `smbd` e disponibilidade de `testparm` sem instalar pacotes.
2. Confirmar `id guionardo` e acesso Unix às raízes; para escrita, testar com conta efetiva em diretório de ensaio **somente após aprovação**.
3. Verificar UUID, tipo, caminho e opções da montagem de **cada** share imediatamente antes de iniciar/recarregar Samba. Se qualquer share não estiver montado exatamente onde esperado, abortar (fail closed). Histórico deve ter `ro` efetivo.
4. Rever política `hosts allow`/firewall e interfaces IPv4/IPv6; a restrição Samba não substitui nftables. Não modificar o firewall existente sem rollback.
5. Verificar `testparm -s /caminho/do/candidato` em arquivo temporário; não editar arquivo de produção.
6. Credenciais SMB somente em mecanismo seguro, nunca em repositório ou logs. Confirmar autorização da conta `guionardo`.
7. Validar acesso remoto autenticado, negação de convidados, escrita nos ativos, bloqueio de escrita nos históricos e ausência de exportação quando volume desmontado.
8. Planejar backup, rollback e checagens de SSH/K3s/Immich.

## Diagnóstico somente leitura no host

```bash
echo '=== Identidade ==='
id guionardo

echo '=== Ferramentas Samba ==='
command -v testparm || true
command -v smbd || true

echo '=== Serviço (sem iniciar) ==='
systemctl is-active smbd || true
systemctl is-enabled smbd || true

echo '=== Caminhos existentes ==='
for path in /mnt/hd500/sdf2 /mnt/dev /mnt/hd500/sdf3 /mnt/hd500/sdf1 /mnt/fotos /mnt/backup-antigo /mnt/projetos-antigos; do
  printf '%s: ' "$path"
  findmnt --mountpoint "$path" -n -o SOURCE,FSTYPE,OPTIONS || echo 'NAO MONTADO'
done
```

**Não usar `set -e` na sessão SSH interativa:** falhas esperadas de comandos de diagnóstico podem encerrar a sessão. O template é candidato, não substituto da configuração operacional.

## Limites conhecidos do candidato

- `hosts allow = 127. 192.168.88.` restringe por prefixo de IP; revisar rede exata e IPv6 antes da aplicação.
- `read only = no` não concede escrita se o Unix/NTFS negar.
- Não há ainda pré-validação de mountpoint integrada ao ciclo de vida do `smbd`, nem regras nftables, nem provisionamento de senha.
- `/mnt/dev` inteiro está provisoriamente em escopo, com risco de exposição de segredos.
- O template não está referenciado por tarefa de implantação; `samba_apply=true` continua bloqueado.
