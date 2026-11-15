"""The JSON Schema validator apelin_schema runs (Documents/Schemas/README.md)."""

from __future__ import annotations

import json
import re
from typing import Any


# --------------------------------------------------------------------------
# JSON Schema (draft 2020-12), the subset these schemas use
# --------------------------------------------------------------------------

# Annotations, plus then/else (read by _k_if) and $defs (read by _resolve).
_SKIPPED_KEYWORDS = {
    "$schema", "$id", "title", "description", "default", "$comment", "examples", "then", "else", "$defs",
}


class SchemaError(Exception):
    pass


def _type_matches(value: Any, name: str) -> bool:
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    if name == "string":
        return isinstance(value, str)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    raise SchemaError(f"unknown type {name}")


def _json_equal(a: Any, b: Any) -> bool:
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_json_equal(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_json_equal(x, y) for x, y in zip(a, b))
    return a == b


def _pattern_matches(pattern: str, text: str) -> bool:
    r"""re.search with ECMA-262's `$`, which matches only at the end of input.

    Python's `$` also matches before a final newline, so "x\n" would pass ^[a-z]+$. An anchor `$` (not escaped, not
    in a character class) becomes `\Z`.
    """
    translated = []
    escaped = in_class = False
    for ch in pattern:
        if escaped:
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == "[":
            in_class = True
        elif ch == "]":
            in_class = False
        elif ch == "$" and not in_class:
            ch = r"\Z"
        translated.append(ch)
    return re.search("".join(translated), text) is not None


class Validator:
    def __init__(self, schema: dict):
        self.root = schema

    def _resolve(self, ref: str) -> dict:
        if not ref.startswith("#/"):
            raise SchemaError(f"only local references are supported: {ref}")
        node: Any = self.root
        for part in ref[2:].split("/"):
            node = node[part.replace("~1", "/").replace("~0", "~")]
        return node

    def errors(self, instance: Any) -> list[str]:
        return self._sub(instance, self.root, "")

    def _check(self, value: Any, schema: Any, where: str, out: list[str]) -> None:
        if schema is True:
            return
        if schema is False:
            out.append(f"{where or '/'}: not allowed")
            return
        for keyword in schema:
            if keyword in _SKIPPED_KEYWORDS:
                continue
            handler = getattr(self, "_k_" + keyword.replace("$", "S"), None)
            if handler is None:
                raise SchemaError(f"unsupported keyword {keyword} at {where or '/'}")
            handler(value, schema[keyword], schema, where, out)

    def _sub(self, value: Any, schema: Any, where: str) -> list[str]:
        out: list[str] = []
        self._check(value, schema, where, out)
        return out

    # Keyword handlers --------------------------------------------------

    def _k_Sref(self, value, ref, schema, where, out):
        self._check(value, self._resolve(ref), where, out)

    def _k_type(self, value, names, schema, where, out):
        names = names if isinstance(names, list) else [names]
        if not any(_type_matches(value, n) for n in names):
            out.append(f"{where or '/'}: expected {'/'.join(names)}")

    def _k_enum(self, value, options, schema, where, out):
        if not any(_json_equal(value, o) for o in options):
            out.append(f"{where or '/'}: {json.dumps(value)} is not one of {json.dumps(options)}")

    def _k_const(self, value, expected, schema, where, out):
        if not _json_equal(value, expected):
            out.append(f"{where or '/'}: must be {json.dumps(expected)}")

    def _k_properties(self, value, props, schema, where, out):
        if isinstance(value, dict):
            for key, sub in props.items():
                if key in value:
                    self._check(value[key], sub, f"{where}/{key}", out)

    def _k_patternProperties(self, value, patterns, schema, where, out):
        if isinstance(value, dict):
            for pattern, sub in patterns.items():
                for key in value:
                    if _pattern_matches(pattern, key):
                        self._check(value[key], sub, f"{where}/{key}", out)

    def _k_additionalProperties(self, value, sub, schema, where, out):
        if not isinstance(value, dict):
            return
        known = set(schema.get("properties", {}))
        patterns = list(schema.get("patternProperties", {}))
        for key in value:
            if key in known or any(_pattern_matches(p, key) for p in patterns):
                continue
            if sub is False:
                out.append(f"{where}/{key}: unknown member")
            else:
                self._check(value[key], sub, f"{where}/{key}", out)

    def _k_propertyNames(self, value, sub, schema, where, out):
        if isinstance(value, dict):
            for key in value:
                if self._sub(key, sub, f"{where}/{key}"):
                    out.append(f"{where}/{key}: member name not allowed")

    def _k_required(self, value, names, schema, where, out):
        if isinstance(value, dict):
            for name in names:
                if name not in value:
                    out.append(f"{where or '/'}: missing {name}")

    def _k_minProperties(self, value, n, schema, where, out):
        if isinstance(value, dict) and len(value) < n:
            out.append(f"{where or '/'}: needs at least {n} members")

    def _k_maxProperties(self, value, n, schema, where, out):
        if isinstance(value, dict) and len(value) > n:
            out.append(f"{where or '/'}: allows at most {n} members")

    def _k_items(self, value, sub, schema, where, out):
        if isinstance(value, list):
            for index, item in enumerate(value):
                self._check(item, sub, f"{where}/{index}", out)

    def _k_minItems(self, value, n, schema, where, out):
        if isinstance(value, list) and len(value) < n:
            out.append(f"{where or '/'}: needs at least {n} items")

    def _k_maxItems(self, value, n, schema, where, out):
        if isinstance(value, list) and len(value) > n:
            out.append(f"{where or '/'}: allows at most {n} items")

    def _k_uniqueItems(self, value, flag, schema, where, out):
        if flag and isinstance(value, list):
            for i in range(len(value)):
                for j in range(i):
                    if _json_equal(value[i], value[j]):
                        out.append(f"{where}/{i}: duplicate item")

    def _k_contains(self, value, sub, schema, where, out):
        if isinstance(value, list) and all(self._sub(item, sub, where) for item in value):
            out.append(f"{where or '/'}: no item matches the required shape")

    def _k_minLength(self, value, n, schema, where, out):
        if isinstance(value, str) and len(value) < n:
            out.append(f"{where or '/'}: shorter than {n}")

    def _k_maxLength(self, value, n, schema, where, out):
        if isinstance(value, str) and len(value) > n:
            out.append(f"{where or '/'}: longer than {n}")

    def _k_pattern(self, value, pattern, schema, where, out):
        if isinstance(value, str) and not _pattern_matches(pattern, value):
            out.append(f"{where or '/'}: {json.dumps(value)} does not match {pattern}")

    def _k_minimum(self, value, n, schema, where, out):
        if _type_matches(value, "number") and value < n:
            out.append(f"{where or '/'}: below {n}")

    def _k_maximum(self, value, n, schema, where, out):
        if _type_matches(value, "number") and value > n:
            out.append(f"{where or '/'}: above {n}")

    def _k_allOf(self, value, subs, schema, where, out):
        for sub in subs:
            self._check(value, sub, where, out)

    def _k_anyOf(self, value, subs, schema, where, out):
        results = [self._sub(value, sub, where) for sub in subs]
        if all(results):
            out.append(f"{where or '/'}: matches none of the allowed shapes ({min(results, key=len)[0]})")

    def _k_oneOf(self, value, subs, schema, where, out):
        results = [self._sub(value, sub, where) for sub in subs]
        passing = sum(1 for r in results if not r)
        if passing == 0:
            out.append(f"{where or '/'}: matches none of the allowed shapes ({min(results, key=len)[0]})")
        elif passing > 1:
            out.append(f"{where or '/'}: matches more than one shape")

    def _k_not(self, value, sub, schema, where, out):
        if not self._sub(value, sub, where):
            out.append(f"{where or '/'}: matches a forbidden shape")

    def _k_if(self, value, sub, schema, where, out):
        if not self._sub(value, sub, where):
            if "then" in schema:
                self._check(value, schema["then"], where, out)
        elif "else" in schema:
            self._check(value, schema["else"], where, out)
