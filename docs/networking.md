# Networking e publicação de aplicações

## Fluxo público padrão

O fluxo validado para novas aplicações HTTP/HTTPS é:

```text
Internet
  -> Cloudflare
  -> Cloudflare Tunnel
  -> cloudflared no K3s (2 réplicas)
  -> http://192.168.88.9:80
  -> Traefik no K3s
  -> Ingress
  -> Service
  -> Pod
```

O DNS wildcard `*.guiosoft.info` aponta para o Cloudflare Tunnel. No Tunnel, a regra wildcard encaminha para `http://192.168.88.9:80`.

Esse origin foi escolhido durante a migração porque era alcançável simultaneamente pelo connector systemd antigo no host e pelos Pods Kubernetes. Isso permitiu adicionar o novo connector antes de remover o antigo, sem janela deliberada de indisponibilidade.

O `cloudflared` agora executa no namespace `cloudflare` como Deployment com duas réplicas. O antigo `cloudflared.service` do host está parado/desabilitado e preservado temporariamente apenas para rollback.

Registros DNS específicos continuam tendo precedência sobre o wildcard e podem apontar para outros Tunnels/serviços durante migrações futuras.

## Convenção de Ingress

Para aplicações HTTP públicas novas:

- usar `ingressClassName: traefik` explicitamente;
- usar um hostname próprio em `*.guiosoft.info`;
- publicar o Service como `ClusterIP`, salvo necessidade específica diferente;
- deixar Traefik fazer o roteamento por hostname;
- não criar NodePort apenas para exposição via Cloudflare Tunnel;
- não publicar dashboards administrativos por padrão;
- manter regras específicas de Cloudflare antes do wildcard quando houver exceções no Tunnel.

Exemplo mínimo:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app
  namespace: app
spec:
  ingressClassName: traefik
  rules:
    - host: app.guiosoft.info
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: app
                port:
                  number: 80
```

## TLS

O acesso do cliente a `https://<app>.guiosoft.info` termina inicialmente na Cloudflare. O trecho entre `cloudflared` e Traefik usa HTTP dentro da rede do host/cluster via `192.168.88.9:80`.

O transporte do Cloudflare Tunnel é criptografado entre os connectors `cloudflared` e a rede Cloudflare. Portanto, não é necessário adicionar TLS no Traefik apenas para satisfazer o Tunnel neste estágio.

TLS interno/origin poderá ser introduzido depois caso exista requisito específico.

## Alta disponibilidade do connector

O Deployment usa duas réplicas do `cloudflared`. Cada Pod estabelece múltiplas conexões QUIC com a Cloudflare e recebe a mesma configuração remota do Tunnel.

No cluster single-node atual, duas réplicas protegem contra falha/restart de processo ou Pod e permitem rolling update sem derrubar deliberadamente todas as conexões. Elas não protegem contra falha física/reboot do único node. A redundância de node só existirá quando o projeto chegar à fase de segundo nó.

Não há necessidade operacional de HPA para `cloudflared`; as réplicas existem para disponibilidade do connector, não para escalar throughput por CPU.

## Teste local antes da publicação externa

Antes de testar pela Internet, validar o Ingress diretamente no Traefik:

```bash
curl -H 'Host: app.guiosoft.info' http://192.168.88.9/
```

Também é possível testar a partir do host por loopback quando apropriado:

```bash
curl -H 'Host: app.guiosoft.info' http://127.0.0.1/
```

Se o teste interno funcionar e o externo não, investigar primeiro Cloudflare DNS/Tunnel e a saúde dos Pods `cloudflared` antes de alterar o workload Kubernetes.

## Wildcard e segurança

O wildcard DNS/Tunnel facilita a publicação, mas também significa que qualquer hostname não coberto por uma regra mais específica pode alcançar o Traefik.

A política validada é **default deny por ausência de rota**: somente hostnames com um Ingress explícito respondem com uma aplicação. Um hostname sob `*.guiosoft.info` sem Ingress correspondente chega ao Traefik e recebe `404 page not found`.

Para workloads LAN-only existe uma proteção adicional: criar uma regra explícita no Tunnel antes do wildcard. O Firecrawl usa:

```text
firecrawl.guiosoft.info -> http_status:404
*.guiosoft.info         -> http://192.168.88.9:80
```

Assim, o split-DNS da LAN pode apontar `firecrawl.guiosoft.info` diretamente para o servidor K3s, enquanto o mesmo hostname solicitado pela Internet é encerrado no Tunnel com HTTP 404 sem alcançar Traefik.

Por isso:

- somente aplicações com Ingress explícito devem responder;
- não usar um catch-all Ingress público sem necessidade;
- aplicações LAN-only sob o wildcard devem ter negação explícita anterior ao wildcard;
- aplicações administrativas ou privadas devem ter política de acesso própria antes da publicação;
- Cloudflare Access permanece uma opção para serviços que realmente precisem ser públicos e autenticados;
- manter inventário dos hostnames publicados.

## Rollback do connector

Durante a janela de observação pós-migração, o runtime antigo do host permanece instalado. Se os connectors Kubernetes apresentarem falha que não possa ser corrigida imediatamente:

```bash
sudo systemctl enable --now cloudflared
```

Como o origin remoto já é `http://192.168.88.9:80`, o connector do host e os connectors Kubernetes são compatíveis com a mesma configuração remota.
