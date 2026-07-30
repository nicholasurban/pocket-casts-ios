# Overcast migration

This fork contains a read-only Overcast exporter and an in-app Pocket Casts
importer. It does not edit either application's SQLite database directly.

## Inspected source

The Overcast Mac app stores its synchronized state in its sandbox Documents
directory. The inspected database contains:

| Table | State used by the exporter |
|---|---|
| `OCPodcast` | subscriptions, feed URLs, ordering, playback effects, download and retention preferences |
| `OCEpisode` | enclosure URLs, dates, titles, duration, progress, stars, and download state |
| `OCPlaylist` | queue order, explicit membership, playlist rules, and manual ordering |
| `OCPlaybackSession` | recent episode-level listening activity |
| `OCUser` | the currently loaded episode |

The source has no episode GUID column. Episode matching therefore uses:

1. enclosure URL;
2. exact title and publication time within five minutes;
3. exact title and duration within two seconds.

Fallback matches must be unique. Ambiguous records are unresolved rather than
being applied to an arbitrary episode.

`OCEpisode.userDeleted` is not Pocket Casts archive state. It is set on nearly
all historical source rows and mapping it would incorrectly hide valid Pocket
Casts episodes. The importer counts and reports these markers but never maps
them to archive or deletion.

`OCEpisode.userLastPlayedTime` was zero in the inspected Mac snapshot.
The exporter derives an episode's last interaction date from the newest
non-deleted `OCPlaybackSession` row when available. The complete session ledger
is also retained in `playback_state.json`.

## Deciding when the source has settled

The export must not run while episodes are still being deleted on the phone or
while Overcast is still syncing. `scripts/overcast-source-stability.py` samples
the live database read-only and reports `STABLE` only when every counter, the
WAL size and the database modification time hold still across the whole window:

```bash
python3 scripts/overcast-source-stability.py --samples 3 --interval 60
```

Exit status is 0 when stable, 1 when the source is still moving, 2 when the
database cannot be inspected. The shared-memory file's modification time is
deliberately ignored, because opening the database read-only rewrites it and
would otherwise report drift we caused ourselves.

## Export

Run the exporter against a fully synchronized, closed Overcast Mac app:

```bash
python3 scripts/overcast-migration-export.py \
  "/path/to/Overcast/Data/Documents/db.sqlite" \
  --output "/path/to/empty/overcast-migration" \
  --include-downloaded-audio
```

The output contains:

```text
artifact-checksums.json
manifest.json
podcasts.json
subscriptions.json
episodes.json
queues.json
playlists.json
show_settings.json
playback_state.json
downloaded-audio-inventory.json
validation-report.html
audio/
```

All source access uses SQLite read-only and query-only modes. Preserved audio
uses APFS copy-on-write clones when available, with ordinary copies as a
fallback. Every present audio file has its byte count and SHA-256 recorded.
`artifact-checksums.json` protects the neutral metadata artifacts from silent
changes after export.

## Import

Use a Debug or Staging build and open:

```text
Settings → Developer
```

For the complete path, choose `Choose Bundle and Run Complete Overcast
Migration`, select the audited folder, review the destructive confirmation,
and start once. If the bundle was copied into the app as
`Documents/OvercastMigrationQA`, use `Run Complete Installed Overcast
Migration` instead.

The complete runner:

1. verifies the neutral artifact checksums;
2. writes a native `.pcasts` database/settings backup before its first write;
3. subscribes through Pocket Casts' normal OPML importer;
4. restores matched episode state and show settings;
5. replaces Up Next and restores playlist snapshots;
6. imports hash-verified preserved audio;
7. refreshes and synchronizes through Pocket Casts;
8. reads the destination back and saves a post-refresh audit report.

`podcasts.json` preserves the full source library and each show's original
subscription flag. Shows needed only for old playback history, stars, queue
entries, playlists, or preserved audio are imported temporarily so Pocket
Casts creates native rows, then restored to unsubscribed before the final
sync. The active subscription set therefore remains the source boundary
rather than silently becoming the entire historical library.

Missing audio is never downloaded without an explicit opt-in. Preserved audio
is handed to Pocket Casts' existing download manager only after its SHA-256
matches. State is applied only to episodes that Pocket Casts already created
through its normal feed pipeline.

Custom Overcast smart-playlist rules have no exact Pocket Casts equivalent.
Their current explicit order can be restored as a manual playlist snapshot;
the report identifies this loss of dynamic behavior. Overcast's Starred preset
maps to Pocket Casts episode stars, and its Queue preset maps to Up Next.

Pocket Casts stores a show's website in `Podcast.podcastUrl`, not its RSS feed.
The importer therefore reconciles the exact imported show by unique episode
enclosure overlap first and unique normalized title second. It never assumes
that `podcastUrl` is a feed URL. Ambiguous shows remain unresolved.

The individual dry-run, subscription, state, collection, audio, and report
controls remain available for diagnosis and recovery. They are not required
for a normal complete run.

## Safe rehearsal and production

Never begin with the live account. Install the audited neutral metadata and at
least one matching preserved-audio file as
`Documents/OvercastMigrationQA` in a disposable simulator and launch with:

```text
--overcast-migration-full-qa
```

This invokes the complete runner against the disposable simulator. Rehearsal
mode imports subscriptions, state, Up Next, playlist snapshots, and one
hash-verified audio file, then refreshes and audits the destination. It writes:

```text
Documents/OvercastMigrationBackups/PocketCasts-before-Overcast-*.pcasts
Documents/OvercastMigrationQACompleteReport.txt
```

The lighter read-only preflight remains available with
`--overcast-migration-qa`; a passing run writes
`Documents/OvercastMigrationQAReceipt.json`.

Immediately before production:

1. retain the frozen Overcast bundle and its checksums;
2. export a Pocket Casts `.pcasts` backup;
3. obtain explicit approval for the live-account mutation;
4. import once and allow Pocket Casts sync to finish;
5. compare the final reconciliation report with the source manifest;
6. keep Overcast and the neutral bundle untouched for several weeks.

## The account is what carries the migration, not the device

The importer writes local rows flagged `notSynced` and then asks Pocket Casts
to sync. That means the migration does not have to happen on the destination
phone at all: a simulator signed into the account uploads the state, and every
other device pulls it down normally. Only downloaded audio is device-local and
does not travel this way.

It also means a run that starts signed out imports locally and then uploads
nothing, while still producing a healthy-looking reconciliation report. The
production launch path therefore refuses to start without credentials.

Credentials are supplied through the environment, never through launch
arguments or this repository:

| Variable | Purpose |
|---|---|
| `OVERCAST_MIGRATION_PC_EMAIL` | Pocket Casts account email |
| `OVERCAST_MIGRATION_PC_PASSWORD` | Pocket Casts account password |

`simctl` forwards them with its `SIMCTL_CHILD_` prefix. Launch arguments:

| Argument | Mode |
|---|---|
| `--overcast-migration-full-qa` | rehearsal; imports one proof-of-path audio file |
| `--overcast-migration-full-production` | production; imports all preserved audio, requires credentials |

## Running the whole thing

`scripts/overcast-migration-run.sh` is the single entry point. It checks source
stability, exports a fresh bundle, builds and installs the migration app on a
clean simulator, signs in, runs the importer, and then reads the sync server
back to prove the upload happened:

```bash
scripts/overcast-migration-run.sh probe        # partial bundle, proves sync works
scripts/overcast-migration-run.sh production   # the real migration
```

Evidence for each run lands in `~/Documents/Overcast Migration Runs/<mode>-<timestamp>/`.

`scripts/pocketcasts-account-audit.py` reads the account from the sync server
on its own. A local reconciliation report describes the simulator's database;
only the server audit shows what actually reached the account.
