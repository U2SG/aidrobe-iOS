#!/usr/bin/env python3
"""Rewrite FastAPI's OpenAPI 3.1 nullable unions for swift-openapi-generator.

FastAPI emits optional fields as `anyOf: [<schema>, {"type": "null"}]`. The
generator does not support the `null` schema and silently drops such
properties, so they never reach Swift. This collapses the union to `<schema>`
and removes the property from `required`, which the generator renders as a
Swift Optional — the same semantics.

Input:  contracts/openapi.json (byte-identical copy of the backend's spec)
Output: Packages/AidrobeKit/Sources/AidrobeKit/openapi.json (generator input)
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "contracts" / "openapi.json"
TARGET = ROOT / "Packages" / "AidrobeKit" / "Sources" / "AidrobeKit" / "openapi.json"


def is_null(schema: object) -> bool:
    return isinstance(schema, dict) and schema.get("type") == "null"


def strip_null(schema: dict) -> tuple[dict, bool]:
    """Returns (schema without the null branch, whether it was nullable)."""
    for key in ("anyOf", "oneOf"):
        branches = schema.get(key)
        if isinstance(branches, list) and any(is_null(b) for b in branches):
            rest = [b for b in branches if not is_null(b)]
            extras = {k: v for k, v in schema.items() if k != key}
            if len(rest) == 1:
                merged = {**rest[0], **{k: v for k, v in extras.items() if k not in rest[0]}}
                return merged, True
            return {**extras, key: rest}, True
    return schema, False


def walk(node: object) -> object:
    if isinstance(node, list):
        return [walk(item) for item in node]
    if not isinstance(node, dict):
        return node
    node = {key: walk(value) for key, value in node.items()}
    node, _ = strip_null(node)
    properties = node.get("properties")
    if isinstance(properties, dict):
        nullable = set()
        for name, prop in list(properties.items()):
            stripped, was_nullable = strip_null(prop) if isinstance(prop, dict) else (prop, False)
            properties[name] = stripped
            if was_nullable:
                nullable.add(name)
        if nullable and isinstance(node.get("required"), list):
            node["required"] = [name for name in node["required"] if name not in nullable]
    return node


def render() -> str:
    spec = json.loads(SOURCE.read_text())
    return json.dumps(walk(spec), ensure_ascii=False, indent=1) + "\n"


if __name__ == "__main__":
    output = render()
    if "--check" in sys.argv:
        if not TARGET.exists() or TARGET.read_text() != output:
            sys.exit(f"{TARGET.relative_to(ROOT)} is stale; run scripts/normalize-openapi.py")
        sys.exit(0)
    TARGET.write_text(output)
