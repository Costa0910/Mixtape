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
    @Published var selectedAlbumIDs: Set<String> = []

    var selectedAlbums: [AlbumFolder] {
        let sel = albums.filter { selectedAlbumIDs.contains($0.id) }
        return sel.isEmpty ? albums : sel
    }
    func toggleAlbumSelection(_ album: AlbumFolder) {
        if selectedAlbumIDs.contains(album.id) { selectedAlbumIDs.remove(album.id) }
        else { selectedAlbumIDs.insert(album.id) }
    }
    func selectAllAlbums() { selectedAlbumIDs = Set(albums.map(\.id)) }
    func selectNoAlbums() { selectedAlbumIDs = [] }

    private var processing = false

    init(settings: SettingsStore) { self.settings = settings }

    var adbAvailable: Bool { BinaryLocator.url(for: .adb) != nil }
    var missingTools: [Tool] { BinaryLocator.missingRequired() }
    var activeJobCount: Int { jobs.filter { $0.status.isActive || $0.status == .queued }.count }

    // MARK: Queue

    func enqueue(url: String, kind: MediaKind, format: AudioFormat, bitrate: String,
                 videoQuality: String, skipVlogs: Bool, customAlbum: String?) {
        let job = DownloadJob(url: url, kind: kind, format: format, bitrate: bitrate,
                              videoQuality: videoQuality, skipVlogs: skipVlogs, customAlbum: customAlbum)
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

    func retry(_ job: DownloadJob) {
        jobs.removeAll { $0.id == job.id }
        enqueue(url: job.url, kind: job.kind, format: job.format, bitrate: job.bitrate,
                videoQuality: job.videoQuality, skipVlogs: job.skipVlogs, customAlbum: job.customAlbum)
    }

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
                url: job.url, album: album, kind: job.kind, format: job.format, mp3Bitrate: job.bitrate,
                videoQuality: job.videoQuality, skipVlogs: job.skipVlogs, libraryRoot: settings.libraryURL,
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

            // 3) organize — music-style tagging only applies to the Music kind
            if job.kind == .music {
                job.status = .organizing
                job.detail = "Tagging…"
                try await Organizer.tagAlbum(albumDir, album: album,
                                             genre: settings.genre.isEmpty ? nil : settings.genre) { frac, name in
                    Task { @MainActor in job.progress = frac; job.detail = "Tagging \(name)" }
                }
            }
            if job.kind != .video && settings.makePlaylists {
                try Organizer.writePlaylists(libraryRoot: settings.libraryURL)
            }
            job.albumDir = albumDir
            job.progress = 1
            job.status = .done
            job.detail = "\(job.trackCount) track(s) saved"
            scanLibrary()
            Notifier.notify(title: "Download complete", body: "\(album) · \(job.trackCount) track(s)")
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
                    .filter { Media.isMedia($0) } ?? []
                if !tracks.isEmpty {
                    found.append(AlbumFolder(url: dir, name: dir.lastPathComponent, trackCount: tracks.count))
                }
            }
        }
        let oldIDs = Set(albums.map(\.id))
        albums = found.sorted { $0.name < $1.name }
        let ids = Set(albums.map(\.id))
        let brandNew = ids.subtracting(oldIDs)
        selectedAlbumIDs = selectedAlbumIDs.intersection(ids).union(brandNew)
        if selectedAlbumIDs.isEmpty && oldIDs.isEmpty { selectedAlbumIDs = ids }
    }

    func deleteAlbum(_ album: AlbumFolder) {
        try? FileManager.default.removeItem(at: album.url)
        if settings.makePlaylists { try? Organizer.writePlaylists(libraryRoot: settings.libraryURL) }
        scanLibrary()
    }

    func tracks(in album: AlbumFolder) -> [TrackFile] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: album.url, includingPropertiesForKeys: nil))?
            .filter { Media.isMedia($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return files.enumerated().map { i, url in
            var name = url.deletingPathExtension().lastPathComponent
            if let r = name.range(of: #"^\d+\s*-\s*"#, options: .regularExpression) {
                name.removeSubrange(r)
            }
            return TrackFile(url: url, index: i + 1, title: name)
        }
    }

    func deleteTrack(_ track: TrackFile, in album: AlbumFolder) {
        Player.shared.stop()
        try? FileManager.default.removeItem(at: track.url)
        if settings.makePlaylists { try? Organizer.writePlaylists(libraryRoot: settings.libraryURL) }
        scanLibrary()
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: Maintenance

    @Published var ytdlpUpdateStatus = ""
    func updateYtDlp() {
        guard let exe = BinaryLocator.url(for: .ytdlp) else { ytdlpUpdateStatus = "yt-dlp not found"; return }
        ytdlpUpdateStatus = "Updating…"
        Task {
            do {
                let out = try await ProcessRunner.capture(exe, ["-U"])
                let last = out.split(separator: "\n").last.map(String.init) ?? "Up to date"
                self.ytdlpUpdateStatus = last
            } catch {
                self.ytdlpUpdateStatus = "Update failed (bundled builds are read-only)."
            }
        }
    }

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
                    try await Transfer.pushAndroid(libraryRoot: settings.libraryURL,
                                                   albums: selectedAlbums, phone: phone) { frac, detail in
                        Task { @MainActor in
                            if frac >= 0 { self.transferProgress = frac }
                            self.transferStatus = detail
                        }
                    }
                    self.transferStatus = "✓ Transferred \(selectedAlbums.count) album(s) to \(phone.name)."
                case .iphone:
                    self.transferStatus = try await Transfer.prepareIPhone(albums: selectedAlbums)
                }
            } catch {
                self.transferStatus = "Transfer failed: \(error.localizedDescription)"
            }
            self.transferring = false
        }
    }
}
