import AVFoundation
import Foundation
import Speech

final class SpeechTranscriber {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalCompletion: ((String) -> Void)?
    private var lastText = ""
    private var didFinish = false

    var onPartial: ((String) -> Void)?

    func start(language: RecognitionLanguage) throws {
        cancel()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)) else {
            throw AppError.message("Speech recognizer unavailable for \(language.rawValue)")
        }
        guard recognizer.isAvailable else {
            throw AppError.message("Speech recognizer is not available now")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false

        self.recognizer = recognizer
        self.request = request
        lastText = ""
        didFinish = false

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                self.lastText = text
                DispatchQueue.main.async { [onPartial] in
                    onPartial?(text)
                }
            }

            if result?.isFinal == true || error != nil {
                self.completeOnce(self.lastText)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func finish(_ completion: @escaping (String) -> Void) {
        finalCompletion = completion
        request?.endAudio()

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.didFinish else { return }
            self.completeOnce(self.lastText)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        finalCompletion = nil
        lastText = ""
        didFinish = false
    }

    private func completeOnce(_ text: String) {
        guard !didFinish else {
            return
        }
        didFinish = true
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil

        let completion = finalCompletion
        finalCompletion = nil
        DispatchQueue.main.async {
            completion?(text)
        }
    }
}
