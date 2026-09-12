#!/usr/bin/env python3
"""Ordered operation and shard authority for the portable parity harness."""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Callable


JsonObject = dict[str, object]
Evaluator = Callable[[JsonObject], object]


class RegistryError(ValueError):
    """Raised when the registry or an operation contract is invalid."""


@dataclass(frozen=True)
class OperationSpec:
    key: str
    argument_keys: tuple[str, ...]
    core: Evaluator
    reference: Evaluator
    mutant: Callable[[object], object]


@dataclass(frozen=True)
class ShardSpec:
    name: str
    operations: tuple[OperationSpec, ...]


def _clamp_arguments(args: JsonObject) -> tuple[int | float, int | float, int | float]:
    if set(args) != {"lower", "upper", "value"}:
        raise RegistryError("Portable.clamp/3 args must contain exactly lower, upper, value")
    values = tuple(args[key] for key in ("value", "lower", "upper"))
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) for value in values):
        raise RegistryError("Portable.clamp/3 args must be finite numbers")
    if any(not math.isfinite(value) for value in values):
        raise RegistryError("Portable.clamp/3 args must be finite numbers")
    value, lower, upper = values
    if lower > upper:
        raise RegistryError("Portable.clamp/3 lower must not exceed upper")
    return value, lower, upper


def _core_clamp(args: JsonObject) -> object:
    value, lower, upper = _clamp_arguments(args)
    return value if lower <= value <= upper else max(lower, min(upper, value))


def _reference_clamp(args: JsonObject) -> object:
    value, lower, upper = _clamp_arguments(args)
    if value < lower:
        return lower
    if value > upper:
        return upper
    return value


def _off_by_one(value: object) -> object:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RegistryError("representative mutant requires a numeric result")
    return value + 1


REGISTRY = (
    ShardSpec(
        "core-reference",
        (
            OperationSpec(
                "Portable.clamp/3",
                ("lower", "upper", "value"),
                _core_clamp,
                _reference_clamp,
                _off_by_one,
            ),
        ),
    ),
)


def validate_registry(registry: tuple[ShardSpec, ...]) -> None:
    if not registry:
        raise RegistryError("registry must contain at least one shard")
    shard_names = [shard.name for shard in registry]
    if shard_names != sorted(shard_names) or len(shard_names) != len(set(shard_names)):
        raise RegistryError("shards must have unique names in canonical order")
    seen: set[str] = set()
    for shard in registry:
        if not shard.name or not shard.operations:
            raise RegistryError("every shard must have a name and at least one operation")
        keys = [operation.key for operation in shard.operations]
        if keys != sorted(keys):
            raise RegistryError(f"shard {shard.name} operations must be in canonical order")
        for operation in shard.operations:
            if not operation.key or operation.key in seen:
                raise RegistryError(f"duplicate operation {operation.key!r}")
            if operation.argument_keys != tuple(sorted(operation.argument_keys)):
                raise RegistryError(f"operation {operation.key} argument keys must be canonical")
            seen.add(operation.key)


validate_registry(REGISTRY)


def operation_index() -> dict[str, tuple[ShardSpec, OperationSpec]]:
    return {
        operation.key: (shard, operation)
        for shard in REGISTRY
        for operation in shard.operations
    }
