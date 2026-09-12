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

Classificação: **ruído incompatível com o perfil atual / remover da configuração**.

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

Caso futuramente kube-proxy passe a ser exposto de forma suportada e útil no K3s, essa decisão pode ser revertida e um endpoint real deve ser configurado antes de reabilitar as regras.

### CPUThrottlingHigh — investigar antes de alterar

Classificação: **informativo / observar**.

O alerta apareceu para:

```text
pod=kube-prometheus-stack-prometheus-node-exporter-...
severity=info
```

No mesmo instante, `kubectl top` mostrava uso atual do node-exporter muito baixo, enquanto o container possui um limite explícito de CPU de `200m`.

Isso pode representar throttling episódico causado por bursts curtos e pelo limite de CPU, não necessariamente saturação real do host. Como a evidência atual não mostra degradação operacional, a decisão é **não desabilitar a regra nem remover o limite ainda**.

Próximo passo: observar se o alerta persiste após algum tempo e, se necessário, consultar as métricas de throttling antes de decidir entre aumentar/remover o CPU limit ou manter o alerta como sinal útil.

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
