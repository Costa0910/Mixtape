import Foundation
import SwiftUI

// A discovered album folder in the library.
struct AlbumFolder: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let trackCount: Int
}

@MainActor
final class AppState: ObservableObject {
    let settings: SettingsStore

    @Published var section: AppSection = .download
    @Published var jobs: [DownloadJob] = []

    // Devices
    @Published var phones: [Phone] = []
    @Published var selectedPhone: Phone?
    @Published var transferStatus = ""
    @Published var transferring = false
    @Published var transferProgress: Double = 0

    // Library
    @Published var albums: [AlbumFolder] = []

    private var processing = false

    init(settings: SettingsStore) { self.settings = settings }

    var adbAvailable: Bool { BinaryLocator.url(for: .adb) != nil }
    var missingTools: [Tool] { BinaryLocator.missingRequired() }
    var activeJobCount: Int { jobs.filter { $0.status.isActive || $0.status == .queued }.count }

    // MARK: Queue

    func enqueue(url: String, format: AudioFormat, bitrate: String,
                 skipVlogs: Bool, customAlbum: String?) {
        let job = DownloadJob(url: url, format: format, bitrate: bitrate,
                              skipVlogs: skipVlogs, customAlbum: customAlbum)
        jobs.insert(job, at: 0)
        processNext()
    }

    func cancel(_ job: DownloadJob) {
        job.task?.cancel()
        job.status = .cancelled
        job.detail = "Cancelled"
        processNext()
    }

    func clearFinished() { jobs.removeAll { $0.status.isFinished } }

    private func processNext() {
        guard !processing else { return }
        guard let job = jobs.last(where: { $0.status == .queued }) else { return }
        processing = true
        job.task = Task { await self.run(job); self.processing = false; self.processNext() }
    }

    private func run(_ job: DownloadJob) async {
        do {
            // 1) analyze to get album name + count
            job.status = .analyzing
            let analysis = try await Downloader.analyze(job.url)
            if Task.isCancelled { return }
            let album = job.customAlbum ?? analysis.albumName
            job.title = album
            job.trackCount = analysis.entries.count

            // 2) download
            job.status = .downloading
            let albumDir = try await Downloader.download(
                url: job.url, album: album, format: job.format, mp3Bitrate: job.bitrate,
                skipVlogs: job.skipVlogs, libraryRoot: settings.libraryURL,
                padding: settings.trackPadding
            ) { p in
                Task { @MainActor in
                    if p.itemTotal > 0 {
                        let base = Double(max(p.itemIndex - 1, 0)) / Double(p.itemTotal)
                        job.progress = base + (p.filePercent / 100) / Double(p.itemTotal)
                        job.detail = "Track \(p.itemIndex)/\(p.itemTotal) · \(p.currentTitle)"
                    } else {
                        job.progress = p.filePercent / 100
                        if !p.currentTitle.isEmpty { job.detail = p.currentTitle }
                    }
                }
            }
            if Task.isCancelled { return }

            // 3) organize
            job.status = .organizing
            job.detail = "Tagging…"
            try await Organizer.tagAlbum(albumDir, album: album,
                                         genre: settings.genre.isEmpty ? nil : settings.genre) { frac, name in
                Task { @MainActor in job.progress = frac; job.detail = "Tagging \(name)" }
            }
            if settings.makePlaylists {
                try Organizer.writePlaylists(libraryRoot: settings.libraryURL)
            }
            job.albumDir = albumDir
            job.progress = 1
            job.status = .done
            job.detail = "\(job.trackCount) track(s) saved"
            scanLibrary()
            if settings.autoTransfer, let phone = selectedPhone { transfer(to: phone) }
        } catch is CancellationError {
            job.status = .cancelled
        } catch {
            job.status = .failed(error.localizedDescription)
            job.detail = error.localizedDescription
        }
    }

    // MARK: Library

    func scanLibrary() {
        let fm = FileManager.default
        let root = settings.libraryURL
        var found: [AlbumFolder] = []
        if let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let tracks = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                    .filter { ["m4a", "mp3", "opus", "ogg"].contains($0.pathExtension.lowercased()) } ?? []
                if !tracks.isEmpty {
                    found.append(AlbumFolder(url: dir, name: dir.lastPathComponent, trackCount: tracks.count))
                }
            }
        }
        albums = found.sorted { $0.name < $1.name }
    }

    func deleteAlbum(_ album: AlbumFolder) {
        try? FileManager.default.removeItem(at: album.url)
        if settings.makePlaylists { try? Organizer.writePlaylists(libraryRoot: settings.libraryURL) }
        scanLibrary()
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: Devices

    func refreshPhones() {
        Task {
            let found = await Transfer.detectPhones()
            self.phones = found
            if self.selectedPhone == nil || !found.contains(where: { $0.id == self.selectedPhone?.id }) {
                self.selectedPhone = found.first
            }
        }
    }

    func transfer(to phone: Phone) {
        transferring = true
        transferStatus = ""
        transferProgress = 0
        Task {
            do {
                switch phone.kind {
                case .android:
                    try await Transfer.pushAndroid(libraryRoot: settings.libraryURL, phone: phone) { frac, detail in
                        Task { @MainActor in
                            if frac >= 0 { self.transferProgress = frac }
                            self.transferStatus = detail
                        }
                    }
                    self.transferStatus = "✓ Transferred to \(phone.name)."
                case .iphone:
                    self.transferStatus = try await Transfer.prepareIPhone(libraryRoot: settings.libraryURL)
                }
            } catch {
                self.transferStatus = "Transfer failed: \(error.localizedDescription)"
            }
            self.transferring = false
        }
    }
}
