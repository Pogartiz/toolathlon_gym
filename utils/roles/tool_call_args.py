"""Best-effort repair for malformed tool-call argument JSON from LLMs."""

from __future__ import annotations

import ast
import json
import re
from typing import Any


def _strip_fences(raw: str) -> str:
    text = raw.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json|JSON)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    return text.strip()


def _trailing_commas(raw: str) -> str:
    return re.sub(r",(\s*[}\]])", r"\1", raw)


def _first_json_object(raw: str) -> str | None:
    start = raw.find("{")
    if start < 0:
        start = raw.find("[")
        if start < 0:
            return None
        open_c, close_c = "[", "]"
    else:
        open_c, close_c = "{", "}"
    depth = 0
    in_str = False
    esc = False
    for i, ch in enumerate(raw[start:], start=start):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == open_c:
            depth += 1
        elif ch == close_c:
            depth -= 1
            if depth == 0:
                return raw[start : i + 1]
    return None


def _coerce_mapping(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    if isinstance(value, list):
        # Some models wrap args in a one-element list.
        if len(value) == 1 and isinstance(value[0], dict):
            return value[0]
        return {"items": value}
    if value is None:
        return {}
    return {"value": value}


def parse_tool_call_arguments(raw: Any) -> dict[str, Any]:
    """Parse tool-call arguments; repair common DeepSeek/OpenRouter glitches.

    Raises:
        json.JSONDecodeError / ValueError: when nothing salvageable remains.
    """
    if isinstance(raw, dict):
        return raw
    if raw is None:
        return {}
    if not isinstance(raw, str):
        raw = str(raw)

    text = _strip_fences(raw)
    if not text:
        return {}

    candidates = [text, _trailing_commas(text)]
    extracted = _first_json_object(text)
    if extracted and extracted not in candidates:
        candidates.append(extracted)
        candidates.append(_trailing_commas(extracted))

    last_exc: Exception | None = None
    for candidate in candidates:
        try:
            return _coerce_mapping(json.loads(candidate))
        except Exception as exc:  # noqa: BLE001 - try next strategy
            last_exc = exc

    # Python-literal style: {'a': 1}
    try:
        return _coerce_mapping(ast.literal_eval(text))
    except Exception as exc:  # noqa: BLE001
        last_exc = exc

    if last_exc is not None:
        raise last_exc
    raise ValueError(f"Unable to parse tool arguments: {text[:200]!r}")
