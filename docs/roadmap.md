# Roadmap

## Fase 0 — Discovery

Objetivo: entender completamente o estado atual antes de modificar o servidor.

- [x] criar script de discovery read-only;
- [ ] executar discovery no Debian 13;
- [ ] analisar hardware, discos, mounts e capacidade;
- [ ] mapear portas e processos;
- [ ] mapear serviços systemd;
- [ ] mapear Docker/Podman/containerd;
- [ ] mapear bancos e dados persistentes;
- [ ] mapear proxies web;
- [ ] mapear Cloudflare Tunnel atual;
- [ ] mapear firewall;
- [ ] produzir matriz de migração dos serviços.

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

- [ ] validar Traefik;
- [ ] criar `cloudflared` Deployment;
- [ ] criar secret do Tunnel de forma segura;
- [ ] publicar hostname de teste em `guiosoft.info`;
- [ ] validar acesso externo;
- [ ] definir padrão de Ingress para aplicações;
- [ ] colocar gradualmente DNS/Tunnel sob Terraform.

## Fase 4 — Migração

Para cada serviço:

1. identificar runtime e dependências;
2. identificar dados persistentes;
3. criar manifests/Helm;
4. testar internamente;
5. testar por hostname temporário quando necessário;
6. mudar rota Cloudflare;
7. observar;
8. manter rollback simples;
9. somente depois remover instalação antiga.

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
