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
                                     registry: registry, into: assistant, session: session,
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
                                     registry: registry, into: assistant, session: session,
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
                                     registry: registry, into: assistant, session: session,
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
                                     registry: registry, into: assistant, session: session,
                                     rawPromptEstimate: 0, modelContext: context)

        XCTAssertEqual(assistant.content, "Sorry.")
        XCTAssertEqual(assistant.toolCallRecords.count, 1)
        XCTAssertTrue(assistant.orderedToolCallRecords.first?.isError ?? false)
    }
}
