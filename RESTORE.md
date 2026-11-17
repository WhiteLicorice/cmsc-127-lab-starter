# Dump and Restore

Run these commands from your repository root in Git Bash on Windows. Add the PostgreSQL 18 `bin` directory to `PATH`. Set `DB` to the name of your database. Set `PGPASSWORD` in the shell, and do not save the password in the repository. Change the host, port, and user in `CONN` to match your cluster.

Write an `answers/rows.sql` file with this query. It counts the rows in every table in `public`, so it works whatever your table names are.

```sql
SELECT table_name,
       (xpath('/row/count/text()',
              query_to_xml(format('SELECT count(*) AS count FROM %I.%I',
                                  table_schema, table_name),
                           false, true, '')))[1]::text::bigint AS rows
  FROM information_schema.tables
 WHERE table_schema = 'public'
   AND table_type = 'BASE TABLE'
 ORDER BY table_name;
```

Then run this sequence. It saves the counts, dumps the database, drops it, creates an empty database with the same name, restores the dump, and saves the counts again.

```bash
set -euo pipefail
export PATH="/c/Program Files/PostgreSQL/18/bin:$PATH"
export PGPASSWORD='your-password'
DB=your_database
TMP="$(mktemp -d)"
CONN=(-h 127.0.0.1 -p 5432 -U postgres -w)

psql -X -v ON_ERROR_STOP=1 "${CONN[@]}" -d "$DB" -A -t -F '|' -f answers/rows.sql > "$TMP/before.txt"
pg_dump "${CONN[@]}" --no-owner -f "$TMP/lab3.dump.sql" "$DB"
dropdb "${CONN[@]}" --if-exists --force "$DB"
createdb "${CONN[@]}" "$DB"
psql -X -v ON_ERROR_STOP=1 "${CONN[@]}" -d "$DB" -f "$TMP/lab3.dump.sql"
psql -X -v ON_ERROR_STOP=1 "${CONN[@]}" -d "$DB" -A -t -F '|' -f answers/rows.sql > "$TMP/after.txt"
cmp "$TMP/before.txt" "$TMP/after.txt"
```

The database must hold the Lab 1 data, the Lab 2 migrations, and the Lab 3 migrations before the first comparison. The `cmp` command prints nothing and exits 0 when the two files match. A difference shows the table whose row count changed.

`pg_dump` saves the database and its grant statements. It does not save cluster role definitions or memberships, tablespace definitions, or cluster settings. This command also omits database-level settings because it does not use `--create`. PostgreSQL 18 documents these limits in [`pg_dump`](https://www.postgresql.org/docs/18/app-pgdump.html) and its [backup guide](https://www.postgresql.org/docs/18/backup-dump.html). The `--create` option includes database-level settings. Cluster settings live in files such as `postgresql.conf` and `postgresql.auto.conf`, which `pg_dump` does not copy. See [PostgreSQL configuration settings](https://www.postgresql.org/docs/18/config-setting.html).

Roles belong to the cluster. This route keeps them when it drops and recreates the database. On a new cluster, run the migration that creates the group roles before the restore. Do not run the grants migration yet, because its tables do not exist. The dump's grant statements can then use those roles. The checks create temporary probe roles. Those roles are not application roles. They do not belong in the dump.

The dump file and comparison files belong in the temporary directory. Keep them out of Git. The dump holds every row, and a public repository is the wrong place for that data.
