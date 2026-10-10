#!/usr/bin/env python3
"""Read-only readiness check and experiment plan for a disposable Samba VM.

Never mounts/unmounts, starts services, creates users or modifies configuration.
There is deliberately no --execute option.
"""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys

REQUIRED = ("smbd", "smbclient", "testparm", "findmnt", "mount", "umount")
STEPS = (
    "Snapshot da VM descartavel e rede isolada",
    "Criar sentinela UNDERLYING_DO_NOT_EXPOSE no diretorio subjacente",
    "Montar filesystem descartavel verificado por UUID; criar MOUNTED_VISIBLE",
    "Validar configuracao Samba de laboratorio e iniciar apenas na VM",
    "Abrir sessao SMB autenticada; confirmar visibilidade apenas de MOUNTED_VISIBLE",
    "Tentar umount normal, sem -f/-l; registrar busy e nao forcar",
    "Se desmontado, testar sessao antiga e nova contra sentinela subjacente",
    "Revalidar identidade do volume antes de qualquer republicacao",
)


def check(platform, marker, tools=None, uid=None):
    """Marker is an explicit opt-in file in VM, not proof of isolation."""
    tools = tools or shutil.which
    uid = os.geteuid() if uid is None else uid
    result = {
        "mode": "dry-run-only",
        "platform": platform,
        "effective_uid": uid,
        "vm_marker": str(marker),
        "vm_marker_present": marker.is_file(),
        "commands": {cmd: tools(cmd) for cmd in REQUIRED},
        "steps": list(STEPS),
        "warnings": [
            "Marcador nao prova isolamento: revisar VM, rede e volumes manualmente",
            "Nao executar unmount no host K3s",
            "Este programa nao executa nenhuma etapa do experimento",
        ],
    }
    result["ready_for_manual_review"] = (
        platform == "linux"
        and result["vm_marker_present"]
        and all(result["commands"].values())
    )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emitir plano e checklist JSON")
    parser.add_argument("--vm-marker", type=pathlib.Path,
                        default=pathlib.Path("/etc/samba-lab-disposable-vm"),
                        help="arquivo de confirmacao criado manualmente na VM")
    args = parser.parse_args()
    report = check(sys.platform, args.vm_marker)
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print("Plano somente leitura: laboratorio de unmount SMB")
        for command, path in report["commands"].items():
            print(f"{command}: {path or 'AUSENTE'}")
        print(f"Marcador de VM: {'presente' if report['vm_marker_present'] else 'ausente'}")
        for index, step in enumerate(report["steps"], 1):
            print(f"{index}. {step}")
        print("Pronto para revisao manual:", report["ready_for_manual_review"])
    return 0 if report["ready_for_manual_review"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
