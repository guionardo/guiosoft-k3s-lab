# Samba — ameaça de desmontagem em runtime (proposta, sem implantação)

Data: 2026-10-10. **Nenhuma alteração no host autorizada.**

## O problema

A geração seletiva do smb.conf impede a publicação inicial de shares inválidos,
mas não garante proteção se um filesystem for desmontado depois do reload.
O caminho /mnt/... continua existindo no filesystem pai. Um processo Samba com
permissão suficiente poderia servir dados desse diretório, e conexões existentes
não são automaticamente encerradas por um novo preflight.

## Defesa em camadas proposta

**Camada A — mountpoint subjacente inacessível:** antes de montar cada volume,
garantir que o diretório de montagem *no filesystem pai* pertença a root,
tenha modo restritivo (por exemplo 0700, ou 000 conforme testes) e não
contenha dados. Quando o volume está montado, permissões do diretório raiz
do volume passam a valer. **Não executar chmod no mountpoint enquanto o
volume estiver montado**, pois alteraria permissões do filesystem montado.
Esta é uma proposta para manutenção controlada, com backup e testes; não
aplicar sem autorização. O Samba opera com processos privilegiados e pode
possuir acesso além do usuário autenticado: testar de fato o acesso via SMB.

**Camada B — publicação inicial por share:** renderizar somente shares
validados, com UUID, fstype e opções conferidos. Nunca publicar diretório
subjacente por fallback. Validar com testparm antes de trocar configuração.

**Camada C — runtime:** estudar eventos systemd/udev para detectar perda
de mount e retirar o share da configuração com reload controlado. Essa
detecção é complementar, pois existe uma janela de corrida entre perda
de montagem e reload. Não depender de polling como barreira principal.

**Camada D — integração:** teste de laboratório com cliente SMB conectado,
arquivos abertos, unmount forçado/inesperado e reconexão. A política só
será considerada segura se a sessão não conseguir listar nem gravar
no diretório subjacente durante ou após o evento.

## Alternativas e restrições

- `RequiresMountsFor=` aplicado diretamente ao serviço `smbd` pode tornar
  **todo** o Samba dependente dos sete volumes, contrariando disponibilidade
  parcial. Não usar sem desenho por instância/serviço.
- `root preexec` ou `preexec` por share podem checar uma nova conexão,
  mas não protegem uma sessão já estabelecida contra unmount posterior.
- `vfs objects`, ACLs e permissões Samba não substituem verificação da
  identidade do filesystem e teste de unmount.
- Montagens bind e caminhos via symlink devem ser tratados como não
  autorizados até testes específicos.

## Plano de teste, sem tocar nos discos reais

1. Criar loop device com filesystem descartável e mountpoint isolado em
   laboratório (exige privilégio **somente em ambiente de teste autorizado**).
2. Configurar share temporário de Samba separado do serviço real.
3. Testar leitura e escrita legítimas com volume presente.
4. Simular perda de montagem e verificar listagem, abertura de arquivos,
   criação de arquivos e reconexão.
5. Medir tempo de despublicação, logs e comportamento de sessões existentes.
6. Repetir para filesystem NTFS e ext4, e para montagem somente leitura.
7. Registrar evidências antes de qualquer integração ao serviço real.

## Critério de aprovação

Nenhuma publicação em produção enquanto não houver uma barreira
verificada contra acesso ao diretório subjacente em runtime, mecanismo de
disponibilidade parcial, credenciais e firewall aprovados, e rollback testado.

## Preparação segura do laboratório — 2026-10-10

Adicionado `scripts/runtime_lab_preflight.py` (commit `9259e2d`): verifica **somente** a presença de `unshare`, `mount`, `umount`, `losetup`, `mkfs.ext4`, `smbd`, `testparm`, `smbclient` e `findmnt`. Não cria namespaces nem altera estado. Exemplo, a partir da raiz do repositório: `python3 ansible/samba-host/scripts/runtime_lab_preflight.py --json`. Exit code `1` significa pré-requisitos incompletos (ou plataforma não Linux), não que seja necessário instalar pacotes imediatamente. Mesmo exit code `0` não confirma privilégios, isolamento ou segurança de testes. **Nenhum script de unmount foi habilitado.** Antes de um teste real, aprovar ambiente separado (preferencialmente VM descartável) e demonstrar que nenhum mount do host é alcançável ou afetado.
