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
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                settings.restoreOriginalSound()
                            }
                            Haptics.success()
                        } label: {
                            Label("Restore Original Sound", systemImage: "arrow.counterclockwise")
                        }
                        .accessibilityHint("Turns off the equalizer and clears all custom adjustments")
                    }
                } header: { Text("Equalizer") } footer: {
                    if settings.eqEnabled {
                        Text("Drag a band to fine-tune (switches to Custom), or restore the song's original sound.")
                    } else {
                        Text("Off plays each song without equalizer adjustments.")
                    }
                }

                Section {
                    Toggle("Sound Check", isOn: $settings.normalizationEnabled)
                    Toggle("Gapless Playback", isOn: Binding(
                        get: { settings.gaplessEnabled },
                        set: { settings.setGaplessEnabled($0) }
                    ))
                    Toggle("Crossfade", isOn: Binding(
                        get: { settings.crossfadeEnabled },
                        set: { settings.setCrossfadeEnabled($0) }
                    ))
                    if settings.crossfadeEnabled {
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text("\(Int(settings.crossfadeSeconds)) sec").foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.crossfadeSeconds, in: 1...12, step: 1)
                    }
                } header: { Text("Playback") } footer: {
                    Text("Sound Check balances volume. Gapless removes silence between tracks; Crossfade blends them instead.")
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
                    Text("Choose how quickly older listening affects Smart Mix. Recommendations are calculated on this iPhone.")
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
            .tint(AppTheme.accent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
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
                    .tint(AppTheme.accent)
                    .accessibilityLabel("\(labels[i]) hertz")
                    .accessibilityValue("\(Int(settings.effectiveGains.indices.contains(i) ? settings.effectiveGains[i] : 0)) decibels")
                    Text(labels[i])
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
