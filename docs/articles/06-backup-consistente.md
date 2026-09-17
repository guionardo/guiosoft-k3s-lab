# O problema dos backups consistentes em Kubernetes

Depois de três rehearsals de Disaster Recovery no meu homelab K3s, eu já conseguia reconstruir o control plane, restaurar PersistentVolumes, carregar imagens OCI sem Internet e iniciar workloads em outra máquina.

Mas ainda havia um problema conceitual.

Eu possuía um backup do control plane e um backup dos volumes.

**Isso não significava que eu possuía um estado consistente do sistema.**

## Dois backups corretos podem formar um restore incorreto

Imagine esta sequência:

```text
10:00 backup do control plane
10:10 aplicação continua escrevendo
10:20 backup dos volumes
```

Os dois backups podem estar tecnicamente íntegros.

Mesmo assim, eles representam instantes diferentes.

Dependendo da aplicação, o Kubernetes pode acreditar em um estado enquanto o volume persistente contém outro.

No meu laboratório, essa diferença apareceu de forma prática quando Tempo precisou lidar com um bloco WAL incompleto durante um restore anterior. O workload conseguiu se recuperar, mas aquilo era evidência suficiente para eu parar de tratar uma cópia de filesystem como automaticamente consistente.

## A ideia: bounded-consistency recovery set

Eu não precisava construir um snapshot distribuído atomicamente perfeito para esse laboratório.

Precisava de algo mais simples e verificável:

1. parar temporariamente os writers persistentes;
2. capturar control plane e PVs enquanto eles permanecem parados;
3. registrar exatamente quais snapshots pertencem ao conjunto;
4. restaurar os writers imediatamente;
5. verificar independentemente os artefatos.

Passei a chamar isso de **bounded-consistency recovery set**.

A palavra “bounded” é importante. Eu não estou afirmando atomicidade distribuída. Estou afirmando que conheço e consigo medir o intervalo durante o qual os writers permaneceram quiesced enquanto os dois lados do backup foram capturados.

## Quiesce sem brigar com operadores

Grafana, Tempo e Loki são StatefulSets que podem ser reduzidos de forma controlada.

Prometheus trouxe uma nuance: seu StatefulSet é gerenciado pelo Prometheus Operator.

Escalar diretamente o StatefulSet seria lutar contra o reconciliador.

A solução foi alterar temporariamente o `spec.replicas` do recurso Prometheus e deixar o próprio Operator produzir o estado desejado.

Essa pequena diferença resume uma regra importante de Kubernetes: **quando existe um controller responsável por um recurso, converse com o controller, não com o efeito gerado por ele.**

O processo também é fail-closed. Não force-deleto Pods writers de produção para conseguir um backup. Se o quiesce gracioso não ocorrer dentro do limite, o backup consistente falha.

## Falhar antes de interromper writers

Outro cuidado foi mover problemas previsíveis para antes da janela de interrupção.

O orquestrador valida API K3s, ferramentas e principalmente o repositório Restic/R2 antes de começar o quiesce.

Se o storage off-host estiver indisponível ou houver um problema conhecido no repositório, não faz sentido parar aplicações apenas para descobrir isso depois.

Operações caras de retenção, prune e integridade também foram movidas para depois que os writers já voltaram.

O objetivo é manter a janela crítica limitada ao que realmente exige consistência.

## Identidade exata dos artefatos

Uma das mudanças mais importantes foi abandonar a ideia de “restaure o backup mais recente”.

O recovery set registra IDs e timestamps exatos.

Para o control plane, o script cria um novo archive SQLite/token, verifica o archive localmente, envia exatamente aquele arquivo e checksum ao R2 e depois resolve o snapshot Restic que contém aquele archive específico.

Para os PVs, o snapshot Restic criado durante a mesma janela também tem ID e timestamp registrados.

O primeiro recovery set completo ficou assim:

```text
backup_set_id=20260916T114220Z

quiesced_at=2026-09-16T11:42:34Z

control_plane_snapshot=
6709a96774a79ded9e3435591074d9445d9f814127b0b1a4ba3041d6a39f3882

pv_snapshot=
1830fedfe1c6f293cef2eb971f390f28fd761ba1e929c75b9e06c2a007da190e

completed_backup_window_at=2026-09-16T11:43:38Z
consistency_window_seconds=64
writers_restored_at=2026-09-16T11:44:21Z
result=PASS
```

A janela medida entre quiesce e conclusão das duas capturas foi de **64 segundos**.

## Verificar o próprio verificador

O orquestrador terminar com `PASS` ainda não era evidência suficiente.

Criei um verificador independente que reabre o repositório off-host e confirma:

- metadata do recovery set em PASS;
- existência dos dois snapshot IDs exatos;
- timestamp real dos snapshots;
- presença do archive de control plane registrado dentro do snapshot correto;
- presença do root esperado dos volumes no snapshot PV;
- timestamps dentro da janela registrada.

Essa etapa também passou.

A diferença é sutil, mas importante: o mesmo processo que produz um artefato não deveria ser a única autoridade dizendo que o artefato está correto.

## Concorrência de backups também é estado

O servidor continua executando o backup diário normal.

O recovery set consistente é semanal porque provoca uma pequena janela de quiesce.

Os dois fluxos compartilham o mesmo lock:

```text
/run/lock/guiosoft-k3s-backup.lock
```

O wrapper semanal mantém o lock não apenas durante a captura, mas também durante verificação e manutenção Restic posterior. Assim outro processo de backup não entra no repositório no meio da sequência e altera o contexto que estou verificando.

## Do recovery set para um bundle portátil

Depois de criar uma identidade formal para o par control-plane/PV, o bundle de DR também precisou mudar.

Antes, um builder poderia selecionar independentemente um snapshot recente de control plane e um snapshot recente de PV. Isso reintroduziria exatamente o problema que eu acabara de resolver.

O bundle v2 agora nasce de um `backup_set_id` específico.

O materializador restaura os snapshot IDs exatos, verifica timestamps, cruza metadata do PV com o mesmo backup set e só então monta o artefato offline contendo:

```text
control plane
persistent volumes
offline OCI images
recovery tooling
recovery-set metadata
checksums
```

O primeiro bundle portátil v2 foi construído a partir do recovery set de 64 segundos e passou sua verificação completa.

## O que mudou na minha definição de backup

No começo do projeto, backup significava algo próximo de:

```text
arquivo existe fora do servidor
```

Depois dos rehearsals, a definição ficou bem mais exigente:

```text
artefato existe
+ checksum confere
+ snapshot exato é conhecido
+ timestamp é conhecido
+ relação CP/PV é conhecida
+ restore foi exercitado
+ imagens estão disponíveis offline
+ tooling está disponível offline
+ secrets possuem recuperação independente
+ pós-condições são verificadas
```

Isso obviamente é mais trabalho.

Mas também transforma backup de uma esperança em uma propriedade testável do sistema.

## Onde o projeto está agora

O homelab que começou com “vamos instalar K3s” hoje possui:

- infraestrutura do host declarada com Ansible;
- recursos externos com Terraform;
- workloads reconciliados por Flux;
- secrets cifrados com SOPS + age;
- métricas, logs e traces correlacionados;
- backup off-host com Restic/R2;
- rehearsals completos em uma segunda máquina;
- recovery OCI offline;
- RTO medido;
- recovery sets com consistência limitada e mensurada;
- bundle de DR portátil ligado a snapshots exatos;
- guards fail-closed para operações destrutivas;
- separação declarativa entre produção e DR.

Ainda há coisas para melhorar, e novos rehearsals certamente vão encontrar outras suposições erradas.

Hoje considero isso uma característica do projeto, não um defeito.

A parte mais interessante do laboratório deixou de ser o Kubernetes em si. Passou a ser usar um ambiente pequeno para exercitar as mesmas perguntas que aparecem em sistemas maiores:

**o estado está declarado? é observável? é recuperável? conseguimos provar?**

É essa última pergunta que pretendo continuar usando como critério para as próximas etapas.

---

Projeto: `guionardo/guiosoft-k3s-lab`.
