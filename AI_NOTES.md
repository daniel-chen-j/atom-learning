# Decisions made with AI assistance

AI helped with source profiling, model design, SQL, local tests and documentation. I ran the BigQuery queries and shared the schemas and results. The assistant had no direct BigQuery access. These notes summarise the decisions made during that work.

| Choice | Reason and tradeoff |
|---|---|
| Keep one answer per question position | Repeated positions sometimes had different correctness values. Counting every event would give revised answers extra weight. We chose the latest answer time with response ID as a tie-breaker. Treating these events as revisions remains an assumption. |
| Validate the whole sitting before scoring subjects | Deduplication reconciled 709 completed sittings. Comparing raw counts would reject usable evidence. Checking the whole sitting also avoids comparing a subject's count with an assessment total spanning several subjects. |
| Use the latest eligible sitting | This reflects recent performance without averaging across school years. A rejected recent sitting can leave an older score in place, so the output includes its ID and date. |
| Use a simple linear proxy | The data has no calibrated mark conversions or linked outcomes. `ROUND(80 + 40 × accuracy)` is easy to inspect, but cannot claim the meaning of an official SATs score. |
| Keep missing scores null | Filling gaps with 80 or 100 would invent attainment. Building the subject list from the hierarchy preserves Science despite its lack of answers. Wellbeing gets a separate not-applicable status because it is a survey. |
| Apply the cutoff before selecting revisions | A later answer must not hide one that existed at the cutoff. Keeping every version supports this. The one-second finish tolerance follows the observed timestamps and never extends the cutoff. |
| Separate evidence from score conversion | Reusable sitting and subject counts let another model use the same validated evidence. A full refresh keeps this small extract easy to review. Incremental processing and stronger source history are deferred. |

AI review exposed validation gaps that could accept null counts, inconsistent calculations, an older eligible score or an incorrect missing-score status. Script 07 now checks each row against its expected status and latest eligible evidence.

These changes affect validation only. Local checks passed and I confirmed that the revised script also passed in BigQuery. The [README](README.md) records the results and remaining limits.
