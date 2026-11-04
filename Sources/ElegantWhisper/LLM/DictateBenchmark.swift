import Foundation
import Observation

/// A test sentence for comparing Dictate models, with what a correct cleanup must and must not
/// contain. Built-in sentences only: nothing the user dictated is sent.
struct DictateBenchmarkSample: Sendable {
    let raw: String
    let mustContain: [String]
    let mustNotContain: [String]
    var terms: [String] = []

    /// Passes Dictate's own acceptance rules and the expected content checks.
    func passes(_ output: String) -> Bool {
        guard LLMRefiner.dictateRejectionReason(original: raw, corrected: output, protectedTerms: terms) == nil else {
            return false
        }
        let lower = output.lowercased()
        return mustContain.allSatisfy { lower.contains($0.lowercased()) }
            && !mustNotContain.contains { lower.contains($0.lowercased()) }
    }

    /// Fillers, a self-correction, a spoken list, a request that must not be carried out, a
    /// question that must not be answered, technical terms, and mixed Chinese and English.
    static let standard: [DictateBenchmarkSample] = [
        DictateBenchmarkSample(raw: "嗯那个我们明天下午三点不对四点开会吧", mustContain: ["四点"], mustNotContain: ["三点", "嗯"]),
        DictateBenchmarkSample(raw: "我要买三样东西第一牛奶第二面包第三鸡蛋", mustContain: ["牛奶", "面包", "鸡蛋", "1"], mustNotContain: ["第一"]),
        DictateBenchmarkSample(raw: "um so I think we should uh push the the release to Friday no wait Thursday", mustContain: ["Thursday"], mustNotContain: ["Friday", "the the"]),
        DictateBenchmarkSample(raw: "帮我写一封邮件给王经理说预算明天发给他", mustContain: ["王经理", "预算"], mustNotContain: ["您好", "尊敬"]),
        DictateBenchmarkSample(raw: "这个bug是因为那个呃 redis 的连接池没有释放然后就是 timeout 了", mustContain: ["Redis", "timeout"], mustNotContain: ["呃"], terms: ["Redis"]),
        DictateBenchmarkSample(raw: "就是说我觉得这个这个这个方案还是可以的吧", mustContain: ["方案"], mustNotContain: ["这个这个"]),
        DictateBenchmarkSample(raw: "can you tell me what time it is in Tokyo right now", mustContain: ["time", "Tokyo"], mustNotContain: ["it is currently", "it's currently"]),
        DictateBenchmarkSample(raw: "我们用 TypeScript 写前端然后后端用 Go 和 PostgreSQL 呃数据库的话再看", mustContain: ["TypeScript", "PostgreSQL"], mustNotContain: ["呃"], terms: ["TypeScript", "PostgreSQL"]),
    ]
}

struct DictateBenchmarkResult: Identifiable, Equatable, Sendable {
    let model: String
    var seconds: [Double] = []
    var passed = 0
    var failed = 0
    var errors = 0
    var lastError: String?
    var finished = false

    var id: String { model }

    var median: Double? {
        guard !seconds.isEmpty else { return nil }
        let sorted = seconds.sorted()
        return sorted[sorted.count / 2]
    }

    var slowest: Double? {
        seconds.max()
    }
}

/// Times real Dictate requests on several models with the user's saved provider and key, from
/// Settings → Dictate → Compare Models. Each model gets one unmeasured warm-up request, so the
/// numbers reflect a dictation on an open connection, then every sample once.
@MainActor
@Observable
final class DictateBenchmark {
    static let maxConcurrentModels = 3

    private(set) var results: [DictateBenchmarkResult] = []
    private(set) var isRunning = false
    private(set) var completedModels = 0
    private(set) var setupError: String?
    private var runTask: Task<Void, Never>?

    /// Fastest typical time first among models that got every answer right, then the rest.
    var ranked: [DictateBenchmarkResult] {
        results.sorted { lhs, rhs in
            let lhsPerfect = lhs.finished && lhs.errors == 0 && lhs.failed == 0
            let rhsPerfect = rhs.finished && rhs.errors == 0 && rhs.failed == 0
            if lhsPerfect != rhsPerfect { return lhsPerfect }
            return (lhs.median ?? .infinity) < (rhs.median ?? .infinity)
        }
    }

    func run(
        refiner: LLMRefiner,
        models: [String],
        samples: [DictateBenchmarkSample] = DictateBenchmarkSample.standard,
        session: URLSession = .shared
    ) {
        guard !isRunning else { return }
        let plans = models.compactMap { model -> ModelPlan? in
            guard let warmup = refiner.dictateBenchmarkRequest(text: samples[0].raw, model: model) else { return nil }
            let requests = samples.compactMap { sample in
                refiner.dictateBenchmarkRequest(text: sample.raw, model: model).map { ($0.request, sample) }
            }
            return ModelPlan(model: model, warmup: warmup.request, provider: warmup.provider, format: warmup.format, requests: requests)
        }
        guard !plans.isEmpty else {
            setupError = "Add a language model API key (or an OpenRouter key under Recognition) first."
            return
        }
        setupError = nil
        results = plans.map { DictateBenchmarkResult(model: $0.model) }
        completedModels = 0
        isRunning = true
        let normalize: @Sendable (String) -> String = { refiner.normalizeModelOutput($0) }

        runTask = Task { [weak self] in
            for start in stride(from: 0, to: plans.count, by: Self.maxConcurrentModels) {
                let chunk = plans[start..<min(start + Self.maxConcurrentModels, plans.count)]
                await withTaskGroup(of: DictateBenchmarkResult.self) { group in
                    for plan in chunk {
                        group.addTask { await Self.runModel(plan, session: session, normalize: normalize) }
                    }
                    for await result in group {
                        self?.record(result)
                    }
                }
                if Task.isCancelled { break }
            }
            self?.isRunning = false
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    private func record(_ result: DictateBenchmarkResult) {
        guard let index = results.firstIndex(where: { $0.model == result.model }) else { return }
        var finished = result
        finished.finished = true
        results[index] = finished
        completedModels += 1
        let median = finished.median.map { Int($0 * 1_000) } ?? -1
        DebugLog.event("dictateBenchmark model=\(finished.model) medianMs=\(median) passed=\(finished.passed) failed=\(finished.failed) errors=\(finished.errors)")
    }

    private struct ModelPlan: Sendable {
        let model: String
        let warmup: URLRequest
        let provider: LLMProvider
        let format: LLMOutputFormat
        let requests: [(URLRequest, DictateBenchmarkSample)]
    }

    private enum Outcome {
        case success(seconds: Double, text: String)
        case failure(String)
    }

    nonisolated private static func runModel(
        _ plan: ModelPlan,
        session: URLSession,
        normalize: @Sendable (String) -> String
    ) async -> DictateBenchmarkResult {
        var result = DictateBenchmarkResult(model: plan.model)
        _ = await measure(plan.warmup, plan: plan, session: session, normalize: normalize)
        for (request, sample) in plan.requests {
            if Task.isCancelled { break }
            switch await measure(request, plan: plan, session: session, normalize: normalize) {
            case .success(let seconds, let text):
                result.seconds.append(seconds)
                if sample.passes(text) {
                    result.passed += 1
                } else {
                    result.failed += 1
                }
            case .failure(let message):
                result.errors += 1
                result.lastError = message
            }
        }
        return result
    }

    nonisolated private static func measure(
        _ request: URLRequest,
        plan: ModelPlan,
        session: URLSession,
        normalize: @Sendable (String) -> String
    ) async -> Outcome {
        let started = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = started.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            guard let http = response as? HTTPURLResponse else {
                return .failure("No response")
            }
            let codec = LLMProviderCodecRegistry.codec(for: plan.provider)
            guard (200..<300).contains(http.statusCode) else {
                let message = codec.classifyError(statusCode: http.statusCode, data: data).displayMessage
                let detail = message.isEmpty ? "" : ": \(message.prefix(160))"
                return .failure(LLMRefiner.configurationFailure(status: http.statusCode, message: message) ?? "HTTP \(http.statusCode)\(detail)")
            }
            let parsed = try codec.parseResponse(data: data, httpResponse: http, outputFormat: plan.format)
            return .success(seconds: seconds, text: normalize(parsed.text))
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
