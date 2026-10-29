import Foundation
import CUACore

/// 缺省配置偏向本机开发；生产环境应开启签名校验并配置允许列表。
struct ServiceConfiguration: Decodable, Sendable {
    var requirePeerValidation = false
    var allowedTeamIdentifiers: [String] = []
    var allowedBundleIdentifiers: [String] = []
    var allowUnsigned = true
    var allowRoot = false
    var autoAuthorizeApps = true
    var codeRequirement: String? = nil

    init() {}
    private enum CodingKeys: String, CodingKey {
        case requirePeerValidation, allowedTeamIdentifiers, allowedBundleIdentifiers
        case allowUnsigned, allowRoot, autoAuthorizeApps, codeRequirement
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requirePeerValidation = try c.decodeIfPresent(Bool.self, forKey: .requirePeerValidation) ?? false
        allowedTeamIdentifiers = try c.decodeIfPresent([String].self, forKey: .allowedTeamIdentifiers) ?? []
        allowedBundleIdentifiers = try c.decodeIfPresent([String].self, forKey: .allowedBundleIdentifiers) ?? []
        allowUnsigned = try c.decodeIfPresent(Bool.self, forKey: .allowUnsigned) ?? true
        allowRoot = try c.decodeIfPresent(Bool.self, forKey: .allowRoot) ?? false
        autoAuthorizeApps = try c.decodeIfPresent(Bool.self, forKey: .autoAuthorizeApps) ?? true
        codeRequirement = try c.decodeIfPresent(String.self, forKey: .codeRequirement)
    }
    static func load(from url: URL = CUAPaths.configPath) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try CUACodec.decode(Self.self, from: Data(contentsOf: url))
    }
}
