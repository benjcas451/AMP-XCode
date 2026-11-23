import Foundation

struct HTTPResponse: Sendable {
    var statusCode: Int
    var body: Data
}

enum TransportError: Error {
    case timedOut
    case failed(String)
}

/// Sends the JSON POST requests of `AMPClient`. Tests substitute a fake AMP.
protocol HTTPTransport: Sendable {
    /// Throws `TransportError`, or `CancellationError` when the calling task
    /// was cancelled.
    func post(_ url: URL, body: Data) async throws -> HTTPResponse

    /// Fails all later requests.
    func close()
}
