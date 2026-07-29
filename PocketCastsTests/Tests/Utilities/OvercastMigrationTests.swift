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
        [{"source_episode_id":2,"source_podcast_id":1,"feed_url":"https://example.com/feed","podcast_title":"Example","published_time":1700000000,"title":"Episode","enclosure_url":"https://example.com/episode.mp3","advertised_duration":60,"progress_seconds":0,"archived":true,"starred_time":0,"download_requested":false,"playback_state":"not_started"}]
        """, named: "episodes.json", in: directory)
        try write("[]", named: "show_settings.json", in: directory)
        try write("[]", named: "playlists.json", in: directory)

        let bundle = try OvercastMigration.Bundle.load(from: directory)
        let plan = OvercastMigration.dryRun(bundle: bundle, podcasts: [])

        XCTAssertTrue(bundle.episodes[0].overcastDeleted)
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

        let opml = try OvercastMigration.writeOPML(bundle: try .load(from: directory))
        defer { try? FileManager.default.removeItem(at: opml) }
        let contents = try String(contentsOf: opml)

        XCTAssertEqual(contents.components(separatedBy: "xmlUrl=").count - 1, 1)
        XCTAssertTrue(contents.contains("a=1&amp;b=2"))
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
