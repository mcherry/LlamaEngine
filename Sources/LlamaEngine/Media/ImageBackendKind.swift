import Foundation

/// Which local image-generation server to talk to. **Developer-extensible only** — add a case (and
/// a matching `ImageProvider`) to support a new backend; this is not user-configurable. Stored as a
/// raw string in settings, like the LLM `BackendKind`.
public enum ImageBackendKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case easyDiffusion
    case comfyUI

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .easyDiffusion: return "Easy Diffusion"
        case .comfyUI: return "ComfyUI"
        }
    }

    /// Builds the provider for this backend pointed at `baseURLString`. The ComfyUI provider is
    /// built without a template (enough for a connection test and model listing); to *generate*,
    /// construct `ComfyUIProvider(baseURLString:template:)` directly with the selected template.
    public func makeProvider(baseURLString: String) -> ImageProvider {
        switch self {
        case .easyDiffusion: return EasyDiffusionProvider(baseURLString: baseURLString)
        case .comfyUI: return ComfyUIProvider(baseURLString: baseURLString)
        }
    }
}
