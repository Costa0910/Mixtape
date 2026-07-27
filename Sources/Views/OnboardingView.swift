import SwiftUI
import AppKit

struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var state: AppState
    @State private var step = 0
    @State private var missing: [Tool] = []

    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: how
                case 2: tools
                default: library
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .move(edge: .trailing)))

            footer
        }
        .background(
            LinearGradient(colors: [settings.accent.color.opacity(0.14), .clear],
                           startPoint: .top, endPoint: .center)
            .ignoresSafeArea()
        )
        .onAppear { missing = BinaryLocator.missingRequired() }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56, weight: .bold)).foregroundStyle(.white)
                .frame(width: 116, height: 116)
                .background(LinearGradient(colors: [settings.accent.color, settings.accent.color.opacity(0.6)],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 28))
                .shadow(color: settings.accent.color.opacity(0.4), radius: 20, y: 10)
            Text("Welcome to Mixtape").font(.system(size: 30, weight: .bold))
            Text("Download music from YouTube, organize it beautifully,\nand send it straight to your phone.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).font(.title3)
        }.padding(40)
    }

    private var how: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("How it works").font(.system(size: 26, weight: .bold))
            featureRow("link", "Paste a link", "A YouTube video or an entire playlist — Mixtape figures out the tracks.")
            featureRow("wand.and.stars", "Organized automatically", "Album folders, clean tags, embedded cover art, and playlist files.")
            featureRow("iphone.and.arrow.forward", "Onto your phone", "One-click to Android; guided import for iPhone.")
        }.frame(maxWidth: 520).padding(40)
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Engine check").font(.system(size: 26, weight: .bold))
            Text("Mixtape uses a few bundled tools. Distributed builds include them; if you're running from source, install or fetch them.")
                .foregroundStyle(.secondary)
            VStack(spacing: 10) {
                toolStatus(.ytdlp); toolStatus(.ffmpeg); toolStatus(.adb)
            }
            if !missing.isEmpty {
                Text("Missing: run Scripts/fetch-tools.sh — or `brew install \(missing.map(\.rawValue).joined(separator: " "))`. You can continue; Android needs adb only for transfers.")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button { missing = BinaryLocator.missingRequired() } label: {
                Label("Check again", systemImage: "arrow.clockwise")
            }
        }.frame(maxWidth: 520).padding(40)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Where should music go?").font(.system(size: 26, weight: .bold))
            Text("Downloads are organized into this folder.").foregroundStyle(.secondary)
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text(settings.libraryPath).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Change…", action: pickFolder)
            }
            .padding(14).background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            Text("You can change this any time in Settings.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: 520).padding(40)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { withAnimation(.smooth) { step -= 1 } }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Circle().fill(i == step ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.3)))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            Button(step == steps - 1 ? "Get started" : "Continue") {
                if step == steps - 1 { withAnimation(.smooth) { settings.hasOnboarded = true } }
                else { withAnimation(.smooth) { step += 1 } }
            }
            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(20)
        .background(.bar)
    }

    // MARK: helpers

    private func featureRow(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.tint)
                .frame(width: 46, height: 46)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(body).foregroundStyle(.secondary)
            }
        }
    }

    private func toolStatus(_ tool: Tool) -> some View {
        let ok = BinaryLocator.url(for: tool) != nil
        return HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(tool.rawValue).fontWeight(.medium)
            Spacer()
            Text(ok ? "Ready" : "Not found").foregroundStyle(.secondary).font(.callout)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = settings.libraryURL
        if panel.runModal() == .OK, let url = panel.url { settings.libraryPath = url.path }
    }
}
