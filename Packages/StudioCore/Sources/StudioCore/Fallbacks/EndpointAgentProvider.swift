import SwiftUI
import StudioDesign

/// Talks to an OpenAI-compatible endpoint's `/models` route, such as LSE's
/// `lse-server` on a Mac (reachable as 127.0.0.1 from the simulator).
public struct ModelEndpointProbe: Sendable {
    public var baseURL: URL
    public var timeout: TimeInterval

    public init(baseURL: URL, timeout: TimeInterval = 2.5) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// The default: LSE's server on this machine.
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8080/v1")!

    /// The served model IDs.
    public func models() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try Self.parseModels(data)
    }

    /// Parses `{"data":[{"id":"..."}]}`.
    public static func parseModels(_ data: Data) throws -> [String] {
        struct Listing: Decodable {
            struct Model: Decodable { var id: String }
            var data: [Model]
        }
        return try JSONDecoder().decode(Listing.self, from: data).data.map(\.id)
    }
}

/// The built-in agent fallback. It has no agent loop; it reports whether
/// the configured model endpoint is reachable and which model it serves,
/// so the status bar shows the model before the agent package is installed.
@MainActor
@Observable
public final class EndpointAgentProvider: AgentProviding {
    public let id = "com.geramyloveless.LemonSeedStudio.agent-endpoint"
    public let displayName = "Model endpoint"
    public private(set) var status = AgentStatus(state: .unavailable("Not checked yet"))
    public var endpoint: URL {
        didSet { if endpoint != oldValue { Task { await refresh() } } }
    }
    public private(set) var models: [String] = []
    public private(set) var lastChecked: Date?

    public init(endpoint: URL = ModelEndpointProbe.defaultEndpoint) {
        self.endpoint = endpoint
    }

    public func refresh() async {
        status = AgentStatus(state: .connecting, backend: backendLabel)
        do {
            let found = try await ModelEndpointProbe(baseURL: endpoint).models()
            models = found
            status = found.isEmpty
                ? AgentStatus(state: .unavailable("The server at \(backendLabel) has no model loaded."), backend: backendLabel)
                : AgentStatus(state: .idle, modelName: found.first, backend: backendLabel)
        } catch {
            models = []
            status = AgentStatus(state: .unavailable("No model server at \(backendLabel)."), backend: backendLabel)
        }
        lastChecked = Date()
    }

    private var backendLabel: String {
        let host = endpoint.host() ?? endpoint.absoluteString
        let port = endpoint.port.map { ":\($0)" } ?? ""
        return host == "127.0.0.1" || host == "localhost" ? "local server \(host)\(port)" : "remote \(host)\(port)"
    }

    public func makePanel(context: any WorkspaceContext) -> AnyView {
        AnyView(EndpointAgentPanel(provider: self))
    }
}

struct EndpointAgentPanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let provider: EndpointAgentProvider

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    StatusDot(dotColor, live: provider.status.state == .idle)
                    Text(title)
                        .font(.studio(type.body, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary.color)
                    Spacer()
                    StudioIconButton(StudioSymbol.refresh, help: "Check again") {
                        Task { await provider.refresh() }
                    }
                }
                Text(provider.endpoint.absoluteString)
                    .font(.system(size: type.caption, design: .monospaced))
                    .foregroundStyle(theme.palette.textSecondary.color)
                    .textSelection(.enabled)
                if case .unavailable(let reason) = provider.status.state {
                    Text(reason + " Start lse-server on your Mac, or change the endpoint in Settings.")
                        .font(.studio(type.caption))
                        .foregroundStyle(theme.palette.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !provider.models.isEmpty {
                    ForEach(provider.models, id: \.self) { model in
                        Label(model, systemImage: "cube.transparent")
                            .font(.studio(type.caption))
                            .foregroundStyle(theme.palette.textPrimary.color)
                    }
                }
            }
            .padding(Space.m)
            .elevatedSurface()

            Text("The coding agent (chat, tools, review) appears here once the agent package is installed. It will run on the GPU attached to this iPad, or on this endpoint.")
                .font(.studio(type.caption))
                .foregroundStyle(theme.palette.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, Space.m)
        .task { if provider.lastChecked == nil { await provider.refresh() } }
    }

    private var title: String {
        switch provider.status.state {
        case .idle: provider.status.modelName ?? "Connected"
        case .connecting: "Connecting…"
        case .working(let what): what
        case .unavailable: "Model offline"
        }
    }

    private var dotColor: Color {
        switch provider.status.state {
        case .idle: theme.palette.success.color
        case .connecting, .working: theme.palette.warning.color
        case .unavailable: theme.palette.textTertiary.color
        }
    }
}

/// The telemetry fallback when no engine layer is present.
@MainActor
@Observable
public final class PlaceholderTelemetryProvider: TelemetryProviding {
    public let id = "com.geramyloveless.LemonSeedStudio.telemetry-placeholder"
    public let displayName = "GPU"
    public private(set) var engineState: EngineState = .unknown
    public let summary: GPUSummary? = nil

    public init() {}

    public func refresh() {}

    public func makeGPUView(context: (any WorkspaceContext)?) -> AnyView {
        AnyView(StudioEmptyState(symbol: StudioSymbol.gpu, title: "GPU unavailable",
                                 message: "GPU telemetry is not available in this build."))
    }
}
