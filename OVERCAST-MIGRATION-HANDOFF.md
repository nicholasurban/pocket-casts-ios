# Overcast Migration Handoff

Last verified: 2026-07-30 13:45 PDT

## Where this stands

The migration is built, tested, and rehearsed. It is waiting on Nick, who is
still deleting shows in Overcast. Nothing should be exported or run until he
says he is finished.

Work item `PCI-001` remains `in-progress`. Do not mark it done until the live
migration and its server-side reconciliation have both completed.

## The plan changed on 2026-07-30

The earlier plan installed a separately signed side-by-side build on Nick's
iPhone. **That is no longer necessary and should not be done.**

The importer writes local rows flagged `notSynced` and then asks Pocket Casts
to sync. The account, not the device, is what carries the migration. So a
simulator on this Mac signs into the real account, uploads everything, and the
iPhone's untouched App Store install pulls it down as a normal sync.

Consequences:

- No build is installed on the iPhone. The App Store app is never touched.
- No signing certificate or provisioning profile is created or revoked.
- Downloaded audio is the one thing that does not travel this way. Exactly one
  preserved file is affected; it can be re-downloaded in the app.

## Live account

- Account: `nurban01@gmail.com`, confirmed working against `api.pocketcasts.com`.
- Credentials live in `~/.claude/.env` as `POCKETCASTS_EMAIL` and
  `POCKETCASTS_PASSWORD`. They are not in this repository.
- Tier: free. Not Plus.
- **The account is completely empty**: 0 subscriptions, 0 Up Next, 0 starred,
  0 history, 0 filters, verified 2026-07-30 against the server.

Because it is empty, it doubles as its own clean room. A probe run can upload,
be verified, and be cleared without risking anything Nick cares about.

## Decisions Nick has made

- **The 568 unmatched episode play-states are accepted.** No further matching
  work. They are old episodes whose feeds rewrote their audio URLs or dropped
  them. Overcast stays installed as the fallback.
- **Simulator-to-account approach approved** over installing on the phone.
- **Account treated as empty**, so the migration replaces rather than merges.

## What was added on 2026-07-30

| Path | Purpose |
|---|---|
| `scripts/overcast-source-stability.py` | Reports whether the Overcast database has stopped changing. Exit 0 stable, 1 changing, 2 unreadable. |
| `scripts/pocketcasts-account-audit.py` | Reads the account from the sync server. The only honest proof the upload happened. |
| `scripts/overcast-migration-run.sh` | Single entry point: stability, export, build, install, sign in, import, server read-back. |
| `--overcast-migration-full-production` | Production launch argument; imports all preserved audio. |
| `OvercastMigration.signInFromEnvironmentIfNeeded()` | Headless sign-in from the environment, so no simulator GUI work is needed. |

A production run now **aborts** if credentials are absent. Previously a
signed-out run would import locally, upload nothing, and still write a
healthy-looking reconciliation report.

## RESOLVED — the upload now finishes (2026-07-30)

The first probe uploaded only a fraction of the migration while every local
number looked perfect: the server received 62 subscriptions but only 18 of 133
stars and roughly 3,221 of 10,038 playback positions.

**Cause:** `ServerConstants.Limits.maxEpisodesToSync` is 2000 on iOS, so one
sync pass uploads at most 2000 episodes. A migration modifies about ten
thousand. `OvercastMigrationRunner` triggered exactly one
`RefreshManager.refreshPodcasts`, received a success callback, and completed.
Nothing drove the remaining passes.

**Fix:** `OvercastMigrationRunner.drainSyncQueue` repeats the sync until
`DataManager.unsyncedEpisodes` returns empty, logging each pass. It caps at 250
passes and *fails loudly* rather than accepting a partial upload. Recovery
after such a failure is more syncing, not re-importing.

**Verified** on the 2026-07-30 15:41 probe — drained after 5 passes:

| State | Simulator database | Reached the server |
|---|---|---|
| Subscriptions | 62 | 62 ✅ |
| Up Next, exact order | 4 | 4 ✅ |
| Filters | 27 | 27 ✅ |
| Starred episodes | 133 | 133 ✅ |
| Playback positions | 10,038 | uploaded, queue empty ✅ |
| Listening-history dates | 112 | not synced — see below |

`scripts/pocketcasts-pending-sync.py` reports `pending upload: 0`.

### Listening history does not sync, by Pocket Casts' design

`SyncTask+LocalChanges.changedEpisodes` uploads playing status, starred,
playback position, duration and archived state. It sends no history dates, and
`SyncTask.swift` references history nowhere. `episodesWithListenHistory` is
used only by `ShareProfileViewModel`.

So the ~112 restored history dates live on whichever device ran the import and
never reach the account. Everything that determines what Nick actually sees —
subscriptions, queue order, played/unplayed, positions, stars, filters — does
sync. This is a limitation to accept, not a defect to fix; the only way to put
history on the phone would be running the import on the phone itself, which is
the side-by-side install this plan deliberately avoids.

### Watch out: `starredModified` is not a pending flag

`scripts/pocketcasts-pending-sync.py` originally counted
`starredModified > 0` and reported 133 stars stuck while the server already had
all 133. The app's own definition is `keepEpisodeModified`; `starredModified`
is a timestamp that survives a successful upload. The script now mirrors
`EpisodeDataManager.unsyncedEpisodes` exactly.

## Verification already passed

- `make test_staging ONLY_TESTING=PocketCastsTests/OvercastMigrationTests`
  passed 8 tests with 0 failures (2026-07-29).
- `make build_staging` ended with `BUILD SUCCEEDED` (2026-07-29).
- Full-history disposable-simulator rehearsal completed (2026-07-29). Evidence:
  `/Users/urbs/Documents/Pocket Casts Overcast QA Evidence 2026-07-29 Full Historical`
- Post-refresh results: 62 subscriptions matched, 0 unresolved, 148 old shows
  verified unsubscribed, exact six-item queue order, 24 playlist snapshots,
  9,979 playback states, 132 stars, 82 listening-history dates, one preserved
  audio file.

**The rehearsal never signed in and never synced.** It proves the data lands
correctly in a local database. It does not prove the upload. That is what the
probe run exists to establish.

## Remaining sequence

1. Wait for Nick to finish deleting shows in Overcast.
2. `python3 scripts/overcast-source-stability.py --samples 3 --interval 60`
   until it reports `STABLE`.
3. `scripts/overcast-migration-run.sh probe` — partial bundle, then confirm via
   `scripts/pocketcasts-account-audit.py` that subscriptions, Up Next order,
   stars and positions actually reached the server.
4. Clear the account back to empty.
5. `scripts/overcast-migration-run.sh production` — fresh full bundle.
6. Reconcile the server audit against the source manifest.
7. Confirm on Nick's iPhone that the App Store app pulled everything down.
8. Update `PCI-001` to done with the server audit as its artifact.

## Source

- Overcast database:
  `/Users/urbs/Library/Containers/4CCCADE0-33F2-45A3-8E1B-B96EF6247C5C/Data/Documents/db.sqlite`
- As of 2026-07-30 13:15 PDT it still showed 62 subscriptions and 101,667
  episodes, so the deletions had not yet happened.
- Every bundle under `~/Documents/Overcast Migration *` is rehearsal evidence
  only. The production bundle must be exported fresh after the source settles.

## Operating constraints

- Preserve dirty and user-owned work, and the repo ledger.
- Do not rely on GitHub Actions.
- Do not rerun passed native gates merely for telemetry.
- The earlier `outliyr-proof-gate` pilot wrapper was infrastructure-stuck;
  preserve that fact and do not rerun it solely for telemetry.
- Retain Overcast and the frozen bundle for rollback confidence.
