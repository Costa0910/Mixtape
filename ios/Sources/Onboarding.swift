import SwiftUI
import SwiftData

// First-run welcome that offers to pull in the music already on the iPhone.
struct OnboardingView: View {
    @Environment(\.modelContext) private var ctx
    @Binding var done: Bool
    @State private var importing = false
    @State private var status = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 16) {
                    BrandMark()

                    VStack(spacing: 8) {
                        Text("Your music. Your iPhone.")
                            .font(.largeTitle.weight(.bold))
                            .tracking(-0.7)
                            .multilineTextAlignment(.center)
                        Text("Listen offline, build playlists, and sync your collection directly from your Mac.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                VStack(spacing: 0) {
                    onboardingRow("Import what you already own", symbol: "music.note")
                    Divider().padding(.leading, 52)
                    onboardingRow("Sync privately over Wi-Fi", symbol: "wifi")
                    Divider().padding(.leading, 52)
                    onboardingRow("No account, ads, or analytics", symbol: "hand.raised.fill")
                }
                .groupedSurface()

                VStack(spacing: 12) {
                    if importing {
                        ProgressView(status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }

                    Button { Task { await allowAndImport() } } label: {
                        Label(importing ? "Importing…" : "Import iPhone music",
                              systemImage: importing ? "arrow.down.circle" : "music.note.list")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(importing)

                    Button("Set up later") { Haptics.light(); done = true }
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                        .disabled(importing)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .appScreenBackground()
    }

    private func onboardingRow(_ title: String, symbol: String) -> some View {
        Label {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(AppTheme.accent)
                .frame(width: 28)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func allowAndImport() async {
        importing = true; status = "Asking for permission…"
        let ok = await MediaLibrary.requestAccess()
        if ok {
            let n = await MediaLibrary.importAll(into: ctx) { i, total in
                status = "Importing \(i) of \(total)…"
            }
            if n > 0 { Haptics.success() }
            status = n > 0 ? "Added \(n) songs" : "No local songs found"
        } else {
            status = "You can allow access later in Settings."
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        importing = false
        done = true
    }
}

/// Reusable button to (re)scan the phone's music library — used on the Sync screen.
struct ImportDeviceMusicButton: View {
    @Environment(\.modelContext) private var ctx
    @State private var importing = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { Task { await run() } } label: {
                HStack {
                    if importing { ProgressView() }
                    Label(importing ? "Scanning…" : "Import iPhone Music", systemImage: "iphone.gen3")
                    Spacer()
                }
            }.disabled(importing)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func run() async {
        importing = true; status = ""
        let ok = await MediaLibrary.requestAccess()
        guard ok else { status = "Access denied — enable it in Settings › Snag."; importing = false; return }
        let n = await MediaLibrary.importAll(into: ctx) { i, total in status = "Importing \(i) of \(total)…" }
        if n > 0 { Haptics.success() }
        status = n > 0 ? "Added \(n) new songs" : "Nothing new to import"
        importing = false
    }
}
