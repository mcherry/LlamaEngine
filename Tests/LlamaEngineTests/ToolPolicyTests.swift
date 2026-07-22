import XCTest
@testable import LlamaEngine

final class ToolPolicyTests: XCTestCase {

    /// A minimal tool whose only meaningful trait is its risk tier.
    private struct StubTool: AgentTool {
        let name = "t"
        let description = "stub"
        let parameters = JSONSchema.empty
        let riskTier: ToolRiskTier
        func validate(_ arguments: JSONValue) throws {}
        func execute(_ arguments: JSONValue) async throws -> ToolResult { ToolResult(content: "") }
    }

    private let policy = ToolPolicy()

    private func decide(_ tier: ToolRiskTier, _ settings: SessionToolSettings) -> ToolDecision {
        policy.decide(tool: StubTool(riskTier: tier), settings: settings)
    }

    private func on(_ extra: (inout SessionToolSettings) -> Void = { _ in }) -> SessionToolSettings {
        var settings = SessionToolSettings(enabled: true, allowedTools: ["t"])
        extra(&settings)
        return settings
    }

    func testDisabledDeniesEverything() {
        XCTAssertEqual(decide(.pure, SessionToolSettings(enabled: false, allowedTools: ["t"])),
                       .deny(reason: "Tools are off for this chat."))
    }

    func testNotAllowListedIsDenied() {
        XCTAssertEqual(decide(.pure, SessionToolSettings(enabled: true, allowedTools: [])),
                       .deny(reason: "t is not enabled for this chat."))
    }

    func testPureAutoRuns() {
        XCTAssertEqual(decide(.pure, on()), .allow)
    }

    func testReadLocalConfirmsByDefault() {
        XCTAssertEqual(decide(.readLocal, on()), .needsConfirmation)
    }

    func testReadLocalCanAutoRunWhenConfigured() {
        XCTAssertEqual(decide(.readLocal, on { $0.confirmReadLocal = false }), .allow)
    }

    func testNetworkAlwaysConfirms() {
        XCTAssertEqual(decide(.network, on()), .needsConfirmation)
        XCTAssertEqual(decide(.network, on { $0.confirmReadLocal = false }), .needsConfirmation)
    }

    func testMutatingAlwaysConfirms() {
        XCTAssertEqual(decide(.mutating, on()), .needsConfirmation)
    }

    func testApprovedForSessionAllowsWithoutConfirm() {
        XCTAssertEqual(decide(.network, on { $0.approvedForSession = ["t"] }), .allow)
        XCTAssertEqual(decide(.mutating, on { $0.approvedForSession = ["t"] }), .allow)
    }

    func testActiveSpecsAdvertiseOnlyAllowListedTools() {
        let registry = ToolRegistry(tools: [CurrentDateTimeTool()])
        let enabled = ToolContext(registry: registry,
                                  settings: SessionToolSettings(enabled: true, allowedTools: ["current_datetime"]))
        XCTAssertEqual(enabled.activeSpecs.map(\.name), ["current_datetime"])
        XCTAssertTrue(enabled.isActive)

        let notListed = ToolContext(registry: registry,
                                    settings: SessionToolSettings(enabled: true, allowedTools: []))
        XCTAssertTrue(notListed.activeSpecs.isEmpty)
        XCTAssertFalse(notListed.isActive)

        let off = ToolContext(registry: registry,
                              settings: SessionToolSettings(enabled: false, allowedTools: ["current_datetime"]))
        XCTAssertTrue(off.activeSpecs.isEmpty)
        XCTAssertFalse(off.isActive)
    }

    func testConfirmationRequestPrettyPrintsArguments() {
        let request = ToolConfirmationRequest(toolName: "get_weather", toolDescription: "d",
                                              riskTier: .network,
                                              arguments: .object(["city": .string("Paris")]))
        XCTAssertTrue(request.argumentsJSON.contains("Paris"))
        XCTAssertTrue(request.argumentsJSON.contains("\n"))   // pretty-printed = multi-line
    }
}
