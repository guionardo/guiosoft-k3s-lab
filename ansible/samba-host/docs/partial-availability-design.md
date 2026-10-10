# Samba: disponibilidade parcial e proteção contra mountpoints ausentes

Status: **proposta de arquitetura; não implantada** (2026-10-10).

## Decisão

A indisponibilidade de um volume não deve derrubar os compartilhamentos saudáveis.
Entretanto, um volume não validado **não pode ser exposto**, nem como diretório vazio
no filesystem subjacente. O script `scripts/check_share_mounts.py` permanece
um diagnóstico global, com exit code diferente de zero quando qualquer share falha.

## Modelo de publicação

1. Executar preflight **antes** de gerar a configuração ativa.
2. Para cada compartilhamento, verificar mountpoint exato, UUID do dispositivo,
   tipo de filesystem e modo `ro`/`rw` esperado.
3. Renderizar apenas os compartilhamentos validados em uma configuração
   **gerada**, distinta do candidato estático atual. Um volume ausente deve
   resultar em share **não publicado**, nunca em um caminho alternativo.
4. Validar o arquivo gerado com `testparm` e efetuar troca atômica e reload
   controlado **somente após aprovação explícita de implantação**.
5. Falhas de validação devem manter o estado seguro; não transformar um
   compartilhamento anteriormente válido em exposição de um diretório
   desmontado. A proteção em runtime é obrigatória.

## Risco de runtime e política de segurança

Apenas omitir o share na geração inicial **não é suficiente**: após um unmount,
o `smbd` poderia continuar servindo o path configurado. Portanto, a implantação
deverá exigir uma barreira adicional que impeça desmontagem inesperada enquanto
o serviço expõe o volume, ou uma política confiável de despublicação imediata
e bloqueio de acesso quando a montagem desaparecer. Uma checagem periódica
isolada tem janela de exposição e não satisfaz esse requisito.

Investigar e testar integração com unidades `systemd` por mountpoint,
dependências `RequiresMountsFor` (avaliando efeito global), unidades específicas,
e controles de acesso por share. **Não ativar** apenas com preflight de startup.

## Comportamento esperado no estado atual

- Publicáveis após validação: Documentos, Desenvolvimento, Temporarios, DevBin.
- Não publicáveis: Fotos, BackupAntigo, ProjetosAntigos (desmontados).
- A configuração candidata existente contém os sete shares e **não deve
  ser aplicada** enquanto os históricos estiverem desmontados.
- O risco de exposição de segredos em todo `/mnt/dev` permanece registrado.

## Critérios para próxima implementação

- Testes unitários para UUID incorreto, filesystem divergente, `rw` em histórico,
  mountpoint ausente e falhas de ferramentas.
- Evitar divergência entre a matriz Ansible e o diagnóstico Python.
- Testes de evento de desmontagem durante uma sessão SMB, em laboratório.
- Revisão de permissões, autenticação e firewall antes de habilitar `smbd`.
- Mudanças em `/etc/samba`, fstab, mountpoints, serviços e firewall exigem
  autorização específica e plano de rollback.

## Evidência de testes — 2026-10-10

Execução pelo operador no host Debian: `python3 -m unittest discover -s ansible/samba-host/tests -p 'test_*.py' -v` retornou **28 testes, OK** (incluindo 7 testes novos do preflight, 2 de integração com `findmnt` e testes da transação histórica de fstab). O comando `python3 ansible/samba-host/scripts/check_share_mounts.py --eligible-json` retornou `eligible = [Documentos, Desenvolvimento, Temporarios, DevBin]` e `blocked = [Fotos, BackupAntigo, ProjetosAntigos]`, cada um por `mountpoint ausente`; exit code **1**, esperado para diagnóstico global com bloqueios. Não foram realizados testes SMB reais nem testes de unmount durante sessão. A seleção `eligible` é apenas relatório, **não** uma autorização de publicação ou configuração ativa.

## Protótipo de renderização seletiva — 2026-10-10

Criado `scripts/render_eligible_smb.py`: recebe o relatório JSON de `check_share_mounts.py --eligible-json` e gera **somente** um candidato offline; rejeita shares desconhecidos, repetidos, ausentes e bloqueios sem justificativa. Se todos estiverem bloqueados, gera apenas a seção global. Testes simulados em `tests/test_render_eligible_smb.py` (6 cenários). **Ainda não executados no host.**

Exemplo seguro, a partir da raiz do repositório (o primeiro comando retorna `1` quando há bloqueios; por isso não encadear com `&&`):

```bash
python3 ansible/samba-host/scripts/check_share_mounts.py --eligible-json > /tmp/samba-eligibility.json
python3 ansible/samba-host/scripts/render_eligible_smb.py /tmp/samba-eligibility.json --output /tmp/smb-eligible-candidate.conf
testparm -s /tmp/smb-eligible-candidate.conf
```

O arquivo de saída **não é sobrescrito** se já existir. Remover arquivos temporários após validação. **Limitações bloqueantes:** o protótipo replica metadados e política Samba do Ansible (risco de divergência), não prova frescor/autenticidade do relatório e não garante proteção contra unmount em runtime. Não copiar para `/etc/samba`, não iniciar serviço e não integrar a pipeline de aplicação até resolver essas limitações.
