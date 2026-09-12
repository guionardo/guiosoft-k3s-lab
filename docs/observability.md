# Observability

## Objetivo

Adicionar uma camada de métricas do cluster sem expor novos endpoints publicamente e sem consumir recursos excessivos do host single-node atual.

A primeira etapa usa o chart `kube-prometheus-stack`, que reúne Prometheus Operator, Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter, dashboards e regras padrão.

## Versões pinadas

- Helm: `v4.3.0`;
- kube-prometheus-stack: `89.2.0`.

As versões são explícitas para manter rebuilds reproduzíveis. Atualizações devem ser feitas de forma consciente, revisando notas de upgrade e CRDs.

## Estado validado no host

A instalação do `kube-prometheus-stack` foi executada com sucesso no cluster K3s atual. Foram observados em `Running`:

- Prometheus;
- Alertmanager;
- Grafana;
- Prometheus Operator;
- kube-state-metrics;
- node-exporter.

Os CRs de Prometheus e Alertmanager estavam reconciliados e disponíveis. Também foram confirmados dois PVCs `Bound` usando `local-path`:

- Prometheus: 10 GiB;
- Grafana: 2 GiB.

Essa validação comprova que a stack foi instalada e que os componentes principais e seus volumes persistentes estão operacionais. A saúde dos scrape targets e os dashboards ainda são validados separadamente.

## Instalação

```bash
make tools
make observability-install
```

O `make tools` instala Helm via Ansible. `make observability-install` cria o namespace `monitoring` e executa `helm upgrade --install` usando:

```text
kubernetes/observability/kube-prometheus-stack-values.yaml
```

## Perfil do homelab

O perfil inicial foi ajustado para o servidor single-node atual:

- Prometheus com retenção de 7 dias e limite aproximado de 6 GB;
- PVC Prometheus de 10 GiB usando `local-path`;
- Grafana com PVC de 2 GiB;
- Alertmanager single-replica;
- `kubeEtcd`, `kubeControllerManager` e `kubeScheduler` desabilitados porque o K3s atual usa SQLite e esses componentes não são expostos como em um cluster kubeadm tradicional;
- requests/limits conservadores para evitar competição desnecessária com os workloads existentes.

Métricas são importantes operacionalmente, mas os dados históricos de Prometheus/Grafana ainda não são classificados como dados críticos de negócio. A política de backup de PVCs continua separada.

## Validação de métricas e targets

Depois da instalação, execute:

```bash
make observability-validate
```

O target é somente leitura. Ele:

- aguarda os Pods do namespace `monitoring` ficarem Ready;
- confirma que os PVCs estão `Bound`;
- consulta a API do Prometheus através do proxy autenticado do Kubernetes API server, sem expor porta externa;
- verifica que existe pelo menos um scrape target ativo;
- falha se algum target ativo estiver com health diferente de `up`;
- executa a query Prometheus `up` e confirma que existem séries retornadas;
- mostra `kubectl top` para node e containers do namespace quando metrics-server estiver disponível.

Esse comando serve como evidência antes de considerar a coleta de métricas do cluster validada.

## Acesso ao Grafana

Nenhum Ingress é criado nesta primeira etapa. Isso evita publicar Grafana automaticamente pelo wildcard Cloudflare.

Para acesso local:

```bash
make observability-grafana
```

O target mostra a senha administrativa gerada pelo chart e inicia um port-forward local para:

```text
http://127.0.0.1:3000
```

O password não é versionado no Git.

## Estado e diagnóstico

```bash
make observability-status
```

O comando mostra:

- release Helm;
- pods no namespace `monitoring`;
- services;
- PVCs;
- recursos Prometheus/Alertmanager quando disponíveis.

## Próximas etapas

1. validar targets Prometheus com `make observability-validate`;
2. abrir Grafana localmente e validar dashboards padrão;
3. revisar consumo de CPU/memória/storage após estabilização;
4. revisar alertas ruidosos ou incompatíveis com K3s;
5. depois adicionar Loki para logs;
6. somente depois avaliar publicação protegida do Grafana via Cloudflare.

## Fontes

- kube-prometheus-stack chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- Artifact Hub kube-prometheus-stack: https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack
- Prometheus Operator: https://prometheus-operator.dev/
- Prometheus HTTP API: https://prometheus.io/docs/prometheus/latest/querying/api/
- Kubernetes API service proxy: https://kubernetes.io/docs/tasks/access-application-cluster/access-cluster-services/
- Helm install docs: https://helm.sh/docs/intro/install/
- Helm releases: https://github.com/helm/helm/releases
