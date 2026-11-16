SELECT student.student_id
  FROM student
 WHERE NOT EXISTS (
       SELECT 1
         FROM enrollment
        WHERE enrollment.student_id = student.student_id
          AND enrollment.term = %s
          AND enrollment.instructor_id = %s
  )
   AND NOT EXISTS (
       SELECT 1
         FROM student_course
        WHERE student_course.student_id = student.student_id
          AND student_course.term = %s
          AND student_course.course_id = %s
  )
 ORDER BY student.student_id
 LIMIT %s;
