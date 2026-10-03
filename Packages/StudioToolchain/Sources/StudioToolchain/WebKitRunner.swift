import Foundation
import WebKit

/// Runs WASI command modules in a hidden WKWebView. WebAssembly executes in
/// WebKit's WebContent process, which may JIT (the app process may not), and a
/// crash or runaway loop there cannot take the IDE down.
///
/// The runtime page and the program are served by a WKURLSchemeHandler under
/// lsx://runtime/ with COOP/COEP headers, so the page is cross-origin isolated
/// (SharedArrayBuffer, needed later for wasi-threads).
@MainActor
public final class WebKitRunner {
  public enum RunnerError: Error, LocalizedError {
    case runtimeMissing
    case pageFailed(String)
    case busy
    public var errorDescription: String? {
      switch self {
      case .runtimeMissing: "The WASI runtime page is missing from the bundle."
      case .pageFailed(let message): "The runtime page failed to load: \(message)"
      case .busy: "A program is already running in this runner."
      }
    }
  }

  /// What the runtime page reported when it loaded.
  public struct EngineInfo: Sendable {
    public var webAssembly: Bool
    public var crossOriginIsolated: Bool
    public var sharedArrayBuffer: Bool
    public var userAgent: String
    public var pageLoadMilliseconds: Double
  }

  public private(set) var engineInfo: EngineInfo?

  private var webView: WKWebView?
  private let schemeHandler = RuntimeSchemeHandler()
  private let messageProxy = MessageProxy()
  private var readyContinuation: CheckedContinuation<Void, Error>?
  private var current: (id: String, output: WasmOutputHandler,
                        continuation: CheckedContinuation<WasmRunResult, Never>, start: ContinuousClock.Instant)?
  private var loadStart = ContinuousClock.now

  public init() {
    messageProxy.owner = self
  }

  /// Loads the runtime page ahead of the first run (otherwise run does it).
  public func prepare() async throws {
    if webView != nil, engineInfo != nil { return }
    guard let runtimeDir = Bundle.module.url(forResource: "WASIRuntime", withExtension: nil) else {
      throw RunnerError.runtimeMissing
    }
    schemeHandler.runtimeDirectory = runtimeDir

    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "lsx")
    configuration.userContentController.add(messageProxy, name: "lsx")
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
    view.isInspectable = true
    view.navigationDelegate = messageProxy
    webView = view
    attachOffscreen(view)

    loadStart = .now
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      readyContinuation = continuation
      view.load(URLRequest(url: URL(string: "lsx://runtime/index.html")!))
    }
  }

  /// Runs a WASI command module to completion, streaming its output.
  public func run(
    wasm: Data, arguments: [String], environment: [String: String] = [:],
    output: @escaping WasmOutputHandler
  ) async throws -> WasmRunResult {
    guard current == nil else { throw RunnerError.busy }
    try await prepare()
    let id = UUID().uuidString
    schemeHandler.programs[id] = wasm
    defer { schemeHandler.programs[id] = nil }

    let config: [String: Any] = [
      "id": id,
      "programURL": "lsx://runtime/program/\(id).wasm",
      "args": arguments,
      "env": environment,
    ]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
    let start = ContinuousClock.now
    return await withCheckedContinuation { continuation in
      current = (id, output, continuation, start)
      webView?.evaluateJavaScript("lsxRun(\(json))") { [weak self] _, error in
        guard let error, let self else { return }
        MainActor.assumeIsolated {
          self.finish(WasmRunResult(exitCode: -1, error: error.localizedDescription,
                                    loadMilliseconds: 0, instantiateMilliseconds: 0,
                                    runMilliseconds: 0, totalMilliseconds: 0))
        }
      }
    }
  }

  /// Tears the web view down (kills a runaway program); the next run reloads it.
  public func reset() {
    if current != nil {
      finish(WasmRunResult(exitCode: -1, error: "terminated", loadMilliseconds: 0,
                           instantiateMilliseconds: 0, runMilliseconds: 0, totalMilliseconds: 0))
    }
    webView?.configuration.userContentController.removeScriptMessageHandler(forName: "lsx")
    webView?.removeFromSuperview()
    webView = nil
    engineInfo = nil
  }

  // MARK: - Messages from the page

  fileprivate func receive(_ body: Any) {
    guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
    switch type {
    case "ready":
      engineInfo = EngineInfo(
        webAssembly: message["webAssembly"] as? Bool ?? false,
        crossOriginIsolated: message["crossOriginIsolated"] as? Bool ?? false,
        sharedArrayBuffer: message["sharedArrayBuffer"] as? Bool ?? false,
        userAgent: message["userAgent"] as? String ?? "",
        pageLoadMilliseconds: milliseconds(ContinuousClock.now - loadStart))
      readyContinuation?.resume()
      readyContinuation = nil
    case "output":
      guard let current, message["id"] as? String == current.id,
            let text = message["text"] as? String else { return }
      let fd = message["fd"] as? Int ?? 1
      current.output(WasmOutput(stream: fd == 2 ? .stderr : .stdout, text: text))
    case "exit":
      guard let current, message["id"] as? String == current.id else { return }
      let number = { (key: String) in (message[key] as? NSNumber)?.doubleValue ?? 0 }
      finish(WasmRunResult(
        exitCode: Int32(truncatingIfNeeded: (message["code"] as? NSNumber)?.intValue ?? -1),
        error: message["error"] as? String,
        loadMilliseconds: number("compileMs"),
        instantiateMilliseconds: number("instantiateMs"),
        runMilliseconds: number("runMs"),
        totalMilliseconds: milliseconds(ContinuousClock.now - current.start),
        unsupportedImports: message["unsupported"] as? [String] ?? []))
    default:
      break
    }
  }

  fileprivate func pageFailed(_ error: Error) {
    readyContinuation?.resume(throwing: RunnerError.pageFailed(error.localizedDescription))
    readyContinuation = nil
  }

  /// The WebContent process died (out of memory, or killed): fail the run,
  /// drop the view; the app itself is unaffected.
  fileprivate func contentProcessTerminated() {
    pageFailed(RunnerError.pageFailed("the web content process terminated"))
    finish(WasmRunResult(exitCode: -1, error: "the web content process terminated",
                         loadMilliseconds: 0, instantiateMilliseconds: 0,
                         runMilliseconds: 0, totalMilliseconds: 0))
    reset()
  }

  private func finish(_ result: WasmRunResult) {
    guard let current else { return }
    self.current = nil
    current.continuation.resume(returning: result)
  }

  /// WebKit may throttle a web view that is in no window; park it, invisible,
  /// in the key window.
  private func attachOffscreen(_ view: WKWebView) {
    view.alpha = 0.01
    view.isUserInteractionEnabled = false
    let window = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first { $0.isKeyWindow } ?? UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }.first?.windows.first
    window?.insertSubview(view, at: 0)
  }
}

/// Receives page messages and navigation events; also breaks the
/// WKUserContentController -> handler retain cycle.
@MainActor
private final class MessageProxy: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  weak var owner: WebKitRunner?
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.receive(message.body)
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
    owner?.pageFailed(error)
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
    owner?.pageFailed(error)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    owner?.contentProcessTerminated()
  }
}

/// Serves lsx://runtime/<file> from the bundle and lsx://runtime/program/<id>.wasm
/// from memory, with the headers that make the page cross-origin isolated.
@MainActor
private final class RuntimeSchemeHandler: NSObject, WKURLSchemeHandler {
  var runtimeDirectory: URL?
  var programs: [String: Data] = [:]

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url else { return }
    let path = url.path
    var body: Data?
    var mime = "application/octet-stream"
    if path.hasPrefix("/program/"), path.hasSuffix(".wasm") {
      let id = String(path.dropFirst("/program/".count).dropLast(".wasm".count))
      body = programs[id]
      mime = "application/wasm"
    } else if let dir = runtimeDirectory {
      let name = String(path.drop { $0 == "/" })
      let file = dir.appending(path: name)
      // Only files directly inside the runtime directory.
      if !name.contains("/"), !name.contains("..") {
        body = try? Data(contentsOf: file)
      }
      mime = name.hasSuffix(".html") ? "text/html" : name.hasSuffix(".js") ? "text/javascript" : mime
    }
    let status = body == nil ? 404 : 200
    let headers = [
      "Content-Type": mime,
      "Content-Length": String(body?.count ?? 0),
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
      "Cross-Origin-Resource-Policy": "same-origin",
      "Cache-Control": "no-store",
    ]
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    task.didReceive(response)
    task.didReceive(body ?? Data())
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
