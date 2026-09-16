"""An argument the arity walk cannot parse must not make the whole call disappear."""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path


TOOLS = Path(__file__).resolve().parents[1]
REPOSITORY = TOOLS.parent
sys.path.insert(0, str(TOOLS))

import parity_ledger  # noqa: E402


def arity_of(source: str) -> int | None:
    """Arity of the first call in `source`, as `_call_sites` would compute it."""
    return parity_ledger._arity(source, source.index("("))


class HalfOpenRangeTests(unittest.TestCase):
    """Why this exists: `_arity` returns None when it cannot balance the brackets, and every caller
    responds with `if arity is None: continue`. An unparseable argument therefore does not degrade
    the callsite, it ERASES it -- the scan reports a declaration nobody calls.

    Swift's half-open range operator ends in a `<` whose next character starts the upper bound, so it
    presents exactly like `Array<Int>`. The walk pushed a bracket nothing ever closed, ran to the end
    of the file and returned None. `Interpreter.hexString/1` is called once, on the line after its own
    declaration, passing `frame[max(0, off)..<max(off, end)]` -- and read as having no production
    callsite at all. Pair that with any test-local helper of the same name lending it a test callsite
    and it reports as test-only dead weight (#2257, where the helper was renamed: that removed the
    trigger, this removes the precondition).
    """

    def test_half_open_range_argument_is_one_argument(self):
        self.assertEqual(arity_of("hexString(frame[max(0, off)..<max(off, end)])"), 1)

    def test_half_open_range_does_not_swallow_the_following_arguments(self):
        self.assertEqual(arity_of("slice(buffer[0..<n], offset, limit)"), 3)

    def test_bare_half_open_range_argument(self):
        self.assertEqual(arity_of("take(0..<count)"), 1)

    def test_closed_range_argument(self):
        self.assertEqual(arity_of("take(0...count)"), 1)


class AngleBracketRegressionTests(unittest.TestCase):
    """The `..<` exemption must not re-admit the two constructs the original guard existed to reject,
    nor stop generic arguments from being balanced."""

    def test_generic_argument_still_balances(self):
        self.assertEqual(arity_of("register(Array<Int>(), key)"), 2)

    def test_nested_generic_argument_still_balances(self):
        self.assertEqual(arity_of("store(Dictionary<String, Array<Int>>(), key)"), 2)

    def test_less_than_comparison_is_not_an_opening_bracket(self):
        self.assertEqual(arity_of("assert(a < b)"), 1)

    def test_less_than_or_equal_comparison_is_not_an_opening_bracket(self):
        self.assertEqual(arity_of("assert(a <= b, message)"), 2)

    def test_empty_argument_list(self):
        self.assertEqual(arity_of("reset()"), 0)


class ProductionCallsiteTests(unittest.TestCase):
    """The real call this bug hid, asserted against the real file rather than a transcription."""

    INTERPRETER = REPOSITORY / "Packages/WhoopProtocol/Sources/WhoopProtocol/Interpreter.swift"

    def test_interpreter_hex_string_call_is_visible_to_the_scan(self):
        if not self.INTERPRETER.exists():  # pragma: no cover - path moved
            self.skipTest(f"{self.INTERPRETER} is not present")
        masked = parity_ledger._SourceSnapshot().masked(self.INTERPRETER)
        arities = [
            parity_ledger._arity(masked, match.end() - 1)
            for match in re.finditer(r"\bhexString\s*\(", masked)
        ]
        self.assertTrue(arities, "expected at least one hexString occurrence")
        self.assertNotIn(None, arities, "a hexString call is invisible to the scan")


if __name__ == "__main__":
    unittest.main()
