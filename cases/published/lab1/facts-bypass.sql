-- Find an unmapped foreign key that repeats a value reached through another
-- declared foreign-key path in the same table, or that folds a fact into its
-- own key. A near copy that agrees on most rows prints a row that starts
-- `warning: <table>.<column>` instead of failing; the runner prints that row
-- and counts it apart from failures.
WITH RECURSIVE foreign_key_edges AS (
    SELECT constraint_entry.oid AS constraint_oid,
           constraint_entry.conrelid AS child_oid,
           constraint_entry.confrelid AS parent_oid,
           constraint_entry.conkey,
           constraint_entry.confkey,
           child_namespace.nspname::text AS child_schema,
           child_table.relname::text AS child_table,
           parent_namespace.nspname::text AS parent_schema,
           parent_table.relname::text AS parent_table
    FROM pg_constraint AS constraint_entry
    JOIN pg_class AS child_table
      ON child_table.oid = constraint_entry.conrelid
    JOIN pg_namespace AS child_namespace
      ON child_namespace.oid = child_table.relnamespace
    JOIN pg_class AS parent_table
      ON parent_table.oid = constraint_entry.confrelid
    JOIN pg_namespace AS parent_namespace
      ON parent_namespace.oid = parent_table.relnamespace
    WHERE constraint_entry.contype = 'f'
      AND constraint_entry.convalidated
      AND child_namespace.nspname = 'public'
      AND parent_namespace.nspname = 'public'
),
unmapped_foreign_key_columns AS (
    SELECT foreign_key_edges.constraint_oid AS target_constraint_oid,
           foreign_key_edges.child_oid AS source_oid,
           foreign_key_edges.child_table AS source_table,
           source_attribute.attname::text AS source_column,
           source_attribute.attnum AS source_attnum,
           foreign_key_edges.parent_oid AS target_parent_oid,
           parent_attribute.attname::text AS target_parent_column
    FROM foreign_key_edges
    CROSS JOIN LATERAL unnest(
        foreign_key_edges.conkey,
        foreign_key_edges.confkey
    ) WITH ORDINALITY AS key_pair(source_attnum, parent_attnum, ordinality)
    JOIN pg_attribute AS source_attribute
      ON source_attribute.attrelid = foreign_key_edges.child_oid
     AND source_attribute.attnum = key_pair.source_attnum
     AND NOT source_attribute.attisdropped
    JOIN pg_attribute AS parent_attribute
      ON parent_attribute.attrelid = foreign_key_edges.parent_oid
     AND parent_attribute.attnum = key_pair.parent_attnum
     AND NOT parent_attribute.attisdropped
    WHERE NOT EXISTS (
        SELECT 1
        FROM column_mapping AS mapping
        WHERE mapping.table_name = foreign_key_edges.child_table
          AND mapping.column_name = source_attribute.attname
          AND mapping.fact <> 'default_column'
    )
),
folded_key_columns AS (
    SELECT constraint_entry.conname::text AS constraint_name,
           child_table.relname::text AS table_name,
           child_attribute.attname::text AS column_name,
           parent_table.relname::text AS parent_table,
           parent_key.key_names
    FROM pg_constraint AS constraint_entry
    JOIN pg_class AS child_table
      ON child_table.oid = constraint_entry.conrelid
    JOIN pg_namespace AS child_namespace
      ON child_namespace.oid = child_table.relnamespace
    JOIN pg_class AS parent_table
      ON parent_table.oid = constraint_entry.confrelid
    JOIN pg_namespace AS parent_namespace
      ON parent_namespace.oid = parent_table.relnamespace
    CROSS JOIN LATERAL (
        SELECT array_agg(key_attribute.attname::text
                         ORDER BY key_column.ordinality) AS key_names,
               array_agg(key_column.attnum
                         ORDER BY key_column.ordinality) AS key_attnums
        FROM pg_index AS index_entry
        CROSS JOIN LATERAL unnest(index_entry.indkey)
            WITH ORDINALITY AS key_column(attnum, ordinality)
        JOIN pg_attribute AS key_attribute
          ON key_attribute.attrelid = index_entry.indrelid
         AND key_attribute.attnum = key_column.attnum
        WHERE index_entry.indrelid = constraint_entry.confrelid
          AND index_entry.indisunique
          AND index_entry.indisvalid
          AND index_entry.indpred IS NULL
          AND index_entry.indexprs IS NULL
          AND key_column.ordinality <= index_entry.indnkeyatts
        GROUP BY index_entry.indexrelid
    ) AS parent_key
    CROSS JOIN LATERAL unnest(constraint_entry.conkey, constraint_entry.confkey)
        WITH ORDINALITY AS key_pair(child_attnum, parent_attnum, ordinality)
    JOIN pg_attribute AS child_attribute
      ON child_attribute.attrelid = constraint_entry.conrelid
     AND child_attribute.attnum = key_pair.child_attnum
     AND NOT child_attribute.attisdropped
    WHERE constraint_entry.contype = 'f'
      AND constraint_entry.convalidated
      AND child_namespace.nspname = 'public'
      AND parent_namespace.nspname = 'public'
      AND parent_key.key_attnums <@ constraint_entry.confkey
      AND cardinality(parent_key.key_attnums)
          < cardinality(constraint_entry.confkey)
      AND NOT (key_pair.parent_attnum = ANY (parent_key.key_attnums))
      AND NOT EXISTS (
          SELECT 1
          FROM column_mapping AS mapping
          WHERE mapping.table_name = child_table.relname
            AND mapping.column_name = child_attribute.attname
            AND mapping.fact <> 'default_column'
      )
),
foreign_key_paths (
    target_constraint_oid,
    source_oid,
    source_table,
    source_column,
    target_parent_oid,
    target_parent_column,
    constraint_oids,
    relation_oids,
    current_oid,
    depth
) AS (
    SELECT unmapped_foreign_key_columns.target_constraint_oid,
           unmapped_foreign_key_columns.source_oid,
           unmapped_foreign_key_columns.source_table,
           unmapped_foreign_key_columns.source_column,
           unmapped_foreign_key_columns.target_parent_oid,
           unmapped_foreign_key_columns.target_parent_column,
           ARRAY[route.constraint_oid],
           ARRAY[route.child_oid, route.parent_oid],
           route.parent_oid,
           1
    FROM unmapped_foreign_key_columns
    JOIN foreign_key_edges AS route
      ON route.child_oid = unmapped_foreign_key_columns.source_oid
     AND route.constraint_oid
         <> unmapped_foreign_key_columns.target_constraint_oid
     AND NOT (unmapped_foreign_key_columns.source_attnum = ANY (route.conkey))
    UNION ALL
    SELECT foreign_key_paths.target_constraint_oid,
           foreign_key_paths.source_oid,
           foreign_key_paths.source_table,
           foreign_key_paths.source_column,
           foreign_key_paths.target_parent_oid,
           foreign_key_paths.target_parent_column,
           foreign_key_paths.constraint_oids || next_edge.constraint_oid,
           foreign_key_paths.relation_oids || next_edge.parent_oid,
           next_edge.parent_oid,
           foreign_key_paths.depth + 1
    FROM foreign_key_paths
    JOIN foreign_key_edges AS next_edge
      ON next_edge.child_oid = foreign_key_paths.current_oid
    WHERE foreign_key_paths.depth < 3
      AND next_edge.constraint_oid <> ALL (foreign_key_paths.constraint_oids)
      AND next_edge.parent_oid <> ALL (foreign_key_paths.relation_oids)
),
candidate_paths AS (
    SELECT foreign_key_paths.*
    FROM foreign_key_paths
    WHERE foreign_key_paths.current_oid = foreign_key_paths.target_parent_oid
),
path_step_parts AS (
    SELECT candidate_paths.target_constraint_oid,
           candidate_paths.source_oid,
           candidate_paths.source_table,
           candidate_paths.source_column,
           candidate_paths.target_parent_oid,
           candidate_paths.target_parent_column,
           candidate_paths.constraint_oids,
           candidate_paths.depth,
           path_step.ordinality AS step,
           foreign_key_edges.parent_schema,
           foreign_key_edges.parent_table,
           key_pair.ordinality AS key_ordinality,
           format(
               't%s.%I = t%s.%I',
               path_step.ordinality - 1,
               source_attribute.attname,
               path_step.ordinality,
               parent_attribute.attname
           ) AS join_part,
           format(
               '%s.%s -> %s.%s',
               foreign_key_edges.child_table,
               source_attribute.attname,
               foreign_key_edges.parent_table,
               parent_attribute.attname
           ) AS path_part
    FROM candidate_paths
    CROSS JOIN LATERAL unnest(candidate_paths.constraint_oids)
        WITH ORDINALITY AS path_step(constraint_oid, ordinality)
    JOIN foreign_key_edges
      ON foreign_key_edges.constraint_oid = path_step.constraint_oid
    CROSS JOIN LATERAL unnest(
        foreign_key_edges.conkey,
        foreign_key_edges.confkey
    ) WITH ORDINALITY AS key_pair(source_attnum, parent_attnum, ordinality)
    JOIN pg_attribute AS source_attribute
      ON source_attribute.attrelid = foreign_key_edges.child_oid
     AND source_attribute.attnum = key_pair.source_attnum
     AND NOT source_attribute.attisdropped
    JOIN pg_attribute AS parent_attribute
      ON parent_attribute.attrelid = foreign_key_edges.parent_oid
     AND parent_attribute.attnum = key_pair.parent_attnum
     AND NOT parent_attribute.attisdropped
),
path_steps AS (
    SELECT path_step_parts.target_constraint_oid,
           path_step_parts.source_oid,
           path_step_parts.source_table,
           path_step_parts.source_column,
           path_step_parts.target_parent_oid,
           path_step_parts.target_parent_column,
           path_step_parts.constraint_oids,
           path_step_parts.depth,
           path_step_parts.step,
           path_step_parts.parent_schema,
           path_step_parts.parent_table,
           string_agg(path_step_parts.join_part, ' AND '
                      ORDER BY path_step_parts.key_ordinality) AS join_condition,
           string_agg(path_step_parts.path_part, ' and '
                      ORDER BY path_step_parts.key_ordinality) AS path_segment
    FROM path_step_parts
    GROUP BY path_step_parts.target_constraint_oid,
             path_step_parts.source_oid,
             path_step_parts.source_table,
             path_step_parts.source_column,
             path_step_parts.target_parent_oid,
             path_step_parts.target_parent_column,
             path_step_parts.constraint_oids,
             path_step_parts.depth,
             path_step_parts.step,
             path_step_parts.parent_schema,
             path_step_parts.parent_table
),
path_queries AS (
    SELECT path_steps.target_constraint_oid,
           path_steps.source_oid,
           path_steps.source_table,
           path_steps.source_column,
           path_steps.target_parent_oid,
           path_steps.target_parent_column,
           path_steps.constraint_oids,
           path_steps.depth,
           string_agg(
               format(
                   'LEFT JOIN %I.%I AS t%s ON %s',
                   path_steps.parent_schema,
                   path_steps.parent_table,
                   path_steps.step,
                   path_steps.join_condition
               ),
               ' ' ORDER BY path_steps.step
           ) AS joins_sql,
           string_agg(path_steps.path_segment, ' then '
                      ORDER BY path_steps.step) AS path_text
    FROM path_steps
    GROUP BY path_steps.target_constraint_oid,
             path_steps.source_oid,
             path_steps.source_table,
             path_steps.source_column,
             path_steps.target_parent_oid,
             path_steps.target_parent_column,
             path_steps.constraint_oids,
             path_steps.depth
),
path_results AS MATERIALIZED (
    SELECT path_queries.*,
           query_to_xml(
               format(
                   'SELECT count(*) FILTER (WHERE source_value IS NOT NULL) AS source_rows, '
                   'count(*) FILTER (WHERE source_value IS NOT NULL AND reached IS NOT NULL) AS reached_rows, '
                   'count(*) FILTER (WHERE source_value IS NOT NULL AND reached IS NOT NULL AND source_value IS DISTINCT FROM reached_value) AS mismatch_rows, '
                   'count(*) FILTER (WHERE source_value IS NOT NULL AND repeat_count > 1) AS repeated_rows '
                   'FROM ('
                   'SELECT to_jsonb(t0.%I) AS source_value, '
                   't%s.tableoid AS reached, '
                   'to_jsonb(t%s.%I) AS reached_value, '
                   'count(*) OVER (PARTITION BY to_jsonb(t0.%I)) AS repeat_count '
                   'FROM public.%I AS t0 %s'
                   ') AS pairs',
                   path_queries.source_column,
                   path_queries.depth,
                   path_queries.depth,
                   path_queries.target_parent_column,
                   path_queries.source_column,
                   path_queries.source_table,
                   path_queries.joins_sql
               ),
               false,
               true,
               ''
           ) AS result
    FROM path_queries
),
path_agreement AS (
    SELECT path_results.*,
           (xpath('/row/source_rows/text()',
                  path_results.result))[1]::text::bigint AS source_rows,
           (xpath('/row/reached_rows/text()',
                  path_results.result))[1]::text::bigint AS reached_rows,
           (xpath('/row/mismatch_rows/text()',
                  path_results.result))[1]::text::bigint AS mismatch_rows,
           (xpath('/row/repeated_rows/text()',
                  path_results.result))[1]::text::bigint AS repeated_rows
    FROM path_results
),
column_failures AS (
    SELECT DISTINCT path_agreement.source_table,
                    path_agreement.source_column
    FROM path_agreement
    WHERE path_agreement.source_rows > 0
      AND path_agreement.source_rows = path_agreement.reached_rows
      AND path_agreement.mismatch_rows = 0
      AND path_agreement.repeated_rows > 0
),
warning_paths AS (
    SELECT DISTINCT ON (path_agreement.source_table, path_agreement.source_column)
           path_agreement.*,
           path_agreement.reached_rows - path_agreement.mismatch_rows AS agree_rows
    FROM path_agreement
    WHERE path_agreement.source_rows > 0
      AND path_agreement.repeated_rows > 0
      AND NOT (
          path_agreement.source_rows = path_agreement.reached_rows
          AND path_agreement.mismatch_rows = 0
      )
      AND (path_agreement.reached_rows - path_agreement.mismatch_rows) * 2
          >= path_agreement.source_rows
      AND NOT EXISTS (
          SELECT 1
          FROM column_failures
          WHERE column_failures.source_table = path_agreement.source_table
            AND column_failures.source_column = path_agreement.source_column
      )
      AND NOT EXISTS (
          SELECT 1
          FROM folded_key_columns
          WHERE folded_key_columns.table_name = path_agreement.source_table
            AND folded_key_columns.column_name = path_agreement.source_column
      )
    ORDER BY path_agreement.source_table,
             path_agreement.source_column,
             path_agreement.reached_rows - path_agreement.mismatch_rows DESC,
             path_agreement.depth,
             path_agreement.path_text
)
SELECT row
FROM (
    SELECT DISTINCT format(
               '%s.%s matches the value reached by foreign-key path %s on every non-NULL row, so the same fact is stored through two foreign keys.',
               path_agreement.source_table,
               path_agreement.source_column,
               path_agreement.path_text
           ) AS row,
           0 AS kind
    FROM path_agreement
    WHERE path_agreement.source_rows > 0
      AND path_agreement.source_rows = path_agreement.reached_rows
      AND path_agreement.mismatch_rows = 0
      AND path_agreement.repeated_rows > 0
    UNION ALL
    SELECT format(
               '%s.%s copies a fact that the parent key %s(%s) already decides, because the foreign key %s references that key inside its parent columns.',
               folded_key_columns.table_name,
               folded_key_columns.column_name,
               folded_key_columns.parent_table,
               array_to_string(folded_key_columns.key_names, ', '),
               folded_key_columns.constraint_name
           ) AS row,
           0 AS kind
    FROM folded_key_columns
    UNION ALL
    SELECT format(
               'warning: %s.%s agrees with the value reached by foreign-key path %s on %s of %s rows that have a value. '
               'If the two are the same fact, an update to one leaves the other wrong, and the rows that differ may already show that problem. '
               'To check, run: SELECT t0.* FROM public.%I AS t0 %s WHERE t0.%I IS DISTINCT FROM t%s.%I; '
               'If the column is the same fact, remove it and read the value through the key. '
               'If it is a different fact that often agrees, keep it, map it to its own export fact if the template lists one, and explain the column under Checker Warnings in DESIGN.md.',
               warning_paths.source_table,
               warning_paths.source_column,
               warning_paths.path_text,
               warning_paths.agree_rows,
               warning_paths.source_rows,
               warning_paths.source_table,
               warning_paths.joins_sql,
               warning_paths.source_column,
               warning_paths.depth,
               warning_paths.target_parent_column
           ) AS row,
           1 AS kind
    FROM warning_paths
) AS rows
ORDER BY kind, row;
