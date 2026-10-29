import Foundation

// MARK: - Arbitrary JSON

/// A type-erased JSON value, used for transport envelopes, error payloads and
/// pass-through MCP arguments.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

// MARK: - Error domain

/// Wire error codes. `-32xxx` codes follow JSON-RPC 2.0; `1xxx` codes are the
/// service domain and carry actionable data for clients.
public enum CUAErrorCode: Int, Codable, Sendable, CaseIterable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603

    case permissionMissing = 1001
    case appNotAuthorized = 1002
    case appNotFound = 1003
    case appNotRunning = 1004
    case elementIndexStale = 1005
    case elementNotFound = 1006
    case timeout = 1007
    case unsupported = 1008
    case sessionNotFound = 1009
    case clientRejected = 1010
    case captureFailed = 1011
    case inputRejected = 1012

    public var isTransportLevel: Bool { rawValue < 0 }
}

/// The single error type crossing every layer of SwiftCUA.
public struct CUAError: Error, Codable, Sendable, Hashable, CustomStringConvertible {
    public var code: CUAErrorCode
    public var message: String
    public var data: JSONValue?

    public init(code: CUAErrorCode, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var description: String { "\(code) \(message)" }

    public static func invalidParams(_ message: String, method: String) -> CUAError {
        CUAError(code: .invalidParams, message: "\(method): \(message)")
    }

    public static func permissionMissing(_ which: String) -> CUAError {
        CUAError(
            code: .permissionMissing,
            message: "Missing macOS permission: \(which)",
            data: .object(["permission": .string(which)])
        )
    }

    public static func appNotAuthorized(_ app: String) -> CUAError {
        CUAError(
            code: .appNotAuthorized,
            message: "App '\(app)' is not authorized for this session",
            data: .object(["app": .string(app)])
        )
    }
}

extension CUAError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - Framing

/// Length-prefixed JSON framing, mirroring the original service: a 4-byte
/// little-endian UInt32 payload length followed by UTF-8 JSON, capped at 8 MiB.
public enum CUAFraming {
    public static let maxMessageBytes = 8 * 1024 * 1024
    public static let headerBytes = 4

    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    public static func encodeJSON<T: Encodable>(_ value: T, using encoder: JSONEncoder) throws -> Data {
        encode(try encoder.encode(value))
    }
}

/// Incremental decoder that tolerates arbitrary chunk boundaries.
public struct CUAStreamDecoder: Sendable {
    private var buffer = Data()
    private let maxMessageBytes: Int

    public init(maxMessageBytes: Int = CUAFraming.maxMessageBytes) {
        self.maxMessageBytes = maxMessageBytes
    }

    /// Appends bytes and returns every complete payload now available.
    public mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var out: [Data] = []
        while buffer.count >= CUAFraming.headerBytes {
            let length = buffer.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
            }
            let payloadLength = Int(UInt32(littleEndian: length))
            guard payloadLength <= maxMessageBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw CUAError(
                    code: .invalidRequest,
                    message: "Frame length \(payloadLength) exceeds \(maxMessageBytes) byte cap"
                )
            }
            let total = CUAFraming.headerBytes + payloadLength
            guard buffer.count >= total else { break }
            let start = buffer.index(buffer.startIndex, offsetBy: CUAFraming.headerBytes)
            let end = buffer.index(start, offsetBy: payloadLength)
            out.append(Data(buffer[start..<end]))
            buffer.removeSubrange(buffer.startIndex..<end)
        }
        return out
    }

    public var bufferedByteCount: Int { buffer.count }
}
