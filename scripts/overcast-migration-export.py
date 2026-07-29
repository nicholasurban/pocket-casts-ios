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
import subprocess
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


def preserve_file(source: Path, destination: Path) -> str:
    """Preserve a file without needlessly duplicating APFS blocks.

    `cp -c` creates a copy-on-write clone on APFS. The destination remains a
    real, independently deletable file and retains the shared blocks if the
    source is later removed. Ordinary copy is the portable fallback.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin":
        cloned = subprocess.run(
            ["/bin/cp", "-c", str(source), str(destination)],
            capture_output=True,
            check=False,
        )
        if cloned.returncode == 0:
            shutil.copystat(source, destination)
            return "apfs_clone"
    shutil.copy2(source, destination)
    return "copy"


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
                record["preservation_method"] = preserve_file(candidate, destination)
    return inventory


def inventory_downloaded_episode_audio(connection: sqlite3.Connection, database: Path, output: Path | None, copy_audio: bool) -> list[dict[str, Any]]:
    """Inventory only audio files that Overcast names after its episode IDs.

    This avoids treating its SQLite files, artwork, or transient network files
    as episode audio. A missing file is intentionally reported as unresolved so
    the Pocket Casts importer can queue a normal re-download instead.
    """
    inventory: list[dict[str, Any]] = []
    files_by_episode_id: dict[int, Path] = {}
    for file in database.parent.iterdir():
        if file.suffix.lower() not in {".mp3", ".m4a"}:
            continue
        try:
            files_by_episode_id[int(file.stem)] = file
        except ValueError:
            continue
    candidates = rows(connection, """
        SELECT id AS source_episode_id, enclosureURL AS enclosure_url,
               downloadedExtension AS file_extension, downloadState AS download_state
        FROM OCEpisode
        WHERE downloadState != 0 OR id IN ({})
        ORDER BY id
    """.format(",".join("?" for _ in files_by_episode_id) or "NULL"), tuple(files_by_episode_id))
    for candidate in candidates:
        source = files_by_episode_id.get(candidate["source_episode_id"])
        record = {
            "source_episode_id": candidate["source_episode_id"],
            "enclosure_url": candidate["enclosure_url"],
            "source_download_state": candidate["download_state"],
            "present": source is not None,
        }
        if source is not None:
            extension = source.suffix.lstrip(".")
            record["file_extension"] = extension
            record["bytes"] = source.stat().st_size
            record["sha256"] = sha256(source)
            record["relative_path"] = f"audio/{source.name}"
            if copy_audio:
                assert output is not None
                destination = output / "audio" / source.name
                record["preservation_method"] = preserve_file(source, destination)
        inventory.append(record)
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
               e.userProgress AS progress_seconds, e.userDeleted AS overcast_deleted,
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
    current_playback = rows(connection, """
        SELECT currentlyLoadedEpisodeID AS source_episode_id
        FROM OCUser
        LIMIT 1
    """)

    last_session_by_episode: dict[int, int] = {}
    for session in playback_sessions:
        if session["deleted"]:
            continue
        episode_id = session["source_episode_id"]
        last_session_by_episode[episode_id] = max(
            last_session_by_episode.get(episode_id, 0),
            session["updated_time"],
        )

    for episode in episodes:
        duration = episode["advertised_duration"]
        progress = episode["progress_seconds"]
        # The inspected Mac database leaves userLastPlayedTime at zero while
        # retaining recent listening activity in OCPlaybackSession.
        episode["last_played_time"] = max(
            episode["last_played_time"],
            last_session_by_episode.get(episode["source_episode_id"], 0),
        )
        episode["playback_state"] = (
            "not_started" if progress == 0
            else "completed" if duration > 0 and progress >= duration
            else "in_progress"
        )
        episode["download_requested"] = episode["download_state"] != 0

    subscriptions = [podcast for podcast in podcasts if podcast["subscribed"]]
    show_settings = [{key: value for key, value in podcast.items() if key not in {
        "title", "author", "language", "link_url", "image_url", "itunes_id", "subscribed", "sort_order"
    }} for podcast in podcasts]
    return {
        "podcasts": podcasts,
        "subscriptions": subscriptions,
        "episodes": episodes,
        "playlists": playlists,
        "queues": [playlist for playlist in playlists if playlist["manual_sort"]],
        "show_settings": show_settings,
        "playback_state": {
            "sessions": playback_sessions,
            "current_source_episode_id": current_playback[0]["source_episode_id"] if current_playback else None,
        },
        "counts": {
            "podcasts": len(podcasts), "subscriptions": len(subscriptions), "episodes": len(episodes),
            "downloaded_candidates": sum(episode["download_state"] != 0 for episode in episodes),
            "in_progress": sum(episode["playback_state"] == "in_progress" for episode in episodes),
            "completed": sum(episode["playback_state"] == "completed" for episode in episodes),
            "starred": sum(episode["starred_time"] > 0 for episode in episodes),
            "history_dates": sum(episode["last_played_time"] > 0 for episode in episodes),
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
    parser.add_argument("--include-downloaded-audio", action="store_true", help="Copy verified Overcast episode files named after source episode IDs")
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
    if args.include_downloaded_audio and args.dry_run:
        parser.error("--include-downloaded-audio requires --output DIRECTORY")
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
    for name in ("podcasts", "subscriptions", "episodes", "queues", "playlists", "show_settings", "playback_state"):
        write_json(output, f"{name}.json", bundle[name])
    (output / "validation-report.html").write_text(report(bundle["counts"]), encoding="utf-8")
    if args.audio_root:
        audio = inventory_audio(args.audio_root, output=output, copy_audio=args.copy_audio)
        write_json(output, "audio-inventory.json", audio)
    if args.include_downloaded_audio:
        with open_source(args.database) as connection:
            downloaded_audio = inventory_downloaded_episode_audio(connection, args.database, output=output, copy_audio=True)
        write_json(output, "downloaded-audio-inventory.json", downloaded_audio)
    checksummed_artifacts = sorted(path for path in output.iterdir() if path.is_file())
    write_json(
        output,
        "artifact-checksums.json",
        {path.name: sha256(path) for path in checksummed_artifacts},
    )
    print(f"Wrote audited migration bundle to {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
