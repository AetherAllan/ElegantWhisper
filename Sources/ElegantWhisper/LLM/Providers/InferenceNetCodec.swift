import Foundation

struct InferenceNetCodec: LLMProviderCodec {
    private let plainBase = OpenAICompatibleCodec()
    private let structuredBase = OpenAICompatibleCodec(
        correctedTextDescription: "The final corrected ASR transcript for direct insertion. Fix obvious homophones and missing punctuation. Do not copy the transcript verbatim when corrections are needed."
    )

    func makeRequest(
        request: LLMTextRequest,
        endpoint: URL,
        apiKey: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard request.outputFormat == .correctedTextJSON else {
            return try plainBase.makeRequest(request: request, endpoint: endpoint, apiKey: apiKey, timeout: timeout)
        }

        // Schematron is tuned as an extraction model. A short instruction keeps it from copying
        // long style-pack rules into corrected_text while still letting normal providers use the
        // full style prompt through OpenAICompatibleCodec.
        let schematronRequest = LLMTextRequest(
            model: request.model,
            systemPrompt: Self.structuredSystemPrompt(from: request.systemPrompt),
            userText: Self.transcriptUserMessage(request.userText),
            temperature: request.temperature,
            maxOutputTokens: request.maxOutputTokens,
            outputFormat: .correctedTextJSON
        )
        return try structuredBase.makeRequest(
            request: schematronRequest,
            endpoint: endpoint,
            apiKey: apiKey,
            timeout: timeout
        )
    }

    func parseResponse(
        data: Data,
        httpResponse: HTTPURLResponse,
        outputFormat: LLMOutputFormat
    ) throws -> LLMTextResponse {
        try (outputFormat == .correctedTextJSON ? structuredBase : plainBase)
            .parseResponse(data: data, httpResponse: httpResponse, outputFormat: outputFormat)
    }

    func classifyError(statusCode: Int, data: Data?) -> LLMProviderError {
        plainBase.classifyError(statusCode: statusCode, data: data)
    }

    func supports(outputFormat: LLMOutputFormat, model: String) -> Bool {
        switch outputFormat {
        case .plainText:
            true
        case .correctedTextJSON:
            model.lowercased().hasPrefix("inference-net/schematron-v2")
        }
    }

    private static func structuredSystemPrompt(from systemPrompt: String) -> String {
        var prompt = """
        You are an ASR correction engine for a macOS voice input app.

        Task:
        Rewrite the raw speech transcript into the final direct-insertion text.
        The user message is one line: transcript: followed by the ASR text to correct.

        Rules:

        Put only the final corrected text in corrected_text.
        Preserve the user's intended meaning.
        Keep the original language. Never translate.
        Chinese input must stay Chinese. Mixed Chinese-English input must stay mixed.
        Do not answer questions, add facts, summarize, explain, or expand.
        Do not include labels, markdown, schema reminders, or validation text.
        Fix obvious ASR mistakes, homophones, punctuation, spacing, and spoken technical terms.
        Add natural Chinese punctuation and commas when the spoken text clearly needs pauses or sentence breaks.
        Remove obvious hesitation only when it does not change meaning, such as repeated filler words: 这个这个, 因为因为, 我觉得我觉得.
        Do not aggressively rewrite style. Prefer minimal correction suitable for direct insertion.
        Do not return corrected_text identical to the transcript unless every homophone, spacing mark, and punctuation mark is already correct.

        Required technical corrections when context makes them obvious:

        外部三 / web三 / web 三 -> Web3
        Top script / Tape script / Type script / 台普 script -> TypeScript
        Java script -> JavaScript
        杰森 -> JSON
        配森 / 派森 -> Python
        C口 / sequel -> SQL
        open router -> OpenRouter
        open ai -> OpenAI
        swift UI -> SwiftUI
        APP kit / app kit -> AppKit

        Examples:
        transcript: 我是一个外部三程序员，特别喜欢用Top script代码
        corrected_text: 我是一个 Web3 程序员，特别喜欢用 TypeScript 代码。

        transcript: 我用杰森解析配森脚本里的API返回
        corrected_text: 我用 JSON 解析 Python 脚本里的 API 返回。

        transcript: 这个这个我觉得我觉得用swift UI做这个功能比较好
        corrected_text: 我觉得用 SwiftUI 做这个功能比较好。

        transcript: 就我现在发给你这句话就是我用它润色之后的基本没效果呀
        corrected_text: 就我现在发给你，这句话就是我用它润色之后，基本上没效果呀。
        """

        if let localContext = localContextSection(from: systemPrompt) {
            prompt += "\n\n\(localContext)"
        }
        return prompt
    }

    private static func transcriptUserMessage(_ transcript: String) -> String {
        "transcript: \(transcript)"
    }

    private static func localContextSection(from systemPrompt: String) -> String? {
        // SpeechFocusContext owns the exact "Local context:" section text. Schematron gets only
        // that section plus the short extraction prompt, not the full editable style-pack prompt.
        guard let range = systemPrompt.range(of: "\n\nLocal context:\n", options: .backwards) else {
            return nil
        }
        return String(systemPrompt[range.upperBound...]).isEmpty
            ? nil
            : "Local context:\n\(systemPrompt[range.upperBound...])"
    }
}
