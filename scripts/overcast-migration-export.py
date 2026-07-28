#!/usr/bin/env python3
"""Create a portable, read-only migration bundle from Overcast's Mac database.

The exporter deliberately does not modify the source database. Its output is a
reviewable JSON bundle for the Pocket Casts in-app importer, not a Pocket Casts
database replacement.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import shutil
import sqlite3
import sys
from pathlib import Path
from typing import Any


FORMAT_VERSION = 1
REQUIRED_TABLES = {"OCPodcast", "OCEpisode", "OCPlaylist", "OCUser"}


def rows(connection: sqlite3.Connection, query: str, parameters: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
    return [dict(row) for row in connection.execute(query, parameters)]


def utc_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def write_json(output: Path, name: str, value: Any) -> None:
    (output / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inventory_audio(roots: list[Path], output: Path | None, copy_audio: bool) -> list[dict[str, Any]]:
    inventory: list[dict[str, Any]] = []
    for root in roots:
        for candidate in sorted(path for path in root.rglob("*") if path.is_file()):
            # Overcast writes incomplete transfer files while a sync is in flight.
            # They are recorded for reconciliation but never copied as preserved audio.
            incomplete = candidate.name.startswith("CFNetworkDownload_") and candidate.suffix == ".tmp"
            record = {
                "root": root.name,
                "relative_path": str(candidate.relative_to(root)),
                "bytes": candidate.stat().st_size,
                "sha256": sha256(candidate),
                "incomplete_transfer": incomplete,
            }
            inventory.append(record)
            if copy_audio and not incomplete:
                assert output is not None
                destination = output / "audio" / root.name / candidate.relative_to(root)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(candidate, destination)
    return inventory


def open_source(path: Path) -> sqlite3.Connection:
    # mode=ro prevents accidental writes while still allowing SQLite to read the
    # current WAL snapshot produced by the live Overcast app.
    uri = f"{path.resolve().as_uri()}?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only = ON")
    return connection


def extract(connection: sqlite3.Connection, episode_limit: int | None = None) -> dict[str, Any]:
    table_names = {row["name"] for row in rows(connection, "SELECT name FROM sqlite_master WHERE type = 'table'")}
    missing = REQUIRED_TABLES - table_names
    if missing:
        raise RuntimeError(f"Not an expected Overcast database; missing: {', '.join(sorted(missing))}")

    podcasts = rows(connection, """
        SELECT id, sjtHash, URL AS feed_url, title, author, language, linkURL AS link_url,
               imageURL AS image_url, iTunesID AS itunes_id, isPrivate AS is_private,
               userSubscribed AS subscribed, userSortOrderInList AS sort_order,
               userItemLimit AS item_limit, userEnhancementMode AS enhancement_mode,
               userUseCustomEffects AS use_custom_effects,
               userPlaybackSpeedID AS playback_speed_id,
               userEpisodeSortOrder AS episode_sort_order,
               userEpisodeSortOrderAll AS episode_sort_order_all,
               userDownloadPolicy AS download_policy, userDeletePolicy AS delete_policy,
               userHasCustomFilters AS has_custom_filters, userMeta AS metadata
        FROM OCPodcast
        ORDER BY userSortOrderInList, id
    """)
    episode_query = """
        SELECT e.id AS source_episode_id, e.podcastID AS source_podcast_id,
               p.URL AS feed_url, p.title AS podcast_title,
               e.publishedTime AS published_time, e.title, e.linkURL AS link_url,
               e.enclosureURL AS enclosure_url, e.episode, e.season,
               e.advertisedDuration AS advertised_duration,
               e.userProgress AS progress_seconds, e.userDeleted AS archived,
               e.userRecommendedTime AS starred_time, e.userAddedManually AS added_manually,
               e.userLastPlayedTime AS last_played_time, e.downloadState AS download_state,
               e.downloadedExtension AS downloaded_extension,
               e.downloadedDuration AS downloaded_duration,
               e.totalBytesDownloaded AS downloaded_bytes, e.noLongerInFeed AS no_longer_in_feed
        FROM OCEpisode e JOIN OCPodcast p ON p.id = e.podcastID
        ORDER BY e.podcastID, e.publishedTime, e.id
    """
    if episode_limit is not None:
        episode_query += " LIMIT ?"
    episodes = rows(connection, episode_query, (() if episode_limit is None else (episode_limit,)))
    playlists = rows(connection, """
        SELECT id, title, preset, includedPodcastIDList AS included_podcast_ids,
               excludedPodcastIDList AS excluded_podcast_ids,
               priorityPodcastIDList AS priority_podcast_ids,
               lowPriorityPodcastIDList AS low_priority_podcast_ids,
               priorityMode AS priority_mode, includedEpisodeIDList AS included_episode_ids,
               excludedEpisodeIDList AS excluded_episode_ids, manualSort AS manual_sort,
               sortMode AS sort_mode, individualEpisodesOnly AS individual_episodes_only,
               episodeStatus AS episode_status, userUpdateTimeWindow AS update_time_window,
               userSortOrderInList AS sort_order, colorIdentifier AS color_identifier,
               iconIdentifier AS icon_identifier, meta AS metadata, userDeletedLocally AS deleted
        FROM OCPlaylist ORDER BY userSortOrderInList, id
    """)
    playback_sessions = rows(connection, """
        SELECT id, updatedTime AS updated_time, calendarDate AS calendar_date,
               podcastID AS source_podcast_id, episodeID AS source_episode_id, action,
               userInfo AS user_info, userDeletedLocally AS deleted
        FROM OCPlaybackSession ORDER BY updatedTime, id
    """) if "OCPlaybackSession" in table_names else []

    subscriptions = [podcast for podcast in podcasts if podcast["subscribed"]]
    show_settings = [{key: value for key, value in podcast.items() if key not in {
        "title", "author", "language", "link_url", "image_url", "itunes_id", "subscribed", "sort_order"
    }} for podcast in podcasts]
    return {
        "subscriptions": subscriptions,
        "episodes": episodes,
        "playlists": playlists,
        "queues": [playlist for playlist in playlists if playlist["manual_sort"]],
        "show_settings": show_settings,
        "playback_state": {"sessions": playback_sessions},
        "counts": {
            "podcasts": len(podcasts), "subscriptions": len(subscriptions), "episodes": len(episodes),
            "downloaded_candidates": sum(episode["download_state"] != 0 for episode in episodes),
            "in_progress": sum(episode["progress_seconds"] > 0 for episode in episodes),
            "starred": sum(episode["starred_time"] > 0 for episode in episodes),
            "playlists": len(playlists), "playback_sessions": len(playback_sessions),
        },
    }


def report(counts: dict[str, int]) -> str:
    items = "".join(f"<tr><th>{html.escape(key.replace('_', ' ').title())}</th><td>{value:,}</td></tr>" for key, value in counts.items())
    return "<!doctype html><meta charset=utf-8><title>Overcast migration export</title><h1>Overcast migration export</h1><p>Review this before importing. No destination changes have been made.</p><table>" + items + "</table>"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path, help="Path to Overcast db.sqlite")
    parser.add_argument("--output", type=Path, help="Empty directory for the migration bundle")
    parser.add_argument("--dry-run", action="store_true", help="Inspect and report counts without writing a bundle")
    parser.add_argument("--audio-root", type=Path, action="append", default=[], help="Directory containing Overcast audio to inventory (repeatable)")
    parser.add_argument("--copy-audio", action="store_true", help="Copy complete files from --audio-root into bundle/audio")
    parser.add_argument("--test-only", action="store_true", help="Allow a deliberately incomplete bundle for exporter verification")
    parser.add_argument("--limit-episodes", type=int, help="Number of episodes in a --test-only bundle")
    args = parser.parse_args()
    if not args.database.is_file():
        parser.error(f"database does not exist: {args.database}")
    if args.dry_run == (args.output is not None):
        parser.error("provide exactly one of --dry-run or --output DIRECTORY")
    if args.output and args.output.exists() and any(args.output.iterdir()):
        parser.error(f"output directory must be empty: {args.output}")
    if args.copy_audio and not args.audio_root:
        parser.error("--copy-audio requires at least one --audio-root")
    if args.limit_episodes is not None and (not args.test_only or args.limit_episodes < 0):
        parser.error("--limit-episodes requires --test-only and a non-negative value")
    for audio_root in args.audio_root:
        if not audio_root.is_dir():
            parser.error(f"audio root does not exist: {audio_root}")

    with open_source(args.database) as connection:
        bundle = extract(connection, episode_limit=args.limit_episodes)
    if args.dry_run:
        audio = inventory_audio(args.audio_root, output=None, copy_audio=False)
        print(json.dumps({**bundle["counts"], "audio_files": len(audio), "audio_bytes": sum(item["bytes"] for item in audio)}, indent=2, sort_keys=True))
        return 0

    output = args.output
    assert output is not None
    output.mkdir(parents=True, exist_ok=True)
    manifest = {
        "format": "overcast-migration", "format_version": FORMAT_VERSION,
        "created_at": utc_iso(), "source": "Overcast Mac db.sqlite",
        "test_only": args.test_only,
        "notes": ["The source schema has no episode GUID column; importers should match enclosure URL first, then feed URL, publication time, title, and duration."],
        "counts": bundle["counts"],
    }
    write_json(output, "manifest.json", manifest)
    for name in ("subscriptions", "episodes", "queues", "playlists", "show_settings", "playback_state"):
        write_json(output, f"{name}.json", bundle[name])
    (output / "validation-report.html").write_text(report(bundle["counts"]), encoding="utf-8")
    if args.audio_root:
        audio = inventory_audio(args.audio_root, output=output, copy_audio=args.copy_audio)
        write_json(output, "audio-inventory.json", audio)
    print(f"Wrote audited migration bundle to {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
