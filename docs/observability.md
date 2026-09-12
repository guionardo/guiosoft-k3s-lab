# Observability

## Objetivo

Adicionar uma camada de métricas do cluster sem expor novos endpoints publicamente e sem consumir recursos excessivos do host single-node atual.

A primeira etapa usa o chart `kube-prometheus-stack`, que reúne Prometheus Operator, Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter, dashboards e regras padrão.

## Versões pinadas

- Helm: `v4.3.0`;
- kube-prometheus-stack: `89.2.0`.

As versões são explícitas para manter rebuilds reproduzíveis. Atualizações devem ser feitas de forma consciente, revisando notas de upgrade e CRDs.

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

1. instalar e validar a stack no host;
2. confirmar consumo de CPU/memória/storage;
3. verificar targets Prometheus;
4. validar dashboards de node, pods, workloads e Kubernetes;
5. revisar alertas ruidosos ou incompatíveis com K3s;
6. depois adicionar Loki para logs;
7. somente depois avaliar publicação protegida do Grafana via Cloudflare.

## Fontes

- kube-prometheus-stack chart: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- Artifact Hub kube-prometheus-stack: https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack
- Prometheus Operator: https://prometheus-operator.dev/
- Helm install docs: https://helm.sh/docs/intro/install/
- Helm releases: https://github.com/helm/helm/releases
