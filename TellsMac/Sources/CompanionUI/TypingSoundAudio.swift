import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// One bar of the beat (design/experiences.md Section 4, "Sound mapping"). A silent bar has 0 ticks.
struct RhythmBar: Equatable, Sendable {
    let ticks: Int          // 0, or 2 to 8
    let swing: Double       // 0 to 1
    let volume: Double      // 0, or 0.3 to 1

    static let silent = RhythmBar(ticks: 0, swing: 0, volume: 0)
}

/// The sound mapping (D-032) and the synthesized click. Pure functions. No audio file, no recording (hard rule 3).
// DEFAULT: D-095
enum TypingRhythm {
    static let totalSeconds = 30.0
    static let sampleRate = 44_100.0
    static let tickSeconds = 0.005
    static let tickHertz = 1_000.0
    static let ticksRange = 2...8
    /// A mean time between key presses of 100 ms or less gives 8 ticks. 400 ms or more gives 2 ticks.
    static let fastMeanMs = 100.0
    static let slowMeanMs = 400.0
    /// A standard deviation of 300 ms or more gives full swing.
    static let fullSwingSdMs = 300.0
    static let lowKeyCount = 20.0
    static let highKeyCount = 400.0
    static let minimumVolume = 0.3
    /// Headroom, so 2 ticks that overlap do not clip.
    static let gain = 0.5

    static func bar(for bar: TypingBar) -> RhythmBar {
        guard bar.isTyping, let mean = bar.ikiMean, let sd = bar.ikiSD, let keys = bar.keyCount else { return .silent }
        let speed = 1 - clamp((mean - fastMeanMs) / (slowMeanMs - fastMeanMs))
        let low = Double(ticksRange.lowerBound)
        let ticks = Int((low + speed * (Double(ticksRange.upperBound) - low)).rounded())
        let swing = clamp(sd / fullSwingSdMs)
        let loudness = clamp((keys - lowKeyCount) / (highKeyCount - lowKeyCount))
        return RhythmBar(ticks: ticks, swing: swing, volume: minimumVolume + loudness * (1 - minimumVolume))
    }

    static func bars(for day: TypingDay) -> [RhythmBar] { day.bars.map(bar(for:)) }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    /// The whole beat as mono samples. The bars share the 30 s equally. A tick swings by a fixed pattern, not by chance.
    static func render(_ bars: [RhythmBar], seconds: Double = totalSeconds, sampleRate: Double = sampleRate) -> [Float] {
        let total = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: total)
        guard !bars.isEmpty, total > 0 else { return samples }
        let barFrames = Double(total) / Double(bars.count)
        let tickFrames = max(1, Int(tickSeconds * sampleRate))
        for (barIndex, bar) in bars.enumerated() where bar.ticks > 0 {
            let slot = barFrames / Double(bar.ticks)
            for tick in 0..<bar.ticks {
                let shift = bar.swing * 0.5 * slot * jitter(bar: barIndex, tick: tick)
                let start = Int((Double(barIndex) * barFrames + Double(tick) * slot + max(0, shift)).rounded())
                for offset in 0..<tickFrames where start + offset < total {
                    let phase = Double(offset) / Double(tickFrames)
                    let envelope = sin(Double.pi * phase)
                    let wave = sin(2 * Double.pi * tickHertz * Double(offset) / sampleRate)
                    samples[start + offset] += Float(wave * envelope * bar.volume * gain)
                }
            }
        }
        return samples
    }

    /// -1 to 1. The same bar and tick always give the same value.
    static func jitter(bar: Int, tick: Int) -> Double {
        let hash = (bar &* 7_919 &+ tick &* 104_729) % 2_001
        return Double(hash) / 1_000 - 1
    }
}

enum RhythmPlayerError: Error { case noOutput, noFormat }

/// Plays 2 channels of samples. The real player uses `AVAudioEngine`. Tests use a fake.
@MainActor
protocol RhythmPlaying: AnyObject {
    var isAvailable: Bool { get }
    var isPlaying: Bool { get }
    var progress: Double { get }
    func play(left: [Float], right: [Float]) throws
    /// Ends the sound and frees the engine. Safe to call at any time.
    func stop()
}

/// The samples and the position. The audio thread reads it. The lock keeps the position safe.
final class BeatSource: Sendable {
    private struct State { var position = 0 }
    private let left: [Float]
    private let right: [Float]
    private let state = Mutex(State())

    init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }

    var frameCount: Int { min(left.count, right.count) }

    var progress: Double {
        guard frameCount > 0 else { return 1 }
        return min(1, Double(state.withLock { $0.position }) / Double(frameCount))
    }

    var isFinished: Bool { state.withLock { $0.position } >= frameCount }

    /// Writes `frames` samples to each channel and moves the position.
    func render(frames: Int, channels: [UnsafeMutablePointer<Float>]) {
        state.withLock { state in
            for index in 0..<frames {
                let at = state.position + index
                let inRange = at < frameCount
                for (channelIndex, channel) in channels.enumerated() {
                    channel[index] = inRange ? (channelIndex == 0 ? left[at] : right[at]) : 0
                }
            }
            state.position = min(frameCount, state.position + frames)
        }
    }
}

/// The real player: an `AVAudioSourceNode` into the main mixer. It never uses the input node (hard rule 3).
/// The engine exists only while a beat plays.
@MainActor
final class EngineRhythmPlayer: RhythmPlaying {
    private var engine: AVAudioEngine?
    private var source: BeatSource?

    var isAvailable: Bool { Self.hasOutputDevice() }
    var isPlaying: Bool { engine != nil && source?.isFinished == false }
    var progress: Double { source?.progress ?? 0 }

    func play(left: [Float], right: [Float]) throws {
        stop()
        guard isAvailable else { throw RhythmPlayerError.noOutput }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TypingRhythm.sampleRate,
                                         channels: 2, interleaved: false) else { throw RhythmPlayerError.noFormat }
        let source = BeatSource(left: left, right: right)
        let node = Self.makeNode(source: source, format: format)
        let engine = AVAudioEngine()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            engine.detach(node)
            throw error
        }
        self.engine = engine
        self.source = source
    }

    func stop() {
        engine?.stop()
        engine = nil
        source = nil
    }

    /// Not main actor: the render block runs on the audio thread.
    private nonisolated static func makeNode(source: BeatSource, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { _, _, frames, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let channels = buffers.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            source.render(frames: Int(frames), channels: channels)
            return noErr
        }
    }

    private static func hasOutputDevice() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != AudioObjectID(kAudioObjectUnknown)
    }
}
