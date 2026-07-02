import XCTest
import SwiftData
@testable import LlamaEngineStore

/// Phase 0 spike: prove a package-defined `@Model` registers in a `ModelContainer`
/// (built from `LlamaEngineStore.models`) and round-trips through save/fetch, all in an
/// in-memory store so the test is hermetic.
final class SpikeNoteTests: XCTestCase {

    @MainActor
    func testPackageModelPersistsInInMemoryContainer() throws {
        let schema = Schema(LlamaEngineStore.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        context.insert(SpikeNote(text: "hello engine"))
        try context.save()

        let notes = try context.fetch(FetchDescriptor<SpikeNote>())
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "hello engine")
    }

    @MainActor
    func testSchemaListsTheSpikeModel() {
        XCTAssertTrue(LlamaEngineStore.models.contains { $0 == SpikeNote.self })
    }
}
