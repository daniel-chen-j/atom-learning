-- GoogleSQL / BigQuery. Read-only. Run in europe-west2.
-- Review estimated bytes in the console before execution.
-- One result table: section, metric, value. Each metric names its counting unit.
-- Purpose: resolve question-vs-position grain, quantify finish-time offsets,
-- and include sittings that were invisible to the response-based profile.
-- Does not choose a deduplication or exclusion rule.
-- Repeat metrics count groups; late-response metrics count individual rows.
-- All flags use the current source snapshot, without a historical cutoff.
-- The fewer-response sitting count includes sittings with zero response rows.

WITH per_question AS (
  SELECT
    pupil_id, session_id, question_id,
    COUNT(*) AS response_rows,
    COUNT(DISTINCT question_number) AS distinct_positions,
    COUNT(DISTINCT is_correct) AS distinct_correctness_values
  FROM `atom-analytics-candidates.de_raw.responses`
  GROUP BY pupil_id, session_id, question_id
),
question_grain AS (
  SELECT
    COUNTIF(response_rows > 1) AS repeated_question_groups,
    COUNTIF(response_rows > 1 AND distinct_positions > 1)
      AS repeated_question_groups_with_multiple_positions,
    COUNTIF(response_rows > 1 AND distinct_correctness_values > 1)
      AS repeated_question_groups_with_different_correctness,
    COALESCE(SUM(response_rows - 1), 0) AS extra_rows_beyond_one_per_question
  FROM per_question
),
per_position AS (
  SELECT
    pupil_id, session_id, question_number,
    COUNT(*) AS response_rows,
    COUNT(DISTINCT question_id) AS distinct_questions,
    COUNT(DISTINCT is_correct) AS distinct_correctness_values
  FROM `atom-analytics-candidates.de_raw.responses`
  WHERE question_number IS NOT NULL
  GROUP BY pupil_id, session_id, question_number
),
position_grain AS (
  SELECT
    COUNTIF(response_rows > 1) AS repeated_position_groups,
    COUNTIF(response_rows > 1 AND distinct_questions > 1)
      AS repeated_position_groups_with_different_questions,
    COUNTIF(response_rows > 1 AND distinct_correctness_values > 1)
      AS repeated_position_groups_with_different_correctness,
    COALESCE(SUM(response_rows - 1), 0) AS extra_rows_beyond_one_per_position
  FROM per_position
),
response_fields AS (
  SELECT
    COUNTIF(question_number IS NULL) AS responses_without_question_number,
    MIN(question_number) AS lowest_question_number,
    MAX(question_number) AS highest_question_number
  FROM `atom-analytics-candidates.de_raw.responses`
),
per_session AS (
  SELECT
    session_id,
    COUNT(*) AS response_rows,
    COUNT(DISTINCT question_id) AS distinct_questions,
    COUNT(DISTINCT question_number) AS distinct_positions
  FROM `atom-analytics-candidates.de_raw.responses`
  GROUP BY session_id
),
sitting_inventory AS (
  SELECT
    COUNT(*) AS total_sittings,
    COUNTIF(r.session_id IS NULL) AS sittings_without_responses,
    COUNTIF(r.session_id IS NULL AND s.is_complete IS TRUE)
      AS complete_sittings_without_responses,
    COUNTIF(r.session_id IS NULL AND s.is_complete IS FALSE)
      AS incomplete_sittings_without_responses,
    COUNTIF(r.session_id IS NULL AND s.started_at IS NULL)
      AS sittings_without_responses_and_start_time,
    COUNTIF(s.is_complete IS TRUE AND r.response_rows > s.total_questions)
      AS complete_sittings_with_extra_response_rows,
    COUNTIF(s.is_complete IS TRUE AND COALESCE(r.response_rows, 0) < s.total_questions)
      AS complete_sittings_with_fewer_response_rows,
    COUNTIF(s.is_complete IS TRUE AND r.response_rows <> s.total_questions
      AND r.distinct_questions = s.total_questions)
      AS complete_mismatched_sittings_matching_unique_questions,
    COUNTIF(s.is_complete IS TRUE AND r.response_rows <> s.total_questions
      AND r.distinct_positions = s.total_questions)
      AS complete_mismatched_sittings_matching_unique_positions
  FROM `atom-analytics-candidates.de_raw.assessment_sittings` AS s
  LEFT JOIN per_session AS r ON s.session_id = r.session_id
),
late_answers AS (
  SELECT TIMESTAMP_DIFF(r.answered_at, s.finished_at, MICROSECOND) AS delay_us
  FROM `atom-analytics-candidates.de_raw.responses` AS r
  JOIN `atom-analytics-candidates.de_raw.assessment_sittings` AS s
    ON r.session_id = s.session_id
  WHERE s.is_complete IS TRUE
    AND r.answered_at > s.finished_at
),
timing AS (
  SELECT
    COUNT(*) AS responses_after_finish,
    COUNTIF(delay_us <= 5000000) AS responses_after_finish_up_to_5_seconds,
    COUNTIF(delay_us > 5000000 AND delay_us <= 60000000)
      AS responses_after_finish_over_5_to_60_seconds,
    COUNTIF(delay_us > 60000000 AND delay_us <= 300000000)
      AS responses_after_finish_over_1_to_5_minutes,
    COUNTIF(delay_us > 300000000) AS responses_after_finish_over_5_minutes,
    MAX(delay_us) AS longest_delay_microseconds
  FROM late_answers
),
observations AS (
  SELECT 'question_grain' AS section, metric, value
  FROM question_grain
  UNPIVOT INCLUDE NULLS (value FOR metric IN (
    repeated_question_groups,
    repeated_question_groups_with_multiple_positions,
    repeated_question_groups_with_different_correctness,
    extra_rows_beyond_one_per_question
  ))
  UNION ALL
  SELECT 'position_grain', metric, value
  FROM position_grain
  UNPIVOT INCLUDE NULLS (value FOR metric IN (
    repeated_position_groups,
    repeated_position_groups_with_different_questions,
    repeated_position_groups_with_different_correctness,
    extra_rows_beyond_one_per_position
  ))
  UNION ALL
  SELECT 'response_fields', metric, value
  FROM response_fields
  UNPIVOT INCLUDE NULLS (value FOR metric IN (
    responses_without_question_number, lowest_question_number, highest_question_number
  ))
  UNION ALL
  SELECT 'sitting_inventory', metric, value
  FROM sitting_inventory
  UNPIVOT INCLUDE NULLS (value FOR metric IN (
    total_sittings,
    sittings_without_responses,
    complete_sittings_without_responses,
    incomplete_sittings_without_responses,
    sittings_without_responses_and_start_time,
    complete_sittings_with_extra_response_rows,
    complete_sittings_with_fewer_response_rows,
    complete_mismatched_sittings_matching_unique_questions,
    complete_mismatched_sittings_matching_unique_positions
  ))
  UNION ALL
  SELECT 'timing', metric, value
  FROM timing
  UNPIVOT INCLUDE NULLS (value FOR metric IN (
    responses_after_finish,
    responses_after_finish_up_to_5_seconds,
    responses_after_finish_over_5_to_60_seconds,
    responses_after_finish_over_1_to_5_minutes,
    responses_after_finish_over_5_minutes,
    longest_delay_microseconds
  ))
)
SELECT section, metric, value
FROM observations
ORDER BY section, metric;
