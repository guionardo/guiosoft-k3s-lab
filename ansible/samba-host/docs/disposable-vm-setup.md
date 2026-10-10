# Preparação da VM descartável para o laboratório Samba

**Estado:** procedimento proposto; não executado. **Não executar no nó K3s
`guiosoft-info`.** Este guia é destinado exclusivamente a uma VM de testes
sem acesso a dados reais, após snapshot e inspeção dos dispositivos.

## Topologia

- VM Debian 13 descartável (servidor SMB), rede host-only ou rede virtual
  privada isolada, sem bridge para LAN de produção.
- Cliente SMB em segunda VM descartável na mesma rede isolada.
- Dois discos virtuais adicionais, sem dados reais, identificados por
  `/dev/disk/by-id/` ou UUID após inspeção. Nunca presumir nomes `/dev/sdb`.
- Share `volatile`: volume descartável sujeito ao unmount normal.
- Share `healthy`: volume independente que deve continuar acessível.
- Nenhuma montagem da máquina física compartilhada com a VM (sem passthrough,
  virtiofs ou pastas compartilhadas).

## Pré-condições manuais

1. Criar snapshot e verificar que o host não é o nó K3s.
2. Confirmar a rede virtual isolada e a ausência de rotas para a LAN.
3. Confirmar, pelo hypervisor, que os dois discos são novos e descartáveis.
4. Registrar `hostnamectl`, `uname -a`, `lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,UUID,MOUNTPOINTS`,
   `findmnt`, `ip -br addr` e `ip route`.
5. Instalar `samba`, `smbclient` e `util-linux` **somente na VM**:
   `sudo apt-get update && sudo apt-get install samba smbclient util-linux`.
6. Criar o marcador `/etc/samba-lab-disposable-vm` **somente na VM**,
   após verificar manualmente os itens anteriores.
7. Executar o planejador de somente leitura:
   `python3 ansible/samba-host/scripts/runtime_unmount_lab_plan.py --json`.
   Resultado `ready_for_manual_review: true` não executa o experimento
   nem comprova isolamento.

## Layout proposto (apenas na VM)

```text
/srv/samba-lab/
  volatile/             # diretório subjacente com UNDERLYING_DO_NOT_EXPOSE
                        # coberto pelo volume virtual de teste
  healthy/              # segundo volume virtual independente
/var/tmp/samba-lab-evidence/
  environment.json
  before/
  during/
  after/
  evidence.json
```

O arquivo sentinela subjacente deve existir **antes** da montagem do disco
`volatile`; seu conteúdo deve ser um texto inofensivo e único, jamais dados
reais. O volume montado deve conter `MOUNTED_VISIBLE` e o segundo
`HEALTHY_VISIBLE`. Nunca executar `mkfs` sem confirmar a identidade dos
discos virtuais no hypervisor e no guest.

## Sequência de observação (manual, sem comandos destrutivos automatizados)

1. Configurar Samba **somente na VM**, com usuário de teste e compartilhamentos
   apontando para os dois diretórios. Registrar saída de `testparm -s`.
2. Registrar `findmnt --target /srv/samba-lab/volatile` e UUID do volume.
3. Abrir uma sessão autenticada do cliente SMB e listar/ler
   `MOUNTED_VISIBLE`. Confirmar que a sentinela subjacente não aparece.
4. Manter a sessão aberta e, na VM servidor, tentar **apenas**
   `umount /srv/samba-lab/volatile` (sem `-f` ou `-l`).
   Se retornar busy, registrar e **não forçar**.
5. Caso a desmontagem normal ocorra, repetir listagem/leitura na sessão
   existente e em uma sessão nova. Qualquer exposição de
   `UNDERLYING_DO_NOT_EXPOSE` é falha crítica.
6. Durante toda a sequência, testar `healthy` a partir do cliente.
7. Remontar **somente o volume de teste identificado**, revalidar UUID,
   filesystem e opções antes de considerar recuperação.
8. Guardar logs, versões, timestamps, códigos de saída e hashes dos
   arquivos de evidência. Preencher `evidence.json` segundo
   `runtime-unmount-lab-runbook.md` e executar o avaliador offline.

## Critérios de interrupção

Interromper imediatamente se o ambiente tiver acesso a discos reais, rede de
produção ou diretórios compartilhados do host; se o UUID do volume não
corresponder ao esperado; se a sentinela aparecer para o cliente SMB; ou se
qualquer etapa exigir `umount -f`, `umount -l` ou alteração de serviços
do nó K3s.

## Limites

Este documento **não contém** scripts de formatação, montagem ou desmontagem
automática. O laboratório ainda não foi executado. Um resultado
`PASS_OBSERVED` indica apenas que as observações registradas satisfazem
os critérios; não comprova ausência de corridas. A escolha da arquitetura
de proteção permanece aberta.

## Ambiente escolhido: Mac com UTM — 2026-10-10

O operador informou que não possui Proxmox e escolheu executar o
laboratório no Mac. Topologia alvo: duas VMs Debian 13 descartáveis no UTM,
uma para Samba e dois discos virtuais de dados; outra para cliente SMB.
Dimensionamento inicial sugerido: 2 GiB RAM e 15 GiB de disco de sistema por
VM; dois discos adicionais de 1 GiB somente na VM Samba. Ajustar segundo
os recursos disponíveis no Mac.

**Antes de criar as VMs:** identificar se o Mac usa Apple Silicon ou Intel,
pois a arquitetura da imagem Debian e as opções de virtualização do UTM
dependem disso. A rede deve ser comprovadamente privada entre as VMs, sem
bridge com a LAN; não assumir que os modos de rede do UTM são equivalentes.
Não anexar discos físicos, pastas do host, virtiofs ou passthrough. Não criar
discos virtuais nem executar comandos de formatação/desmontagem até confirmar
o hypervisor, a arquitetura e o isolamento. O nó K3s permanece fora do
laboratório.

## Arquitetura do Mac confirmada — 2026-10-10

O operador confirmou Mac com chip **M4**, arquitetura Apple Silicon
(`arm64`). Para evitar emulação x86, selecionar imagem **Debian 13 arm64**
e modo **Virtualize → Linux** no UTM, com backend disponível na versão
instalada. Verificar os modos de rede oferecidos pelo UTM antes de declarar
a rede isolada; não usar bridge com LAN de produção. Manter compartilhamento
de pastas e passthrough de discos físicos desativados. Nenhuma VM foi
criada ou validada por esta atualização documental.

## Primeira inspeção da VM UTM — 2026-10-10

O operador informou layout do guest: `vda1` 16 MiB, `vda2` 863 MiB
vfat em `/boot/efi`, `vda3` 13,4 GiB ext3 em `/`, `vda4` 805 MiB
swap; `vdb` e `vdc` com 1 GiB cada, sem partições ou filesystem
apresentados na saída. Interface `enp0s1` em `192.168.64.3/24`,
rota default via `192.168.64.1`. LAN física `192.168.88.0/24`.

**Não declarar isolamento validado:** a faixa `192.168.64.0/24` com
gateway sugere rede UTM compartilhada/NAT; NAT pode permitir tráfego
iniciado pela VM em direção à LAN real. Próxima etapa: identificar modo
de rede no UTM e migrar para rede privada sem bridge/rota à LAN antes
de qualquer experimento. Também confirmar arquitetura com `uname -m`,
ainda não fornecido, e identidade dos discos virtuais no hypervisor e
guest antes de `mkfs`.
