# Storage

## Objetivo

Preparar um layout previsível para dados persistentes do K3s sem formatar discos, mover dados existentes ou alterar dados já existentes no host.

## Discos utilizados nesta fase

O laboratório reutiliza os mounts já existentes:

```text
/mnt/store1   -> armazenamento primário para dados persistentes do cluster
/mnt/store2   -> área local de staging para backups
```

O NVMe montado em `/mnt/dev` não entra no layout do K3s porque permanece reservado prioritariamente para código e desenvolvimento.

## Namespace estável

Aplicações e automações devem preferir caminhos sob:

```text
/srv/k3s
```

O role `storage` cria os seguintes links estáveis:

```text
/srv/k3s/local-path  -> /mnt/store1/k3s/local-path
/srv/k3s/persistent  -> /mnt/store1/k3s/persistent
/srv/k3s/backups     -> /mnt/store2/k3s/backups
```

Isso separa o caminho lógico usado pela infraestrutura da localização física atual dos discos.

## Responsabilidade de cada diretório

### `/srv/k3s/local-path`

Área dedicada aos volumes provisionados dinamicamente pelo `local-path-provisioner` do K3s.

O K3s recebe no seu `config.yaml`:

```yaml
default-local-storage-path: /mnt/store1/k3s/local-path
```

O caminho físico é usado diretamente pelo K3s para evitar depender da resolução de symlink dentro do fluxo de provisionamento. O link `/srv/k3s/local-path` continua sendo o nome lógico para administração humana e automações do host.

A alteração vale para novos volumes. Não existe migração automática de PVs antigos para o novo caminho.

### `/srv/k3s/persistent`

Dados persistentes explicitamente administrados, por exemplo bancos de dados ou aplicações que precisem de um caminho de host estável e conhecido.

Isso não implica que todo workload deva usar `hostPath`. Para aplicações normais, PVC continua sendo a interface preferencial.

### `/srv/k3s/backups`

Área local para staging de backups. Ela está em outro disco físico em relação ao armazenamento primário, mas **não é considerada backup definitivo**.

A cópia off-host atual usa Restic sobre Cloudflare R2.

## Capacidade declarada de PVCs no `local-path`

No perfil atual do laboratório, um PVC como:

```yaml
resources:
  requests:
    storage: 10Gi
```

**não pré-aloca nem reserva 10 GiB no filesystem do host**. O `local-path-provisioner` cria um diretório local para o volume e o consumo físico cresce conforme arquivos são realmente gravados.

Em outras palavras:

```text
PVC request = capacidade declarada ao Kubernetes
            ≠ espaço pré-alocado no disco
            ≠ reserva física garantida
            ≠ quota rígida do diretório
```

Se cinco PVCs declararem juntos 32 GiB, mas seus arquivos ocuparem apenas 6 GiB, o uso real do filesystem ficará próximo desses 6 GiB, somado ao overhead normal do filesystem.

Também é importante não interpretar `capacity: 10Gi` como uma quota forte do ext4 usado atualmente. O provisionador local não cria automaticamente uma quota de filesystem para aquele diretório. Portanto, um workload pode consumir mais espaço físico que o valor nominal do PVC enquanto o filesystem subjacente ainda tiver espaço disponível.

Consequências operacionais:

- existe possibilidade de **overcommit** de storage declarado;
- a soma da capacidade dos PVCs não representa espaço já ocupado ou garantido;
- o risco real é o filesystem `/mnt/store1` ficar cheio;
- capacidade livre do filesystem deve ser monitorada independentemente da capacidade nominal dos PVCs;
- para workloads realmente críticos, backup e observabilidade de disco continuam obrigatórios mesmo com PVC definido.

Prometheus/node-exporter já fornece métricas adequadas para acompanhar isso, como:

```text
node_filesystem_avail_bytes
node_filesystem_size_bytes
```

Um alerta específico para pouco espaço livre em `/mnt/store1` pode ser adicionado quando houver workloads persistentes relevantes.

## Regras de segurança do role Ansible

O role `storage` é deliberadamente conservador:

- exige que `/mnt/store1` e `/mnt/store2` já estejam montados;
- aborta se algum mount esperado não estiver disponível, evitando gravar acidentalmente no filesystem raiz;
- cria apenas diretórios e links simbólicos;
- não formata nem particiona discos;
- não altera `/etc/fstab`;
- não move dados existentes;
- não remove arquivos;
- não migra volumes existentes.

## Teste de persistência

O workload de validação está em:

```text
kubernetes/storage/persistence-test.yaml
```

Ele cria:

- um PVC `ReadWriteOnce` de 16 MiB usando `storageClassName: local-path`;
- um Deployment com BusyBox;
- um arquivo `/data/marker.txt` criado somente quando ainda não existe.

Fluxo de validação:

```bash
make k3s
make storage-test
make storage-test-recreate
```

O primeiro comando aplica o `default-local-storage-path` e reinicia o K3s se a configuração mudou. O segundo cria o PVC/Deployment e mostra o marker. O terceiro apaga apenas o Pod; o Deployment cria outro Pod e o mesmo marker deve continuar disponível.

Para inspecionar o volume:

```bash
make storage-test-status
make storage-test-placement
```

`make storage-test-placement` aceita PVs representados por `spec.hostPath.path` ou `spec.local.path` e exige que o caminho físico esteja abaixo de:

```text
/mnt/store1/k3s/local-path
```

## Reprovisionamento validado

O inventário inicial mostrou que o primeiro PVC de teste havia sido criado no path legado:

```text
/var/lib/rancher/k3s/storage
```

Como `default-local-storage-path` só afeta novos volumes, isso era esperado para um PV anterior à mudança de configuração.

O PVC descartável foi então reprovisionado e a localização física foi validada com sucesso usando:

```bash
make storage-test-reprovision
make storage-test-placement
```

O novo PV foi confirmado abaixo de `/mnt/store1/k3s/local-path`, comprovando que novos volumes seguem o layout desejado.

Depois da validação, o workload de teste pode ser removido com:

```bash
make storage-test-delete
```

Como o StorageClass `local-path` possui política de reclaim `Delete`, remover o PVC também remove o PV e o diretório provisionado para esse volume. Portanto, esse target é adequado apenas ao PVC descartável de teste.

## Estado atual dos dados de aplicação

A stack de observabilidade já utiliza PVCs reais em `local-path` para Prometheus, Grafana, Tempo e Loki. Esses volumes são operacionais e reconstruíveis a partir da configuração, mas contêm histórico útil de métricas, dashboards/estado do Grafana, traces e logs.

O Firecrawl, no perfil inicial de migração definido em setembro de 2026, **não usa PVC para PostgreSQL, Redis ou RabbitMQ**. Esses componentes foram deliberadamente classificados como efêmeros nesta etapa e usam `emptyDir`; seus dados podem desaparecer quando o Pod é substituído. Essa decisão pode ser revista se o Firecrawl passar a armazenar dados que precisem sobreviver a recriações.

Para workloads stateful futuros, a política continua sendo:

- bancos de dados críticos: backup nativo/lógico ou físico suportado pela engine;
- arquivos: backup consistente do filesystem, snapshot ou export suportado pela aplicação;
- serviços externos: procedimento específico do provedor;
- stateless/efêmero: reconstrução por Git/IaC.

## Limitação importante

`local-path` é armazenamento local ao nó. Um Pod que usa esse PV fica associado ao nó que contém os dados. Isso funciona bem no cluster single-node atual, mas não fornece replicação nem alta disponibilidade quando um segundo nó for adicionado.

## Próximas etapas

1. monitorar espaço livre de `/mnt/store1` independentemente da soma nominal dos PVCs;
2. classificar cada futuro workload stateful no momento em que for introduzido;
3. implementar backup nativo para bancos de dados reais;
4. implementar backup de PVCs file-oriented reais;
5. executar disaster recovery completo em ambiente separado;
6. reavaliar storage quando houver segundo nó.

## Fontes

- K3s — Volumes and Storage: https://docs.k3s.io/add-ons/storage
- Rancher local-path-provisioner: https://github.com/rancher/local-path-provisioner
- Manifest padrão do local storage no K3s: https://github.com/k3s-io/k3s/blob/main/manifests/local-storage.yaml
- Kubernetes — Persistent Volumes: https://kubernetes.io/docs/concepts/storage/persistent-volumes/
