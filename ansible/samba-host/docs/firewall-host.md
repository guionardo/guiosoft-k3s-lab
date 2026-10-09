# Integração do Samba ao firewall do host (diagnóstico de 2026-10-09)

**Estado: proposta não aplicada.** O host Debian 13/K3s usa a tabela `inet guiosoft_host`, mantida em `/etc/nftables.d/guiosoft-host.nft` pelo serviço habilitado `guiosoft-host-firewall.service`. O serviço `nftables.service` padrão está desabilitado/inativo. Não o habilitar nem executar `nft flush ruleset`.

## Regra existente

```nft
iifname "enp2s0" ip saddr 192.168.88.0/24 tcp dport { 22, 80, 443, 6443 } accept
```

Regra **proposta**, a ser aplicada somente quando `smbd` estiver configurado e testado:

```nft
iifname "enp2s0" ip saddr 192.168.88.0/24 tcp dport { 22, 80, 443, 445, 6443 } accept
```

Preservar loopback, established/related, ICMP/ICMPv6, DHCP, mDNS, `cni0`, `flannel.1`, drop final e todas as outras tabelas K3s.

## Risco identificado no serviço atual

`ExecStart` e `ExecReload` executam `nft delete table inet guiosoft_host` antes de carregar o arquivo. Caso o carregamento falhe, a tabela de proteção do host poderá permanecer ausente. **Não utilizar reload desse serviço como mecanismo de deploy sem corrigir o procedimento**. `nft -c -f` verifica a sintaxe, mas não garante ausência de falhas de execução nem preserva sozinho o acesso SSH.

## Requisitos para implementação futura

1. Ler e comparar a configuração autoritativa atual; recusar alteração se a estrutura esperada divergir.
2. Gerar uma cópia completa com somente TCP 445 adicionado à regra LAN.
3. Validar a configuração gerada, preparar backup e mecanismo de recuperação fora da sessão SSH.
4. Planejar substituição atômica apenas da tabela `guiosoft_host` em uma única transação nftables; nunca remover a tabela antes de confirmar a substituição.
5. Verificar conectividade SSH, portas esperadas, restrição LAN e saúde do K3s; documentar rollback.
6. Não publicar SMB na WAN nem nas interfaces de pods por padrão; avaliar a regra `iifname "cni0"/"flannel.1" accept` em uma revisão separada de segmentação.
7. A implantação deve exigir aprovação explícita e continuar bloqueada no playbook até a implementação completa.

Fonte: saída de `cat /etc/nftables.d/guiosoft-host.nft`, `systemctl cat guiosoft-host-firewall.service` e `systemctl is-enabled` fornecida pelo operador.
