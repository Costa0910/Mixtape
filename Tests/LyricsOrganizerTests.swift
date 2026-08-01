import XCTest
@testable import Snag

final class LyricsOrganizerTests: XCTestCase {
    func testOrganizerEmbedsDescriptionFallbackAsLyrics() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let audio = directory.appendingPathComponent("001 - Example.m4a")
        let description = """
        Example Song Lyrics
        This is the first lyric line
        This is the second lyric line
        This is the third lyric line
        """

        try runTool(.ffmpeg, arguments: [
            "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-t", "0.2", "-c:a", "aac", "-metadata", "description=\(description)", audio.path
        ])

        try await Organizer.tagAlbum(directory, album: "Fixture", genre: "Test") { _, _ in }

        let output = try runTool(.ffprobe, arguments: [
            "-v", "error", "-show_entries", "format_tags=lyrics", "-of", "default=nw=1", audio.path
        ])
        XCTAssertTrue(output.contains("This is the first lyric line"))
        XCTAssertTrue(output.contains("This is the third lyric line"))
    }

    @discardableResult
    private func runTool(_ tool: Tool, arguments: [String]) throws -> String {
        guard let executable = BinaryLocator.url(for: tool) else {
            throw XCTSkip("\(tool.rawValue) is unavailable")
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, output)
        return output
    }
}
