-- GoogleSQL / BigQuery. Read-only; returns one grouped response summary.
-- Review the console's estimated bytes before running.
-- Purpose: distinguish response session types, explain missing sittings,
-- inspect subjects, and understand omissions/repeats before defining scores.
-- Uses session_id/question_id uniqueness verified in the supplied profile.
-- LEFT JOINs retain responses whose parent sitting or hierarchy row is absent.
-- All source responses are included; eligibility rules are not applied here.
-- Repeat groups use (pupil_id, session_id, question_id). The repeat metric
-- counts ALL response rows in such groups, not just the extra rows.
-- Sitting response counts include every subject and pupil in that session.
-- Within-group distinct pupils/sessions and mismatch counts must not be added
-- across groups: one pupil/session can occur in more than one group.
-- Sittings without any responses are outside this response-based profile.
-- A count mismatch or timestamp mismatch is an observation to investigate,
-- not an automatic exclusion or proof of bad data.

WITH response_details AS (
  SELECT
    pupil_id,
    session_id,
    question_id,
    session_type,
    is_correct,
    is_no_attempt,
    answered_at,
    COUNT(*) OVER (
      PARTITION BY pupil_id, session_id, question_id
    ) AS rows_per_pupil_session_question,
    COUNT(*) OVER (PARTITION BY session_id) AS rows_per_session
  FROM `atom-analytics-candidates.de_raw.responses`
),
joined AS (
  SELECT
    r.*,
    h.subject_id,
    h.subject_name,
    s.session_id AS matched_session_id,
    s.session_type AS sitting_session_type,
    s.style AS sitting_style,
    s.year_group_at_sitting,
    s.total_questions,
    s.started_at,
    s.finished_at,
    CASE
      WHEN s.session_id IS NULL THEN 'missing_sitting'
      WHEN s.is_deleted IS TRUE THEN 'deleted'
      WHEN s.is_complete IS TRUE AND s.finished_at IS NOT NULL THEN 'complete'
      WHEN s.is_complete IS FALSE THEN 'incomplete'
      ELSE 'unknown_or_inconsistent'
    END AS sitting_status
  FROM response_details AS r
  LEFT JOIN `atom-analytics-candidates.de_raw.assessment_sittings` AS s
    ON r.session_id = s.session_id
  LEFT JOIN `atom-analytics-candidates.de_raw.course_hierarchy` AS h
    ON r.question_id = h.question_id
)
SELECT
  subject_id,
  subject_name,
  session_type AS response_session_type,
  sitting_session_type,
  sitting_style,
  sitting_status,
  COUNT(*) AS response_rows,
  COUNT(DISTINCT pupil_id) AS distinct_pupils,
  COUNT(DISTINCT session_id) AS distinct_sessions,
  COUNTIF(is_no_attempt IS TRUE) AS no_attempt_rows,
  COUNTIF(is_correct IS TRUE) AS correct_rows,
  COUNTIF(rows_per_pupil_session_question > 1)
    AS response_rows_in_repeated_question_groups,
  COUNT(DISTINCT CASE
    WHEN matched_session_id IS NOT NULL AND started_at IS NULL
    THEN matched_session_id
  END) AS sittings_missing_start,
  COUNT(DISTINCT CASE
    WHEN rows_per_session <> total_questions THEN matched_session_id
  END) AS sittings_with_response_count_mismatch,
  COUNTIF(answered_at < started_at) AS responses_before_sitting_start,
  COUNTIF(answered_at > finished_at) AS responses_after_sitting_finish,
  MIN(year_group_at_sitting) AS lowest_year_group,
  MAX(year_group_at_sitting) AS highest_year_group,
  MIN(answered_at) AS earliest_answered_at,
  MAX(answered_at) AS latest_answered_at
FROM joined
GROUP BY
  subject_id,
  subject_name,
  session_type,
  sitting_session_type,
  sitting_style,
  sitting_status
ORDER BY
  sitting_status,
  subject_name,
  subject_id,
  response_session_type,
  sitting_session_type,
  sitting_style;
