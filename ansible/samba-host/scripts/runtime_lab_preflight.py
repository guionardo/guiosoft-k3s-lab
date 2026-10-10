#!/usr/bin/env python3
"""Read-only prerequisites for an isolated Samba unmount laboratory.

No services, mounts, permissions, firewall, or system configuration are changed.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys


def check_command(name):
    path = shutil.which(name)
    if not path:
        for directory in ("/usr/sbin", "/sbin", "/usr/bin", "/bin"):
            candidate = os.path.join(directory, name)
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                path = candidate
                break
    return {"command": name, "available": bool(path), "path": path}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emitir JSON")
    args = parser.parse_args()
    checks = [check_command(name) for name in (
        "unshare", "mount", "umount", "losetup", "mkfs.ext4",
        "smbd", "testparm", "smbclient", "findmnt"
    )]
    environment = {
        "platform": sys.platform,
        "effective_uid": os.geteuid() if hasattr(os, "geteuid") else None,
        "commands": checks,
        "notes": [
            "Diagnostico somente leitura; nao cria mount namespaces.",
            "Nao executar testes de unmount em volumes reais.",
            "A presenca de ferramentas nao comprova permissao para mount namespaces.",
            "A protecao em runtime permanece nao validada.",
        ],
    }
    if args.json:
        print(json.dumps(environment, ensure_ascii=False, indent=2))
    else:
        for item in checks:
            print(f'{"OK" if item["available"] else "AUSENTE"}: {item["command"]} ({item["path"] or "-"})')
        for note in environment["notes"]:
            print(f"NOTA: {note}")
    return 0 if sys.platform == "linux" and all(item["available"] for item in checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
