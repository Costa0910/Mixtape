import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = PlaybackSettings.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RecommendationPreferences.memoryKey) private var memoryRaw = TasteMemory.balanced.rawValue
    @AppStorage(RecommendationPreferences.discoveryKey) private var discovery = 0.45
    @AppStorage(RecommendationPreferences.timelessFavoritesKey) private var timelessFavorites = true
    @AppStorage(RecommendationPreferences.learnFromSkipsKey) private var learnFromSkips = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Equalizer", isOn: $settings.eqEnabled)
                    if settings.eqEnabled {
                        Picker("Preset", selection: $settings.eqPreset) {
                            ForEach(EQPreset.allCases) { Text($0.rawValue).tag($0) }
                        }
                        EQBandsView().listRowInsets(EdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8))
                    }
                } header: { Text("Equalizer") } footer: {
                    if settings.eqEnabled { Text("Drag a band to fine-tune (switches to Custom).") }
                }

                Section {
                    Toggle("Sound Check", isOn: $settings.normalizationEnabled)
                    Toggle("Gapless Playback", isOn: $settings.gaplessEnabled)
                    Toggle("Crossfade", isOn: $settings.crossfadeEnabled)
                    if settings.crossfadeEnabled {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text("\(Int(settings.crossfadeSeconds)) sec").foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.crossfadeSeconds, in: 1...12, step: 1)
                    }
                } header: { Text("Playback") } footer: {
                    Text("Sound Check evens out volume without changing your files. Gapless Playback removes silence between consecutive tracks. Crossfade replaces the gapless transition when enabled.")
                }

                Section {
                    Picker("Taste Memory", selection: $memoryRaw) {
                        ForEach(TasteMemory.allCases) { memory in
                            Text(memory.title).tag(memory.rawValue)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Discovery")
                            Spacer()
                            Text(discoveryLabel).foregroundStyle(.secondary)
                        }
                        Slider(value: $discovery, in: 0...1, step: 0.05) {
                            Text("Discovery")
                        } minimumValueLabel: {
                            Image(systemName: "person.fill")
                        } maximumValueLabel: {
                            Image(systemName: "sparkles")
                        }
                    }

                    Toggle("Keep Favorites Timeless", isOn: $timelessFavorites)
                    Toggle("Learn from Skips", isOn: $learnFromSkips)
                } header: { Text("Smart Mix") } footer: {
                    Text("Taste Memory controls how quickly old listening habits fade. Favorites stay marked until you remove the heart; when Keep Favorites Timeless is on, their recommendation boost never fades. Everything is calculated on this iPhone.")
                }

                Section {
                    ImportDeviceMusicButton()
                } header: { Text("Library") }

                Section {
                    Label("Listening history stays on this device", systemImage: "iphone.and.arrow.forward")
                    Label("Wi-Fi sync connects directly to your Mac", systemImage: "wifi")
                    Label("No account, ads, or analytics", systemImage: "hand.raised")
                } header: { Text("Privacy & Data") } footer: {
                    Text("Play, skip, and favorite history is used only on this iPhone to improve Smart Mix and autoplay.")
                }

                Section {
                    HStack { Text("Version"); Spacer(); Text(appVersion).foregroundStyle(.secondary) }
                    Text("Snag plays the music on your device — fully offline.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("About") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private var discoveryLabel: String {
        switch discovery {
        case ..<0.34: "Familiar"
        case 0.34..<0.67: "Balanced"
        default: "Adventurous"
        }
    }
}

/// A row of vertical EQ sliders (one per frequency band).
struct EQBandsView: View {
    @ObservedObject private var settings = PlaybackSettings.shared
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<PlaybackSettings.bandCount, id: \.self) { i in
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { Double(settings.effectiveGains.indices.contains(i) ? settings.effectiveGains[i] : 0) },
                            set: { settings.setBand(i, Float($0)) }
                        ),
                        in: -12...12
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 108)
                    .frame(width: 30, height: 108)
                    .tint(.indigo)
                    Text(labels[i]).font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
