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
    var onLevel: (@MainActor @Sendable (Float) -> Void)?

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
            let levelMeter = AudioLevelMeter(onLevel: onLevel)
            let bufferCallback = onBuffer
            input.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: format,
                block: Self.makeTapBlock(levelMeter: levelMeter, bufferCallback: bufferCallback)
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
        let callback = onLevel
        Task { @MainActor in
            callback?(0)
        }
    }

    nonisolated private static func makeTapBlock(
        levelMeter: AudioLevelMeter,
        bufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?
    ) -> AVAudioNodeTapBlock {
        // Build this closure outside MainActor isolation. AVAudioEngine invokes
        // tap blocks on its realtime audio queue; a MainActor-isolated closure
        // traps at runtime under Swift 6 executor checks.
        { buffer, _ in
            levelMeter.update(with: buffer)
            bufferCallback?(buffer)
        }
    }
}

// ponytail: one meter per installed tap. AVAudioEngine delivers a tap serially,
// so the smoothing envelope is owned by that callback path and is never reset
// from MainActor. If Apple ever documents concurrent tap delivery, replace this
// with a lock-free atomic Float or move level smoothing to MainActor.
private final class AudioLevelMeter: @unchecked Sendable {
    private var smoothedLevel: Float = 0
    private let onLevel: (@MainActor @Sendable (Float) -> Void)?

    init(onLevel: (@MainActor @Sendable (Float) -> Void)?) {
        self.onLevel = onLevel
    }

    func update(with buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return
        }

        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }

        let rms = min(1, sqrt(sum / Float(count)) * 18)
        let coefficient: Float = rms > smoothedLevel ? 0.40 : 0.15
        smoothedLevel += (rms - smoothedLevel) * coefficient

        let level = smoothedLevel
        let callback = onLevel
        Task { @MainActor in
            callback?(level)
        }
    }
}
