import PocketCastsDataModel
import XCTest
@testable import podcasts

final class OvercastMigrationTests: XCTestCase {
    func testLoadAcceptsLegacyArchivedFieldButDoesNotTreatItAsRestoreState() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try write("""
        {"format":"overcast-migration","format_version":1,"test_only":false,"counts":{"subscriptions":1,"episodes":1,"downloaded_candidates":0,"in_progress":0,"completed":0,"starred":0,"playlists":0}}
        """, named: "manifest.json", in: directory)
        try write("""
        [{"id":1,"feed_url":"https://example.com/feed","title":"Example"}]
        """, named: "subscriptions.json", in: directory)
        try write("""
        [{"source_episode_id":2,"source_podcast_id":1,"feed_url":"https://example.com/feed","podcast_title":"Example","published_time":1700000000,"title":"Episode","enclosure_url":"https://example.com/episode.mp3","advertised_duration":60,"progress_seconds":0,"archived":1,"starred_time":0,"download_requested":false,"playback_state":"not_started"}]
        """, named: "episodes.json", in: directory)
        try write("[]", named: "show_settings.json", in: directory)
        try write("[{\"title\":\"Queue\",\"preset\":8,\"included_episode_ids\":\"2,3\",\"manual_sort\":\"3,2\",\"individual_episodes_only\":1,\"deleted\":0}]", named: "playlists.json", in: directory)
        try write("[]", named: "downloaded-audio-inventory.json", in: directory)
        try write("{\"current_source_episode_id\":null,\"sessions\":[]}", named: "playback_state.json", in: directory)

        let bundle = try OvercastMigration.Bundle.load(from: directory)
        let plan = OvercastMigration.dryRun(bundle: bundle, podcasts: [])

        XCTAssertTrue(bundle.episodes[0].overcastDeleted)
        XCTAssertTrue(bundle.playlists[0].individualEpisodesOnly)
        XCTAssertFalse(bundle.playlists[0].deleted)
        XCTAssertEqual(bundle.playlists[0].orderedEpisodeIds, [3, 2])
        XCTAssertEqual(plan.statefulEpisodes, 0)
        XCTAssertEqual(plan.ignoredOvercastDeletionMarkers, 1)
    }

    func testWriteOPMLUsesEachFeedOnce() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("""
        {"format":"overcast-migration","format_version":1,"test_only":false,"counts":{"subscriptions":2,"episodes":0,"downloaded_candidates":0,"in_progress":0,"completed":0,"starred":0,"playlists":0}}
        """, named: "manifest.json", in: directory)
        try write("""
        [{"id":1,"feed_url":"https://example.com/feed?a=1&b=2","title":"One"},{"id":2,"feed_url":"https://example.com/feed?a=1&b=2","title":"Two"}]
        """, named: "subscriptions.json", in: directory)
        try write("[]", named: "episodes.json", in: directory)
        try write("[]", named: "show_settings.json", in: directory)
        try write("[]", named: "playlists.json", in: directory)
        try write("[]", named: "downloaded-audio-inventory.json", in: directory)
        try write("{\"current_source_episode_id\":null,\"sessions\":[]}", named: "playback_state.json", in: directory)

        let opml = try OvercastMigration.writeOPML(bundle: try .load(from: directory))
        defer { try? FileManager.default.removeItem(at: opml) }
        let contents = try String(contentsOf: opml)

        XCTAssertEqual(contents.components(separatedBy: "xmlUrl=").count - 1, 1)
        XCTAssertTrue(contents.contains("a=1&amp;b=2"))
    }

    func testWriteOPMLTemporarilyIncludesHistoricalShowNeededForState() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("""
        {"format":"overcast-migration","format_version":1,"test_only":false,"counts":{"podcasts":2,"subscriptions":1,"episodes":1,"downloaded_candidates":0,"in_progress":0,"completed":1,"starred":0,"playlists":0}}
        """, named: "manifest.json", in: directory)
        try write("""
        [{"id":1,"feed_url":"https://example.com/active.xml","title":"Active","subscribed":1},{"id":2,"feed_url":"https://example.com/history.xml","title":"History","subscribed":0}]
        """, named: "podcasts.json", in: directory)
        try write("""
        [{"id":1,"feed_url":"https://example.com/active.xml","title":"Active"}]
        """, named: "subscriptions.json", in: directory)
        try write("""
        [{"source_episode_id":2,"source_podcast_id":2,"feed_url":"https://example.com/history.xml","podcast_title":"History","published_time":1700000000,"title":"Played Episode","enclosure_url":"https://example.com/played.mp3","advertised_duration":60,"progress_seconds":60,"starred_time":0,"download_requested":false,"playback_state":"completed"}]
        """, named: "episodes.json", in: directory)
        try write("[]", named: "show_settings.json", in: directory)
        try write("[]", named: "playlists.json", in: directory)
        try write("[]", named: "downloaded-audio-inventory.json", in: directory)
        try write("{\"current_source_episode_id\":null,\"sessions\":[]}", named: "playback_state.json", in: directory)

        let bundle = try OvercastMigration.Bundle.load(from: directory)
        let opml = try OvercastMigration.writeOPML(bundle: bundle)
        defer { try? FileManager.default.removeItem(at: opml) }
        let contents = try String(contentsOf: opml)

        XCTAssertEqual(OvercastMigration.sourcePodcastsForImport(bundle).count, 2)
        XCTAssertTrue(contents.contains("https://example.com/active.xml"))
        XCTAssertTrue(contents.contains("https://example.com/history.xml"))
    }

    func testPreflightReportExplainsUnresolvedAndUnsafeState() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try write("""
        {"format":"overcast-migration","format_version":1,"test_only":false,"counts":{"subscriptions":1,"episodes":1,"downloaded_candidates":1,"in_progress":0,"completed":0,"starred":0,"playlists":1}}
        """, named: "manifest.json", in: directory)
        try write("""
        [{"id":1,"feed_url":null,"title":"Missing Feed"}]
        """, named: "subscriptions.json", in: directory)
        try write("""
        [{"source_episode_id":2,"source_podcast_id":1,"feed_url":null,"podcast_title":"Missing Feed","published_time":1700000000,"title":"Episode","enclosure_url":"https://example.com/episode.mp3","advertised_duration":60,"progress_seconds":0,"overcast_deleted":1,"starred_time":0,"download_requested":true,"playback_state":"not_started"}]
        """, named: "episodes.json", in: directory)
        try write("[]", named: "show_settings.json", in: directory)
        try write("[{\"title\":\"Smart\",\"preset\":2,\"included_episode_ids\":null,\"manual_sort\":null,\"individual_episodes_only\":0,\"deleted\":0}]", named: "playlists.json", in: directory)
        try write("[{\"source_episode_id\":2,\"present\":false,\"relative_path\":null,\"sha256\":null}]", named: "downloaded-audio-inventory.json", in: directory)
        try write("{\"current_source_episode_id\":null,\"sessions\":[]}", named: "playback_state.json", in: directory)

        let reportURL = try OvercastMigration.writePreflightReport(
            bundle: try .load(from: directory),
            podcasts: []
        )
        defer { try? FileManager.default.removeItem(at: reportURL) }
        let report = try String(contentsOf: reportURL)

        XCTAssertTrue(report.contains("Not yet present or unresolved: 1"))
        XCTAssertTrue(report.contains("[1] Missing Feed — (missing feed URL)"))
        XCTAssertTrue(report.contains("1 raw Overcast removal markers will NOT be mapped"))
        XCTAssertTrue(report.contains("Missing audio will NOT be redownloaded"))
        XCTAssertTrue(report.contains("Smart (Overcast preset 2"))
    }

    func testLoadRejectsArtifactChecksumMismatch() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try write("""
        {"format":"overcast-migration","format_version":1,"test_only":false,"counts":{"subscriptions":0,"episodes":0,"downloaded_candidates":0,"in_progress":0,"completed":0,"starred":0,"playlists":0}}
        """, named: "manifest.json", in: directory)
        try write("[]", named: "subscriptions.json", in: directory)
        try write("[]", named: "episodes.json", in: directory)
        try write("[]", named: "show_settings.json", in: directory)
        try write("[]", named: "playlists.json", in: directory)
        try write("[]", named: "downloaded-audio-inventory.json", in: directory)
        try write("{\"current_source_episode_id\":null,\"sessions\":[]}", named: "playback_state.json", in: directory)
        try write("{\"episodes.json\":\"not-the-real-sha256\"}", named: "artifact-checksums.json", in: directory)

        XCTAssertThrowsError(try OvercastMigration.Bundle.load(from: directory)) { error in
            guard case OvercastMigration.Error.artifactChecksumMismatch("episodes.json") = error else {
                return XCTFail("Expected an episode checksum mismatch, got \(error)")
            }
        }
    }

    func testDryRunMatchesImportedPodcastByUniqueTitleWhenPodcastURLIsWebsite() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try write("""
        {"format":"overcast-migration","format_version":1,"test_only":false,"counts":{"subscriptions":1,"episodes":0,"downloaded_candidates":0,"in_progress":0,"completed":0,"starred":0,"playlists":0}}
        """, named: "manifest.json", in: directory)
        try write("""
        [{"id":1,"feed_url":"https://example.com/feed.xml","title":"Example Show"}]
        """, named: "subscriptions.json", in: directory)
        try write("[]", named: "episodes.json", in: directory)
        try write("[]", named: "show_settings.json", in: directory)
        try write("[]", named: "playlists.json", in: directory)
        try write("[]", named: "downloaded-audio-inventory.json", in: directory)
        try write("{\"current_source_episode_id\":null,\"sessions\":[]}", named: "playback_state.json", in: directory)

        let podcast = Podcast()
        podcast.id = 123
        podcast.title = "Example Show"
        podcast.podcastUrl = "https://example.com"
        let plan = OvercastMigration.dryRun(
            bundle: try .load(from: directory),
            podcasts: [podcast]
        )

        XCTAssertEqual(plan.matchedSubscriptions, 1)
        XCTAssertEqual(plan.unresolvedSubscriptions, 0)
    }

    func testRestoreCollectionsDoesNotSendEmptyBatchToPlaybackQueue() throws {
        let directory = try makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try write("""
        {"format":"overcast-migration","format_version":1,"test_only":false,"counts":{"subscriptions":1,"episodes":1,"downloaded_candidates":0,"in_progress":0,"completed":0,"starred":0,"playlists":1}}
        """, named: "manifest.json", in: directory)
        try write("""
        [{"id":1,"feed_url":"https://example.com/feed.xml","title":"Missing Show"}]
        """, named: "subscriptions.json", in: directory)
        try write("""
        [{"source_episode_id":2,"source_podcast_id":1,"feed_url":"https://example.com/feed.xml","podcast_title":"Missing Show","published_time":1700000000,"title":"Episode","enclosure_url":"https://example.com/episode.mp3","advertised_duration":60,"progress_seconds":0,"starred_time":0,"download_requested":false,"playback_state":"not_started"}]
        """, named: "episodes.json", in: directory)
        try write("[]", named: "show_settings.json", in: directory)
        try write("[{\"title\":\"Queue\",\"preset\":8,\"included_episode_ids\":\"2\",\"manual_sort\":\"2\",\"individual_episodes_only\":1,\"deleted\":0}]", named: "playlists.json", in: directory)
        try write("[]", named: "downloaded-audio-inventory.json", in: directory)
        try write("{\"current_source_episode_id\":null,\"sessions\":[]}", named: "playback_state.json", in: directory)

        let report = OvercastMigration.restoreCollections(
            bundle: try .load(from: directory),
            podcasts: []
        )

        XCTAssertEqual(report.restoredQueueEpisodes, 0)
        XCTAssertEqual(report.unresolvedCollectionEpisodes, 1)
    }

    func testInstalledRealBundlePreflightRehearsal() throws {
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let directory = documents.appendingPathComponent("OvercastMigrationQA", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("Install a real bundle as Documents/OvercastMigrationQA for disposable simulator rehearsal.")
        }

        let bundle = try OvercastMigration.Bundle.load(from: directory)
        let receiptURL = try OvercastMigration.runInstalledPreflightRehearsal()
        defer { try? FileManager.default.removeItem(at: receiptURL) }
        let receipt = try JSONSerialization.jsonObject(
            with: Data(contentsOf: receiptURL)
        ) as? [String: Any]

        XCTAssertEqual(receipt?["passed"] as? Bool, true)
        XCTAssertEqual(receipt?["subscriptions"] as? Int, bundle.manifest.counts.subscriptions)
        XCTAssertEqual(receipt?["episodes"] as? Int, bundle.manifest.counts.episodes)
        XCTAssertEqual(
            receipt?["unresolved_subscriptions"] as? Int,
            bundle.manifest.counts.subscriptions
        )
        XCTAssertGreaterThan(receipt?["verified_artifact_checksums"] as? Int ?? 0, 0)
    }

    private func makeBundleDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OvercastMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ string: String, named name: String, in directory: URL) throws {
        try Data(string.utf8).write(to: directory.appendingPathComponent(name))
    }
}
