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

O K3s passa a receber no seu `config.yaml`:

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

Uma estratégia de backup válida ainda deve incluir cópia off-host e testes reais de restore.

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

Foi adicionado um workload de validação em:

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

O primeiro comando aplica o novo `default-local-storage-path` e reinicia o K3s se a configuração mudou. O segundo cria o PVC/Deployment e mostra o marker. O terceiro apaga o Pod; o Deployment cria outro Pod e o mesmo marker deve continuar disponível.

Para inspecionar o volume:

```bash
make storage-test-status
kubectl get pv
```

Depois da validação, o workload de teste pode ser removido com:

```bash
make storage-test-delete
```

Como o StorageClass `local-path` possui política de reclaim `Delete`, remover o PVC também remove o PV e o diretório provisionado para esse volume. Portanto, esse target é adequado apenas ao PVC descartável de teste.

## Limitação importante

`local-path` é armazenamento local ao nó. Um Pod que usa esse PV fica associado ao nó que contém os dados. Isso funciona bem no cluster single-node atual, mas não fornece replicação nem alta disponibilidade quando um segundo nó for adicionado.

## Próximas etapas

Depois da validação real do PVC no host:

1. confirmar que o PV foi criado fisicamente sob `/mnt/store1/k3s/local-path`;
2. remover/recriar o Pod e confirmar persistência;
3. definir política para bancos de dados;
4. implementar backup local automatizado;
5. adicionar destino off-host;
6. executar restore real.

## Fontes

- K3s — Volumes and Storage: https://docs.k3s.io/add-ons/storage
- Rancher local-path-provisioner: https://github.com/rancher/local-path-provisioner
- Manifest padrão do local storage no K3s: https://github.com/k3s-io/k3s/blob/main/manifests/local-storage.yaml
