# Alternativas de isolamento de compartilhamentos Samba

**Estado:** análise arquitetural, não implantada. Ambiente de produção: nó K3s
`guiosoft-info`. A proteção contra unmount durante sessões SMB ativas **não
foi demonstrada**. Nenhuma alternativa abaixo está aprovada para implantação.

## Invariantes de segurança

1. Um volume ausente nunca é publicado pelo processo de configuração.
2. Após a perda de um volume, arquivos do diretório subjacente não podem ser
   listados nem lidos, inclusive em sessões SMB previamente abertas.
3. A indisponibilidade de um volume não deve interromper os demais shares.
4. Reaparecimento exige revalidação de identidade (UUID, filesystem, opções).
5. O mecanismo deve resistir a eventos concorrentes e não depender somente
   da velocidade de um observador ou de um reload do serviço.
6. Falhas no mecanismo devem resultar em negação de acesso, não publicação
   de diretórios subjacentes.

## Comparação preliminar

| Alternativa | Sessão SMB aberta | Disponibilidade parcial | Complexidade | Situação |
| --- | --- | --- | --- | --- |
| Preflight + configuração seletiva | Não protege após unmount | Sim no startup | Baixa | Implementada offline |
| Inotify/udev/systemd + reload | Janela de corrida; reload não revoga necessariamente sessão | Possível | Média | Não suficiente isoladamente |
| `root preexec` por share | Só protege abertura de novas conexões; sessão existente não coberta | Sim | Baixa/média | Defesa adicional, não principal |
| Permissões no mountpoint subjacente | Pode ajudar, mas `smbd` privilegiado e semântica de acesso exigem teste | Sim | Média | Não comprovada |
| `RequiresMountsFor` global em `smbd` | Não garante bloqueio de sessões após perda e pode afetar serviço inteiro | Não, se acoplar todos volumes | Média | Evitar acoplamento global |
| Instância Samba isolada por volume, com namespace/mount próprio | Potencial isolamento de falha; não garante sozinho que caminho subjacente fique inacessível | Sim, em princípio | Alta | Candidata a experimento |
| Compartilhamento via ponto de montagem dedicado com barreira de acesso independente do volume | Pode impedir fallback se barreira for garantida no kernel; desenho exato depende de testes | Sim, em princípio | Alta | Candidata a experimento |

## Hipóteses que exigem prova

- Uma montagem ativa normalmente impede `umount` se há referências em uso,
  mas clientes SMB e `smbd` podem não manter referências suficientes.
  Registrar retorno de `umount` e verificar acesso nas duas situações.
- `umount -l` altera a semântica e pode manter referências antigas; não usar
  como prova de segurança do desenho normal.
- Um bind mount e um mount namespace não são, por si sós, uma barreira
  obrigatória: é preciso demonstrar que nenhum caminho alternativo chega ao
  diretório subjacente.
- Negação por permissões Unix pode não equivaler a negação efetiva para um
  daemon que inicia privilegiado. Testar com cliente SMB real.
- A seleção por relatório JSON não comprova frescor: um volume pode sumir
  entre a inspeção e a publicação. Essa condição deve ser modelada e testada.

## Experimentos prioritários na VM descartável

1. **Baseline de exposição:** montar filesystem descartável sobre diretório
   com sentinela; abrir cliente; tentar unmount normal; medir visibilidade.
2. **Barreira de diretório:** repetir com permissões do diretório subjacente
   restritivas, testando sessões antigas e novas sem assumir segurança.
3. **Namespace/instância por volume:** comparar separação de processos,
   visibilidade dos mounts e comportamento quando volume desaparece.
4. **Condição de corrida:** alternar disponibilidade do volume de teste
   enquanto o cliente tenta abrir e listar arquivos; registrar qualquer
   acesso à sentinela como falha crítica.
5. **Recuperação e parcialidade:** manter um segundo share saudável e verificar
   sua disponibilidade durante falhas do primeiro.

## Critério para escolher a arquitetura

A alternativa só avança se impedir leitura/listagem do diretório subjacente
em todas as observações, preservar outros shares, permitir recuperação
controlada, e tiver operação/monitoramento/rollback documentados. Mesmo
resultados positivos no laboratório não eliminam todas as corridas; o desenho
precisa de justificativa de segurança independente do tempo de reação.

## Decisão provisória

Manter **preflight + renderização seletiva** apenas como controle de publicação.
Não integrar a configuração gerada ao `smbd` de produção. Priorizar
experimentos com barreira de acesso e isolamento por volume na VM descartável.
A escolha final permanece **em aberto**.
