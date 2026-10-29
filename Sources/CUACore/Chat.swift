import Foundation

public struct ChatParams: Codable, Sendable, Hashable {
    public var app: String
    public var name: String?
    public var chat: String?
    public var text: String?
    public var sessionId: String?
    public var limit: Int?
    public init(app: String, name: String? = nil, chat: String? = nil, text: String? = nil, limit: Int? = nil) {
        self.app = app; self.name = name; self.chat = chat; self.text = text; self.limit = limit
    }
}

public struct ChatMessage: Codable, Sendable, Hashable {
    public var sender: String?
    public var text: String
    public init(sender: String? = nil, text: String) { self.sender = sender; self.text = text }
}

public struct ChatResult: Codable, Sendable, Hashable {
    public var chat: String
    public var windowTitle: String
    public var capturedAt: String
    public var messages: [ChatMessage]
    public var evidence: [String]
    public var verified: Bool
    public init(chat: String, windowTitle: String, messages: [ChatMessage], evidence: [String], verified: Bool = true) {
        self.chat = chat; self.windowTitle = windowTitle; self.messages = messages; self.evidence = evidence
        self.capturedAt = ISO8601DateFormatter().string(from: Date()); self.verified = verified
    }
}

/// Pure fail-closed policy. Names alone cannot establish identity, so send also
/// requires an exact composer title in the same window as the message list.
public enum ChatSafety {
    public static let allowedSelfChats: Set<String> = ["文件传输助手", "knight"]
    public static func validateSend(chat: String, title: String) throws {
        guard allowedSelfChats.contains(chat), title == chat else {
            throw CUAError(code: .inputRejected, message: "Sending requires an allowed self-chat and an exact composer title (文件传输助手 / knight)")
        }
    }
    public static func matchingRow(_ labels: [String], name: String) throws -> Int {
        let matches = labels.indices.filter { labels[$0].components(separatedBy: "\n").first == name }
        guard matches.count == 1, let index = matches.first else {
            throw CUAError(code: .elementNotFound, message: "Expected one exact chat result, found \(matches.count)")
        }
        return index
    }
    public static func verifiedSend(before: [String], after: [String], text: String, composer: String) -> Bool {
        composer.isEmpty && after.filter { $0 == text }.count > before.filter { $0 == text }.count
    }
}
