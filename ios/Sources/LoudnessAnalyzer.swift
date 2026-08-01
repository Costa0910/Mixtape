import AVFoundation
import Foundation

/// Lightweight, entirely local loudness analysis for imported music.
///
/// It measures gated 400 ms energy windows, then chooses a conservative gain
/// toward the normal listening level. Peak protection prevents boosted tracks
/// from clipping. The original audio file is never changed.
enum LoudnessAnalyzer {
    static let targetDBFS = -18.0
    static let maximumAdjustmentDB = 12.0
    static let peakCeilingDBFS = -1.0

    static func analyze(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }

        let windowFrames = max(1, Int(format.sampleRate * 0.4))
        let capacity = AVAudioFrameCount(min(max(windowFrames, 4_096), 65_536))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var windowEnergy = 0.0
        var windowSampleCount = 0
        var energies: [Double] = []
        var peak = 0.0

        while true {
            do { try file.read(into: buffer, frameCount: capacity) }
            catch { return nil }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { break }
            guard let channels = buffer.floatChannelData else { return nil }

            for frame in 0..<frames {
                var monoEnergy = 0.0
                for channel in 0..<Int(format.channelCount) {
                    let sample = Double(channels[channel][frame])
                    monoEnergy += sample * sample
                    peak = max(peak, abs(sample))
                }
                windowEnergy += monoEnergy / Double(format.channelCount)
                windowSampleCount += 1
                if windowSampleCount >= windowFrames {
                    energies.append(windowEnergy / Double(windowSampleCount))
                    windowEnergy = 0
                    windowSampleCount = 0
                }
            }
        }

        if windowSampleCount > 0 { energies.append(windowEnergy / Double(windowSampleCount)) }
        return recommendedGainDB(windowEnergies: energies, peak: peak)
    }

    static func recommendedGainDB(windowEnergies: [Double], peak: Double) -> Double? {
        let audible = windowEnergies.filter { energy in
            energy > 0 && 10 * log10(energy) > -70
        }
        guard !audible.isEmpty, peak > 0 else { return nil }

        let ungatedMean = audible.reduce(0, +) / Double(audible.count)
        let relativeGate = 10 * log10(ungatedMean) - 10
        let gated = audible.filter { 10 * log10($0) >= relativeGate }
        guard !gated.isEmpty else { return nil }

        let measuredDBFS = 10 * log10(gated.reduce(0, +) / Double(gated.count))
        let peakDBFS = 20 * log10(peak)
        let peakLimitedBoost = peakCeilingDBFS - peakDBFS
        let desired = targetDBFS - measuredDBFS
        let gain = min(desired, peakLimitedBoost)
        return min(max(gain, -maximumAdjustmentDB), maximumAdjustmentDB)
    }
}
