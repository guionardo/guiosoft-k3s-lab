#!/usr/bin/env python3
"""Render an offline Samba candidate from validated share names.

No mount, Samba service, /etc or firewall modifications. Inputs are trusted
repository configuration plus a fresh eligibility report; report alone does not
authorize deployment or guarantee protection against runtime unmounts.
"""
import argparse
import json
import pathlib
import re
import sys

from share_manifest import DEFAULTS, load_manifest

SHARES = tuple(
    (s["name"], s["path"], s["readonly"])
    for s in load_manifest()
)


def render_template(shares):
    """Use the exact same Jinja2 policy template as the Ansible candidate."""
    try:
        import yaml
        from jinja2 import Environment, StrictUndefined
    except ImportError as exc:
        raise ValueError("PyYAML e Jinja2 sao necessarios para renderizar") from exc
    config = yaml.safe_load(DEFAULTS.read_text(encoding="utf-8"))
    users = config.get("samba_auth_users")
    if (not isinstance(users, list) or not users or
            any(not isinstance(u, str) or not u or
                re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", u) is None for u in users)):
        raise ValueError("samba_auth_users invalido")
    template_path = pathlib.Path(__file__).resolve().parents[1] / "templates" / "smb.conf.candidate.j2"
    template = Environment(undefined=StrictUndefined, autoescape=False).from_string(
        template_path.read_text(encoding="utf-8")
    )
    return template.render(samba_shares=shares, samba_auth_users=users)


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
    selected = [share for share in load_manifest() if share["name"] in eligible]
    return render_template(selected)


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
