import Foundation
import Hummingbird
import NIOCore
import NIOFoundationCompat

extension JSONEncoder {
    /// Sorted keys so responses read the same every time; ISO 8601 dates.
    static var whatFeature: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var whatFeature: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension DecodingError {
    /// A short, client-safe description. Never includes context values.
    var summary: String {
        switch self {
        case .keyNotFound(let key, let context):
            "Missing '\((context.codingPath + [key]).dotPath)'"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.codingPath.isEmpty
                ? context.debugDescription
                : "'\(context.codingPath.dotPath)': \(context.debugDescription)"
        @unknown default:
            "Invalid request"
        }
    }
}

extension [any CodingKey] {
    var dotPath: String { map(\.stringValue).joined(separator: ".") }
}

extension Response {
    static func json(
        _ value: some Encodable,
        status: HTTPResponse.Status,
        headers: HTTPFields = [:]
    ) throws -> Response {
        var headers = headers
        headers[.contentType] = "application/json"
        let data = try JSONEncoder.whatFeature.encode(value)
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(data: data)))
    }
}
