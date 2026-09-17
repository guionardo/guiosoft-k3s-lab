#!/usr/bin/env python3
"""Extract Mermaid fenced blocks from the article series into standalone .mmd files."""
from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTICLES = ROOT / "docs" / "articles"
OUTPUT = ROOT / ".artifacts" / "mermaid"
BLOCK = re.compile(r"```mermaid\s*\n(.*?)```", re.DOTALL)


def main() -> int:
    shutil.rmtree(OUTPUT, ignore_errors=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)

    paths = sorted(ARTICLES.glob("[0-9][0-9]-*.md"))
    paths += sorted((ARTICLES / "en").glob("[0-9][0-9]-*.md"))
    paths += sorted((ARTICLES / "es").glob("[0-9][0-9]-*.md"))

    count = 0
    for path in paths:
        text = path.read_text(encoding="utf-8")
        lang = "pt" if path.parent == ARTICLES else path.parent.name
        for index, diagram in enumerate(BLOCK.findall(text), 1):
            count += 1
            name = f"{lang}-{path.name[:2]}-{index:02d}.mmd"
            (OUTPUT / name).write_text(diagram.strip() + "\n", encoding="utf-8")

    if count == 0:
        raise SystemExit("no Mermaid diagrams found")
    print(f"Extracted {count} Mermaid diagrams to {OUTPUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
