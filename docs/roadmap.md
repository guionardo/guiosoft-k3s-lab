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
- [x] classificar serviços LAN/cluster/loopback e implementar role `firewall` isolado em nftables;
- [x] validar live trial do firewall com rollback automático e testes externos pela LAN;
- [x] configurar persistência via `guiosoft-host-firewall.service` sem tomar posse do ruleset global;
- [x] validar persistência do firewall após reboot real do host, com SSH/kubectl LAN, K3s, workloads e Firecrawl funcionais.

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
- [x] corrigir wildcard Tunnel para `http://127.0.0.1:80` durante a fase inicial;
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
- [x] mudar o origin wildcard para `http://192.168.88.9:80`, compatível simultaneamente com o connector host e Pods K3s;
- [x] criar namespace/Deployment/Service/ServiceMonitor para `cloudflared` no Kubernetes;
- [x] armazenar Tunnel token como Kubernetes Secret cifrado com SOPS + age;
- [x] validar connector Kubernetes em paralelo com o systemd do host, incluindo quatro conexões QUIC e configuração remota;
- [x] parar/desabilitar `cloudflared.service` somente após validação pública/LAN com o connector Kubernetes;
- [x] escalar `cloudflared` para duas réplicas e validar tráfego após o cutover exclusivo para K3s;
- [x] preservar temporariamente instalação/configuração systemd como rollback simples durante a janela de observação;
- [ ] pinçar a imagem `cloudflared` por digest após registrar o `imageID` runtime.

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
- [x] adicionar alerta de pouco espaço livre para `/mnt/store1` quando houver necessidade operacional — `K3sLocalPathLowFreeSpace` na Fase 9;
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

- [x] escolher Flux como controlador GitOps;
- [x] instalar/pinar Flux CLI via Ansible;
- [x] bootstrap GitOps no GitHub com acesso runtime via SSH/deploy key;
- [x] validar reconciliação do próprio `flux-system` a partir do Git;
- [x] adotar `cloudflared` como primeiro workload sem downtime;
- [x] integrar secrets cifrados com SOPS + age ao Flux;
- [x] ordenar reconciliação `namespace -> secrets -> workload` com `dependsOn`;
- [x] validar recuperação real do `cloudflared-tunnel-token` após exclusão manual, recriado a partir do Git cifrado;
- [x] validar workload e rota pública após recuperação do Secret, com HTTP 200;
- [x] executar teste controlado de drift manual e validar self-healing para o estado do Git;
- [x] validar mudança versionada e rollback declarativo via Git sem indisponibilidade;
- [x] migrar Firecrawl para Flux com cadeia independente `namespace -> secrets -> workload`;
- [x] validar self-healing do `firecrawl-api` após drift controlado de réplicas, preservando HTTP 200 pela LAN;
- [x] migrar observabilidade/Helm para Flux em ordem conservadora: Alloy -> OpenTelemetry Collector -> Tempo -> Loki -> kube-prometheus-stack;
- [x] validar adoção dos releases existentes sem recriação, preservando versões, PVCs e workloads;
- [x] validar traces distribuídos após adoção de OTel Collector/Tempo e correlação de logs após adoção Loki/Alloy;
- [x] manter todos os cinco HelmReleases de observabilidade ativos e `Ready` sob Flux.

## Fase 8 — Disaster Recovery

- [x] documentação, readiness check e rehearsal isolado via R2;
- [x] export verificado do archive/checksum;
- [x] guards explícitos para alvo DR;
- [x] restore destrutivo implementado somente para host marcado;
- [x] inventário Ansible de exemplo para DR;
- [x] cópia off-host independente da identidade privada age, cifrada com senha de DR separada e validada por restore isolado + descriptografia de Secrets SOPS reais;
- [ ] provisionar VM/host isolado — adiado até existir recurso disponível;
- [ ] restaurar K3s e aplicações em ambiente separado;
- [ ] teste completo de reconstrução e registro de RTO/RPO.

## Fase 9 — Registry OCI LAN-only

- [x] regra de bloqueio `registry.guiosoft.info -> http_status:404` antes do wildcard no Cloudflare Tunnel, declarada no Terraform;
- [x] namespace `registry` e wiring Flux (`registry-namespace -> registry-secrets -> registry`);
- [x] credenciais htpasswd `pusher`/`puller` cifradas com SOPS + age, com Secret aplicado separado do arquivo de senhas (fora da kustomization);
- [x] Zot v2.1.22 pinado por digest com PVC `local-path` de 20Gi (`registry/registry-data`) como cache descartável;
- [x] Ingress `registry.guiosoft.info` via Traefik com certificado autoassinado padrão, pinado ao entrypoint `websecure`;
- [x] retenção das 10 tags pushed mais recentes por repositório, com `gc: true` e intervalo de 24h;
- [x] confiança do containerd (`registries.yaml` com TLS no bloco top-level `configs` + `/etc/hosts`) e timeouts de leitura/escrita do Traefik sem limite, codificados no role Ansible `k3s`;
- [x] validação ponta a ponta com `scripts/registry.sh` e alvos `make registry-status`/`registry-validate`/`registry-login`;
- [x] exclusão do cache do registry do snapshot de PVs, calculada do `claimRef` vivo e com falha ruidosa em resolução ambígua;
- [x] asserção no DR preflight de que o PV do registry está ausente do recovery set;
- [x] alerta `K3sLocalPathLowFreeSpace` (< 15% livre em `/mnt/store1`) via PrometheusRule `registry/registry-storage`;
- [x] documentação operacional em `docs/registry.md`, incluindo o diff de adoção pelo `gh-eva`;
- [ ] `terraform apply` da regra de bloqueio do Tunnel — sem credenciais Cloudflare nesta estação; hoje a rota pública já morre com `404` no Traefik por causa do pin `websecure`;
- [x] split-DNS no MikroTik `registry.guiosoft.info -> 192.168.88.9` — aplicado; a asserção 1 do `validate` passou a resolver para o IP interno;
- [x] playbook Ansible do k3s executado no host: `registries.yaml`, `/etc/hosts` e o `HelmChartConfig` do Traefik aplicados, com pull por Pod comprovado pela asserção 7 (`pod pull (containerd): … pulled successfully`);
- [x] exercer retenção/GC com sonda de 12 tags via `docker push`: 12 tags pushed em `retention-probe-20261106114603`; após restart do zot (GC no startup), restaram 10 (`v3..v12`), `v1` e `v2` evictados (manifests → 404). Confirma que o GC roda no startup e que `delay: 1h` não bloqueia evicção de tags.
- [ ] adotar no `gh-eva`: substituir `docker save` + `ctr images import` por `docker push` + `imagePullSecrets` — bloqueio de TLS resolvido: daemon Docker do nó configurado com `insecure-registries` (push verificado com sucesso);
- [ ] dívida técnica: `puller` consegue push — o zot v2.1.22 autentica o htpasswd mas não impõe separação leitura/escrita; revisar em upgrade do zot ou com camada de autorização na frente.
- [ ] varredura de CVE automatizada (opção B): imagem customizada do Zot com Trivy embutido (multi-stage a partir de `ghcr.io/project-zot/zot:v2.1.22`), habilitar `extensions.search.cve` (updateInterval 2h) no ConfigMap, reiniciar o Pod; scan dispara após o push e resultados aparecem na UI (ícones de bug). Pré-requisito: Pod com saída para `ghcr.io/aquasecurity/trivy-db`. Até lá, scan sob demanda com `trivy image --insecure` na estação.

## Fase 10 — Segundo nó

- [ ] adicionar K3s agent/server;
- [ ] scheduling, affinity, taints/tolerations e DaemonSets;
- [ ] cordon/drain e simulação de indisponibilidade;
- [ ] avaliar storage distribuído apenas quando houver benefício real.

## Fase 12 — Keycloak (OIDC broker)

- [x] namespace `keycloak` e wiring Flux (`keycloak-namespace -> keycloak-secrets -> keycloak`);
- [x] PostgreSQL 16 com PVC `local-path` de 5Gi (`keycloak-postgres-data`) para estado durável;
- [x] Keycloak v26.0.7 com `start` (produção), KC_PROXY=edge, KC_HOSTNAME=https://auth.guiosoft.info;
- [x] Ingress `auth.guiosoft.info` via Traefik com certificado mkcert, pinado ao entrypoint `websecure`;
- [x] secret SOPS `keycloak-secrets` com credenciais de DB e admin (cifradas com age);
- [x] secret TLS `auth-tls` com certificado mkcert (aplicado via kubectl);
- [x] issuer OIDC acessível: `https://auth.guiosoft.info/realms/master` (verificado via OpenID configuration);
- [x] admin console acessível: `https://auth.guiosoft.info/admin/` (HTTP 200);
- [x] split-DNS no MikroTik `auth.guiosoft.info -> 192.168.88.9` — verificado (dig retorna 192.168.88.9);
- [x] regra Terraform `auth.guiosoft.info -> http_status:404` aplicada e verificada (404 de fora da LAN, 200 de dentro);
- [x] criar realm `guiosoft` e configurar Google identity brokering (client secret armazenado no Keycloak DB + SOPS backup);
- [x] provisionar clientes Ariadne (Explorer e CLI) com Authorization Code + PKCE;
- [x] audience mapper `ariadne-api` nos dois clientes públicos;
- [x] claim mappers padrão (email, preferred_username, groups) nos dois clientes públicos;
- [x] redirect URIs ajustados para wildcard de porta (http://localhost:*) — kc_idp_hint=google redireciona para Google (verificado);
- [x] claims verificados: Ariadne lê apenas iss, sub, aud do token. Keycloak já emite iss (https://auth.guiosoft.info/realms/guiosoft), sub (UUID do usuário), aud (ariadne-api). Nenhum mapper customizado necessário (ADR 0008). Tenant é configurado por instância, não via token. Configuração Ariadne: issuer=https://auth.guiosoft.info/realms/guiosoft, audience=ariadne-api, bootstrap.subject=ab332186-528e-43ef-8b0a-3ba3bb9037c3;
- [x] documentar injeção, rotação, backup e restore de segredos (docs/keycloak.md);
- [x] validar login com Google: fluxo completo testado (consent -> callback -> token). Issuer: https://auth.guiosoft.info/realms/guiosoft. Audience: ariadne-api. Claims: email, preferred_username, groups. PKCE S256 verificado.;
- [x] validar logout: endpoint end_session_endpoint e backchannel_logout_supported confirmados;
- [x] rotação de chaves: admin password rotacionada via Admin API (reset-password), senha antiga rejeitada, nova senha funciona. Procedimento documentado em docs/keycloak.md.;
- [x] recovery testado: pg_dump do PostgreSQL (324K, 87 tabelas), drop+recreate do database, restore via psql. Keycloak reiniciou, issuer acessível, admin login OK, clientes e Google IdP preservados.;
- [x] documentar como adicionar um novo provedor sem alterar o Ariadne (docs/keycloak.md).

## Fase 11 — Documentação de estudo e publicação

Ao final do projeto, consolidar a experiência em material independente do README operacional.

- [ ] produzir narrativa cronológica reproduzível;
- [ ] registrar arquitetura inicial e final;
- [ ] consolidar decisões, alternativas e trade-offs;
- [ ] registrar hipóteses erradas, falhas e correções;
- [ ] anexar evidências/testes e fontes oficiais;
- [ ] produzir artigo longo para blog;
- [ ] produzir versão condensada para LinkedIn;
- [ ] revisar todo o material para remover dados sensíveis antes da publicação.
