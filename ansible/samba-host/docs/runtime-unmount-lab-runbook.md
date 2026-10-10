# Laboratório de desmontagem durante sessão SMB

**Estado:** proposta experimental; **não executar no host K3s** `guiosoft-info`.
**Ambiente obrigatório:** VM Linux descartável com snapshot, disco/FS de teste
sem dados reais e rede isolada. O resultado não autoriza implantação.

## Hipótese e risco

A verificação de mountpoint antes da publicação impede configurar um share
ausente naquele instante, mas não garante segurança se o volume for desmontado
com uma sessão SMB já estabelecida. O caminho do mountpoint pode continuar
existindo e revelar arquivos do filesystem subjacente. É necessário verificar
comportamento real de `smbd` para sessões existentes e novas.

## Critérios de isolamento

- VM descartável, nunca o nó K3s, discos físicos ou diretórios de dados reais.
- Snapshot anterior, rede host-only sem encaminhamento de portas, Samba
  instalado apenas na VM; cliente SMB separado, na mesma rede isolada.
- Compartilhamento exclusivo `/srv/samba-lab/share`; nenhum caminho sob
  `/mnt` do host de produção.
- Usuário Samba de laboratório sem privilégios administrativos.
- Não reutilizar senhas ou chaves de produção.
- Antes de qualquer unmount, confirmar por `findmnt --mountpoint` que o alvo
  é o filesystem descartável esperado. Se a identidade divergir, **abortar**.
- Não desmontar um volume montado por serviços reais. Evitar `umount -l` e
  `umount -f`: podem mascarar o comportamento que queremos observar.

## Cenários e evidências

1. **Controle sem mount:** diretório subjacente contém arquivo sentinela
   `UNDERLYING_DO_NOT_EXPOSE`. Com o filesystem ausente, um share desse
   caminho não pode ser publicado pelo mecanismo de seleção.
2. **Volume montado:** o filesystem de teste contém arquivo diferente,
   `MOUNTED_VISIBLE`. Um cliente autenticado acessa apenas este arquivo.
3. **Sessão aberta + desmontagem:** manter cliente SMB conectado, tentar
   desmontagem normal do filesystem e registrar se `umount` falha com
   `busy`. **Não forçar**. Se a desmontagem for possível, repetir listagem
   e leitura pela sessão existente e por nova sessão.
4. **Após indisponibilidade:** comprovar que o arquivo sentinela subjacente
   nunca é listado nem lido. Se for exposto, classificar como falha crítica.
5. **Retorno do volume:** testar publicação apenas após nova validação da
   identidade do filesystem; não confiar no estado antigo do relatório.

Registrar versão de kernel, Samba, configuração efetiva (`testparm -s`),
`findmnt` antes/depois, códigos de saída, logs do servidor e do cliente,
identificador de sessão, horários e hash dos arquivos sentinela.

## Critérios de aceitação

- Nenhuma leitura ou listagem do conteúdo subjacente em sessão existente
  ou nova, inclusive em condições de corrida.
- Ausência de volume não interrompe os demais compartilhamentos saudáveis.
- Um relatório de elegibilidade antigo não autoriza publicar volume ausente.
- Recuperação exige identidade correta de volume e revalidação.

**Atenção:** um teste que não reproduza exposição não comprova ausência de
corridas. Repetir com carga e considerar isolamento por namespace/mount
por instância; uma mera atualização de `smb.conf` ou `root preexec` não
protege necessariamente sessões abertas.

## Próxima implementação

Construir automação do laboratório **dentro da VM**, com modo `--dry-run`,
verificações explícitas de ambiente descartável e coleta de evidências.
Não incorporar o experimento ao playbook Ansible de produção.

## Planejador somente leitura — 2026-10-10

Adicionado `scripts/runtime_unmount_lab_plan.py --json`, sem modo de execução. Confere Linux, marcador `/etc/samba-lab-disposable-vm` (a criar **somente dentro da VM**, após inspeção manual), e presença de `smbd`, `smbclient`, `testparm`, `findmnt`, `mount`, `umount`. Mesmo com resultado `ready_for_manual_review: true`, não há autorização para executar o experimento automaticamente. O marcador é uma declaração humana, **não** prova técnica de isolamento. Quatro testes unitários simulam ferramentas e marcador; execução da suíte ainda pendente.

No host K3s, é seguro executar somente a inspeção, que deverá recusar prontidão por ausência de marcador e ferramentas:

```bash
python3 ansible/samba-host/scripts/runtime_unmount_lab_plan.py --json
```

Não criar o marcador no host K3s para contornar a checagem.

## Resultado do planejador no host K3s — 2026-10-10

O operador confirmou `Ran 47 tests in 0.065s` e `OK`. Execução de `runtime_unmount_lab_plan.py --json`: Linux, UID efetivo 1000, marcador `/etc/samba-lab-disposable-vm` ausente, `smbd` e `smbclient` ausentes; `testparm`, `findmnt`, `mount`, `umount` presentes. `ready_for_manual_review: false`, exit code `1` (esperado). A ferramenta não executou nenhuma ação de montagem ou serviço. O laboratório SMB com sessão ativa **continua não executado**; a proteção em runtime permanece sem validação.
