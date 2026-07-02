import XCTest
@testable import LlamaEngine

final class DiagramHintFilterTests: XCTestCase {

    private func blocks(_ md: String) -> [MarkdownBlock] {
        MarkdownParser.parse(md)
    }

    func testRemovesLiveEditorHintAfterDiagram() {
        let md = """
        Here is a diagram:

        ```mermaid
        graph TD
        A --> B
        ```

        Copy and paste this into an online mermaid live editor, like the following one:

        https://mermaid-js.github.io/mermaid-live-editor/
        """
        let filtered = DiagramHintFilter.removeEditorHints(from: blocks(md))
        // The intro paragraph and the diagram survive; both hint paragraphs are gone.
        XCTAssertTrue(filtered.contains(where: {
            if case .paragraph(let t) = $0 { return t == "Here is a diagram:" }
            return false
        }))
        XCTAssertTrue(filtered.contains(where: {
            if case .codeBlock(let lang, _) = $0 { return lang == "mermaid" }
            return false
        }))
        XCTAssertFalse(filtered.contains(where: {
            if case .paragraph(let t) = $0 { return DiagramHintFilter.isEditorHint(t) }
            return false
        }))
    }

    func testNoMermaidBlockLeavesHintAlone() {
        // Without a mermaid block, don't touch anything (nothing rendered inline).
        let md = "Try the mermaid live editor at https://mermaid.live to draw it."
        let original = blocks(md)
        XCTAssertEqual(DiagramHintFilter.removeEditorHints(from: original), original)
    }

    func testKeepsNormalProseAroundDiagram() {
        let md = """
        ```mermaid
        graph TD
        A --> B
        ```

        This flow shows how A leads to B in the login sequence.
        """
        let filtered = DiagramHintFilter.removeEditorHints(from: blocks(md))
        XCTAssertTrue(filtered.contains(where: {
            if case .paragraph(let t) = $0 {
                return t == "This flow shows how A leads to B in the login sequence."
            }
            return false
        }))
    }

    // MARK: - isEditorHint

    func testHintDetectionPositiveCases() {
        XCTAssertTrue(DiagramHintFilter.isEditorHint(
            "Copy and paste this into an online mermaid live editor, like the following one:"))
        XCTAssertTrue(DiagramHintFilter.isEditorHint("See https://mermaid.live for a preview."))
        XCTAssertTrue(DiagramHintFilter.isEditorHint(
            "Paste the diagram into the Mermaid editor to view it."))
        XCTAssertTrue(DiagramHintFilter.isEditorHint(
            "You can open this in the live editor at mermaid-js.github.io/mermaid-live-editor/"))
    }

    func testHintDetectionNegativeCases() {
        XCTAssertFalse(DiagramHintFilter.isEditorHint("The diagram shows the request flow."))
        XCTAssertFalse(DiagramHintFilter.isEditorHint("A code editor like VS Code works well."))
        XCTAssertFalse(DiagramHintFilter.isEditorHint("Mermaid is a diagramming tool."))
    }
}
