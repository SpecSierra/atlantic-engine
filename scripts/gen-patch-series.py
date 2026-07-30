#!/usr/bin/env python3
"""Generate patches/SERIES.md from scripts/patches.sh.

The apply order in patches.sh is authoritative; this only reports it, so the
table can never drift from what the build does. Run after adding or removing a
patch:

    python3 scripts/gen-patch-series.py
"""
import re
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PATCHES_SH = ROOT / "scripts" / "patches.sh"
OUT = ROOT / "patches" / "SERIES.md"

# Patches that only make the tree compile on the CI host / SFOS sysroot: added
# includes, owner headers, export macros, platform guards. Behaviour-neutral.
BUILD_FIX = re.compile(
    r"(wtf|pal|jsc|webcore)-|icu-imported|isnan|llint-build|shell-object"
    r"|-cstdint|-cstddef|unistdextras|memoryfootprint|ramsize|includes\.patch"
)

ARRAY_RE = re.compile(r"^readonly (\w+)=\(")


def parse_order():
    """Yield (array_name, patch_path, inline_note) in apply order."""
    array = None
    note: list[str] = []
    for line in PATCHES_SH.read_text().splitlines():
        m = ARRAY_RE.match(line)
        if m:
            array, note = m.group(1), []
            continue
        if array is None:
            continue
        s = line.strip()
        if s == ")":
            array = None
            continue
        if s.startswith("#"):
            note.append(s.lstrip("# ").strip())
            continue
        m = re.match(r'"(patches/[^"]+\.patch)"', s)
        if m:
            yield array, m.group(1), " ".join(note)
            note = []


def describe(patch: pathlib.Path):
    text = patch.read_text(errors="replace")
    files = sorted(set(re.findall(r"^\+\+\+ b/(\S+)", text, re.M)))
    flags = sorted(
        set(
            f
            for f in re.findall(r"\b(?:WEBKIT|ATLANTIC)_[A-Z0-9_]{3,}", text)
            if not f.endswith("_")
        )
    )
    return files, flags


def main():
    rows = []
    for array, rel, note in parse_order():
        p = ROOT / rel
        if not p.exists():
            print(f"missing: {rel}", file=sys.stderr)
            return 1
        files, flags = describe(p)
        rows.append((array, rel, note, files, flags))

    lines = [
        "# Patch series",
        "",
        "**Generated — do not edit.** `python3 scripts/gen-patch-series.py`",
        "",
        "Apply order comes from `scripts/patches.sh` and is load-bearing: patches "
        "that touch the same file must stay in this order. Validate the stack "
        "**sequentially** on a version bump — isolated dry-runs give false failures.",
        "",
    ]

    total_files = set()
    for array, rel, note, files, flags in rows:
        total_files.update(files)

    build = [r for r in rows if BUILD_FIX.search(pathlib.Path(r[1]).name)]
    feature = [r for r in rows if r not in build]
    lines += [
        f"| | Count |",
        f"|---|---|",
        f"| Patches | {len(rows)} |",
        f"| …portability / build fixes | {len(build)} |",
        f"| …behaviour | {len(feature)} |",
        f"| Distinct source files touched | {len(total_files)} |",
        f"| Env flags introduced | {len(set(f for r in rows for f in r[4]))} |",
        "",
        "## Hot files",
        "",
        "Files edited by more than one patch — every one is an ordering constraint.",
        "",
        "| Source file | Patches |",
        "|---|---|",
    ]
    counts: dict[str, int] = {}
    for *_, files, _flags in rows:
        for f in files:
            counts[f] = counts.get(f, 0) + 1
    for f, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        if n > 1:
            lines.append(f"| `{f}` | {n} |")

    for title, subset in (
        ("Behaviour patches", feature),
        ("Portability / build fixes", build),
    ):
        lines += [
            "",
            f"## {title}",
            "",
            "| # | Patch | Files | Env flags | Note |",
            "|---|---|---|---|---|",
        ]
        for i, (array, rel, note, files, flags) in enumerate(subset, 1):
            name = pathlib.Path(rel).name
            fl = "<br>".join(f"`{f}`" for f in flags) or "—"
            note = re.sub(rf"^{re.escape(name)}:?\s*", "", note)
            nt = (note[:200] + "…") if len(note) > 200 else (note or "—")
            lines.append(f"| {i} | `{name}` | {len(files)} | {fl} | {nt} |")

    OUT.write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}: {len(rows)} patches, {len(total_files)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
