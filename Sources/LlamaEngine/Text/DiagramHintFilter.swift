import Foundation

/// Removes redundant "paste this into an online Mermaid editor" boilerplate that some
/// models append next to a diagram. Because Llamatron renders ` ```mermaid ` blocks
/// inline, that hint is pointless and looks out of place.
///
/// This is a **display-only** filter: it operates on parsed `MarkdownBlock`s for
/// rendering. The underlying message text is never modified, so copy, export, and the
/// request/turn inspector still show exactly what the model produced.
///
/// Pure and synchronous, so it is unit-tested. It only acts when the message actually
/// contains a Mermaid block, and only strips paragraphs that clearly reference a
/// Mermaid live editor.
public enum DiagramHintFilter {
    /// Returns `blocks` with editor-hint paragraphs removed, but only when a Mermaid
    /// code block is present (otherwise the input is returned unchanged).
    public static func removeEditorHints(from blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        guard blocks.contains(where: isMermaid) else { return blocks }
        return blocks.filter { block in
            if case .paragraph(let text) = block, isEditorHint(text) { return false }
            return true
        }
    }

    private static func isMermaid(_ block: MarkdownBlock) -> Bool {
        if case .codeBlock(let language, _) = block {
            return language?.lowercased() == "mermaid"
        }
        return false
    }

    /// Whether a paragraph is a "use the Mermaid live editor" hint.
    static func isEditorHint(_ text: String) -> Bool {
        let lower = text.lowercased()
        // A link to a known Mermaid live editor is an unambiguous signal.
        if lower.contains("mermaid.live") || lower.contains("mermaid-live-editor") {
            return true
        }
        // Otherwise require the "live editor" phrasing tied to a copy/paste/diagram cue.
        if lower.contains("live editor"),
           lower.contains("mermaid") || lower.contains("diagram")
            || lower.contains("paste") || lower.contains("copy") {
            return true
        }
        // "(copy and) paste this into ... editor/viewer/renderer" style hints.
        if (lower.contains("paste") || lower.contains("copy")),
           lower.contains("editor") || lower.contains("viewer") || lower.contains("renderer"),
           lower.contains("mermaid") || lower.contains("diagram") {
            return true
        }
        return false
    }
}
