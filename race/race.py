"""Run the enrollment race in a fixed schedule against one scratch database."""

from __future__ import annotations

import argparse
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
import json
import os
from pathlib import Path
import sys
import time
from typing import LiteralString, cast

import psycopg
from psycopg.rows import tuple_row


ROOT = Path(__file__).resolve().parents[1]
REPEATS = 10
STUDENT_LIMIT = REPEATS * 2
LOCK_WAIT_SECONDS = 5.0
SCRATCH_PREFIX = "cmsc127_race_"
DATE = "2099-08-01"
WAIT_EVENT_SQL = """
SELECT wait_event_type
  FROM pg_stat_activity
 WHERE application_name = %s
"""


@dataclass(frozen=True)
class Fixture:
    """One section with exactly one free seat and twenty valid students."""

    section_id: int
    term: str
    instructor_id: int
    original_capacity: int
    enrollment_count: int
    student_ids: list[int]


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _connect(
    database: str,
    application_name: str,
) -> psycopg.Connection[tuple[object, ...]]:
    return psycopg.connect(
        os.environ["CMSC127_DATABASE_URL"],
        dbname=database,
        connect_timeout=3,
        options="-c lock_timeout=2000 -c statement_timeout=10000",
        application_name=application_name,
        autocommit=True,
        row_factory=tuple_row,
    )


def _one(
    connection: psycopg.Connection[tuple[object, ...]],
    query: str,
    parameters: tuple[object, ...] = (),
) -> tuple[object, ...] | None:
    with connection.cursor() as cursor:
        cursor.execute(cast(LiteralString, query), parameters)
        return cursor.fetchone()


def _all(
    connection: psycopg.Connection[tuple[object, ...]],
    query: str,
    parameters: tuple[object, ...] = (),
) -> list[tuple[object, ...]]:
    with connection.cursor() as cursor:
        cursor.execute(cast(LiteralString, query), parameters)
        return cursor.fetchall()


def _execute(
    connection: psycopg.Connection[tuple[object, ...]],
    query: str,
    parameters: tuple[object, ...] = (),
) -> None:
    with connection.cursor() as cursor:
        cursor.execute(cast(LiteralString, query), parameters)


def _fixture(
    connection: psycopg.Connection[tuple[object, ...]],
) -> Fixture:
    sections_path = ROOT / "race" / "fixtures" / "sections.sql"
    students_path = ROOT / "race" / "fixtures" / "students.sql"
    update_sql = "UPDATE section SET section_capacity = %s WHERE section_id = %s"

    for row in _all(connection, _read(sections_path)):
        section_id = cast(int, row[0])
        term = cast(str, row[1])
        instructor_id = cast(int, row[2])
        original_capacity = cast(int, row[4])
        enrollment_count = cast(int, row[5])
        if enrollment_count >= 32767:
            continue
        students = _all(
            connection,
            _read(students_path),
            (STUDENT_LIMIT,),
        )
        if len(students) != STUDENT_LIMIT:
            continue
        _execute(connection, update_sql, (enrollment_count + 1, section_id))
        return Fixture(
            section_id=section_id,
            term=term,
            instructor_id=instructor_id,
            original_capacity=original_capacity,
            enrollment_count=enrollment_count,
            student_ids=[cast(int, student[0]) for student in students],
        )
    raise RuntimeError("No section has twenty eligible students for the race.")


def _restore_capacity(
    connection: psycopg.Connection[tuple[object, ...]],
    fixture: Fixture,
) -> None:
    query = "UPDATE section SET section_capacity = %s WHERE section_id = %s"
    _execute(connection, query, (fixture.original_capacity, fixture.section_id))


def _operation_paths(
    variant: bool,
) -> tuple[Path, Path]:
    if variant:
        directory = ROOT / "variants" / "race"
        return directory / "count.sql", directory / "insert.sql"
    directory = ROOT / "operations" / "enroll"
    return (
        directory / "unsafe" / "count.sql",
        directory / "unsafe" / "insert.sql",
    )


def _count(
    connection: psycopg.Connection[tuple[object, ...]],
    query: str,
    section_id: int,
) -> tuple[int, int]:
    row = _one(connection, query, (section_id,))
    if row is None:
        raise RuntimeError(f"Section {section_id} does not exist.")
    if len(row) == 1:
        capacity = _one(
            connection,
            "SELECT section_capacity FROM section WHERE section_id = %s",
            (section_id,),
        )
        if capacity is None:
            raise RuntimeError(f"Section {section_id} does not exist.")
        return cast(int, capacity[0]), cast(int, row[0])
    return cast(int, row[0]), cast(int, row[1])


def _enroll(
    connection: psycopg.Connection[tuple[object, ...]],
    fixture: Fixture,
    student_id: int,
    query: str,
) -> None:
    parameters: tuple[object, ...] = (
        student_id,
        fixture.term,
        fixture.instructor_id,
        DATE,
    )
    _execute(connection, query, parameters)


def _cleanup(
    connection: psycopg.Connection[tuple[object, ...]],
    fixture: Fixture,
    student_ids: list[int],
) -> None:
    query = "DELETE FROM enrollment WHERE student_id = %s AND term = %s AND instructor_id = %s"
    for student_id in student_ids:
        _execute(
            connection,
            query,
            (student_id, fixture.term, fixture.instructor_id),
        )


def _run_unsafe(
    first: psycopg.Connection[tuple[object, ...]],
    second: psycopg.Connection[tuple[object, ...]],
    fixture: Fixture,
    variant: bool,
) -> int:
    count_path, insert_path = _operation_paths(variant)
    check_sql = _read(count_path)
    insert_sql = _read(insert_path)
    begin_sql = ""
    commit_sql = ""
    if variant:
        directory = ROOT / "variants" / "race"
        begin_sql = _read(directory / "begin.sql")
        commit_sql = _read(directory / "commit.sql")
    overbooked = 0

    for run in range(REPEATS):
        first_student = fixture.student_ids[run * 2]
        second_student = fixture.student_ids[run * 2 + 1]
        try:
            if variant:
                _execute(first, begin_sql)
                _execute(second, begin_sql)
            first_capacity, first_count = _count(first, check_sql, fixture.section_id)
            second_capacity, second_count = _count(second, check_sql, fixture.section_id)
            expected_capacity = fixture.enrollment_count + 1
            if (
                first_capacity != expected_capacity
                or second_capacity != expected_capacity
                or first_count != fixture.enrollment_count
                or second_count != fixture.enrollment_count
            ):
                raise RuntimeError("Both sessions did not read the same one-seat state.")

            _enroll(first, fixture, first_student, insert_sql)
            _enroll(second, fixture, second_student, insert_sql)
            if variant:
                _execute(first, commit_sql)
                _execute(second, commit_sql)
        except Exception:
            if variant:
                first.rollback()
                second.rollback()
            raise

        actual_capacity, actual_count = _count(first, check_sql, fixture.section_id)
        if actual_count != actual_capacity + 1:
            raise RuntimeError("The unsafe schedule did not overbook by one row.")
        overbooked += 1
        _cleanup(first, fixture, [first_student, second_student])
        _, clean_count = _count(first, check_sql, fixture.section_id)
        if clean_count != fixture.enrollment_count:
            raise RuntimeError("The unsafe run did not clean its enrollment rows.")
    return overbooked


def _wait_for_lock(
    connection: psycopg.Connection[tuple[object, ...]],
    application_name: str,
    future: Future[tuple[object, ...] | None],
) -> None:
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    while time.monotonic() < deadline:
        row = _one(connection, WAIT_EVENT_SQL, (application_name,))
        if row is not None and row[0] == "Lock":
            return
        if future.done():
            raise RuntimeError("The second session completed without waiting for the section lock.")
        time.sleep(0.01)
    raise TimeoutError("The second session did not reach the section lock in time.")


def _run_safe(
    first: psycopg.Connection[tuple[object, ...]],
    second: psycopg.Connection[tuple[object, ...]],
    fixture: Fixture,
    run_index: int,
) -> None:
    directory = ROOT / "operations" / "enroll" / "safe"
    begin_sql = _read(directory / "begin.sql")
    lock_timeout_sql = _read(directory / "lock_timeout.sql")
    statement_timeout_sql = _read(directory / "statement_timeout.sql")
    lock_sql = _read(directory / "lock.sql")
    count_sql = _read(directory / "count.sql")
    insert_sql = _read(directory / "insert.sql")
    commit_sql = _read(directory / "commit.sql")
    rollback_sql = _read(directory / "rollback.sql")
    first_student = fixture.student_ids[run_index * 2]
    second_name = f"cmsc127_race_b_{os.getpid()}"
    try:
        _execute(first, begin_sql)
        _execute(first, lock_timeout_sql)
        _execute(first, statement_timeout_sql)
        first_lock = _one(first, lock_sql, (fixture.section_id,))
        if first_lock is None:
            raise RuntimeError("The first session could not lock the section.")
        capacity, current_count = _count(first, count_sql, fixture.section_id)
        if capacity != fixture.enrollment_count + 1 or current_count != fixture.enrollment_count:
            raise RuntimeError("The first session did not find one free seat.")

        _execute(second, begin_sql)
        _execute(second, lock_timeout_sql)
        _execute(second, statement_timeout_sql)
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(_one, second, lock_sql, (fixture.section_id,))
            _wait_for_lock(first, second_name, future)
            _enroll(first, fixture, first_student, insert_sql)
            _execute(first, commit_sql)
            second_lock = future.result(timeout=LOCK_WAIT_SECONDS)
            if second_lock is None:
                raise RuntimeError("The second session could not lock the section.")
        second_capacity, second_count = _count(second, count_sql, fixture.section_id)
        if second_capacity != capacity or second_count != capacity:
            raise RuntimeError("The second session did not reject the now-full section.")
        _execute(second, rollback_sql)
    except Exception:
        first.rollback()
        second.rollback()
        raise

    _cleanup(first, fixture, [first_student])
    _, clean_count = _count(first, count_sql, fixture.section_id)
    if clean_count != fixture.enrollment_count:
        raise RuntimeError("The safe run did not clean its enrollment row.")


def _run(
    database: str,
    variant: bool,
    scratch: bool,
) -> dict[str, object]:
    if scratch and not database.startswith(SCRATCH_PREFIX):
        raise ValueError(f"The database name must start with {SCRATCH_PREFIX} when --scratch is set.")

    process_id = os.getpid()
    first_name = f"cmsc127_race_a_{process_id}"
    second_name = f"cmsc127_race_b_{process_id}"
    with _connect(database, first_name) as first, _connect(database, second_name) as second:
        fixture = _fixture(first)
        try:
            if variant:
                overbooked = _run_unsafe(first, second, fixture, True)
                return {
                    "check": "safe enrollment",
                    "variant": "overbooked",
                    "runs": REPEATS,
                    "failed_runs": overbooked,
                }

            wrong_runs = _run_unsafe(first, second, fixture, False)
            right_runs = 0
            for run_index in range(REPEATS):
                _run_safe(first, second, fixture, run_index)
                right_runs += 1
            return {
                "unsafe": {
                    "runs": REPEATS,
                    "wrong_runs": wrong_runs,
                    "over_capacity_by": 1,
                },
                "safe": {
                    "runs": REPEATS,
                    "right_runs": right_runs,
                    "accepted": 1,
                    "rejected": 1,
                },
            }
        finally:
            _cleanup(first, fixture, fixture.student_ids)
            _restore_capacity(first, fixture)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", help="scratch database with Lab 1 and Lab 2 data")
    parser.add_argument("--variant", action="store_true", help="run the unlocked defect variant")
    parser.add_argument(
        "--scratch",
        action="store_true",
        help="require a scratch database name with the cmsc127_race_ prefix",
    )
    arguments = parser.parse_args()
    database = cast(str, arguments.database)
    variant = cast(bool, arguments.variant)
    scratch = cast(bool, arguments.scratch)

    try:
        result = _run(database, variant, scratch)
    except Exception as error:
        print(f"race driver failed: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    if variant:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
