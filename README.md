# Atom Learning assessment scoring

This project builds a score from 80 to 120 using each pupil's latest eligible assessment in each subject. Every pupil has a row for every subject, with a status explaining any missing score.

## Run in BigQuery

1. [05_prepare_models.sql](sql/05_prepare_models.sql) creates the staging tables and subject dimension.
2. [06_build_scores.sql](sql/06_build_scores.sql) builds the audit tables, sitting facts and final snapshot.
3. [07_validate_scores.sql](sql/07_validate_scores.sql) checks coverage, calculations, statuses and latest eligible evidence.
4. [08_review_score_summary.sql](sql/08_review_score_summary.sql) returns counts and score ranges by subject.

Run each file in full and continue only after it succeeds. The models are already materialised, so start with 07 and 08 to inspect them. Scripts 01 to 04 contain the source profiling queries.

For another cutoff, update `score_as_of` and rerun 06 and 07. Match the cutoff and model version in any summary or repeatability queries. Refresh staging with 05 only when the source extract should change. Run builds one at a time because intermediate tables hold only the latest run.

To check repeatability, run [09](sql/09_save_repeatability_baseline.sql), rerun 06 with unchanged staging and settings, then run [10](sql/10_check_repeatability.sql). The baseline already exists, so choose a new table name in both 09 and 10 for a fresh comparison. Keep the rerun job ID. The comparison checks all columns, row counts and duplicate keys.

## Model structure

| Models | Purpose |
|---|---|
| `stg_pupils`, `stg_questions`, `stg_sittings` | One row per source entity, retaining IDs and flags. |
| `stg_response_versions` | Every answer version, partitioned by answer date and clustered by pupil, session and position. |
| `dim_subjects` | All subjects from the hierarchy, including those without responses. |
| `audit_response_status`, `audit_sitting_quality` | Response validation totals and one eligibility record per sitting. |
| `fct_sitting_subject_scores` | Reusable counts for each eligible pupil, sitting and subject. |
| `mart_pupil_subject_scores` | Final scores and evidence for each pupil, subject, cutoff and model version. |

Answers are deduplicated before checking whole sittings. Eligible sittings are grouped by subject, then the latest is selected for each pupil and subject.

## Scoring choices

```text
accuracy = correct questions / all question positions
sats_score_proxy = ROUND(80 + 40 × accuracy)
```

Each question is worth one mark. Recorded non-attempts stay in the denominator with zero credit. The latest eligible completed sitting reflects recent performance. Ties use descending session ID.

**This is an uncalibrated proxy, not an official SATs score.** A score of 100 means 50% correct here. [Official conversions](https://www.gov.uk/guidance/understanding-scaled-scores-at-key-stage-2) depend on the test. The source lacks calibration outcomes and the formula does not adjust for year group, difficulty or subject. One usable question is enough to score, so the output retains question counts and assessment dates.

Missing scores stay `NULL` with status `no_eligible_assessment`, `not_applicable` for Wellbeing surveys or `inactive_or_unknown_pupil`. This interprets full coverage as a row for every combination without inventing attainment. That interpretation needs agreement before application use.

## Data quality

The extract contains 63,707 responses, 2,509 sittings, 242 pupils and 10,552 questions. All four checked source keys are unique and populated.

| Finding | Handling |
|---|---|
| 2,411 excess responses across 2,082 repeated positions, including 965 groups with different correctness | Treat them as revisions. Keep the latest `answered_at`, then descending `response_id`, per `(pupil_id, session_id, question_number)`. The upstream cause is unconfirmed. |
| Deduplication reconciles 709 completed sittings | Require valid positions and a count matching the whole sitting's declared total. Reject a sitting if any canonical response is invalid. |
| 1,433 responses lack sittings and 79 sittings have no responses | Exclude unsupported evidence and retain audit reasons. |
| 13 incomplete sittings and 12 missing start times | Require completion and a finish by the cutoff. A missing start alone does not exclude otherwise valid evidence. |
| 1,608 answers occur after completion, all within one second | Allow `finished_at + 1 second` while still enforcing the cutoff. |
| Science has no answers and Wellbeing is a survey | Keep both subjects in the output. Science has no eligible evidence and Wellbeing is not applicable. |

Only active pupils and complete, undeleted `fixed_question` sittings of type `summative_assessment` qualify. Response type must be `MOCK_TEST`. Recorded non-attempts differ from missing responses. If the latest sitting fails validation, an older eligible sitting can supply the score.

## Recorded results

The BigQuery snapshot has **1,694 rows across 242 pupils and seven subjects**. There are 397 scored combinations, 1,055 without eligible evidence, 242 not applicable and no inactive pupils.

| Subject | Scored | No eligible evidence | Not applicable | Score range |
|---|---|---|---|---|
| English | 153 | 89 | 0 | 81 to 120 |
| Maths | 151 | 91 | 0 | 81 to 119 |
| Non-Verbal Reasoning | 3 | 239 | 0 | 102 to 108 |
| Science | 0 | 242 | 0 | No scores |
| Screeners | 82 | 160 | 0 | 80 to 120 |
| Verbal Reasoning | 8 | 234 | 0 | 88 to 116 |
| Wellbeing | 0 | 0 | 242 | Not applicable |

The candidate confirmed that the revised script 07 passed all eight assertions in BigQuery. Local checks also passed. The recorded repeatability check returned 1,694 rows in each snapshot with no differences or duplicate keys. Job IDs have not been supplied.

## History, scale and application use

Filter answer versions to the inclusive UTC cutoff before ranking them and require the sitting to have finished by then. A transaction replaces only the matching cutoff and model version in the final table.

Historical scores use the current staged extract. Without ingestion timestamps, deletion histories or dimension versions, later corrections can change a historical rebuild. Strict reproduction needs immutable source snapshots plus code and model versions.

The current full refresh is for the supplied extract and has not been benchmarked at 100 million responses. At that scale, add ingestion watermarks, preserve revision history and reprocess affected sessions and pupils, including backfills and dimension changes. Partitioning alone does not make the build incremental.

For an application database, enforce `(pupil_id, subject_id, as_of_at, model_version)` as the key. Scores are nullable integers with counts, selected sitting and UTC timestamps alongside them. Publish one cutoff and version together. Keep missing scores null.

## Optional GCSE extension

Link primary activity to later GCSE outcomes and train only on information available before prediction. Start with a simple baseline, evaluate on held-out pupils and later cohorts and check calibration across schools and pupil groups. Report uncertainty. The supplied data has no GCSE labels, so this remains a proposal.

[AI_NOTES.md](AI_NOTES.md) records the main decisions made with AI assistance.
