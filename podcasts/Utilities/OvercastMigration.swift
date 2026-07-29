import Foundation
import PocketCastsDataModel

/// The portable format written by `scripts/overcast-migration-export.py`.
/// Loading and planning are intentionally side-effect-free. Subscription and
/// state writes happen only after the developer UI presents this report.
enum OvercastMigration {
    static let format = "overcast-migration"
    static let supportedFormatVersion = 1

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
        let subscriptions: Int
        let episodes: Int
        let downloadedCandidates: Int
        let inProgress: Int
        let completed: Int
        let starred: Int
        let playlists: Int

        enum CodingKeys: String, CodingKey {
            case subscriptions, episodes, starred, playlists, completed
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
            // Bundles made before the field was clarified used `archived`.
            overcastDeleted = try container.decodeIfPresent(Bool.self, forKey: .overcastDeleted)
                ?? container.decodeIfPresent(Bool.self, forKey: .archived)
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

        var orderedEpisodeIds: [Int64] {
            let value = (manualSort?.isEmpty == false ? manualSort : includedEpisodeIds) ?? ""
            return value.split(separator: ",").compactMap { Int64($0) }
        }
    }

    struct Bundle {
        let manifest: Manifest
        let subscriptions: [Subscription]
        let episodes: [Episode]
        let showSettings: [ShowSetting]
        let playlists: [Playlist]

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
            return Self(
                manifest: manifest,
                subscriptions: try decode("subscriptions.json", in: directory),
                episodes: try decode("episodes.json", in: directory),
                showSettings: try decode("show_settings.json", in: directory),
                playlists: try decode("playlists.json", in: directory)
            )
        }

        private static func decode<T: Decodable>(_ name: String, in directory: URL) throws -> T {
            let file = directory.appendingPathComponent(name, isDirectory: false)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw Error.missingArtifact(name)
            }
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
        var restoredQueueEpisodes = 0
        var restoredPlaylists = 0
        var unresolvedCollectionEpisodes = 0
    }

    static func dryRun(bundle: Bundle, podcasts: [Podcast]) -> DryRun {
        let destinationFeeds = Set(podcasts.compactMap { canonicalFeedURL($0.podcastUrl) })
        let sourceFeeds = bundle.subscriptions.compactMap { canonicalFeedURL($0.feedURL) }
        let matched = sourceFeeds.filter(destinationFeeds.contains).count
        let statefulEpisodes = bundle.episodes.filter {
            $0.playbackState != .notStarted || $0.starredTime > 0
        }.count
        return DryRun(
            sourceSubscriptions: sourceFeeds.count,
            matchedSubscriptions: matched,
            unresolvedSubscriptions: sourceFeeds.count - matched,
            statefulEpisodes: statefulEpisodes,
            downloadedEpisodes: bundle.episodes.filter(\.downloadRequested).count,
            requiredRefreshes: Set(bundle.episodes.map(\.sourcePodcastId)).count,
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
        let destinationByFeed = Dictionary(
            podcasts.compactMap { podcast in canonicalFeedURL(podcast.podcastUrl).map { ($0, podcast) } },
            uniquingKeysWith: { first, _ in first }
        )
        var podcastsBySourceId = [Int64: Podcast]()
        for subscription in bundle.subscriptions {
            guard let feed = canonicalFeedURL(subscription.feedURL) else {
                report.unresolvedSubscriptions += 1
                continue
            }
            guard let podcast = destinationByFeed[feed] else {
                report.unresolvedSubscriptions += 1
                continue
            }
            podcastsBySourceId[subscription.sourcePodcastId] = podcast
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

        var episodesByPodcastId = [Int64: [Episode]]()
        for podcast in Set(podcastsBySourceId.values) {
            episodesByPodcastId[podcast.id] = dataManager.findEpisodesWhere(
                customWhere: "podcast_id = ?",
                arguments: [podcast.id]
            )
        }

        for source in bundle.episodes where shouldRestore(source, restoreDownloads: restoreDownloads) {
            guard let podcast = podcastsBySourceId[source.sourcePodcastId],
                  let destination = matchingEpisode(source, in: episodesByPodcastId[podcast.id] ?? [])
            else {
                report.unresolvedEpisodes += 1
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
        return report
    }

    static func restoreCollections(
        bundle: Bundle,
        podcasts: [Podcast],
        dataManager: DataManager = .sharedManager,
        playbackQueue: PlaybackQueue = PlaybackQueue()
    ) -> Reconciliation {
        var report = Reconciliation()
        let destinationByFeed = Dictionary(
            podcasts.compactMap { podcast in canonicalFeedURL(podcast.podcastUrl).map { ($0, podcast) } },
            uniquingKeysWith: { first, _ in first }
        )
        let sourcePodcastById = Dictionary(uniqueKeysWithValues: bundle.subscriptions.compactMap { subscription in
            guard let feed = canonicalFeedURL(subscription.feedURL),
                  let podcast = destinationByFeed[feed]
            else { return nil }
            return (subscription.sourcePodcastId, podcast)
        })
        var destinationEpisodes = [Int64: [PocketCastsDataModel.Episode]]()
        for podcast in sourcePodcastById.values {
            destinationEpisodes[podcast.id] = dataManager.findEpisodesWhere(
                customWhere: "podcast_id = ?",
                arguments: [podcast.id]
            )
        }
        let sourceEpisodes = Dictionary(uniqueKeysWithValues: bundle.episodes.map { ($0.sourceEpisodeId, $0) })

        func matched(_ ids: [Int64]) -> [PocketCastsDataModel.Episode] {
            ids.compactMap { id in
                guard let source = sourceEpisodes[id],
                      let podcast = sourcePodcastById[source.sourcePodcastId],
                      let episode = matchingEpisode(source, in: destinationEpisodes[podcast.id] ?? [])
                else {
                    report.unresolvedCollectionEpisodes += 1
                    return nil
                }
                return episode
            }
        }

        if let queue = bundle.playlists.first(where: { $0.preset == 8 && !$0.deleted }) {
            let episodes = matched(queue.orderedEpisodeIds)
            playbackQueue.bulkAdd(episodes, toTop: false)
            report.restoredQueueEpisodes = episodes.count
        }

        let existingNames = Set(dataManager.allPlaylists(includeDeleted: false).map(\.playlistName))
        for playlist in bundle.playlists
            where playlist.preset == 0 && playlist.individualEpisodesOnly && !playlist.deleted &&
            !existingNames.contains(playlist.title) {
            let episodes = matched(playlist.orderedEpisodeIds)
            guard !episodes.isEmpty else { continue }
            report.restoredPlaylists += dataManager.createManualPlaylists(
                from: episodes,
                batchSize: 10_000,
                baseName: playlist.title
            )
        }
        return report
    }

    /// Creates a temporary OPML document for the existing, audited OPML
    /// importer. The caller is responsible for presenting an explicit import
    /// action; merely writing this file never changes a subscription.
    static func writeOPML(bundle: Bundle) throws -> URL {
        let feeds = Array(Set(bundle.subscriptions.compactMap(\.feedURL))).sorted()
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
        episode.playbackState != .notStarted || episode.starredTime > 0 || (restoreDownloads && episode.downloadRequested)
    }

    private static func matchingEpisode(_ source: Episode, in destination: [PocketCastsDataModel.Episode]) -> PocketCastsDataModel.Episode? {
        if let exact = destination.first(where: { $0.downloadUrl == source.enclosureURL }) {
            return exact
        }
        let published = Date(timeIntervalSince1970: TimeInterval(source.publishedTime))
        if let titleAndDate = destination.first(where: {
            $0.title == source.title && abs(($0.publishedDate ?? .distantPast).timeIntervalSince(published)) < 300
        }) {
            return titleAndDate
        }
        return destination.first(where: {
            $0.title == source.title && abs($0.duration - Double(source.advertisedDuration)) < 2
        })
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

        var errorDescription: String? {
            switch self {
            case let .missingArtifact(name): "Migration bundle is missing \(name)."
            case let .unsupportedFormat(format): "Unsupported migration format: \(format)."
            case let .unsupportedVersion(version): "Unsupported migration format version: \(version)."
            case .testOnlyBundle: "A test-only migration bundle cannot be imported."
            }
        }
    }
}
