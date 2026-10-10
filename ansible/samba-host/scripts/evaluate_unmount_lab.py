#!/usr/bin/env python3
"""Evaluate recorded disposable-VM SMB unmount experiments; never executes them.

Evidence JSON is supplied by the operator. PASS means the *recorded observations*
satisfy these checks, not that the architecture is proven race-free.
"""
import argparse
import json
from pathlib import Path
import sys

REQUIRED = ("baseline", "existing_session", "new_session", "other_share", "recovery")


def evaluate(data):
    if not isinstance(data, dict) or set(data) != {"environment", "observations"}:
        raise ValueError("estrutura do relatorio invalida")
    env = data["environment"]
    obs = data["observations"]
    if not isinstance(env, dict) or not isinstance(obs, dict):
        raise ValueError("ambiente/observacoes invalidos")
    if set(obs) != set(REQUIRED):
        raise ValueError("observacoes incompletas ou desconhecidas")
    for field in ("vm_disposable", "network_isolated", "test_volume_verified"):
        if env.get(field) is not True:
            raise ValueError(f"isolamento nao confirmado: {field}")
    failures, inconclusive = [], []
    for name in REQUIRED:
        item = obs[name]
        if not isinstance(item, dict) or set(item) != {"performed", "underlying_exposed", "expected_behavior"}:
            raise ValueError(f"observacao invalida: {name}")
        if item["performed"] is not True:
            inconclusive.append(name)
            continue
        if item["underlying_exposed"] is True:
            failures.append(f"{name}: diretorio subjacente exposto")
        elif item["underlying_exposed"] is not False:
            inconclusive.append(f"{name}: exposicao nao verificada")
        if item["expected_behavior"] is False:
            failures.append(f"{name}: comportamento esperado falhou")
        elif item["expected_behavior"] is not True:
            inconclusive.append(f"{name}: comportamento esperado nao verificado")
    status = "FAIL" if failures else "INCONCLUSIVE" if inconclusive else "PASS_OBSERVED"
    return {"status": status, "failures": failures, "inconclusive": inconclusive,
            "disclaimer": "PASS_OBSERVED nao prova ausencia de condicoes de corrida nem autoriza producao"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    try:
        result = evaluate(json.loads(args.evidence.read_text(encoding="utf-8")))
    except (OSError, ValueError) as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return {"PASS_OBSERVED": 0, "FAIL": 1, "INCONCLUSIVE": 2}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
