# Grafana dashboard audit

## Objetivo

Revisar os dashboards provisionados pelo `kube-prometheus-stack` no perfil single-node K3s e separar:

- dashboards úteis para operação do homelab;
- dashboards válidos, mas secundários;
- dashboards não aplicáveis à plataforma atual;
- dashboards realmente quebrados ou com referências inválidas.

A auditoria é read-only:

```bash
make observability-grafana-dashboard-audit
```

## Primeira execução

Foram descobertos 26 dashboards.

Os principais dashboards esperados estavam presentes:

- `Kubernetes / Compute Resources / Cluster`;
- `Kubernetes / Compute Resources / Namespace (Pods)`;
- `Kubernetes / Compute Resources / Node (Pods)`;
- `Node Exporter / Nodes`;
- `OTel Go Demo - Application Metrics`.

Não foram encontrados dashboards específicos de `etcd`, `scheduler`, `controller-manager` ou `kube-proxy` na lista atual. Isso é coerente com o perfil K3s configurado, que não monitora esses componentes pelo modelo convencional do `kube-prometheus-stack`.

## Falso positivo encontrado no script de auditoria

A primeira versão do auditor reportou 25 warnings de datasource, quase todos apontando para:

```text
$datasource
${datasource}
```

Esses valores não são UIDs quebrados. São variáveis de template do Grafana usadas pelos dashboards upstream para selecionar o datasource dinamicamente.

Portanto, a auditoria estava classificando como erro uma construção válida de dashboard.

O script foi corrigido para ignorar explicitamente `$datasource` e `${datasource}` ao procurar referências inesperadas.

Esse caso reforça o mesmo princípio usado na auditoria de alertas: uma ferramenta de validação também precisa ser validada antes de transformar warning em mudança de configuração.

## Classificação inicial

### Úteis para este homelab

Prioridade alta:

- `Kubernetes / Compute Resources / Cluster`;
- `Kubernetes / Compute Resources / Nodes Overview`;
- `Kubernetes / Compute Resources / Node (Pods)`;
- `Kubernetes / Compute Resources / Namespace (Pods)`;
- `Kubernetes / Compute Resources / Namespace (Workloads)`;
- `Kubernetes / Compute Resources / Pod`;
- `Kubernetes / Compute Resources / Workload`;
- `Kubernetes / Persistent Volumes`;
- `Kubernetes / Networking / Cluster`;
- `Kubernetes / Kubelet`;
- `Node Exporter / Nodes`;
- `Node Exporter / USE Method / Node`;
- `Prometheus / Overview`;
- `Alertmanager / Overview`;
- `CoreDNS`;
- `OTel Go Demo - Application Metrics`.

### Válidos, mas secundários no cluster single-node

- `Kubernetes / Compute Resources / Multi-Cluster` — válido, porém pouco útil enquanto só existe um cluster;
- `Node Exporter / USE Method / Cluster` — funciona, mas agrega pouco valor em um cluster de um único node;
- dashboards de networking por namespace/workload/pod — úteis quando houver mais workloads reais, mas hoje têm prioridade menor;
- `Grafana Overview` — útil para operar o próprio Grafana, não para a saúde geral do cluster.

### Não aplicáveis ao host atual

- `Node Exporter / AIX`;
- `Node Exporter / MacOS`.

O host é Linux, portanto esses dashboards podem permanecer provisionados sem causar impacto operacional, mas não fazem parte do conjunto recomendado para uso diário.

Não há necessidade de removê-los somente para reduzir a lista. Remoção só seria útil se quisermos uma interface mais enxuta no futuro.

## Critério de conclusão

A revisão será considerada concluída quando a versão corrigida do auditor confirmar:

- todos os dashboards podem ser carregados pela API;
- referências `$datasource`/`${datasource}` não geram falso positivo;
- não existem UIDs de datasource realmente inválidos;
- o dashboard customizado do demo continua presente;
- dashboards não aplicáveis estão apenas classificados, não necessariamente removidos.

## Fontes

- Grafana dashboards: https://grafana.com/docs/grafana/latest/dashboards/
- Grafana dashboard variables: https://grafana.com/docs/grafana/latest/dashboards/variables/
- kube-prometheus-stack: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
