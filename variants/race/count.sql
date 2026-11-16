SELECT section.section_capacity,
       COUNT(enrollment.student_id)::integer AS enrollment_count
  FROM section
  LEFT JOIN enrollment
    ON enrollment.term = section.term
   AND enrollment.instructor_id = section.instructor_id
 WHERE section.section_id = %s
 GROUP BY section.section_id, section.section_capacity;
