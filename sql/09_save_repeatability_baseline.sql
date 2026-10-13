-- GoogleSQL. Run once in europe-west2 BEFORE rerunning 06_build_scores.sql.
-- Order: 09 -> 06 (same cutoff/version, unchanged staging) -> 10.
-- CREATE TABLE deliberately fails if this baseline already exists, so an
-- accidental rerun cannot overwrite the original comparison evidence.
DECLARE score_as_of TIMESTAMP DEFAULT TIMESTAMP '2026-09-17 00:00:00+00';
DECLARE score_model_version STRING DEFAULT 'latest_sitting_linear_v1';

ASSERT EXISTS (
  SELECT 1 FROM `atom-analytics-candidates.daniel_chen.mart_pupil_subject_scores`
  WHERE as_of_at = score_as_of AND model_version = score_model_version
) AS 'Build and validate the requested snapshot before capturing a baseline';

CREATE TABLE `atom-analytics-candidates.daniel_chen.audit_repeatability_baseline` AS
SELECT * FROM `atom-analytics-candidates.daniel_chen.mart_pupil_subject_scores`
WHERE as_of_at = score_as_of AND model_version = score_model_version;

SELECT 'BASELINE_SAVED' AS capture_status,
  score_as_of AS as_of_at, score_model_version AS model_version,
  COUNT(*) AS baseline_rows
FROM `atom-analytics-candidates.daniel_chen.audit_repeatability_baseline`;
