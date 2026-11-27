# Dump and Restore

Run these commands from your repository root in Git Bash on Windows. Add the PostgreSQL 18 `bin` directory to `PATH`. Set `DB` to your database. Set `PGPASSWORD` in the shell, and don't save the password in the repository. Change the host, port, and user in `CONN` to match your cluster.

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

Then run this sequence. It saves the counts, dumps the database, drops it, creates an empty database with the same name, restores the dump, and saves the counts again. The drop and create step rebuilds the database from empty.

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
diff -u "$TMP/before.txt" "$TMP/after.txt"
```

The database must hold the Lab 1 data, the Lab 2 migrations, and the Lab 3 migrations before the count check. `diff -u` prints nothing and exits 0 when the two lists match. A difference prints the table line whose count changed.

That sequence is one of two restore destinations. `./run restore` is the other. It writes into the database named by `CMSC127_DATABASE_URL` with `pg_restore --clean --single-transaction`. `--clean` drops the objects the archive holds and recreates them. `--single-transaction` runs the whole restore as one transaction, so an error rolls every change back. A common error starts with a child table whose foreign key points at a table in the dump. The child is a newer object that depends on an archived one, so PostgreSQL won't drop the archived table while the child exists. The restore stops. The wrapper prints one line that states the cause. When that happens, use the drop and create route above to restore into an empty database.

The counts prove that each table kept its row count. They don't prove that each row kept its values. For row equality, `bash check.sh 3` runs `lab3/restore-state`: it records every row, dumps, empties the tables, restores, and compares the rows.

`pg_dump` saves the database and its grant statements. It doesn't save cluster role definitions or memberships, tablespace definitions, or cluster settings. This command also omits database-level settings because it doesn't use `--create`. PostgreSQL 18 documents these limits in [`pg_dump`](https://www.postgresql.org/docs/18/app-pgdump.html) and its [backup guide](https://www.postgresql.org/docs/18/backup-dump.html). The `--create` option includes database-level settings. Cluster settings live in files such as `postgresql.conf` and `postgresql.auto.conf`, which `pg_dump` doesn't copy. See [PostgreSQL configuration settings](https://www.postgresql.org/docs/18/config-setting.html).

Roles belong to the cluster. This route keeps them when it drops and recreates the database. On a new cluster, run the migration that creates the group roles before the restore. Don't run the grants migration yet. Its tables don't exist. The dump's grant statements can then use those roles. The checks create temporary probe roles. Those roles aren't application roles. They don't belong in the dump.

The dump file and comparison files belong in the temporary directory. Keep them out of Git. The dump holds every row. A public repository is the wrong place for that data.
