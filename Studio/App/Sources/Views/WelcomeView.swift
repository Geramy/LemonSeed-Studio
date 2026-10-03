import SwiftUI
import StudioCore
import StudioDesign

/// The window before a workspace opens: open a folder from Files, create
/// a project, or pick up a recent workspace.
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    @Environment(\.openWindow) private var openWindow
    let router: SceneRouter
    @State private var projects: [URL] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                header
                actions
                if !app.library.recents.isEmpty { recents }
                if !unlistedProjects.isEmpty { projectsSection }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.xxxl + Space.l)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(backdrop)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome")
        .task { projects = app.library.projects() }
        .onChange(of: app.library.recents) { _, _ in projects = app.library.projects() }
    }

    private var backdrop: some View {
        ZStack {
            theme.palette.canvas.color
            RadialGradient(colors: [theme.palette.accentFill.opacity(theme.appearance == .dark ? 0.10 : 0.16).color, .clear],
                           center: .topLeading, startRadius: 20, endRadius: 700)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.l) {
            LemonMark(size: 64)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("LemonSeed Studio")
                    .font(.system(size: 34, weight: .semibold, design: .default))
                    .tracking(-0.4)
                    .foregroundStyle(theme.palette.textPrimary.color)
                Text("Write, build and run code on iPad, with a desktop GPU beside you.")
                    .font(.studio(type.body + 1))
                    .foregroundStyle(theme.palette.textSecondary.color)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Space.m) {
            ActionCard(symbol: StudioSymbol.filesApp, title: "Open Folder", detail: "From Files, iCloud Drive or a drive",
                       shortcut: "⌘O", identifier: "welcome.openFolder") { router.showOpenFolder() }
            ActionCard(symbol: "plus.square.on.square", title: "New Project", detail: "An empty folder in Projects",
                       shortcut: nil, identifier: "welcome.newProject") { router.showNewProject() }
            ActionCard(symbol: StudioSymbol.settings, title: "Settings", detail: "Theme, fonts, keys, model",
                       shortcut: "⌘,", identifier: "welcome.settings") { router.showSettings() }
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            StudioSectionHeader("Recent")
            VStack(spacing: 0) {
                ForEach(app.library.recents) { reference in
                    RecentRow(reference: reference) {
                        router.open(reference)
                    }
                    .contextMenu {
                        Button("Open", systemImage: "arrow.up.forward.app") { router.open(reference) }
                        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
                            openWindow(id: StudioScenes.workspace, value: reference.id)
                        }
                        Divider()
                        Button("Remove from Recents", systemImage: "minus.circle", role: .destructive) {
                            app.library.remove(reference.id)
                        }
                    }
                    if reference.id != app.library.recents.last?.id {
                        Hairline().padding(.leading, 52)
                    }
                }
            }
            .elevatedSurface(cornerRadius: Radius.l)
        }
    }

    /// Projects not already shown under Recent.
    private var unlistedProjects: [URL] {
        let listed = Set(app.library.recents.compactMap { reference -> String? in
            if case .project(let name) = reference.location { return name }
            return nil
        })
        return projects.filter { !listed.contains($0.lastPathComponent) }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            StudioSectionHeader("Projects on this iPad")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Space.m)], spacing: Space.m) {
                ForEach(unlistedProjects, id: \.self) { url in
                    Button {
                        router.openProject(named: url.lastPathComponent)
                    } label: {
                        HStack(spacing: Space.s) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(theme.syntax.function.color)
                            Text(url.lastPathComponent)
                                .font(.studio(type.body, weight: .medium))
                                .foregroundStyle(theme.palette.textPrimary.color)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(Space.m)
                        .frame(minHeight: 52)
                        .elevatedSurface()
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.lift)
                    .accessibilityIdentifier("welcome.project.\(url.lastPathComponent)")
                }
            }
        }
    }
}

private struct ActionCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let symbol: String
    let title: String
    let detail: String
    let shortcut: String?
    let identifier: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(theme.palette.accent.color)
                        .frame(width: 36, height: 36)
                        .background(theme.palette.accentWash.color, in: RoundedRectangle(cornerRadius: Radius.s + 2, style: .continuous))
                    Spacer()
                    if let shortcut { KeyCaps(shortcut) }
                }
                Spacer(minLength: Space.s)
                Text(title)
                    .font(.studio(type.body + 1, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary.color)
                Text(detail)
                    .font(.studio(type.caption))
                    .foregroundStyle(theme.palette.textSecondary.color)
                    .lineLimit(2)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, minHeight: 136, alignment: .leading)
            .background(hovering ? theme.palette.elevated.mixed(with: theme.palette.textPrimary, 0.04).color : theme.palette.elevated.color,
                        in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .strokeBorder(hovering ? theme.palette.accent.opacity(0.45).color : theme.palette.hairline.color, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        }
        .buttonStyle(.plain)
        .studioHover($hovering)
        .hoverEffect(.lift)
        .accessibilityIdentifier(identifier)
    }
}

private struct RecentRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.typeScale) private var type
    let reference: WorkspaceReference
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                Image(systemName: reference.isProject ? "folder.fill" : "externaldrive.fill.badge.icloud")
                    .font(.system(size: 18))
                    .foregroundStyle(reference.isProject ? theme.syntax.function.color : theme.syntax.type.color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reference.displayName)
                        .font(.studio(type.body, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary.color)
                    Text(reference.locationDescription)
                        .font(.studio(type.caption))
                        .foregroundStyle(theme.palette.textTertiary.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(reference.lastOpened, format: .relative(presentation: .named))
                    .font(.studio(type.caption))
                    .foregroundStyle(theme.palette.textTertiary.color)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.textTertiary.color)
            }
            .padding(.horizontal, Space.l)
            .frame(minHeight: 60)
            .background(hovering ? theme.palette.hover.color : .clear)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .studioHover($hovering)
        .accessibilityIdentifier("welcome.recent.\(reference.displayName)")
    }
}
