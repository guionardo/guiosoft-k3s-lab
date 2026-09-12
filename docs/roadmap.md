# Roadmap

## Fase 0 — Discovery e limpeza pré-K3s

- [x] discovery read-only do host Debian 13;
- [x] mapear hardware, discos, mounts, portas, serviços, Docker/containerd e Cloudflare Tunnel;
- [x] excluir `escoteirando-suite` e `gitea` do escopo de migração;
- [x] remover Tailscale e validar ausência no preflight;
- [x] remover publicação OpenShip no Cloudflare;
- [x] remover `traefik.guiosoft.info`;
- [ ] confirmar situação local do OpenShip;
- [ ] remover `git.guiosoft.info`;
- [ ] remover `git-ssh.guiosoft.info`;
- [x] auditar firewall/listeners após bootstrap do K3s;
- [x] consolidar estado atual em documentação versionada.

## Fase 1 — Infrastructure as Code

- [x] inventário e roles Ansible para base, storage, K3s e tooling;
- [x] playbooks preflight/bootstrap/storage/K3s;
- [x] Helm pinado via Ansible;
- [x] Terraform Cloudflare provider v5;
- [x] importar Tunnel, configuração remota e wildcard DNS e obter `No changes`;
- [x] SOPS + age com round-trip e fluxo de Kubernetes Secret cifrado;
- [x] Makefile como interface operacional principal;
- [ ] role `firewall` somente após classificação final dos serviços LAN/cluster/loopback.

## Fase 2 — K3s

- [x] instalar `v1.36.4+k3s1` via Ansible;
- [x] configurar `kubectl` e kubeconfig para usuário administrativo local;
- [x] validar `kubectl` sem `sudo`;
- [x] adicionar `make kubeconfig-external` com `InternalIP` em vez de loopback;
- [x] validar kubeconfig e `kubectl` a partir de outra máquina da LAN;
- [x] validar node, CoreDNS, Traefik e local-path;
- [x] namespace `lab` e workload de teste;
- [x] troubleshooting básico documentado.

## Fase 3 — Networking e Cloudflare

- [x] validar Traefik e Ingress internamente;
- [x] manter inicialmente `cloudflared` no host;
- [x] publicar `k3s-test.guiosoft.info`;
- [x] corrigir wildcard Tunnel para `http://127.0.0.1:80`;
- [x] apontar `*.guiosoft.info` para o Tunnel;
- [x] validar Cloudflare -> Tunnel -> Traefik -> Ingress -> Service -> Pod;
- [x] definir padrão de Ingress e 404 para hosts desconhecidos;
- [x] colocar Tunnel/config/wildcard sob Terraform;
- [ ] migrar `cloudflared` para Kubernetes somente depois das demais fundações.

## Fase 4 — Workloads

Para cada workload futuro:

1. identificar runtime/dependências;
2. classificar dados persistentes;
3. criar manifests/Helm;
4. testar internamente;
5. testar hostname temporário quando necessário;
6. mudar rota Cloudflare;
7. observar e manter rollback simples;
8. remover instalação anterior apenas depois da validação.

## Fase 5 — Storage e backup

- [x] layout `/srv/k3s` mapeado para discos existentes;
- [x] role de storage não destrutivo;
- [x] `local-path` abaixo de `/mnt/store1/k3s/local-path`;
- [x] teste de PVC/persistência e reprovisionamento no path correto;
- [x] backup local verificável do SQLite + server token;
- [x] restore rehearsal não destrutivo;
- [x] systemd timer + retenção local;
- [x] Cloudflare R2 como destino off-host;
- [x] bucket R2 por Terraform com `prevent_destroy`;
- [x] credenciais R2/Restic cifradas com SOPS + age;
- [x] round-trip Restic -> R2 -> restore por SHA-256;
- [x] cadeia automatizada local -> R2 e `restic check`;
- [x] inventário read-only de PVC/PV;
- [ ] validar round-trip local do Restic;
- [ ] estratégia para bancos de dados e PVCs de aplicações reais;
- [ ] restore completo em host/VM DR;
- [ ] testes periódicos de restore.

## Fase 6 — Observabilidade

### Métricas

- [x] definir e instalar `kube-prometheus-stack` `89.2.0`;
- [x] Prometheus, Alertmanager, Grafana, Operator, kube-state-metrics e node-exporter em `Running`;
- [x] PVCs Prometheus 10 GiB e Grafana 2 GiB em `local-path`;
- [x] provisionar automaticamente datasources Prometheus, Tempo e Loki no Grafana;
- [x] validar reload/provisioning dos datasources Grafana;
- [x] executar/revisar `make observability-validate`: 13/13 scrape targets `up`, query `up` com 13 séries, datasources Prometheus/Tempo/Loki com health `OK`, Pods Ready e PVCs Bound;
- [x] instrumentar o demo Go com counters, histograms e gauge Prometheus de baixa cardinalidade;
- [x] adicionar `ServiceMonitor` para `otel-go-demo` e `otel-go-downstream`;
- [x] adicionar `make otel-go-demo-metrics-test` com geração de tráfego e queries à API do Prometheus;
- [x] validar em runtime as métricas customizadas do demo no Prometheus (frontend, histogram buckets, downstream e serviço downstream);
- [x] adicionar dashboard customizado `OTel Go Demo - Application Metrics`;
- [x] adicionar regras `OtelGoDemoHighErrorRate`, `OtelGoDemoHighP95Latency` e `OtelGoDemoDownstreamErrors`;
- [x] validar em runtime a reconciliação das regras customizadas pelo Prometheus Operator;
- [x] implementar `make otel-go-demo-incident-test` com falha downstream controlada e restauração automática;
- [x] validar em runtime o incident drill completo: HTTP 502 -> métricas -> alerta pending/firing -> Loki -> Tempo -> recuperação;
- [ ] revisar dashboards Grafana padrão;
- [ ] revisar alertas ruidosos/incompatíveis com K3s.

### Traces

- [x] Tempo chart `2.2.3` single-binary;
- [x] OpenTelemetry Collector chart `0.172.1`;
- [x] pipeline OTLP Collector -> Tempo;
- [x] datasource Tempo no Grafana;
- [x] PVC Tempo de 5 GiB `Bound`;
- [x] workload Go instrumentado;
- [x] validar trace real aplicação -> Collector -> Tempo por `trace_id`;
- [x] implementar segundo serviço Go e propagação W3C `traceparent` entre processos;
- [x] adaptar `make otel-go-demo-test` para exigir os dois `service.name` no mesmo trace;
- [x] validar em runtime o trace distribuído `otel-go-demo -> otel-go-downstream`;
- [x] validar trace visualmente no Grafana Explore.

### Logs

- [x] escolher Grafana Alloy em vez de Promtail (EOL em 2026);
- [x] definir Loki community chart `18.5.0` em modo `Monolithic`;
- [x] definir Alloy chart `1.12.1` com coleta de Pod logs via Kubernetes API;
- [x] configurar Loki TSDB/filesystem, PVC 5 GiB e retenção inicial de 7 dias;
- [x] adicionar datasource Loki e derived field `TraceID` -> Tempo;
- [x] adicionar `tracesToLogsV2` Tempo -> Loki;
- [x] adaptar demo Go para escrever `trace_id` nos logs;
- [x] adicionar `make observability-logging-install/status/test`;
- [x] instalar Loki + Alloy no cluster;
- [x] validar Loki/Alloy operacionais e gateway acessível;
- [x] validar ingestão Alloy -> Loki;
- [x] validar `make observability-logging-test` usando o mesmo `trace_id` da requisição;
- [x] validar navegação Loki log -> Tempo trace e Tempo trace -> Loki logs no Grafana.

### Capacidade

- [x] registrar baseline inicial de recursos com a stack completa: node em ~782m CPU (13%) e ~8331 MiB RAM (52%); maiores consumidores observados foram Grafana ~440 MiB e Prometheus ~337 MiB;
- [ ] revisar consumo novamente após período maior de retenção/carga;
- [x] adicionar dashboard/alertas customizados essenciais para o demo de aplicação;
- [ ] adicionar exemplars/span metrics quando houver benefício real.

## Fase 7 — GitOps

- [ ] escolher Argo CD ou Flux;
- [ ] bootstrap GitOps;
- [ ] reconciliar aplicações a partir do Git;
- [ ] promoção/rollback;
- [ ] secrets cifrados integrados.

## Fase 8 — Disaster Recovery

- [x] documentação, readiness check e rehearsal isolado via R2;
- [x] export verificado do archive/checksum;
- [x] guards explícitos para alvo DR;
- [x] restore destrutivo implementado somente para host marcado;
- [x] inventário Ansible de exemplo para DR;
- [ ] cópia off-host independente da identidade privada age;
- [ ] provisionar VM/host isolado — adiado até existir recurso disponível;
- [ ] restaurar K3s e aplicações em ambiente separado;
- [ ] teste completo de reconstrução e registro de RTO/RPO.

## Fase 9 — Segundo nó

- [ ] adicionar K3s agent/server;
- [ ] scheduling, affinity, taints/tolerations e DaemonSets;
- [ ] cordon/drain e simulação de indisponibilidade;
- [ ] avaliar storage distribuído apenas quando houver benefício real.

## Fase 10 — Documentação de estudo e publicação

Ao final do projeto, consolidar a experiência em material independente do README operacional.

- [ ] produzir uma documentação detalhada, cronológica e reproduzível do processo completo;
- [ ] explicar objetivos, arquitetura inicial e arquitetura final;
- [ ] registrar decisões arquiteturais, alternativas consideradas, trade-offs e motivos das escolhas;
- [ ] incluir problemas encontrados, hipóteses incorretas, correções e troubleshooting relevante;
- [ ] incluir evidências dos testes realizados e critérios usados para considerar cada etapa validada;
- [ ] transformar a documentação em material de estudo sobre K3s/Kubernetes, IaC, storage, backup, Cloudflare e observabilidade;
- [ ] manter referências e fontes oficiais usadas durante cada etapa;
- [ ] produzir uma versão editorial em formato de artigo técnico para blog;
- [ ] produzir uma versão condensada e adequada para publicação no LinkedIn;
- [ ] revisar o material para remover secrets, IDs desnecessários e informações sensíveis antes da publicação.
