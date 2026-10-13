-- GoogleSQL. One read-only SELECT, run in europe-west2 AFTER 09 then 06.
-- Keep staging and the 06 cutoff/version unchanged between the two builds.
-- Compares every output column in both directions, including NULLs.
-- Counts and duplicate-key checks prevent set comparison from hiding duplicates.
-- A PASS compares the saved snapshot with the current snapshot. The separate
-- rerun job ID is evidence that 06 was actually run between capture and comparison.
WITH run_parameters AS (
  SELECT TIMESTAMP '2026-09-17 00:00:00+00' AS as_of_at,
    'latest_sitting_linear_v1' AS model_version
),
baseline AS (
  SELECT b.*
  FROM `atom-analytics-candidates.daniel_chen.audit_repeatability_baseline` AS b
  JOIN run_parameters AS p
    ON b.as_of_at = p.as_of_at AND b.model_version = p.model_version
),
rerun AS (
  SELECT m.*
  FROM `atom-analytics-candidates.daniel_chen.mart_pupil_subject_scores` AS m
  JOIN run_parameters AS p
    ON m.as_of_at = p.as_of_at AND m.model_version = p.model_version
),
missing_or_changed AS (
  SELECT * FROM baseline
  EXCEPT DISTINCT
  SELECT * FROM rerun
),
new_or_changed AS (
  SELECT * FROM rerun
  EXCEPT DISTINCT
  SELECT * FROM baseline
),
baseline_duplicates AS (
  SELECT pupil_id, subject_id FROM baseline
  GROUP BY pupil_id, subject_id HAVING COUNT(*) > 1
),
rerun_duplicates AS (
  SELECT pupil_id, subject_id FROM rerun
  GROUP BY pupil_id, subject_id HAVING COUNT(*) > 1
),
comparison AS (
  SELECT
    (SELECT COUNT(*) FROM baseline) AS baseline_rows,
    (SELECT COUNT(*) FROM rerun) AS rerun_rows,
    (SELECT COUNT(*) FROM missing_or_changed) AS missing_or_changed_rows,
    (SELECT COUNT(*) FROM new_or_changed) AS new_or_changed_rows,
    (SELECT COUNT(*) FROM baseline_duplicates) AS baseline_duplicate_key_groups,
    (SELECT COUNT(*) FROM rerun_duplicates) AS rerun_duplicate_key_groups
)
SELECT
  CASE WHEN c.baseline_rows > 0 AND c.baseline_rows = c.rerun_rows
      AND c.missing_or_changed_rows = 0 AND c.new_or_changed_rows = 0
      AND c.baseline_duplicate_key_groups = 0 AND c.rerun_duplicate_key_groups = 0
    THEN 'PASS' ELSE 'FAIL'
  END AS repeatability_status,
  p.as_of_at, p.model_version, c.*
FROM comparison AS c CROSS JOIN run_parameters AS p;
