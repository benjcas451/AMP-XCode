import Foundation
import os

final class URLSessionTransport: HTTPTransport {
    /// One session for all clients. It keeps no cookies, cache or credentials,
    /// so nothing leaks from one set of settings to the next.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private let closed = OSAllocatedUnfairLock(initialState: false)

    func post(_ url: URL, body: Data) async throws -> HTTPResponse {
        if closed.withLock({ $0 }) {
            throw TransportError.failed("Die Verbindung wurde geschlossen.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HTTPResponse(statusCode: status, body: data)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw TransportError.timedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TransportError.failed(error.localizedDescription)
        }
    }

    func close() {
        closed.withLock { $0 = true }
    }
}
