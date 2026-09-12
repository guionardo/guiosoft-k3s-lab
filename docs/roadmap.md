# Roadmap

## Fase 0 — Discovery e limpeza pré-K3s

Objetivo: entender o estado atual, eliminar dependências desnecessárias e preparar o host sem afetar workloads que permanecerão.

- [x] criar script de discovery read-only;
- [x] executar discovery no Debian 13;
- [x] analisar hardware, discos, mounts e capacidade;
- [x] mapear portas e processos;
- [x] mapear serviços systemd;
- [x] mapear Docker/containerd;
- [x] mapear Cloudflare Tunnel atual;
- [x] identificar serviços relevantes para preservação;
- [x] excluir `escoteirando-suite` do escopo de migração;
- [x] excluir `gitea` do escopo de migração;
- [ ] confirmar situação do OpenShip;
- [ ] confirmar que nenhum acesso administrativo depende do Tailscale;
- [ ] remover Tailscale e validar DNS/rede do host;
- [ ] remover do Cloudflare `traefik.guiosoft.info`;
- [ ] remover do Cloudflare `git.guiosoft.info`;
- [ ] remover do Cloudflare `git-ssh.guiosoft.info`;
- [ ] preservar configuração do OpenShip até decisão explícita;
- [ ] validar firewall após limpeza;
- [ ] consolidar estado atual em documentação versionada.

## Fase 1 — Infrastructure as Code

- [ ] inventário Ansible;
- [ ] role `base`;
- [ ] role `storage`;
- [ ] role `k3s`;
- [ ] role `firewall`;
- [ ] playbook `bootstrap.yml`;
- [ ] Terraform Cloudflare;
- [ ] estratégia SOPS + age;
- [ ] Makefile para operações comuns.

## Fase 2 — K3s

- [ ] validar requisitos e conflitos de portas;
- [ ] instalar versão estável fixada do K3s via Ansible;
- [ ] configurar kubectl;
- [ ] validar node/CoreDNS/Traefik/local-path;
- [ ] criar namespaces base;
- [ ] deploy de workload de teste;
- [ ] documentar troubleshooting básico.

## Fase 3 — Networking e Cloudflare

- [ ] validar Traefik internamente;
- [ ] manter inicialmente o `cloudflared` atual no host;
- [ ] publicar hostname de teste dedicado, como `k3s-test.guiosoft.info`;
- [ ] validar caminho Cloudflare -> Traefik -> Ingress -> Service -> Pod;
- [ ] definir padrão de Ingress para aplicações;
- [ ] colocar gradualmente DNS/Tunnel sob Terraform;
- [ ] migrar `cloudflared` para Kubernetes apenas depois do fluxo estar validado.

## Fase 4 — Workloads

Não existe mais obrigação de migrar os stacks `escoteirando-suite` ou `gitea`.

Para qualquer workload escolhido futuramente:

1. identificar runtime e dependências;
2. identificar dados persistentes;
3. criar manifests/Helm;
4. testar internamente;
5. testar por hostname temporário quando necessário;
6. mudar rota Cloudflare;
7. observar;
8. manter rollback simples;
9. somente depois remover instalação antiga, se aplicável.

## Fase 5 — Storage e backup

- [ ] definir layout definitivo de `/srv`;
- [ ] PVCs/local-path;
- [ ] estratégia para bancos de dados;
- [ ] backup automatizado;
- [ ] backup externo/off-host;
- [ ] testes reais de restore.

## Fase 6 — Observabilidade

- [ ] métricas do cluster;
- [ ] Prometheus;
- [ ] Grafana;
- [ ] logs com Loki;
- [ ] dashboards de recursos;
- [ ] alertas essenciais.

## Fase 7 — GitOps

- [ ] escolher Argo CD ou Flux;
- [ ] bootstrap GitOps;
- [ ] aplicações reconciliadas a partir do Git;
- [ ] definir promoção/rollback;
- [ ] integrar secrets criptografados.

## Fase 8 — Disaster Recovery

Objetivo: reconstruir um servidor a partir de Debian limpo + Git + backups.

- [ ] documentar pré-requisitos externos;
- [ ] automatizar bootstrap;
- [ ] restaurar K3s;
- [ ] restaurar infraestrutura Kubernetes;
- [ ] restaurar dados;
- [ ] executar teste completo de reconstrução;
- [ ] registrar RTO/RPO observados.

## Fase 9 — Segundo nó

- [ ] adicionar K3s agent/server conforme objetivo do laboratório;
- [ ] scheduling;
- [ ] affinity;
- [ ] taints/tolerations;
- [ ] DaemonSets;
- [ ] cordon/drain;
- [ ] simular indisponibilidade de nó;
- [ ] avaliar storage distribuído somente quando houver benefício real.
