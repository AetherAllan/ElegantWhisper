import AVFoundation
import Foundation

final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var smoothedLevel: Float = 0
    private var isRunning = false
    private var tapInstalled = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?

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
        DispatchQueue.main.async { [onLevel] in
            onLevel?(0)
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

        DispatchQueue.main.async { [onLevel, smoothedLevel] in
            onLevel?(smoothedLevel)
        }
    }
}
