import Foundation

/// Production `HTTPFetcher` over `URLSession`. Uses a 10-second request timeout to match the
/// Claude OAuth first-poll timeout (Baseline §13.3).
public struct URLSessionFetcher: HTTPFetcher {

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
        // Identify honestly (REV-14): never mimic Claude Code's UA — misrepresenting the client to
        // dodge a rate limiter risks a block and misidentifies us in Anthropic's logs.
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
