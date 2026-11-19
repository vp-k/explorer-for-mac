#!/usr/bin/env python3
"""Check literal Swift L/CL keys and English .strings format arguments.

Run from any directory. Extra translations are reported; missing keys, malformed
tables, duplicate keys and incompatible printf arguments cause a nonzero exit.
"""

import re
import sys
from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
QUOTED = r'"(?:\\[\s\S]|[^"\\])*"'
TOKENS = re.compile(
    rf'//[^\n]*|/\*[\s\S]*?\*/|{QUOTED}|[A-Za-z_][A-Za-z_0-9]*|[^\s]',
)
FORMAT = re.compile(
    r"%(?:(?P<position>[1-9]\d*)\$)?[-+ #0']*"
    r"(?P<width>\*(?:[1-9]\d*\$)?|\d+)?"
    r"(?:\.(?P<precision>\*(?:[1-9]\d*\$)?|\d*))?"
    r"(?P<length>hh|ll|[hljztqL])?(?P<type>[@diouxXfFeEgGaAcCsSpnDUO])"
)


def tokens(text):
    """Skip comments without removing comment-like text inside string literals."""
    return [match for match in TOKENS.finditer(text)
            if not match.group().startswith(("//", "/*"))]


def unquote(literal):
    """Decode Swift and OpenStep escapes while preserving literal Unicode."""
    escapes = {"n": "\n", "r": "\r", "t": "\t", "0": "\0", '"': '"',
               "'": "'", "\\": "\\", "a": "\a", "b": "\b", "f": "\f", "v": "\v"}

    def decode(match):
        value = match.group()[1:]
        if value.startswith("u{"):
            return chr(int(value[2:-1], 16))
        if value.startswith("U"):
            return chr(int(value[1:], 16))
        if len(value) > 1 and value[0] in "01234567":
            return chr(int(value, 8))
        if value not in escapes:
            raise ValueError(f"unsupported string escape: {match.group()}")
        return escapes[value]

    return re.sub(r"\\(?:u\{[0-9A-Fa-f]+\}|U[0-9A-Fa-f]{4}|[0-7]{2,3}|.)",
                  decode, literal[1:-1])


def source_keys(directory, function):
    keys = set()
    errors = []
    for path in sorted(directory.rglob("*.swift")):
        text = path.read_text(encoding="utf-8-sig")
        stream = tokens(text)
        for index, token in enumerate(stream[:-2]):
            if token.group() != function or stream[index + 1].group() != "(":
                continue
            literal = stream[index + 2].group()
            # Ignore the helper implementation's L(key)/CL(key) forwarding call.
            if not literal.startswith('"'):
                continue
            location = f"{path.relative_to(ROOT)}:{text.count(chr(10), 0, token.start()) + 1}"
            try:
                if r"\(" in literal:
                    raise ValueError("interpolated localization key; use printf placeholders")
                if stream[index + 3].group() not in (",", ")"):
                    raise ValueError("localization key must be a single string literal")
                keys.add(unquote(literal))
            except (ValueError, IndexError) as error:
                errors.append(f"{location}: {error}")
    return keys, errors


def translations(path):
    stream = tokens(path.read_text(encoding="utf-8-sig"))
    table = {}
    errors = []
    for index in range(0, len(stream), 4):
        entry = [token.group() for token in stream[index:index + 4]]
        if (len(entry) != 4 or not entry[0].startswith('"') or entry[1] != "="
                or not entry[2].startswith('"') or entry[3] != ";"):
            raise ValueError(f"{path.relative_to(ROOT)}: malformed .strings entry {entry!r}")
        key, value = unquote(entry[0]), unquote(entry[2])
        if key in table:
            errors.append(f"{path.relative_to(ROOT)}: duplicate key {key!r}")
        table[key] = value
    return table, errors


def placeholders(text):
    """Compare each argument's index and type; allow positional reordering.

    Width/precision stars consume int arguments. %% consumes no argument.
    Length modifiers distinguish %d, %ld, %lld, %zu, etc.
    """
    result = Counter()
    next_argument = 1
    offset = 0
    while offset < len(text):
        if text[offset] != "%":
            offset += 1
            continue
        if text.startswith("%%", offset):
            offset += 2
            continue
        match = FORMAT.match(text, offset)
        if match is None:
            # Ordinary percent signs (e.g. "100%") are not format arguments.
            offset += 1
            continue
        for name in ("width", "precision"):
            field = match[name]
            if field and field.startswith("*"):
                position = int(field[1:-1]) if field.endswith("$") else next_argument
                if not field.endswith("$"):
                    next_argument += 1
                result[(position, "d")] += 1
        position = int(match["position"]) if match["position"] else next_argument
        if match["position"] is None:
            next_argument += 1
        result[(position, (match["length"] or "") + match["type"])] += 1
        offset = match.end()
    return result


def check(directory, function, filename):
    keys, errors = source_keys(ROOT / "Sources" / directory, function)
    path = ROOT / "Resources" / "en.lproj" / filename
    table, table_errors = translations(path)
    errors.extend(table_errors)
    missing = keys - table.keys()
    extra = table.keys() - keys
    print(f"{function}: {len(keys)} source keys, {len(table)} translations, "
          f"{len(missing)} missing, {len(extra)} extra")
    for key in sorted(missing):
        print(f"  MISSING {key!r}")
    for key in sorted(extra):
        print(f"  EXTRA   {key!r}")
    for key, value in sorted(table.items()):
        source, translated = placeholders(key), placeholders(value)
        if source != translated:
            errors.append(f"{filename}: placeholder mismatch for {key!r}: "
                          f"source={dict(source)}, translation={dict(translated)}")
    for error in errors:
        print(f"  ERROR   {error}")
    return bool(missing or errors)


def main():
    failed = False
    for directory, function, filename in (
        ("ExplorerCore", "CL", "Core.strings"),
        ("Explorer", "L", "Localizable.strings"),
    ):
        try:
            failed |= check(directory, function, filename)
        except (OSError, ValueError) as error:
            print(f"ERROR: {error}", file=sys.stderr)
            failed = True
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
