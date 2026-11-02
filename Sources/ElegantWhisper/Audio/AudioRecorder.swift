import Accelerate
import AVFoundation
import Foundation

// AVAudioEngine calls the input tap on a realtime audio thread. Keep recorder
// lifecycle state on MainActor and keep per-buffer audio state inside the tap's
// private AudioLevelMeter so stop/start never races the realtime callback.
@MainActor
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var isRunning = false
    private var tapInstalled = false

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Levels for consecutive 1/60 s slices of audio, oldest first, delivered once per tap buffer.
    var onLevels: (@MainActor @Sendable ([Float]) -> Void)?

    func start() throws {
        if isRunning {
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AppError.message("No valid audio input device")
        }
        input.removeTap(onBus: 0)
        tapInstalled = false

        do {
            let levelSmoother = AudioLevelSmoother(onLevels: onLevels)
            let bufferCallback = onBuffer
            input.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: format,
                block: Self.makeTapBlock(levelSmoother: levelSmoother, bufferCallback: bufferCallback)
            )
            tapInstalled = true

            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            if tapInstalled {
                input.removeTap(onBus: 0)
            }
            tapInstalled = false
            isRunning = false
            engine.stop()
            throw error
        }
    }

    func stop() {
        guard isRunning || tapInstalled else {
            return
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        isRunning = false
        tapInstalled = false
        let callback = onLevels
        Task { @MainActor in
            callback?([0])
        }
    }

    nonisolated private static func makeTapBlock(
        levelSmoother: AudioLevelSmoother,
        bufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) -> AVAudioNodeTapBlock {
        // Build this closure outside MainActor isolation. AVAudioEngine invokes
        // tap blocks on its realtime audio queue; a MainActor-isolated closure
        // traps at runtime under Swift 6 executor checks.
        { buffer, _ in
            levelSmoother.update(with: buffer)
            bufferCallback?(buffer)
        }
    }
}

// ponytail: one smoother per installed tap. AVAudioEngine delivers a tap serially,
// so the smoothing envelope is owned by that callback path and is never reset
// from MainActor. If Apple ever documents concurrent tap delivery, replace this
// with a lock-free atomic Float or move level smoothing to MainActor.
//
// macOS often delivers ~100 ms tap buffers whatever bufferSize asks for, so one level per buffer
// animates at about 10 fps. Slicing each buffer into display-rate chunks lets the HUD play the
// levels back one per frame.
private final class AudioLevelSmoother: @unchecked Sendable {
    static let levelsPerSecond: Double = 60

    private var meter = VoiceLevelMeter()
    private let onLevels: (@MainActor @Sendable ([Float]) -> Void)?

    init(onLevels: (@MainActor @Sendable ([Float]) -> Void)?) {
        self.onLevels = onLevels
    }

    func update(with buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        let chunkSize = max(64, Int(buffer.format.sampleRate / Self.levelsPerSecond))
        var levels: [Float] = []
        levels.reserveCapacity(frameCount / chunkSize + 1)
        var offset = 0
        while offset < frameCount {
            let length = min(chunkSize, frameCount - offset)
            var rms: Float = 0
            vDSP_rmsqv(channel + offset, 1, &rms, vDSP_Length(length))
            levels.append(meter.process(rms: rms))
            offset += length
        }

        let callback = onLevels
        Task { @MainActor in
            callback?(levels)
        }
    }
}

/// Turns raw RMS into a calm 0...1 display level for the waveform. Display only: the audio sent
/// to speech recognition is untouched.
///
/// - Loudness is measured in dB, closer to how loud speech sounds than linear RMS, which pinned
///   bars at the top for normal speech.
/// - An adaptive noise floor follows the room (fans, air conditioning) so steady background noise
///   reads as silence instead of constant flicker.
/// - A soft knee keeps loud speech below the top of the bar.
struct VoiceLevelMeter {
    /// Expected to be called once per 1/60 s chunk; the rates below assume that.
    /// Typical laptop-mic room noise, so a new recording starts close to the real floor.
    private(set) var noiseFloorDB: Float = -50
    private(set) var level: Float = 0

    static let minimumFloorDB: Float = -75
    static let maximumFloorDB: Float = -35
    /// Voice must rise this far above the floor before bars move.
    static let gateDB: Float = 6
    /// dB above the gate that map to the full input range of the knee.
    static let rangeDB: Float = 36
    /// Loudest bar height; normal speech lands around 0.5-0.75.
    static let ceiling: Float = 0.9

    mutating func process(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        // Fall to quieter readings quickly (pauses between words reveal the room) and rise at about
        // 5 dB a second: fast enough to learn a noisy room in a couple of seconds, slow enough that
        // a syllable never becomes the floor.
        if db < noiseFloorDB {
            noiseFloorDB += (db - noiseFloorDB) * 0.3
        } else {
            noiseFloorDB += 0.08
        }
        noiseFloorDB = min(max(noiseFloorDB, Self.minimumFloorDB), Self.maximumFloorDB)

        let normalized = min(max((db - noiseFloorDB - Self.gateDB) / Self.rangeDB, 0), 1)
        let target = Self.ceiling * tanh(1.6 * normalized)
        // Rise fast enough to follow syllables, fall gently so bars settle instead of flickering.
        let coefficient: Float = target > level ? 0.35 : 0.12
        level += (target - level) * coefficient
        return level
    }
}
