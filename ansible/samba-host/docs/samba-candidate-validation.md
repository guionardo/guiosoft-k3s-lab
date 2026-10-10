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

## Evidência de preflight — 2026-10-10

O operador executou o diagnóstico somente leitura no host: `id guionardo` retornou UID/GID 1000; `testparm` disponível em `/usr/bin/testparm`; `command -v smbd` não retornou caminho; `systemctl is-active smbd` retornou `inactive` e `systemctl is-enabled smbd` retornou `not-found`. Os quatro volumes ativos estavam montados com `rw` (`/mnt/hd500/sdf2`, `/mnt/dev`, `/mnt/hd500/sdf3`, `/mnt/hd500/sdf1`); os três históricos permaneciam desmontados. NTFS ativos expuseram `fuseblk` com `user_id=0,group_id=0`; isso não determina, isoladamente, se o usuário não privilegiado consegue escrever. Não houve instalação, escrita ou ativação de serviço.

Próximo gate: validar o template em arquivo temporário usando `testparm`, com ferramenta de renderização disponível, e inspecionar permissões Unix dos pontos de montagem sem executar testes de escrita. **Não iniciar Samba nem editar `/etc/samba/smb.conf`.**

## Evidência de permissões — 2026-10-10

O operador reportou: Documentos `/mnt/hd500/sdf2` `0777 root:root`, Desenvolvimento `/mnt/dev` `0755 guionardo:guionardo`, Temporarios `/mnt/hd500/sdf3` `0777 root:root` e DevBin `/mnt/hd500/sdf1` `0777 root:root`. Para UID 1000, `test -r` e `test -w` foram positivos em todos os quatro mountpoints. Isso comprova o resultado da checagem de permissões Unix, não um teste de escrita SMB. `testparm --version`: `4.22.11-Debian-4.22.11+dfsg-0+deb13u1`; Ansible Core `2.19.11`. Permissões locais `0777` em NTFS devem ser reavaliadas posteriormente; não alterar agora.

### Validação offline proposta (sem aplicação)

No checkout atualizado, a partir da raiz do repositório, renderizar o template Jinja com `ansible localhost` usando variáveis da role em um diretório temporário privado. Não usar `become` e não modificar `/etc/samba`:

```bash
cd ansible/samba-host
TMPDIR_SMB=$(mktemp -d)
chmod 700 "$TMPDIR_SMB"
cat > "$TMPDIR_SMB/render.yml" <<'YAML'
---
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - PLACEHOLDER_DEFAULTS
  tasks:
    - name: Render candidate offline
      ansible.builtin.template:
        src: PLACEHOLDER_TEMPLATE
        dest: PLACEHOLDER_OUTPUT
        mode: '0600'
YAML
# Substituir os placeholders por caminhos absolutos locais antes de executar.
# Depois: testparm -s "$TMPDIR_SMB/smb.conf"; remover somente o diretório temporário criado.
```

O exemplo é um esboço de procedimento, não um script executável pronto; usar caminhos absolutos e revisar o playbook antes da execução.
