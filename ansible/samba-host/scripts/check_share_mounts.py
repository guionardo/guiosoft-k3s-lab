#!/usr/bin/env python3
"""Read-only, fail-closed preflight of Samba share mountpoints.

Uses findmnt and blkid; never mounts, writes or changes services.
Not wired to smbd startup: this is a standalone diagnostic.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

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
    executable = args[0]
    resolved = shutil.which(executable)
    if resolved is None:
        for directory in ("/usr/sbin", "/sbin", "/usr/bin", "/bin"):
            candidate = os.path.join(directory, executable)
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                resolved = candidate
                break
    if resolved is None:
        return subprocess.CompletedProcess(args, 127, "", f"executavel ausente: {executable}")
    try:
        return subprocess.run((resolved, *args[1:]), capture_output=True, text=True, check=False)
    except OSError as exc:
        return subprocess.CompletedProcess(args, 127, "", str(exc))


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
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="emitir diagnostico JSON")
    output.add_argument("--eligible-json", action="store_true", help="emitir nomes dos shares validos em JSON (nao implanta)")
    args = parser.parse_args()
    if sys.platform != "linux":
        print("Este diagnostico exige Linux", file=sys.stderr)
        return 2
    results = [inspect_one(*item) for item in EXPECTED]
    if args.eligible_json:
        print(json.dumps({"eligible": [item["share"] for item in results if item["ok"]],
                          "blocked": [{"share": item["share"], "issues": item["issues"]}
                                      for item in results if not item["ok"]]}, ensure_ascii=False, indent=2))
    elif args.json:
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
