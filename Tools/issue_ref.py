"""Strict, repository-qualified references for governed GitHub issues."""

from __future__ import annotations

import re
from dataclasses import dataclass


_CURRENT = re.compile(
    r"(?P<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)/"
    r"(?P<name>[A-Za-z0-9][A-Za-z0-9_.-]*)#(?P<number>[1-9][0-9]*)"
)
class IssueRefError(ValueError):
    """Raised when governed issue metadata is not canonical."""


@dataclass(frozen=True, order=True)
class IssueRef:
    repo: str
    number: int

    def __str__(self) -> str:
        return f"{self.repo}#{self.number}"


def parse_current(value: object) -> IssueRef:
    """Parse only the canonical current ``owner/repo#N`` representation."""
    if not isinstance(value, str):
        raise IssueRefError("issue must be a canonical owner/repo#N string")
    match = _CURRENT.fullmatch(value)
    if match is None:
        raise IssueRefError(f"invalid issue reference {value!r}; expected owner/repo#N")
    return IssueRef(
        f"{match.group('owner')}/{match.group('name')}",
        int(match.group("number")),
    )


def validate_current_issue_fields(value: object, location: str = "JSON") -> None:
    """Validate every governed field literally named ``issue`` in current JSON."""
    def walk(node: object, pointer: str) -> None:
        if isinstance(node, dict):
            for key, child in node.items():
                child_pointer = f"{pointer}/{key}"
                if key == "issue":
                    try:
                        parse_current(child)
                    except IssueRefError as exc:
                        raise IssueRefError(f"{location}{child_pointer}: {exc}") from exc
                walk(child, child_pointer)
        elif isinstance(node, list):
            for index, child in enumerate(node):
                walk(child, f"{pointer}/{index}")

    walk(value, "")
