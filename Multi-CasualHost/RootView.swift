import SwiftUI
import UserNotifications
import UIKit
import MultiCasual

struct RootView: View {
    @Environment(AuthSession.self) private var authSession
    @Environment(APIClient.self) private var api
    @Environment(\.appLanguage) private var appLanguage
    @State private var selectedTab: AppTab = AppTab.debugInitialTab

    enum AppTab: Hashable {
        case inbox, issues, myIssues, projects, settings

        static var debugInitialTab: AppTab {
            #if DEBUG
            switch ProcessInfo.processInfo.environment["MULTI_CASUAL_DEBUG_INITIAL_TAB"] {
            case "issues": return .issues
            case "my-issues": return .myIssues
            case "projects": return .projects
            case "settings": return .settings
            default: return .inbox
            }
            #else
            return .inbox
            #endif
        }
    }

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.environment["MULTI_CASUAL_DEBUG_FORCE_HTML_PREVIEW"] == "1" {
                HTMLAttachmentPreviewDebugScreen()
            } else if ProcessInfo.processInfo.environment["MULTI_CASUAL_DEBUG_FORCE_LOGIN_SCREEN"] == "1" {
                LoginView()
            } else if authSession.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authSession.isAuthenticated {
                mainTabView
                    .onReceive(NotificationCenter.default.publisher(for: .didRegisterPushToken)) { note in
                        guard let token = note.object as? String else { return }
                        let workspaceId = authSession.currentWorkspace?.id
                        Task { try? await api.registerPushToken(token, workspaceId: workspaceId) }
                    }
            } else {
                LoginView()
            }
            #else
            if authSession.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if authSession.isAuthenticated {
                mainTabView
                    .onReceive(NotificationCenter.default.publisher(for: .didRegisterPushToken)) { note in
                        guard let token = note.object as? String else { return }
                        let workspaceId = authSession.currentWorkspace?.id
                        Task { try? await api.registerPushToken(token, workspaceId: workspaceId) }
                    }
            } else {
                LoginView()
            }
            #endif
        }
        .onOpenURL { url in handleDeepLink(url) }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { InboxView() }
                .tabItem { Label(AppStrings.localized("Inbox", language: appLanguage), systemImage: "tray") }
                .tag(AppTab.inbox)

            NavigationStack { debugInitialIssueView }
                .tabItem { Label(AppStrings.localized("Issues", language: appLanguage), systemImage: "checklist") }
                .tag(AppTab.issues)

            NavigationStack { IssueListView(scope: .assignedToMe) }
                .tabItem { Label(AppStrings.localized("My Issues", language: appLanguage), systemImage: "person.crop.circle.badge.checkmark") }
                .tag(AppTab.myIssues)

            NavigationStack { debugInitialProjectView }
                .tabItem { Label(AppStrings.localized("Projects", language: appLanguage), systemImage: "folder") }
                .tag(AppTab.projects)

            NavigationStack { SettingsView() }
                .tabItem { Label(AppStrings.localized("Settings", language: appLanguage), systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onAppear { requestPushPermission() }
    }

    @ViewBuilder
    private var debugInitialIssueView: some View {
        #if DEBUG
        if let taskId = ProcessInfo.processInfo.environment["MULTI_CASUAL_DEBUG_INITIAL_TASK_ID"], !taskId.isEmpty {
            AgentTranscriptView(taskId: taskId, workspaceId: authSession.currentWorkspace?.id)
        } else if let issueId = ProcessInfo.processInfo.environment["MULTI_CASUAL_DEBUG_INITIAL_ISSUE_ID"], !issueId.isEmpty {
            IssueDetailView(issueId: issueId)
        } else {
            IssueListView()
        }
        #else
        IssueListView()
        #endif
    }

    @ViewBuilder
    private var debugInitialProjectView: some View {
        #if DEBUG
        if let projectId = ProcessInfo.processInfo.environment["MULTI_CASUAL_DEBUG_INITIAL_PROJECT_ID"], !projectId.isEmpty {
            DebugProjectDetailRoute(projectId: projectId)
        } else {
            ProjectsView()
        }
        #else
        ProjectsView()
        #endif
    }

    private func requestPushPermission() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MULTI_CASUAL_DEBUG_SKIP_PUSH_PROMPT"] == "1" {
            return
        }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == AppEnvironment.current.urlScheme else { return }
        switch url.host {
        case "inbox": selectedTab = .inbox
        case "issues": selectedTab = .issues
        case "my-issues": selectedTab = .myIssues
        default: break
        }
    }
}

#if DEBUG
private struct HTMLAttachmentPreviewDebugScreen: View {
    @Environment(\.openURL) private var openURL
    @State private var showSource = false

    var body: some View {
        NavigationStack {
            ZStack {
                HTMLAttachmentPreview(html: Self.fixtureHTML) { url in
                    openURL(url)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(showSource ? 0 : 1)
                .allowsHitTesting(!showSource)
                .accessibilityIdentifier("HTMLPreviewDebugRender")

                if showSource {
                    ScrollView([.vertical, .horizontal]) {
                        Text(Self.fixtureHTML)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding()
                    }
                    .background(Color(.systemBackground))
                    .accessibilityIdentifier("HTMLPreviewDebugSource")
                }
            }
            .navigationTitle("HTML Preview Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showSource ? "Render" : "Source") {
                        showSource.toggle()
                    }
                    .accessibilityIdentifier("HTMLPreviewDebugSourceToggle")
                }
            }
        }
    }

    private static let fixtureHTML = """
    <!doctype html>
    <html>
    <head>
      <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; padding: 24px; background: #fff7d6; color: #111; }
        h1 { margin-top: 0; }
        .tabs { display: flex; gap: 8px; margin-bottom: 16px; }
        button { border: 2px solid #111; background: white; padding: 10px 14px; font-weight: 700; border-radius: 8px; }
        button.active { background: #003cff; color: white; }
        .panel { border: 2px solid #111; padding: 18px; border-radius: 12px; background: white; min-height: 120px; }
        .hidden { display: none; }
      </style>
    </head>
    <body>
      <h1>HTML preview fixture</h1>
      <p id=\"status\">If this text is visible, WKWebView rendered HTML.</p>
      <div class=\"tabs\">
        <button id=\"tab-a\" class=\"active\" onclick=\"showTab('a')\">Tab A</button>
        <button id=\"tab-b\" onclick=\"showTab('b')\">Tab B</button>
      </div>
      <div id=\"panel-a\" class=\"panel\">Panel A: initial content.</div>
      <div id=\"panel-b\" class=\"panel hidden\">Panel B: JavaScript tab interaction works.</div>
      <script>
        function showTab(id) {
          document.getElementById('tab-a').classList.toggle('active', id === 'a');
          document.getElementById('tab-b').classList.toggle('active', id === 'b');
          document.getElementById('panel-a').classList.toggle('hidden', id !== 'a');
          document.getElementById('panel-b').classList.toggle('hidden', id !== 'b');
          document.getElementById('status').textContent = 'Clicked ' + id.toUpperCase();
        }
      </script>
    </body>
    </html>
    """
}
#endif

#if DEBUG
private struct DebugProjectDetailRoute: View {
    let projectId: String
    @Environment(AuthSession.self) private var authSession
    @Environment(APIClient.self) private var api
    @State private var project: Project?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let project {
                ProjectDetailView(project: project)
            } else if let errorMessage {
                ErrorRetryView(message: errorMessage) {
                    Task { await loadProject() }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Projects")
        .task { await loadProject() }
    }

    private func loadProject() async {
        do {
            errorMessage = nil
            let workspaceId = authSession.currentWorkspace?.id
            project = try await api.getProject(id: projectId, workspaceId: workspaceId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
