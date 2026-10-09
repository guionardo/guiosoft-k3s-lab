# Operação e recuperação — Samba host

## Estado atual

**Preparação apenas.** Não instalar Samba, não montar volumes históricos e não editar `/etc/fstab` em produção nesta etapa.

## Diagnóstico seguro

A partir de `ansible/samba-host`:

```bash
git pull
ansible-playbook -i inventory/hosts.ini playbooks/site.yml --ask-become-pass
```

Critérios de aceitação: `failed=0`, `changed=0`; sete UUIDs e tipos corretos; quatro volumes atuais montados; três históricos desmontados; diretórios históricos ausentes ou vazios e sem symlink.

## Procedimento de mudança planejado — NÃO executar ainda

1. Validar preflight e confirmar que nenhuma outra alteração ocorreu no `fstab`.
2. Revisar o arquivo candidato e a presença do driver `mount.ntfs-3g`.
3. Confirmar que não existem entradas conflitantes por UUID, destino ou dispositivo.
4. Gerar backup datado do `/etc/fstab` e comparar bytes com o original.
5. Criar os diretórios históricos somente após autorização, garantindo que estejam vazios.
6. Inserir apenas as três entradas históricas, com `ro,nofail,noauto`.
7. Validar sintaxe e conteúdo do `fstab`; reverter imediatamente em falha.
8. Em fase posterior, montar **individualmente** e conferir UUID, fonte, destino e modo `ro` efetivo.
9. Só depois considerar Samba, autenticação e regras de firewall.

## Recuperação prevista

A implementação preliminar `roles/samba_host/tasks/historical_fstab_apply.yml` tenta restaurar o backup no bloco `rescue`. Ainda faltam testes de falhas injetadas e de concorrência; **não considerar o rollback validado**.

Em incidente, preservar evidências, interromper a automação e comparar o `fstab` com seu backup antes de qualquer reinicialização. Não executar `mount -a` para testar uma configuração ainda não validada.

## Evidências e verificação

Guardar data, commit Git, comando, recap Ansible e diferenças observadas. Não publicar senhas SMB, arquivos Vault nem segredos de infraestrutura.
