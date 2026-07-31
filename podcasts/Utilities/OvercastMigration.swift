import Combine
import CryptoKit
import Foundation
import PocketCastsDataModel
import PocketCastsServer

/// The portable format written by `scripts/overcast-migration-export.py`.
/// Loading and planning are intentionally side-effect-free. Subscription and
/// state writes happen only after the developer UI presents this report.
enum OvercastMigration {
    static let format = "overcast-migration"
    static let supportedFormatVersion = 1
    static let qaLaunchArgument = "--overcast-migration-qa"
    static let fullQALaunchArgument = "--overcast-migration-full-qa"
    /// Runs the same complete runner as `fullQALaunchArgument` but in
    /// production mode, so every preserved audio file is imported rather than
    /// the single proof-of-path file used during rehearsal.
    static let fullProductionLaunchArgument = "--overcast-migration-full-production"
    static let qaBundleDirectoryName = "OvercastMigrationQA"
    static let qaMarkerFileName = "OvercastMigrationQA.run"
    static let qaReceiptFileName = "OvercastMigrationQAReceipt.json"

    /// Environment variables used to sign the simulator into a Pocket Casts
    /// account without driving the sign-in UI. They are read from the process
    /// environment (set by `simctl` with the `SIMCTL_CHILD_` prefix) so the
    /// password never appears in a launch argument or in this repository.
    static let accountEmailEnvironmentKey = "OVERCAST_MIGRATION_PC_EMAIL"
    static let accountPasswordEnvironmentKey = "OVERCAST_MIGRATION_PC_PASSWORD"

    enum SignInOutcome {
        /// No credentials were supplied; the caller should proceed offline.
        case notRequested
        /// The account was already signed in before this launch.
        case alreadySignedIn(String)
        case signedIn(String)
    }

    /// Signs in from the environment when credentials are present.
    ///
    /// The migration writes local rows flagged `notSynced` and then asks Pocket
    /// Casts to sync. Without an authenticated account that final step is a
    /// silent no-op, so the run must fail loudly here rather than appear to
    /// succeed and upload nothing.
    static func signInFromEnvironmentIfNeeded() async throws -> SignInOutcome {
        let environment = ProcessInfo.processInfo.environment
        guard
            let email = environment[accountEmailEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            let password = environment[accountPasswordEnvironmentKey],
            !email.isEmpty,
            !password.isEmpty
        else {
            return .notRequested
        }

        if SyncManager.isUserLoggedIn(), let existing = ServerSettings.syncingEmail(), existing == email {
            return .alreadySignedIn(existing)
        }

        _ = try await AuthenticationHelper.validateLogin(username: email, password: password)
        return .signedIn(email)
    }

    struct Manifest: Decodable {
        let format: String
        let formatVersion: Int
        let testOnly: Bool
        let counts: Counts

        enum CodingKeys: String, CodingKey {
            case format, counts
            case formatVersion = "format_version"
            case testOnly = "test_only"
        }
    }

    struct Counts: Decodable {
        let podcasts: Int?
        let subscriptions: Int
        let episodes: Int
        let downloadedCandidates: Int
        let inProgress: Int
        let completed: Int
        let starred: Int
        let playlists: Int

        enum CodingKeys: String, CodingKey {
            case podcasts, subscriptions, episodes, starred, playlists, completed
            case downloadedCandidates = "downloaded_candidates"
            case inProgress = "in_progress"
        }
    }

    struct Subscription: Decodable {
        let sourcePodcastId: Int64
        let feedURL: String?
        let title: String

        enum CodingKeys: String, CodingKey {
            case title
            case sourcePodcastId = "id"
            case feedURL = "feed_url"
        }
    }

    struct SourcePodcast: Decodable {
        let sourcePodcastId: Int64
        let feedURL: String?
        let title: String
        let subscribed: Bool

        enum CodingKeys: String, CodingKey {
            case title, subscribed
            case sourcePodcastId = "id"
            case feedURL = "feed_url"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sourcePodcastId = try container.decode(Int64.self, forKey: .sourcePodcastId)
            feedURL = try container.decodeIfPresent(String.self, forKey: .feedURL)
            title = try container.decode(String.self, forKey: .title)
            subscribed = try container.decodeSQLiteBooleanIfPresent(forKey: .subscribed) ?? false
        }

        init(subscription: Subscription) {
            sourcePodcastId = subscription.sourcePodcastId
            feedURL = subscription.feedURL
            title = subscription.title
            subscribed = true
        }
    }

    struct ShowSetting: Decodable {
        let sourcePodcastId: Int64
        let feedURL: String?
        let itemLimit: Int
        let playbackSpeedId: Int64
        let downloadPolicy: Int
        let metadata: String?

        enum CodingKeys: String, CodingKey {
            case metadata
            case sourcePodcastId = "id"
            case feedURL = "feed_url"
            case itemLimit = "item_limit"
            case playbackSpeedId = "playback_speed_id"
            case downloadPolicy = "download_policy"
        }

        var playbackSpeed: Double? {
            guard playbackSpeedId != 0 else { return nil }
            let encoded = playbackSpeedId & 0x3FFF_FFFF
            let speed = (Double(encoded) / 1000 * 20).rounded() / 20
            return (0.5 ... 5).contains(speed) ? speed : nil
        }

        var skipTimes: (intro: Int, outro: Int) {
            guard let metadata,
                  let data = metadata.data(using: .utf8),
                  let values = try? JSONDecoder().decode([String: Int].self, from: data)
            else { return (0, 0) }
            return (max(0, values["si"] ?? 0), max(0, values["so"] ?? 0))
        }
    }

    struct Episode: Decodable {
        enum PlaybackState: String, Decodable {
            case notStarted = "not_started"
            case inProgress = "in_progress"
            case completed
        }

        let sourceEpisodeId: Int64
        let sourcePodcastId: Int64
        let feedURL: String?
        let podcastTitle: String
        let publishedTime: Int64
        let title: String
        let enclosureURL: String
        let advertisedDuration: Int
        let progressSeconds: Int
        let lastPlayedTime: Int64
        /// This is Overcast's raw `userDeleted` flag. It is intentionally not
        /// treated as Pocket Casts archive state: in the inspected source it
        /// marks most historical feed entries, so applying it would hide a
        /// large amount of valid destination content.
        let overcastDeleted: Bool
        let starredTime: Int64
        let downloadRequested: Bool
        let playbackState: PlaybackState

        enum CodingKeys: String, CodingKey {
            case title, archived
            case sourceEpisodeId = "source_episode_id"
            case sourcePodcastId = "source_podcast_id"
            case feedURL = "feed_url"
            case podcastTitle = "podcast_title"
            case publishedTime = "published_time"
            case enclosureURL = "enclosure_url"
            case advertisedDuration = "advertised_duration"
            case progressSeconds = "progress_seconds"
            case lastPlayedTime = "last_played_time"
            case starredTime = "starred_time"
            case downloadRequested = "download_requested"
            case playbackState = "playback_state"
            case overcastDeleted = "overcast_deleted"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sourceEpisodeId = try container.decode(Int64.self, forKey: .sourceEpisodeId)
            sourcePodcastId = try container.decode(Int64.self, forKey: .sourcePodcastId)
            feedURL = try container.decodeIfPresent(String.self, forKey: .feedURL)
            podcastTitle = try container.decode(String.self, forKey: .podcastTitle)
            publishedTime = try container.decode(Int64.self, forKey: .publishedTime)
            title = try container.decode(String.self, forKey: .title)
            enclosureURL = try container.decode(String.self, forKey: .enclosureURL)
            advertisedDuration = try container.decode(Int.self, forKey: .advertisedDuration)
            progressSeconds = try container.decode(Int.self, forKey: .progressSeconds)
            lastPlayedTime = try container.decodeIfPresent(Int64.self, forKey: .lastPlayedTime) ?? 0
            // Bundles made before the field was clarified used `archived`.
            overcastDeleted = try container.decodeSQLiteBooleanIfPresent(forKey: .overcastDeleted)
                ?? container.decodeSQLiteBooleanIfPresent(forKey: .archived)
                ?? false
            starredTime = try container.decode(Int64.self, forKey: .starredTime)
            downloadRequested = try container.decode(Bool.self, forKey: .downloadRequested)
            playbackState = try container.decode(PlaybackState.self, forKey: .playbackState)
        }
    }

    struct Playlist: Decodable {
        let title: String
        let preset: Int
        let includedEpisodeIds: String?
        let manualSort: String?
        let individualEpisodesOnly: Bool
        let deleted: Bool

        enum CodingKeys: String, CodingKey {
            case title, preset, deleted
            case includedEpisodeIds = "included_episode_ids"
            case manualSort = "manual_sort"
            case individualEpisodesOnly = "individual_episodes_only"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            preset = try container.decode(Int.self, forKey: .preset)
            includedEpisodeIds = try container.decodeIfPresent(String.self, forKey: .includedEpisodeIds)
            manualSort = try container.decodeIfPresent(String.self, forKey: .manualSort)
            individualEpisodesOnly = try container.decodeSQLiteBooleanIfPresent(forKey: .individualEpisodesOnly) ?? false
            deleted = try container.decodeSQLiteBooleanIfPresent(forKey: .deleted) ?? false
        }

        /// The playlist's full membership, in the user's chosen order.
        ///
        /// `manual_sort` is Overcast's drag-to-reorder list: it holds only the
        /// episodes the user explicitly repositioned, and is always a strict
        /// subset of `included_episode_ids`. Treating it as the membership —
        /// which this did until 2026-07-30 — silently truncates a playlist to
        /// whatever happened to be hand-sorted. It rebuilt a 94-episode
        /// playlist from 4 entries and a 12-episode queue from 4.
        ///
        /// So: `manual_sort` supplies the order for the episodes it names, and
        /// the rest of the membership follows. When there is no explicit
        /// membership the playlist is rule-based and `manual_sort` is all we
        /// have, so it stands alone.
        var orderedEpisodeIds: [Int64] {
            let included = (includedEpisodeIds ?? "")
                .split(separator: ",").compactMap { Int64($0) }
            let manual = (manualSort ?? "")
                .split(separator: ",").compactMap { Int64($0) }

            // The union, manual order first. Neither field is a superset of the
            // other: "Biohacking Content" carries 51 included against 18
            // manual, while "All Episodes" carries 15 included against 727
            // manual. Treating either one as authoritative discards real
            // membership — preferring manual truncated eleven playlists, and
            // preferring included then cut All Episodes from 691 to 15.
            var seen = Set<Int64>()
            var ordered = [Int64]()
            ordered.reserveCapacity(manual.count + included.count)
            for id in manual where seen.insert(id).inserted {
                ordered.append(id)
            }
            for id in included where seen.insert(id).inserted {
                ordered.append(id)
            }
            return ordered
        }
    }

    struct AudioRecord: Decodable {
        let sourceEpisodeId: Int64
        let present: Bool
        let relativePath: String?
        let sha256: String?

        enum CodingKeys: String, CodingKey {
            case present, sha256
            case sourceEpisodeId = "source_episode_id"
            case relativePath = "relative_path"
        }
    }

    struct PlaybackState: Decodable {
        let currentSourceEpisodeId: Int64?

        enum CodingKeys: String, CodingKey {
            case currentSourceEpisodeId = "current_source_episode_id"
        }
    }

    struct Bundle {
        let manifest: Manifest
        let sourcePodcasts: [SourcePodcast]
        let subscriptions: [Subscription]
        let episodes: [Episode]
        let showSettings: [ShowSetting]
        let playlists: [Playlist]
        let audioRecords: [AudioRecord]
        let directory: URL
        let playbackState: PlaybackState
        let verifiedArtifactChecksums: Int

        static func load(from directory: URL) throws -> Self {
            let manifest: Manifest = try decode("manifest.json", in: directory)
            guard manifest.format == OvercastMigration.format else {
                throw Error.unsupportedFormat(manifest.format)
            }
            guard manifest.formatVersion == OvercastMigration.supportedFormatVersion else {
                throw Error.unsupportedVersion(manifest.formatVersion)
            }
            guard !manifest.testOnly else {
                throw Error.testOnlyBundle
            }
            let verifiedArtifactChecksums = try verifyArtifactChecksums(in: directory)
            let subscriptions: [Subscription] = try decode("subscriptions.json", in: directory)
            let sourcePodcasts: [SourcePodcast] =
                try decodeIfPresent("podcasts.json", in: directory)
                ?? subscriptions.map(SourcePodcast.init(subscription:))
            return Self(
                manifest: manifest,
                sourcePodcasts: sourcePodcasts,
                subscriptions: subscriptions,
                episodes: try decode("episodes.json", in: directory),
                showSettings: try decode("show_settings.json", in: directory),
                playlists: try decode("playlists.json", in: directory),
                audioRecords: try decode("downloaded-audio-inventory.json", in: directory),
                directory: directory,
                playbackState: try decode("playback_state.json", in: directory),
                verifiedArtifactChecksums: verifiedArtifactChecksums
            )
        }

        private static func verifyArtifactChecksums(in directory: URL) throws -> Int {
            let checksumFile = directory.appendingPathComponent("artifact-checksums.json")
            guard FileManager.default.fileExists(atPath: checksumFile.path) else {
                return 0 // Compatibility with bundles made before checksums were added.
            }
            let checksums = try JSONDecoder().decode(
                [String: String].self,
                from: Data(contentsOf: checksumFile)
            )
            for (name, expected) in checksums {
                guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent else {
                    throw Error.invalidArtifactName(name)
                }
                let file = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw Error.missingArtifact(name)
                }
                guard OvercastMigration.fileSHA256(file) == expected else {
                    throw Error.artifactChecksumMismatch(name)
                }
            }
            return checksums.count
        }

        private static func decode<T: Decodable>(_ name: String, in directory: URL) throws -> T {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw Error.missingArtifact(name)
            }
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
        }

        private static func decodeIfPresent<T: Decodable>(
            _ name: String,
            in directory: URL
        ) throws -> T? {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
        }
    }

    struct DryRun {
        let sourceSubscriptions: Int
        let matchedSubscriptions: Int
        let unresolvedSubscriptions: Int
        let statefulEpisodes: Int
        let downloadedEpisodes: Int
        let requiredRefreshes: Int
        let ignoredOvercastDeletionMarkers: Int
    }

    private struct PodcastReconciliation {
        let podcastsBySourceId: [Int64: Podcast]
        /// Loads one show's destination episodes on demand.
        ///
        /// This used to be a `[Int64: [Episode]]` holding every episode of
        /// every show at once. At Nick's library size that is ~101,500 episode
        /// objects, each carrying `showNotes`, `episodeDescription` and
        /// `detailedDescription` — full HTML, routinely tens of kilobytes
        /// apiece. Together with the source side it drove the process past
        /// 16 GB and took the machine down on 2026-07-30. Loading per show
        /// caps the peak at a single podcast's episodes.
        let loadEpisodes: (Int64) -> [PocketCastsDataModel.Episode]
    }

    /// Pocket Casts' `podcastUrl` is the show's website, not its RSS feed.
    /// Reconcile an imported show first by exact episode enclosure overlap,
    /// then by a unique title. A feed/website equality is retained only as an
    /// additional exact signal for private feeds that expose it there.
    private static func reconcilePodcasts(
        bundle: Bundle,
        podcasts: [Podcast],
        dataManager: DataManager
    ) -> PodcastReconciliation {
        // Build only the enclosure index here. Each show's episodes are read,
        // reduced to their download URLs, and released before the next show is
        // read, so peak memory is one podcast rather than the whole library.
        var destinationIdsByEnclosure = [String: Set<Int64>]()
        for podcast in podcasts {
            autoreleasepool {
                let episodes = dataManager.findEpisodesWhere(
                    customWhere: "podcast_id = ?",
                    arguments: [podcast.id]
                )
                for enclosure in episodes.compactMap(\.downloadUrl) where !enclosure.isEmpty {
                    destinationIdsByEnclosure[enclosure, default: []].insert(podcast.id)
                }
            }
        }

        let podcastsById = Dictionary(
            podcasts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let podcastsByURL = Dictionary(
            podcasts.compactMap { podcast in
                canonicalFeedURL(podcast.podcastUrl).map { ($0, [podcast]) }
            },
            uniquingKeysWith: +
        )
        let podcastsByTitle = Dictionary(
            podcasts.map { (normalizedTitle($0.title), [$0]) },
            uniquingKeysWith: +
        )
        let sourceEpisodes = Dictionary(
            grouping: bundle.episodes,
            by: \.sourcePodcastId
        )

        var result = [Int64: Podcast]()
        var claimedDestinationIds = Set<Int64>()
        for sourcePodcast in sourcePodcastsForImport(bundle) {
            var overlapCounts = [Int64: Int]()
            for episode in sourceEpisodes[sourcePodcast.sourcePodcastId] ?? [] {
                for destinationId in destinationIdsByEnclosure[episode.enclosureURL] ?? [] {
                    overlapCounts[destinationId, default: 0] += 1
                }
            }
            let highestOverlap = overlapCounts.values.max() ?? 0
            let overlapCandidates = overlapCounts
                .filter { $0.value == highestOverlap && highestOverlap > 0 }
                .compactMap { podcastsById[$0.key] }

            let feedCandidates = canonicalFeedURL(sourcePodcast.feedURL)
                .flatMap { podcastsByURL[$0] } ?? []
            let titleCandidates = podcastsByTitle[normalizedTitle(sourcePodcast.title)] ?? []
            let candidates = overlapCandidates.count == 1
                ? overlapCandidates
                : (feedCandidates.count == 1 ? feedCandidates : titleCandidates)

            guard candidates.count == 1,
                  let podcast = candidates.first,
                  !claimedDestinationIds.contains(podcast.id)
            else { continue }
            result[sourcePodcast.sourcePodcastId] = podcast
            claimedDestinationIds.insert(podcast.id)
        }
        return PodcastReconciliation(
            podcastsBySourceId: result,
            loadEpisodes: { podcastId in
                dataManager.findEpisodesWhere(
                    customWhere: "podcast_id = ?",
                    arguments: [podcastId]
                )
            }
        )
    }

    /// Holds one show's destination episodes at a time.
    ///
    /// The exporter orders episodes by podcast, so callers walking the source
    /// bundle ask for the same show many times in a row. A single-entry cache
    /// therefore serves almost every lookup without re-querying, while never
    /// holding more than one podcast's episodes in memory.
    final class DestinationEpisodeCache {
        private let load: (Int64) -> [PocketCastsDataModel.Episode]
        private var cachedPodcastId: Int64?
        private var cachedEpisodes: [PocketCastsDataModel.Episode] = []

        init(load: @escaping (Int64) -> [PocketCastsDataModel.Episode]) {
            self.load = load
        }

        func episodes(for podcastId: Int64) -> [PocketCastsDataModel.Episode] {
            if cachedPodcastId == podcastId {
                return cachedEpisodes
            }
            cachedEpisodes = load(podcastId)
            cachedPodcastId = podcastId
            return cachedEpisodes
        }
    }

    private static func normalizedTitle(_ value: String?) -> String {
        value?
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func sourcePodcastsForImport(_ bundle: Bundle) -> [SourcePodcast] {
        var requiredIds = Set(
            bundle.sourcePodcasts.filter(\.subscribed).map(\.sourcePodcastId)
        )
        requiredIds.formUnion(bundle.episodes.lazy.filter {
            shouldRestore($0, restoreDownloads: true)
        }.map(\.sourcePodcastId))
        let episodeById = Dictionary(
            uniqueKeysWithValues: bundle.episodes.map { ($0.sourceEpisodeId, $0) }
        )
        for playlist in bundle.playlists where !playlist.deleted {
            requiredIds.formUnion(
                playlist.orderedEpisodeIds.compactMap { episodeById[$0]?.sourcePodcastId }
            )
        }
        if let currentId = bundle.playbackState.currentSourceEpisodeId,
           let current = bundle.episodes.first(where: { $0.sourceEpisodeId == currentId }) {
            requiredIds.insert(current.sourcePodcastId)
        }
        return bundle.sourcePodcasts.filter {
            requiredIds.contains($0.sourcePodcastId)
        }
    }

    static func importFeedURLs(_ bundle: Bundle) -> [String] {
        Array(Set(sourcePodcastsForImport(bundle).compactMap(\.feedURL))).sorted()
    }

    /// Writes a durable, human-readable preflight report without changing
    /// either app. Exact episode reconciliation remains a post-refresh step,
    /// so this report clearly separates known matches from work that cannot be
    /// verified until Pocket Casts has refreshed the imported feeds.
    static func writePreflightReport(bundle: Bundle, podcasts: [Podcast]) throws -> URL {
        let reconciliation = reconcilePodcasts(
            bundle: bundle,
            podcasts: podcasts,
            dataManager: .sharedManager
        )
        let sourceSubscriptions = bundle.subscriptions.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let unresolved = sourceSubscriptions.filter {
            reconciliation.podcastsBySourceId[$0.sourcePodcastId] == nil
        }
        let missingFeed = sourceSubscriptions.filter { canonicalFeedURL($0.feedURL) == nil }
        let playlistSnapshots = bundle.playlists.filter {
            $0.preset == 0 && !$0.deleted && !$0.orderedEpisodeIds.isEmpty
        }
        let queueEpisodes = bundle.playlists.first {
            $0.preset == 8 && !$0.deleted
        }?.orderedEpisodeIds.count ?? 0
        let untranslatedPlaylists = bundle.playlists.filter {
            !$0.deleted && $0.preset != 8 &&
                !($0.preset == 0 && $0.individualEpisodesOnly)
        }
        let presentAudio = bundle.audioRecords.filter(\.present)
        let missingAudio = bundle.audioRecords.filter { !$0.present }
        let plan = dryRun(bundle: bundle, podcasts: podcasts)

        func subscriptionLine(_ subscription: Subscription) -> String {
            let feed = subscription.feedURL ?? "(missing feed URL)"
            return "- [\(subscription.sourcePodcastId)] \(subscription.title) — \(feed)"
        }

        func playlistLine(_ playlist: Playlist) -> String {
            "- \(playlist.title) (Overcast preset \(playlist.preset), \(playlist.orderedEpisodeIds.count) explicit episodes)"
        }

        let unresolvedLines = unresolved.isEmpty
            ? "- None"
            : unresolved.map(subscriptionLine).joined(separator: "\n")
        let missingFeedLines = missingFeed.isEmpty
            ? "- None"
            : missingFeed.map(subscriptionLine).joined(separator: "\n")
        let untranslatedLines = untranslatedPlaylists.isEmpty
            ? "- None"
            : untranslatedPlaylists.map(playlistLine).joined(separator: "\n")

        let report = """
        Overcast → Pocket Casts Migration Preflight

        This report is read-only. No Pocket Casts account or Overcast data was changed.

        Source inventory
        - Subscriptions: \(bundle.subscriptions.count)
        - Library shows needed for state restoration: \(sourcePodcastsForImport(bundle).count)
        - Feeds to import temporarily: \(importFeedURLs(bundle).count)
        - Episodes: \(bundle.episodes.count)
        - Stateful episodes: \(plan.statefulEpisodes)
        - Download candidates: \(plan.downloadedEpisodes)
        - Preserved audio files: \(presentAudio.count)
        - Missing source audio files: \(missingAudio.count)
        - Queue episodes: \(queueEpisodes)
        - Custom playlist snapshots eligible for restoration: \(playlistSnapshots.count)

        Subscription reconciliation before import
        - Already present in Pocket Casts by canonical feed URL: \(plan.matchedSubscriptions)
        - Not yet present or unresolved: \(plan.unresolvedSubscriptions)

        Unresolved subscriptions
        \(unresolvedLines)

        Subscriptions missing a usable feed URL
        \(missingFeedLines)

        Safety decisions
        - \(plan.ignoredOvercastDeletionMarkers) raw Overcast removal markers will NOT be mapped to Pocket Casts archive or deletion state.
        - Missing audio will NOT be redownloaded unless the operator explicitly opts in.
        - Preserved audio is imported only after its SHA-256 hash matches the bundle inventory.
        - Episode state is applied only after an existing Pocket Casts episode matches by enclosure URL, or by audited title/date or title/duration fallback.
        - Exact unresolved episode counts are available only after subscriptions import and feed refresh.
        - Custom playlist membership is restored as a manual snapshot; Overcast-only smart rules cannot remain dynamic.

        Overcast smart playlists preserved but not automatically translated
        \(untranslatedLines)
        """

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("overcast-migration-preflight-\(UUID().uuidString).txt")
        try Data(report.utf8).write(to: file, options: .atomic)
        return file
    }

    struct QAReceipt: Encodable {
        let passed: Bool
        let format: String
        let formatVersion: Int
        let subscriptions: Int
        let episodes: Int
        let unresolvedSubscriptions: Int
        let ignoredOvercastDeletionMarkers: Int
        let audioInventoryRecords: Int
        let generatedOPMLFeeds: Int
        let reportBytes: Int
        let verifiedArtifactChecksums: Int

        enum CodingKeys: String, CodingKey {
            case passed, format, subscriptions, episodes
            case formatVersion = "format_version"
            case unresolvedSubscriptions = "unresolved_subscriptions"
            case ignoredOvercastDeletionMarkers = "ignored_overcast_deletion_markers"
            case audioInventoryRecords = "audio_inventory_records"
            case generatedOPMLFeeds = "generated_opml_feeds"
            case reportBytes = "report_bytes"
            case verifiedArtifactChecksums = "verified_artifact_checksums"
        }
    }

    /// Runs the real preflight path in a disposable Debug app sandbox. This
    /// never invokes subscription import or any restoration method.
    static func shouldRunInstalledPreflightRehearsal() -> Bool {
        if ProcessInfo.processInfo.arguments.contains(qaLaunchArgument) {
            return true
        }

        guard let documents = try? documentsDirectory() else { return false }
        return FileManager.default.fileExists(
            atPath: documents.appendingPathComponent(qaMarkerFileName).path
        )
    }

    static func installedBundleURL() throws -> URL {
        try documentsDirectory().appendingPathComponent(
            qaBundleDirectoryName,
            isDirectory: true
        )
    }

    @discardableResult
    static func runInstalledPreflightRehearsal() throws -> URL {
        let documents = try documentsDirectory()
        let bundle = try Bundle.load(
            from: documents.appendingPathComponent(qaBundleDirectoryName, isDirectory: true)
        )
        let plan = dryRun(bundle: bundle, podcasts: [])
        let reportURL = try writePreflightReport(bundle: bundle, podcasts: [])
        defer { try? FileManager.default.removeItem(at: reportURL) }
        let report = try Data(contentsOf: reportURL)
        guard String(decoding: report, as: UTF8.self)
            .contains("raw Overcast removal markers will NOT be mapped")
        else {
            throw Error.invalidQAOutput("Preflight report is missing the deletion-marker safety decision.")
        }

        let opmlURL = try writeOPML(bundle: bundle)
        defer { try? FileManager.default.removeItem(at: opmlURL) }
        let opml = try String(contentsOf: opmlURL)
        let generatedFeeds = opml.components(separatedBy: "xmlUrl=").count - 1
        let expectedFeeds = importFeedURLs(bundle).count
        guard generatedFeeds == expectedFeeds else {
            throw Error.invalidQAOutput(
                "OPML contains \(generatedFeeds) feeds; expected \(expectedFeeds)."
            )
        }

        let receipt = QAReceipt(
            passed: true,
            format: bundle.manifest.format,
            formatVersion: bundle.manifest.formatVersion,
            subscriptions: bundle.subscriptions.count,
            episodes: bundle.episodes.count,
            unresolvedSubscriptions: plan.unresolvedSubscriptions,
            ignoredOvercastDeletionMarkers: plan.ignoredOvercastDeletionMarkers,
            audioInventoryRecords: bundle.audioRecords.count,
            generatedOPMLFeeds: generatedFeeds,
            reportBytes: report.count,
            verifiedArtifactChecksums: bundle.verifiedArtifactChecksums
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let receiptURL = documents.appendingPathComponent(qaReceiptFileName)
        try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        try report.write(
            to: documents.appendingPathComponent("OvercastMigrationQAPreflight.txt"),
            options: .atomic
        )
        return receiptURL
    }

    private static func documentsDirectory() throws -> URL {
        guard let directory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw Error.invalidQAOutput("The app Documents directory is unavailable.")
        }
        return directory
    }

    struct Reconciliation {
        var matchedSubscriptions = 0
        var unresolvedSubscriptions = 0
        var matchedEpisodes = 0
        var unresolvedEpisodes = 0
        var restoredPlaybackStates = 0
        var ignoredOvercastDeletionMarkers = 0
        var restoredStars = 0
        var queuedRedownloads = 0
        var restoredShowSettings = 0
        var restoredUnsubscribedLibraryShows = 0
        var restoredQueueEpisodes = 0
        var restoredPlaylists = 0
        var unresolvedCollectionEpisodes = 0
        var importedAudioFiles = 0
        var unresolvedAudioFiles = 0
        var restoredHistoryDates = 0
        var restoredCurrentEpisode = false
        var unresolvedRecords = [UnresolvedRecord]()

        mutating func merge(_ other: Self) {
            matchedSubscriptions += other.matchedSubscriptions
            unresolvedSubscriptions += other.unresolvedSubscriptions
            matchedEpisodes += other.matchedEpisodes
            unresolvedEpisodes += other.unresolvedEpisodes
            restoredPlaybackStates += other.restoredPlaybackStates
            ignoredOvercastDeletionMarkers += other.ignoredOvercastDeletionMarkers
            restoredStars += other.restoredStars
            queuedRedownloads += other.queuedRedownloads
            restoredShowSettings += other.restoredShowSettings
            restoredUnsubscribedLibraryShows += other.restoredUnsubscribedLibraryShows
            restoredQueueEpisodes += other.restoredQueueEpisodes
            restoredPlaylists += other.restoredPlaylists
            unresolvedCollectionEpisodes += other.unresolvedCollectionEpisodes
            importedAudioFiles += other.importedAudioFiles
            unresolvedAudioFiles += other.unresolvedAudioFiles
            restoredHistoryDates += other.restoredHistoryDates
            restoredCurrentEpisode = restoredCurrentEpisode || other.restoredCurrentEpisode
            unresolvedRecords += other.unresolvedRecords
        }
    }

    struct UnresolvedRecord {
        let stage: String
        let sourceEpisodeId: Int64
        let podcastTitle: String
        let episodeTitle: String
        let publishedTime: Int64
        let enclosureURL: String
        let reason: String
    }

    struct DestinationAudit {
        var matchedLibraryShows = 0
        var matchedSubscriptions = 0
        var unresolvedSubscriptions = 0
        var matchedStatefulEpisodes = 0
        var verifiedPlaybackStates = 0
        var verifiedStars = 0
        var verifiedHistoryDates = 0
        var verifiedShowSettings = 0
        var verifiedUnsubscribedLibraryShows = 0
        var expectedQueueEpisodes = 0
        var actualQueueEpisodes = 0
        var queueOrderMatches = false
        var verifiedPlaylistSnapshots = 0
        var verifiedAudioFiles = 0
    }

    static func dryRun(bundle: Bundle, podcasts: [Podcast]) -> DryRun {
        let podcastsBySourceId = reconcilePodcasts(
            bundle: bundle,
            podcasts: podcasts,
            dataManager: .sharedManager
        ).podcastsBySourceId
        let matched = bundle.subscriptions.filter {
            podcastsBySourceId[$0.sourcePodcastId] != nil
        }.count
        let statefulEpisodes = bundle.episodes.filter {
            $0.playbackState != .notStarted || $0.starredTime > 0
        }.count
        return DryRun(
            sourceSubscriptions: bundle.subscriptions.count,
            matchedSubscriptions: matched,
            unresolvedSubscriptions: bundle.subscriptions.count - matched,
            statefulEpisodes: statefulEpisodes,
            downloadedEpisodes: bundle.episodes.filter(\.downloadRequested).count,
            requiredRefreshes: sourcePodcastsForImport(bundle).count,
            ignoredOvercastDeletionMarkers: bundle.episodes.filter(\.overcastDeleted).count
        )
    }

    /// Applies state only to episodes that already exist in Pocket Casts. The
    /// caller must first import subscriptions and refresh their feeds using the
    /// normal app services; this method never manufactures database rows.
    static func restoreExistingState(
        bundle: Bundle,
        podcasts: [Podcast],
        dataManager: DataManager = .sharedManager,
        downloadManager: DownloadManager = .shared,
        restoreDownloads: Bool = false
    ) -> Reconciliation {
        var report = Reconciliation()
        let reconciliation = reconcilePodcasts(
            bundle: bundle,
            podcasts: podcasts,
            dataManager: dataManager
        )
        let podcastsBySourceId = reconciliation.podcastsBySourceId
        for subscription in bundle.subscriptions {
            guard podcastsBySourceId[subscription.sourcePodcastId] != nil else {
                report.unresolvedSubscriptions += 1
                continue
            }
            report.matchedSubscriptions += 1
        }

        for setting in bundle.showSettings {
            guard let podcast = podcastsBySourceId[setting.sourcePodcastId] else { continue }
            let skips = setting.skipTimes
            var changed = false
            if let speed = setting.playbackSpeed {
                podcast.playbackSpeed = speed
                changed = true
            }
            if skips.intro > 0 {
                podcast.startFrom = Int32(clamping: skips.intro)
                changed = true
            }
            if skips.outro > 0 {
                podcast.skipLast = Int32(clamping: skips.outro)
                changed = true
            }
            if setting.downloadPolicy != 0 {
                podcast.autoDownloadSetting = AutoDownloadSetting.latest.rawValue
                changed = true
            }
            if setting.itemLimit > 0 {
                podcast.autoArchiveEpisodeLimit = Int32(clamping: setting.itemLimit)
                changed = true
            }
            if changed {
                podcast.syncStatus = SyncStatus.notSynced.rawValue
                dataManager.save(podcast: podcast)
                report.restoredShowSettings += 1
            }
        }

        let episodesByPodcastId = DestinationEpisodeCache(load: reconciliation.loadEpisodes)

        for source in bundle.episodes where shouldRestore(source, restoreDownloads: restoreDownloads) {
            guard let podcast = podcastsBySourceId[source.sourcePodcastId] else {
                report.unresolvedEpisodes += 1
                report.unresolvedRecords.append(
                    unresolvedRecord(source, stage: "episode state", reason: "subscription feed was not matched")
                )
                continue
            }
            let match = episodeMatch(source, in: episodesByPodcastId.episodes(for: podcast.id))
            guard let destination = match.episode else {
                report.unresolvedEpisodes += 1
                report.unresolvedRecords.append(
                    unresolvedRecord(source, stage: "episode state", reason: match.failureReason)
                )
                continue
            }
            report.matchedEpisodes += 1
            if source.playbackState != .notStarted {
                let position = source.playbackState == .completed ? destination.duration : Double(source.progressSeconds)
                dataManager.saveEpisode(playedUpTo: position, episode: destination, updateSyncFlag: true)
                dataManager.saveEpisode(
                    playingStatus: source.playbackState == .completed ? .completed : .inProgress,
                    episode: destination,
                    updateSyncFlag: true
                )
                report.restoredPlaybackStates += 1
            }
            if source.lastPlayedTime > 0 {
                destination.lastPlaybackInteractionDate = Date(
                    timeIntervalSince1970: TimeInterval(source.lastPlayedTime)
                )
                dataManager.save(episode: destination)
                report.restoredHistoryDates += 1
            }
            if source.overcastDeleted {
                report.ignoredOvercastDeletionMarkers += 1
            }
            if source.starredTime > 0 {
                dataManager.saveEpisode(starred: true, episode: destination, updateSyncFlag: true)
                report.restoredStars += 1
            }
            if restoreDownloads, source.downloadRequested {
                downloadManager.addToQueue(episodeUuid: destination.uuid, fireNotification: false, autoDownloadStatus: .notSpecified)
                report.queuedRedownloads += 1
            }
        }
        if let currentId = bundle.playbackState.currentSourceEpisodeId,
           let source = bundle.episodes.first(where: { $0.sourceEpisodeId == currentId }),
           let podcast = podcastsBySourceId[source.sourcePodcastId],
           let current = matchingEpisode(source, in: episodesByPodcastId.episodes(for: podcast.id)) {
            PlaybackManager.shared.load(episode: current, autoPlay: false, overrideUpNext: false)
            report.restoredCurrentEpisode = true
        }
        return report
    }

    static func restorePreservedAudio(
        bundle: Bundle,
        podcasts: [Podcast],
        dataManager: DataManager = .sharedManager,
        downloadManager: DownloadManager = .shared,
        limit: Int? = nil
    ) -> Reconciliation {
        var report = Reconciliation()
        let reconciliation = reconcilePodcasts(
            bundle: bundle,
            podcasts: podcasts,
            dataManager: dataManager
        )
        let sourcePodcastById = reconciliation.podcastsBySourceId
        let destinationEpisodes = DestinationEpisodeCache(load: reconciliation.loadEpisodes)
        let sourceEpisodes = Dictionary(uniqueKeysWithValues: bundle.episodes.map { ($0.sourceEpisodeId, $0) })

        let presentAudio = bundle.audioRecords.filter(\.present)
        let candidates = limit == nil ? presentAudio : presentAudio.filter {
            guard let relativePath = $0.relativePath,
                  let file = preservedAudioURL(relativePath, in: bundle.directory)
            else { return false }
            return FileManager.default.fileExists(atPath: file.path)
        }
        for audio in limit.map({ Array(candidates.prefix($0)) }) ?? candidates {
            guard let relativePath = audio.relativePath,
                  let expectedHash = audio.sha256,
                  let source = sourceEpisodes[audio.sourceEpisodeId],
                  let podcast = sourcePodcastById[source.sourcePodcastId]
            else {
                report.unresolvedAudioFiles += 1
                continue
            }
            let match = episodeMatch(source, in: destinationEpisodes.episodes(for: podcast.id))
            guard let destination = match.episode else {
                report.unresolvedAudioFiles += 1
                report.unresolvedRecords.append(
                    unresolvedRecord(source, stage: "preserved audio", reason: match.failureReason)
                )
                continue
            }
            guard let sourceFile = preservedAudioURL(
                relativePath,
                in: bundle.directory
            ) else {
                report.unresolvedAudioFiles += 1
                report.unresolvedRecords.append(
                    unresolvedRecord(
                        source,
                        stage: "preserved audio",
                        reason: "inventory path is outside the bundle audio directory"
                    )
                )
                continue
            }
            guard fileSHA256(sourceFile) == expectedHash else {
                report.unresolvedAudioFiles += 1
                report.unresolvedRecords.append(
                    unresolvedRecord(source, stage: "preserved audio", reason: "source file is missing or failed SHA-256")
                )
                continue
            }
            downloadManager.processEpisode(destination, downloadedFile: sourceFile, reportedContentType: nil, copyFile: true)
            if destination.downloaded(pathFinder: downloadManager) {
                report.importedAudioFiles += 1
            } else {
                report.unresolvedAudioFiles += 1
            }
        }
        return report
    }

    private static func fileSHA256(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try? handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func preservedAudioURL(
        _ relativePath: String,
        in directory: URL
    ) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            return nil
        }
        let audioDirectory = directory.appendingPathComponent(
            "audio",
            isDirectory: true
        ).standardizedFileURL
        let candidate = directory.appendingPathComponent(relativePath)
            .standardizedFileURL
        guard candidate.path.hasPrefix(audioDirectory.path + "/") else {
            return nil
        }
        return candidate
    }

    static func restoreCollections(
        bundle: Bundle,
        podcasts: [Podcast],
        dataManager: DataManager = .sharedManager,
        playbackQueue: PlaybackQueue = PlaybackQueue()
    ) -> Reconciliation {
        var report = Reconciliation()
        let reconciliation = reconcilePodcasts(
            bundle: bundle,
            podcasts: podcasts,
            dataManager: dataManager
        )
        let sourcePodcastById = reconciliation.podcastsBySourceId
        let destinationEpisodes = DestinationEpisodeCache(load: reconciliation.loadEpisodes)
        let sourceEpisodes = Dictionary(uniqueKeysWithValues: bundle.episodes.map { ($0.sourceEpisodeId, $0) })

        func matched(_ ids: [Int64]) -> [PocketCastsDataModel.Episode] {
            ids.compactMap { id in
                guard let source = sourceEpisodes[id],
                      let podcast = sourcePodcastById[source.sourcePodcastId]
                else {
                    report.unresolvedCollectionEpisodes += 1
                    return nil
                }
                let match = episodeMatch(source, in: destinationEpisodes.episodes(for: podcast.id))
                guard let episode = match.episode else {
                    report.unresolvedCollectionEpisodes += 1
                    report.unresolvedRecords.append(
                        unresolvedRecord(source, stage: "queue or playlist", reason: match.failureReason)
                    )
                    return nil
                }
                return episode
            }
        }

        if let queue = bundle.playlists.first(where: { $0.preset == 8 && !$0.deleted }) {
            let episodes = matched(queue.orderedEpisodeIds)
            if !episodes.isEmpty || queue.orderedEpisodeIds.isEmpty {
                playbackQueue.removeAllEpisodes()
            }
            if !episodes.isEmpty {
                playbackQueue.bulkAdd(episodes, toTop: false)
            }
            report.restoredQueueEpisodes = episodes.count
        }

        // A playlist bearing a source playlist's name is one this migration
        // created on an earlier run, so replace it rather than skip it.
        //
        // Skipping on a name collision made the migration impossible to repair:
        // a re-run signs in, syncs the previous run's playlists down, sees the
        // names already present, and declines to touch them. That is how the
        // 2026-07-30 run left eleven truncated playlists in place — the fix for
        // the truncation could not apply because the truncated playlists
        // themselves blocked it.
        //
        // `createManualPlaylists` splits oversized playlists into numbered
        // batches, so matching is by prefix as well as exact name.
        for playlist in bundle.playlists
            where playlist.preset == 0 && !playlist.deleted && !playlist.orderedEpisodeIds.isEmpty {
            let episodes = matched(playlist.orderedEpisodeIds)
            guard !episodes.isEmpty else { continue }
            for existing in dataManager.allPlaylists(includeDeleted: false)
            where existing.playlistName == playlist.title
                || existing.playlistName.hasPrefix("\(playlist.title) ") {
                dataManager.delete(playlist: existing)
            }
            report.restoredPlaylists += dataManager.createManualPlaylists(
                from: episodes,
                batchSize: Constants.Limits.maxFilterItems,
                baseName: playlist.title
            )
        }
        return report
    }

    /// OPML temporarily subscribes to old shows whose episodes are needed for
    /// history, stars, queues, playlists, or preserved audio. Restore the
    /// source subscription boundary after all episode work is complete while
    /// retaining Pocket Casts' native show and episode rows.
    static func restoreSubscriptionMembership(
        bundle: Bundle,
        podcasts: [Podcast],
        dataManager: DataManager = .sharedManager
    ) -> Reconciliation {
        var report = Reconciliation()
        let reconciliation = reconcilePodcasts(
            bundle: bundle,
            podcasts: podcasts,
            dataManager: dataManager
        )
        for source in sourcePodcastsForImport(bundle) where !source.subscribed {
            guard let podcast = reconciliation.podcastsBySourceId[source.sourcePodcastId]
            else { continue }
            if podcast.isSubscribed() {
                podcast.subscribed = 0
                podcast.syncStatus = SyncStatus.notSynced.rawValue
                dataManager.save(podcast: podcast)
            }
            report.restoredUnsubscribedLibraryShows += 1
        }
        return report
    }

    /// Reads the destination back after Pocket Casts' final refresh/sync.
    /// This is deliberately separate from the write counters so a successful
    /// API call cannot be mistaken for durable destination proof.
    static func auditDestination(
        bundle: Bundle,
        podcasts: [Podcast],
        dataManager: DataManager = .sharedManager,
        downloadManager: DownloadManager = .shared,
        audioLimit: Int? = nil
    ) -> DestinationAudit {
        var audit = DestinationAudit()
        let reconciliation = reconcilePodcasts(
            bundle: bundle,
            podcasts: podcasts,
            dataManager: dataManager
        )
        let podcastsBySourceId = reconciliation.podcastsBySourceId
        let episodesByPodcastId = DestinationEpisodeCache(load: reconciliation.loadEpisodes)
        audit.matchedLibraryShows = podcastsBySourceId.count
        audit.matchedSubscriptions = bundle.subscriptions.filter {
            podcastsBySourceId[$0.sourcePodcastId] != nil
        }.count
        audit.unresolvedSubscriptions = bundle.subscriptions.count - audit.matchedSubscriptions
        audit.verifiedUnsubscribedLibraryShows = sourcePodcastsForImport(bundle).filter {
            !$0.subscribed &&
                podcastsBySourceId[$0.sourcePodcastId]?.isSubscribed() == false
        }.count

        for source in bundle.episodes where shouldRestore(source, restoreDownloads: false) {
            guard let podcast = podcastsBySourceId[source.sourcePodcastId],
                  let destination = matchingEpisode(
                      source,
                      in: episodesByPodcastId.episodes(for: podcast.id)
                  )
            else { continue }
            audit.matchedStatefulEpisodes += 1
            switch source.playbackState {
            case .notStarted:
                break
            case .inProgress:
                if destination.playingStatus == PlayingStatus.inProgress.rawValue,
                   abs(destination.playedUpTo - Double(source.progressSeconds)) <= 1 {
                    audit.verifiedPlaybackStates += 1
                }
            case .completed:
                if destination.playingStatus == PlayingStatus.completed.rawValue {
                    audit.verifiedPlaybackStates += 1
                }
            }
            if source.starredTime > 0, destination.keepEpisode {
                audit.verifiedStars += 1
            }
            if source.lastPlayedTime > 0,
               let date = destination.lastPlaybackInteractionDate,
               abs(date.timeIntervalSince1970 - Double(source.lastPlayedTime)) <= 1 {
                audit.verifiedHistoryDates += 1
            }
        }

        for setting in bundle.showSettings {
            guard let podcast = podcastsBySourceId[setting.sourcePodcastId] else { continue }
            var verified = true
            if let speed = setting.playbackSpeed {
                verified = verified && abs(podcast.playbackSpeed - speed) < 0.001
            }
            let skips = setting.skipTimes
            if skips.intro > 0 {
                verified = verified && podcast.startFrom == Int32(clamping: skips.intro)
            }
            if skips.outro > 0 {
                verified = verified && podcast.skipLast == Int32(clamping: skips.outro)
            }
            if setting.downloadPolicy != 0 {
                verified = verified &&
                    podcast.autoDownloadSetting == AutoDownloadSetting.latest.rawValue
            }
            if setting.itemLimit > 0 {
                verified = verified &&
                    podcast.autoArchiveEpisodeLimit == Int32(clamping: setting.itemLimit)
            }
            if verified {
                audit.verifiedShowSettings += 1
            }
        }

        let sourceEpisodes = Dictionary(
            uniqueKeysWithValues: bundle.episodes.map { ($0.sourceEpisodeId, $0) }
        )
        func matchedUUIDs(_ ids: [Int64]) -> [String] {
            ids.compactMap { id in
                guard let source = sourceEpisodes[id],
                      let podcast = podcastsBySourceId[source.sourcePodcastId]
                else { return nil }
                return matchingEpisode(
                    source,
                    in: episodesByPodcastId.episodes(for: podcast.id)
                )?.uuid
            }
        }
        if let queue = bundle.playlists.first(where: { $0.preset == 8 && !$0.deleted }) {
            let expected = matchedUUIDs(queue.orderedEpisodeIds)
            let actual = dataManager.allUpNextPlaylistEpisodes().map(\.episodeUuid)
            audit.expectedQueueEpisodes = expected.count
            audit.actualQueueEpisodes = actual.count
            audit.queueOrderMatches = actual == expected
        }

        let playlistNames = Set(
            dataManager.allPlaylists(includeDeleted: false).map(\.playlistName)
        )
        audit.verifiedPlaylistSnapshots = bundle.playlists.filter {
            $0.preset == 0 && !$0.deleted && !$0.orderedEpisodeIds.isEmpty &&
                playlistNames.contains($0.title)
        }.count

        let presentAudio = bundle.audioRecords.filter(\.present)
        let candidates = audioLimit == nil ? presentAudio : presentAudio.filter {
            guard let relativePath = $0.relativePath,
                  let file = preservedAudioURL(relativePath, in: bundle.directory)
            else { return false }
            return FileManager.default.fileExists(atPath: file.path)
        }
        for audio in audioLimit.map({ Array(candidates.prefix($0)) }) ?? candidates {
            guard let source = sourceEpisodes[audio.sourceEpisodeId],
                  let podcast = podcastsBySourceId[source.sourcePodcastId],
                  let destination = matchingEpisode(
                      source,
                      in: episodesByPodcastId.episodes(for: podcast.id)
                  ),
                  destination.downloaded(pathFinder: downloadManager)
            else { continue }
            audit.verifiedAudioFiles += 1
        }
        return audit
    }

    static func writeReconciliationReport(
        bundle: Bundle,
        report: Reconciliation,
        stage: String,
        audit: DestinationAudit? = nil
    ) throws -> URL {
        let unresolved = report.unresolvedRecords.isEmpty
            ? "- None"
            : report.unresolvedRecords.map { record in
                let podcast = record.podcastTitle.replacingOccurrences(of: "\n", with: " ")
                let title = record.episodeTitle.replacingOccurrences(of: "\n", with: " ")
                return "- [\(record.sourceEpisodeId)] \(podcast) — \(title) — published \(record.publishedTime) — \(record.enclosureURL) — \(record.reason)"
            }.joined(separator: "\n")
        let auditSection: String
        if let audit {
            auditSection = """

            Post-refresh destination audit
            - Matched library shows: \(audit.matchedLibraryShows)
            - Matched subscriptions: \(audit.matchedSubscriptions)
            - Unresolved subscriptions: \(audit.unresolvedSubscriptions)
            - Matched stateful episodes: \(audit.matchedStatefulEpisodes)
            - Playback states verified: \(audit.verifiedPlaybackStates)
            - Stars verified: \(audit.verifiedStars)
            - Listening-history dates verified: \(audit.verifiedHistoryDates)
            - Show-setting records verified: \(audit.verifiedShowSettings)
            - Old library shows verified unsubscribed: \(audit.verifiedUnsubscribedLibraryShows)
            - Queue episodes expected after matching: \(audit.expectedQueueEpisodes)
            - Queue episodes found: \(audit.actualQueueEpisodes)
            - Exact queue order verified: \(audit.queueOrderMatches)
            - Playlist snapshots verified by name: \(audit.verifiedPlaylistSnapshots)
            - Preserved audio files verified: \(audit.verifiedAudioFiles)
            """
        } else {
            auditSection = """

            Post-refresh destination audit
            - Not run for this staged report.
            """
        }
        let contents = """
        Overcast → Pocket Casts Reconciliation

        Stage: \(stage)

        Source
        - Library shows: \(bundle.sourcePodcasts.count)
        - Library shows needed for state restoration: \(sourcePodcastsForImport(bundle).count)
        - Subscriptions: \(bundle.manifest.counts.subscriptions)
        - Episodes: \(bundle.manifest.counts.episodes)
        - Download candidates: \(bundle.manifest.counts.downloadedCandidates)
        - In-progress episodes: \(bundle.manifest.counts.inProgress)
        - Completed episodes: \(bundle.manifest.counts.completed)
        - Starred episodes: \(bundle.manifest.counts.starred)
        - Playlists: \(bundle.manifest.counts.playlists)

        Destination results
        - Matched subscriptions: \(report.matchedSubscriptions)
        - Unresolved subscriptions: \(report.unresolvedSubscriptions)
        - Matched stateful episodes: \(report.matchedEpisodes)
        - Unresolved stateful episodes: \(report.unresolvedEpisodes)
        - Playback states restored: \(report.restoredPlaybackStates)
        - Stars restored: \(report.restoredStars)
        - Listening-history dates restored: \(report.restoredHistoryDates)
        - Current episode restored: \(report.restoredCurrentEpisode)
        - Show settings restored: \(report.restoredShowSettings)
        - Old library shows restored to unsubscribed: \(report.restoredUnsubscribedLibraryShows)
        - Queue episodes restored: \(report.restoredQueueEpisodes)
        - Playlist snapshots restored: \(report.restoredPlaylists)
        - Unresolved queue or playlist episodes: \(report.unresolvedCollectionEpisodes)
        - Preserved audio files imported: \(report.importedAudioFiles)
        - Unresolved preserved audio files: \(report.unresolvedAudioFiles)
        - Downloads queued: \(report.queuedRedownloads)
        - Raw Overcast deletion markers ignored: \(report.ignoredOvercastDeletionMarkers)

        Unresolved episode details
        \(unresolved)
        \(auditSection)
        """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("overcast-migration-reconciliation-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: file, options: .atomic)
        return file
    }

    /// Captures Pocket Casts' database, WAL, and preferences before the first
    /// migration write. The backup uses the app's existing `.pcasts` format
    /// and remains in Documents so it can be copied off the device.
    static func writePocketCastsBackup() throws -> URL {
        let documents = try documentsDirectory()
        let directory = documents.appendingPathComponent(
            "OvercastMigrationBackups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = directory.appendingPathComponent(
            "PocketCasts-before-Overcast-\(timestamp).pcasts",
            isDirectory: true
        )
        let wrapper = try PCBundleDoc().fileWrapper()
        try wrapper.write(to: backup, originalContentsURL: nil)
        return backup
    }

    static func preserveReconciliationReport(
        _ report: URL,
        rehearsal: Bool
    ) throws -> URL {
        let name = rehearsal
            ? "OvercastMigrationQACompleteReport.txt"
            : "OvercastMigrationCompleteReport.txt"
        let destination = try documentsDirectory().appendingPathComponent(name)
        try Data(contentsOf: report).write(to: destination, options: .atomic)
        return destination
    }

    /// Creates a temporary OPML document for the existing, audited OPML
    /// importer. The caller is responsible for presenting an explicit import
    /// action; merely writing this file never changes a subscription.
    static func writeOPML(bundle: Bundle) throws -> URL {
        let feeds = importFeedURLs(bundle)
        let outlines = feeds.map { feed in
            "  <outline type=\"rss\" xmlUrl=\"\(xmlEscaped(feed))\" />"
        }.joined(separator: "\n")
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
        <body>
        \(outlines)
        </body>
        </opml>
        """
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("overcast-migration-\(UUID().uuidString).opml")
        try Data(opml.utf8).write(to: file, options: .atomic)
        return file
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func shouldRestore(_ episode: Episode, restoreDownloads: Bool) -> Bool {
        episode.playbackState != .notStarted || episode.starredTime > 0 ||
            episode.lastPlayedTime > 0 || (restoreDownloads && episode.downloadRequested)
    }

    private struct EpisodeMatch {
        let episode: PocketCastsDataModel.Episode?
        let failureReason: String
    }

    private static func episodeMatch(_ source: Episode, in destination: [PocketCastsDataModel.Episode]) -> EpisodeMatch {
        let exact = destination.filter { $0.downloadUrl == source.enclosureURL }
        if exact.count == 1 {
            return EpisodeMatch(episode: exact[0], failureReason: "")
        }
        if exact.count > 1 {
            return EpisodeMatch(episode: nil, failureReason: "multiple enclosure-URL matches")
        }
        let published = Date(timeIntervalSince1970: TimeInterval(source.publishedTime))
        let titleAndDate = destination.filter {
            $0.title == source.title && abs(($0.publishedDate ?? .distantPast).timeIntervalSince(published)) < 300
        }
        if titleAndDate.count == 1 {
            return EpisodeMatch(episode: titleAndDate[0], failureReason: "")
        }
        if titleAndDate.count > 1 {
            return EpisodeMatch(episode: nil, failureReason: "multiple title-and-date matches")
        }
        let titleAndDuration = destination.filter {
            $0.title == source.title && abs($0.duration - Double(source.advertisedDuration)) < 2
        }
        if titleAndDuration.count == 1 {
            return EpisodeMatch(episode: titleAndDuration[0], failureReason: "")
        }
        let reason = titleAndDuration.isEmpty
            ? "no enclosure-URL, title-and-date, or title-and-duration match"
            : "multiple title-and-duration matches"
        return EpisodeMatch(episode: nil, failureReason: reason)
    }

    private static func matchingEpisode(
        _ source: Episode,
        in destination: [PocketCastsDataModel.Episode]
    ) -> PocketCastsDataModel.Episode? {
        episodeMatch(source, in: destination).episode
    }

    private static func unresolvedRecord(
        _ source: Episode,
        stage: String,
        reason: String
    ) -> UnresolvedRecord {
        UnresolvedRecord(
            stage: stage,
            sourceEpisodeId: source.sourceEpisodeId,
            podcastTitle: source.podcastTitle,
            episodeTitle: source.title,
            publishedTime: source.publishedTime,
            enclosureURL: source.enclosureURL,
            reason: reason
        )
    }

    static func canonicalFeedURL(_ raw: String?) -> String? {
        guard var components = raw.flatMap(URLComponents.init(string:)) else { return nil }
        components.fragment = nil
        components.host = components.host?.lowercased()
        components.scheme = components.scheme?.lowercased()
        var value = components.string
        if value?.hasSuffix("/") == true {
            value?.removeLast()
        }
        return value
    }

    enum Error: LocalizedError {
        case missingArtifact(String)
        case unsupportedFormat(String)
        case unsupportedVersion(Int)
        case testOnlyBundle
        case invalidQAOutput(String)
        case invalidArtifactName(String)
        case artifactChecksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case let .missingArtifact(name): "Migration bundle is missing \(name)."
            case let .unsupportedFormat(format): "Unsupported migration format: \(format)."
            case let .unsupportedVersion(version): "Unsupported migration format version: \(version)."
            case .testOnlyBundle: "A test-only migration bundle cannot be imported."
            case let .invalidQAOutput(message): "Migration rehearsal failed: \(message)"
            case let .invalidArtifactName(name): "Migration bundle contains an invalid artifact name: \(name)."
            case let .artifactChecksumMismatch(name): "Migration bundle artifact failed its checksum: \(name)."
            }
        }
    }
}

/// Runs the complete migration through Pocket Casts' normal import, model,
/// queue, download, and refresh services. The developer screen provides the
/// explicit production confirmation; the rehearsal mode is for a disposable
/// simulator and imports only one audio file to prove that path without
/// duplicating the full archive.
@MainActor
final class OvercastMigrationRunner: ObservableObject {
    enum Mode {
        case rehearsal
        case production

        var audioLimit: Int? {
            switch self {
            case .rehearsal: 1
            case .production: nil
            }
        }

        var reportStage: String {
            switch self {
            case .rehearsal: "Complete disposable-simulator rehearsal"
            case .production: "Complete production import"
            }
        }

        var isRehearsal: Bool {
            switch self {
            case .rehearsal: true
            case .production: false
            }
        }
    }

    @Published private(set) var isRunning = false
    /// Every transition is echoed to stdout. The migration is normally driven
    /// unattended from `scripts/overcast-migration-run.sh`, where a status
    /// string that only reaches the developer UI is indistinguishable from a
    /// hang. `[overcast-migration]` is the greppable prefix.
    @Published private(set) var status = "Ready" {
        didSet {
            guard status != oldValue else { return }
            print("[overcast-migration] \(status)")
        }
    }
    @Published private(set) var backupURL: URL?
    @Published private(set) var reportURL: URL?

    private var bundle: OvercastMigration.Bundle?
    private var mode: Mode?
    private var opmlURL: URL?
    private var notificationTokens = [NSObjectProtocol]()
    private var securityScopedURL: URL?

    func runInstalled(mode: Mode) {
        do {
            try run(bundleURL: OvercastMigration.installedBundleURL(), mode: mode)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func run(bundleURL: URL, mode: Mode) throws {
        guard !isRunning else { return }
        isRunning = true
        status = "Verifying migration bundle"
        reportURL = nil

        let hasAccess = bundleURL.startAccessingSecurityScopedResource()
        if hasAccess {
            securityScopedURL = bundleURL
        }

        do {
            let bundle = try OvercastMigration.Bundle.load(from: bundleURL)
            let backup = try OvercastMigration.writePocketCastsBackup()
            let opml = try OvercastMigration.writeOPML(bundle: bundle)
            self.bundle = bundle
            self.mode = mode
            backupURL = backup
            opmlURL = opml
            observeOPMLImport()
            status = "Importing \(OvercastMigration.importFeedURLs(bundle).count) feeds needed for subscriptions and library state"
            PodcastManager.shared.importPodcastsFromOpml(opml)
        } catch {
            finishSecurityScope()
            isRunning = false
            throw error
        }
    }

    private func observeOPMLImport() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: Constants.Notifications.opmlImportCompleted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restoreImportedState()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: Constants.Notifications.opmlImportFailed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fail("Pocket Casts could not parse or start the OPML import.")
            }
        })
    }

    private func restoreImportedState() {
        removeObservers()
        guard let bundle, let mode else {
            fail("Migration state was lost before restoration.")
            return
        }
        status = "Restoring matched state, Up Next, playlists, and preserved audio"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let podcasts = DataManager.sharedManager.allPodcasts(
                includeUnsubscribed: true,
                reloadFromDatabase: true
            )
            var report = OvercastMigration.restoreExistingState(
                bundle: bundle,
                podcasts: podcasts
            )
            report.merge(OvercastMigration.restoreCollections(
                bundle: bundle,
                podcasts: podcasts,
                playbackQueue: PlaybackManager.shared.queue
            ))
            report.merge(OvercastMigration.restorePreservedAudio(
                bundle: bundle,
                podcasts: podcasts,
                limit: mode.audioLimit
            ))
            report.merge(OvercastMigration.restoreSubscriptionMembership(
                bundle: bundle,
                podcasts: podcasts
            ))

            do {
                let temporaryReport = try OvercastMigration.writeReconciliationReport(
                    bundle: bundle,
                    report: report,
                    stage: mode.reportStage
                )
                let reportURL = try OvercastMigration.preserveReconciliationReport(
                    temporaryReport,
                    rehearsal: mode.isRehearsal
                )
                try? FileManager.default.removeItem(at: temporaryReport)
                DispatchQueue.main.async { [weak self] in
                    self?.reportURL = reportURL
                    self?.drainSyncQueue(bundle: bundle, mode: mode, report: report, pass: 1)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.fail(error.localizedDescription)
                }
            }
        }
    }

    /// Repeatedly synchronizes until Pocket Casts has nothing left to upload.
    ///
    /// A sync pass sends at most `ServerConstants.Limits.maxEpisodesToSync`
    /// episodes (2000 on iOS), and listening history is capped separately at
    /// 100 items per pass. A migration modifies roughly ten thousand episodes,
    /// so a single pass uploads a fraction of it and returns success. Every
    /// local number then looks perfect while most of the library never reaches
    /// the account — which is exactly what the 2026-07-30 probe measured.
    private func drainSyncQueue(
        bundle: OvercastMigration.Bundle,
        mode: Mode,
        report: OvercastMigration.Reconciliation,
        pass: Int
    ) {
        let remaining = DataManager.sharedManager.unsyncedEpisodes(limit: Self.syncDrainProbeLimit).count
        if remaining == 0, pass > 1 {
            status = "Upload queue drained after \(pass - 1) sync passes"
            auditAndComplete(bundle: bundle, mode: mode, report: report)
            return
        }

        guard pass <= Self.maximumSyncPasses else {
            // Report rather than silently accept a partial upload; the
            // reconciliation report and the local database are both intact, so
            // this is recoverable by syncing again rather than re-importing.
            fail("Upload did not finish: \(remaining)+ episodes still queued after \(Self.maximumSyncPasses) sync passes.")
            return
        }

        status = "Synchronizing Pocket Casts (pass \(pass), \(remaining)+ episodes queued)"
        RefreshManager.shared.refreshPodcasts { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .newData, .noData:
                    // Give the sync task time to finish writing its results
                    // before counting what is left.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.syncPassInterval) {
                        self.drainSyncQueue(
                            bundle: bundle,
                            mode: mode,
                            report: report,
                            pass: pass + 1
                        )
                    }
                case .failed:
                    self.fail(
                        "Local import finished, but Pocket Casts refresh/sync failed on pass \(pass). The reconciliation report was preserved."
                    )
                }
            }
        }
    }

    /// Enough passes to clear a full migration at 2000 episodes per pass, with
    /// generous headroom for history's much smaller per-pass cap.
    private static let maximumSyncPasses = 250
    private static let syncPassInterval: TimeInterval = 5
    /// Only ever asked whether work remains, so one row is enough.
    private static let syncDrainProbeLimit = 1

    private func auditAndComplete(
        bundle: OvercastMigration.Bundle,
        mode: Mode,
        report: OvercastMigration.Reconciliation
    ) {
        status = "Auditing the refreshed Pocket Casts destination"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let podcasts = DataManager.sharedManager.allPodcasts(
                includeUnsubscribed: true,
                reloadFromDatabase: true
            )
            let audit = OvercastMigration.auditDestination(
                bundle: bundle,
                podcasts: podcasts,
                audioLimit: mode.audioLimit
            )
            do {
                let temporaryReport = try OvercastMigration.writeReconciliationReport(
                    bundle: bundle,
                    report: report,
                    stage: mode.reportStage,
                    audit: audit
                )
                let reportURL = try OvercastMigration.preserveReconciliationReport(
                    temporaryReport,
                    rehearsal: mode.isRehearsal
                )
                try? FileManager.default.removeItem(at: temporaryReport)
                DispatchQueue.main.async { [weak self] in
                    self?.reportURL = reportURL
                    self?.complete()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.fail(
                        "Pocket Casts refreshed, but the final destination audit report could not be saved: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func complete() {
        status = "Migration finished; review the reconciliation report"
        isRunning = false
        cleanupTemporaryOPML()
        finishSecurityScope()
        bundle = nil
        mode = nil
    }

    private func fail(_ message: String) {
        print("[overcast-migration] FAILED: \(message)")
        status = "Failed: \(message)"
        isRunning = false
        removeObservers()
        cleanupTemporaryOPML()
        finishSecurityScope()
        bundle = nil
        mode = nil
    }

    private func removeObservers() {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func cleanupTemporaryOPML() {
        if let opmlURL {
            try? FileManager.default.removeItem(at: opmlURL)
        }
        opmlURL = nil
    }

    private func finishSecurityScope() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }
}

private extension KeyedDecodingContainer {
    func decodeSQLiteBooleanIfPresent(forKey key: Key) throws -> Bool? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value != 0
        }
        throw DecodingError.typeMismatch(
            Bool.self,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected a JSON boolean or SQLite 0/1 integer."
            )
        )
    }
}
