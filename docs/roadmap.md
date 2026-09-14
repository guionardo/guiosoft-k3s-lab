# Roadmap

## Fase 0 — Discovery e limpeza pré-K3s

- [x] discovery read-only do host Debian 13;
- [x] mapear hardware, discos, mounts, portas, serviços, Docker/containerd e Cloudflare Tunnel;
- [x] excluir `escoteirando-suite` e `gitea` do escopo de migração;
- [x] remover Tailscale e validar ausência no preflight;
- [x] remover publicação OpenShip no Cloudflare;
- [x] remover `traefik.guiosoft.info`;
- [x] confirmar situação local do OpenShip — nenhuma unidade systemd/container local encontrado;
- [x] remover `git.guiosoft.info`;
- [x] remover `git-ssh.guiosoft.info`;
- [x] auditar firewall/listeners após bootstrap do K3s;
- [x] consolidar estado atual em documentação versionada.

## Fase 1 — Infrastructure as Code

- [x] inventário e roles Ansible para base, storage, K3s e tooling;
- [x] playbooks preflight/bootstrap/storage/K3s;
- [x] Helm pinado via Ansible;
- [x] Terraform Cloudflare provider v5;
- [x] importar Tunnel, configuração remota e wildcard DNS e obter `No changes`;
- [x] criar por Terraform a aplicação Cloudflare Access do Firecrawl e dois Service Tokens independentes para Hermes e OpenCode;
- [x] validar que Service Auth no provider/API usa `decision = "non_identity"`;
- [x] SOPS + age com round-trip e fluxo de Kubernetes Secret cifrado;
- [x] Makefile como interface operacional principal;
- [x] codificar no bootstrap o estado disabled de NFS/RPC, PCP e Cockpit após validação de que são desnecessários;
- [x] manter Avahi deliberadamente enquanto DNS interno/LAN-only é consolidado;
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
- [x] proteger inicialmente `firecrawl.guiosoft.info` com Cloudflare Access Service Auth e tokens separados por agente;
- [x] validar HTTP 401 sem token e acesso funcional autenticado com os tokens Hermes e OpenCode;
- [x] configurar split-DNS no MikroTik para `firecrawl.guiosoft.info -> 192.168.88.9`;
- [x] validar resolução interna por `dig`/`getent` e HTTP 200 direto ao Traefik/Firecrawl;
- [x] validar Firecrawl LAN-only com Hermes;
- [x] validar Firecrawl LAN-only com OpenCode via MCP;
- [x] bloquear explicitamente `firecrawl.guiosoft.info` no Tunnel com `http_status:404` antes do wildcard e validar a rota pública sem prejudicar o acesso LAN;
- [x] remover declarativamente a aplicação Cloudflare Access e os Service Tokens Hermes/OpenCode após o bloqueio público validado;
- [x] validar novamente HTTP pela LAN e HTTPS pela rota pública após o cutover definitivo;
- [ ] migrar `cloudflared` para Kubernetes somente depois das demais fundações.

## Fase 4 — Workloads

Para cada workload futuro:

1. identificar runtime/dependências;
2. classificar dados persistentes;
3. criar manifests/Helm;
4. testar internamente;
5. testar hostname temporário quando necessário;
6. publicar externamente somente quando houver consumidor/requisito real;
7. observar e manter rollback simples;
8. remover instalação anterior apenas depois da validação.

### Firecrawl — primeiro workload real

- [x] auditar stack Docker Compose atual sem expor secrets;
- [x] confirmar os cinco containers, rede privada, porta publicada, limites e volumes;
- [x] associar o volume Docker anônimo ao RabbitMQ em `/var/lib/rabbitmq`;
- [x] identificar os `repo_digest` exatos das cinco imagens em execução;
- [x] pinçar as imagens Kubernetes pelos digests observados em produção;
- [x] documentar estratégia incremental e rollback;
- [x] criar scaffold Kubernetes com namespace, ConfigMap, Services e Deployments;
- [x] classificar PostgreSQL/NuQ, Redis e RabbitMQ como efêmeros nesta primeira fase;
- [x] substituir PVCs Firecrawl por `emptyDir` no perfil atual;
- [x] criar Ingress `firecrawl.guiosoft.info` via Traefik;
- [x] manter apenas a API publicada pelo Ingress; backends continuam `ClusterIP`;
- [x] atualizar validação read-only para exigir Ingress, imagens por digest e ausência de PVCs Firecrawl;
- [x] criar helper para gerar Secret SOPS diretamente do `.env` local sem imprimir valores;
- [x] validar em runtime o scaffold com `make firecrawl-k8s-validate`;
- [x] gerar `firecrawl-secrets.sops.yaml` a partir do `.env` local;
- [x] validar/aplicar o Secret com os targets genéricos SOPS;
- [x] subir a stack K3s e validar os cinco Deployments `Ready`;
- [x] validar rota local Traefik usando `Host: firecrawl.guiosoft.info`;
- [x] validar `https://firecrawl.guiosoft.info` pelo Cloudflare Tunnel durante a fase pública;
- [x] executar request funcional real `POST /v1/scrape` com `success=true` e Markdown retornado;
- [x] registrar baseline pós-scrape: API ~2826 MiB, PostgreSQL ~110 MiB, Playwright ~268 MiB, RabbitMQ ~224 MiB, Redis ~9 MiB;
- [x] comparar baseline com Docker e confirmar perfil de memória compatível, sem evidência de overhead anormal do K3s;
- [x] registrar que a API emite `You're bypassing authentication` com `USE_DB_AUTHENTICATION=false`; tratar como decisão de segurança, não falha de runtime;
- [x] adicionar observação read-only de readiness, restarts, eventos, recursos e warnings/errors por componente;
- [x] investigar os dois restarts iniciais da API: `exit code 1`, sem OOM, causados por `ECONNREFUSED` ao RabbitMQ durante corrida de startup;
- [x] adicionar `initContainer` na API para aguardar PostgreSQL, Redis, RabbitMQ e Playwright antes de iniciar o harness Firecrawl;
- [x] reaplicar o Deployment e validar novo Pod da API com `RESTARTS=0`;
- [x] definir e validar Cloudflare Access Service Auth durante a fase de publicação pública;
- [x] concluir que Access deixou de ser necessário após classificar Hermes/OpenCode como consumidores exclusivamente LAN;
- [x] validar Hermes diretamente contra o hostname resolvido internamente;
- [x] validar OpenCode/Firecrawl via MCP com configuração no objeto `mcp` de `~/.config/opencode/opencode.jsonc`;
- [x] retirar definitivamente Cloudflare Access/Service Tokens e manter Firecrawl LAN-only com bloqueio público explícito no Tunnel;
- [x] observar estabilidade e consumo por um período maior antes da remoção definitiva do runtime antigo;
- [x] parar Docker Compose antigo mantendo rollback simples — containers e volumes preservados;
- [x] observar K3s sozinho após o cutover, com os cinco Pods `Ready`, `RESTARTS=0` e sem warnings relevantes;
- [ ] remover Docker Compose somente após estabilidade suficiente; preservar volumes até o encerramento da janela de rollback.

## Fase 5 — Storage e backup

- [x] layout `/srv/k3s` mapeado para discos existentes;
- [x] role de storage não destrutivo;
- [x] `local-path` abaixo de `/mnt/store1/k3s/local-path`;
- [x] teste de PVC/persistência e reprovisionamento no path correto;
- [x] documentar que capacidade de PVC `local-path` não representa pré-alocação/reserva física nem quota rígida no filesystem atual;
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
- [ ] adicionar alerta de pouco espaço livre para `/mnt/store1` quando houver necessidade operacional;
- [ ] estratégia para bancos de dados e PVCs de aplicações reais;
- [ ] restore completo em host/VM DR;
- [ ] testes periódicos de restore.

## Fase 6 — Observabilidade

A fundação de métricas, traces e logs está operacional e validada. O histórico detalhado de versões, testes, incident drill, alertas e dashboards permanece nos documentos específicos de observabilidade.

- [x] kube-prometheus-stack / Prometheus / Alertmanager / Grafana;
- [x] Tempo + OpenTelemetry Collector;
- [x] Loki + Alloy;
- [x] demo Go com tracing distribuído e métricas customizadas;
- [x] correlação logs <-> traces;
- [x] incident drill completo;
- [x] auditoria de alertas e dashboards;
- [ ] revisar consumo novamente após período maior de retenção/carga;
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

- [ ] produzir narrativa cronológica reproduzível;
- [ ] registrar arquitetura inicial e final;
- [ ] consolidar decisões, alternativas e trade-offs;
- [ ] registrar hipóteses erradas, falhas e correções;
- [ ] anexar evidências/testes e fontes oficiais;
- [ ] produzir artigo longo para blog;
- [ ] produzir versão condensada para LinkedIn;
- [ ] revisar todo o material para remover dados sensíveis antes da publicação.
