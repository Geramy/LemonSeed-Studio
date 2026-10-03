import SwiftUI
import StudioCore
import StudioDesign

enum StudioScenes {
    static let workspace = "workspace"
    static let gpuMonitor = "gpu-monitor"
}

@main
struct LemonSeedStudioApp: App {
    @State private var app = AppModel.shared

    var body: some Scene {
        // Each window is a workspace (Stage Manager: one window per
        // workspace). The value is the workspace reference, so windows
        // reopen their workspace on relaunch.
        WindowGroup(id: StudioScenes.workspace, for: UUID.self) { $referenceID in
            StudioSceneView(referenceID: $referenceID)
                .environment(app)
        }
        .commands {
            StudioMenuCommands(app: app)
        }

        WindowGroup("GPU Monitor", id: StudioScenes.gpuMonitor) {
            GPUMonitorWindow()
                .environment(app)
        }
    }
}

/// Applies the theme, density and code font to a window's content.
struct StudioEnvironment: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let theme = app.settings.theme(for: systemScheme)
        content
            .studioTheme(theme)
            .environment(\.density, app.resolvedDensity)
            .environment(\.codeFont, app.settings.codeFont)
            .environment(\.editorSettings, app.settings.editor)
    }
}

/// One window: the welcome screen until a workspace opens, then the
/// workspace window.
struct StudioSceneView: View {
    @Binding var referenceID: UUID?
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("window.state") private var savedState: Data?
    @State private var router = SceneRouter()
    @State private var restored = false
    @State private var newProjectName = ""

    var body: some View {
        @Bindable var router = router
        Group {
            if let controller = router.controller {
                WorkspaceWindow(controller: controller)
                    .id(ObjectIdentifier(controller))
            } else {
                WelcomeView(router: router)
            }
        }
        .modifier(StudioEnvironment())
        .focusedSceneValue(\.sceneRouter, router)
        .sheet(isPresented: $router.isPickingFolder) {
            FolderPicker(startingAt: app.library.projectsFolder) { url in
                router.isPickingFolder = false
                if let url { router.openFolder(url) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $router.isSettingsPresented) {
            SettingsView(page: router.settingsPage)
                .modifier(StudioEnvironment())
                .environment(app)
        }
        .alert("New Project", isPresented: $router.isNewProjectPresented) {
            TextField("Name", text: $newProjectName)
                .accessibilityIdentifier("newProject.name")
            Button("Create") {
                let name = newProjectName.trimmingCharacters(in: .whitespaces)
                newProjectName = ""
                if !name.isEmpty { router.createProject(named: name) }
            }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        } message: {
            Text("A new folder in On My iPad › LemonSeed Studio › Projects.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { router.errorMessage != nil },
                                                           set: { if !$0 { router.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(router.errorMessage ?? "")
        }
        .onAppear {
            router.onReferenceChange = { referenceID = $0 }
            app.activeRouter = router
            openInitialWorkspace()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.activeRouter = router }
            if phase != .active { persist() }
        }
        .onChange(of: router.controller?.windowState) { _, _ in persistSoon() }
    }

    private func openInitialWorkspace() {
        guard router.controller == nil else { return }
        if let id = referenceID, !LaunchOptions.resetState {
            router.open(referenceID: id)
        } else if let project = LaunchOptions.openProject, !app.claimedLaunchProject {
            app.claimedLaunchProject = true
            router.openProject(named: project)
        }
        if let controller = router.controller, let data = savedState, LaunchOptions.openFiles == nil,
           let state = try? JSONDecoder().decode(WindowState.self, from: data) {
            controller.restore(state)
        }
    }

    @State private var persistTask: Task<Void, Never>?

    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        guard let controller = router.controller else {
            savedState = nil
            return
        }
        savedState = try? JSONEncoder().encode(controller.windowState)
    }
}
