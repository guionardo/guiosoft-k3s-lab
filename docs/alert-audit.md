# Alert audit — kube-prometheus-stack on K3s

## Objetivo

Registrar quais alertas padrão do `kube-prometheus-stack` são úteis neste homelab K3s, quais são esperados por desenho e quais precisam ser ajustados para evitar ruído.

A auditoria é feita por:

```bash
make observability-validate
```

O script consulta a API `/api/v1/alerts` do Prometheus de forma read-only e lista estado, nome, severidade e contexto do alerta.

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

### CPUThrottlingHigh — investigação direcionada

Classificação atual: **informativo / investigar antes de alterar**.

Após o ajuste de kube-proxy, o alerta permaneceu `pending` para o container `node-exporter`. Na mesma amostra:

```text
node CPU total: ~1130m / 18%
node memory:    ~7265 MiB / 45%
node-exporter:  ~7m CPU / 11 MiB
```

O container possui um limite explícito de CPU de `200m`. Uso médio baixo não exclui throttling: bursts curtos podem atingir a quota CFS mesmo quando a média de CPU observada pelo `kubectl top` é pequena.

Para evitar alterar limites ou regras por suposição, foi adicionado um diagnóstico read-only:

```bash
make observability-cpu-throttling-audit
```

Ele mostra:

- expressão efetiva da regra `CPUThrottlingHigh` carregada no Prometheus;
- razão de períodos throttled nos últimos 5 minutos;
- uso médio de CPU no mesmo período;
- requests e limits de CPU configurados;
- estado atual do alerta.

A decisão sobre aumentar/remover o CPU limit do node-exporter só será tomada depois dessa evidência.

## Critério adotado

Não remover alertas apenas porque estão firing.

Para cada alerta:

1. verificar se o componente realmente existe no desenho do K3s;
2. verificar se há target saudável correspondente;
3. separar alertas sintéticos/operacionais (`Watchdog`, `InfoInhibitor`) de falhas reais;
4. comparar o alerta com métricas atuais de recursos;
5. somente então alterar regras ou limites.

Isso evita transformar a observabilidade em um sistema silencioso apenas para obter uma tela sem alertas.

## Fontes

- kube-prometheus-stack values e regras: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
- Prometheus alerting rules: https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- Prometheus Operator: https://prometheus-operator.dev/
- K3s networking: https://docs.k3s.io/networking/basic-network-options
