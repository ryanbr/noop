"""The pure complete-field verdict must gate all standard-HR entry points before effects."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent


def parser_body(relative, signature):
    text = (ROOT / relative).read_text(encoding="utf-8")
    start = text.index("{", text.index(signature)) + 1
    depth = 1
    end = start
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end - 1]


class StandardHRPacketContractTests(unittest.TestCase):
    def test_apple_parser_starts_with_complete_field_verdict(self):
        body = parser_body("Strand/BLE/StandardHeartRate.swift", "public static func parse(")
        self.assertRegex(body, r"^\s*guard StandardHRMeasurement\.hasCompleteFields\(data\) else \{ return nil \}")

    def test_android_sensor_parser_starts_with_complete_field_verdict(self):
        body = parser_body("android/app/src/main/java/com/noop/ble/StandardHeartRate.kt", "fun parse(")
        self.assertRegex(body, r"^\s*if \(!StandardHrMeasurement\.hasCompleteFields\(data\)\) return null")

    def test_android_whoop_parser_rejects_before_decoding_or_effects(self):
        body = parser_body("android/app/src/main/java/com/noop/ble/WhoopBleClient.kt", "private fun parseStandardHr(")
        self.assertRegex(body, r"^\s*if \(!com\.noop\.protocol\.StandardHrMeasurement\.hasCompleteFields\(data\)\) \{")
        verdict = body.split("}", 1)[0]
        self.assertIn('log("HR notify parse failed: incomplete measurement fields")', verdict)
        self.assertRegex(verdict, r"\breturn\s*$")


if __name__ == "__main__":
    unittest.main()
