import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Collects tool executions during a Foundation Models turn so the persisting controller can
/// turn them into audit records afterward, without the bridged tool ever touching a SwiftData
/// `@Model`. An `actor`, so the framework's tool loop can append safely. Available on the
/// deployment target (no framework types), so only the FM-typed pieces are behind `#if`.
public actor AppleToolCollector {
    public struct Entry: Sendable {
        public let toolName: String
        public let argumentsJSON: String
        public let result: ToolResult
        public let decision: String
        public let durationSeconds: Double?
    }

    private var entries: [Entry] = []
    public init() {}
    func add(_ entry: Entry) { entries.append(entry) }
    public func drain() -> [Entry] {
        let current = entries
        entries = []
        return current
    }
}

#if canImport(FoundationModels)

/// Bridges one `AgentTool` to a Foundation Models `Tool`. Because our tools take dynamic
/// JSON, the model calls this with a single `arguments_json` string (the tool's description
/// documents the fields). The bridge decodes it, runs the SAME policy + confirmation gate as
/// the server-backend loop — the gate is the first thing `call()` does, so nothing runs until
/// the user approves — executes the tool locally, and records the outcome in the collector.
@available(macOS 26, iOS 26, *)
struct BridgedAgentTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let base: any AgentTool
    let context: ToolContext
    let collector: AppleToolCollector

    let name: String
    let description: String
    let parameters: GenerationSchema

    init(base: any AgentTool, context: ToolContext, collector: AppleToolCollector) {
        self.base = base
        self.context = context
        self.collector = collector
        self.name = base.name
        self.description = base.description
            + "\n\nCall this tool by putting its arguments as a JSON object string in the \"arguments_json\" field."
        self.parameters = GenerationSchema(
            type: GeneratedContent.self,
            description: nil,
            properties: [
                GenerationSchema.Property(name: "arguments_json",
                                          description: "A JSON object string containing this tool's arguments.",
                                          type: String.self)
            ])
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let json = (try? arguments.value(String.self, forProperty: "arguments_json")) ?? "{}"
        let parsed = (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])

        // Boundary validation, then the policy + confirmation gate — identical to the loop.
        do {
            try base.validate(parsed)
        } catch {
            return await record(parsed, .failure(error.localizedDescription), decision: "invalid", duration: nil)
        }
        switch context.policy.decide(tool: base, settings: context.settings) {
        case .deny(let reason):
            return await record(parsed, .failure(reason), decision: "denied", duration: nil)
        case .needsConfirmation:
            let request = ToolConfirmationRequest(toolName: base.name, toolDescription: base.description,
                                                  riskTier: base.riskTier, arguments: parsed)
            if (await context.confirm?(request) ?? .denied) == .denied {
                return await record(parsed, .failure("The user declined to run \(base.name)."), decision: "denied", duration: nil)
            }
        case .allow:
            break
        }

        let started = Date()
        let result = await context.registry.run(ToolCall(id: "apple", name: base.name, arguments: parsed))
        let label = base.riskTier == .pure ? "auto" : "confirmed"
        return await record(parsed, result, decision: label, duration: Date().timeIntervalSince(started))
    }

    private func record(_ arguments: JSONValue, _ result: ToolResult, decision: String, duration: Double?) async -> String {
        await collector.add(.init(toolName: base.name, argumentsJSON: arguments.jsonString,
                                  result: result, decision: decision, durationSeconds: duration))
        return result.content
    }
}

/// Runs an on-device Foundation Models turn *with tools*. Unlike the server backends, the
/// framework owns the tool loop, so this streams the assistant text and lets the bridged
/// tools gate + execute themselves; the executions land in `collector` for the controller to
/// audit afterward. Yields cumulative content snapshots (Apple's streaming semantics).
@available(macOS 26, iOS 26, *)
public enum AppleToolSession {
    public static func stream(instructions: String,
                              prompt: String,
                              tools: [any AgentTool],
                              context: ToolContext,
                              options: AppleGenerationOptions,
                              collector: AppleToolCollector) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard case .available = SystemLanguageModel.default.availability else {
                        throw AppleIntelligenceError.unavailable(AppleIntelligence.statusMessage)
                    }
                    let bridged: [any FoundationModels.Tool] = tools.map {
                        BridgedAgentTool(base: $0, context: context, collector: collector)
                    }
                    let session = LanguageModelSession(tools: bridged, instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt,
                                                                     options: FoundationModelsBackend.makeOptions(options)) {
                        try Task.checkCancellation()
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

#endif
