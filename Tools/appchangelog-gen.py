#!/usr/bin/env python3
"""Generate the in-app "What's New" entry (AppChangelog) for BOTH platforms from a release file's
front-matter, so the Kotlin and Swift entries stay byte-identical and the version bump is automatic.

A per-version notes file docs/releases/v<VER>.md may carry a YAML front-matter block:

    ---
    whatsnew:
      title: "Short headline for the in-app card"
      date: "July 2026"
      items:
        - "**Bold lead.** One-line description."
        - "**Another.** ..."
      title_locales:            # OPTIONAL, but see below — without it the card ships English titles
        de: "Kurze Überschrift"
        es: "..."
        fr: "..."
        pt-PT: "..."
        zh: "..."
    ---
    # NOOP v<VER>
    <the full release notes — the GitHub release body; the front-matter is stripped there>

Running `Tools/appchangelog-gen.py docs/releases/v8.2.2.md` prepends the generated Release entry to
`releases` in AppChangelog.kt AND AppChangelog.swift and bumps CURRENT_VERSION/currentVersion to that
version. Idempotent: if the version is already the newest entry it only re-checks the constant. The
version comes from the filename (v8.2.2.md -> 8.2.2).

ANDROID TITLE LOCALIZATION (#878). Compose has no auto-extraction, so a raw Kotlin `title = "..."`
is a hardcoded literal: the i18n gate fails on it, and because that gate audits the WHOLE tree the
failure red-checks every open PR on a line none of them touched. Apple is unaffected (SwiftUI
auto-extracts into the catalog), so the Swift entry keeps its literal title.

This script therefore emits `title = uiString(R.string.<key>)` for Kotlin and writes the string
itself, using the repo's key scheme: `l10n_app_changelog_<first 6 alnum words, lowercased>_<sha1 of
the exact title>[:8]` — verified to reproduce the existing 9.2.0 and 9.2.1 keys.

Translations come from `whatsnew.title_locales`. A locale with no entry falls back to the ENGLISH
title and is named in a warning, because the alternative — leaving the key out of that locale — is
the same red gate this exists to prevent. An English title in a German card is a visible, fixable
wart; a red main after every release is not.
"""
import hashlib
import re
import sys
import pathlib


ROOT = pathlib.Path(__file__).resolve().parent.parent
KT = ROOT / "android/app/src/main/java/com/noop/ui/AppChangelog.kt"
SW = ROOT / "Strand/System/AppChangelog.swift"
RES = ROOT / "android/app/src/main/res"

#: The locale resource dirs the i18n gate treats as the focus set. `values` is the English source.
LOCALE_DIRS = {"en": "values", "de": "values-de", "es": "values-es",
               "fr": "values-fr", "pt-PT": "values-pt-rPT", "zh": "values-zh"}


def title_key(title: str) -> str:
    """`l10n_app_changelog_<first 6 alnum words>_<sha1(title)[:8]>` — the repo's existing scheme.

    Hashed on the EXACT title text, so an edited headline mints a new key rather than silently
    re-pointing the old one's translations at different words.
    """
    slug = "_".join(re.findall(r"[A-Za-z0-9]+", title.lower())[:6])
    return f"l10n_app_changelog_{slug}_{hashlib.sha1(title.encode()).hexdigest()[:8]}"


def esc_xml(s: str) -> str:
    """Android resource escaping: XML entities, plus the apostrophe Android requires backslashed."""
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace("'", "\\'"))


def write_title_strings(key: str, title: str, locales: dict) -> None:
    """Add `key` to values/ and each focus locale, before </resources>. Idempotent."""
    missing = []
    for loc, d in LOCALE_DIRS.items():
        path = RES / d / "strings.xml"
        if not path.is_file():
            print(f"  WARNING: {path} not found — skipped")
            continue
        text = path.read_text()
        if f'name="{key}"' in text:
            continue
        value = title if loc == "en" else locales.get(loc)
        if value is None:
            value, fell_back = title, True
            missing.append(loc)
        else:
            fell_back = False
        text = text.replace("</resources>",
                            f'    <string name="{key}">{esc_xml(value)}</string>\n</resources>')
        path.write_text(text)
        print(f"  {d}/strings.xml: + {key}" + ("  (ENGLISH FALLBACK)" if fell_back else ""))
    if missing:
        print(f"  WARNING: no whatsnew.title_locales for {', '.join(missing)} — those cards show the "
              f"English title. Add them to the release notes front-matter and re-run to fix.")


def frontmatter(md: pathlib.Path) -> dict:
    # Imported HERE, not at module scope: the pure helpers below carry the #878 key scheme and are
    # unit-tested, and a test runner should not need PyYAML installed to import them. Parsing the
    # front-matter is the only thing that actually needs it, and it still fails with the same message.
    try:
        import yaml
    except ImportError:
        sys.exit("appchangelog-gen: needs PyYAML (pip install pyyaml)")
    m = re.match(r"^---\n(.*?)\n---\n", md.read_text(), re.S)
    if not m:
        sys.exit(f"appchangelog-gen: no YAML front-matter in {md}")
    wn = (yaml.safe_load(m.group(1)) or {}).get("whatsnew")
    if not (wn and wn.get("title") and wn.get("date") and wn.get("items")):
        sys.exit(f"appchangelog-gen: front-matter needs whatsnew.{{title,date,items}} in {md}")
    return wn


def esc_kt(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")


def esc_sw(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def kt_block(ver, wn):
    items = "\n".join(f'                "{esc_kt(i)}",' for i in wn["items"])
    # #878: a resource reference, never a literal — see the module docstring.
    return (
        "        Release(\n"
        f'            version = "{ver}",\n'
        f'            title = uiString(R.string.{title_key(wn["title"])}),\n'
        f'            date = "{esc_kt(wn["date"])}",\n'
        "            items = listOf(\n"
        f"{items}\n"
        "            ),\n"
        "        ),\n"
    )


def sw_block(ver, wn):
    items = "\n".join(f'                "{esc_sw(i)}",' for i in wn["items"])
    return (
        "        Release(\n"
        f'            version: "{ver}",\n'
        f'            title: "{esc_sw(wn["title"])}",\n'
        f'            date: "{esc_sw(wn["date"])}",\n'
        "            items: [\n"
        f"{items}\n"
        "            ]\n"
        "        ),\n"
    )


def apply(path, anchor, block, ver, const_re, const_new, title_line=None):
    """Insert `block` at `anchor`, or refresh an existing entry for `ver`, then bump the constant.

    `title_line` is the platform's rendered title assignment (Kotlin's `title = uiString(...)`, Swift's
    `title: "..."`). It is re-applied to an entry that already exists, because re-running after editing
    the headline is a normal thing to do during a release — and without this the two halves disagree:
    `write_title_strings` would mint and write the NEW key while the entry kept referencing the old one,
    so the card showed the previous headline and the new key sat orphaned in six locale files. Found by
    doing exactly that.
    """
    text = path.read_text()
    idx = text.index(anchor) + len(anchor)
    already = f'version = "{ver}"' in text[idx:idx + 400] or f'version: "{ver}"' in text[idx:idx + 400]
    if already:
        if title_line:
            pat = re.compile(rf'((?:version = "{re.escape(ver)}",|version: "{re.escape(ver)}",)\s*\n\s*)'
                             r'(title[ =:][^\n]*)')
            m = pat.search(text, idx)
            if not m:
                sys.exit(f"appchangelog-gen: found a v{ver} entry in {path.name} but not its title line")
            if m.group(2).rstrip(",") == title_line.rstrip(","):
                print(f"  {path.name}: v{ver} already the newest entry — title unchanged, refreshing constant")
            else:
                text = text[:m.start(2)] + title_line + text[m.end(2):]
                print(f"  {path.name}: v{ver} already present — title UPDATED to the current headline")
        else:
            print(f"  {path.name}: v{ver} already the newest entry — leaving entries, refreshing constant")
    else:
        text = text[:idx] + block + text[idx:]
    text, n = re.subn(const_re, const_new, text, count=1)
    if n != 1:
        sys.exit(f"appchangelog-gen: could not bump the version constant in {path.name}")
    path.write_text(text)
    if not already:
        print(f"  {path.name}: inserted v{ver} entry + set constant")


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: appchangelog-gen.py docs/releases/v<VER>.md")
    md = pathlib.Path(sys.argv[1])
    ver = md.stem.lstrip("vV")
    wn = frontmatter(md)
    print(f"appchangelog-gen: v{ver} — {wn['title']}")
    write_title_strings(title_key(wn["title"]), wn["title"], wn.get("title_locales") or {})
    apply(KT, "val releases: List<Release> = listOf(\n", kt_block(ver, wn), ver,
          r'(const val CURRENT_VERSION = ")[^"]*(")', rf'\g<1>{ver}\g<2>',
          title_line=f'title = uiString(R.string.{title_key(wn["title"])}),')
    apply(SW, "static let releases: [Release] = [\n", sw_block(ver, wn), ver,
          r'(static let currentVersion = ")[^"]*(")', rf'\g<1>{ver}\g<2>',
          title_line=f'title: "{esc_sw(wn["title"])}",')
    print("appchangelog-gen: done. Review the diff, then compile.")


if __name__ == "__main__":
    main()
