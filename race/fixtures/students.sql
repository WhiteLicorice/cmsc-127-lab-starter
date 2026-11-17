SELECT student.student_id
  FROM student
 WHERE student.student_id <> 834
 ORDER BY student.student_id
 LIMIT %s;
