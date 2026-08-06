import SwiftUI
import SwiftData

struct SearchView: View {
    @EnvironmentObject var player: PlayerEngine
    @Query private var tracks: [Track]
    @State private var q = ""
    @AppStorage("collectionLayout.search") private var layout: CollectionLayoutMode = .list

    var results: [Track] {
        guard !q.isEmpty else { return [] }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.artist.localizedCaseInsensitiveContains(q) ||
            $0.album.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        Group {
            if q.isEmpty {
                ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                       description: Text("Find songs, artists, and albums."))
            } else if results.isEmpty {
                ContentUnavailableView.search(text: q)
            } else if layout == .grid {
                TrackGridView(tracks: results, currentTrackID: player.current?.id) { index in
                    player.play(results, startAt: index)
                }
            } else {
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { pair in
                        Button { player.play(results, startAt: pair.offset); Haptics.light() } label: {
                            TrackRow(track: pair.element, playing: player.current?.id == pair.element.id)
                        }.buttonStyle(.plain).trackMenu(pair.element).trackSwipeActions(pair.element)
                    }
                }.listStyle(.plain)
            }
        }
        .appScreenBackground()
        .searchable(text: $q, prompt: "Songs, artists, albums")
        .navigationTitle("Search")
        .toolbar {
            if !q.isEmpty { CollectionLayoutPicker(selection: $layout) }
        }
    }
}

// MARK: - Sync (Wi‑Fi from the Mac)

struct SyncView: View {
    @Environment(\.modelContext) private var ctx
    @Query private var tracks: [Track]
    @StateObject private var client = SyncClient()
    @StateObject private var browser = BonjourBrowser()
    @AppStorage("syncHost") private var host = ""
    @AppStorage("syncPin") private var pin = ""

    var body: some View {
        List {
            if !browser.found.isEmpty {
                Section {
                    ForEach(browser.found) { mac in
                        Button {
                            Haptics.light(); host = mac.address
                        } label: {
                            HStack {
                                Image(systemName: "desktopcomputer").foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mac.name).foregroundStyle(.primary)
                                    Text(mac.address).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if host == mac.address { Image(systemName: "checkmark").foregroundStyle(.indigo) }
                            }
                        }
                    }
                } header: { Text("On your network") }
            }

            Section {
                TextField("192.168.1.42:8080", text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("PIN", text: $pin).keyboardType(.numberPad)
            } header: { Text("Your Mac") } footer: {
                Text("On the Mac: **Snag → Devices → Wireless (on)**. Your Mac appears above automatically, or type the address and PIN it shows.")
            }

            Section {
                Button { Task { await run() } } label: {
                    HStack {
                        if client.busy { ProgressView().tint(.white) }
                        Text(client.busy ? "Syncing…" : "Sync now").fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(client.busy || host.isEmpty || pin.isEmpty)
                .listRowBackground(host.isEmpty || pin.isEmpty ? Color(uiColor: .tertiarySystemFill) : AppTheme.accent)
                .foregroundStyle(host.isEmpty || pin.isEmpty ? Color.secondary : Color.white)

                if client.busy {
                    ProgressView(value: client.progress).tint(.indigo)
                }
                if !client.status.isEmpty {
                    Text(client.status).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                ImportDeviceMusicButton()
                ImportButton(label: "Import from Files")
            } header: { Text("On this iPhone") } footer: {
                Text("Bring in the music already in your Music app, or add files via AirDrop or the Files app.")
            }
        }
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.large)
        .appScreenBackground()
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func run() async {
        Haptics.light()
        await client.sync(host: host, pin: pin, into: ctx)
        if client.progress >= 1 { Haptics.success() }
    }
}

// MARK: - Floating mini-player

