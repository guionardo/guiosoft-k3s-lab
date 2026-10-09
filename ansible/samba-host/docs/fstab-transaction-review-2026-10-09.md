# Revisão da transação de fstab — 2026-10-09

## Escopo e estado

A revisão é baseada no código da branch `main`; o diagnóstico do host informado pelo operador terminou com `ok=14 changed=0 failed=0`. **Nenhuma escrita no host foi realizada nesta revisão.** A role principal continua executando somente diagnóstico e bloqueia `samba_apply=true`.

O estágio preliminar `historical_fstab_apply.yml` continha defeitos: rejeitava suas próprias entradas numa segunda execução; backup por timestamp podia colidir; o `rescue` dependia de estados Ansible intermediários; validar `findmnt --verify` depois de escrever diretamente em `/etc/fstab` abria uma janela de falha; verificações por regex eram insuficientes para conflito de destinos. O backup antes da edição não constituía garantia de rollback seguro em caso de interrupção brusca.

## Implementação revisada

`scripts/historical_fstab_transaction.py` é um auxiliar de arquivo isolado com as seguintes propriedades:

- Por padrão realiza somente `--dry-run` implícito, sem gravação no arquivo alvo; `--apply` é explícito.
- Preserva linhas pré-existentes, insere um bloco marcado único, mantém opções `ro,uid=1000,gid=1000,umask=027,nofail,noauto`; recusa bloco gerenciado adulterado, duplicado ou incompleto.
- Rejeita conflitos básicos de UUID e caminho fora do bloco, symlinks e arquivos com múltiplos hardlinks.
- Usa lock exclusivo entre instâncias deste auxiliar; cria candidato e valida com `findmnt --verify --tab-file` **antes** da substituição.
- Em mudança real, grava backup antes de `os.replace` e compara novamente bytes/inode antes de substituir.
- Não cria mountpoints, não monta volumes, não instala Samba e não modifica firewall.

**Limites:** lock não coordena ferramentas externas (`mount`, editores, `systemd`, outros Ansible). A checagem de concorrência não elimina a janela TOCTOU entre conferência e `os.replace`. `findmnt --verify` pode produzir diagnósticos dependentes dos diretórios de montagem. Falha de energia ou falha depois do `os.replace` exige inspeção/recuperação manual a partir do backup — não existe rollback automático universalmente seguro. O utilitário ainda precisa de revisão de configurações de fstab legadas, labels, aliases de dispositivos, escapes e atributos especiais. **Não liberado para aplicação em produção.**

O arquivo `roles/samba_host/tasks/historical_fstab_apply.yml` agora contém somente estágio de *preview*, exige os três gates de autorização e termina obrigatoriamente em falha antes de qualquer edição de fstab. Continua não importado pela role principal.

## Teste local isolado

A partir da raiz do repositório:

```bash
python3 -m unittest discover -s ansible/samba-host/tests -p 'test_*.py' -v
```

Casos cobertos: preview sem escrita; primeira aplicação sobre arquivo temporário; repetição idempotente; conflitos por fonte e destino; marcadores danificados; adulteração de opções; validação com falha injetada antes da escrita; recusa de symlink. **Execução comprovada em ambiente isolado em 2026-10-09:** `python -m unittest discover -s tests -v` na cópia dos arquivos publicados; **8 testes, 8 aprovados**, duração **0,008 s**. O teste faz mock do validador; **não atesta** o comportamento real do `findmnt` no Debian 13, nem a execução Ansible ou a segurança em produção. Os testes foram executados fora do host `guiosoft-info`.

### Ensaio adicional sem escrever no host

Em ambiente local descartável com Python 3, executar com arquivos de teste:

```bash
tmpdir=$(mktemp -d)
printf '# fixture de teste\n' > "$tmpdir/fstab"
python3 ansible/samba-host/scripts/historical_fstab_transaction.py --fstab "$tmpdir/fstab"
cat "$tmpdir/fstab" # deve continuar sem novas entradas
rm -rf -- "$tmpdir"
```

Somente após revisão específica, ampliar o ensaio local para `--apply` e `findmnt --verify` real. Não rodar `--apply` contra `/etc/fstab` neste estágio; não executar `mount -a`.

## Próximos gates e evidências

1. Executar testes de unidade e registrar saída/ambiente. Criar teste de integração usando `findmnt` real sobre arquivo temporário e mountpoints descartáveis.
2. Revisar fstab real para aliases, destinos escapados e eventual configuração não padronizada antes de permitir escrita.
3. Revisar política de dono/permissões `uid=1000,gid=1000` para os dados históricos.
4. Planejar criação dos três diretórios separadamente; cada montagem precisa de autorização e verificação independente de UUID, driver, modo `ro` e ausência de dados ocultados.
5. Implementar Samba, usuários/Vault e firewall persistente somente depois.

Este registro será fonte do artigo técnico, mas só poderá ser descrito como resultado comprovado aquilo que tiver saída real arquivada.

## Complemento — ensaio real de findmnt em ambiente isolado

Em ambiente de execução separado do host, `findmnt from util-linux 2.41.5` aceitou o candidato com as três entradas históricas e mountpoints ausentes: **exit 0, 0 erros, 6 warnings** (três destinos ausentes e três UUIDs inacessíveis). Portanto, `--verify` com retorno zero **não comprova** que os dispositivos existem nem que podem ser montados. O preflight de UUID e tipo continua obrigatório.

Ao verificar fixture malformada contendo apenas `invalid-entry`, esta instalação do util-linux reportou erro de parse e encerrou com **SIGSEGV (exit 139)**. O comportamento deve ser investigado separadamente; não ocorreu no servidor de produção.

Commits posteriores adicionaram teste de integração isolado com `findmnt` real e exigência de `--fstab` explícito; `--apply --fstab /etc/fstab` agora é recusado pelo CLI. **Os novos testes automatizados ainda precisam ser executados em CI e no ambiente de desenvolvimento.** Nenhuma aplicação real foi autorizada.

## Evidência do operador — macOS, 2026-10-09

Após `git pull origin main` (fast-forward `aed5537..694d64e`), o operador executou `python3 -m unittest discover -s ansible/samba-host/tests -p 'test_*.py' -v`. Resultado informado: **Ran 10 tests in 0.004s; OK (skipped=2)**. Os oito testes de unidade passaram; dois testes de integração foram ignorados com motivo `util-linux findmnt unavailable`. Portanto, o teste com `findmnt` real **não foi executado no macOS**. Próxima evidência necessária: repetir a suíte em Linux descartável, sem alterar o servidor K3s.

## Evidência do operador — Debian 13 em Docker, 2026-10-09

Após a execução da suíte no contêiner Linux sugerido, o operador forneceu a saída com os **10 casos marcados `ok`**, incluindo `test_candidate_validation_with_real_findmnt` e `test_malformed_fixture_rejected_by_findmnt`. Rodapé fornecido: `Ran 10 tests in 0.023s`. A mensagem recebida não continha a linha final `OK`, mas nenhum teste apresentou `FAIL`, `ERROR` ou `skipped` na saída compartilhada. Esta é evidência de teste em contêiner, **não** de execução no host K3s. Os testes continuam sem verificar dispositivos reais, mountpoints do servidor ou recuperação de falhas após `os.replace`.

Próxima prioridade: testar falhas injetadas nas fases de backup, detecção de alterações concorrentes e persistência; manter a aplicação no host desabilitada até revisão e aprovação explícitas.
