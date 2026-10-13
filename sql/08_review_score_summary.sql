-- GoogleSQL. One read-only SELECT: results appear as a single result table.
-- Use europe-west2. Keep the cutoff/version aligned with the snapshot to review.
SELECT
  subject_id,
  subject_name,
  COUNT(*) AS pupil_subject_rows,
  COUNTIF(score_status = 'scored') AS scored_pupils,
  COUNTIF(score_status = 'no_eligible_assessment') AS no_evidence_pupils,
  COUNTIF(score_status = 'not_applicable') AS not_applicable_pupils,
  COUNTIF(score_status = 'inactive_or_unknown_pupil') AS inactive_pupils,
  MIN(sats_score_proxy) AS minimum_score,
  MAX(sats_score_proxy) AS maximum_score
FROM `atom-analytics-candidates.daniel_chen.mart_pupil_subject_scores`
WHERE as_of_at = TIMESTAMP '2026-09-17 00:00:00+00'
  AND model_version = 'latest_sitting_linear_v1'
GROUP BY subject_id, subject_name
ORDER BY subject_name, subject_id;
