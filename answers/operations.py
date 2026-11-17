"""Run the Lab 3 enrollment and payment operations."""

from __future__ import annotations

from datetime import date
from decimal import Decimal, InvalidOperation
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Any, cast

import psycopg
import psycopg.sql
from psycopg.conninfo import conninfo_to_dict


ROOT = Path(__file__).resolve().parent.parent


def _statement(path: Path) -> psycopg.sql.SQL:
    return psycopg.sql.SQL(cast(Any, path.read_text(encoding="utf-8")))


def _run_sql(
    connection: psycopg.Connection[tuple[object, ...]],
    path: Path,
    parameters: tuple[object, ...] = (),
) -> tuple[object, ...] | None:
    with connection.cursor() as cursor:
        cursor.execute(_statement(path), parameters)
        row = cursor.fetchone() if cursor.description is not None else None
    return row


def _query_one(
    connection: psycopg.Connection[tuple[object, ...]],
    statement: str,
    parameters: tuple[object, ...],
) -> tuple[object, ...] | None:
    with connection.cursor() as cursor:
        cursor.execute(psycopg.sql.SQL(cast(Any, statement)), parameters)
        row = cursor.fetchone()
    return row


def _url(operation: str) -> str:
    variable = "CMSC127_REGISTRAR_DATABASE_URL" if operation == "enroll" else "CMSC127_CASHIER_DATABASE_URL"
    database_url = os.environ.get(variable)
    if not database_url:
        raise ValueError(f"Set {variable} before running this operation.")
    return database_url


def _constraint_message(error: psycopg.Error, operation: str) -> str:
    constraint = error.diag.constraint_name or ""
    if constraint in {"payment_seq_check", "installment_number_check"}:
        return "Payment number must be from 1 to 99."
    if constraint in {"payment_amount_check", "installment_amount_check"}:
        return "Payment amount must be greater than zero."
    if constraint in {"payment_receipt_code_check", "installment_receipt_code_check"}:
        return "Receipt code must contain 1 to 40 characters without outer spaces."
    if operation == "enroll":
        return "Enrollment failed. No rows changed."
    return "Payment failed. No row changed."


def _operation_path(operation: str, mode: str, name: str) -> Path:
    return ROOT / "operations" / operation / mode / f"{name}.sql"


def _enroll(arguments: list[str]) -> int:
    if len(arguments) != 3:
        print("Usage: ./run enroll STUDENT_ID SECTION_ID YYYY-MM-DD", file=sys.stderr)
        return 2
    student_id = int(arguments[0])
    section_id = int(arguments[1])
    enrolled_on = date.fromisoformat(arguments[2])
    with psycopg.connect(_url("enroll")) as connection:
        with connection.transaction():
            student_sql = "SELECT student_id FROM student WHERE student_id = %s"
            lock_sql = _operation_path("enroll", "safe", "lock")
            insert_sql = _operation_path("enroll", "safe", "insert")
            student = _query_one(connection, student_sql, (student_id,))
            if student is None:
                raise ValueError("Student not found.")
            _run_sql(
                connection,
                _operation_path("enroll", "safe", "lock_timeout"),
            )
            _run_sql(
                connection,
                _operation_path("enroll", "safe", "statement_timeout"),
            )
            _run_sql(connection, lock_sql, (section_id,))
            details_sql = "SELECT term, instructor_id FROM section WHERE section_id = %s"
            details = _query_one(connection, details_sql, (section_id,))
            if details is None:
                raise ValueError("Section not found.")
            counts = _run_sql(
                connection,
                _operation_path("enroll", "safe", "count"),
                (section_id,),
            )
            if counts is None:
                raise ValueError("Section not found.")
            capacity = cast(int, counts[0])
            enrolled = cast(int, counts[1])
            if enrolled >= capacity:
                raise ValueError("The section is full.")
            insert_values: tuple[object, ...] = (
                student_id,
                cast(str, details[0]),
                cast(int, details[1]),
                enrolled_on,
            )
            _run_sql(connection, insert_sql, insert_values)
    print(f"Student {student_id} enrolled in section {section_id}.")
    return 0


def _payment(arguments: list[str]) -> int:
    if len(arguments) != 6:
        print("Usage: ./run payment STUDENT_ID TERM NUMBER AMOUNT YYYY-MM-DD RECEIPT_CODE", file=sys.stderr)
        return 2
    student_id = int(arguments[0])
    term = arguments[1]
    number = int(arguments[2])
    amount = Decimal(arguments[3])
    paid_on = date.fromisoformat(arguments[4])
    receipt_code = arguments[5]
    if not receipt_code:
        raise ValueError("Enter a receipt code.")
    with psycopg.connect(_url("payment")) as connection:
        with connection.transaction():
            charge_sql = "SELECT student_id FROM charge WHERE student_id = %s AND term = %s"
            with connection.cursor() as cursor:
                cursor.execute(psycopg.sql.SQL(charge_sql), (student_id, term))
                charge = cursor.fetchone()
            if charge is None:
                raise ValueError("The charge does not exist.")
            if not 1 <= number <= 99:
                raise ValueError("Payment number must be from 1 to 99.")
            if amount <= 0:
                raise ValueError("Payment amount must be greater than zero.")
            path = _operation_path("payment", "safe", "insert")
            _run_sql(
                connection,
                path,
                (student_id, term, number, amount, paid_on, receipt_code),
            )
    print(f"Payment {receipt_code} recorded.")
    return 0


def _race(arguments: list[str]) -> int:
    if arguments not in ([], ["--variant"]):
        print("Usage: ./run race [--variant]", file=sys.stderr)
        return 2
    variant = arguments == ["--variant"]
    database_url = os.environ.get("CMSC127_DATABASE_URL")
    if not database_url:
        raise ValueError("Set CMSC127_DATABASE_URL before running the race driver.")
    connection_info = conninfo_to_dict(database_url)
    database = cast(str, connection_info.get("dbname", ""))
    if not database:
        raise ValueError("The database URL must name a database.")
    command = [
        sys.executable,
        str(ROOT / "race" / "race.py"),
        database,
        "--scratch",
    ]
    if variant:
        command.append("--variant")
    completed = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
    )
    expected_exit = 1 if variant else 0
    if completed.returncode != expected_exit:
        print(completed.stderr, file=sys.stderr, end="")
        return 1
    raw_result = json.loads(completed.stdout)
    result = cast(dict[str, object], raw_result)
    if variant:
        overbooked = result.get("failed_runs")
        print(json.dumps({"columns": ["overbooked_runs"], "rows": [[overbooked]]}))
        return 0 if overbooked == 10 else 1
    unsafe = cast(dict[str, object], result["unsafe"])
    safe = cast(dict[str, object], result["safe"])
    print(json.dumps({
        "columns": ["unsafe_wrong_runs", "safe_right_runs"],
        "rows": [[unsafe["wrong_runs"], safe["right_runs"]]],
    }))
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: ./run enroll | payment | race", file=sys.stderr)
        return 2
    operation = sys.argv[1]
    try:
        if operation == "enroll":
            return _enroll(sys.argv[2:])
        if operation == "payment":
            return _payment(sys.argv[2:])
        if operation == "race":
            return _race(sys.argv[2:])
    except (OSError, ValueError, InvalidOperation, psycopg.Error) as error:
        if isinstance(error, psycopg.errors.ForeignKeyViolation):
            message = "The charge does not exist." if operation == "payment" else "Student or section not found."
        elif isinstance(error, psycopg.errors.UniqueViolation):
            if error.diag.constraint_name == "payment_receipt_code_key":
                message = "That receipt code is already in use."
            elif error.diag.constraint_name == "student_course_pkey":
                message = "The student already takes this course in this term."
            else:
                message = "The student is already enrolled in this section."
        elif isinstance(error, psycopg.errors.CheckViolation):
            message = _constraint_message(error, operation)
        elif isinstance(error, psycopg.errors.NotNullViolation):
            message = "Enter a receipt code."
        elif isinstance(error, psycopg.errors.QueryCanceled):
            message = "The section lock timed out. Try again."
        elif isinstance(error, psycopg.errors.InsufficientPrivilege):
            message = "This database role cannot perform that operation."
        elif isinstance(error, ValueError):
            message = str(error)
        else:
            message = "Enrollment failed. No rows changed." if operation == "enroll" else "Payment failed. No row changed."
        print(message, file=sys.stderr)
        return 1
    print("Choose enroll or payment.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
