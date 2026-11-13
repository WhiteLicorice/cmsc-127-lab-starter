"""Execute one SQL file and print its result as JSON."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from datetime import date
from decimal import Decimal
import json
import math
import os
from pathlib import Path
import sys
from typing import Any, cast

import psycopg
import psycopg.sql


def _json_text(value: object) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, Decimal):
        return format(value, "f") if value.is_finite() else json.dumps(str(value))
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return json.dumps(value) if math.isfinite(value) else json.dumps(str(value))
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, date):
        return json.dumps(value.isoformat())
    if isinstance(value, bytes):
        return json.dumps(value.hex())
    if isinstance(value, Mapping):
        mapping = cast(Mapping[str, object], value)
        return "{" + ", ".join(
            f"{json.dumps(key, ensure_ascii=False)}: {_json_text(item)}"
            for key, item in mapping.items()
        ) + "}"
    if isinstance(value, (list, tuple)):
        sequence = cast(Sequence[object], value)
        return "[" + ", ".join(_json_text(item) for item in sequence) + "]"
    return json.dumps(str(value), ensure_ascii=False)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: ./run path/to/query.sql", file=sys.stderr)
        return 2
    database_url = os.environ.get("CMSC127_DATABASE_URL")
    if not database_url:
        print("Set CMSC127_DATABASE_URL before running a query.", file=sys.stderr)
        return 2
    query_path = Path(sys.argv[1])
    if not query_path.is_file() or query_path.suffix != ".sql":
        print("The query path must name an existing .sql file.", file=sys.stderr)
        return 2
    with psycopg.connect(database_url) as connection:
        with connection.cursor() as cursor:
            query = cast(Any, query_path.read_text(encoding="utf-8"))
            cursor.execute(psycopg.sql.SQL(query))
            result: dict[str, object]
            if cursor.description is None:
                result = {"columns": [], "rows": []}
            else:
                rows = cast(list[tuple[object, ...]], cursor.fetchall())
                result = {
                    "columns": [column.name for column in cursor.description],
                    "rows": [list(row) for row in rows],
                }
    print(_json_text(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
