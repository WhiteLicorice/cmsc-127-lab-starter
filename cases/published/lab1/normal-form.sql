-- Each dependent must sit in a relation that also holds its determinant
-- columns, and that relation must have a unique key on exactly them. Every
-- column of every table must be mapped as a fact, a key, or a foreign key. The
-- facts check requires one mapped column for each export fact.
WITH rules (rule_id, determinant, dependents) AS (
    VALUES
        ('NF1', ARRAY['nf_student_id'], ARRAY['nf_student_name', 'nf_student_program', 'nf_student_year_level']),
        ('NF2', ARRAY['nf_section_term', 'nf_section_instructor'], ARRAY['nf_section_course']),
        ('NF3', ARRAY['source_instructor_id'], ARRAY['source_instructor_name']),
        ('NF4', ARRAY['source_course_id'], ARRAY['source_course_title', 'source_units'])
),
dependencies AS (
    SELECT rules.rule_id || ':' || dependent.fact AS dependency_id,
           rules.determinant,
           dependent.fact AS dependent
    FROM rules
    CROSS JOIN LATERAL unnest(rules.dependents) AS dependent(fact)
),
facts AS (
    SELECT dependency_id, 'determinant' AS side, unnest(determinant) AS fact
    FROM dependencies
    UNION ALL
    SELECT dependency_id, 'dependent', dependent FROM dependencies
),
resolved AS (
    SELECT facts.dependency_id, facts.side, facts.fact,
           mapping.table_name, mapping.column_name,
           class_entry.oid AS relation_oid,
           attribute.attnum
    FROM facts
    LEFT JOIN column_mapping AS mapping ON mapping.fact = facts.fact
    LEFT JOIN pg_namespace AS namespace_entry ON namespace_entry.nspname = 'public'
    LEFT JOIN pg_class AS class_entry
      ON class_entry.relnamespace = namespace_entry.oid
     AND class_entry.relname = mapping.table_name
     AND class_entry.relkind IN ('r', 'p')
    LEFT JOIN pg_attribute AS attribute
      ON attribute.attrelid = class_entry.oid
     AND attribute.attname = mapping.column_name
     AND attribute.attnum > 0
     AND NOT attribute.attisdropped
),
fact_plan AS (
    SELECT dependency_id, side, fact,
           count(*) AS copies,
           count(*) FILTER (
               WHERE relation_oid IS NOT NULL
                 AND attnum IS NOT NULL
           ) AS resolved_copies
    FROM resolved
    GROUP BY dependency_id, side, fact
),
dependency_facts AS (
    SELECT dependency_id,
           count(*) FILTER (
               WHERE copies = 0 OR resolved_copies <> copies
           ) AS invalid_count
    FROM fact_plan
    GROUP BY dependency_id
),
dependent_relations AS (
    SELECT DISTINCT dependency_id, relation_oid
    FROM resolved
    WHERE side = 'dependent'
      AND relation_oid IS NOT NULL
      AND attnum IS NOT NULL
),
determinants AS (
    SELECT dependency_id,
           array_agg(DISTINCT column_name::text ORDER BY column_name::text) AS columns
    FROM resolved
    WHERE side = 'determinant'
      AND relation_oid IS NOT NULL
      AND attnum IS NOT NULL
    GROUP BY dependency_id
),
determinant_presence AS (
    SELECT dependent_relations.dependency_id,
           dependent_relations.relation_oid,
           count(attribute.attnum) AS present_count
    FROM dependent_relations
    JOIN determinants ON determinants.dependency_id = dependent_relations.dependency_id
    CROSS JOIN LATERAL unnest(determinants.columns) AS determinant_column(name)
    LEFT JOIN pg_attribute AS attribute
      ON attribute.attrelid = dependent_relations.relation_oid
     AND attribute.attname = determinant_column.name
     AND attribute.attnum > 0
     AND NOT attribute.attisdropped
    GROUP BY dependent_relations.dependency_id, dependent_relations.relation_oid
),
unique_keys AS (
    SELECT index_entry.indrelid AS relation_oid,
           array_agg(attribute.attname::text ORDER BY attribute.attname) AS columns
    FROM pg_index AS index_entry
    JOIN pg_class AS class_entry ON class_entry.oid = index_entry.indrelid
    JOIN pg_namespace AS namespace_entry ON namespace_entry.oid = class_entry.relnamespace
    JOIN LATERAL unnest(index_entry.indkey) WITH ORDINALITY AS key_column(attnum, ordinality)
      ON key_column.ordinality <= index_entry.indnkeyatts
    JOIN pg_attribute AS attribute
      ON attribute.attrelid = class_entry.oid
     AND attribute.attnum = key_column.attnum
    WHERE namespace_entry.nspname = 'public'
      AND index_entry.indisunique
      AND index_entry.indisvalid
      AND index_entry.indpred IS NULL
      AND index_entry.indexprs IS NULL
    GROUP BY index_entry.indrelid, index_entry.indexrelid
),
dependent_check AS (
    SELECT dependent_relations.dependency_id,
           bool_and(
               determinant_presence.present_count = cardinality(determinants.columns)
               AND EXISTS (
                   SELECT 1
                   FROM unique_keys
                   WHERE unique_keys.relation_oid = dependent_relations.relation_oid
                     AND unique_keys.columns = determinants.columns
               )
           ) AS ok
    FROM dependent_relations
    JOIN determinants ON determinants.dependency_id = dependent_relations.dependency_id
    LEFT JOIN determinant_presence
      ON determinant_presence.dependency_id = dependent_relations.dependency_id
     AND determinant_presence.relation_oid = dependent_relations.relation_oid
    GROUP BY dependent_relations.dependency_id
),
mapped_columns AS (
    SELECT DISTINCT table_name, column_name
    FROM column_mapping
    WHERE table_name IS NOT NULL
      AND column_name IS NOT NULL
),
key_columns AS (
    SELECT DISTINCT class_entry.relname AS table_name,
                    attribute.attname AS column_name
    FROM pg_index AS index_entry
    JOIN pg_class AS class_entry ON class_entry.oid = index_entry.indrelid
    JOIN pg_namespace AS namespace_entry ON namespace_entry.oid = class_entry.relnamespace
    JOIN LATERAL unnest(index_entry.indkey) WITH ORDINALITY AS key_column(attnum, ordinality)
      ON key_column.ordinality <= index_entry.indnkeyatts
    JOIN pg_attribute AS attribute
      ON attribute.attrelid = class_entry.oid
     AND attribute.attnum = key_column.attnum
    WHERE namespace_entry.nspname = 'public'
      AND index_entry.indisunique
      AND index_entry.indisvalid
      AND index_entry.indpred IS NULL
      AND index_entry.indexprs IS NULL
),
foreign_key_columns AS (
    SELECT DISTINCT class_entry.relname AS table_name,
                    attribute.attname AS column_name
    FROM pg_constraint AS constraint_entry
    JOIN pg_class AS class_entry ON class_entry.oid = constraint_entry.conrelid
    JOIN pg_namespace AS namespace_entry ON namespace_entry.oid = class_entry.relnamespace
    CROSS JOIN LATERAL unnest(constraint_entry.conkey) AS key_column(attnum)
    JOIN pg_attribute AS attribute
      ON attribute.attrelid = class_entry.oid
     AND attribute.attnum = key_column.attnum
    WHERE namespace_entry.nspname = 'public'
      AND constraint_entry.contype = 'f'
),
unmapped AS (
    SELECT 'unmapped:'
           || CASE
                  WHEN namespace_entry.nspname = 'public' THEN ''
                  ELSE namespace_entry.nspname || '.'
              END
           || class_entry.relname || '.' || attribute.attname AS dependency_id
    FROM pg_class AS class_entry
    JOIN pg_namespace AS namespace_entry
      ON namespace_entry.oid = class_entry.relnamespace
    JOIN pg_attribute AS attribute
      ON attribute.attrelid = class_entry.oid
     AND attribute.attnum > 0
     AND NOT attribute.attisdropped
    WHERE namespace_entry.nspname NOT IN ('pg_catalog', 'information_schema')
      AND namespace_entry.nspname NOT LIKE 'pg\_%'
      AND class_entry.relkind IN ('r', 'p')
      AND class_entry.relname <> 'column_mapping'
      AND (
          namespace_entry.nspname <> 'public'
          OR (
              NOT EXISTS (
                  SELECT 1
                  FROM mapped_columns
                  WHERE mapped_columns.table_name = class_entry.relname
                    AND mapped_columns.column_name = attribute.attname
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM key_columns
                  WHERE key_columns.table_name = class_entry.relname
                    AND key_columns.column_name = attribute.attname
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM foreign_key_columns
                  WHERE foreign_key_columns.table_name = class_entry.relname
                    AND foreign_key_columns.column_name = attribute.attname
              )
          )
      )
),
problems AS (
    SELECT dependency_facts.dependency_id
    FROM dependency_facts
    LEFT JOIN dependent_check
      ON dependent_check.dependency_id = dependency_facts.dependency_id
    WHERE dependency_facts.invalid_count > 0
       OR dependent_check.dependency_id IS NULL
       OR NOT dependent_check.ok
    UNION ALL
    SELECT unmapped.dependency_id FROM unmapped
)
SELECT DISTINCT dependency_id
FROM problems
ORDER BY dependency_id;
