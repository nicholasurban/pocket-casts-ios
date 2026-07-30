# Fork features

Features built for Nick's own build of Pocket Casts, beyond the Overcast
migration. Decisions recorded 2026-07-30; nothing here is started until the
migration is finished and verified.

None of these unlock a paid Pocket Casts feature. Where a Plus feature is
adjacent, the note below says explicitly what is and is not being touched.

## 1. Local audio files, on Nick's own storage

**Why this is not the Plus feature.** Pocket Casts Plus sells 20 GB of
Automattic's cloud storage plus cross-device sync of uploaded files. That is
the paid thing and it stays untouched — nothing here uploads to their servers
or consumes their quota.

The local half is already unpaid. `UserEpisodeManager.addUserEpisode(uuid:
title:localFileUrl:artwork:color:fileSize:duration:)` has no subscription
check, and the `SJUserEpisode` table exists in the database regardless of
tier. The gates sit on custom artwork (`AddCustomViewController.swift:372`)
and on the cloud sync settings (`UploadedSettingsViewController`).

**Decision:** import via the iOS Files app picker and the share sheet. Works
with iCloud Drive, Dropbox, AirDrop, or anything else that can hand over a
file. No folder watching, no background refresh, nothing to keep running.

**Shape:**
- Files land in the app's own Documents directory and are registered as
  `SJUserEpisode` rows.
- The cloud upload path is never invoked; these rows stay device-local.
- Do not reuse the gated artwork picker. Either derive artwork from the file's
  own embedded art or leave it blank.

## 2. Related next episode, on the home screen

A card that suggests what to play next based on the topic of whatever is
currently playing, drawn from episodes already in the library.

**Decision:** on-device text similarity. No network, no API key, no per-lookup
cost, and it keeps working offline. Compares the current episode's title and
show notes against the rest of the library.

**Shape:**
- Score candidates by term overlap against title + `episodeDescription`,
  weighted toward rarer terms so common podcast words do not dominate.
- Draw only from subscribed shows, excluding the current episode, anything
  already finished, and anything already in Up Next.
- Recompute when the playing episode changes; cache per episode so scrolling
  the home screen does not re-score the library.
- The library is ~101k episode rows, so scoring must run off the main thread
  and should restrict candidates before scoring rather than ranking everything.

Explicitly rejected: category-only matching (too crude — suggests anything
filed under Health) and an LLM call (better quality, but adds a key, network
dependency, and latency to a home-screen card).

## 3. All-episodes quick view in the tab bar

Replace the Discover tab with a flat view of every episode across every
subscription.

**Decision:** everything, newest first, **with filters and sorting options**.
Filters for unplayed / in-progress / downloaded; sorting is a first-class
control, not just the implied newest-first default.

**Shape:**
- Reverse-chronological across all subscribed shows by default.
- Filter toggles: unplayed, in progress, downloaded.
- Sort options: newest, oldest, longest, shortest, and by show.
- `SJFilteredPlaylist` already models filtering and 27 rows exist post
  migration; check whether this should be a built-in filter rather than a new
  screen before writing a parallel implementation.

**Discover moves to a button on the Podcasts screen's nav bar** — one tap
away, no tab-bar slot consumed. Rejected: burying it in Profile (too far for
something occasionally useful) and a fifth tab (cramped).
