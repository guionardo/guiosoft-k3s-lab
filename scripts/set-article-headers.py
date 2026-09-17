#!/usr/bin/env python3
"""Attach the six shared, language-neutral headers to all 18 articles.

The operation is deterministic and idempotent. Portuguese articles live directly
under docs/articles; English and Spanish versions live one directory deeper and
therefore use a different relative asset path.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTICLES = ROOT / "docs" / "articles"
LANG_DIRS = (ARTICLES, ARTICLES / "en", ARTICLES / "es")
ARTICLE_RE = re.compile(r"^(0[1-6])-.+\.md$")
HEADER_RE = re.compile(r"^!\[[^\]]*\]\((?:\.\./)?assets/0[1-6]\.png\)\n\n", re.MULTILINE)


def main() -> int:
    changed = 0
    seen = 0

    for directory in LANG_DIRS:
        for path in sorted(directory.glob("[0-9][0-9]-*.md")):
            match = ARTICLE_RE.match(path.name)
            if not match:
                continue
            seen += 1
            number = match.group(1)
            text = path.read_text(encoding="utf-8")

            # Remove only a header managed by this script, making reruns safe.
            text = HEADER_RE.sub("", text, count=1)

            asset = f"assets/{number}.png" if directory == ARTICLES else f"../assets/{number}.png"
            header = f"![Article {number} illustration]({asset})\n\n"
            new_text = header + text

            if new_text != path.read_text(encoding="utf-8"):
                path.write_text(new_text, encoding="utf-8")
                changed += 1

    if seen != 18:
        raise SystemExit(f"expected 18 articles, found {seen}")

    print(f"Article headers mapped: {seen} articles, {changed} files changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
