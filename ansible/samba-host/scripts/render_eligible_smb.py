#!/usr/bin/env python3
"""Render an offline Samba candidate from validated share names.

No mount, Samba service, /etc or firewall modifications. Inputs are trusted
repository configuration plus a fresh eligibility report; report alone does not
authorize deployment or guarantee protection against runtime unmounts.
"""
import argparse
import json
import pathlib
import sys

# Deliberately separate from the global diagnostic: render only explicitly
# validated shares and reject stale/ambiguous/unknown input.
GLOBAL = """# CANDIDATO OFFLINE; NAO IMPLANTAR. Revalidar mounts e runtime antes de uso.
[global]
    workgroup = WORKGROUP
    server role = standalone server
    security = user
    server min protocol = SMB2_02
    map to guest = Never
    usershare allow guests = no
    restrict anonymous = 2
    hosts allow = 127. 192.168.88.
    hosts deny = ALL
    follow symlinks = no
    wide links = no
"""
SHARE = """
[{name}]
    path = {path}
    browseable = yes
    guest ok = no
    valid users = guionardo
    read only = {readonly}
    follow symlinks = no
    wide links = no
"""

from share_manifest import load_manifest

SHARES = tuple(
    (s["name"], s["path"], s["readonly"])
    for s in load_manifest()
)

def render(report):
    if not isinstance(report, dict) or set(report) != {"eligible", "blocked"}:
        raise ValueError("relatorio com estrutura inesperada")
    eligible = report["eligible"]
    blocked = report["blocked"]
    if not isinstance(eligible, list) or not isinstance(blocked, list):
        raise ValueError("eligible/blocked devem ser listas")
    if any(not isinstance(name, str) for name in eligible):
        raise ValueError("nome de share invalido")
    blocked_names = []
    for item in blocked:
        if not isinstance(item, dict) or not isinstance(item.get("share"), str):
            raise ValueError("bloqueio invalido")
        if not isinstance(item.get("issues"), list) or not item["issues"]:
            raise ValueError("bloqueio sem justificativa")
        blocked_names.append(item["share"])
    names = [item[0] for item in SHARES]
    combined = eligible + blocked_names
    if len(combined) != len(names) or set(combined) != set(names):
        raise ValueError("relatorio incompleto, duplicado ou desconhecido")
    if len(set(combined)) != len(combined):
        raise ValueError("share duplicado")
    return GLOBAL + "".join(
        SHARE.format(name=name, path=path, readonly="yes" if readonly else "no")
        for name, path, readonly in SHARES if name in eligible
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=pathlib.Path, help="JSON do preflight")
    parser.add_argument("--output", type=pathlib.Path, help="arquivo de saida; padrao stdout")
    args = parser.parse_args()
    try:
        content = render(json.loads(args.report.read_text(encoding="utf-8")))
        if args.output:
            if args.output.exists():
                raise ValueError("arquivo de saida ja existe; nao sobrescrever")
            args.output.write_text(content, encoding="utf-8")
        else:
            sys.stdout.write(content)
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
