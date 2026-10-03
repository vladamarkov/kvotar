import Foundation

/// Minimal HTTP GET seam over the direct `wham/usage` endpoint (Baseline §8.2). Injected so tests
/// can return fixture bodies with chosen status codes and headers, with no real network — the
/// same pattern as Claude's `HTTPFetcher` (ClaudeAdapter/Seams.swift), duplicated here because
/// `CodexAdapter` cannot import `ClaudeAdapter` (ARCHITECTURE.md §SPM package dependency graph).
public protocol CodexHTTPFetcher: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
}

/// Production `CodexHTTPFetcher` over `URLSession`. 10-second request timeout — the wham/usage
/// fallback budget (Baseline §13.3 Timeout chain: "Codex wham/usage fallback — 10s").
public struct CodexURLSessionFetcher: CodexHTTPFetcher {

    private let session: URLSession

    public init(timeout: TimeInterval = 10) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Identify honestly (REV-14): never mimic another client to dodge a rate limiter.
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    /// `Kvotar/<version>` from the host app bundle (`CFBundleShortVersionString`).
    private static let userAgent =
        "Kvotar/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")"
}
