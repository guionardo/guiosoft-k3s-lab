# Alert audit — kube-prometheus-stack on K3s

## Objetivo

Registrar quais alertas padrão do `kube-prometheus-stack` são úteis neste homelab K3s, quais são esperados por desenho e quais precisam ser ajustados para evitar ruído.

A auditoria é feita por:

```bash
make observability-validate
```

O script consulta a API `/api/v1/alerts` do Prometheus de forma read-only e lista estado, nome, severidade e contexto do alerta.

Para investigar throttling de CPU sem alterar estado:

```bash
make observability-cpu-throttling-audit
```

## Primeira auditoria runtime

Com 15/15 targets `up`, foram encontrados quatro alertas ativos:

```text
CPUThrottlingHigh   firing  severity=info
InfoInhibitor       firing  severity=none
KubeProxyDown       firing  severity=critical
Watchdog            firing  severity=none
```

### Watchdog — esperado

Classificação: **esperado / manter**.

`Watchdog` é propositalmente configurado para permanecer firing continuamente. Sua função é provar que a cadeia Prometheus -> Alertmanager continua viva. A ausência desse alerta é mais interessante que sua presença.

Não deve ser tratado como incidente do cluster.

### InfoInhibitor — esperado

Classificação: **esperado / manter**.

`InfoInhibitor` faz parte da estratégia de inibição das regras padrão e normalmente aparece junto com alertas de nível informativo. Não representa, isoladamente, falha operacional.

Não deve ser removido apenas por aparecer como firing.

### KubeProxyDown — falso positivo para o perfil K3s atual

Classificação: **ruído incompatível com o perfil atual / removido da configuração**.

O chart `kube-prometheus-stack` habilita por padrão tanto o monitoramento de kube-proxy quanto as regras associadas. Esse modelo assume que existe um target convencional de kube-proxy disponível para discovery/scrape.

No cluster K3s atual não há target kube-proxy sendo descoberto pelo Prometheus. O alerta, portanto, permanecia critical apesar de todos os targets existentes estarem healthy.

A correção adotada foi explícita no `kube-prometheus-stack-values.yaml`:

```yaml
kubeProxy:
  enabled: false

defaultRules:
  rules:
    kubeProxy: false
```

A decisão é melhor do que silenciar apenas `KubeProxyDown`, porque deixa claro que este perfil não pretende monitorar esse componente por meio do mecanismo convencional do chart.

### Validação após o ajuste

Depois de reaplicar o chart e executar novamente `make observability-validate`, o cluster continuou com:

```text
Prometheus active targets: 15 total, 15 up, 0 not-up
Prometheus query 'up': 15 series
```

E os alertas passaram a ser:

```text
InfoInhibitor       firing
Watchdog            firing
CPUThrottlingHigh   pending
```

`KubeProxyDown` desapareceu como esperado. Isso confirma que o ajuste removeu somente o falso positivo específico do perfil K3s, sem degradar os targets existentes.

### CPUThrottlingHigh — causa confirmada e corrigida

Classificação final: **resource limit artificialmente restritivo / corrigido e validado**.

A auditoria específica inicial retornou:

```text
rule threshold: >25%
rule for: 900s (15m)
5m throttling ratio: 44.08%
5m average CPU usage: ~0.00577 cores (~5.8m)
CPU request: 20m
CPU limit: 200m
alert state: pending
```

O ponto importante foi a combinação de **throttling muito alto** com **uso médio muito baixo**. O node estava longe de saturação e o processo consumia, em média, uma fração pequena do limite configurado. Isso é compatível com bursts curtos atingindo o hard CPU limit e sendo limitados por CFS, mesmo com CPU livre no host.

Na mesma amostra:

```text
node CPU total: ~1130m / 18%
node memory:    ~7265 MiB / 45%
node-exporter:  ~7m CPU / 11 MiB
```

Kubernetes aplica `limits.cpu` por throttling via CFS/cgroups. Um container pode, portanto, ser throttled mesmo quando o node possui CPU ociosa. Para este homelab single-node, o node-exporter é um componente leve e essencial para observabilidade; não há benefício prático em cortar seus bursts curtos em `200m` quando o próprio host tem ampla folga.

A decisão adotada foi:

- manter `requests.cpu: 20m` para scheduling/QoS;
- manter `requests.memory: 32Mi`;
- manter `limits.memory: 128Mi`;
- **remover apenas `limits.cpu: 200m`**.

Configuração resultante:

```yaml
prometheus-node-exporter:
  resources:
    requests:
      cpu: 20m
      memory: 32Mi
    limits:
      memory: 128Mi
```

A regra `CPUThrottlingHigh` permaneceu habilitada. O objetivo não foi esconder o alerta; foi remover a causa artificial detectada e revalidar o comportamento real.

#### Validação após estabilização

Após cerca de duas horas do rollout, a auditoria retornou:

```text
Current 5-minute throttling ratio:
- no matching throttling series found

Current 5-minute average CPU usage:
- node-exporter cpu_cores=0.0023578320121328193

Configured CPU requests:
- request_cores=0.02

Configured CPU limits:
- no CPU limit series found

Current CPUThrottlingHigh alert state:
- not active
```

A validação consolidada retornou:

```text
Prometheus active targets: 15 total, 15 up, 0 not-up
Prometheus query 'up': 15 series
Active alerts: 1 total, 1 firing, 0 pending
- Watchdog
```

O node estava em aproximadamente:

```text
CPU:    742m / 12%
Memory: 6995 MiB / 44%
```

O node-exporter aparecia em aproximadamente `1m CPU / 11 MiB` no `kubectl top`.

Isso fecha a investigação: o throttling desapareceu sem desabilitar a regra, os 15 targets continuaram saudáveis e o único alerta ativo restante passou a ser o `Watchdog`, esperado por desenho.

## Critério adotado

Não remover alertas apenas porque estão firing.

Para cada alerta:

1. verificar se o componente realmente existe no desenho do K3s;
2. verificar se há target saudável correspondente;
3. separar alertas sintéticos/operacionais (`Watchdog`, `InfoInhibitor`) de falhas reais;
4. comparar o alerta com métricas atuais de recursos;
5. medir a expressão efetiva da regra quando necessário;
6. alterar a causa mensurável antes de desabilitar o alerta;
7. aguardar a janela da métrica/regra e revalidar depois da estabilização.

Esse processo evitou transformar a observabilidade em um sistema silencioso apenas para obter uma tela sem alertas e produziu uma correção baseada em evidência.

## Fontes

- kube-prometheus-stack values e regras: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- Prometheus alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus Operator: https://prometheus-operator.dev/
- Kubernetes resource management: https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Kubernetes CPU management/CFS quota: https://kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/
- K3s networking: https://docs.k3s.io/networking/basic-network-options
