-- Rebuild each export group from its one mapped home per fact.
-- Relations join only through their declared foreign keys.
WITH RECURSIVE export_groups (group_id, expected_rows, expected_digest, facts) AS (
    VALUES
        ('terms', 8::bigint, '81d30a87e80e2ea739dc1113e62610d0', ARRAY['term', 'term_start']),
        ('programs', 4::bigint, 'dacf7b3cc7e57b9f776421ad6a02a0dd', ARRAY['program_name']),
        ('students', 3200::bigint, 'b2c087c876e4f71ccc76707bd96b0fab', ARRAY['student_id', 'student_name', 'student_program', 'student_year_level']),
        ('courses', 36::bigint, '2cb560e76810cae449cafe182087237b', ARRAY['course_id', 'course_code', 'course_title', 'units']),
        ('instructors', 80::bigint, '59395a8deafdf9469d3358c5818961df', ARRAY['instructor_id', 'instructor_name']),
        ('rooms', 80::bigint, '00c354381aab5056d42874dedcb21b2d', ARRAY['room_id', 'room_name']),
        ('sections', 640::bigint, 'efb5389781eaca6f55ad236690871052', ARRAY['section_id', 'section_term', 'section_instructor', 'section_course', 'section_room', 'section_capacity']),
        ('enrollments', 38184::bigint, '2581803472f7d2041fef1a752866b762', ARRAY['enrollment_student', 'enrollment_term', 'enrollment_instructor', 'enrolled_on']),
        ('student_courses', 38184::bigint, 'aa0b04e20c6d14db5191454172888e14', ARRAY['student_course_student', 'student_course_term', 'student_course_course']),
        ('charges', 20136::bigint, '2f2e27feaec94fd9d84e3bb95b4a7652', ARRAY['charge_student', 'charge_term', 'tuition_due']),
        ('payments', 25795::bigint, '489a877146ad69a5065986e7ba5c7e3d', ARRAY['payment_student', 'payment_term', 'payment_seq', 'payment_amount', 'paid_on'])
),
fact_aliases (fact, export_fact) AS (
    VALUES
        ('source_student_id', 'student_id'),
        ('source_student_name', 'student_name'),
        ('source_program', 'student_program'),
        ('source_year_level', 'student_year_level'),
        ('nf_student_id', 'student_id'),
        ('nf_student_name', 'student_name'),
        ('nf_student_program', 'student_program'),
        ('nf_student_year_level', 'student_year_level'),
        ('source_term', 'term'),
        ('source_instructor_id', 'instructor_id'),
        ('source_instructor_name', 'instructor_name'),
        ('source_course_id', 'course_id'),
        ('source_course_title', 'course_title'),
        ('source_units', 'units'),
        ('source_section_id', 'section_id'),
        ('source_section_capacity', 'section_capacity'),
        ('nf_section_term', 'section_term'),
        ('nf_section_instructor', 'section_instructor'),
        ('nf_section_course', 'section_course')
),
known_mapping_facts AS (
    SELECT fact
    FROM export_groups
    CROSS JOIN LATERAL unnest(export_groups.facts) AS export_fact(fact)
    UNION
    SELECT fact FROM fact_aliases
    UNION
    SELECT 'default_column'
    UNION
    SELECT 'payment_receipt_code'
),
fact_rows AS (
    SELECT export_groups.group_id, export_groups.expected_rows,
           export_groups.expected_digest, export_groups.facts,
           fact.fact, fact.ordinality,
           mapping.fact AS mapped_fact,
           mapping.table_name, mapping.column_name,
           class_entry.oid AS relation_oid,
           attribute.attnum
    FROM export_groups
    CROSS JOIN LATERAL unnest(export_groups.facts) WITH ORDINALITY
        AS fact(fact, ordinality)
    LEFT JOIN column_mapping AS mapping ON mapping.fact = fact.fact
    LEFT JOIN pg_namespace AS namespace_entry
      ON namespace_entry.nspname = 'public'
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
    SELECT group_id, expected_rows, expected_digest, facts,
           fact, ordinality,
           count(mapped_fact) AS mapping_count,
           count(*) FILTER (
               WHERE relation_oid IS NOT NULL AND attnum IS NOT NULL
           ) AS resolved_count,
           string_agg(
               format('%s.%s', coalesce(table_name, '<table>'),
                      coalesce(column_name, '<column>')),
               ', ' ORDER BY table_name, column_name
           ) AS targets
    FROM fact_rows
    GROUP BY group_id, expected_rows, expected_digest, facts,
             fact, ordinality
),
group_plan AS (
    SELECT group_id, expected_rows, expected_digest, facts,
           count(*) AS fact_count,
           count(*) FILTER (
               WHERE mapping_count = 1 AND resolved_count = 1
           ) AS valid_count
    FROM fact_plan
    GROUP BY group_id, expected_rows, expected_digest, facts
),
valid_facts AS (
    SELECT fact_rows.group_id, fact_rows.fact, fact_rows.ordinality,
           fact_rows.table_name, fact_rows.column_name,
           fact_rows.relation_oid, fact_rows.attnum
    FROM fact_rows
    JOIN fact_plan
      ON fact_plan.group_id = fact_rows.group_id
     AND fact_plan.fact = fact_rows.fact
     AND fact_plan.ordinality = fact_rows.ordinality
    WHERE fact_plan.mapping_count = 1
      AND fact_plan.resolved_count = 1
      AND fact_rows.relation_oid IS NOT NULL
      AND fact_rows.attnum IS NOT NULL
),
relation_order AS (
    SELECT valid_facts.group_id, valid_facts.relation_oid,
           min(valid_facts.table_name) AS table_name,
           dense_rank() OVER (
               PARTITION BY valid_facts.group_id
               ORDER BY min(valid_facts.ordinality), valid_facts.relation_oid
           ) AS relation_rank
    FROM valid_facts
    GROUP BY valid_facts.group_id, valid_facts.relation_oid
),
fact_columns AS (
    SELECT valid_facts.group_id, valid_facts.fact,
           valid_facts.ordinality, valid_facts.table_name,
           valid_facts.column_name, relation_order.relation_rank
    FROM valid_facts
    JOIN relation_order
      ON relation_order.group_id = valid_facts.group_id
     AND relation_order.relation_oid = valid_facts.relation_oid
),
public_tables AS (
    SELECT class_entry.oid AS relation_oid,
           class_entry.relname::text AS table_name
    FROM pg_class AS class_entry
    JOIN pg_namespace AS namespace_entry
      ON namespace_entry.oid = class_entry.relnamespace
    WHERE namespace_entry.nspname = 'public'
      AND class_entry.relkind IN ('r', 'p')
      AND class_entry.relname <> 'column_mapping'
),
foreign_key_columns AS (
    SELECT constraint_entry.conrelid AS relation_oid,
           key_column.attnum
    FROM pg_constraint AS constraint_entry
    CROSS JOIN LATERAL unnest(constraint_entry.conkey)
        AS key_column(attnum)
    WHERE constraint_entry.contype = 'f'
      AND constraint_entry.convalidated
),
unvalidated_foreign_keys AS (
    SELECT class_entry.relname::text AS table_name,
           constraint_entry.conname::text AS constraint_name,
           NOT EXISTS (
               SELECT 1
               FROM unnest(constraint_entry.conkey) AS key_column(attnum)
               JOIN pg_attribute AS key_attribute
                 ON key_attribute.attrelid = constraint_entry.conrelid
                AND key_attribute.attnum = key_column.attnum
               WHERE NOT EXISTS (
                   SELECT 1
                   FROM column_mapping AS mapping
                   WHERE mapping.table_name = class_entry.relname
                     AND mapping.column_name = key_attribute.attname
                     AND mapping.fact <> 'default_column'
               )
           ) AS holds_mapped_fact
    FROM pg_constraint AS constraint_entry
    JOIN pg_class AS class_entry
      ON class_entry.oid = constraint_entry.conrelid
    JOIN pg_namespace AS namespace_entry
      ON namespace_entry.oid = class_entry.relnamespace
    WHERE constraint_entry.contype = 'f'
      AND namespace_entry.nspname = 'public'
      AND NOT constraint_entry.convalidated
),
table_column_counts AS (
    SELECT public_tables.relation_oid,
           count(DISTINCT attribute.attnum) AS column_count,
           count(DISTINCT attribute.attnum) FILTER (
               WHERE foreign_key_columns.attnum IS NOT NULL
           ) AS foreign_key_count
    FROM public_tables
    LEFT JOIN pg_attribute AS attribute
      ON attribute.attrelid = public_tables.relation_oid
     AND attribute.attnum > 0
     AND NOT attribute.attisdropped
    LEFT JOIN foreign_key_columns
      ON foreign_key_columns.relation_oid = public_tables.relation_oid
     AND foreign_key_columns.attnum = attribute.attnum
    GROUP BY public_tables.relation_oid
),
mapped_home_tables AS (
    SELECT DISTINCT relation_oid
    FROM valid_facts
),
no_home_tables AS (
    SELECT public_tables.relation_oid, public_tables.table_name
    FROM public_tables
    JOIN table_column_counts
      ON table_column_counts.relation_oid = public_tables.relation_oid
    LEFT JOIN mapped_home_tables
      ON mapped_home_tables.relation_oid = public_tables.relation_oid
    WHERE mapped_home_tables.relation_oid IS NULL
      AND table_column_counts.column_count > table_column_counts.foreign_key_count
),
link_tables AS (
    SELECT public_tables.relation_oid, public_tables.table_name
    FROM public_tables
    JOIN table_column_counts
      ON table_column_counts.relation_oid = public_tables.relation_oid
    LEFT JOIN mapped_home_tables
      ON mapped_home_tables.relation_oid = public_tables.relation_oid
    WHERE mapped_home_tables.relation_oid IS NULL
      AND table_column_counts.column_count = table_column_counts.foreign_key_count
),
foreign_key_pairs AS (
    SELECT constraint_entry.oid AS constraint_oid,
           constraint_entry.conrelid AS child_oid,
           constraint_entry.confrelid AS parent_oid,
           child_attribute.attname::text AS child_column,
           parent_attribute.attname::text AS parent_column,
           key_column.ordinality
    FROM pg_constraint AS constraint_entry
    JOIN pg_class AS child_class
      ON child_class.oid = constraint_entry.conrelid
    JOIN pg_namespace AS child_namespace
      ON child_namespace.oid = child_class.relnamespace
    JOIN pg_class AS parent_class
      ON parent_class.oid = constraint_entry.confrelid
    JOIN pg_namespace AS parent_namespace
      ON parent_namespace.oid = parent_class.relnamespace
    CROSS JOIN LATERAL unnest(
        constraint_entry.conkey, constraint_entry.confkey
    ) WITH ORDINALITY
        AS key_column(child_attnum, parent_attnum, ordinality)
    JOIN pg_attribute AS child_attribute
      ON child_attribute.attrelid = constraint_entry.conrelid
     AND child_attribute.attnum = key_column.child_attnum
    JOIN pg_attribute AS parent_attribute
      ON parent_attribute.attrelid = constraint_entry.confrelid
     AND parent_attribute.attnum = key_column.parent_attnum
    WHERE constraint_entry.contype = 'f'
      AND constraint_entry.convalidated
      AND child_namespace.nspname = 'public'
      AND parent_namespace.nspname = 'public'
),
group_nodes AS (
    SELECT relation_order.group_id, relation_order.relation_oid,
           relation_order.table_name, false AS is_link
    FROM relation_order
    UNION
    SELECT relation_order.group_id, link_tables.relation_oid,
           link_tables.table_name, true
    FROM relation_order
    CROSS JOIN link_tables
),
candidate_foreign_key_pairs AS (
    SELECT child_node.group_id,
           foreign_key_pairs.constraint_oid,
           foreign_key_pairs.child_oid,
           foreign_key_pairs.parent_oid,
           foreign_key_pairs.child_column,
           foreign_key_pairs.parent_column,
           foreign_key_pairs.ordinality
    FROM group_nodes AS child_node
    JOIN foreign_key_pairs
      ON foreign_key_pairs.child_oid = child_node.relation_oid
    JOIN group_nodes AS parent_node
      ON parent_node.group_id = child_node.group_id
     AND parent_node.relation_oid = foreign_key_pairs.parent_oid
),
candidate_edges AS (
    SELECT group_id, child_oid AS from_oid, parent_oid AS to_oid
    FROM candidate_foreign_key_pairs
    UNION
    SELECT group_id, parent_oid, child_oid
    FROM candidate_foreign_key_pairs
),
candidate_reachability (group_id, source_oid, target_oid) AS (
    SELECT group_id, relation_oid, relation_oid
    FROM group_nodes
    UNION
    SELECT candidate_reachability.group_id,
           candidate_reachability.source_oid,
           candidate_edges.to_oid
    FROM candidate_reachability
    JOIN candidate_edges
      ON candidate_edges.group_id = candidate_reachability.group_id
     AND candidate_edges.from_oid = candidate_reachability.target_oid
),
group_links AS (
    SELECT group_nodes.group_id, group_nodes.relation_oid,
           group_nodes.table_name
    FROM group_nodes
    WHERE group_nodes.is_link
      AND (
          SELECT count(DISTINCT relation_order.relation_oid)
          FROM relation_order
          JOIN candidate_reachability
            ON candidate_reachability.group_id = relation_order.group_id
           AND candidate_reachability.source_oid = group_nodes.relation_oid
           AND candidate_reachability.target_oid = relation_order.relation_oid
          WHERE relation_order.group_id = group_nodes.group_id
      ) > 1
),
rebuild_order AS (
    SELECT group_id, relation_oid, table_name,
           row_number() OVER (
               PARTITION BY group_id
               ORDER BY is_link, mapped_rank NULLS LAST, table_name,
                        relation_oid
           ) AS relation_rank
    FROM (
        SELECT relation_order.group_id, relation_order.relation_oid,
               relation_order.table_name, false AS is_link,
               relation_order.relation_rank AS mapped_rank
        FROM relation_order
        UNION ALL
        SELECT group_links.group_id, group_links.relation_oid,
               group_links.table_name, true, NULL::bigint
        FROM group_links
    ) AS relations
),
group_foreign_key_pairs AS (
    SELECT child_relation.group_id,
           foreign_key_pairs.constraint_oid,
           child_relation.relation_rank AS child_rank,
           parent_relation.relation_rank AS parent_rank,
           foreign_key_pairs.child_column,
           foreign_key_pairs.parent_column,
           foreign_key_pairs.ordinality
    FROM rebuild_order AS child_relation
    JOIN foreign_key_pairs
      ON foreign_key_pairs.child_oid = child_relation.relation_oid
    JOIN rebuild_order AS parent_relation
      ON parent_relation.group_id = child_relation.group_id
     AND parent_relation.relation_oid = foreign_key_pairs.parent_oid
     AND child_relation.relation_oid <> parent_relation.relation_oid
),
foreign_key_joins AS (
    SELECT group_id, constraint_oid, child_rank, parent_rank,
           string_agg(
               format('t%s.%I = t%s.%I', child_rank, child_column,
                      parent_rank, parent_column),
               ' AND ' ORDER BY ordinality
           ) AS condition
    FROM group_foreign_key_pairs
    GROUP BY group_id, constraint_oid, child_rank, parent_rank
),
foreign_key_edges AS (
    SELECT group_id, child_rank AS from_rank, parent_rank AS to_rank
    FROM foreign_key_joins
    UNION
    SELECT group_id, parent_rank, child_rank
    FROM foreign_key_joins
),
reachability (group_id, source_rank, target_rank) AS (
    SELECT group_id, relation_rank, relation_rank
    FROM rebuild_order
    UNION
    SELECT reachability.group_id, reachability.source_rank,
           foreign_key_edges.to_rank
    FROM reachability
    JOIN foreign_key_edges
      ON foreign_key_edges.group_id = reachability.group_id
     AND foreign_key_edges.from_rank = reachability.target_rank
),
connected_groups AS (
    SELECT relation_order.group_id
    FROM relation_order
    LEFT JOIN reachability
      ON reachability.group_id = relation_order.group_id
     AND reachability.source_rank = 1
     AND reachability.target_rank = relation_order.relation_rank
    GROUP BY relation_order.group_id
    HAVING count(reachability.target_rank) = count(*)
),
relation_counts AS (
    SELECT group_id, count(*) AS relation_count
    FROM relation_order
    GROUP BY group_id
),
from_sql AS (
    SELECT group_id,
           string_agg(
               format('public.%I AS t%s', table_name, relation_rank),
               ' CROSS JOIN ' ORDER BY relation_rank
           ) AS text
    FROM rebuild_order
    GROUP BY group_id
),
row_id_sql AS (
    SELECT group_id,
           string_agg(
               format('t%s.tableoid AS tableoid_%s, t%s.ctid AS ctid_%s',
                      relation_rank, relation_rank, relation_rank,
                      relation_rank),
               ', ' ORDER BY relation_rank
           ) AS text
    FROM rebuild_order
    GROUP BY group_id
),
row_count_sql AS (
    SELECT group_id,
           string_agg(
               format(
                   '(SELECT count(*)::text FROM public.%I) AS total_rows_%s, count(DISTINCT (fact_rows.tableoid_%s, fact_rows.ctid_%s))::text AS joined_rows_%s',
                   table_name, relation_rank, relation_rank, relation_rank,
                   relation_rank
               ),
               ', ' ORDER BY relation_rank
           ) AS text
    FROM rebuild_order
    GROUP BY group_id
),
where_sql AS (
    SELECT group_id,
           string_agg(
               '(' || condition || ')', ' AND '
               ORDER BY child_rank, parent_rank, constraint_oid
           ) AS text
    FROM foreign_key_joins
    GROUP BY group_id
),
fact_parts AS (
    SELECT fact_columns.group_id, fact_columns.fact,
           fact_columns.ordinality,
           format(
               'CASE WHEN t%s.%I IS NULL THEN %L ELSE encode(convert_to(t%s.%I::text, %L), %L) END',
               fact_columns.relation_rank, fact_columns.column_name, '!',
               fact_columns.relation_rank, fact_columns.column_name,
               'UTF8', 'hex'
           ) AS text
    FROM fact_columns
),
row_parts AS (
    SELECT group_id,
           string_agg(text, ', ' ORDER BY ordinality) AS text
    FROM fact_parts
    GROUP BY group_id
),
ready AS MATERIALIZED (
    SELECT group_plan.group_id, group_plan.expected_rows,
           group_plan.expected_digest,
           format(
               'SELECT count(*)::text AS row_count, md5(COALESCE(string_agg(row_key, chr(10) ORDER BY row_key COLLATE "C"), %L)) AS digest, %s FROM (SELECT array_to_string(ARRAY[%s], %L) AS row_key, %s FROM %s WHERE %s) AS fact_rows',
               '', row_count_sql.text, row_parts.text, '|', row_id_sql.text,
               from_sql.text,
               coalesce(where_sql.text, 'TRUE')
           ) AS sql_text
    FROM group_plan
    JOIN row_parts ON row_parts.group_id = group_plan.group_id
    JOIN from_sql ON from_sql.group_id = group_plan.group_id
    JOIN row_count_sql ON row_count_sql.group_id = group_plan.group_id
    JOIN row_id_sql ON row_id_sql.group_id = group_plan.group_id
    JOIN connected_groups
      ON connected_groups.group_id = group_plan.group_id
    LEFT JOIN where_sql ON where_sql.group_id = group_plan.group_id
    WHERE group_plan.fact_count = cardinality(group_plan.facts)
      AND group_plan.valid_count = cardinality(group_plan.facts)
),
actual AS MATERIALIZED (
    SELECT ready.group_id, ready.expected_rows, ready.expected_digest,
           query_to_xml(ready.sql_text, false, true, '') AS result
    FROM ready
),
disconnected AS (
    SELECT relation_order.group_id, fact_columns.table_name,
           fact_columns.column_name
    FROM relation_order
    JOIN relation_counts
      ON relation_counts.group_id = relation_order.group_id
    JOIN fact_columns
      ON fact_columns.group_id = relation_order.group_id
     AND fact_columns.relation_rank = relation_order.relation_rank
    WHERE relation_counts.relation_count > 1
      AND NOT EXISTS (
          SELECT 1
          FROM connected_groups
          WHERE connected_groups.group_id = relation_order.group_id
      )
),
table_participation AS (
    SELECT actual.group_id, rebuild_order.table_name,
           (xpath(
               format('/row/total_rows_%s/text()', rebuild_order.relation_rank),
               actual.result
           ))[1]::text::bigint AS total_rows,
           (xpath(
               format('/row/joined_rows_%s/text()', rebuild_order.relation_rank),
               actual.result
           ))[1]::text::bigint AS joined_rows
    FROM actual
    JOIN rebuild_order
      ON rebuild_order.group_id = actual.group_id
),
unassigned_link_tables AS (
    SELECT counted_links.table_name, counted_links.row_count
    FROM (
        SELECT link_tables.relation_oid, link_tables.table_name,
               (xpath(
                   '/row/row_count/text()',
                   query_to_xml(
                       format(
                           'SELECT count(*)::text AS row_count FROM public.%I',
                           link_tables.table_name
                       ), false, true, ''
                   )
               ))[1]::text::bigint AS row_count
        FROM link_tables
    ) AS counted_links
    WHERE counted_links.row_count > 0
      AND NOT EXISTS (
        SELECT 1 FROM group_links
        WHERE group_links.relation_oid = counted_links.relation_oid
    )
),
materialized_views AS (
    SELECT class_entry.relname::text AS table_name
    FROM pg_class AS class_entry
    JOIN pg_namespace AS namespace_entry
      ON namespace_entry.oid = class_entry.relnamespace
    WHERE namespace_entry.nspname = 'public'
      AND class_entry.relkind = 'm'
),
self_referencing_foreign_keys AS (
    SELECT class_entry.relname::text AS table_name,
           attribute.attname::text AS column_name
    FROM pg_constraint AS constraint_entry
    JOIN pg_class AS class_entry
      ON class_entry.oid = constraint_entry.conrelid
    JOIN pg_namespace AS namespace_entry
      ON namespace_entry.oid = class_entry.relnamespace
    CROSS JOIN LATERAL unnest(constraint_entry.conkey)
        AS key_column(attnum)
    JOIN pg_attribute AS attribute
      ON attribute.attrelid = constraint_entry.conrelid
     AND attribute.attnum = key_column.attnum
    WHERE constraint_entry.contype = 'f'
      AND constraint_entry.conrelid = constraint_entry.confrelid
      AND namespace_entry.nspname = 'public'
),
digest_failures AS (
    SELECT actual.group_id
    FROM actual
    WHERE (xpath('/row/row_count/text()', actual.result))[1]::text::bigint
              <> actual.expected_rows
       OR (xpath('/row/digest/text()', actual.result))[1]::text
              <> actual.expected_digest
),
no_primary_key AS (
    SELECT public_tables.table_name
    FROM public_tables
    WHERE NOT EXISTS (
        SELECT 1
        FROM pg_index AS index_entry
        WHERE index_entry.indrelid = public_tables.relation_oid
          AND index_entry.indisprimary
          AND index_entry.indisvalid
    )
),
unmapped_columns AS (
    SELECT public_tables.table_name,
           attribute.attname::text AS column_name
    FROM public_tables
    JOIN pg_attribute AS attribute
      ON attribute.attrelid = public_tables.relation_oid
     AND attribute.attnum > 0
     AND NOT attribute.attisdropped
    WHERE NOT EXISTS (
        SELECT 1
        FROM column_mapping AS mapping
        WHERE mapping.table_name = public_tables.table_name
          AND mapping.column_name = attribute.attname
    )
      AND NOT EXISTS (
        SELECT 1
        FROM pg_index AS index_entry
        WHERE index_entry.indrelid = public_tables.relation_oid
          AND index_entry.indisprimary
          AND index_entry.indisvalid
          AND index_entry.indnkeyatts = 1
      -- The first indkey entry is the primary-key column. INCLUDE entries follow it.
          AND index_entry.indkey[0] = attribute.attnum
    )
      AND NOT EXISTS (
        SELECT 1
        FROM foreign_key_columns
        WHERE foreign_key_columns.relation_oid = public_tables.relation_oid
          AND foreign_key_columns.attnum = attribute.attnum
    )
),
default_column_role_issues AS (
    SELECT format(
               '%s.%s has no mapped export fact, declared foreign key, or one-column primary key role, so default_column exempts nothing.',
               public_tables.table_name, attribute.attname
           ) AS issue
    FROM column_mapping AS default_mapping
    JOIN public_tables
      ON public_tables.table_name = default_mapping.table_name
    JOIN pg_attribute AS attribute
      ON attribute.attrelid = public_tables.relation_oid
     AND attribute.attname = default_mapping.column_name
     AND attribute.attnum > 0
     AND NOT attribute.attisdropped
    WHERE default_mapping.fact = 'default_column'
      AND NOT EXISTS (
          SELECT 1
          FROM export_groups
          CROSS JOIN LATERAL unnest(export_groups.facts)
              AS export_fact(fact)
          JOIN column_mapping AS export_mapping
            ON export_mapping.fact = export_fact.fact
          WHERE export_mapping.table_name = default_mapping.table_name
            AND export_mapping.column_name = default_mapping.column_name
      )
      AND NOT EXISTS (
          SELECT 1
          FROM foreign_key_columns
          WHERE foreign_key_columns.relation_oid = public_tables.relation_oid
            AND foreign_key_columns.attnum = attribute.attnum
      )
      AND NOT EXISTS (
          SELECT 1
          FROM pg_index AS index_entry
          WHERE index_entry.indrelid = public_tables.relation_oid
            AND index_entry.indisprimary
            AND index_entry.indisvalid
            AND index_entry.indnkeyatts = 1
            AND index_entry.indkey[0] = attribute.attnum
      )
),
mapping_issues AS (
    SELECT format(
               'column_mapping.%s maps to %s.%s, but it is not an export fact, so it cannot map an export column.',
               coalesce(mapping.fact, '<null>'),
               coalesce(mapping.table_name, '<table>'),
               coalesce(mapping.column_name, '<column>')
           ) AS issue
    FROM column_mapping AS mapping
    WHERE NOT EXISTS (
        SELECT 1 FROM known_mapping_facts
        WHERE known_mapping_facts.fact = mapping.fact
    )
    UNION ALL
    SELECT default_column_role_issues.issue
    FROM default_column_role_issues
    UNION ALL
    SELECT format(
               'column_mapping.%s has %s rows, so its export alias must map once.',
               alias_plan.fact, alias_plan.mapping_count
           )
    FROM (
        SELECT fact_aliases.fact, count(mapping.fact) AS mapping_count
        FROM fact_aliases
        LEFT JOIN column_mapping AS mapping
          ON mapping.fact = fact_aliases.fact
        GROUP BY fact_aliases.fact
    ) AS alias_plan
    WHERE alias_plan.mapping_count <> 1
    UNION ALL
    SELECT format(
               'column_mapping.%s maps to %s.%s instead of %s.%s, so it does not point to the export fact column.',
               fact_aliases.fact,
               coalesce(alias_mapping.table_name, '<table>'),
               coalesce(alias_mapping.column_name, '<column>'),
               coalesce(export_mapping.table_name, '<table>'),
               coalesce(export_mapping.column_name, '<column>')
           )
    FROM fact_aliases
    JOIN column_mapping AS alias_mapping
      ON alias_mapping.fact = fact_aliases.fact
    JOIN valid_facts AS export_mapping
      ON export_mapping.fact = fact_aliases.export_fact
    WHERE (alias_mapping.table_name, alias_mapping.column_name)
          IS DISTINCT FROM
          (export_mapping.table_name, export_mapping.column_name)
    UNION ALL
    SELECT format(
               'column_mapping.%s has no table.column, so the export fact has no home.',
               fact_plan.fact
           ) AS issue
    FROM fact_plan
    WHERE fact_plan.mapping_count = 0
    UNION ALL
    SELECT format(
               'column_mapping.%s maps to %s, so the export fact has more than one home.',
               fact_plan.fact, fact_plan.targets
           )
    FROM fact_plan
    WHERE fact_plan.mapping_count > 1
    UNION ALL
    SELECT format(
               '%s is not a public table column, so the export fact cannot be rebuilt.',
               fact_plan.targets
           )
    FROM fact_plan
    WHERE fact_plan.mapping_count = 1
      AND fact_plan.resolved_count <> 1
),
row_issues AS (
    SELECT format(
               '%s.<row> has %s rows, but only %s take part in the rebuilt %s export, so every row must appear in the rebuild.',
               table_participation.table_name,
               table_participation.total_rows,
               table_participation.joined_rows,
               table_participation.group_id
           ) AS issue
    FROM table_participation
    WHERE table_participation.total_rows <> table_participation.joined_rows
),
digest_issues AS (
    SELECT format(
               '%s.%s does not rebuild the %s export facts, so the joined rows differ from the export.',
               fact_columns.table_name, fact_columns.column_name,
               fact_columns.group_id
           ) AS issue
    FROM fact_columns
    JOIN digest_failures
      ON digest_failures.group_id = fact_columns.group_id
),
join_issues AS (
    SELECT format(
               '%s.%s has no declared foreign-key path to the other mapped tables in %s, so the facts cannot be joined.',
               disconnected.table_name, disconnected.column_name,
               disconnected.group_id
           ) AS issue
    FROM disconnected
)
SELECT issue FROM mapping_issues
UNION ALL
SELECT format('%s.<primary key> has no primary key, so its rows have no declared row key.',
              no_primary_key.table_name)
FROM no_primary_key
UNION ALL
SELECT format(
           '%s.%s is unmapped, is not a declared foreign key, and is not the table''s one-column primary key, so it has no permitted role.',
           unmapped_columns.table_name, unmapped_columns.column_name
       )
FROM unmapped_columns
UNION ALL
SELECT format(
           '%s has no mapped fact and is not a link table, so it breaks the rule that tables hold facts or link other tables.',
           no_home_tables.table_name
       )
FROM no_home_tables
UNION ALL
SELECT format(
           '%s.<row> has %s row%s, but 0 take part in any rebuilt export, so every link row must join a mapped fact table.',
           unassigned_link_tables.table_name,
           unassigned_link_tables.row_count,
           CASE WHEN unassigned_link_tables.row_count = 1 THEN '' ELSE 's' END
       )
FROM unassigned_link_tables
UNION ALL
SELECT format(
           '%s is a materialized view, so its stored rows sit outside the tables used to rebuild the export.',
           materialized_views.table_name
       )
FROM materialized_views
UNION ALL
SELECT format(
           '%s.%s references its own table, and the export has no hierarchy, so the facts check cannot rebuild a table joined to itself.',
           self_referencing_foreign_keys.table_name,
           self_referencing_foreign_keys.column_name
       )
FROM self_referencing_foreign_keys
UNION ALL
SELECT format(
           '%s.%s is not validated, so it can''t be a rebuild or bypass path.',
           unvalidated_foreign_keys.table_name,
           unvalidated_foreign_keys.constraint_name
       )
FROM unvalidated_foreign_keys
WHERE unvalidated_foreign_keys.holds_mapped_fact
UNION ALL
SELECT format(
           '%s.%s is not validated, so it can''t give a column a role.',
           unvalidated_foreign_keys.table_name,
           unvalidated_foreign_keys.constraint_name
       )
FROM unvalidated_foreign_keys
WHERE NOT unvalidated_foreign_keys.holds_mapped_fact
UNION ALL
SELECT issue FROM join_issues
UNION ALL
SELECT issue FROM row_issues
UNION ALL
SELECT issue FROM digest_issues
ORDER BY 1;
