#!/usr/bin/env python3
"""Compare native dumps; permit PostgreSQL's redundant string-check cast spelling."""
import difflib
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[2]
engine = sys.argv[1] if len(sys.argv) == 2 else ""
if engine not in {"postgresql", "mysql2"}:
    raise SystemExit("Usage: compare_schemas.py postgresql|mysql2")
fresh = (root / ".local/state" / f"{engine}-fresh-schema.rb").read_text()
loaded = (root / "db" / f"schema_{engine}.rb").read_text()

def normalized(text):
    lines = []
    for line in text.splitlines(keepends=True):
        if engine == "postgresql" and "t.check_constraint " in line:
            # PG may deparse the same varchar IN check by casting the array or
            # each element to text. Column types, values/operators and all other
            # schema lines remain exact comparison inputs.
            line = line.replace("::text[]", "").replace("::character varying", "").replace("::text", "")
        lines.append(line)
    return lines

left, right = normalized(fresh), normalized(loaded)
if left != right:
    sys.stdout.writelines(difflib.unified_diff(left, right, "fresh", "schema-loaded"))
    raise SystemExit(1)
mode = "PostgreSQL redundant check text/varchar casts normalized" if engine == "postgresql" else "exact bytes"
print(f"PASS: fresh migrations and loaded schema agree; {mode}")
