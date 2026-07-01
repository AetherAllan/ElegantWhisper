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
    private var timeoutWorkItem: DispatchWorkItem?

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
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        sessionID += 1
        let currentSessionID = sessionID

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            let isCurrentSession = currentSessionID == self.sessionID && !self.delivered
            self.lock.unlock()
            guard isCurrentSession else { return }

            if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                self.lock.lock()
                self.lastText = text
                self.lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    guard self?.isCurrentSession(currentSessionID) == true else {
                        return
                    }
                    self?.onPartial?(text)
                }
            }

            if result?.isFinal == true || error != nil {
                self.lock.lock()
                let shouldComplete = self.finalCompletion != nil
                self.completedEarly = true
                let text = self.lastText
                self.lock.unlock()

                if shouldComplete {
                    self.completeOnce(text, sessionID: currentSessionID)
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
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let expectedSessionID = sessionID
        let request = request
        let shouldCompleteNow = completedEarly || request == nil
        let text = lastText
        lock.unlock()

        if shouldCompleteNow {
            completeOnce(text, sessionID: expectedSessionID)
            return
        }

        request?.endAudio()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldComplete = self.sessionID == expectedSessionID && !self.delivered
            let text = self.lastText
            self.lock.unlock()
            if shouldComplete {
                self.completeOnce(text, sessionID: expectedSessionID)
            }
        }
        lock.lock()
        timeoutWorkItem = workItem
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
    }

    func cancel() {
        lock.lock()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
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

    private func completeOnce(_ text: String, sessionID expectedSessionID: Int) {
        lock.lock()
        guard self.sessionID == expectedSessionID, !delivered else {
            lock.unlock()
            return
        }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        delivered = true
        sessionID += 1
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

    private func isCurrentSession(_ expectedSessionID: Int) -> Bool {
        lock.lock()
        let result = sessionID == expectedSessionID && !delivered
        lock.unlock()
        return result
    }
}
