#!/usr/bin/env python3
"""Report whether the live Overcast database has stopped changing.

The migration export must never run while Overcast is still syncing or while
episodes are still being deleted on the phone. This samples the source database
read-only several times and reports STABLE only when every observed counter,
file size and modification time is unchanged across the whole window.

Exit codes:
  0  stable, safe to export
  1  still changing, do not export
  2  the source could not be inspected
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

DEFAULT_DATABASE = Path(
    "/Users/urbs/Library/Containers/4CCCADE0-33F2-45A3-8E1B-B96EF6247C5C"
    "/Data/Documents/db.sqlite"
)

# Counters chosen to move whenever Nick deletes a show or an episode, stars
# something, listens to anything, or Overcast pulls new state down from sync.
COUNT_QUERIES: dict[str, str] = {
    "podcasts": "SELECT COUNT(*) FROM OCPodcast",
    "subscribed_podcasts": "SELECT COUNT(*) FROM OCPodcast WHERE userSubscribed = 1",
    "episodes": "SELECT COUNT(*) FROM OCEpisode",
    "episodes_in_progress": "SELECT COUNT(*) FROM OCEpisode WHERE userProgress > 0",
    "episodes_starred": "SELECT COUNT(*) FROM OCEpisode WHERE userRecommendedTime > 0",
    "episodes_downloaded": "SELECT COUNT(*) FROM OCEpisode WHERE downloadState > 0",
    "episodes_deleted_marker": "SELECT COUNT(*) FROM OCEpisode WHERE userDeleted = 1",
    "playlists": "SELECT COUNT(*) FROM OCPlaylist WHERE userDeletedLocally = 0",
    "playback_sessions": "SELECT COUNT(*) FROM OCPlaybackSession",
}


def open_source(path: Path) -> sqlite3.Connection:
    """Open the live database read-only, exactly as the exporter does."""
    uri = f"{path.resolve().as_uri()}?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=30)
    connection.execute("PRAGMA query_only = ON")
    return connection


def file_facts(database: Path) -> dict[str, Any]:
    facts: dict[str, Any] = {}
    for suffix in ("", "-wal", "-shm"):
        candidate = Path(str(database) + suffix)
        key = "db" if suffix == "" else suffix.lstrip("-")
        if candidate.exists():
            stat = candidate.stat()
            facts[f"{key}_bytes"] = stat.st_size
            facts[f"{key}_mtime"] = int(stat.st_mtime)
        else:
            facts[f"{key}_bytes"] = None
            facts[f"{key}_mtime"] = None
    return facts


def sample(database: Path) -> dict[str, Any]:
    observation = file_facts(database)
    connection = open_source(database)
    try:
        for name, query in COUNT_QUERIES.items():
            try:
                observation[name] = connection.execute(query).fetchone()[0]
            except sqlite3.Error as error:
                observation[name] = f"unavailable: {error}"
    finally:
        connection.close()
    return observation


def overcast_processes() -> list[str]:
    """Overcast runs as an iOS-app-on-Mac wrapper; report anything still alive."""
    try:
        completed = subprocess.run(
            ["pgrep", "-fl", "Overcast"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    return [line for line in completed.stdout.splitlines() if line.strip()]


def differences(first: dict[str, Any], second: dict[str, Any]) -> dict[str, Any]:
    changed: dict[str, Any] = {}
    for key in sorted(set(first) | set(second)):
        before, after = first.get(key), second.get(key)
        if before != after:
            changed[key] = {"from": before, "to": after}
    return changed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("database", nargs="?", type=Path, default=DEFAULT_DATABASE)
    parser.add_argument("--samples", type=int, default=3, help="number of observations (minimum 2)")
    parser.add_argument("--interval", type=float, default=60.0, help="seconds between observations")
    parser.add_argument("--json", type=Path, default=None, help="write the full observation set here")
    parser.add_argument("--quiet", action="store_true", help="print only the verdict line")
    arguments = parser.parse_args()

    if not arguments.database.exists():
        print(f"UNAVAILABLE  source database not found: {arguments.database}")
        return 2
    if arguments.samples < 2:
        parser.error("--samples must be at least 2")

    observations: list[dict[str, Any]] = []
    for index in range(arguments.samples):
        if index:
            time.sleep(arguments.interval)
        try:
            observation = sample(arguments.database)
        except sqlite3.Error as error:
            print(f"UNAVAILABLE  could not read the source database: {error}")
            return 2
        observation["observed_at"] = int(time.time())
        observations.append(observation)
        if not arguments.quiet:
            print(
                f"sample {index + 1}/{arguments.samples}  "
                f"subscribed={observation.get('subscribed_podcasts')}  "
                f"episodes={observation.get('episodes')}  "
                f"in_progress={observation.get('episodes_in_progress')}  "
                f"wal_bytes={observation.get('wal_bytes')}"
            )

    # `shm_mtime` is excluded because merely opening the database read-only
    # rewrites the shared-memory index; it would report drift we caused
    # ourselves. Real edits still surface through the counters, the WAL size
    # and the database mtime.
    ignored_keys = {"observed_at", "shm_mtime"}
    drift: dict[str, Any] = {}
    for earlier, later in zip(observations, observations[1:]):
        for key, change in differences(earlier, later).items():
            if key in ignored_keys:
                continue
            drift.setdefault(key, []).append(change)

    running = overcast_processes()
    payload = {
        "database": str(arguments.database),
        "samples": observations,
        "drift": drift,
        "overcast_processes": running,
        "stable": not drift,
    }
    if arguments.json:
        arguments.json.parent.mkdir(parents=True, exist_ok=True)
        arguments.json.write_text(json.dumps(payload, indent=2) + "\n")

    window = arguments.interval * (arguments.samples - 1)
    if drift:
        print(f"CHANGING  the source moved during {window:.0f}s; do not export yet")
        for key, changes in drift.items():
            print(f"  {key}: {changes[0]['from']} -> {changes[-1]['to']}")
        return 1

    print(f"STABLE  nothing moved across {window:.0f}s; safe to export")
    if running:
        print("  note: Overcast is still running; quitting it first is safer but not required")
    return 0


if __name__ == "__main__":
    sys.exit(main())
