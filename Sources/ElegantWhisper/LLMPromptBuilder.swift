import Foundation

enum LLMPromptBuilder {
    static let hotwordPlaceholder = "{{HOTWORDS}}"

    static let conservativeTemplate = """
    You correct conservative speech recognition errors only.

    Rules:
    1. Fix obvious ASR mistakes, Chinese homophones, and spoken technical terms.
    2. Do not polish, expand, summarize, translate, delete, answer questions, or change meaning.
    3. Keep commands, paths, URLs, numbers, environment variables, model names, and code symbols unchanged unless they are obvious ASR mistakes.
    4. If the text already looks correct, return it unchanged.
    5. Return only the corrected text.

    Examples:
    - 配森 -> Python
    - 杰森 -> JSON
    - 跟目录 -> 根目录

    {{HOTWORDS}}
    """

    static let promptCleanupTemplate = """
    You turn spoken dictation into a clearer prompt while preserving the user's intent.

    Rules:
    1. Keep the user's request, constraints, names, code symbols, URLs, and numbers.
    2. Remove filler words and repeated self-corrections only when the intended final wording is clear.
    3. Do not answer the prompt. Do not add facts, examples, or requirements the user did not say.
    4. Prefer concise structure when the transcript is long.
    5. Return only the cleaned prompt text.

    {{HOTWORDS}}
    """

    static let technicalTemplate = """
    You clean technical dictation for direct insertion.

    Rules:
    1. Preserve commands, paths, filenames, APIs, model names, code identifiers, punctuation that matters, and version numbers.
    2. Fix obvious ASR mistakes in technical terms.
    3. Do not explain, summarize, translate, or invent missing steps.
    4. Return only the cleaned technical text.

    {{HOTWORDS}}
    """

    static func systemPrompt(stylePack: StylePack, hotwords: [String]) -> String {
        systemPrompt(template: stylePack.systemPrompt, hotwords: hotwords)
    }

    static func systemPrompt(template rawTemplate: String, hotwords: [String]) -> String {
        let template = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? conservativeTemplate
            : rawTemplate
        let block = hotwordBlock(hotwords)
        if template.contains(hotwordPlaceholder) {
            return template.replacingOccurrences(of: hotwordPlaceholder, with: block)
        }
        // If users remove the placeholder, keep dictionary hints as a safety footer instead of
        // silently dropping them. This mirrors OpenLess' "move or delete placeholder" behavior
        // without needing a full style-pack runtime.
        return "\(template)\n\n\(block)"
    }

    private static func hotwordBlock(_ hotwords: [String]) -> String {
        let values = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(80)
            .map(sanitizedHotword)

        guard !values.isEmpty else {
            return """
            User dictionary:
            No user dictionary terms are configured. Use context to fix only obvious recognition errors.
            """
        }

        // Dictionary terms are semantic hints, not mechanical replacements. This matches OpenLess'
        // hotword idea while keeping ElegantWhisper's stronger "do not change meaning" boundary.
        let bullets = values.map { "- \($0)" }.joined(separator: "\n")
        return """
        User dictionary:
        Prefer these spellings when the transcript contains a clear homophone, near-sound, or ASR typo for them. Do not force them into unrelated text.
        \(bullets)
        """
    }

    private static func sanitizedHotword(_ value: String) -> String {
        // Dictionary terms are local user data, but they still enter a system prompt. Keep each
        // term one-line and short so an accidental pasted paragraph cannot become prompt control.
        String(value.filter { $0 != "\n" && $0 != "\r" }.prefix(80))
    }
}
