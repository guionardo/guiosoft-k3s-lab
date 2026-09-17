# De um servidor Debian a uma plataforma Kubernetes em casa

Há alguns dias comecei um projeto que parecia relativamente simples: transformar um servidor Debian que tenho em casa em um pequeno ambiente Kubernetes.

A ideia inicial era instalar K3s e usá-lo como laboratório para alguns assuntos com que trabalho no dia a dia: containers, observabilidade, GitOps, automação e aplicações distribuídas.

Mas coloquei uma regra no projeto: **o cluster não seria apenas um laboratório descartável. Eu colocaria aplicações reais nele.**

Isso mudou bastante as decisões.

Se existem aplicações que quero manter funcionando, instalar Kubernetes deixa de ser a parte mais interessante do problema.

Onde ficam os dados? Como acesso o cluster de outra máquina? Como publico uma aplicação sem abrir portas da minha rede? Onde ficam os secrets? O que acontece depois de um reboot? Como reproduzo a configuração do servidor? E, eventualmente, surge uma pergunta ainda mais desconfortável: se esse servidor morrer hoje, eu consigo reconstruir tudo?

O que começou como uma instalação de K3s acabou se tornando um exercício de engenharia de plataforma.

## Por que K3s?

O ambiente inicial é deliberadamente pequeno: um único servidor físico executando Debian 13.

Eu não queria começar construindo um cluster grande apenas para aprender a operar um cluster grande. O objetivo era reduzir o custo operacional inicial sem abandonar as primitivas do Kubernetes que eu queria estudar: Deployments, StatefulSets, Services, Ingress, PVCs, scheduling, observabilidade e GitOps.

Por isso comecei com K3s single-node.

Há uma limitação importante nessa decisão: duas réplicas de uma aplicação no mesmo servidor podem proteger contra a falha de um processo ou Pod, mas não contra a falha física da máquina. Isso não é alta disponibilidade do ponto de vista do host. No meu caso, essa limitação é intencional e faz parte do laboratório.

## O servidor já existia

Outro detalhe importante: o Debian não começou vazio.

Já havia serviços executando diretamente no host. Eu não queria que a adoção do Kubernetes se transformasse em uma migração big bang.

A arquitetura inicial, portanto, precisou aceitar dois mundos durante algum tempo:

```text
Internet
   |
Cloudflare
   |
Debian 13
   |-- serviços ainda no host
   |
   `-- K3s
       |-- Traefik
       |-- Services
       `-- workloads migrados
```

Cada aplicação poderia ser movida individualmente. A rota pública só seria alterada depois que o workload correspondente estivesse validado no K3s.

Essa estratégia trouxe uma propriedade que considero importante em qualquer migração: **rollback pequeno**.

## Rede: uma decisão simples que evita problemas futuros

O host também executava Docker. Portanto, antes de instalar o cluster, defini explicitamente as redes do K3s:

```text
Pod CIDR:     10.42.0.0/16
Service CIDR: 10.43.0.0/16
```

A intenção era mantê-las longe das bridges Docker existentes na faixa `172.x`.

É o tipo de decisão pouco interessante quando tudo funciona e extremamente interessante quando não foi tomada antes de um conflito de rotas.

Também configurei o kubeconfig para administração a partir de outra máquina da LAN. O endereço anunciado não poderia permanecer como `127.0.0.1` ou `localhost`: o cluster precisava ser administrável como infraestrutura, não apenas pelo terminal local do servidor.

## Por que manter Traefik se eu já tinha Cloudflare Tunnel?

Para publicar serviços, eu já utilizava Cloudflare Tunnel. Como o túnel é estabelecido de dentro para fora, não preciso abrir uma porta de entrada no roteador para cada aplicação.

A arquitetura alvo ficou assim:

```text
Internet
   |
Cloudflare DNS / Tunnel
   |
cloudflared no K3s
   |
Traefik
   |
Ingress
   |
Service
   |
Pod
```

Tecnicamente seria possível fazer o `cloudflared` apontar diretamente para alguns Services.

Decidi manter Traefik no caminho.

O motivo é arquitetural: quero que Ingress, middlewares e roteamento continuem sendo responsabilidade do Kubernetes. O Cloudflare é a entrada externa; não quero que ele se torne o catálogo interno da topologia de cada aplicação.

Isso também mantém aberta a possibilidade de acessar aplicações pela LAN independentemente do túnel.

Depois, o próprio `cloudflared`, que originalmente executava como serviço do host, foi migrado para dentro do K3s com duas réplicas. A instalação antiga foi preservada, porém desabilitada, como rollback durante a transição.

## Storage: configuração reconstruível não é dado persistente

No início usei o `local-path` provisioner do K3s. Para um cluster single-node ele é simples e suficiente para estudar PVCs e workloads persistentes.

Mas uma distinção começou a ficar importante:

**manifests podem ser reconstruídos; dados não necessariamente.**

No servidor atual, o storage do K3s foi organizado para manter os volumes locais em uma área conhecida do disco, separando configuração, dados persistentes e backups.

Essa separação posteriormente se tornaria fundamental quando comecei a testar Disaster Recovery de verdade.

## Infrastructure as Code, mas com responsabilidades separadas

Eu não queria uma ferramenta tentando controlar tudo.

Dividi as responsabilidades:

```text
Ansible
  -> Debian
  -> pacotes
  -> K3s
  -> diretórios
  -> firewall
  -> configuração do host

Terraform
  -> recursos externos
  -> Cloudflare
  -> storage off-host de backup

Kubernetes / Helm / Flux
  -> recursos dentro do cluster
  -> aplicações
  -> observabilidade
  -> configuração declarativa dos workloads
```

Essa separação acabou sendo bastante útil. O host físico possui um ciclo de vida diferente de um Deployment Kubernetes, e ambos possuem um ciclo diferente de um recurso externo.

Recentemente levei essa separação mais longe no Ansible: as variáveis comuns, de produção e de Disaster Recovery passaram a pertencer a grupos diferentes. O inventário de DR, por padrão, não herda automação de backup off-host nem `cloudflared` da produção.

## Firewall e redução da superfície do host

Instalar Kubernetes não deveria significar ignorar o sistema operacional abaixo dele.

O host recebeu uma política dedicada em nftables, persistida por systemd e validada depois de reboot. Serviços que estavam instalados mas não eram necessários — como listeners de NFS/RPC, PCP e Cockpit — foram desabilitados de forma reversível.

A ideia não era produzir um checklist genérico de hardening. Era reduzir a superfície efetivamente encontrada naquele servidor sem destruir a possibilidade de rollback.

## O primeiro resultado

Nesse ponto eu já tinha algo bem diferente do objetivo inicial.

O servidor continuava sendo uma máquina física em casa, mas agora havia uma plataforma com:

- K3s single-node;
- Traefik;
- Cloudflare Tunnel executando dentro do cluster;
- workloads reais;
- storage persistente conhecido;
- firewall persistente;
- configuração do host via Ansible;
- recursos externos declarativos via Terraform;
- administração remota pela LAN.

E foi justamente quando tudo começou a funcionar que apareceu a próxima pergunta:

**como eu sei que tudo isso está funcionando bem?**

`kubectl get pods` é uma excelente ferramenta, mas não é uma estratégia de observabilidade.

No próximo artigo vou mostrar como esse pequeno cluster ganhou métricas, logs e traces — e por que instalar Grafana foi apenas uma pequena parte do problema.

---

Projeto: `guionardo/guiosoft-k3s-lab`.
