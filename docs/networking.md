# Networking e publicação de aplicações

## Fluxo público padrão

O fluxo validado para novas aplicações HTTP/HTTPS é:

```text
Internet
  -> Cloudflare
  -> Cloudflare Tunnel
  -> cloudflared no host
  -> http://127.0.0.1:80
  -> Traefik no K3s
  -> Ingress
  -> Service
  -> Pod
```

O DNS wildcard `*.guiosoft.info` aponta para o Cloudflare Tunnel do host. No Tunnel, a regra wildcard encaminha para `http://127.0.0.1:80`.

Registros DNS específicos continuam tendo precedência sobre o wildcard e podem apontar para outros Tunnels/serviços durante a migração gradual.

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

O acesso do cliente a `https://<app>.guiosoft.info` termina inicialmente na Cloudflare. O trecho entre `cloudflared` e Traefik usa HTTP local em `127.0.0.1:80`.

O transporte do Cloudflare Tunnel é criptografado entre o `cloudflared` e a rede Cloudflare. Portanto, não é necessário adicionar TLS no Traefik apenas para satisfazer o Tunnel neste estágio.

TLS interno/origin poderá ser introduzido depois caso exista requisito específico.

## Teste local antes da publicação externa

Antes de testar pela Internet, validar o Ingress diretamente no host:

```bash
curl -H 'Host: app.guiosoft.info' http://127.0.0.1/
```

Se o teste local funcionar e o externo não, investigar primeiro Cloudflare DNS/Tunnel antes de alterar Kubernetes.

## Wildcard e segurança

O wildcard DNS/Tunnel facilita a publicação, mas também significa que qualquer hostname não coberto por um registro específico pode alcançar o Traefik.

Por isso:

- somente aplicações com Ingress explícito devem responder;
- não usar um catch-all Ingress público sem necessidade;
- aplicações administrativas ou privadas devem ter política de acesso própria antes da publicação;
- futuramente avaliar Cloudflare Access para serviços administrativos;
- manter inventário dos hostnames publicados.
