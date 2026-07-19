import Foundation

/// One image to describe: a plain `Sendable` value (base64 + a name), so it can cross
/// actor boundaries without touching a SwiftData `@Model`.
public struct VisionImage: Sendable {
    public let id: UUID
    public let name: String
    public let base64: String

    public init(id: UUID, name: String, base64: String) {
        self.id = id
        self.name = name
        self.base64 = base64
    }
}

/// The result of describing one image. `Sendable`, cached back onto the attachment.
public struct VisionDescription: Sendable {
    public let id: UUID
    public let name: String
    public let description: String

    public init(id: UUID, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// Runs the "eyes" step of a multi-model session: sends an image to a vision model and
/// returns its text description, which the primary model then reasons over. A small
/// `Sendable` helper around a chat backend with an image-bearing turn.
public struct VisionExtractor: Sendable {
    public var client: any ChatStreaming
    public var visionModel: String

    public init(client: any ChatStreaming, visionModel: String) {
        self.client = client
        self.visionModel = visionModel
    }

    /// Describes `images` one at a time, returning the descriptions in input order.
    /// Failures yield a short error placeholder rather than throwing, so one bad image
    /// doesn't sink the whole send.
    public func describe(_ images: [VisionImage], userPrompt: String) async -> [VisionDescription] {
        var results: [VisionDescription] = []
        for image in images {
            let text = await describeOne(image, userPrompt: userPrompt)
            results.append(VisionDescription(id: image.id, name: image.name, description: text))
        }
        return results
    }

    private func describeOne(_ image: VisionImage, userPrompt: String) async -> String {
        let instruction = """
        Describe this image in thorough detail so someone who cannot see it could \
        answer questions about it. Transcribe any visible text exactly, and note \
        layout, objects, people, colors, and anything notable. The user's question is: \
        "\(userPrompt)". Focus your description on what's relevant to it, but don't omit \
        other important details.
        """
        let request = ChatRequest(
            model: visionModel,
            messages: [ChatTurn(role: Role.user.rawValue, content: instruction, images: [image.base64])],
            contextSize: 4096,
            stream: false,
            think: false
        )
        do {
            var out = ""
            for try await chunk in client.chat(request) { out += chunk.contentDelta }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "(the vision model returned no description)" : trimmed
        } catch {
            return "(couldn't describe \(image.name): \(error.localizedDescription))"
        }
    }
}
