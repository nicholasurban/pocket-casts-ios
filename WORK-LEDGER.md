# Work Ledger

Repo: `/Users/urbs/Apps/pocket-casts-ios`

Machine source: `WORK-LEDGER.jsonl`

## Changelog

| Updated | ID | Status | Surface | Request | Shipped In | Verification | Verified By |
|---|---|---|---|---|---|---|---|
| 2026-07-30T16:03:29-07:00 | PCI-001 | in-progress | Simulator + throwaway account; sync drain fixed and verified; production run awaiting Nick's deletions | Complete the full Overcast to Pocket Casts migration end to end, overcoming obstacles until it is verified. | 7d674965d:codex/overcast-migration | /Users/urbs/Documents/Overcast Migration 2026-07-29 production-ready/manifest.json; /Users/urbs/Documents/Pocket Casts Overcast QA Evidence 2026-07-29 62-show/OvercastMigrationQACompleteReport.txt<br>/Users/urbs/Documents/Pocket Casts Overcast QA Evidence 2026-07-29 Full Historical/OvercastMigrationQACompleteReport.txt; make test_staging ONLY_TESTING=PocketCastsTests/OvercastMigrationTests (8/8); make build_staging (BUILD SUCCEEDED)<br>scripts/overcast-source-stability.py STABLE run; scripts/pocketcasts-account-audit.py --expect-empty EMPTY (0 subs/queue/stars/history/filters, 2026-07-30)<br>Probe 2026-07-30: local import correct (62 subs, 133 stars, 10038 positions) but server received 62 subs / 18 stars / 0 history; 16210 rows still queued per scripts/pocketcasts-pending-sync.py<br>Probe 2026-07-30 15:41: drained after 5 sync passes; server shows 62 subs / 133 stars / 27 filters / 4-item queue in exact order; scripts/pocketcasts-pending-sync.py reports 0 pending | Direct read of api.pocketcasts.com plus the app's podcast_newDB.sqlite3 |

## OPEN / NOT-DONE

| ID | Status | Surface | Request | Proof still missing | Reopens |
|---|---|---|---|---|---|
| PCI-001 | in-progress | Simulator + throwaway account; sync drain fixed and verified; production run awaiting Nick's deletions | Complete the full Overcast to Pocket Casts migration end to end, overcoming obstacles until it is verified. | Not marked done | 0 |
