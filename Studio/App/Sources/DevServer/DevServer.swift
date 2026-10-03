#if DEBUG
import Foundation
import Network
import Observation
import UIKit
import os
import StudioCore
import StudioAgent
import StudioAgentUI

private let devLog = Logger(subsystem: "com.geramyloveless.LemonSeedStudio", category: "devserver")

/// `value ?? NSNull()` for JSON objects: the value, or JSON null.
fileprivate func ?? <T>(lhs: T?, rhs: @autoclosure () -> NSNull) -> Any {
    if let lhs { return lhs }
    return rhs()
}

/// App and engine log lines with sequence numbers, for `GET /logs?since=`.
@MainActor
final class DevLog {
    static let shared = DevLog()
    private(set) var lines: [(seq: Int, time: Date, source: String, text: String)] = []
    private var next = 1

    func append(_ text: String, source: String) {
        lines.append((next, Date(), source, text))
        next += 1
        if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
    }
}

/// The development remote control: a small HTTP server on the iPad's Wi-Fi
/// interface (port 8765, Bonjour `_lemonseed-dev._tcp`) that lets the Mac
/// drive the app (`Studio/scripts/studioctl`). Debug builds only; every
/// request needs the per-launch token from Settings › Developer or
/// Documents/devserver.json. Cellular is never used.
@MainActor
@Observable
final class DevServer {
    static let shared = DevServer()
    static let port: UInt16 = 8765
    static let serviceType = "_lemonseed-dev._tcp"

    private(set) var token = DevServer.makeToken()
    private(set) var state = "stopped"
    private(set) var addresses: [String] = []
    private(set) var requestCount = 0
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "dev.serverEnabled")
            enabled ? start() : stop()
        }
    }

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "com.geramyloveless.LemonSeedStudio.devserver")

    private init() {
        enabled = UserDefaults.standard.object(forKey: "dev.serverEnabled") as? Bool ?? true
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func startIfEnabled() {
        guard enabled else { return }
        start()
        UIDriver.enableAccessibilityTree()
    }

    func regenerateToken() {
        token = Self.makeToken()
        writeInfo()
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .wifi
            params.prohibitedInterfaceTypes = [.cellular]
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.service = NWListener.Service(name: "LemonSeed Studio \(UIDevice.current.name)", type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.update(state) }
            }
            listener.newConnectionHandler = { connection in
                let http = DevHTTPConnection(connection: connection) { request in
                    await DevServer.shared.handle(request)
                }
                http.start(queue: DispatchQueue(label: "com.geramyloveless.LemonSeedStudio.devserver.connection"))
            }
            listener.start(queue: queue)
            self.listener = listener
            state = "starting"
        } catch {
            state = "failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = "stopped"
        try? FileManager.default.removeItem(at: Self.infoURL)
    }

    private func update(_ s: NWListener.State) {
        switch s {
        case .ready:
            state = "listening on port \(Self.port)"
            addresses = Self.wifiAddresses()
            writeInfo()
            devLog.log("dev server ready on \(self.addresses.joined(separator: ", "), privacy: .public):\(Self.port)")
        case .failed(let error):
            state = "failed: \(error.localizedDescription)"
            listener?.cancel()
            listener = nil
        case .waiting(let error):
            state = "waiting: \(error.localizedDescription)"
        case .cancelled:
            state = "stopped"
        default:
            break
        }
    }

    static var infoURL: URL { DevSupport.documents.appendingPathComponent("devserver.json") }

    /// Documents/devserver.json, which studioctl fetches with devicectl.
    private func writeInfo() {
        let info: [String: Any] = ["port": Int(Self.port), "token": token, "addresses": addresses,
                                   "service": Self.serviceType, "device": UIDevice.current.name,
                                   "started": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.infoURL, options: .atomic)
        }
    }

    /// IPv4 addresses of the Wi-Fi interface (en0).
    static func wifiAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let name = String(cString: entry.pointee.ifa_name)
            if name == "en0", let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    result.append(String(cString: host))
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return result
    }

    // MARK: Routing

    private var app: AppModel { AppModel.shared }

    func handle(_ request: DevRequest) async -> DevResponse {
        requestCount += 1
        let bearer = request.headers["authorization"].map { $0.replacingOccurrences(of: "Bearer ", with: "") }
        guard (bearer ?? request.headers["x-token"] ?? request.query["token"]) == token else {
            return .error("missing or wrong token", status: 401)
        }
        DevLog.shared.append("\(request.method) \(request.path)", source: "devserver")
        let body = request.json()
        switch (request.method, request.path) {
        case ("GET", "/status"):
            return .json(status())
        case ("GET", "/ui/tree"):
            return .json(["elements": UIDriver.tree(includeAll: request.query["all"] == "1")])
        case ("GET", "/ui/find"):
            guard let found = UIDriver.find(id: request.query["id"], label: request.query["label"]) else {
                return .error("not found", status: 404)
            }
            let f = found.frame
            return .json(["frame": [f.origin.x, f.origin.y, f.size.width, f.size.height],
                          "label": found.object.accessibilityLabel ?? "", "value": found.object.accessibilityValue ?? ""])
        case ("POST", "/ui/tap"):
            var point: CGPoint?
            if let p = body["point"] as? [Double], p.count == 2 { point = CGPoint(x: p[0], y: p[1]) }
            let (ok, detail) = UIDriver.tap(id: body["id"] as? String, label: body["label"] as? String, point: point)
            return .json(["ok": ok, "detail": detail], status: ok ? 200 : 404)
        case ("POST", "/ui/type"):
            let (ok, detail) = await UIDriver.type(body["text"] as? String ?? "", into: body["id"] as? String)
            return .json(["ok": ok, "detail": detail], status: ok ? 200 : 409)
        case ("POST", "/ui/key"):
            let (ok, detail) = UIDriver.key(body["key"] as? String ?? "", modifiers: body["modifiers"] as? [String] ?? [], app: app)
            return .json(["ok": ok, "detail": detail], status: ok ? 200 : 409)
        case ("POST", "/ui/scroll"):
            var point: CGPoint?
            if let p = body["point"] as? [Double], p.count == 2 { point = CGPoint(x: p[0], y: p[1]) }
            let (ok, detail) = UIDriver.scroll(id: body["id"] as? String, point: point,
                                               dx: CGFloat(body["dx"] as? Double ?? 0), dy: CGFloat(body["dy"] as? Double ?? 0))
            return .json(["ok": ok, "detail": detail], status: ok ? 200 : 404)
        case ("POST", "/ui/drag"):
            let id = body["id"] as? String ?? "sidebar.resize"
            let (ok, detail) = UIDriver.drag(id: id, dx: CGFloat(body["dx"] as? Double ?? 0),
                                             dy: CGFloat(body["dy"] as? Double ?? 0), app: app)
            return .json(["ok": ok, "detail": detail, "sidebarWidth": Double(app.activeRouter?.controller?.sidebarWidth ?? 0)],
                         status: ok ? 200 : 404)
        case ("POST", "/ui/rotate"):
            let portrait = (body["orientation"] as? String ?? "landscape") == "portrait"
            await DevSupport.rotate(to: portrait ? .portrait : .landscape)
            return .json(["ok": true])
        case ("GET", "/ui/screenshot"):
            if let delay = request.query["delay"].flatMap(Double.init) { try? await Task.sleep(for: .seconds(delay)) }
            guard let png = DevSupport.snapshot() else { return .error("no window", status: 503) }
            return .data(status: 200, contentType: "image/png", body: png)
        case ("POST", "/nav"):
            let (ok, detail) = await UIDriver.navigate(body["screen"] as? String ?? "", app: app)
            if ok, let width = body["sidebarWidth"] as? Double { app.activeRouter?.controller?.sidebarWidth = CGFloat(width) }
            return .json(["ok": ok, "detail": detail, "screens": UIDriver.screens], status: ok ? 200 : 400)
        case ("GET", "/engine/status"):
            return .json(engineStatus())
        case ("POST", "/engine/start"):
            app.gpu.startIfPossible()
            return .json(engineStatus())
        case ("POST", "/engine/stop"):
            app.engine.stop()
            return .json(engineStatus())
        case ("POST", "/engine/reload"):
            guard let launch = app.gpu.currentLaunch() else { return .error("no model installed", status: 409) }
            app.engine.reload(launch)
            return .json(engineStatus())
        case ("POST", "/engine/request"):
            return engineRequest(body)
        case ("GET", "/chat/sessions"):
            return chatSessions()
        case ("POST", "/chat/send"):
            return chatSend(body)
        case ("POST", "/chat/new"):
            guard let model = agentModel() else { return .error("no workspace open", status: 409) }
            model.newSession()
            return .json(["ok": true])
        case ("POST", "/chat/session/close"):
            guard let id = body["id"] as? String else { return .error("id required") }
            app.engine.closeSession(id)
            return .json(["ok": true, "engineSupportsClose": app.engine.supportsSessionClose])
        case ("POST", "/chat/session/delete"):
            guard let model = agentModel(), let id = body["id"] as? String,
                  let s = model.sessions.first(where: { $0.id == id }) else { return .error("no such session", status: 404) }
            model.deleteSession(s)
            return .json(["ok": true])
        case ("GET", "/logs"):
            let since = Int(request.query["since"] ?? "0") ?? 0
            let lines = DevLog.shared.lines.filter { $0.seq > since }.suffix(2000)
            let f = ISO8601DateFormatter()
            return .json(["lines": lines.map { ["seq": $0.seq, "time": f.string(from: $0.time), "source": $0.source, "text": $0.text] }])
        case ("GET", "/driver/status"):
            return .json(driverStatus())
        case ("POST", "/fixtures/record"):
            guard app.driver.service != nil else { return .error("the driver is not running", status: 409) }
            let name = body["name"] as? String ?? "r9700-idle"
            guard name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return .error("bad name") }
            let line = await FixtureCapture.record(name: name, description: body["description"] as? String ?? "",
                                                   seconds: body["seconds"] as? Double ?? 60)
            return .json(["result": line, "file": "fixtures/\(name).json"])
        case ("GET", "/file"):
            return file(request.query["path"] ?? "")
        default:
            return .error("no route \(request.method) \(request.path)", status: 404)
        }
    }

    // MARK: Handlers

    private func status() -> [String: Any] {
        let bundle = Bundle.main
        return [
            "app": "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))",
            "workspace": app.activeRouter?.controller?.displayName ?? NSNull(),
            "sidebar": app.activeRouter?.controller?.sidebarItem.rawValue ?? NSNull(),
            "sidebarWidth": Double(app.activeRouter?.controller?.sidebarWidth ?? 0),
            "engine": app.engine.statusLine,
            "driver": app.driver.service.map { "\($0.className) 0x\(String($0.registryID, radix: 16))" } ?? "not running",
            "screens": UIDriver.screens,
        ]
    }

    private func engineStatus() -> [String: Any] {
        var s = app.engine.status()
        s["phase"] = "\(app.engine.phase)"
        s["statusLine"] = app.engine.statusLine
        if let launch = app.engine.launch {
            s["launch"] = ["model": launch.modelID, "draft": launch.draftID ?? NSNull(),
                           "kv": "\(launch.kvCacheDType)/\(launch.kvLength)",
                           "batch": "\(launch.batchSize)/\(launch.ubatchSize)"] as [String: Any]
        }
        if let seconds = app.engine.loadSeconds { s["loadSeconds"] = seconds }
        s["canReopenInProcess"] = EngineService.canReopenInProcess
        if let pending = app.engine.restartRequired {
            s["restartRequired"] = ["model": pending.modelID, "kv": "\(pending.kvCacheDType)/\(pending.kvLength)"]
        }
        return s
    }

    private func driverStatus() -> [String: Any] {
        let d = app.driver
        var s: [String: Any] = [
            "embeddedDext": d.embeddedDext ?? NSNull(),
            "enabled": d.isEnabled.map { $0 as Any } ?? NSNull(),
            "service": d.service.map { ["class": $0.className, "registryID": String($0.registryID, radix: 16),
                                        "server": $0.userServerName, "matches": $0.matchCount] as [String: Any] } ?? NSNull(),
            "engineState": "\(app.services.telemetry.engineState)",
        ]
        #if LEMONSEED_DEVICE
        s["probeReport"] = ProbeModel.shared.report
        #endif
        return s
    }

    /// Raw lse_request: the body as given, streamed back as SSE when
    /// `stream` is true (each engine chunk one event).
    private func engineRequest(_ body: [String: Any]) -> DevResponse {
        let method = body["method"] as? String ?? "POST"
        let path = body["path"] as? String ?? "/v1/chat/completions"
        let payload: Data? = if let object = body["body"] as? [String: Any] {
            try? JSONSerialization.data(withJSONObject: object)
        } else if let text = body["body"] as? String {
            Data(text.utf8)
        } else {
            nil
        }
        let box = app.engine.box
        let streaming = (body["body"] as? [String: Any])?["stream"] as? Bool ?? false
        guard streaming else {
            return .stream { sink in
                let response = await Task.detached { try? box.perform(method: method, path: path, body: payload) { _ in true } }.value
                let object = response.flatMap { try? JSONSerialization.jsonObject(with: $0.body) } ?? NSNull()
                await sink.send(["status": response?.status ?? 503, "body": object])
            }
        }
        return .stream { sink in
            let (chunks, continuation) = AsyncStream<Data>.makeStream()
            let worker = Task.detached {
                let response = try? box.perform(method: method, path: path, body: payload) { chunk in
                    continuation.yield(chunk)
                    return !sink.closed
                }
                continuation.finish()
                return response?.status ?? 503
            }
            for await chunk in chunks {
                let object = (try? JSONSerialization.jsonObject(with: chunk)) as? [String: Any] ?? ["raw": String(decoding: chunk, as: UTF8.self)]
                await sink.send(object)
            }
            await sink.send(["status": await worker.value])
        }
    }

    private func agentModel() -> AgentViewModel? {
        guard let controller = app.activeRouter?.controller,
              let provider = app.services.agent as? StudioAgentProvider else { return nil }
        return provider.viewModel(for: controller.rootURL, displayName: controller.displayName)
    }

    private func chatSessions() -> DevResponse {
        guard let model = agentModel() else { return .error("no workspace open", status: 409) }
        model.refreshSessions()
        let f = ISO8601DateFormatter()
        return .json(["current": model.currentSessionID ?? NSNull(), "thinking": model.thinking.rawValue,
                      "sessions": model.sessions.map {
                          ["id": $0.id, "title": $0.title, "model": $0.model ?? NSNull(), "thinking": $0.thinking ?? NSNull(),
                           "messages": $0.messageCount, "pinned": $0.pinned, "modified": f.string(from: $0.modified)] as [String: Any]
                      }])
    }

    /// Sends a chat message in the AI panel and streams what appears there:
    /// reasoning and answer deltas, tool calls, then the final timings.
    private func chatSend(_ body: [String: Any]) -> DevResponse {
        guard app.engine.phase == .ready else { return .error("the engine is not ready (\(app.engine.statusLine))", status: 409) }
        guard let model = agentModel() else { return .error("no workspace open", status: 409) }
        guard let text = body["text"] as? String, !text.isEmpty else { return .error("text required") }
        if let session = body["session"] as? String {
            if session == "new" {
                model.newSession()
            } else if session != model.currentSessionID {
                model.refreshSessions()
                guard let s = model.sessions.first(where: { $0.id == session }) else { return .error("no session \(session)", status: 404) }
                model.open(s)
            }
        }
        if let raw = body["thinking"] as? String {
            let level = ThinkingLevel(rawValue: raw) ?? ThinkingLevel.pickerLevels.first { $0.title.lowercased() == raw.lowercased() }
            if let level { model.setThinking(level) }
        }
        if let mode = (body["mode"] as? String).flatMap(PermissionMode.init(rawValue:)) { model.mode = mode }
        app.activeRouter?.controller?.show(SidebarItem.agent)
        return .stream { [model] sink in
            let started = Date()
            let firstItem = model.items.count
            model.send(text)
            var sentText: [String: Int] = [:], sentReasoning: [String: Int] = [:]
            var toolStates: [String: String] = [:]
            var firstToken: Double?
            try? await Task.sleep(for: .milliseconds(100))
            while !sink.closed {
                let running = model.isRunning
                for item in model.items.dropFirst(firstItem) {
                    switch item.kind {
                    case .assistant(let b):
                        let r = sentReasoning[item.id, default: 0]
                        if b.reasoning.count > r {
                            let delta = String(b.reasoning.dropFirst(r))
                            sentReasoning[item.id] = b.reasoning.count
                            if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                            await sink.send(["type": "reasoning", "text": delta])
                        }
                        let t = sentText[item.id, default: 0]
                        if b.text.count > t {
                            let delta = String(b.text.dropFirst(t))
                            sentText[item.id] = b.text.count
                            if firstToken == nil { firstToken = Date().timeIntervalSince(started) }
                            await sink.send(["type": "text", "text": delta,
                                             "tokens": b.streamedTokens, "tokPerSec": b.liveTokensPerSecond() ?? NSNull()])
                        }
                    case .tool(let card):
                        let s = "\(card.status)"
                        if toolStates[card.callID] != s {
                            toolStates[card.callID] = s
                            await sink.send(["type": "tool", "name": card.name, "status": s,
                                             "arguments": card.arguments.serialized(),
                                             "result": card.result.map { String($0.text.prefix(500)) } ?? NSNull()])
                        }
                    case .notice(let message, let isError):
                        _ = message; _ = isError
                    default:
                        break
                    }
                }
                if !running, Date().timeIntervalSince(started) > 0.5 { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            var final: [String: Any] = ["type": "done", "seconds": Date().timeIntervalSince(started),
                                        "session": model.currentSessionID ?? NSNull(),
                                        "thinking": model.thinking.rawValue,
                                        "context": model.stats.contextTokens, "contextWindow": model.stats.contextWindow,
                                        "firstTokenSeconds": firstToken ?? NSNull()]
            if let t = model.stats.lastTimings {
                final["timings"] = ["promptTokens": t.promptTokens ?? NSNull(), "promptPerSecond": t.promptPerSecond ?? NSNull(),
                                    "decodeTokens": t.decodeTokens ?? NSNull(), "decodePerSecond": t.decodePerSecond ?? NSNull(),
                                    "acceptance": t.acceptanceRate ?? NSNull(), "cached": t.promptCachedTokens ?? NSNull()] as [String: Any]
            }
            let notices = model.items.dropFirst(firstItem).compactMap { item -> String? in
                if case .notice(let m, _) = item.kind { return m }
                return nil
            }
            if !notices.isEmpty { final["notices"] = notices }
            await sink.send(final)
        }
    }

    /// A file under Documents (fixtures, engine-status.json, screenshots).
    private func file(_ path: String) -> DevResponse {
        guard !path.isEmpty, !path.contains(".."), !path.hasPrefix("/") else { return .error("path must be relative to Documents") }
        let url = DevSupport.documents.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else { return .error("no file \(path)", status: 404) }
        let type = url.pathExtension == "json" ? "application/json" : url.pathExtension == "png" ? "image/png" : "application/octet-stream"
        return .data(status: 200, contentType: type, body: data)
    }
}
#endif
