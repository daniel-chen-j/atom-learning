-- GoogleSQL / BigQuery. Read-only; returns one summary row per source table.
-- Based on the INFORMATION_SCHEMA output supplied by the user.
-- Review the console's estimated bytes before running: this reads source data.
-- Candidate keys are hypotheses, not verified primary-key constraints.
-- Duplicate excess counts non-null key rows beyond the first per exact key;
-- it does not establish that the complete rows are identical.
-- Missing keys include NULL, empty strings, and whitespace-only strings.
-- NULL date results for pupils/course_hierarchy mean no event-time field exists.
-- Aggregation reference:
-- https://docs.cloud.google.com/bigquery/docs/reference/standard-sql/aggregate_functions

WITH profiles AS (
  SELECT
    'responses' AS table_name,
    'response_id' AS candidate_key,
    COUNT(*) AS total_rows,
    COUNT(DISTINCT response_id) AS distinct_non_null_keys,
    COALESCE(COUNTIF(NULLIF(TRIM(response_id), '') IS NULL), 0)
      AS missing_or_blank_key_rows,
    COUNT(response_id) - COUNT(DISTINCT response_id)
      AS duplicate_key_extra_rows,
    'answered_at' AS event_time_column,
    COALESCE(COUNTIF(answered_at IS NULL), 0) AS missing_event_time_rows,
    MIN(answered_at) AS earliest_event_at,
    MAX(answered_at) AS latest_event_at
  FROM `atom-analytics-candidates.de_raw.responses`

  UNION ALL

  SELECT
    'assessment_sittings',
    'session_id',
    COUNT(*),
    COUNT(DISTINCT session_id),
    COALESCE(COUNTIF(NULLIF(TRIM(session_id), '') IS NULL), 0),
    COUNT(session_id) - COUNT(DISTINCT session_id),
    'started_at',
    COALESCE(COUNTIF(started_at IS NULL), 0),
    MIN(started_at),
    MAX(started_at)
  FROM `atom-analytics-candidates.de_raw.assessment_sittings`

  UNION ALL

  SELECT
    'pupils',
    'pupil_id',
    COUNT(*),
    COUNT(DISTINCT pupil_id),
    COALESCE(COUNTIF(NULLIF(TRIM(pupil_id), '') IS NULL), 0),
    COUNT(pupil_id) - COUNT(DISTINCT pupil_id),
    CAST(NULL AS STRING),
    CAST(NULL AS INT64),
    CAST(NULL AS TIMESTAMP),
    CAST(NULL AS TIMESTAMP)
  FROM `atom-analytics-candidates.de_raw.pupils`

  UNION ALL

  SELECT
    'course_hierarchy',
    'question_id',
    COUNT(*),
    COUNT(DISTINCT question_id),
    COALESCE(COUNTIF(NULLIF(TRIM(question_id), '') IS NULL), 0),
    COUNT(question_id) - COUNT(DISTINCT question_id),
    CAST(NULL AS STRING),
    CAST(NULL AS INT64),
    CAST(NULL AS TIMESTAMP),
    CAST(NULL AS TIMESTAMP)
  FROM `atom-analytics-candidates.de_raw.course_hierarchy`
)
SELECT *
FROM profiles
ORDER BY table_name;
