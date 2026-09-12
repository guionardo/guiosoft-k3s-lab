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
- [ ] confirmar situação local do OpenShip;
- [x] remover Tailscale e validar ausência da interface no preflight;
- [x] remover do Cloudflare `traefik.guiosoft.info`;
- [ ] remover do Cloudflare `git.guiosoft.info`;
- [ ] remover do Cloudflare `git-ssh.guiosoft.info`;
- [x] remover publicação do OpenShip no Cloudflare;
- [x] validar firewall após bootstrap do cluster;
- [x] documentar postura atual do firewall e listeners expostos;
- [x] consolidar estado atual em documentação versionada.

## Fase 1 — Infrastructure as Code

- [x] inventário Ansible;
- [x] role `base`;
- [x] role `storage` não destrutivo;
- [x] role `k3s`;
- [ ] role `firewall` — implementar somente após classificar serviços LAN/cluster/loopback;
- [x] playbook `preflight.yml`;
- [x] playbook `bootstrap.yml`;
- [x] playbook `k3s.yml`;
- [x] playbook `storage.yml`;
- [x] audit read-only pós-K3s de firewall e serviços preservados;
- [x] scaffold Terraform Cloudflare com provider v5 e proteção contra destroy;
- [x] importar Tunnel existente, configuração remota e wildcard DNS para o state;
- [x] validar `terraform plan` sem mudanças inesperadas (`No changes`);
- [x] estratégia SOPS + age instalada e validada com round-trip e fluxo de Kubernetes Secret cifrado;
- [x] Makefile para operações comuns;
- [x] role Ansible para Helm pinado e verificado por SHA-256.

## Fase 2 — K3s

- [x] automatizar validação inicial de requisitos e conflitos de 80/443;
- [x] executar preflight no host já limpo;
- [x] executar bootstrap do Debian;
- [x] instalar `v1.36.4+k3s1` via Ansible;
- [x] automatizar configuração de `kubectl` e kubeconfig para o usuário administrativo local;
- [x] validar `kubectl` sem `sudo` no host;
- [x] adicionar `make kubeconfig-external` para renderizar kubeconfig administrativo com o `InternalIP` do servidor em vez de loopback;
- [ ] validar `make kubeconfig-external` e acesso `kubectl` a partir de outra máquina da LAN;
- [x] validar node/CoreDNS/Traefik/local-path após estabilização inicial;
- [x] criar namespace `lab`;
- [x] deploy de workload de teste;
- [x] documentar troubleshooting básico.

## Fase 3 — Networking e Cloudflare

- [x] validar Traefik internamente;
- [x] validar Ingress local com workload de teste;
- [x] manter inicialmente o `cloudflared` atual no host;
- [x] publicar hostname de teste dedicado `k3s-test.guiosoft.info`;
- [x] corrigir origin do wildcard do Tunnel para `http://127.0.0.1:80`;
- [x] apontar o wildcard DNS `*.guiosoft.info` para o Cloudflare Tunnel em vez do origin IP legado;
- [x] validar caminho Cloudflare -> Tunnel -> Traefik -> Ingress -> Service -> Pod com HTTP 200;
- [x] definir padrão de Ingress para aplicações;
- [x] definir e validar comportamento para hostnames sem Ingress conhecido (HTTP 404);
- [x] colocar Tunnel, configuração remota e wildcard DNS existentes sob Terraform, com import e `plan` sem drift;
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

- [x] definir layout lógico de `/srv/k3s` e mapeamento para os discos existentes;
- [x] automatizar criação não destrutiva do layout com Ansible;
- [x] validar o role `storage` no host;
- [x] configurar novos volumes `local-path` para `/mnt/store1/k3s/local-path`;
- [x] adicionar workload automatizado para teste de PVC/persistência;
- [x] validar persistência após recriação do Pod;
- [x] inventariar PVC/PV atual e identificar que o único PVC é o workload descartável `lab/persistence-test`;
- [x] identificar que o PV inicial do teste foi provisionado no path legado `/var/lib/rancher/k3s/storage` e não representa dados de aplicação;
- [x] reprovisionar o PVC descartável e confirmar criação abaixo de `/mnt/store1/k3s/local-path`;
- [ ] estratégia para bancos de dados;
- [x] implementar backup local manual verificável do datastore SQLite + server token;
- [x] validar criação do backup no host;
- [x] validar restore rehearsal não destrutivo do backup;
- [x] implementar agendamento systemd via Ansible;
- [x] implementar retenção local conservadora por quantidade de archives;
- [x] validar timer, execução agendada e retenção no host;
- [x] adicionar restic ao tooling Ansible para preparar backup off-host;
- [ ] validar round-trip local do restic;
- [x] escolher Cloudflare R2 como destino off-host via API S3-compatible;
- [x] criar stack Terraform separada para o bucket R2 com `prevent_destroy`;
- [x] criar bucket R2 e validar acesso;
- [x] criar credencial R2 Object Read & Write restrita ao bucket;
- [x] armazenar credenciais R2 + senha Restic com SOPS + age;
- [x] inicializar repositório Restic no R2;
- [x] validar round-trip real Restic -> R2 -> restore com comparação SHA-256;
- [x] implementar automação de cópia off-host e retenção remota no serviço de backup;
- [x] validar execução completa local + R2 pelo `k3s-backup.service`;
- [x] validar `restic check` no repositório R2;
- [x] adicionar inventário read-only de PVC/PV para planejar backup de dados de aplicações;
- [x] confirmar que ainda não existem PVCs de aplicação reais para classificar ou proteger;
- [ ] classificar futuros PVCs de aplicação como stateless, file-oriented, database ou external;
- [ ] definir e implementar backup nativo para cada banco de dados persistente;
- [ ] definir backup de PVCs file-oriented;
- [ ] executar restore completo do K3s a partir de backup em ambiente de disaster recovery;
- [ ] testes periódicos de restore.

## Fase 6 — Observabilidade

- [x] definir stack inicial com `kube-prometheus-stack` pinado;
- [x] adicionar namespace `monitoring` e values conservadores para o homelab;
- [x] adicionar instalação Helm idempotente via `make observability-install`;
- [x] manter Grafana sem Ingress na primeira etapa;
- [x] executar `make tools` e validar Helm indiretamente pela instalação/upgrade bem-sucedida do chart;
- [x] instalar a stack de observabilidade no cluster (`kube-prometheus-stack` 89.2.0);
- [x] validar Pods de Prometheus, Alertmanager, Grafana, Operator, kube-state-metrics e node-exporter em `Running`;
- [x] validar PVCs Bound para Prometheus (10 GiB) e Grafana (2 GiB) em `local-path`;
- [x] definir tracing com Tempo single-binary + OpenTelemetry Collector;
- [x] adicionar values pinados para Tempo e OpenTelemetry Collector;
- [x] adicionar pipeline OTLP Collector -> Tempo e datasource Tempo no Grafana;
- [x] expor instalação/status de tracing pelo Makefile;
- [x] instalar Tempo `2.2.3` e OpenTelemetry Collector chart `0.172.1` no cluster;
- [x] validar Tempo e Collector em `Running` e PVC Tempo de 5 GiB em `local-path`;
- [x] atualizar exporter do Collector para `otlp_grpc` após deprecation reportada pelo chart;
- [x] implementar workload Go instrumentado com OpenTelemetry e fluxo local build -> K3s containerd;
- [x] adicionar validação automatizada que gera `trace_id` e consulta o trace diretamente no Tempo;
- [x] executar `make otel-go-demo-install` e validar rollout do workload instrumentado;
- [x] executar `make otel-go-demo-test` e confirmar trace ponta a ponta aplicação -> Collector -> Tempo;
- [ ] validar métricas do cluster e targets Prometheus com `make observability-validate`;
- [ ] validar Grafana e dashboards padrão;
- [ ] visualizar o trace no Grafana Explore;
- [ ] revisar consumo de CPU, memória e storage após estabilização;
- [ ] revisar alertas incompatíveis/ruidosos no K3s;
- [ ] logs com Loki;
- [ ] configurar correlação metrics -> traces -> logs;
- [ ] demonstrar propagação distribuída entre dois serviços instrumentados;
- [ ] dashboards adicionais de recursos/workloads;
- [ ] alertas essenciais customizados.

## Fase 7 — GitOps

- [ ] escolher Argo CD ou Flux;
- [ ] bootstrap GitOps;
- [ ] aplicações reconciliadas a partir do Git;
- [ ] definir promoção/rollback;
- [ ] integrar secrets criptografados.

## Fase 8 — Disaster Recovery

Objetivo: reconstruir um servidor a partir de Debian limpo + Git + backups.

- [x] documentar pré-requisitos externos e sequência de rehearsal em `docs/disaster-recovery.md`;
- [x] adicionar readiness check somente leitura para Git, SOPS/age, Restic/R2 e backup local;
- [x] validar `make dr-readiness` no host atual;
- [x] implementar rehearsal isolado que restaura o snapshot K3s diretamente do R2 sem tocar no cluster ativo;
- [x] validar `make dr-r2-rehearsal` no host atual;
- [x] implementar export verificado do archive/checksum diretamente do R2 para transferência ao alvo DR;
- [x] implementar marker explícito e guards contra hostname/IP de produção no alvo de rehearsal;
- [x] implementar restore destrutivo somente para alvo explicitamente marcado como DR, com confirmação adicional e safety copy do estado inicial do alvo;
- [x] adicionar inventário Ansible de exemplo para um host DR separado;
- [ ] garantir cópia off-host independente da identidade privada age;
- [ ] provisionar/automatizar um host ou VM isolado para rehearsal — adiado até existir hardware/VM disponível;
- [ ] restaurar K3s em ambiente separado;
- [ ] restaurar infraestrutura Kubernetes;
- [ ] restaurar dados de aplicações quando existirem;
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
