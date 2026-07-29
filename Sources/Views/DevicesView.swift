import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var server: WebServer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ScreenHeader(title: "Devices",
                                 subtitle: "Send your library to a phone — USB or Wi-Fi",
                                 systemImage: "iphone.gen3")
                    Button { state.refreshPhones() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.controlSize(.large)
                }

                wirelessCard

                if !state.adbAvailable {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("Android transfer needs adb — run Scripts/fetch-tools.sh or `brew install android-platform-tools`.")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                    }
                    .padding(12).glassSurface(12)
                }

                if state.albums.isEmpty {
                    infoCard("Nothing to transfer yet",
                             "Download some music first — then it'll appear here to send.",
                             "tray")
                } else {
                    albumSelector
                }

                if state.phones.isEmpty {
                    connectHelp
                } else {
                    ForEach(state.phones) { phone in PhoneCard(phone: phone) }
                }

                if !state.transferStatus.isEmpty {
                    Text(state.transferStatus)
                        .font(.callout)
                        .foregroundStyle(state.transferStatus.hasPrefix("✓") ? .green : .primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 4)
                }
            }
            .padding(22)
        }
        .onAppear { state.refreshPhones() }
    }

    private var wirelessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Wireless (any phone)", systemImage: "wifi").font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { server.running },
                        set: { $0 ? server.start(root: settings.libraryURL) : server.stop() }
                    )).labelsHidden().toggleStyle(.switch)
                }
                if server.running, !server.address.isEmpty {
                    HStack(alignment: .top, spacing: 16) {
                        if let qr = WebServer.qrImage(server.address) {
                            Image(nsImage: qr).interpolation(.none).resizable()
                                .frame(width: 110, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("On your phone (same Wi-Fi), scan the code or open:")
                                .font(.callout).foregroundStyle(.secondary)
                            Text(server.address).font(.title3.monospaced().weight(.semibold))
                                .textSelection(.enabled)
                            Text("Then tap any track to download it — works on iPhone and Android.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } else {
                    Text("Serve your library over Wi-Fi so any phone can download tracks in a browser — no USB, no Music sync.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var albumSelector: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Albums to send", systemImage: "checklist").font(.headline)
                    Spacer()
                    Text("\(state.selectedAlbums.count)/\(state.albums.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("All") { state.selectAllAlbums() }.controlSize(.small).buttonStyle(.borderless)
                    Button("None") { state.selectNoAlbums() }.controlSize(.small).buttonStyle(.borderless)
                }
                ForEach(state.albums) { album in
                    let on = state.selectedAlbumIDs.contains(album.id)
                    HStack {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Image(systemName: album.isVideo ? "film" : "music.note")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(album.name).lineLimit(1)
                        Spacer()
                        Text("\(album.trackCount)").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { state.toggleAlbumSelection(album) }
                    .padding(.vertical, 3)
                }
                Text("On Android, audio goes to Music and video to Movies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var connectHelp: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("No phone detected", systemImage: "cable.connector").font(.headline)
                helpRow("iphone", "iPhone", "Connect via USB, unlock, and tap Trust. Transfer imports into the Music app; you finish with Sync in Finder.")
                helpRow("candybarphone", "Android", "Connect via USB, set it to File Transfer, and enable USB debugging (Developer options). Tap Allow when prompted.")
            }
        }
    }

    private func helpRow(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func infoCard(_ title: String, _ body: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(body).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14).glassSurface(12)
    }
}

struct PhoneCard: View {
    let phone: Phone
    @EnvironmentObject var state: AppState

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: phone.kind == .iphone ? "iphone" : "candybarphone")
                        .font(.system(size: 26)).foregroundStyle(.tint)
                        .frame(width: 46, height: 46)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phone.name).font(.headline)
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if phone.needsSetup {
                        Button { state.refreshPhones() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }.controlSize(.large)
                    } else {
                        Button {
                            state.transfer(to: phone)
                        } label: {
                            Label(phone.kind == .iphone ? "Prepare for iPhone" : "Transfer",
                                  systemImage: "square.and.arrow.up.fill")
                        }
                        .controlSize(.large).buttonStyle(.borderedProminent)
                        .disabled(state.transferring || state.albums.isEmpty)
                    }
                }
                if state.transferring {
                    ProgressView(value: max(0, min(state.transferProgress, 1)))
                }
                if phone.needsSetup && !phone.hint.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                        Text(phone.hint).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var label: String {
        var parts = [phone.kind == .iphone ? "iPhone" : "Android"]
        if !phone.freeText.isEmpty { parts.append(phone.freeText) }
        return parts.joined(separator: " · ")
    }
}
