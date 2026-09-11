import importlib.util
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Strand/Resources/Localizable.xcstrings"


def catalog_strings():
    return json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]


def german_value(key):
    return catalog_strings()[key]["localizations"]["de"]["stringUnit"]["value"]


def test_today_customization_has_real_german_plurals():
    strings = catalog_strings()
    expected = {
        "%lld metrics shown": ("%lld Messwert angezeigt", "%lld Messwerte angezeigt"),
        "%lld cards shown": ("%lld Karte angezeigt", "%lld Karten angezeigt"),
        "%lld added": ("%lld hinzugefügt", "%lld hinzugefügt"),
    }
    for key, (one, other) in expected.items():
        plural = strings[key]["localizations"]["de"]["variations"]["plural"]
        assert plural["one"]["stringUnit"]["value"] == one
        assert plural["other"]["stringUnit"]["value"] == other
        assert "%lld" in one and "%lld" in other


def test_reviewed_today_vocabulary_is_pinned():
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
    assert {key: german_value(key) for key in expected} == expected


def test_today_customization_is_complete_for_every_supported_apple_locale():
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
            assert set(plural) == categories
            for category in categories:
                value = plural[category]["stringUnit"]["value"]
                assert value != key and "%lld" in value

    for key in ("Added to Today", "Available", "None added yet", "Shown on Today"):
        for locale in expected_plural_categories:
            value = strings[key]["localizations"][locale]["stringUnit"]["value"]
            assert value != key


def test_german_today_product_vocabulary_avoids_whoop_score_names_and_charge_value():
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
        assert f'<string name="{key}">{value}</string>' in android_de


def test_android_today_recovery_explanation_is_localized_in_remaining_locales():
    for locale in ("pl", "ru", "zh"):
        content = (ROOT / f"android/app/src/main/res/values-{locale}/strings.xml").read_text(encoding="utf-8")
        assert '<string name="today_recovery_vitals_explanation">' in content


def test_pending_strap_sync_detail_has_complete_apple_localizations():
    key = "Pending sync · strap history still offloading"
    strings = catalog_strings()
    assert strings[key]["localizations"]["de"]["stringUnit"]["value"] == (
        "Synchronisierung ausstehend · Strap-Verlauf wird noch übertragen"
    )
    assert set(strings[key]["localizations"]) == {
        "de", "en", "es", "fr", "it", "pl", "pt-PT", "ru", "zh-Hans", "zh-Hant"
    }


def test_today_voiceover_uses_catalogued_sync_key_and_german_data_block_terms():
    source = (ROOT / "Strand/Screens/TodayView.swift").read_text(encoding="utf-8")
    assert 'String(localized: "Syncing strap history, \\(n) chunks")' in source
    assert 'String(localized: "Syncing strap history, chunk \\(n)")' not in source

    strings = catalog_strings()
    plural = strings["Syncing strap history, %lld chunks"]["localizations"]["de"]["variations"]["plural"]
    assert plural["one"]["stringUnit"]["value"] == "Verlaufssynchronisierung des Straps läuft, %lld Datenblock"
    assert plural["other"]["stringUnit"]["value"] == "Verlaufssynchronisierung des Straps läuft, %lld Datenblöcke"
    assert german_value("%lld chunks") == "%lld Datenblöcke"
    assert german_value("%lld chunks pulled") == "%lld Datenblöcke übertragen"


def test_legacy_translation_helper_preserves_reviewed_catalog_units(tmp_path):
    spec = importlib.util.spec_from_file_location("translate_de", ROOT / "Tools/translate-de.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    fixture = tmp_path / "Localizable.xcstrings"
    fixture.write_text(json.dumps({"strings": {
        "Rest": {"localizations": {"de": {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": "GEPRÜFT"}}
        }}}}},
        "Synthesis": {"localizations": {}},
    }}), encoding="utf-8")
    module.CATALOG = fixture

    assert module.main() == 0
    strings = json.loads(fixture.read_text(encoding="utf-8"))["strings"]
    assert strings["Rest"]["localizations"]["de"]["variations"]["plural"]["one"]["stringUnit"]["value"] == "GEPRÜFT"
    assert strings["Synthesis"]["localizations"]["de"]["stringUnit"]["value"] == "Zusammenfassung"
