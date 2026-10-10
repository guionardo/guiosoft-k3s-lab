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

## Testes adicionais de falha e concorrência — pendentes de execução

Foram adicionados quatro testes unitários com injeção de falhas: edição concorrente do conteúdo, substituição concorrente do inode, erro ao criar backup e erro no `os.replace`. Todos usam `TemporaryDirectory`, sem alterar o sistema real. **Estes quatro casos ainda não possuem evidência de execução.**

A implementação atual ainda possui uma janela entre a última conferência e `os.replace`: o `flock` só coordena processos que utilizem o mesmo lock. Um editor externo não cooperativo pode escrever nesse intervalo. A falha de `fsync` do diretório após `os.replace` também pode deixar o novo arquivo aplicado apesar de retorno de erro. Portanto, **não existe garantia de rollback após commit**, e a etapa Ansible de escrita continua bloqueada.

## Evidência do operador — macOS, suíte ampliada, 2026-10-09

Após os commits de testes de concorrência e falhas, o operador forneceu a saída de `unittest discover`: **Ran 14 tests in 0.028s**. Doze casos reportaram `ok`, inclusive os quatro cenários novos de falha e concorrência. Dois casos dependentes de `findmnt` foram ignorados (`util-linux findmnt unavailable`). A saída compartilhada não inclui a linha final `OK`, mas não mostra falhas ou erros. A suíte ampliada ainda precisa ser repetida em Linux; não houve execução no servidor K3s.

## Evidência do operador — Debian 13 em Docker, suíte ampliada, 2026-10-09

O operador forneceu a saída da execução Linux com **14 testes marcados `ok`**, incluindo os dois testes reais de `findmnt` e os quatro novos testes de concorrência/injeção de falhas. Rodapé compartilhado: `Ran 14 tests in 0.013s`. Nenhum `skipped`, `FAIL` ou `ERROR` aparece na saída recebida; a linha final `OK` não foi incluída no trecho enviado. Evidência restrita ao contêiner de teste, não ao host K3s. Permanecem pendentes cenários de falha após `os.replace`, preservação de metadados estendidos e análise da janela de concorrência com editores não cooperativos.

## Estado pós-commit — implementação pendente de testes (2026-10-10)

Foi introduzida a exceção `CommitDurabilityUncertain`: se `os.replace` já concluiu e a abertura ou `fsync` do diretório falhar, a operação informa `APPLIED_DURABILITY_UNCERTAIN` com caminho do backup e hash do candidato. O backup é preservado; não há rollback automático. Um teste novo injeta erro no terceiro `os.fsync` (após sincronização de candidato e backup), verificando que o destino já contém o bloco gerenciado e que o backup mantém o original. **Ainda não executado pelo operador.**

A mensagem de erro representa persistência não confirmada, não corrupção comprovada. A ferramenta continua incapaz de impedir escritores externos não cooperativos, e o fluxo Ansible de aplicação permanece desabilitado. O bloqueio de escrita em `/etc/fstab` está no CLI; a função interna `execute` ainda deve ser considerada interface de teste, não interface pública de operação.

## Evidência do operador — macOS, falha pós-commit, 2026-10-10

A execução da suíte ampliada foi compartilhada com **15 casos**: 13 marcados `ok` e dois ignorados por ausência do `util-linux findmnt`. Dentre os aprovados está `test_directory_fsync_failure_reports_applied_uncertain_and_retains_backup`. Rodapé compartilhado: `Ran 15 tests in 0.010s`. Não houve falhas ou erros na saída apresentada. A linha final `OK` não constava do trecho recebido. A evidência é de simulação local e **não comprova durabilidade em falhas reais de energia/disco**. Pendente: executar os 15 testes em Debian 13 isolado.

## Evidência do operador — host guiosoft-info, 2026-10-10

O operador executou diretamente no host `guiosoft-info` o comando `python3 -m unittest discover -s ansible/samba-host/tests -p 'test_*.py' -v`. Resultado integral informado: **Ran 15 tests in 0.035s; OK**. Todos os 15 testes, incluindo os dois com `findmnt` real e o cenário de `fsync` pós-substituição, passaram, sem skips. Os testes usam `TemporaryDirectory` e injeção de falhas: a execução não montou volumes, não editou `/etc/fstab` e não aplicou o papel Ansible. O comando foi executado pelo operador, não pelo assistente. Ainda pendem a revisão de metadados e os controles de concorrência antes de qualquer autorização de aplicação.
