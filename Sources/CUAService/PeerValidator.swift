import Foundation
import Darwin
import Security
import CUACore

struct PeerValidator: Sendable {
    struct Identity: Sendable {
        var pid: pid_t
        var uid: uid_t
        var bundleIdentifier: String?
        var teamIdentifier: String?
        var cdhash: String?
        var validSignature: Bool
        var isUnsigned = true
    }
    let configuration: ServiceConfiguration
    var bypass = false

    func validate(fd: Int32) -> Bool {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        var uid: uid_t = 0
        var gid: gid_t = 0
        let pidOK = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0
        let uidOK = getpeereid(fd, &uid, &gid) == 0
        var identity = Identity(pid: pid, uid: uid, validSignature: false)
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        let status = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(rawValue: 0), &code)
        identity.isUnsigned = status == errSecCSUnsigned
        if status == errSecSuccess, let code {
            var info: CFDictionary?
            var staticCode: SecStaticCode?
            // Swift SDK 将 kSecCSDefaultFlags 映射为零值；签名信息接口需要静态代码对象。
            if SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
               let staticCode,
               SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 0), &info) == errSecSuccess,
               let info = info as? [String: Any] {
                identity.bundleIdentifier = info[kSecCodeInfoIdentifier as String] as? String
                identity.teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
                identity.cdhash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
            }
            var requirement: SecRequirement?
            var requirementOK = true
            if let text = configuration.codeRequirement {
                requirementOK = SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess
            }
            let validity = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), requirement)
            identity.validSignature = requirementOK && validity == errSecSuccess
            identity.isUnsigned = validity == errSecCSUnsigned
        }
        let accepted = pidOK && uidOK && accepts(identity)
        // 即使禁用签名检查，也记录内核身份和签名信息；不能信任 ping 声明的 pid。
        CUALogger(CUALog.transport).info("peer pid=\(pid) uid=\(uid) bundle=\(identity.bundleIdentifier ?? "unsigned") team=\(identity.teamIdentifier ?? "none") cdhash=\(identity.cdhash ?? "none") signatureValid=\(identity.validSignature) accepted=\(accepted)")
        return accepted
    }
    func accepts(_ peer: Identity) -> Bool {
        guard peer.pid > 0 else { return false }
        guard peer.uid != 0 || configuration.allowRoot || bypass else { return false }
        if bypass || !configuration.requirePeerValidation { return true }
        if !peer.validSignature {
            // 有签名但签名无效不得降级成「允许无签名」。要求列表也不允许无签名绕过。
            return peer.isUnsigned && peer.cdhash == nil && configuration.allowUnsigned && configuration.codeRequirement == nil
                && configuration.allowedTeamIdentifiers.isEmpty && configuration.allowedBundleIdentifiers.isEmpty
        }
        if !configuration.allowedTeamIdentifiers.isEmpty,
           !configuration.allowedTeamIdentifiers.contains(peer.teamIdentifier ?? "") { return false }
        if !configuration.allowedBundleIdentifiers.isEmpty,
           !configuration.allowedBundleIdentifiers.contains(peer.bundleIdentifier ?? "") { return false }
        return true
    }
}
