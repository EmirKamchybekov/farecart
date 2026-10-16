import Foundation

public enum PostgRESTDecoder {
    /// Models declare explicit snake_case `CodingKeys`, so this is a plain decoder; dates are
    /// handled per-field because `date` and `timestamptz` columns differ.
    public static func make() -> JSONDecoder {
        JSONDecoder()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try make().decode(type, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(describe(error))
        }
    }

    static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx): "missing key '\(key.stringValue)' at \(path(ctx))"
        case .typeMismatch(let type, let ctx): "type mismatch (\(type)) at \(path(ctx))"
        case .valueNotFound(let type, let ctx): "null \(type) at \(path(ctx))"
        case .dataCorrupted(let ctx): "corrupted data at \(path(ctx)): \(ctx.debugDescription)"
        @unknown default: "unknown decoding error"
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        ctx.codingPath.map(\.stringValue).joined(separator: ".")
    }
}
