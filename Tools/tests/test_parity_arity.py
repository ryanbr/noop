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


class OperatorAngleBracketTests(unittest.TestCase):
    """Why this exists: `<` is the only genuinely ambiguous character in the walk. A generic argument
    list needs it treated as a bracket; `a << b` and `a<b` need it treated as an operator; and no
    lexical rule separates the two. Guarding one spelling at a time does not converge: exempting the
    half-open range operator still leaves every shift expression erased, 35 of them here, in decoders
    and importers alike.

    So the ambiguity is resolved by outcome: if the walk cannot balance, retry with angle brackets
    demoted to ordinary characters, and if THAT balances it was an operator. A call that already
    balanced returns before the retry, so no successful parse can change.
    """

    def test_left_shift_argument(self):
        self.assertEqual(arity_of("write(mask << 8)"), 1)

    def test_left_shift_does_not_swallow_the_following_arguments(self):
        self.assertEqual(arity_of("write(mask << 3, flags)"), 2)

    def test_right_shift_argument(self):
        self.assertEqual(arity_of("write(mask >> 8)"), 1)

    def test_comparison_without_surrounding_space(self):
        self.assertEqual(arity_of("assert(i<n)"), 1)

    def test_comparison_without_surrounding_space_keeps_later_arguments(self):
        self.assertEqual(arity_of("assert(i<n, message)"), 2)

    def test_generic_and_operator_in_the_same_call(self):
        self.assertEqual(arity_of("register(Set<Int>(), flags << 2)"), 2)

    def test_retry_only_runs_when_the_strict_walk_fails(self):
        """The retry is lossy for a generic carrying a comma, because demoting the angle brackets
        exposes that comma as a separator. This is tolerable ONLY because a call that parses
        strictly never reaches the retry. Pin that ordering, since losing it would silently
        re-arity every generic call in the repository."""
        source = "store(Dictionary<String, Int>(), key)"
        self.assertEqual(arity_of(source), 2)
        self.assertEqual(
            parity_ledger._arity(source, source.index("("), angles_are_brackets=False),
            3,
            "retry is expected to over-count here; the strict walk must therefore win",
        )

    def test_half_open_range_is_kept_off_the_lossy_retry(self):
        """`..<` is exempted in the strict walk rather than left to the retry, so a call that pairs
        it with a comma-carrying generic still parses accurately."""
        self.assertEqual(arity_of("f(Dictionary<String, Int>(), x..<y)"), 2)


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
