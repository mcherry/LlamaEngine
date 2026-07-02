import Foundation

/// Minimal, dependency-free reachability check for the Ollama server, used by the
/// first-run setup and Settings. The full networking layer (`OllamaClient`) arrives
/// in a later phase; this only needs to confirm the server answers.
public enum ServerProbe {
    public enum Outcome: Sendable {
        case success(version: String)
        case failure(reason: String)
    }

    public static func checkVersion(baseURL: String) async -> Outcome {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = URL(string: trimmed) else {
            return .failure(reason: "That doesn't look like a valid URL.")
        }
        let url = root.appending(path: "api/version")
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(reason: "No response from the server.")
            }
            guard http.statusCode == 200 else {
                return .failure(reason: "Server returned HTTP \(http.statusCode).")
            }
            let version = (try? JSONDecoder().decode([String: String].self, from: data))?["version"]
            return .success(version: version ?? "unknown")
        } catch {
            return .failure(reason: error.localizedDescription)
        }
    }
}
