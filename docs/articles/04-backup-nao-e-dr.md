# Backup não significa Disaster Recovery

Eu tinha backups do meu cluster Kubernetes.

Então resolvi fazer a pergunta que normalmente é fácil adiar:

**consigo realmente restaurá-los?**

A resposta curta foi: não tão facilmente quanto parecia.

Essa talvez tenha sido a etapa mais valiosa do meu homelab K3s até agora, porque o exercício deixou de ser sobre criar backup e passou a ser sobre produzir um sistema executável em outra máquina.

## Dois níveis de recuperação

Comecei separando o problema em duas partes.

O primeiro nível é o control plane: restaurar o datastore SQLite do K3s e o server token.

O segundo é o que passei a chamar de Full DR:

```text
control plane
+ persistent volumes
+ imagens OCI disponíveis offline
+ workloads executáveis
```

Essa distinção parece óbvia depois de escrita. Antes do teste, é fácil pensar no backup do cluster como uma coisa única.

Não é.

## O alvo de DR precisa ser perigoso por design — e seguro por controle

Usei uma segunda máquina Debian 13, `guionote-hp`, como alvo de recuperação.

A produção continuou funcionando no servidor `guiosoft-info`.

Restaurar o datastore de produção em outra máquina traz um risco importante: os workloads restaurados podem acreditar que estão em produção e tentar acessar serviços externos.

Por isso o alvo recebe uma barreira independente de nftables antes do restore.

Ela permite loopback, LAN e redes internas do Kubernetes, mas rejeita o restante do tráfego IPv4/IPv6 de saída e forwarding.

Em outras palavras: eu quero que o cluster restaurado funcione o suficiente para ser examinado, mas não quero que ele converse com a Internet.

Além disso, os scripts destrutivos exigem marker de DR, recusam hostname/IP de produção e exigem confirmações explícitas.

Recentemente o reset do alvo ganhou ainda um modo de preflight não destrutivo. Eu validei o mesmo script contra produção e ele recusou a execução antes de qualquer alteração.

## O primeiro problema: datastore não vive sozinho

Uma das primeiras descobertas foi que restaurar apenas banco e token enquanto se preservavam materiais TLS/credentials do cluster limpo podia produzir incompatibilidade de bootstrap.

A estratégia foi alterada: durante o restore, os materiais do target são preservados em uma área de segurança, o datastore é restaurado e o K3s reconstrói o bootstrap a partir do estado recuperado.

Esse é exatamente o tipo de detalhe que um arquivo de backup existente não revela.

Só aparece quando alguém tenta inicializar o sistema restaurado.

## O segundo problema: PersistentVolumes locais lembram do servidor antigo

Meu cluster usa `local-path` em single-node.

Depois de restaurar os dados físicos dos volumes no host DR, ainda havia um problema Kubernetes: os PVs recuperados possuíam node affinity para o hostname de produção e paths locais apontando para o storage da produção.

Esses campos não podem simplesmente ser corrigidos com um patch comum.

A transação que funcionou foi mais cuidadosa:

1. manter writers recuperados em zero réplicas;
2. mudar reclaim policy para `Retain`;
3. preservar manifests;
4. remover PVC/PV antigos na ordem correta;
5. recriar os PVs com path do DR e affinity para o futuro hostname DR;
6. recriar PVCs pre-bound por `volumeName`;
7. confirmar novos UIDs/claimRefs e estado `Bound`;
8. somente depois ativar o node e os workloads.

Também apareceu outro detalhe: Pods restaurados em `Terminating` ainda podiam referenciar PVCs protegidos. A solução segura não era arrancar finalizers indiscriminadamente, mas identificar e remover somente os Pods que bloqueavam a transação.

## O terceiro problema: o cluster restaurado começa sem o node DR

Durante o restore isolado, o K3s precisa iniciar em modo agentless (`disable-agent:true`).

Nesse momento, a API pode conter apenas o Node restaurado da produção. O novo node ainda não existe.

Isso significa que o remapeamento de PV precisa aceitar node affinity para um **hostname futuro**. O objeto Node será registrado apenas quando o agent for ativado depois.

Um dos meus scripts inicialmente assumia o contrário. O rehearsal encontrou a suposição e ela virou um novo invariante da automação.

## O quarto problema: imagem listada não é necessariamente imagem recuperável

Eu também descobri que não deveria tratar o content store do containerd da produção como backup de imagens.

Durante o rehearsal, algumas imagens que apareciam como disponíveis/running não puderam ser exportadas porque blobs referenciados não estavam presentes da forma esperada.

A solução foi criar previamente um kit OCI específico para a plataforma `linux/amd64`, contendo as imagens necessárias e checksums gerados na origem.

No DR, essas imagens são colocadas no diretório nativo de preload do K3s:

```text
/var/lib/rancher/k3s/agent/images/
```

E a validação é feita pelo CRI, não apenas pela listagem do `ctr`.

Isso tornou o recovery independente de registries externos — algo obrigatório porque o alvo permanece sem Internet.

## GitHub também desaparece durante o desastre

Outro aprendizado simples: se a estratégia de segurança do DR bloqueia a Internet, o runbook não pode dizer “agora faça git pull”.

O recovery kit passou a carregar uma cópia autocontida e versionada dos scripts necessários, checksums, imagens OCI e material cifrado de recuperação.

A chave privada age e demais credenciais continuam fora do Git e precisam de recuperação independente.

Essa restrição mudou a maneira como passei a pensar sobre GitOps:

**Git é uma excelente fonte de verdade, mas não deve ser a única mídia necessária para recuperar o sistema.**

## E os workloads?

No rehearsal completo, quatro workloads persistentes de observabilidade foram recuperados.

Grafana abriu seu SQLite restaurado. Loki recuperou checkpoint/WAL e índices locais. Prometheus abriu os blocos TSDB, fez replay de WAL/checkpoint e voltou a escrever novos blocos. Tempo também voltou a ficar Ready.

Em um dos rehearsals, Tempo descartou um bloco WAL incompleto que não possuía `meta.json`.

Isso foi outro alerta: uma cópia de filesystem pode ser recuperável sem ser necessariamente um snapshot consistente da aplicação.

Essa observação acabaria levando a uma etapa posterior do projeto: criar um recovery set com consistência limitada e mensurada.

## O principal aprendizado

Antes do teste, eu tinha backups.

Depois do teste, eu tinha uma lista de suposições que estavam erradas:

```text
backup do datastore != cluster executável

dados do PV != PV utilizável em outro node

imagem no containerd != backup OCI confiável

Git disponível hoje != Git disponível durante DR

script terminou 0 != pós-condição realmente satisfeita
```

Essa é a diferença que passei a enxergar entre backup e Disaster Recovery.

Backup é um artefato.

Disaster Recovery é uma capacidade que precisa ser exercitada.

Depois que consegui recuperar o ambiente, surgiu a pergunta seguinte: **quanto tempo isso leva?**

No próximo artigo vou mostrar como comecei a medir RTO de verdade, incluindo bootstrap, intervenção manual e os próprios erros encontrados durante o rehearsal — e como o tempo caiu de 1h07m09s para 47m03s.

---

Projeto: `guionardo/guiosoft-k3s-lab`.
