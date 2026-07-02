import Foundation

/// Fetches a single web page for context, hardened for a manual, user-triggered flow:
/// http/https only, a real User-Agent, a timeout, a content-type check, and a size cap.
/// There is no crawling and no model-initiated fetch — the user pastes a URL, so there's
/// no exfiltration channel (see WEB_CONTENT_PLAN.md). Returns the raw HTML for
/// `HTMLExtractor`; throws a descriptive error (including block/paywall signals) on failure.
enum WebFetcher {

    enum FetchError: LocalizedError {
        case invalidURL
        case blocked(Int)
        case http(Int)
        case notText(String)
        case tooLarge
        case empty
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "That doesn't look like a web address. Use an http or https URL."
            case .blocked(let code):
                return "The site refused the request (HTTP \(code)) — it may block automated access or require sign-in. Try opening it in a browser and pasting the text."
            case .http(let code):
                return "The page couldn't be loaded (HTTP \(code))."
            case .notText(let type):
                return "That link isn't a web page (\(type.isEmpty ? "unknown type" : type)). Only web pages and text can be added."
            case .tooLarge:
                return "That page is too large to add. Try a more specific article, or paste the text."
            case .empty:
                return "The page came back empty or in an unreadable encoding."
            case .transport(let message):
                return message
            }
        }
    }

    /// Fetches `urlString` and returns the final URL plus the page's HTML/text.
    static func fetch(_ urlString: String,
                      maxBytes: Int = 3_000_000,
                      timeout: TimeInterval = 20,
                      session: URLSession = .shared) async throws -> (url: URL, html: String) {
        guard let url = normalizedURL(urlString) else { throw FetchError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) Llamatron/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FetchError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.transport("The server didn't return a web response.")
        }
        if [401, 402, 403, 407, 429].contains(http.statusCode) {
            throw FetchError.blocked(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FetchError.http(http.statusCode)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let isTextual = contentType.isEmpty
            || contentType.contains("text/html")
            || contentType.contains("text/plain")
            || contentType.contains("xml")
            || contentType.contains("application/xhtml")
        guard isTextual else { throw FetchError.notText(contentType) }
        guard data.count <= maxBytes else { throw FetchError.tooLarge }

        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FetchError.empty
        }
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FetchError.empty }
        return (http.url ?? url, html)
    }

    /// Normalizes user input to an http/https URL with a host (defaults the scheme to
    /// https), or nil if it can't be one. Rejects everything else (file://, data:, etc.).
    static func normalizedURL(_ input: String) -> URL? {
        var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if !string.contains("://") { string = "https://" + string }
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
