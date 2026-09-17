# Série de artigos — guiosoft.info K3s Lab

Rascunhos editoriais para publicação no LinkedIn sobre a evolução real do projeto `guiosoft-k3s-lab`.

A série evita o formato de tutorial linear. O objetivo é registrar decisões de engenharia, erros encontrados, validações executadas e como um homelab inicialmente simples evoluiu para uma plataforma reproduzível e recuperável.

## Artigos

1. [De um servidor Debian a uma plataforma Kubernetes em casa](01-k3s-homelab.md)
2. [Observabilidade de verdade em um Kubernetes pequeno](02-observabilidade.md)
3. [GitOps, secrets e infraestrutura reproduzível](03-gitops-secrets-iac.md)
4. [Backup não significa Disaster Recovery](04-backup-nao-e-dr.md)
5. [Medindo Disaster Recovery: reduzindo o RTO em 29,9%](05-medindo-disaster-recovery.md)
6. [O problema dos backups consistentes em Kubernetes](06-backup-consistente.md)

## Linha editorial

Os textos foram escritos a partir do que foi efetivamente implementado e validado neste repositório. Números de versões, RTO, janelas de consistência e resultados de testes devem ser atualizados se novos rehearsals alterarem o estado do projeto antes da publicação.

A intenção é publicar os artigos separadamente, mantendo cada texto autocontido e usando o final de um artigo como ponte natural para o próximo.
