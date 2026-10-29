import Foundation
import AppKit
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
    var headless: Bool

    init(arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        headless = environment["SWIFTCUA_HEADLESS"] == "1"
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
            case "--headless": headless = true
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
    // 同步入口：NSApplication.run() 会长期占用主线程，若把它包在
    // `await MainActor.run { ... }` 里，MainActor 的后续任务（例如 PreviewHub
    // 订阅）将永远得不到执行，预览面板就不会出现。
    static func main() {
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
            if options.headless {
                runHeadless(server: server, sessions: sessions)
            } else {
                // main() 固定在主线程；把整个 AppKit 生命周期切到 MainActor。
                MainActor.assumeIsolated { runApplication(server: server, sessions: sessions) }
            }
        } catch {
            FileHandle.standardError.write(Data("SwiftCUA service: \(error)\n".utf8))
            exit(1)
        }
    }

    /// 无 UI 模式：主线程只等异步服务器结束，不创建 NSApplication。
    private static func runHeadless(server: SocketServer, sessions: SessionStore) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try server.start(installSignalHandlers: true)
                await sessions.startCleanup()
                await server.waitUntilStopped()
                await sessions.stopCleanup()
            } catch {
                FileHandle.standardError.write(Data("SwiftCUA service: \(error)\n".utf8))
                exit(1)
            }
            done.signal()
        }
        done.wait()
    }

    @MainActor
    private static func runApplication(server: SocketServer, sessions: SessionStore) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let lifecycle = ServiceApplicationDelegate(server: server, sessions: sessions)
        application.delegate = lifecycle
        lifecycle.start()
        withExtendedLifetime(lifecycle) { application.run() }
    }
}

/// 仅负责服务与 AppKit 生命周期接线；信号处理仍由 SocketServer 安装。
@MainActor
private final class ServiceApplicationDelegate: NSObject, NSApplicationDelegate {
    private let server: SocketServer
    private let sessions: SessionStore
    private let preview = PreviewUI()
    private var serverTask: Task<Void, Never>?
    private var terminating = false
    private var exitCode: Int32 = 0

    init(server: SocketServer, sessions: SessionStore) {
        self.server = server
        self.sessions = sessions
    }

    func start() {
        let server = server
        let sessions = sessions
        serverTask = Task.detached { [weak self] in
            do {
                try server.start(installSignalHandlers: true)
                if Task.isCancelled { server.stop() }
                await sessions.startCleanup()
                await server.waitUntilStopped()
                await sessions.stopCleanup()
            } catch {
                FileHandle.standardError.write(Data("SwiftCUA service: \(error)\n".utf8))
                await self?.recordFailure()
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private func recordFailure() { exitCode = 1 }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            // 退出菜单也走完整异步清理；不能在 willTerminate 里才创建来不及执行的 Task。
            // 取消标记配合 start 后检查，避免极早退出时 stop 先于 start 导致永远等待。
            serverTask?.cancel()
            server.stop()
            await serverTask?.value
            server.stop()
            await sessions.stopCleanup()
            await preview.shutdown()
            await WindowStream.shared.stopAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if exitCode != 0 { exit(exitCode) }
    }
}
