import AVFoundation
import Foundation
import Speech

final class SpeechTranscriber {
    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalCompletion: ((String) -> Void)?
    private var lastText = ""
    private var completedEarly = false
    private var delivered = false
    private var sessionID = 0

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
        completedEarly = false
        delivered = false
        sessionID += 1
        let currentSessionID = sessionID

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            let isCurrentSession = currentSessionID == self.sessionID
            self.lock.unlock()
            guard isCurrentSession else { return }

            if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                self.lock.lock()
                self.lastText = text
                self.lock.unlock()
                DispatchQueue.main.async { [onPartial] in
                    onPartial?(text)
                }
            }

            if result?.isFinal == true || error != nil {
                self.lock.lock()
                let shouldComplete = self.finalCompletion != nil
                self.completedEarly = true
                let text = self.lastText
                self.lock.unlock()

                if shouldComplete {
                    self.completeOnce(text)
                } else {
                    self.stopTask()
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = request
        lock.unlock()
        request?.append(buffer)
    }

    func finish(_ completion: @escaping (String) -> Void) {
        lock.lock()
        finalCompletion = completion
        let request = request
        let shouldCompleteNow = completedEarly || request == nil
        let text = lastText
        lock.unlock()

        if shouldCompleteNow {
            completeOnce(text)
            return
        }

        request?.endAudio()

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldComplete = !self.delivered
            let text = self.lastText
            self.lock.unlock()
            if shouldComplete {
                self.completeOnce(text)
            }
        }
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        finalCompletion = nil
        lastText = ""
        completedEarly = false
        delivered = false
        sessionID += 1
        lock.unlock()
    }

    private func completeOnce(_ text: String) {
        lock.lock()
        guard !delivered else {
            lock.unlock()
            return
        }
        delivered = true
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil

        let completion = finalCompletion
        finalCompletion = nil
        lock.unlock()

        DispatchQueue.main.async {
            completion?(text)
        }
    }

    private func stopTask() {
        lock.lock()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        lock.unlock()
    }
}
