import Foundation

/// An event property value: a string (up to 512 characters), a number, a
/// boolean or `null`, the same types the ingest API accepts.
///
///     Appeeky.track("export", properties: ["format": "pdf", "pages": 3, "shared": true])
public enum PropValue: Sendable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
}

/// Event properties: up to 64-character keys and ``PropValue`` values.
public typealias Properties = [String: PropValue]

extension PropValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension PropValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension PropValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension PropValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension PropValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension PropValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        // JSON has no NaN or Infinity; send null like JSON.stringify does.
        case .double(let value): value.isFinite ? try container.encode(value) : try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension String {
    /// The longest prefix that is at most `max` UTF-16 code units long, without
    /// splitting a character. The server counts string lengths in UTF-16 units.
    func prefixUTF16(_ max: Int) -> String {
        if utf16.count <= max { return self }
        var used = 0
        var end = startIndex
        for index in indices {
            let width = self[index].utf16.count
            if used + width > max { break }
            used += width
            end = self.index(after: index)
        }
        return String(self[startIndex..<end])
    }
}

/// Keys up to 64 characters, string values up to 512, like the React Native SDK.
func cleanProps(_ props: Properties?) -> Properties? {
    guard let props, !props.isEmpty else { return nil }
    var out: Properties = [:]
    for (key, value) in props {
        if case .string(let text) = value {
            out[key.prefixUTF16(64)] = .string(text.prefixUTF16(512))
        } else if case .double(let number) = value, !number.isFinite {
            out[key.prefixUTF16(64)] = .null
        } else {
            out[key.prefixUTF16(64)] = value
        }
    }
    return out.isEmpty ? nil : out
}
