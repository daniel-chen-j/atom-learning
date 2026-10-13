-- GoogleSQL. Read-only. Run directly after 06, with the same cutoff/version.
DECLARE score_as_of TIMESTAMP DEFAULT TIMESTAMP '2026-09-17 00:00:00+00';
DECLARE score_model_version STRING DEFAULT 'latest_sitting_linear_v1';

CREATE TEMP TABLE output AS
SELECT * FROM `atom-analytics-candidates.daniel_chen.mart_pupil_subject_scores`
WHERE as_of_at = score_as_of AND model_version = score_model_version;

ASSERT (SELECT COUNT(*) FROM output) > 0 AS 'Requested snapshot must exist';

ASSERT NOT EXISTS (
  SELECT pupil_id, subject_id FROM output
  GROUP BY pupil_id, subject_id HAVING COUNT(*) <> 1
) AS 'Snapshot grain must be one row per pupil and subject';

ASSERT NOT EXISTS (
  SELECT p.pupil_id, d.subject_id
  FROM `atom-analytics-candidates.daniel_chen.stg_pupils` AS p
  CROSS JOIN `atom-analytics-candidates.daniel_chen.dim_subjects` AS d
  LEFT JOIN output AS o ON p.pupil_id = o.pupil_id AND d.subject_id = o.subject_id
  WHERE o.pupil_id IS NULL
) AS 'No pupil-subject combinations may be missing';

ASSERT (SELECT COUNT(*) FROM output) = (
  SELECT COUNT(*) FROM `atom-analytics-candidates.daniel_chen.stg_pupils`
) * (
  SELECT COUNT(*) FROM `atom-analytics-candidates.daniel_chen.dim_subjects`
) AS 'Snapshot must not contain unexpected combinations';

ASSERT NOT EXISTS (
  SELECT 1 FROM output
  WHERE score_status IS NULL
    OR score_status NOT IN ('scored', 'no_eligible_assessment', 'not_applicable',
      'inactive_or_unknown_pupil')
    OR question_count IS NULL OR correct_count IS NULL OR no_attempt_count IS NULL
    OR (score_status = 'scored' AND (
      sats_score_proxy IS NULL OR sats_score_proxy NOT BETWEEN 80 AND 120
      OR question_count <= 0 OR correct_count < 0 OR no_attempt_count < 0
      OR correct_count + no_attempt_count > question_count
      OR accuracy IS NULL OR accuracy NOT BETWEEN 0 AND 1
      OR accuracy IS DISTINCT FROM SAFE_DIVIDE(correct_count, question_count)
      OR sats_score_proxy <> CAST(ROUND(80 + 40 * accuracy) AS INT64)
      OR selected_session_id IS NULL OR assessment_finished_at IS NULL
      OR last_answered_at IS NULL OR assessment_finished_at > score_as_of
      OR last_answered_at > score_as_of
      OR last_answered_at > TIMESTAMP_ADD(assessment_finished_at, INTERVAL 1 SECOND)
    ))
    OR (score_status <> 'scored' AND (
      sats_score_proxy IS NOT NULL OR accuracy IS NOT NULL OR question_count <> 0
      OR correct_count <> 0 OR no_attempt_count <> 0
      OR selected_session_id IS NOT NULL
    ))
) AS 'Score status, evidence, range and timing must agree';

-- Intermediate tables represent the last build, not all historical snapshots.
ASSERT NOT EXISTS (
  SELECT 1 FROM `atom-analytics-candidates.daniel_chen.audit_sitting_quality`
  WHERE as_of_at <> score_as_of OR model_version <> score_model_version
) AS 'Run 06 for this cutoff before validating intermediate tables';

ASSERT NOT EXISTS (
  SELECT 1 FROM output AS o
  LEFT JOIN `atom-analytics-candidates.daniel_chen.audit_sitting_quality` AS a
    ON o.selected_session_id = a.session_id
  WHERE o.score_status = 'scored'
    AND (a.session_id IS NULL OR a.sitting_status <> 'eligible'
      OR a.pupil_id <> o.pupil_id OR a.canonical_response_count <> a.total_questions)
) AS 'Every score must come from an eligible reconciled sitting';

-- Reconcile every status and selected sitting, including rows with no score.
-- Matching any eligible fact is insufficient: it must be the latest eligible fact.
ASSERT NOT EXISTS (
  WITH latest AS (
    SELECT *
    FROM `atom-analytics-candidates.daniel_chen.fct_sitting_subject_scores`
    WHERE as_of_at = score_as_of AND model_version = score_model_version
    QUALIFY ROW_NUMBER() OVER (
      PARTITION BY pupil_id, subject_id
      ORDER BY finished_at DESC, session_id DESC
    ) = 1
  )
  SELECT 1 FROM output AS o
  JOIN `atom-analytics-candidates.daniel_chen.stg_pupils` AS p
    ON o.pupil_id = p.pupil_id
  JOIN `atom-analytics-candidates.daniel_chen.dim_subjects` AS d
    ON o.subject_id = d.subject_id
  LEFT JOIN latest AS f
    ON o.pupil_id = f.pupil_id AND o.subject_id = f.subject_id
    AND p.is_deleted IS FALSE AND d.is_score_applicable
  WHERE o.score_status IS DISTINCT FROM CASE
      WHEN p.is_deleted IS NOT FALSE THEN 'inactive_or_unknown_pupil'
      WHEN NOT d.is_score_applicable THEN 'not_applicable'
      WHEN f.session_id IS NULL THEN 'no_eligible_assessment'
      ELSE 'scored'
    END
    OR o.selected_session_id IS DISTINCT FROM f.session_id
    OR o.question_count IS DISTINCT FROM COALESCE(f.question_count, 0)
    OR o.correct_count IS DISTINCT FROM COALESCE(f.correct_count, 0)
    OR o.no_attempt_count IS DISTINCT FROM COALESCE(f.no_attempt_count, 0)
    OR o.assessment_finished_at IS DISTINCT FROM f.finished_at
    OR o.last_answered_at IS DISTINCT FROM f.last_answered_at
    OR o.year_group_at_sitting IS DISTINCT FROM f.year_group_at_sitting
) AS 'Every row must match its expected status and latest sitting subject evidence';

SELECT 'PASS' AS validation_status,
  score_as_of AS as_of_at, score_model_version AS model_version,
  COUNT(*) AS pupil_subject_rows,
  COUNTIF(score_status = 'scored') AS scored_rows,
  COUNTIF(score_status = 'no_eligible_assessment') AS no_evidence_rows,
  COUNTIF(score_status = 'not_applicable') AS not_applicable_rows,
  COUNTIF(score_status = 'inactive_or_unknown_pupil') AS inactive_pupil_rows
FROM output;
