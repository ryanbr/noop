"""Regression coverage for every shipped locale of the steps feature."""
import json
import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "android/app/src/main/res"
IOS_KEYS = [
    "3 weeks",
    "sparse, widened to %@",
    "30-day step average",
    "Rolling average over the last 30 days",
    "%lld of 30 days",
    "Historical trend",
    "bar",
    "bars",
    "week of %@",
    "2W",
    "3W",
    "%lld daily %@ · %@",
    "%lld weekly %@ · average per observed day · %@",
    "%lld monthly %@ · average per observed day · %@",
    "%@ steps",
    "%@ average steps per observed day",
    "Steps chart, no data",
    "Steps chart, %lld daily %@, latest %lld steps, %@",
    "Steps chart, %lld weekly %@, latest %lld average steps per observed day, %@",
    "Steps chart, %lld monthly %@, latest %lld average steps per observed day, %@",
    "1 observed day",
    "%lld observed days",
    "1 week · averages per observed day",
    "%lld weeks · averages per observed day",
    "1 month · averages per observed day",
    "%lld months · averages per observed day"
]

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result

def signature(value):
    result = {}
    next_index = 1
    for match in re.finditer(r"%(?:(\d+)\$)?(lld|[sd@])", value):
        index, kind = match.groups()
        index = int(index) if index else next_index
        next_index += 1
        if index in result and result[index] != kind:
            raise ValueError(f"Inconsistent placeholder {index}")
        result[index] = kind
    return result

class StepsTranslationsTests(unittest.TestCase):
    def test_android_all_shipped_locales(self):
        source = ET.parse(RES / "values/steps_view.xml").getroot()
        keys = {entry.attrib["name"]: entry for entry in source}
        directories = [RES / "values", *sorted(RES.glob("values-*"))]
        for directory in directories:
            if directory != RES / "values" and not (directory / "strings.xml").exists():
                continue
            with self.subTest(locale=directory.name):
                entries = {}
                for path in directory.glob("*.xml"):
                    for entry in ET.parse(path).getroot():
                        name = entry.get("name")
                        if name not in keys:
                            continue
                        self.assertNotIn(name, entries, f"Duplicate {name} in {directory}")
                        entries[name] = entry
                self.assertEqual(set(entries), set(keys))
                for name, original in keys.items():
                    translated = entries[name]
                    self.assertEqual(original.tag, translated.tag)
                    if original.tag == "string-array":
                        self.assertEqual(len(original), len(translated))
                        self.assertTrue(all(item.text for item in translated))
                    else:
                        self.assertTrue(translated.text)
                        self.assertEqual(signature(original.text), signature(translated.text), name)

    def test_ios_all_shipped_locales(self):
        catalog = json.loads(
            (ROOT / "Strand/Resources/Localizable.xcstrings").read_text(),
            object_pairs_hook=unique_object,
        )
        locales = set().union(*(set(entry.get("localizations", {}))
                                for entry in catalog["strings"].values()))
        locales.discard(catalog["sourceLanguage"])
        for key in IOS_KEYS:
            entry = catalog["strings"][key]
            self.assertTrue(locales <= set(entry["localizations"]), key)
            for locale in locales:
                with self.subTest(key=key, locale=locale):
                    unit = entry["localizations"][locale]["stringUnit"]
                    self.assertEqual(unit["state"], "translated")
                    self.assertTrue(unit["value"])
                    self.assertEqual(signature(key), signature(unit["value"]))

if __name__ == "__main__":
    unittest.main()

