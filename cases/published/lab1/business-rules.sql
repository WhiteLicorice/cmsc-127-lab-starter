-- Each key-enforced business rule must have a key on its mapped columns in the
-- relation that holds the dependent. A vertical split may put a rule's facts in
-- several relations; each dependent is checked in the relation that holds it.
-- The facts check requires one mapped column for each export fact.
WITH rules (rule_id, determinant, dependents) AS (
    VALUES
        ('R1',  ARRAY['term'], ARRAY['term_start']),
        ('R2',  ARRAY['program_name'], ARRAY['program_name']),
        ('R3',  ARRAY['student_id'], ARRAY['student_name', 'student_program', 'student_year_level']),
        ('R4',  ARRAY['course_id'], ARRAY['course_code', 'course_title', 'units']),
        ('R5',  ARRAY['course_code'], ARRAY['course_id']),
        ('R6',  ARRAY['instructor_id'], ARRAY['instructor_name']),
        ('R7a', ARRAY['room_id'], ARRAY['room_name']),
        ('R7b', ARRAY['room_name'], ARRAY['room_id']),
        ('R8',  ARRAY['section_term', 'section_instructor'], ARRAY['section_course']),
        ('R9',  ARRAY['section_term', 'section_room'], ARRAY['section_instructor']),
        ('R10', ARRAY['enrollment_student', 'enrollment_term', 'enrollment_instructor'], ARRAY['enrolled_on']),
        ('R12', ARRAY['charge_student', 'charge_term'], ARRAY['tuition_due']),
        ('R13', ARRAY['payment_student', 'payment_term', 'payment_seq'], ARRAY['payment_amount', 'paid_on'])
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
)
SELECT DISTINCT split_part(dependency_facts.dependency_id, ':', 1) AS rule_id
FROM dependency_facts
LEFT JOIN dependent_check
  ON dependent_check.dependency_id = dependency_facts.dependency_id
WHERE dependency_facts.invalid_count > 0
   OR dependent_check.dependency_id IS NULL
   OR NOT dependent_check.ok
ORDER BY rule_id;
