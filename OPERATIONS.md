# Lab 3 Operation Catalog

The application sends parameterized SQL through `psycopg`. Each operation has inputs, a success message, and one plain message for each error a user can cause. The command layer is in `answers/operations.py`. The SQL files under `operations/` are yours.

## Enroll a Student

Inputs: student ID, section ID, and enrollment date.

The application reads the section and counts its enrollment rows. It inserts one row into your enrollment table. A trigger inserts the matching course choice into your course-choice table in the same transaction.

Success: `Student <student id> enrolled in section <section id>.`

Errors:

- `Enter the student number as digits.`
- `Enter the section number as digits.`
- `Enter the date as YYYY-MM-DD.`
- `Student not found.`
- `Section not found.`
- `The section is full.`
- `The student is already enrolled in this section.`
- `The student already takes this course in this term.`
- `The section lock timed out. Try again.`
- `Enrollment failed. No rows changed.`

The unsafe SQL reads the enrollment count and inserts without a transaction. The safe SQL begins a transaction, sets a two-second lock timeout and a ten-second statement timeout, locks the section row, counts the enrollment rows, inserts when a seat remains, and commits.

The transaction uses PostgreSQL's default `READ COMMITTED` isolation. The count runs after the row lock, so it sees the earlier commit.

Section capacity is a shared limit that two sessions can read. The count and the insert are separate steps, so both sessions can act on the same stale count. This check-then-act race uses enrollment data students already know. The safe operation locks the section before it counts. The row lock enforces capacity only when every enrollment writer follows the lock-then-count protocol. Under `READ COMMITTED`, each statement gets a fresh snapshot, so a transaction alone still lets both sessions count before either inserts.

The insert and the trigger form one atomic operation. A failed insert or trigger rolls back both table changes. The application maps unique and foreign-key errors to the messages above.

## Record a Payment

Inputs: student ID, term, payment number, amount, payment date, and receipt code.

The operation inserts one row into your payment table.

Success: `Payment <receipt code> recorded.`

Errors:

- `Enter the student number as digits.`
- `Enter the payment number as digits.`
- `Enter the amount as a number.`
- `Enter the date as YYYY-MM-DD.`
- `The charge does not exist.`
- `Payment number must be from 1 to 99.`
- `Payment amount must be greater than zero.`
- `Enter a receipt code.`
- `Receipt code must contain 1 to 40 characters without leading or trailing spaces.`
- `That receipt code is already in use.`
- `Payment failed. No row changed.`

Lab 3 adds a receipt code to each payment table. Stable legacy codes identify existing rows. A check rejects blank or padded codes. A unique constraint rejects a repeated code. `NOT NULL` rejects a missing code.

The unsafe form runs one `INSERT` in autocommit mode. A transaction wraps the safe form around the same insert. The application reads the safe file. PostgreSQL already makes one statement atomic, so this operation needs no row lock.

## Roles

Registrars may read student, section, and enrollment details and insert enrollments. They may not insert payments. Cashiers may read charges and payments and insert payments. They may not insert enrollments. The application connects with a login role that's a member of the registrar or cashier group role. The group roles stay `NOLOGIN`.

The grants migration gives no direct write access to the course-choice helper table. It marks the existing trigger function as `SECURITY DEFINER` and fixes its search path. The trigger can then maintain that table when the registrar inserts an enrollment.

The lock migration grants the registrar access to one fixed-search-path function. The function locks a section without granting the registrar permission to update section data.

## SQL Files

Two programs read these files. `answers/operations.py` runs the enroll and payment commands. `race/race.py` runs the race. The command layer opens each transaction through `psycopg`'s `connection.transaction()`, so it never reads `begin.sql`, `commit.sql`, or `rollback.sql`. Each file holds one statement. The `%s` marks a parameter, in the order the program passes it.

| File | The statement it holds | Parameters | Read by |
|:--|:--|:--|:--|
| `operations/enroll/unsafe/count.sql` | The count without a lock | section ID | race |
| `operations/enroll/unsafe/insert.sql` | The insert without a transaction | student ID, term, instructor ID, date | race |
| `operations/enroll/safe/begin.sql` | `BEGIN;` | none | race |
| `operations/enroll/safe/lock_timeout.sql` | `SET LOCAL lock_timeout = '2s';` | none | command and race |
| `operations/enroll/safe/statement_timeout.sql` | `SET LOCAL statement_timeout = '10s';` | none | command and race |
| `operations/enroll/safe/lock.sql` | The section lock | section ID | command and race |
| `operations/enroll/safe/count.sql` | The count after the lock | section ID | command and race |
| `operations/enroll/safe/insert.sql` | The insert | student ID, term, instructor ID, date | command and race |
| `operations/enroll/safe/commit.sql` | `COMMIT;` | none | race |
| `operations/enroll/safe/rollback.sql` | `ROLLBACK;` | none | race |
| `operations/payment/unsafe/insert.sql` | The insert without a transaction | student ID, term, number, amount, date, receipt code | never |
| `operations/payment/safe/insert.sql` | The insert inside a transaction | student ID, term, number, amount, date, receipt code | command |

The race driver reads the enrollment files and the four files under `variants/race/`. It runs the two sessions in a fixed order, so the wrong result is repeatable. It sets `lock_timeout`, `statement_timeout`, and `connect_timeout`, so a lock wait can't hold the driver indefinitely.

You'll use your Lab 2 roster view to fill `variants/race/count.sql`, which takes one section ID and returns capacity followed by the enrollment count.
