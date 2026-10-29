import Foundation

/// Observed UI change is evidence, not a guarantee that a business goal succeeded.
public struct CUAActionResult: Codable, Sendable, Hashable {
    public var accepted: Bool = true
    public var changed: Bool?
    public var effect: String
    public var path: String
    public var evidence: JSONValue
    public init(changed: Bool? = nil, path: String = "unknown", evidence: JSONValue = .object([:])) {
        self.changed = changed
        self.effect = changed == true ? "observed-change" : "unverified"
        self.path = path
        self.evidence = evidence
    }
}

public struct AXParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var elementIndex: Int
    public var windowId: UInt32?
    public var attribute: String?
    public var action: String?
    public var value: JSONValue?
}

/// Pure validation shared by the AX adapter and its tests. Names come from the app,
/// not a fixed whitelist; unsupported operations must fail before mutation.
public enum AXPrimitive {
    public static func name(_ requested: String?, available: [String]) throws -> String {
        guard let requested, let name = available.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) else {
            throw CUAError(code: .unsupported, message: "Unsupported AX name: \(requested ?? "<missing>")", data: .object(["available": .array(available.sorted().map(JSONValue.string))]))
        }
        return name
    }
    public static func checkMutation(_ name: String, activate: Bool) throws {
        if !activate && ["AXRaise", "AXFrontmost", "AXMain"].contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw CUAError(code: .inputRejected, message: "\(name) requires explicit --activate")
        }
    }
    public static func changed(before: JSONValue?, after: JSONValue?) -> Bool? {
        guard let before, let after else { return nil }
        return before != after
    }
}
