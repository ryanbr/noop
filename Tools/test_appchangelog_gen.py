#!/usr/bin/env python3
"""#878 — the generated Android What's New title must be a resource reference, not a literal.

A raw Kotlin `title = "..."` is a hardcoded literal that the i18n gate rejects, and because that gate
audits the WHOLE tree, one bad line red-checks every open PR on code none of them touched. That is not
hypothetical: it happened on 9.2.0 and again on 9.2.1, and both times it was cleared by hand afterwards
rather than by the generator getting it right.

These pin the two things that would bring it back: the emitted shape, and the key scheme that shape
depends on. The scheme is pinned against a title that is actually shipping, so the test fails if either
the hashing or the slugging drifts from what is already in strings.xml.
"""
import hashlib
import importlib.util
import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("acg", ROOT / "Tools/appchangelog-gen.py")
acg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(acg)

# The 9.2.1 headline and the key it actually ships under, copied from values/strings.xml.
SHIPPED_TITLE = ("Battery saver quiets the gauges, translated Android notifications, "
                 "and instant chart loads")
SHIPPED_KEY = "l10n_app_changelog_battery_saver_quiets_the_gauges_translated_bdbe8650"


class TitleKeyTests(unittest.TestCase):

    def test_reproduces_a_key_that_is_actually_shipping(self):
        """Pinned against the real artifact, not against the function's own output."""
        self.assertEqual(SHIPPED_KEY, acg.title_key(SHIPPED_TITLE))

    def test_that_key_really_is_in_strings_xml(self):
        """If someone renames the key in the resources, this test's premise is gone — say so loudly
        rather than keep asserting against a string nothing uses."""
        xml = (ROOT / "android/app/src/main/res/values/strings.xml").read_text()
        self.assertIn(f'name="{SHIPPED_KEY}"', xml)

    def test_editing_the_title_mints_a_new_key(self):
        """The hash covers the exact title, so a reworded headline cannot silently inherit the old
        key — and with it, translations of different words."""
        self.assertNotEqual(acg.title_key(SHIPPED_TITLE), acg.title_key(SHIPPED_TITLE + " and more"))

    def test_slug_is_six_words_and_hash_is_eight_hex(self):
        key = acg.title_key("One two three four five six seven eight")
        self.assertTrue(key.startswith("l10n_app_changelog_one_two_three_four_five_six_"))
        self.assertRegex(key.rsplit("_", 1)[-1], r"^[0-9a-f]{8}$")

    def test_hash_is_of_the_title_text_itself(self):
        t = "Anything at all"
        self.assertTrue(acg.title_key(t).endswith(hashlib.sha1(t.encode()).hexdigest()[:8]))


class EscapingTests(unittest.TestCase):

    def test_apostrophe_is_backslashed_for_android(self):
        """An unescaped ' in a resource value is an aapt2 error, and release titles have them."""
        self.assertEqual(r"L\'économiseur", acg.esc_xml("L'économiseur"))

    def test_xml_entities(self):
        self.assertEqual("a &amp; b &lt;c&gt;", acg.esc_xml("a & b <c>"))

    def test_ampersand_is_escaped_before_the_others(self):
        """Escaping & last would double-escape the entities introduced by < and >."""
        self.assertEqual("&lt;a&gt; &amp; &lt;b&gt;", acg.esc_xml("<a> & <b>"))


class EmittedBlockTests(unittest.TestCase):

    WN = {"title": SHIPPED_TITLE, "date": "July 2026", "items": ["**One.** A thing."]}

    def test_kotlin_title_is_a_resource_reference(self):
        block = acg.kt_block("9.2.1", self.WN)
        self.assertIn(f"title = uiString(R.string.{SHIPPED_KEY})", block)

    def test_kotlin_title_is_not_a_literal(self):
        """The regression itself: `title = "…"` is what fails the gate."""
        block = acg.kt_block("9.2.1", self.WN)
        self.assertNotRegex(block, r'title\s*=\s*"')

    def test_swift_title_stays_a_literal(self):
        """SwiftUI auto-extracts into the catalog, so Apple needs no reference — and changing it
        would break the baseline that tracks these titles."""
        block = acg.sw_block("9.2.1", self.WN)
        self.assertIn(f'title: "{SHIPPED_TITLE}"', block)

    def test_items_stay_literals_on_both_platforms(self):
        """Only the title moved. Items are long-form prose the gate does not require extracting, and
        turning them into 60 resources per release was never the ask."""
        for block in (acg.kt_block("9.2.1", self.WN), acg.sw_block("9.2.1", self.WN)):
            self.assertIn('"**One.** A thing."', block)


class TitleRefreshTests(unittest.TestCase):
    """Re-running after editing the headline must update the entry, not leave it stale.

    The bug this pins: `apply()` skipped an entry that already existed, while the string writer ran
    unconditionally — so an edited headline minted and wrote a NEW key into six locale files while the
    entry kept referencing the OLD one. The card showed the previous headline and the new key was an
    orphan, with nothing failing. Found by doing it.
    """

    KT_HEAD = ("object AppChangelog {\n"
               "    const val CURRENT_VERSION = \"0.0.0\"\n"
               "    val releases: List<Release> = listOf(\n")
    KT_TAIL = "    )\n}\n"

    def _file(self, body):
        import tempfile
        f = tempfile.NamedTemporaryFile("w", suffix=".kt", delete=False)
        f.write(self.KT_HEAD + body + self.KT_TAIL)
        f.close()
        return pathlib.Path(f.name)

    ENTRY = ('        Release(\n'
             '            version = "9.9.9",\n'
             '            title = uiString(R.string.l10n_app_changelog_old_one_aaaaaaaa),\n'
             '            date = "July 2026",\n'
             '        ),\n')

    def test_existing_entry_gets_its_title_updated(self):
        path = self._file(self.ENTRY)
        acg.apply(path, "val releases: List<Release> = listOf(\n", "IGNORED", "9.9.9",
                  r'(const val CURRENT_VERSION = ")[^"]*(")', r'\g<1>9.9.9\g<2>',
                  title_line="title = uiString(R.string.l10n_app_changelog_new_one_bbbbbbbb),")
        out = path.read_text()
        self.assertIn("l10n_app_changelog_new_one_bbbbbbbb", out)
        self.assertNotIn("l10n_app_changelog_old_one_aaaaaaaa", out)
        path.unlink()

    def test_it_does_not_duplicate_the_entry(self):
        path = self._file(self.ENTRY)
        acg.apply(path, "val releases: List<Release> = listOf(\n", "SHOULD_NOT_APPEAR", "9.9.9",
                  r'(const val CURRENT_VERSION = ")[^"]*(")', r'\g<1>9.9.9\g<2>',
                  title_line="title = uiString(R.string.l10n_app_changelog_new_one_bbbbbbbb),")
        out = path.read_text()
        self.assertEqual(1, out.count('version = "9.9.9"'))
        self.assertNotIn("SHOULD_NOT_APPEAR", out)
        path.unlink()

    def test_unchanged_title_is_left_alone(self):
        """The ENTRY is untouched when the headline has not moved. Asserting the title line rather than
        the whole file, because `apply()` legitimately rewrites the version constant on every run —
        which is what this test got wrong the first time."""
        same = "title = uiString(R.string.l10n_app_changelog_old_one_aaaaaaaa),"
        path = self._file(self.ENTRY)
        acg.apply(path, "val releases: List<Release> = listOf(\n", "IGNORED", "9.9.9",
                  r'(const val CURRENT_VERSION = ")[^"]*(")', r'\g<1>9.9.9\g<2>', title_line=same)
        out = path.read_text()
        self.assertEqual(1, out.count(same))
        self.assertEqual(1, out.count('version = "9.9.9"'))
        self.assertIn('const val CURRENT_VERSION = "9.9.9"', out)   # the constant DOES move
        path.unlink()


class LocaleTargetTests(unittest.TestCase):

    def test_focus_locales_match_the_resource_dirs_on_disk(self):
        """A renamed or added locale dir must not leave the generator writing into nowhere."""
        for loc, d in acg.LOCALE_DIRS.items():
            self.assertTrue((ROOT / "android/app/src/main/res" / d / "strings.xml").is_file(),
                            f"{loc} -> {d}/strings.xml is missing")

    def test_english_source_is_the_values_dir(self):
        self.assertEqual("values", acg.LOCALE_DIRS["en"])


if __name__ == "__main__":
    unittest.main()
