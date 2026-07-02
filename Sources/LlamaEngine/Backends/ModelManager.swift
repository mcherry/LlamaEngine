import Foundation
import Observation

/// Headless controller for Ollama model management: lists installed models with their
/// loaded state, pulls new models (streaming progress), and deletes them.
///
/// Presentation binds to its `@Observable` state; the server URL is injected per call so
/// the engine holds no configuration of its own. `@MainActor` so its published state
/// updates a UI directly — only one pull runs at a time.
@MainActor
@Observable
public final class ModelManager {
    /// Installed models, name-sorted, from the last successful `reload`.
    public private(set) var models: [OllamaModel] = []
    /// Names of models currently resident in memory on the server.
    public private(set) var running: Set<String> = []
    /// True while a `reload` is in flight.
    public private(set) var isLoading = false
    /// True while a `pull` is streaming.
    public private(set) var isPulling = false
    /// Human-readable status of the active (or most recent) pull.
    public private(set) var pullStatus = ""
    /// Fraction of the active pull completed (0…1), or `nil` when indeterminate.
    public private(set) var pullFraction: Double?
    /// Set when the last action failed, for the UI to surface (and clear).
    public var errorMessage: String?

    private var pullTask: Task<Void, Never>?

    public init() {}

    /// Whether a model is currently loaded in the server's memory.
    public func isRunning(_ name: String) -> Bool {
        running.contains(name)
    }

    /// Refreshes the installed-model list and which models are loaded. Sets
    /// `errorMessage` and leaves prior results in place on failure.
    public func reload(serverURL: String) async {
        guard let client = OllamaClient(baseURLString: serverURL) else {
            errorMessage = "Invalid server URL. Check Settings."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            models = try await client.models().sorted { $0.name < $1.name }
            running = Set((try? await client.runningModels())?.map(\.name) ?? [])
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Pulls `name` from the registry, streaming progress into `pullStatus` /
    /// `pullFraction`, then reloads the list. Trims whitespace; no-ops on an empty name
    /// or invalid URL. Call `cancelPull()` to stop an in-flight pull.
    public func pull(_ name: String, serverURL: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let client = OllamaClient(baseURLString: serverURL) else { return }
        isPulling = true
        pullStatus = "Starting…"
        pullFraction = nil
        errorMessage = nil
        pullTask = Task { [weak self] in
            do {
                for try await progress in client.pullModel(trimmed) {
                    self?.pullStatus = progress.status
                    self?.pullFraction = progress.fraction
                }
                self?.pullStatus = "Done"
            } catch is CancellationError {
                self?.pullStatus = "Cancelled"
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            self?.isPulling = false
            self?.pullFraction = nil
            await self?.reload(serverURL: serverURL)
        }
    }

    /// Cancels an in-flight pull, if any.
    public func cancelPull() {
        pullTask?.cancel()
    }

    /// Deletes `name` from the server, then reloads. Sets `errorMessage` on failure.
    public func delete(_ name: String, serverURL: String) async {
        guard let client = OllamaClient(baseURLString: serverURL) else { return }
        do {
            try await client.deleteModel(name)
            await reload(serverURL: serverURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
