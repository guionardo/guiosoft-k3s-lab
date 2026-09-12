# Acesso remoto ao K3s com kubectl

## Objetivo

Permitir que outra máquina da mesma rede local use `kubectl` contra o K3s sem copiar manualmente um kubeconfig cujo endpoint aponta para `127.0.0.1` ou `localhost`.

## Gerar kubeconfig para outra máquina

No servidor K3s:

```bash
make kubeconfig-external
```

O target:

1. lê o kubeconfig administrativo atual com `kubectl config view --raw --flatten`;
2. descobre o `InternalIP` do node Kubernetes;
3. preserva CA, certificados, chaves e contexto;
4. troca somente o `server:` para `https://<InternalIP>:6443`;
5. escreve o kubeconfig resultante em stdout.

Para salvar diretamente em um arquivo privado:

```bash
umask 077
make kubeconfig-external > k3s-guiosoft.yaml
```

Na máquina cliente:

```bash
export KUBECONFIG="$PWD/k3s-guiosoft.yaml"
kubectl get nodes
```

Também é possível fornecer endereço e porta explicitamente:

```bash
make kubeconfig-external ADDRESS=192.168.88.9
make kubeconfig-external ADDRESS=192.168.88.9 PORT=6443
```

O endereço explícito é útil caso o cluster passe a ter múltiplos nodes ou o endereço desejado seja diferente do primeiro `InternalIP` retornado pela API.

## Segurança

O kubeconfig produzido contém credenciais administrativas do cluster. Trate o arquivo como secret:

- não versionar no Git;
- não enviar por canais públicos;
- manter permissões restritas (`0600`);
- apagar cópias temporárias quando não forem mais necessárias.

O target recusa endereços loopback (`127.x`, `localhost`, `::1`).

## Rede

Gerar o arquivo não altera firewall nem exposição de rede. A máquina cliente precisa conseguir alcançar o servidor K3s na porta TCP `6443` pela LAN.

No host atual, a intenção é acesso somente pela rede local. Não publicar a API Kubernetes pela Cloudflare Tunnel nem abrir `6443` na Internet.

Se futuramente o firewall do host for ativado, a regra para `6443/TCP` deve ser restrita à rede ou aos hosts administrativos necessários.

## TLS

O certificado da API precisa ser válido para o endereço usado no kubeconfig. No K3s atual, o acesso pela LAN deve ser validado executando `kubectl get nodes` a partir de outra máquina. Se houver erro de SAN/certificado, o endpoint não deve ser contornado com `insecure-skip-tls-verify`; a configuração TLS do K3s deve ser corrigida para incluir o endereço apropriado.

## Fontes

- K3s cluster access: https://docs.k3s.io/cluster-access
- Kubernetes kubeconfig: https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- kubectl config: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_config/
