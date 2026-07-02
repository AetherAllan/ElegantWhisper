import AVFoundation
import Foundation

// AVAudioEngine calls the input tap on a realtime audio thread, while the app
// uses the recorder from the main controller. The mutable engine state is still
// owned by AppController's state machine; this conformance only tells Swift that
// the callback handoff below is intentional and that UI work is re-entered on
// MainActor.
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var smoothedLevel: Float = 0
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
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.updateLevel(buffer)
                self.onBuffer?(buffer)
            }
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
        smoothedLevel = 0
        let callback = onLevel
        Task { @MainActor in
            callback?(0)
        }
    }

    private func updateLevel(_ buffer: AVAudioPCMBuffer) {
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
