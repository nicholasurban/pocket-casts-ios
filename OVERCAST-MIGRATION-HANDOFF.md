# Overcast Migration Handoff

Last verified: 2026-07-29 14:20 PDT

## Durable state

- Branch: `codex/overcast-migration`
- Latest pushed checkpoint before this handoff: `8602529d2`
- Migration implementation checkpoint: `c1378ee979288bb2dac7d4a3f0f98de8ddecf303`
- QA feed-drift isolation: `7d674965d`
- Checkout was clean after the checkpoints above.
- Work item `PCI-001` remains `in-progress`; do not mark it done until the live-account migration and reconciliation finish.

## Verification already passed

- `make test_staging ONLY_TESTING=PocketCastsTests/OvercastMigrationTests`
  passed 8 tests with 0 failures.
- `make build_staging` ended with `BUILD SUCCEEDED`.
- A full-history disposable-simulator rehearsal completed.
- Preserved evidence:
  `/Users/urbs/Documents/Pocket Casts Overcast QA Evidence 2026-07-29 Full Historical`
- Rehearsal report:
  `/Users/urbs/Documents/Pocket Casts Overcast QA Evidence 2026-07-29 Full Historical/OvercastMigrationQACompleteReport.txt`
- Important post-refresh results: 62 subscriptions matched, 0 unresolved
  subscriptions, 148 old shows verified unsubscribed, exact six-item queue
  order verified, 24 playlist snapshots verified, 9,979 playback states,
  132 stars, 82 listening-history dates, and one preserved audio file verified.

## Source state and required next action

- Overcast database:
  `/Users/urbs/Library/Containers/4CCCADE0-33F2-45A3-8E1B-B96EF6247C5C/Data/Documents/db.sqlite`
- Nick deleted more episodes on his phone after the previous production bundle
  was generated. The existing
  `/Users/urbs/Documents/Overcast Migration 2026-07-29 production-ready`
  bundle is therefore rehearsal evidence only, not the final live source.
- Overcast is running as an iOS App-on-Mac wrapper. Wait until the database,
  WAL, counts, and hashes stabilize after sync. Then regenerate and audit a
  fresh final bundle with `scripts/overcast-migration-export.py`.
- Do not export while the source database is changing.

## Live-account boundary

- The paired iPhone is named `Android 2`.
- CoreDevice ID: `D45F1E9B-64FD-5695-8964-7C2433A7E7E4`
- Device UDID: `00008140-0012519111FB001C`
- The App Store Pocket Casts install must remain untouched.
- Prepare a side-by-side, separately signed migration build. Never create or
  revoke a signing certificate.
- Immediately before provisioning/installing the side-by-side build or making
  any live-account migration writes, obtain Nick's explicit approval.
- After approval: create a native Pocket Casts backup before writes, import the
  fresh audited bundle, complete sync, perform a second sync/readback, preserve
  the report/database/backup, and reconcile subscriptions, queue order,
  playlists, playback state, stars, history, show settings, and preserved audio.
- Retain Overcast and the frozen migration bundle for rollback confidence.

## Operating constraints

- Preserve dirty/user-owned work and the repo ledger.
- Do not rely on GitHub Actions.
- Do not rerun passed native gates merely for telemetry.
- The earlier `outliyr-proof-gate` pilot wrapper was infrastructure-stuck;
  preserve that fact and do not rerun it solely for telemetry.
