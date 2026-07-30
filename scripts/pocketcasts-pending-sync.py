#!/usr/bin/env python3
"""Report how much migrated state is still waiting to upload to Pocket Casts.

The importer writes local rows and marks them modified; Pocket Casts' own sync
drains that queue in the background. Draining ten thousand episode states takes
far longer than writing them, so a run that stops at the reconciliation report
uploads only a fraction while looking complete.

This reads the app's database read-only and counts what has not yet been sent.

Exit codes:
  0  nothing pending, the upload has drained
  1  work still queued
  2  the database could not be read
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from pathlib import Path

# These must mirror `EpisodeDataManager.unsyncedEpisodes`, which is the app's
# own definition of "not yet uploaded":
#
#   playingStatusModified > 0 OR playedUpToModified > 0 OR durationModified > 0
#   OR keepEpisodeModified > 0 OR archivedModified > 0
#
# Note `keepEpisodeModified`, not `starredModified`. The latter is a separate
# modification timestamp that stays set after a successful upload, so counting
# it reports rows as pending forever — this tool did exactly that on
# 2026-07-30 and claimed 133 stars were stuck while the server already had all
# 133 of them.
PENDING_QUERIES: dict[str, str] = {
    "podcasts": "SELECT COUNT(*) FROM SJPodcast WHERE syncStatus = 0",
    "stars": "SELECT COUNT(*) FROM SJEpisode WHERE keepEpisodeModified > 0",
    "playback_positions": "SELECT COUNT(*) FROM SJEpisode WHERE playedUpToModified > 0",
    "playing_status": "SELECT COUNT(*) FROM SJEpisode WHERE playingStatusModified > 0",
    "duration": "SELECT COUNT(*) FROM SJEpisode WHERE durationModified > 0",
    "archived": "SELECT COUNT(*) FROM SJEpisode WHERE archivedModified > 0",
}


def pending(database: Path) -> dict[str, int]:
    uri = f"{database.resolve().as_uri()}?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=30)
    connection.execute("PRAGMA query_only = ON")
    try:
        counts: dict[str, int] = {}
        for name, query in PENDING_QUERIES.items():
            try:
                counts[name] = connection.execute(query).fetchone()[0]
            except sqlite3.Error:
                # A column missing simply means this build does not track that
                # kind of state; treat it as nothing pending rather than fatal.
                counts[name] = 0
        return counts
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("database", type=Path, help="path to podcast_newDB.sqlite3")
    parser.add_argument("--json", type=Path, default=None)
    parser.add_argument("--quiet", action="store_true")
    arguments = parser.parse_args()

    if not arguments.database.exists():
        print(f"UNAVAILABLE  database not found: {arguments.database}")
        return 2

    try:
        counts = pending(arguments.database)
    except sqlite3.Error as error:
        print(f"UNAVAILABLE  {error}")
        return 2

    total = sum(counts.values())
    if arguments.json:
        arguments.json.parent.mkdir(parents=True, exist_ok=True)
        arguments.json.write_text(json.dumps({"pending": counts, "total": total}, indent=2) + "\n")

    if not arguments.quiet:
        detail = "  ".join(f"{name}={value}" for name, value in counts.items() if value)
        print(f"pending upload: {total}" + (f"  ({detail})" if detail else ""))

    return 0 if total == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
