import SwiftUI
import SwiftData

// First-run welcome that offers to pull in the music already on the iPhone.
struct OnboardingView: View {
    @Environment(\.modelContext) private var ctx
    @Binding var done: Bool
    @State private var importing = false
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 68))
                .foregroundStyle(.primary)
            Text("Welcome to Snag")
                .font(.largeTitle.bold()).tracking(-0.5).padding(.top, 20)
            Text("Your music, all in one place. Snag can bring in the songs already on your iPhone — and sync more from your Mac over Wi‑Fi.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 36).padding(.top, 12)

            Spacer()

            if importing {
                ProgressView().padding(.bottom, 6)
                Text(status).font(.callout).foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Button { Task { await allowAndImport() } } label: {
                    Text(importing ? "Importing…" : "Import my iPhone music")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color.indigo, in: Capsule()).foregroundStyle(.white)
                }
                .buttonStyle(Pressable()).disabled(importing)

                Button("Not now") { Haptics.light(); done = true }
                    .foregroundStyle(.secondary).disabled(importing)
            }
            .padding(.horizontal, 28).padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
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
        status = n > 0 ? "Added \(n) new songs 🎉" : "Nothing new to import."
        importing = false
    }
}
