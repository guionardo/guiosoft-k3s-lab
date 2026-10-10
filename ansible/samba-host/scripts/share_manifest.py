"""Single source of share definitions: Ansible role defaults/main.yml.

Requires PyYAML (the YAML library used by Ansible). Fail closed on invalid data.
No host state changes.
"""
from pathlib import Path

DEFAULTS = Path(__file__).resolve().parents[1] / "roles" / "samba_host" / "defaults" / "main.yml"
FIELDS = {"name", "path", "uuid", "fstype", "readonly"}


def load_manifest(path=DEFAULTS):
    try:
        import yaml
    except ImportError as exc:
        raise ValueError("PyYAML indisponivel: execute com Python que possua yaml") from exc
    try:
        config = yaml.safe_load(Path(path).read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        raise ValueError(f"nao foi possivel ler defaults Ansible: {exc}") from exc
    if not isinstance(config, dict) or not isinstance(config.get("samba_shares"), list):
        raise ValueError("samba_shares ausente ou invalido")
    shares = config["samba_shares"]
    if not shares:
        raise ValueError("nenhum share configurado")
    seen_names, seen_paths = set(), set()
    for share in shares:
        if not isinstance(share, dict) or set(share) != FIELDS:
            raise ValueError("share com campos invalidos")
        name, path = share["name"], share["path"]
        if not isinstance(name, str) or not name or any(c in name for c in "[]\r\n"):
            raise ValueError("nome de share invalido")
        if not isinstance(path, str) or not path.startswith("/mnt/") or "\n" in path or "\r" in path:
            raise ValueError("caminho de share invalido")
        if name in seen_names or path in seen_paths:
            raise ValueError("share ou caminho duplicado")
        seen_names.add(name)
        seen_paths.add(path)
        if not isinstance(share["uuid"], str) or not share["uuid"]:
            raise ValueError("UUID invalido")
        if share["fstype"] not in ("ntfs", "ext4"):
            raise ValueError("filesystem nao permitido")
        if type(share["readonly"]) is not bool:
            raise ValueError("readonly deve ser booleano")
    return shares
