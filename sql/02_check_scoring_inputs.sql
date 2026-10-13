-- GoogleSQL / BigQuery. Read-only; returns one result table of observations.
-- Review the console's estimated bytes before running: this reads source data.
-- Run after 01_profile_sources.sql. A nonzero observation is not automatically
-- a defect: deleted, incomplete, and no-attempt records can be legitimate.
-- All rows are profiled, including deleted/incomplete records. No scoring
-- population or filtering policy has been chosen yet.
-- Each percentage uses all rows of its named source table as its denominator.
-- DISTINCT parent keys prevent duplicate parents from multiplying responses
-- during these checks. They do not fix or approve the underlying duplicates.

WITH pupil_keys AS (
  SELECT DISTINCT pupil_id
  FROM `atom-analytics-candidates.de_raw.pupils`
  WHERE NULLIF(TRIM(pupil_id), '') IS NOT NULL
),
session_keys AS (
  SELECT DISTINCT session_id
  FROM `atom-analytics-candidates.de_raw.assessment_sittings`
  WHERE NULLIF(TRIM(session_id), '') IS NOT NULL
),
session_pupil_keys AS (
  SELECT DISTINCT session_id, pupil_id
  FROM `atom-analytics-candidates.de_raw.assessment_sittings`
  WHERE NULLIF(TRIM(session_id), '') IS NOT NULL
    AND NULLIF(TRIM(pupil_id), '') IS NOT NULL
),
question_keys AS (
  SELECT DISTINCT question_id
  FROM `atom-analytics-candidates.de_raw.course_hierarchy`
  WHERE NULLIF(TRIM(question_id), '') IS NOT NULL
),
response_checks AS (
  SELECT
    COUNT(*) AS total_rows,
    COUNTIF(NULLIF(TRIM(r.pupil_id), '') IS NULL) AS missing_pupil_key,
    COUNTIF(NULLIF(TRIM(r.session_id), '') IS NULL) AS missing_session_key,
    COUNTIF(NULLIF(TRIM(r.question_id), '') IS NULL) AS missing_question_key,
    COUNTIF(
      NULLIF(TRIM(r.pupil_id), '') IS NOT NULL AND p.pupil_id IS NULL
    ) AS pupil_key_not_found,
    COUNTIF(
      NULLIF(TRIM(r.session_id), '') IS NOT NULL AND s.session_id IS NULL
    ) AS session_key_not_found,
    COUNTIF(
      NULLIF(TRIM(r.question_id), '') IS NOT NULL AND q.question_id IS NULL
    ) AS question_key_not_found,
    COUNTIF(
      s.session_id IS NOT NULL
      AND NULLIF(TRIM(r.pupil_id), '') IS NOT NULL
      AND sp.pupil_id IS NULL
    ) AS existing_session_without_pupil_match,
    COUNTIF(r.is_correct IS NULL) AS unknown_correctness,
    COUNTIF(r.is_no_attempt IS NULL) AS unknown_attempt_status,
    COUNTIF(r.is_no_attempt IS TRUE) AS no_attempt_rows,
    COUNTIF(r.is_correct IS TRUE AND r.is_no_attempt IS TRUE)
      AS correct_and_no_attempt,
    COUNTIF(r.answered_at IS NULL) AS missing_answered_at,
    COUNTIF(r.seconds_taken < 0) AS negative_seconds_taken
  FROM `atom-analytics-candidates.de_raw.responses` AS r
  LEFT JOIN pupil_keys AS p ON r.pupil_id = p.pupil_id
  LEFT JOIN session_keys AS s ON r.session_id = s.session_id
  LEFT JOIN session_pupil_keys AS sp
    ON r.session_id = sp.session_id AND r.pupil_id = sp.pupil_id
  LEFT JOIN question_keys AS q ON r.question_id = q.question_id
),
sitting_checks AS (
  SELECT
    COUNT(*) AS total_rows,
    COUNTIF(NULLIF(TRIM(s.pupil_id), '') IS NULL) AS missing_pupil_key,
    COUNTIF(
      NULLIF(TRIM(s.pupil_id), '') IS NOT NULL AND p.pupil_id IS NULL
    ) AS pupil_key_not_found,
    COUNTIF(s.is_complete IS FALSE) AS incomplete_sittings,
    COUNTIF(s.is_complete IS NULL) AS unknown_completion_status,
    COUNTIF(s.is_deleted IS TRUE) AS deleted_sittings,
    COUNTIF(s.is_deleted IS NULL) AS unknown_deletion_status,
    COUNTIF(s.started_at IS NULL) AS missing_started_at,
    COUNTIF(s.finished_at IS NULL) AS missing_finished_at,
    COUNTIF(s.is_complete IS TRUE AND s.finished_at IS NULL)
      AS complete_without_finished_at,
    COUNTIF(s.finished_at < s.started_at) AS finished_before_started,
    COUNTIF(s.total_questions IS NULL) AS unknown_total_questions,
    COUNTIF(s.total_questions <= 0) AS nonpositive_total_questions
  FROM `atom-analytics-candidates.de_raw.assessment_sittings` AS s
  LEFT JOIN pupil_keys AS p ON s.pupil_id = p.pupil_id
),
pupil_checks AS (
  SELECT
    COUNT(*) AS total_rows,
    COUNTIF(is_deleted IS TRUE) AS deleted_pupils,
    COUNTIF(is_deleted IS NULL) AS unknown_deletion_status
  FROM `atom-analytics-candidates.de_raw.pupils`
),
hierarchy_checks AS (
  SELECT
    COUNT(*) AS total_rows,
    COUNTIF(NULLIF(TRIM(subject_id), '') IS NULL) AS missing_subject_id,
    COUNTIF(NULLIF(TRIM(subject_name), '') IS NULL) AS missing_subject_name
  FROM `atom-analytics-candidates.de_raw.course_hierarchy`
),
observations AS (
  SELECT 'responses' AS table_name, metric, COALESCE(matching_rows, 0) AS matching_rows, total_rows
  FROM response_checks
  UNPIVOT INCLUDE NULLS (
    matching_rows FOR metric IN (
      missing_pupil_key,
      missing_session_key,
      missing_question_key,
      pupil_key_not_found,
      session_key_not_found,
      question_key_not_found,
      existing_session_without_pupil_match,
      unknown_correctness,
      unknown_attempt_status,
      no_attempt_rows,
      correct_and_no_attempt,
      missing_answered_at,
      negative_seconds_taken
    )
  )

  UNION ALL

  SELECT 'assessment_sittings', metric, COALESCE(matching_rows, 0), total_rows
  FROM sitting_checks
  UNPIVOT INCLUDE NULLS (
    matching_rows FOR metric IN (
      missing_pupil_key,
      pupil_key_not_found,
      incomplete_sittings,
      unknown_completion_status,
      deleted_sittings,
      unknown_deletion_status,
      missing_started_at,
      missing_finished_at,
      complete_without_finished_at,
      finished_before_started,
      unknown_total_questions,
      nonpositive_total_questions
    )
  )

  UNION ALL

  SELECT 'pupils', metric, COALESCE(matching_rows, 0), total_rows
  FROM pupil_checks
  UNPIVOT INCLUDE NULLS (
    matching_rows FOR metric IN (deleted_pupils, unknown_deletion_status)
  )

  UNION ALL

  SELECT 'course_hierarchy', metric, COALESCE(matching_rows, 0), total_rows
  FROM hierarchy_checks
  UNPIVOT INCLUDE NULLS (
    matching_rows FOR metric IN (missing_subject_id, missing_subject_name)
  )
)
SELECT
  table_name,
  metric,
  matching_rows,
  total_rows,
  ROUND(100.0 * SAFE_DIVIDE(matching_rows, total_rows), 2) AS percent_of_table
FROM observations
ORDER BY table_name, metric;
