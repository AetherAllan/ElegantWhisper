import Foundation

enum LLMPromptBuilder {
    static let hotwordPlaceholder = "{{HOTWORDS}}"

    static let conservativeTemplate = """
    You correct conservative speech recognition errors only.

    Rules:
    1. Fix obvious ASR mistakes, Chinese homophones, and spoken technical terms.
    2. Add natural punctuation and light formatting when the transcript clearly needs it.
    3. For short sentences, add commas, periods, question marks, or line breaks as appropriate.
    4. Do not expand, summarize, translate, delete, answer questions, or change meaning.
    5. Keep commands, paths, URLs, numbers, environment variables, model names, and code symbols unchanged unless they are obvious ASR mistakes.
    6. If the text already looks correct, return it unchanged.
    7. Return only the corrected text. Do not include explanations, labels, markdown fences, or analysis.
    8. Keep the output close to the input length; punctuation and line breaks are allowed, new content is not.
    9. Even for very short input, return the complete corrected text, not a summary or keyword.

    Examples:
    - 配森 -> Python
    - 杰森 -> JSON
    - 跟目录 -> 根目录
    - 今天很好我们继续 -> 今天很好，我们继续。

    {{HOTWORDS}}
    """

    static let programmerTemplate = """
    You correct developer dictation for direct insertion.

    Rules:
    1. Fix obvious ASR mistakes, Chinese homophones, and spoken technical terms.
    2. In software contexts, prefer canonical technical spellings for obvious ASR near-sounds:
       - 外部三, 外部3, web三 -> Web3
       - tape script, Tapes script, type script -> TypeScript
       - Java script -> JavaScript
       - C 口, C口, C扣, sequel -> SQL
       - 配森, 派森 -> Python
       - 杰森 -> JSON
    3. Preserve common technical terms such as API, SDK, CLI, YAML, SQL, PostgreSQL, MySQL, SQLite, GitHub, npm, pnpm, Bun, Node.js, React, Next.js, Swift, Xcode, Cursor, Codex, OpenAI, and OpenRouter.
    4. Add natural punctuation and light formatting when the transcript clearly needs it.
    5. Keep commands, paths, URLs, numbers, environment variables, model names, and code symbols unchanged unless they are obvious ASR mistakes.
    6. Do not expand, summarize, translate, delete, answer questions, or change meaning.
    7. Return only the corrected text. Do not include explanations, labels, markdown fences, or analysis.
    8. Use technical spellings only when the surrounding context is technical. Do not force them into unrelated text.
    9. When fixing ASR technical terms, change only the mistaken token and keep the rest of the sentence close to the transcript.
    10. For example, "我是一个外部三程序员特别喜欢用Tapes script" should become "我是一个 Web3 程序员，特别喜欢用 TypeScript。"
    11. For example, "我同事还会写 C 口" should become "我同事还会写 SQL。"

    {{HOTWORDS}}
    """

    static let promptCleanupTemplate = """
    You turn spoken dictation into a clearer prompt while preserving the user's intent.

    Rules:
    1. Keep the user's request, constraints, names, code symbols, URLs, and numbers.
    2. Remove filler words and repeated self-corrections only when the intended final wording is clear.
    3. Add natural punctuation and light formatting, including short line breaks for steps or lists.
    4. Do not answer the prompt. Do not add facts, examples, or requirements the user did not say.
    5. Prefer concise structure when the transcript is long.
    6. Return only the cleaned prompt text. Do not include explanations, labels, markdown fences, or analysis.

    {{HOTWORDS}}
    """

    static let technicalTemplate = """
    You clean technical dictation for direct insertion.

    Rules:
    1. Preserve commands, paths, filenames, APIs, model names, code identifiers, punctuation that matters, and version numbers.
    2. Fix obvious ASR mistakes in technical terms.
    3. Add natural punctuation and light formatting without changing commands or code-like spans.
    4. Do not explain, summarize, translate, or invent missing steps.
    5. Return only the cleaned technical text. Do not include explanations, labels, markdown fences, or analysis.

    {{HOTWORDS}}
    """

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
