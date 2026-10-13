-- GoogleSQL. Run the entire file in europe-west2 after 05_prepare_models.sql.
-- Inclusive UTC cutoff. Change this value to recompute another point in time.
-- The default follows the latest supplied response (2026-09-16).
DECLARE score_as_of TIMESTAMP DEFAULT TIMESTAMP '2026-09-17 00:00:00+00';
DECLARE score_model_version STRING DEFAULT 'latest_sitting_linear_v1';

-- CRITICAL: filter before ranking. A future revision must not hide an older one.
CREATE TEMP TABLE canonical_responses AS
SELECT *
FROM `atom-analytics-candidates.daniel_chen.stg_response_versions`
WHERE answered_at <= score_as_of
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY pupil_id, session_id, question_number
  ORDER BY answered_at DESC, response_id DESC
) = 1;

CREATE TEMP TABLE response_audit AS
SELECT
  r.*, q.subject_id,
  CASE
    WHEN p.pupil_id IS NULL THEN 'missing_pupil'
    WHEN p.is_deleted IS NOT FALSE THEN 'inactive_or_unknown_pupil'
    WHEN s.session_id IS NULL THEN 'missing_sitting'
    WHEN r.pupil_id <> s.pupil_id OR s.pupil_id IS NULL THEN 'pupil_mismatch'
    WHEN q.question_id IS NULL THEN 'missing_question'
    WHEN r.session_type IS NULL OR r.session_type <> 'MOCK_TEST'
      THEN 'unsupported_response_type'
    WHEN r.is_correct IS NULL OR r.is_no_attempt IS NULL
      OR (r.is_correct AND r.is_no_attempt) THEN 'invalid_answer_flags'
    WHEN r.question_number < 1 OR r.question_number > s.total_questions
      THEN 'invalid_position'
    WHEN r.answered_at < s.started_at
      OR r.answered_at > TIMESTAMP_ADD(s.finished_at, INTERVAL 1 SECOND)
      THEN 'outside_sitting_window'
    ELSE 'valid_response'
  END AS response_status
FROM canonical_responses AS r
LEFT JOIN `atom-analytics-candidates.daniel_chen.stg_pupils` AS p
  ON r.pupil_id = p.pupil_id
LEFT JOIN `atom-analytics-candidates.daniel_chen.stg_sittings` AS s
  ON r.session_id = s.session_id
LEFT JOIN `atom-analytics-candidates.daniel_chen.stg_questions` AS q
  ON r.question_id = q.question_id;

-- The declared total belongs to the WHOLE sitting, even if it spans subjects.
-- Keep one primary reason per sitting, plus counts for investigation.
CREATE TEMP TABLE sitting_quality AS
WITH counts AS (
  SELECT session_id, COUNT(*) AS canonical_response_count,
    COUNTIF(response_status <> 'valid_response') AS invalid_response_count
  FROM response_audit
  GROUP BY session_id
)
SELECT
  score_as_of AS as_of_at, score_model_version AS model_version,
  s.*,
  COALESCE(c.canonical_response_count, 0) AS canonical_response_count,
  COALESCE(c.invalid_response_count, 0) AS invalid_response_count,
  CASE
    WHEN p.pupil_id IS NULL THEN 'missing_pupil'
    WHEN p.is_deleted IS NOT FALSE THEN 'inactive_or_unknown_pupil'
    WHEN s.is_deleted IS NOT FALSE THEN 'deleted_or_unknown_sitting'
    WHEN s.is_complete IS NOT TRUE THEN 'incomplete_or_unknown'
    WHEN s.finished_at IS NULL THEN 'missing_finish'
    WHEN s.finished_at > score_as_of THEN 'not_finished_as_of'
    WHEN s.finished_at < s.started_at THEN 'invalid_sitting_window'
    WHEN s.style IS NULL OR s.style <> 'fixed_question'
      OR s.session_type IS NULL OR s.session_type <> 'summative_assessment'
      THEN 'unsupported_sitting_type'
    WHEN s.total_questions IS NULL OR s.total_questions < 1 THEN 'invalid_total'
    WHEN COALESCE(c.canonical_response_count, 0) = 0 THEN 'no_responses'
    WHEN c.invalid_response_count > 0 THEN 'invalid_responses'
    WHEN c.canonical_response_count <> s.total_questions THEN 'question_count_mismatch'
    ELSE 'eligible'
  END AS sitting_status
FROM `atom-analytics-candidates.daniel_chen.stg_sittings` AS s
LEFT JOIN `atom-analytics-candidates.daniel_chen.stg_pupils` AS p
  ON s.pupil_id = p.pupil_id
LEFT JOIN counts AS c ON s.session_id = c.session_id;

CREATE TEMP TABLE sitting_subject_scores AS
SELECT
  score_as_of AS as_of_at, score_model_version AS model_version,
  r.pupil_id, r.session_id, r.subject_id,
  s.assessment_id, s.finished_at, s.year_group_at_sitting,
  COUNT(*) AS question_count,
  COUNTIF(r.is_correct AND NOT r.is_no_attempt) AS correct_count,
  COUNTIF(r.is_no_attempt) AS no_attempt_count,
  MAX(r.answered_at) AS last_answered_at
FROM response_audit AS r
JOIN sitting_quality AS s ON r.session_id = s.session_id
JOIN `atom-analytics-candidates.daniel_chen.dim_subjects` AS d
  ON r.subject_id = d.subject_id
WHERE s.sitting_status = 'eligible' AND d.is_score_applicable
GROUP BY r.pupil_id, r.session_id, r.subject_id,
  s.assessment_id, s.finished_at, s.year_group_at_sitting;

CREATE TEMP TABLE pupil_subject_scores AS
WITH latest AS (
  SELECT * FROM sitting_subject_scores
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY pupil_id, subject_id
    ORDER BY finished_at DESC, session_id DESC
  ) = 1
)
SELECT
  score_as_of AS as_of_at, score_model_version AS model_version,
  p.pupil_id, d.subject_id, d.subject_name,
  CASE
    WHEN p.is_deleted IS NOT FALSE THEN 'inactive_or_unknown_pupil'
    WHEN NOT d.is_score_applicable THEN 'not_applicable'
    WHEN l.session_id IS NULL THEN 'no_eligible_assessment'
    ELSE 'scored'
  END AS score_status,
  CASE WHEN l.session_id IS NOT NULL AND p.is_deleted IS FALSE
      AND d.is_score_applicable
    THEN CAST(ROUND(80 + 40 * SAFE_DIVIDE(l.correct_count, l.question_count)) AS INT64)
  END AS sats_score_proxy,
  SAFE_DIVIDE(l.correct_count, l.question_count) AS accuracy,
  COALESCE(l.question_count, 0) AS question_count,
  COALESCE(l.correct_count, 0) AS correct_count,
  COALESCE(l.no_attempt_count, 0) AS no_attempt_count,
  l.session_id AS selected_session_id,
  l.finished_at AS assessment_finished_at,
  l.last_answered_at,
  l.year_group_at_sitting
FROM `atom-analytics-candidates.daniel_chen.stg_pupils` AS p
CROSS JOIN `atom-analytics-candidates.daniel_chen.dim_subjects` AS d
LEFT JOIN latest AS l ON p.pupil_id = l.pupil_id AND d.subject_id = l.subject_id;

-- Validate before publishing this run.
ASSERT (
  SELECT COUNT(*) FROM pupil_subject_scores
) = (
  SELECT COUNT(*) FROM `atom-analytics-candidates.daniel_chen.stg_pupils`
) * (
  SELECT COUNT(*) FROM `atom-analytics-candidates.daniel_chen.dim_subjects`
) AS 'Output must cover every pupil and subject';

ASSERT NOT EXISTS (
  SELECT 1 FROM pupil_subject_scores
  WHERE (score_status = 'scored' AND (
    sats_score_proxy IS NULL OR sats_score_proxy NOT BETWEEN 80 AND 120
    OR question_count < 1 OR correct_count > question_count
    OR assessment_finished_at > score_as_of OR last_answered_at > score_as_of
  )) OR (score_status <> 'scored' AND sats_score_proxy IS NOT NULL)
) AS 'Scores must be bounded, supported by evidence and within the cutoff';

-- Audit/intermediate tables show the most recent script run only.
CREATE OR REPLACE TABLE `atom-analytics-candidates.daniel_chen.audit_response_status`
CLUSTER BY response_status AS
SELECT score_as_of AS as_of_at, score_model_version AS model_version,
  response_status, COUNT(*) AS canonical_response_count
FROM response_audit
GROUP BY response_status;

CREATE OR REPLACE TABLE `atom-analytics-candidates.daniel_chen.audit_sitting_quality`
CLUSTER BY sitting_status, pupil_id AS
SELECT * FROM sitting_quality;

CREATE OR REPLACE TABLE `atom-analytics-candidates.daniel_chen.fct_sitting_subject_scores`
PARTITION BY DATE(finished_at)
CLUSTER BY pupil_id, subject_id AS
SELECT * FROM sitting_subject_scores;

-- Preserve other cutoff/version snapshots; replace just this run atomically.
CREATE TABLE IF NOT EXISTS `atom-analytics-candidates.daniel_chen.mart_pupil_subject_scores`
PARTITION BY DATE(as_of_at)
CLUSTER BY pupil_id, subject_id AS
SELECT * FROM pupil_subject_scores WHERE FALSE;

BEGIN TRANSACTION;
DELETE FROM `atom-analytics-candidates.daniel_chen.mart_pupil_subject_scores`
WHERE as_of_at = score_as_of AND model_version = score_model_version;

INSERT INTO `atom-analytics-candidates.daniel_chen.mart_pupil_subject_scores` (
  as_of_at, model_version, pupil_id, subject_id, subject_name, score_status,
  sats_score_proxy, accuracy, question_count, correct_count, no_attempt_count,
  selected_session_id, assessment_finished_at, last_answered_at, year_group_at_sitting
)
SELECT as_of_at, model_version, pupil_id, subject_id, subject_name, score_status,
  sats_score_proxy, accuracy, question_count, correct_count, no_attempt_count,
  selected_session_id, assessment_finished_at, last_answered_at, year_group_at_sitting
FROM pupil_subject_scores;
COMMIT TRANSACTION;

-- Small result to review and share, without exporting pupil-level records.
SELECT subject_name, score_status, COUNT(*) AS pupil_count,
  MIN(sats_score_proxy) AS minimum_score, MAX(sats_score_proxy) AS maximum_score
FROM `atom-analytics-candidates.daniel_chen.mart_pupil_subject_scores`
WHERE as_of_at = score_as_of AND model_version = score_model_version
GROUP BY subject_name, score_status
ORDER BY subject_name, score_status;
