-- GoogleSQL. Run the entire file in europe-west2 before 06_build_scores.sql.
-- Copies the small supplied extract into reusable candidate-owned tables.
-- Explicit full refresh: do not schedule this unchanged at 100m+ rows.
-- All response versions are retained for historical recomputation.

CREATE OR REPLACE TABLE `atom-analytics-candidates.daniel_chen.stg_pupils` AS
SELECT pupil_id, is_deleted
FROM `atom-analytics-candidates.de_raw.pupils`;

CREATE OR REPLACE TABLE `atom-analytics-candidates.daniel_chen.stg_questions` AS
SELECT question_id, atom_id, subtopic_id, topic_id, subject_id, subject_name
FROM `atom-analytics-candidates.de_raw.course_hierarchy`;

CREATE OR REPLACE TABLE `atom-analytics-candidates.daniel_chen.stg_sittings` AS
SELECT session_id, pupil_id, assessment_id, session_type, style,
  year_group_at_sitting, total_questions, is_complete, is_deleted,
  started_at, finished_at
FROM `atom-analytics-candidates.de_raw.assessment_sittings`;

CREATE OR REPLACE TABLE `atom-analytics-candidates.daniel_chen.stg_response_versions`
PARTITION BY DATE(answered_at)
CLUSTER BY pupil_id, session_id, question_number AS
SELECT response_id, pupil_id, session_id, session_type, question_id,
  is_correct, is_no_attempt, seconds_taken, question_number, answered_at
FROM `atom-analytics-candidates.de_raw.responses`;

-- Fail rather than silently multiply rows in joins or choose an unstable winner.
ASSERT NOT EXISTS (
  SELECT pupil_id FROM `atom-analytics-candidates.daniel_chen.stg_pupils`
  GROUP BY pupil_id
  HAVING pupil_id IS NULL OR TRIM(pupil_id) = '' OR COUNT(*) > 1
) AS 'Pupil IDs must be unique and populated';

ASSERT NOT EXISTS (
  SELECT question_id FROM `atom-analytics-candidates.daniel_chen.stg_questions`
  GROUP BY question_id
  HAVING question_id IS NULL OR TRIM(question_id) = '' OR COUNT(*) > 1
) AS 'Question IDs must be unique and populated';

ASSERT NOT EXISTS (
  SELECT session_id FROM `atom-analytics-candidates.daniel_chen.stg_sittings`
  GROUP BY session_id
  HAVING session_id IS NULL OR TRIM(session_id) = '' OR COUNT(*) > 1
) AS 'Sitting IDs must be unique and populated';

ASSERT NOT EXISTS (
  SELECT response_id FROM `atom-analytics-candidates.daniel_chen.stg_response_versions`
  GROUP BY response_id
  HAVING response_id IS NULL OR TRIM(response_id) = '' OR COUNT(*) > 1
) AS 'Response IDs must be unique and populated';

ASSERT NOT EXISTS (
  SELECT 1 FROM `atom-analytics-candidates.daniel_chen.stg_response_versions`
  WHERE answered_at IS NULL
    OR pupil_id IS NULL OR TRIM(pupil_id) = ''
    OR session_id IS NULL OR TRIM(session_id) = ''
    OR question_number IS NULL
) AS 'Historical ranking requires an event time and a complete position key';

ASSERT NOT EXISTS (
  SELECT subject_id FROM `atom-analytics-candidates.daniel_chen.stg_questions`
  GROUP BY subject_id
  HAVING subject_id IS NULL OR TRIM(subject_id) = ''
    OR COUNT(DISTINCT subject_name) <> 1
    OR COUNTIF(subject_name IS NULL OR TRIM(subject_name) = '') > 0
) AS 'Each subject ID must have exactly one populated name';

CREATE OR REPLACE TABLE `atom-analytics-candidates.daniel_chen.dim_subjects` AS
SELECT subject_id, MIN(subject_name) AS subject_name,
  -- Explicit policy for this extract: surveys do not measure attainment.
  LOWER(TRIM(MIN(subject_name))) <> 'wellbeing' AS is_score_applicable
FROM `atom-analytics-candidates.daniel_chen.stg_questions`
GROUP BY subject_id;
