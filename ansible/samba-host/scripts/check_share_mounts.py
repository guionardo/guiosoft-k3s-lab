#!/usr/bin/env python3
"""Read-only, fail-closed preflight of Samba share mountpoints.

Reads Linux /proc/self/mountinfo and blkid; never mounts, writes or changes services.
Not wired to smbd startup: this is a standalone diagnostic.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

EXPECTED = (
    ("Documentos", "/mnt/hd500/sdf2", "01D36FD6673F4300", "ntfs", False),
    ("Desenvolvimento", "/mnt/dev", "3ed56e92-ab85-4b9a-8993-d2f1cda6a62e", "ext4", False),
    ("Fotos", "/mnt/fotos", "8CE4EC1DE4EC0AF2", "ntfs", True),
    ("BackupAntigo", "/mnt/backup-antigo", "964C33BF4C3398C7", "ntfs", True),
    ("ProjetosAntigos", "/mnt/projetos-antigos", "DA087AB8087A92ED", "ntfs", True),
    ("Temporarios", "/mnt/hd500/sdf3", "1068AFBC68AF9ECA", "ntfs", False),
    ("DevBin", "/mnt/hd500/sdf1", "01D36FD612953850", "ntfs", False),
)


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=False)


def inspect_one(name, path, uuid, fstype, readonly):
    result = {"share": name, "path": path, "expected_uuid": uuid, "ok": False, "issues": []}
    mount = run("findmnt", "--mountpoint", path, "--noheadings", "--output", "SOURCE,FSTYPE,OPTIONS")
    if mount.returncode != 0 or not mount.stdout.strip():
        result["issues"].append("mountpoint ausente")
        return result
    # Query fields separately to avoid ambiguities in whitespace parsing.
    source = run("findmnt", "--mountpoint", path, "--noheadings", "--output", "SOURCE")
    options = run("findmnt", "--mountpoint", path, "--noheadings", "--output", "OPTIONS")
    if source.returncode or options.returncode:
        result["issues"].append("falha ao consultar origem/opcoes")
        return result
    device = source.stdout.strip()
    opts = set(options.stdout.strip().split(","))
    result["source"] = device
    result["options"] = sorted(opts)
    if not device.startswith("/dev/"):
        result["issues"].append("origem nao e dispositivo de bloco")
        return result
    identity = run("blkid", "-o", "export", device)
    if identity.returncode:
        result["issues"].append("blkid nao conseguiu identificar origem")
        return result
    attrs = dict(line.split("=", 1) for line in identity.stdout.splitlines() if "=" in line)
    result["observed_uuid"] = attrs.get("UUID")
    result["observed_type"] = attrs.get("TYPE")
    if attrs.get("UUID", "").upper() != uuid.upper():
        result["issues"].append("UUID divergente")
    if attrs.get("TYPE", "").lower() != fstype:
        result["issues"].append("tipo divergente")
    if readonly and "ro" not in opts:
        result["issues"].append("historico nao esta somente leitura")
    if not readonly and "rw" not in opts:
        result["issues"].append("ativo nao esta em modo escrita")
    result["ok"] = not result["issues"]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emitir JSON")
    args = parser.parse_args()
    if sys.platform != "linux":
        print("Este diagnostico exige Linux", file=sys.stderr)
        return 2
    results = [inspect_one(*item) for item in EXPECTED]
    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    else:
        for item in results:
            status = "OK" if item["ok"] else "BLOQUEADO"
            print(f'{status}: {item["share"]} ({item["path"]})')
            for issue in item["issues"]:
                print(f"  - {issue}")
    return 0 if all(item["ok"] for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
