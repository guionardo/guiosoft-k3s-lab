# Storage

## Objetivo

Preparar um layout previsível para dados persistentes do K3s sem formatar discos, mover dados existentes ou alterar o `local-path` atual antes de uma validação explícita.

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

Destino planejado para volumes provisionados pelo `local-path-provisioner`.

Nesta etapa o StorageClass atual do K3s **não é alterado**. A mudança será feita somente depois de validar o layout e testar criação/remoção de PVCs.

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
- não altera o StorageClass atual;
- não migra volumes existentes.

## Próximas etapas

Depois da validação do role no host:

1. testar o layout e capacidade observada;
2. configurar o `local-path-provisioner` para usar `/srv/k3s/local-path`;
3. criar um PVC de teste;
4. escrever e ler dados no PVC;
5. remover/recriar o Pod e confirmar persistência;
6. definir política para bancos de dados;
7. implementar backup local automatizado;
8. adicionar destino off-host;
9. executar restore real.
