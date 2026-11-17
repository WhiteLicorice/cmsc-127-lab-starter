# CMSC 127 Lab Starter

This folder holds your pair's database work. A pair is two students who work
together.

## Quick Start

The steps below run the Lab 1 checks. They use Git Bash, the shell that comes
with Git for Windows, and they run in this folder.

### Before You Start

Each line gives one requirement, why the checks need it, and how to check it.
Skip a line when the check passes. A failed check states its repair on the same
line.

- Git, which fetches the pinned runner on the first run. Check it with
  `git --version`. If the command is missing, install Git from
  <https://git-scm.com/downloads>.
- PostgreSQL 18, the database server that holds your tables. The runner creates
  a scratch database on it. Check it with `pg_isready`. The reply is
  `accepting connections`. If the command is missing, add the PostgreSQL `bin`
  folder to `PATH`.
- Python 3.15 or newer, which runs the runner and your code. Check it with
  `python --version`. The reply starts with `Python 3.15` or a later version.
  If the reply is lower, install Python 3.15 from
  <https://www.python.org/downloads/>. On Windows, `py -3.15 --version` selects
  an installed 3.15, and step 1 uses `py -3.15` to create the environment.
  After step 2 activates it, `python` means the environment's interpreter. If
  `python` still reports the system version, the environment is not active.
  Rerun the activation command from step 2.
- Pyright 1.1.414, which type-checks your Python. It installs with the Python
  packages from `requirements.txt`. Check it with `pyright --version`. The reply
  starts with `pyright 1.1.414`. If the check fails, activate the environment and
  run `python -m pip install -r requirements.txt` again.

In PowerShell, replace the activation command with
`.\.venv\Scripts\Activate.ps1` and the `export` command with
`$env:CMSC127_DATABASE_URL = '...'`. An activated environment provides
`python` in PowerShell too. Run `bash check.sh` from Git Bash, since
PowerShell may find a different `bash`.

### Steps

1. Create the Python environment. Run `python -m venv .venv`. On Windows, run
   `py -3.15 -m venv .venv`. Skip this step when the folder already holds
   `.venv`.
2. Activate it. Run `source .venv/Scripts/activate`. On macOS and Linux, run
   `source .venv/bin/activate`.
3. Install the Python packages into the environment. Run
   `python -m pip install -r requirements.txt`. The file holds the PostgreSQL
   driver.
4. Set the database URL. Run
   `export CMSC127_DATABASE_URL='postgresql://your_user:your_password@127.0.0.1:5432/your_database'`.
   Replace `your_user`, `your_password`, and `your_database` with your
   PostgreSQL role, its password, and your database. The password is the one
   you set for the role when you installed PostgreSQL.
5. Run the checks. Run `bash check.sh 1`. The count line prints when the run
   ends. The first run fails until you add your schema and data.

## The Details

A schema is the set of tables and their columns. Add your schema to
`migrations/`. A migration is a SQL file that creates or changes tables. The
data loader is the SQL file that fills the tables with rows. Add your data to
`load.sql`.

Edit only `README.md`, `DESIGN.md`, `.stage`, `load.sql`, and the folders
`migrations/`, `cases/pair/`, `reports/`, `answers/`, `operations/`, `race/`,
and `variants/`. The runner compares every other file that came with this
folder with its original.

### Set Up on Windows

PostgreSQL is the database server that holds your tables. Install Git, Python
3.15 or newer, and PostgreSQL. Start the PostgreSQL server before you run the
checks.

Open Git Bash, the Git shell for Windows. A Python environment is a private
folder that holds Python packages. Create the environment and install the Python
packages, including Pyright:

```bash
py -3.15 -m venv .venv
source .venv/Scripts/activate
python -m pip install -r requirements.txt
```

Pyright is a type checker for Python. The runner reports its result.

A role is a PostgreSQL user account. Set `CMSC127_DATABASE_URL` in your shell,
the window where you type commands. Use a local role that can create and drop
databases. The runner creates a separate database for each run, so your working
data stays unchanged.

```bash
export CMSC127_DATABASE_URL='postgresql://your_user:your_password@127.0.0.1:5432/your_database'
```

Add a password to the URL only in your local shell when your server needs one.
Do not save a password in this folder.

### Set Up on macOS and Linux

Use the same steps with the macOS and Linux activation path:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
export CMSC127_DATABASE_URL='postgresql://your_user:your_password@127.0.0.1:5432/your_database'
```

### Run the Checks

A stage is one group of checks, one for each lab. The runner is the program
that runs them. Run stage 1 with `bash check.sh 1`. Run stage 2 with
`bash check.sh 2`. Stage 2 includes stage 1, so a failure in Lab 1 still fails
during Lab 2. GitHub Actions reads `.stage` at the repository root and runs the
checks through that stage. The workflow prints the stage. The starter ships
`.stage` at `1`. Change it to `2` when you start Lab 2 and `3` when you start
Lab 3, and commit the change.

The first run downloads the runner at a fixed version. Later runs use the
local copy and need no network.

A case is one check with one expected result. The runner prints one line for
each case and each invariant check. An invariant is a rule that must hold for
every correct database. A failed check exits with a nonzero status. The runner
ends with a count line.

#### Run One Case

`bash check.sh --case lab1/health` runs one case. Use it while you debug one
query. The command still creates a scratch database, a temporary database for
one run, and applies your migrations. It exits 0 when the case passes, 1 when
it fails, and 2 for a form fault or a usage error.

#### Check the Form Without a Database

`./lint` checks the form of your files. The form covers a file's name, its
headings, and the fields the checks read. The command reads the case
manifests, `.stage`, the protected files, the `DESIGN.md` headings, the
migration names, and the files each stage requires. It needs no database and
prints no expected answer.

`./lint` exits 0 when the form is clean and 1 when it finds a fault. Each fault
gives the file, the line where one exists, and the change to make. `bash
check.sh` runs the same checks first and prints them under a `== form ==`
heading. Read that heading first when it appears. A fault under that heading is
a typing mistake.

#### Test the Runner

`bash check.sh --self-test` tests the runner itself. It uses a separate scratch
database and does not check your schema. The result stays in
`.cmsc127/last-run.json`.

### Migrations and Data

Put schema changes in `migrations/`. Use the filename form
`NNNN_lowercase_description.sql`, such as `0001_create_observer.sql`. Start at
`0001` and do not skip a number. The runner applies the files in filename order
to a new database. A missing number stops the run. The runner cannot tell
whether the missing file changes the schema.

Put the data loader in `load.sql`. The runner calls `./run prepare` after it
applies the migrations. The command runs this SQL file without changing your
source files.

`./run` is the command script in this folder. The runner calls `./run prepare`,
`./run backup`, `./run restore`, or `./run path/to/query.sql`. A report name runs
`reports/<name>.sql`, so `./run room_assignments` runs
`reports/room_assignments.sql`. The connection helper runs one SQL file and
prints its columns and rows as JSON.

### Lab 3 Operations

Set `CMSC127_REGISTRAR_DATABASE_URL` for enrollment. Set
`CMSC127_CASHIER_DATABASE_URL` for payments. Each login role must belong to the
matching `registrar` or `cashier` group role.

Run `./run enroll STUDENT_ID SECTION_ID YYYY-MM-DD` to enroll a student. Run
`./run payment STUDENT_ID TERM NUMBER AMOUNT YYYY-MM-DD RECEIPT_CODE` to record
a payment. Both commands use parameterized SQL and a transaction.

Run `./run race` to compare the unsafe and safe enrollment schedules.

Set `CMSC127_BACKUP_FILE` to a file path. Run `./run dump` to save a custom
format database dump. Run `./run restore` to restore it. A dump holds database
objects, rows, and grant statements. It does not hold role definitions,
memberships, tablespace definitions, or cluster settings. Without `--create`,
it also does not hold database-level settings.

Write the two No-SQL responses in `answers/nosql.md` under its headings. The
check confirms that both sections contain text. It does not grade the answers.

### Cases and Results

The runner reads `cases/manifest.json`, each
`cases/published/<lab>/manifest.json`, and `cases/pair/manifest.json`. Each
manifest lists its cases, stages, groups, and kinds. Each case needs an
`.expected` JSON file. An optional `.exit` file holds its expected exit status.
Every case file must appear in a manifest.

Add your own cases in `cases/pair/manifest.json`. Use the same fields, and keep
the files inside `cases/pair/`. The starter holds each lab's published files
under `cases/published/<lab>/`. Keep those files unchanged. Your pair manifest
stays yours.

A minimal pair manifest:

```json
{
  "version": 1,
  "cases": [
    {
      "id": "pair/observers",
      "stage": 1,
      "group": "Query Correctness",
      "kind": "query",
      "file": "cases/pair/observers.sql"
    }
  ]
}
```

The case file holds one SQL statement or one command. The expected file holds a
`columns` list and a `rows` list:

```json
{"columns": ["observer_id", "observer_name"], "rows": [[1, "Ada"], [2, null]]}
```

The runner compares the result with that object. Use JSON `null` for SQL
`NULL`. Numbers compare by value, so `1`, `1.0`, and `1.00` match. Column names
and their order must match. Row order must match unless the manifest sets
`ordered` to `false`. Set `ordered` to `false` when the result has no required
row order. The runner compares duplicate rows too.

The nine case kinds are `output`, `schema`, `reject`, `state`, `race`, `query`,
`document`, `report`, and `view`. `output` compares the JSON from `./run`.
`schema` compares the ERD with the live schema. `reject` requires SQL to fail.
`state` checks the rows after an operation. `race` runs ordered steps on two
sessions, each one an open connection to the database. `query` runs a SQL file
directly. `document` checks the structure of a Markdown file. `report` runs a
report SQL file named in a JSON body. `view` reads the catalog to prove that a
report reads a required view.

A skipped check prints `SKIP` with a reason. A skip does not count as a pass. A
form fault stops the run before it creates a database. It reports the file,
line, and column. It exits with status 2. The form check covers the manifest
and each expected result. It also covers each state or race body and each
invariant's required fields.

The result file `.cmsc127/last-run.json` holds every case result, with its
status, expected value, actual value, and differences. The expected file holds
one result.

### Invariant Checks

After the cases, the runner checks each invariant. The checks are:

- **Normal form.** A rule says that one column determines another, such as a
  supplier determining its city. The runner reads the catalog, PostgreSQL's own
  description of the tables, and confirms that a key enforces each rule.
- **Work in SQL.** Each report must run as SQL.
- **Required features.** A view, a saved query that acts like a table, must
  contain a named SQL feature.
- **Index.** A migration must create the required index, a lookup structure
  that speeds up a query.
- **Backup and restore.** A backup must restore the same rows.
- **Protected files.** Every file outside the writable paths matches its
  original. A new tracked file, or a new untracked file that Git does not
  ignore, fails when it sits outside those paths. An ignored generated file,
  such as `.venv/` or `.cmsc127/last-run.json`, does not.
- **Written sections.** Each required section must hold text.
- **Type checking.** Your Python must pass strict Pyright.
- **Contribution.** The runner prints a table of commits and changed lines by
  member and week.

The runner prints each result, a count for each group, and one final count:

```text
PASS lab1/health
FAIL lab2/health
  row 1 differs: expected [3], actual [4]
SKIP lab3/race-driver: this platform cannot run two sessions
== result ==
1/3 checks passed, 1 failed, 1 skipped, 0 warnings; Pyright: 0 errors
```

A `PASS` line means the result matched. A `FAIL` line shows the difference and
the expected and actual values. A `SKIP` line gives a reason and does not enter
the count. The `Pyright` part of the count line reports the type-check result.

### Write the ERD

An entity-relationship diagram (ERD) shows tables and their relationships. Edit
the ERD block in this README to match your schema. The runner compares table
names, column names, primary keys, foreign keys, and the tables at each end of
a relationship. A primary key identifies a row. A foreign key points to a row
in another table.

```mermaid
erDiagram
    observer ||--o{ session : fk_session_observer_id
    session ||--o{ sighting : fk_sighting_session_id
    target ||--o{ sighting : fk_sighting_target_id

    observer {
        int observer_id PK
        string observer_name
    }
    session {
        int session_id PK
        int observer_id FK
        date observed_on
    }
    target {
        int target_id PK
        string target_name
    }
    sighting {
        int session_id PK, FK
        int target_id PK, FK
    }
```
