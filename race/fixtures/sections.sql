WITH race_term AS (
    INSERT INTO term (term, term_start)
    VALUES ('2099-1S', DATE '2099-01-01')
    ON CONFLICT (term) DO UPDATE SET term_start = EXCLUDED.term_start
    RETURNING term
),
race_section AS (
    INSERT INTO section (
        section_id, term, instructor_id, course_id, room_id, section_capacity
    )
    SELECT 900001, race_term.term, 33, 1, NULL, 1
      FROM race_term
    ON CONFLICT (term, instructor_id)
        DO UPDATE SET section_capacity = EXCLUDED.section_capacity
    RETURNING section_id, term, instructor_id, course_id, section_capacity
)
SELECT race_section.section_id,
       race_section.term,
       race_section.instructor_id,
       race_section.course_id,
       race_section.section_capacity,
       0::integer AS enrollment_count
  FROM race_section;
