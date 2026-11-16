-- The required date, amount, and default types.
WITH wanted (fact, expected_type, expected_precision, expected_scale) AS (
    VALUES
        ('term_start', 'date', NULL::integer, NULL::integer),
        ('enrolled_on', 'date', NULL::integer, NULL::integer),
        ('paid_on', 'date', NULL::integer, NULL::integer),
        ('tuition_due', 'numeric', 10, 2),
        ('payment_amount', 'numeric', 10, 2),
        ('default_column', NULL, NULL::integer, NULL::integer)
),
resolved AS (
    SELECT wanted.fact, wanted.expected_type, wanted.expected_precision, wanted.expected_scale,
           mapping.table_name, mapping.column_name,
           count(mapping.fact) OVER (PARTITION BY wanted.fact) AS mapping_count
    FROM wanted
    LEFT JOIN column_mapping AS mapping ON mapping.fact = wanted.fact
),
actual AS (
    SELECT resolved.fact, resolved.expected_type, resolved.expected_precision, resolved.expected_scale,
           resolved.table_name, resolved.column_name, resolved.mapping_count,
           columns.data_type, columns.numeric_precision, columns.numeric_scale, columns.column_default
    FROM resolved
    LEFT JOIN information_schema.columns AS columns
      ON columns.table_schema = 'public'
     AND columns.table_name = resolved.table_name
     AND columns.column_name = resolved.column_name
)
SELECT fact
FROM actual
WHERE mapping_count <> 1
   OR table_name IS NULL
   OR column_name IS NULL
   OR data_type IS NULL
   OR (expected_type IS NOT NULL AND data_type <> expected_type)
   OR (expected_precision IS NOT NULL AND numeric_precision IS DISTINCT FROM expected_precision)
   OR (expected_scale IS NOT NULL AND numeric_scale IS DISTINCT FROM expected_scale)
   OR (fact = 'default_column' AND column_default IS NULL)
ORDER BY fact;
