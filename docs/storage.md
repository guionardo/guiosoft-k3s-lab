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

O inventário mais recente não encontrou PVC real de aplicação. O único PVC existente é `lab/persistence-test`.

Portanto, ainda não há banco de dados ou PVC file-oriented real para proteger. A política será aplicada quando o primeiro workload stateful for introduzido:

- bancos de dados: backup nativo/lógico ou físico suportado pela engine;
- arquivos: backup consistente do filesystem, snapshot ou export suportado pela aplicação;
- serviços externos: procedimento específico do provedor;
- stateless: reconstrução por Git/IaC.

## Limitação importante

`local-path` é armazenamento local ao nó. Um Pod que usa esse PV fica associado ao nó que contém os dados. Isso funciona bem no cluster single-node atual, mas não fornece replicação nem alta disponibilidade quando um segundo nó for adicionado.

## Próximas etapas

1. classificar cada futuro workload stateful no momento em que for introduzido;
2. implementar backup nativo para bancos de dados reais;
3. implementar backup de PVCs file-oriented reais;
4. executar disaster recovery completo em ambiente separado;
5. reavaliar storage quando houver segundo nó.

## Fontes

- K3s — Volumes and Storage: https://docs.k3s.io/add-ons/storage
- Rancher local-path-provisioner: https://github.com/rancher/local-path-provisioner
- Manifest padrão do local storage no K3s: https://github.com/k3s-io/k3s/blob/main/manifests/local-storage.yaml
