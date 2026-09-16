# Troubleshooting básico

## Estado geral do cluster

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get services -A
kubectl get ingress -A
```

O node deve estar `Ready`. Para o caminho HTTP padrão, o Traefik deve estar `Running` no namespace `kube-system`.

## K3s/API indisponível

```bash
sudo systemctl status k3s --no-pager
sudo journalctl -u k3s -n 100 --no-pager
kubectl get --raw=/readyz
```

Se `kubectl` não conseguir abrir o kubeconfig:

```bash
ls -l ~/.kube/config
kubectl config view --minify
```

O kubeconfig administrativo local é gerenciado pelo role Ansible `k3s` e contém credenciais de administrador do cluster. Deve permanecer com modo `0600` e não deve ser versionado.

## Pod com problema

```bash
kubectl get pods -A
kubectl describe pod -n <namespace> <pod>
kubectl logs -n <namespace> <pod>
```

Para containers múltiplos:

```bash
kubectl logs -n <namespace> <pod> -c <container>
```

## Service não alcança o Pod

```bash
kubectl get service -n <namespace> <service> -o wide
kubectl get endpoints -n <namespace> <service>
kubectl get pods -n <namespace> --show-labels
```

Se não houver endpoints, verificar se o selector do Service corresponde aos labels dos Pods.

## Ingress não responde

```bash
kubectl get ingress -n <namespace>
kubectl describe ingress -n <namespace> <ingress>
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
```

Validar primeiro localmente, forçando o `Host` esperado:

```bash
curl -v -H 'Host: app.guiosoft.info' http://127.0.0.1/
```

Se este teste funcionar, o caminho Traefik -> Ingress -> Service -> Pod está funcional e a investigação deve seguir para Cloudflare.

## Cloudflare: local funciona, externo falha

Verificar o serviço e os logs do Tunnel:

```bash
sudo systemctl status cloudflared --no-pager
sudo journalctl -u cloudflared -f
```

A regra wildcard validada é conceitualmente:

```text
*.guiosoft.info -> http://127.0.0.1:80
```

Evitar `http://localhost:80`: neste host `localhost` pode resolver primeiro para `::1`, enquanto a porta 80 do Traefik está disponível pelo caminho IPv4 local.

Também verificar o DNS. O wildcard deve apontar para o Tunnel (`<TUNNEL-ID>.cfargotunnel.com`), e não para um endereço A de um origin antigo.

Um registro DNS específico para um hostname tem precedência sobre o wildcard e pode encaminhar a aplicação para outro Tunnel.

## Traefik

```bash
kubectl get pod -n kube-system -l app.kubernetes.io/name=traefik -o wide
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=100
kubectl get service -n kube-system traefik -o wide
```

No laboratório atual, o Service LoadBalancer do Traefik expõe as portas 80/443 no node através do ServiceLB do K3s.

## DNS

De outra máquina:

```bash
dig app.guiosoft.info
dig CNAME app.guiosoft.info +short
```

Quando o registro é proxied pela Cloudflare, uma consulta A/AAAA pode retornar endereços da própria Cloudflare; isso sozinho não revela o target original configurado no painel.

## Sequência de diagnóstico recomendada

```text
1. Pod está Running?
2. Service possui endpoints?
3. Ingress existe e aponta para o Service correto?
4. curl local com Host funciona?
5. cloudflared está conectado?
6. request externo aparece no log do cloudflared?
7. DNS está apontando para o Tunnel correto?
```

Essa ordem evita alterar Kubernetes quando o problema está no DNS/Tunnel, e vice-versa.
