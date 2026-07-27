import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    // Input / options
    @Published var urlInput = ""
    @Published var format: AudioFormat = .m4a
    @Published var mp3Bitrate = "320"
    @Published var skipVlogs = true
    @Published var albumName = ""

    // Pipeline state
    @Published var phase: Phase = .idle
    @Published var analysis: Analysis?
    @Published var progressValue: Double = 0      // 0…1 for current stage
    @Published var progressDetail = ""
    @Published var log: [String] = []

    // Library / output
    @Published var libraryRoot: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Mixtape", isDirectory: true)
    }()
    @Published var lastAlbumDir: URL?

    // Devices
    @Published var phones: [Phone] = []
    @Published var selectedPhone: Phone?
    @Published var transferStatus = ""
    @Published var transferring = false

    var missingTools: [Tool] { BinaryLocator.missingRequired() }
    var adbAvailable: Bool { BinaryLocator.url(for: .adb) != nil }

    private func logLine(_ s: String) {
        log.append(s)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: Analyze

    func analyze() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        phase = .analyzing
        analysis = nil
        Task {
            do {
                let a = try await Downloader.analyze(url)
                self.analysis = a
                self.albumName = a.albumName
                self.phase = .ready
                self.logLine("Found \(a.entries.count) track(s) · album “\(a.albumName)”"
                             + (a.vlogCount > 0 ? " · \(a.vlogCount) vlog(s) will be skipped" : ""))
            } catch {
                self.phase = .failed(error.localizedDescription)
                self.logLine("Analyze failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Download + organize

    func startDownload() {
        let url = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let album = albumName.isEmpty ? (analysis?.albumName ?? "Downloaded Music") : albumName
        let genre = "Music"
        phase = .downloading
        progressValue = 0
        progressDetail = "Starting…"
        Task {
            do {
                try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
                let albumDir = try await Downloader.download(
                    url: url, album: album, format: format, mp3Bitrate: mp3Bitrate,
                    skipVlogs: skipVlogs, libraryRoot: libraryRoot
                ) { p in
                    Task { @MainActor in self.applyDownloadProgress(p) }
                }
                self.phase = .organizing
                self.progressValue = 0
                self.progressDetail = "Tagging…"
                try await Organizer.tagAlbum(albumDir, album: album, genre: genre) { frac, name in
                    Task { @MainActor in
                        self.progressValue = frac
                        self.progressDetail = "Tagging \(name)"
                    }
                }
                try Organizer.writePlaylists(libraryRoot: self.libraryRoot)
                self.lastAlbumDir = albumDir
                self.phase = .done
                self.progressValue = 1
                self.progressDetail = "Saved to \(albumDir.lastPathComponent)"
                self.logLine("Done · \(album) saved to \(albumDir.path)")
            } catch {
                self.phase = .failed(error.localizedDescription)
                self.logLine("Download failed: \(error.localizedDescription)")
            }
        }
    }

    private func applyDownloadProgress(_ p: DownloadProgress) {
        if p.itemTotal > 0 {
            let base = Double(max(p.itemIndex - 1, 0)) / Double(p.itemTotal)
            progressValue = base + (p.filePercent / 100.0) / Double(p.itemTotal)
            progressDetail = "Track \(p.itemIndex)/\(p.itemTotal) · \(p.currentTitle)"
        } else {
            progressValue = p.filePercent / 100.0
            if !p.currentTitle.isEmpty { progressDetail = p.currentTitle }
        }
    }

    // MARK: Devices

    func refreshPhones() {
        Task {
            let found = await Transfer.detectPhones()
            self.phones = found
            if self.selectedPhone == nil { self.selectedPhone = found.first }
            self.logLine("Detected \(found.count) phone(s).")
        }
    }

    func transfer() {
        guard let phone = selectedPhone else { transferStatus = "No phone selected."; return }
        transferring = true
        transferStatus = ""
        Task {
            do {
                switch phone.kind {
                case .android:
                    try await Transfer.pushAndroid(libraryRoot: libraryRoot, phone: phone) { frac, detail in
                        Task { @MainActor in
                            if frac >= 0 { self.progressValue = frac }
                            self.transferStatus = detail
                        }
                    }
                    self.transferStatus = "✓ Transferred to \(phone.name). Open a music player on the phone."
                case .iphone:
                    let msg = try await Transfer.prepareIPhone(libraryRoot: libraryRoot)
                    self.transferStatus = msg
                }
            } catch {
                self.transferStatus = "Transfer failed: \(error.localizedDescription)"
            }
            self.transferring = false
        }
    }

    func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([lastAlbumDir ?? libraryRoot])
    }
}
