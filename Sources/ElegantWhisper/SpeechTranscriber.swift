import AVFoundation
import Foundation
import Speech

// SFSpeechRecognitionTask invokes its callback on a framework-managed thread.
// All mutable session state below is serialized through `queue`; UI callbacks
// are explicitly bounced to MainActor.
final class SpeechTranscriber: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aetherallan.ElegantWhisper.speech-transcriber")
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finalCompletion: (@MainActor @Sendable (String) -> Void)?
    private var lastText = ""
    private var completedEarly = false
    private var delivered = false
    private var sessionID = 0
    private var timeoutWorkItem: DispatchWorkItem?

    var onPartial: (@MainActor @Sendable (String) -> Void)?
    var onUnexpectedStop: (@MainActor @Sendable (String) -> Void)?

    func start(language: RecognitionLanguage, contextualStrings: [String] = []) throws {
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
        // Apple Speech contextual strings are vocabulary hints, not a prompt. We only pass
        // user-approved terms here, so the recognizer gets spelling help without any rewrite step.
        request.contextualStrings = contextualStrings

        queue.sync {
            self.recognizer = recognizer
            self.request = request
            self.lastText = ""
            self.completedEarly = false
            self.delivered = false
            self.timeoutWorkItem?.cancel()
            self.timeoutWorkItem = nil
            self.sessionID += 1
        }
        let currentSessionID = queue.sync { sessionID }

        let recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            guard self.isCurrentSession(currentSessionID) else { return }

            if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                self.queue.sync {
                    self.lastText = text
                }
                let handler = self.onPartial
                Task { @MainActor [weak self] in
                    guard self?.isCurrentSession(currentSessionID) == true else {
                        return
                    }
                    handler?(text)
                }
            }

            if result?.isFinal == true || error != nil {
                let state = self.queue.sync { () -> (Bool, String, String) in
                    self.completedEarly = true
                    let message = error?.localizedDescription ?? "Speech recognition ended before recording stopped"
                    return (self.finalCompletion != nil, self.lastText, message)
                }

                if state.0 {
                    self.completeOnce(state.1, sessionID: currentSessionID)
                } else {
                    self.stopTask()
                    let handler = self.onUnexpectedStop
                    Task { @MainActor [weak self] in
                        guard self?.isCurrentSession(currentSessionID) == true else {
                            return
                        }
                        handler?(state.2)
                    }
                }
            }
        }

        queue.sync {
            self.task = recognitionTask
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let request = queue.sync { self.request }
        request?.append(buffer)
    }

    func finish(_ completion: @escaping @MainActor @Sendable (String) -> Void) {
        let state = queue.sync { () -> (Int, SFSpeechAudioBufferRecognitionRequest?, Bool, String) in
            finalCompletion = completion
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            return (sessionID, request, completedEarly || request == nil, lastText)
        }

        if state.2 {
            completeOnce(state.3, sessionID: state.0)
            return
        }

        state.1?.endAudio()

        let expectedSessionID = state.0
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let timeoutState = self.queue.sync { () -> (Bool, String) in
                (self.sessionID == expectedSessionID && !self.delivered, self.lastText)
            }
            if timeoutState.0 {
                self.completeOnce(timeoutState.1, sessionID: expectedSessionID)
            }
        }
        queue.sync {
            timeoutWorkItem = workItem
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
    }

    func cancel() {
        let workItem = queue.sync { () -> DispatchWorkItem? in
            let workItem = timeoutWorkItem
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
            return workItem
        }
        workItem?.cancel()
    }

    private func completeOnce(_ text: String, sessionID expectedSessionID: Int) {
        let completion = queue.sync { () -> (@MainActor @Sendable (String) -> Void)? in
            guard self.sessionID == expectedSessionID, !delivered else {
                return nil
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
            return completion
        }

        Task { @MainActor in
            completion?(text)
        }
    }

    private func stopTask() {
        queue.sync {
            task?.cancel()
            task = nil
            request = nil
            recognizer = nil
        }
    }

    private func isCurrentSession(_ expectedSessionID: Int) -> Bool {
        queue.sync {
            sessionID == expectedSessionID && !delivered
        }
    }
}
