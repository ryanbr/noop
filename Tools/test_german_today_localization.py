#!/usr/bin/env python3
"""Reviewed German copy for the Today surfaces on Apple and Android.

Pins the German Today vocabulary, its plural forms, and the helper that must not
overwrite reviewed catalog units. Run with::

    python3 Tools/test_german_today_localization.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Strand/Resources/Localizable.xcstrings"


def catalog_strings():
    return json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]


def german_value(key):
    return catalog_strings()[key]["localizations"]["de"]["stringUnit"]["value"]


class GermanTodayLocalizationTest(unittest.TestCase):
    def test_today_customization_has_real_german_plurals(self) -> None:
        strings = catalog_strings()
        expected = {
            "%lld metrics shown": ("%lld Messwert angezeigt", "%lld Messwerte angezeigt"),
            "%lld cards shown": ("%lld Karte angezeigt", "%lld Karten angezeigt"),
            "%lld added": ("%lld hinzugefügt", "%lld hinzugefügt"),
        }
        for key, (one, other) in expected.items():
            plural = strings[key]["localizations"]["de"]["variations"]["plural"]
            self.assertEqual(one, plural["one"]["stringUnit"]["value"], key)
            self.assertEqual(other, plural["other"]["stringUnit"]["value"], key)
            self.assertIn("%lld", one)
            self.assertIn("%lld", other)

    def test_reviewed_today_vocabulary_is_pinned(self) -> None:
        expected = {
            "Shown on Today": "Auf „Heute“ angezeigt",
            "Added to Today": "Zu „Heute“ hinzugefügt",
            "Available": "Verfügbar",
            "None added yet": "Noch keine hinzugefügt",
            "Detailed tiles": "Detaillierte Kacheln",
            "Good afternoon": "Guten Tag",
            "Key Metrics": "Wichtige Messwerte",
            "Synthesis": "Zusammenfassung",
            "Readings": "Messwerte",
            "Start session": "Training starten",
            "Rest": "Erholung",
            "Squarer tiles with a trend graph under the bar.": "Größere Kacheln mit einem Trenddiagramm unter dem Balken.",
        }
        self.assertEqual(expected, {key: german_value(key) for key in expected})

    def test_today_customization_is_complete_for_every_supported_apple_locale(self) -> None:
        strings = catalog_strings()
        expected_plural_categories = {
            "it": {"one", "other"},
            "pl": {"one", "few", "many", "other"},
            "ru": {"one", "few", "many", "other"},
            "zh-Hans": {"other"},
            "zh-Hant": {"other"},
        }
        for key in ("%lld added", "%lld cards shown", "%lld metrics shown"):
            for locale, categories in expected_plural_categories.items():
                plural = strings[key]["localizations"][locale]["variations"]["plural"]
                self.assertEqual(categories, set(plural), f"{locale}: {key}")
                for category in categories:
                    value = plural[category]["stringUnit"]["value"]
                    self.assertNotEqual(key, value, f"{locale}/{category}: {key}")
                    self.assertIn("%lld", value, f"{locale}/{category}: {key}")

        for key in ("Added to Today", "Available", "None added yet", "Shown on Today"):
            for locale in expected_plural_categories:
                value = strings[key]["localizations"][locale]["stringUnit"]["value"]
                self.assertNotEqual(key, value, f"{locale}: {key}")

    def test_german_today_product_vocabulary_avoids_whoop_score_names_and_charge_value(self) -> None:
        expected = {
            "l10n_today_screen_recovery_ea924f72": "Erholung",
            "today_recovery_carried": "Erholung · %1$s",
            "today_card_coupled_subtitle": "Erholung, Belastung und Schlaf auf einen Blick",
            "today_pending_scores_body": (
                "Deine Live-Herzfrequenz kommt bereits vom Strap. Erholung, Belastung und Schlaf "
                "werden in den nächsten Nächten aufgebaut und mit deinem Basiswert genauer. Für den "
                "vollständigen Verlauf kannst du deinen WHOOP-Export unter „Datenquellen“ importieren; "
                "er wird in etwa einer Minute ergänzt."
            ),
            "today_training_read_explanation": "Eine Trainingseinschätzung, unabhängig von deinem Energiewert.",
        }
        android_de = (ROOT / "android/app/src/main/res/values-de/strings.xml").read_text(encoding="utf-8")
        for key, value in expected.items():
            self.assertIn(f'<string name="{key}">{value}</string>', android_de)

    def test_android_today_recovery_explanation_is_localized_in_remaining_locales(self) -> None:
        for locale in ("pl", "ru", "zh"):
            content = (ROOT / f"android/app/src/main/res/values-{locale}/strings.xml").read_text(encoding="utf-8")
            self.assertIn('<string name="today_recovery_vitals_explanation">', content, locale)

    def test_pending_strap_sync_detail_has_complete_apple_localizations(self) -> None:
        key = "Pending sync · strap history still offloading"
        strings = catalog_strings()
        self.assertEqual(
            "Synchronisierung ausstehend · Strap-Verlauf wird noch übertragen",
            strings[key]["localizations"]["de"]["stringUnit"]["value"],
        )
        self.assertEqual(
            {"de", "en", "es", "fr", "it", "pl", "pt-PT", "ru", "zh-Hans", "zh-Hant"},
            set(strings[key]["localizations"]),
        )

    def test_today_voiceover_uses_catalogued_sync_key_and_german_data_block_terms(self) -> None:
        source = (ROOT / "Strand/Screens/TodayView.swift").read_text(encoding="utf-8")
        self.assertIn('String(localized: "Syncing strap history, \\(n) chunks")', source)
        self.assertNotIn('String(localized: "Syncing strap history, chunk \\(n)")', source)

        strings = catalog_strings()
        plural = strings["Syncing strap history, %lld chunks"]["localizations"]["de"]["variations"]["plural"]
        self.assertEqual(
            "Verlaufssynchronisierung des Straps läuft, %lld Datenblock", plural["one"]["stringUnit"]["value"]
        )
        self.assertEqual(
            "Verlaufssynchronisierung des Straps läuft, %lld Datenblöcke", plural["other"]["stringUnit"]["value"]
        )
        plural = strings["Syncing strap history, %lld chunks, %@"]["localizations"]["de"]["variations"]["plural"]
        self.assertEqual(
            "Verlaufssynchronisierung des Straps läuft, %lld Datenblock, %@", plural["one"]["stringUnit"]["value"]
        )
        self.assertEqual(
            "Verlaufssynchronisierung des Straps läuft, %lld Datenblöcke, %@", plural["other"]["stringUnit"]["value"]
        )
        self.assertEqual("%lld Datenblöcke", german_value("%lld chunks"))
        self.assertEqual("%lld Datenblöcke übertragen", german_value("%lld chunks pulled"))

        android_de = ET.parse(ROOT / "android/app/src/main/res/values-de/strings.xml").getroot()
        chunks = android_de.find("plurals[@name='sync_chip_chunks_count']")
        self.assertEqual(
            {"one": "%1$d Datenblock", "other": "%1$d Datenblöcke"},
            {item.get("quantity"): item.text for item in chunks.findall("item")},
        )
        pulled = android_de.find("string[@name='l10n_components_chunks_chunks_pulled_cec186cf']")
        self.assertEqual("%1$s Datenblöcke übertragen", pulled.text)

    def test_legacy_translation_helper_preserves_reviewed_catalog_units(self) -> None:
        spec = importlib.util.spec_from_file_location("translate_de", ROOT / "Tools/translate-de.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "Localizable.xcstrings"
            fixture.write_text(json.dumps({"strings": {
                "Rest": {"localizations": {"de": {"variations": {"plural": {
                    "one": {"stringUnit": {"state": "translated", "value": "GEPRÜFT"}}
                }}}}},
                "Synthesis": {"localizations": {}},
            }}), encoding="utf-8")
            module.CATALOG = fixture

            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, module.main())
            strings = json.loads(fixture.read_text(encoding="utf-8"))["strings"]

        self.assertEqual(
            "GEPRÜFT",
            strings["Rest"]["localizations"]["de"]["variations"]["plural"]["one"]["stringUnit"]["value"],
        )
        self.assertEqual("Zusammenfassung", strings["Synthesis"]["localizations"]["de"]["stringUnit"]["value"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
