import Foundation
import Darwin
import CUACore
import CUAEngine

struct ServiceOptions {
    var socketPath: String?
    var home: String?
    var bypassPeer = false
    var requirePeer = false
    var autoAuthorize: Bool?
    var printSocket = false
    var version = false

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else { throw CUAError(code: .invalidParams, message: "Missing value for \(argument)") }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--socket": socketPath = try value()
            case "--home": home = try value()
            case "--foreground": break
            case "--no-peer-check": bypassPeer = true
            case "--require-peer": requirePeer = true
            case "--auto-authorize":
                let raw = try value()
                guard raw == "true" || raw == "false" else { throw CUAError(code: .invalidParams, message: "--auto-authorize expects true or false") }
                autoAuthorize = raw == "true"
            case "--print-socket": printSocket = true
            case "--version": version = true
            default: throw CUAError(code: .invalidParams, message: "Unknown option: \(argument)")
            }
            index += 1
        }
        guard !(bypassPeer && requirePeer) else { throw CUAError(code: .invalidParams, message: "--no-peer-check conflicts with --require-peer") }
    }
}

@main
struct ServiceMain {
    static func main() async {
        do {
            let options = try ServiceOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if let home = options.home { setenv("SWIFTCUA_HOME", (home as NSString).expandingTildeInPath, 1) }
            if options.version { print(CUAProtocolVersion.serviceVersion); return }
            let socketPath = options.socketPath ?? CUAPaths.socketPath.path
            if options.printSocket { print(socketPath); return }
            var config = try ServiceConfiguration.load()
            if options.requirePeer { config.requirePeerValidation = true }
            if let autoAuthorize = options.autoAuthorize { config.autoAuthorizeApps = autoAuthorize }
            let sessions = try SessionStore(autoAuthorizeApps: config.autoAuthorizeApps)
            let router = RequestRouter(engine: SkyEngine(), sessions: sessions)
            let server = SocketServer(socketPath: socketPath, router: router,
                                      validator: PeerValidator(configuration: config, bypass: options.bypassPeer)) { path in
                FileHandle.standardError.write(Data("SwiftCUA service \(CUAProtocolVersion.serviceVersion) api \(CUAProtocolVersion.current) listening on \(path)\n".utf8))
            }
            try server.start(installSignalHandlers: true)
            await sessions.startCleanup()
            await server.waitUntilStopped()
            await sessions.stopCleanup()
        } catch {
            FileHandle.standardError.write(Data("SwiftCUA service: \(error)\n".utf8))
            exit(1)
        }
    }
}
