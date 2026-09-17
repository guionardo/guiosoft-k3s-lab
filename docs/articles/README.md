# Série de artigos — guiosoft.info K3s Lab

Artigos para publicação sobre a evolução real do projeto `guiosoft-k3s-lab`.

A série evita o formato de tutorial linear. O objetivo é registrar decisões de engenharia, erros encontrados, validações executadas e como um homelab inicialmente simples evoluiu para uma plataforma reproduzível e recuperável.

Os artigos estão disponíveis em **Português**, **English** e **Español**. Diagramas de arquitetura e fluxo usam MermaidJS sempre que uma representação visual melhora a leitura.

## Artigos / Articles / Artículos

| # | Português | English | Español |
|---|---|---|---|
| 1 | [De um servidor Debian a uma plataforma Kubernetes em casa](01-k3s-homelab.md) | [From a Debian server to a Kubernetes platform at home](en/01-k3s-homelab.md) | [De un servidor Debian a una plataforma Kubernetes en casa](es/01-k3s-homelab.md) |
| 2 | [Observabilidade de verdade em um Kubernetes pequeno](02-observabilidade.md) | [Real observability in a small Kubernetes cluster](en/02-observability.md) | [Observabilidad real en un Kubernetes pequeño](es/02-observabilidad.md) |
| 3 | [GitOps, secrets e infraestrutura reproduzível](03-gitops-secrets-iac.md) | [GitOps, secrets, and reproducible infrastructure](en/03-gitops-secrets-iac.md) | [GitOps, secrets e infraestructura reproducible](es/03-gitops-secrets-iac.md) |
| 4 | [Backup não significa Disaster Recovery](04-backup-nao-e-dr.md) | [Backup does not mean Disaster Recovery](en/04-backup-is-not-dr.md) | [Backup no significa Disaster Recovery](es/04-backup-no-es-dr.md) |
| 5 | [Medindo Disaster Recovery: reduzindo o RTO em 29,9%](05-medindo-disaster-recovery.md) | [Measuring Disaster Recovery: reducing RTO by 29.9%](en/05-measuring-disaster-recovery.md) | [Midiendo Disaster Recovery: reduciendo el RTO un 29,9%](es/05-midiendo-disaster-recovery.md) |
| 6 | [O problema dos backups consistentes em Kubernetes](06-backup-consistente.md) | [The problem of consistent backups in Kubernetes](en/06-consistent-backups.md) | [El problema de los backups consistentes en Kubernetes](es/06-backups-consistentes.md) |

## Linha editorial

Os textos foram escritos a partir do que foi efetivamente implementado e validado neste repositório. Números de versões, RTO, janelas de consistência e resultados de testes devem ser atualizados se novos rehearsals alterarem o estado do projeto antes da publicação.

A intenção é publicar os artigos separadamente, mantendo cada texto autocontido e usando o final de um artigo como ponte natural para o próximo. As três versões linguísticas devem permanecer estruturalmente alinhadas, preservando os mesmos fatos, medições e diagramas.
