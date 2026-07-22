import XCTest
import SwiftData
import LlamaEngine
@testable import LlamaEngineStore

/// A canned `ChatStreaming` backend: each `chat(_:)` call returns the next scripted round
/// of chunks, so the agent loop can be exercised deterministically with no server.
private final class StubToolBackend: ChatStreaming, @unchecked Sendable {
    private var rounds: [[ChatChunk]]
    private var index = 0
    private let lock = NSLock()

    init(_ rounds: [[ChatChunk]]) { self.rounds = rounds }

    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        lock.lock()
        let chunks = index < rounds.count ? rounds[index] : []
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

@MainActor
final class ToolLoopTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema(LlamaEngineStore.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    /// Builds a session (title auto-naming off so the loop doesn't call the stub again) and an
    /// empty assistant turn, both inserted into a fresh in-memory context.
    private func fixture() throws -> (ModelContext, ChatSession, ChatMessage) {
        let context = try makeContext()
        let session = ChatSession(modelName: "qwen")
        session.titleIsAuto = false
        context.insert(session)
        let assistant = ChatMessage(role: .assistant, content: "")
        assistant.session = session
        context.insert(assistant)
        return (context, session, assistant)
    }

    /// A tool context with tools enabled and every tool in the registry allow-listed, so a
    /// `pure` tool auto-runs (the common case for the loop mechanics tests).
    private func enabledContext(_ registry: ToolRegistry,
                                confirm: ToolConfirmationHandler? = nil) -> ToolContext {
        ToolContext(registry: registry,
                    settings: SessionToolSettings(enabled: true,
                                                  allowedTools: Set(registry.tools.map(\.name))),
                    confirm: confirm)
    }

    func testToolLoopExecutesToolThenAnswers() async throws {
        let (context, session, assistant) = try fixture()
        let registry = ToolRegistry(tools: [CurrentDateTimeTool()])
        let toolDelta = ToolCallDelta(index: 0, id: "c1", name: "current_datetime",
                                      argumentsFragment: #"{"timezone":"UTC"}"#)
        let backend = StubToolBackend([
            [ChatChunk(contentDelta: "", done: true, toolCallDeltas: [toolDelta])],  // round 0: call tool
            [ChatChunk(contentDelta: "The current time.", done: true)]               // round 1: answer
        ])
        let base = ChatRequest(model: "qwen",
                               messages: [ChatTurn(role: "user", content: "what time is it?")],
                               contextSize: 4096, tools: registry.specs)

        let controller = ConversationController()
        await controller.runToolLoop(backend: backend, baseRequest: base, baseTurns: base.messages,
                                     context: enabledContext(registry), into: assistant, session: session,
                                     rawPromptEstimate: 0, modelContext: context)

        XCTAssertEqual(assistant.content, "The current time.")
        XCTAssertEqual(assistant.toolCallRecords.count, 1)
        let record = try XCTUnwrap(assistant.orderedToolCallRecords.first)
        XCTAssertEqual(record.toolName, "current_datetime")
        XCTAssertFalse(record.isError)
        XCTAssertTrue(record.result.contains("UTC"))
        XCTAssertFalse(controller.isStreaming)
    }

    func testToolLoopWithNoToolCallsAnswersDirectly() async throws {
        let (context, session, assistant) = try fixture()
        let registry = ToolRegistry(tools: [CurrentDateTimeTool()])
        let backend = StubToolBackend([[ChatChunk(contentDelta: "Hello!", done: true)]])
        let base = ChatRequest(model: "qwen", messages: [ChatTurn(role: "user", content: "hi")],
                               contextSize: 4096, tools: registry.specs)

        let controller = ConversationController()
        await controller.runToolLoop(backend: backend, baseRequest: base, baseTurns: base.messages,
                                     context: enabledContext(registry), into: assistant, session: session,
                                     rawPromptEstimate: 0, modelContext: context)

        XCTAssertEqual(assistant.content, "Hello!")
        XCTAssertTrue(assistant.toolCallRecords.isEmpty)
    }

    func testToolLoopStopsAtMaxIterations() async throws {
        let (context, session, assistant) = try fixture()
        let registry = ToolRegistry(tools: [CurrentDateTimeTool()], maxIterations: 2)
        let toolRound: [ChatChunk] = [ChatChunk(contentDelta: "", done: true,
            toolCallDeltas: [ToolCallDelta(index: 0, id: "c", name: "current_datetime", argumentsFragment: "{}")])]
        let finalRound: [ChatChunk] = [ChatChunk(contentDelta: "Final.", done: true)]
        // A model that never stops calling: rounds 0 and 1 request the tool; round 2 has tools
        // withdrawn, so it must answer.
        let backend = StubToolBackend([toolRound, toolRound, finalRound])
        let base = ChatRequest(model: "qwen", messages: [ChatTurn(role: "user", content: "loop")],
                               contextSize: 4096, tools: registry.specs)

        let controller = ConversationController()
        await controller.runToolLoop(backend: backend, baseRequest: base, baseTurns: base.messages,
                                     context: enabledContext(registry), into: assistant, session: session,
                                     rawPromptEstimate: 0, modelContext: context)

        XCTAssertEqual(assistant.toolCallRecords.count, 2)   // capped at maxIterations
        XCTAssertEqual(assistant.content, "Final.")
    }

    func testToolLoopUnknownToolFeedsBackErrorAndContinues() async throws {
        let (context, session, assistant) = try fixture()
        let registry = ToolRegistry(tools: [CurrentDateTimeTool()])
        let backend = StubToolBackend([
            [ChatChunk(contentDelta: "", done: true,
                       toolCallDeltas: [ToolCallDelta(index: 0, id: "c1", name: "does_not_exist", argumentsFragment: "{}")])],
            [ChatChunk(contentDelta: "Sorry.", done: true)]
        ])
        let base = ChatRequest(model: "qwen", messages: [ChatTurn(role: "user", content: "x")],
                               contextSize: 4096, tools: registry.specs)

        let controller = ConversationController()
        await controller.runToolLoop(backend: backend, baseRequest: base, baseTurns: base.messages,
                                     context: enabledContext(registry), into: assistant, session: session,
                                     rawPromptEstimate: 0, modelContext: context)

        XCTAssertEqual(assistant.content, "Sorry.")
        XCTAssertEqual(assistant.toolCallRecords.count, 1)
        XCTAssertTrue(assistant.orderedToolCallRecords.first?.isError ?? false)
    }

    func testConfirmedHigherTierToolRunsAndRecordsConfirmed() async throws {
        let (context, session, assistant) = try fixture()
        let tool = RecordingTool(tier: .network)
        let registry = ToolRegistry(tools: [tool])
        let spy = ConfirmSpy(.approvedOnce)
        let backend = StubToolBackend([
            [ChatChunk(contentDelta: "", done: true,
                       toolCallDeltas: [ToolCallDelta(index: 0, id: "c1", name: "stub_tool", argumentsFragment: "{}")])],
            [ChatChunk(contentDelta: "Done.", done: true)]
        ])
        let base = ChatRequest(model: "qwen", messages: [ChatTurn(role: "user", content: "go")], contextSize: 4096)
        let toolCtx = ToolContext(registry: registry,
                                  settings: SessionToolSettings(enabled: true, allowedTools: ["stub_tool"]),
                                  confirm: spy.handler)

        let controller = ConversationController()
        await controller.runToolLoop(backend: backend, baseRequest: base, baseTurns: base.messages,
                                     context: toolCtx, into: assistant, session: session,
                                     rawPromptEstimate: 0, modelContext: context)

        XCTAssertEqual(spy.count, 1)          // a network tool was confirmed
        XCTAssertTrue(tool.executed)
        XCTAssertEqual(assistant.content, "Done.")
        let record = try XCTUnwrap(assistant.orderedToolCallRecords.first)
        XCTAssertEqual(record.decision, "confirmed")
        XCTAssertFalse(record.isError)
    }

    func testDeniedToolDoesNotRun() async throws {
        let (context, session, assistant) = try fixture()
        let tool = RecordingTool(tier: .network)
        let registry = ToolRegistry(tools: [tool])
        let spy = ConfirmSpy(.denied)
        let backend = StubToolBackend([
            [ChatChunk(contentDelta: "", done: true,
                       toolCallDeltas: [ToolCallDelta(index: 0, id: "c1", name: "stub_tool", argumentsFragment: "{}")])],
            [ChatChunk(contentDelta: "Okay.", done: true)]
        ])
        let base = ChatRequest(model: "qwen", messages: [ChatTurn(role: "user", content: "go")], contextSize: 4096)
        let toolCtx = ToolContext(registry: registry,
                                  settings: SessionToolSettings(enabled: true, allowedTools: ["stub_tool"]),
                                  confirm: spy.handler)

        let controller = ConversationController()
        await controller.runToolLoop(backend: backend, baseRequest: base, baseTurns: base.messages,
                                     context: toolCtx, into: assistant, session: session,
                                     rawPromptEstimate: 0, modelContext: context)

        XCTAssertEqual(spy.count, 1)          // asked, and the user declined
        XCTAssertFalse(tool.executed)
        let record = try XCTUnwrap(assistant.orderedToolCallRecords.first)
        XCTAssertEqual(record.decision, "denied")
        XCTAssertTrue(record.isError)
    }

    func testNotAllowListedToolIsDeniedWithoutConfirming() async throws {
        let (context, session, assistant) = try fixture()
        let tool = RecordingTool(tier: .network)
        let registry = ToolRegistry(tools: [tool])
        let spy = ConfirmSpy(.approvedOnce)
        let backend = StubToolBackend([
            [ChatChunk(contentDelta: "", done: true,
                       toolCallDeltas: [ToolCallDelta(index: 0, id: "c1", name: "stub_tool", argumentsFragment: "{}")])],
            [ChatChunk(contentDelta: "Okay.", done: true)]
        ])
        let base = ChatRequest(model: "qwen", messages: [ChatTurn(role: "user", content: "go")], contextSize: 4096)
        // Tools enabled, but this tool is NOT allow-listed → policy denies without confirming.
        let toolCtx = ToolContext(registry: registry,
                                  settings: SessionToolSettings(enabled: true, allowedTools: []),
                                  confirm: spy.handler)

        let controller = ConversationController()
        await controller.runToolLoop(backend: backend, baseRequest: base, baseTurns: base.messages,
                                     context: toolCtx, into: assistant, session: session,
                                     rawPromptEstimate: 0, modelContext: context)

        XCTAssertEqual(spy.count, 0)          // never even asked
        XCTAssertFalse(tool.executed)
        let record = try XCTUnwrap(assistant.orderedToolCallRecords.first)
        XCTAssertEqual(record.decision, "denied")
    }
}

/// A stub tool with a configurable risk tier that records whether it actually executed.
private final class RecordingTool: AgentTool, @unchecked Sendable {
    let name: String
    let description = "A stub tool for tests."
    let parameters = JSONSchema.empty
    let riskTier: ToolRiskTier
    private let lock = NSLock()
    private var didExecute = false
    var executed: Bool { lock.withLock { didExecute } }

    init(name: String = "stub_tool", tier: ToolRiskTier) {
        self.name = name
        self.riskTier = tier
    }

    func validate(_ arguments: JSONValue) throws {}
    func execute(_ arguments: JSONValue) async throws -> ToolResult {
        lock.withLock { didExecute = true }
        return ToolResult(content: "ran")
    }
}

/// A confirmation handler that returns a fixed outcome and counts how many times it was asked.
private final class ConfirmSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let outcome: ToolConfirmationOutcome

    init(_ outcome: ToolConfirmationOutcome) { self.outcome = outcome }

    var count: Int { lock.withLock { calls } }

    var handler: ToolConfirmationHandler {
        { [self] _ in
            lock.withLock { calls += 1 }
            return outcome
        }
    }
}
