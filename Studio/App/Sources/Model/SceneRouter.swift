import SwiftUI
import Observation
import StudioCore

/// Per-window state that exists whether or not a workspace is open: the
/// open workspace (if any), and the window's sheets. Every window publishes
/// its router as a focused *scene* value, so the menu bar always has a
/// target for the frontmost window, with or without a focused view and
/// with or without a hardware keyboard.
@MainActor
@Observable
final class SceneRouter {
    private(set) var controller: WorkspaceController?
    var isPickingFolder = false
    var isSettingsPresented = false
    var settingsPage: SettingsPage = .appearance
    var isNewProjectPresented = false
    var errorMessage: String?
    /// Set by the scene to persist which workspace the window shows.
    @ObservationIgnored var onReferenceChange: ((UUID?) -> Void)?

    let app: AppModel

    init(app: AppModel = .shared) {
        self.app = app
    }

    // MARK: Opening

    func open(_ reference: WorkspaceReference) {
        do {
            let resolved = try app.library.resolve(reference)
            app.library.markOpened(reference.id)
            show(Workspace(rootURL: resolved.url, reference: reference, resolved: resolved))
            onReferenceChange?(reference.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(referenceID: UUID) {
        guard controller?.workspace.reference?.id != referenceID else { return }
        if let reference = app.library.reference(id: referenceID) {
            open(reference)
        }
    }

    /// A folder picked in Files.
    func openFolder(_ url: URL) {
        do {
            open(try app.library.addFolder(url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openProject(named name: String) {
        open(app.library.reference(forProject: name))
    }

    func createProject(named name: String) {
        do {
            open(try app.library.createProject(named: name))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeWorkspace() {
        controller?.tearDown()
        controller = nil
        onReferenceChange?(nil)
    }

    private func show(_ workspace: Workspace) {
        controller?.tearDown()
        let controller = WorkspaceController(workspace: workspace, router: self)
        self.controller = controller
        Task { await controller.start() }
    }

    // MARK: Menu actions available in every window

    func showOpenFolder() { isPickingFolder = true }
    func showSettings(page: SettingsPage = .appearance) {
        settingsPage = page
        isSettingsPresented = true
    }
    func showNewProject() { isNewProjectPresented = true }
}

extension FocusedValues {
    /// The frontmost window's router (a scene value, never tied to a focused view).
    @Entry var sceneRouter: SceneRouter?
}
