import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Thin seam over URLSession so the client can be tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }
}

public enum APIError: Error, Sendable {
    case invalidResponse
    case httpStatus(Int, body: String)
    case decoding(String)

    public var isOffline: Bool {
        false
    }
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server sent an unexpected response."
        case .httpStatus(let code, let body): "Server error \(code). \(body.prefix(200))"
        case .decoding(let message): "Could not read the server's data. \(message)"
        }
    }
}
