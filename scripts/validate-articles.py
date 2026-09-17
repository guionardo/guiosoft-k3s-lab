#!/usr/bin/env python3
"""Validate the multilingual technical article series.

Checks that are cheap and deterministic locally/CI:
- exactly six numbered articles exist in PT, EN and ES;
- every article has a single H1 and at least one Mermaid diagram;
- Mermaid timeline period labels do not contain ':' (Mermaid uses ':' as separator);
- local Markdown image references resolve to existing files;
- once headers are introduced, require them consistently across all languages.

Mermaid syntax itself is rendered separately in CI with mermaid-cli.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARTICLES = ROOT / "docs" / "articles"
LANG_DIRS = {"pt": ARTICLES, "en": ARTICLES / "en", "es": ARTICLES / "es"}
EXPECTED = set(range(1, 7))
MERMAID_BLOCK = re.compile(r"```mermaid\s*\n(.*?)```", re.DOTALL)
IMAGE = re.compile(r"!\[[^\]]*\]\(([^)\s]+)(?:\s+[^)]*)?\)")


def numbered_articles(directory: Path) -> dict[int, Path]:
    result: dict[int, Path] = {}
    for path in directory.glob("[0-9][0-9]-*.md"):
        try:
            number = int(path.name[:2])
        except ValueError:
            continue
        result[number] = path
    return result


def validate_timeline(block: str, path: Path, errors: list[str]) -> None:
    lines = block.splitlines()
    if not any(line.strip() == "timeline" for line in lines):
        return
    for line_no, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped == "timeline" or stripped.startswith(("title ", "accTitle", "accDescr", "section ")):
            continue
        # A timeline event is PERIOD : EVENT. A ':' inside PERIOD is ambiguous/invalid.
        if ":" not in stripped:
            continue
        period, _event = stripped.rsplit(" : ", 1) if " : " in stripped else (stripped, "")
        if ":" in period:
            errors.append(f"{path.relative_to(ROOT)}: Mermaid timeline period contains ':': {period!r}")


def main() -> int:
    errors: list[str] = []
    all_articles: list[Path] = []

    for lang, directory in LANG_DIRS.items():
        articles = numbered_articles(directory)
        found = set(articles)
        if found != EXPECTED:
            errors.append(f"{lang}: expected article numbers {sorted(EXPECTED)}, found {sorted(found)}")
        all_articles.extend(articles.values())

    if len(all_articles) != 18:
        errors.append(f"expected 18 articles, found {len(all_articles)}")

    header_presence: list[tuple[Path, bool]] = []
    for path in sorted(all_articles):
        text = path.read_text(encoding="utf-8")
        h1 = [line for line in text.splitlines() if line.startswith("# ")]
        if len(h1) != 1:
            errors.append(f"{path.relative_to(ROOT)}: expected exactly one H1, found {len(h1)}")

        blocks = MERMAID_BLOCK.findall(text)
        if not blocks:
            errors.append(f"{path.relative_to(ROOT)}: expected at least one Mermaid block")
        for block in blocks:
            validate_timeline(block, path, errors)

        images = IMAGE.findall(text)
        header_presence.append((path, bool(images)))
        for target in images:
            if target.startswith(("http://", "https://", "data:")):
                continue
            resolved = (path.parent / target).resolve()
            try:
                resolved.relative_to(ROOT.resolve())
            except ValueError:
                errors.append(f"{path.relative_to(ROOT)}: image escapes repository: {target}")
                continue
            if not resolved.is_file():
                errors.append(f"{path.relative_to(ROOT)}: missing local image: {target}")

    # Header rollout must be atomic: either none yet, or every article has one.
    with_header = [path for path, present in header_presence if present]
    if with_header and len(with_header) != len(header_presence):
        missing = [str(path.relative_to(ROOT)) for path, present in header_presence if not present]
        errors.append("header images are only partially deployed; missing: " + ", ".join(missing))

    if errors:
        print("Article validation FAILED", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"Article validation PASS: {len(all_articles)} articles across PT/EN/ES")
    if not with_header:
        print("Header images: not deployed yet (consistent state)")
    else:
        print(f"Header images: present in all {len(with_header)} articles")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
