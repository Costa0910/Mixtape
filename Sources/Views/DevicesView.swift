import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ScreenHeader(title: "Devices",
                                 subtitle: "Send your library to a connected phone",
                                 systemImage: "iphone.gen3")
                    Button { state.refreshPhones() } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }.controlSize(.large)
                }

                if !state.adbAvailable {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("Android transfer needs adb — run Scripts/fetch-tools.sh or `brew install android-platform-tools`.")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                    }
                    .padding(12).background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }

                if state.albums.isEmpty {
                    infoCard("Nothing to transfer yet",
                             "Download some music first — then it'll appear here to send.",
                             "tray")
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
        .padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct PhoneCard: View {
    let phone: Phone
    @EnvironmentObject var state: AppState

    private var isUnauthorized: Bool { phone.name.contains("Allow") }

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
                    Button {
                        state.transfer(to: phone)
                    } label: {
                        Label(phone.kind == .iphone ? "Prepare for iPhone" : "Transfer",
                              systemImage: "square.and.arrow.up.fill")
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(state.transferring || state.albums.isEmpty || isUnauthorized)
                }
                if state.transferring {
                    ProgressView(value: max(0, min(state.transferProgress, 1)))
                }
                if isUnauthorized {
                    Text("Tap “Allow USB debugging” on the phone, then hit Refresh.")
                        .font(.caption).foregroundStyle(.orange)
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
