#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

public struct SettingsView: View {
    @Environment(AuthSession.self) private var authSession
    @Environment(AppLanguageSettings.self) private var languageSettings
    @Environment(\.appLanguage) private var appLanguage
    @State private var showingLogoutConfirmation = false

    public init() {}

    public var body: some View {
        List {
            Section(AppStrings.localized("Account", language: appLanguage)) {
                if let user = authSession.currentUser {
                    HStack {
                        AvatarView(name: user.name, avatarUrl: user.avatarUrl, kind: .user, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            MarkdownText(user.name).font(.body.bold())
                            MarkdownText(user.email).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
                if authSession.workspaces.isEmpty {
                    LabeledContent(
                        AppStrings.localized("Workspace", language: appLanguage),
                        value: AppStrings.localized("No workspace", language: appLanguage)
                    )
                } else {
                    Picker(AppStrings.localized("Workspace", language: appLanguage), selection: workspaceSelection) {
                        ForEach(authSession.workspaces) { workspace in
                            MarkdownText(workspace.name).tag(workspace.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("SettingsWorkspacePicker")
                    .accessibilityValue("Current workspace: \(authSession.currentWorkspace?.name ?? "None"). Workspace options loaded: \(authSession.workspaces.count)")
                }
            }

            Section(AppStrings.localized("Preferences", language: appLanguage)) {
                Picker(AppStrings.localized("Language", language: appLanguage), selection: languageSelection) {
                    ForEach(AppLanguage.allCases) { language in
                        MarkdownText(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("SettingsLanguagePicker")
            }

            Section(AppStrings.localized("Configure", language: appLanguage)) {
                NavigationLink(AppStrings.localized("Workspaces", language: appLanguage)) { WorkspaceAccessView() }
                NavigationLink(AppStrings.localized("Workspace Details", language: appLanguage)) { WorkspaceSettingsView() }
                NavigationLink(AppStrings.localized("Members", language: appLanguage)) { WorkspaceMembersView() }
                NavigationLink(AppStrings.localized("Notifications", language: appLanguage)) { NotificationPreferencesView() }
                NavigationLink(AppStrings.localized("API Tokens", language: appLanguage)) { PersonalAccessTokensView() }
                NavigationLink(AppStrings.localized("Labels", language: appLanguage)) { LabelsView() }
                NavigationLink(AppStrings.localized("Agents", language: appLanguage)) { AgentsView() }
                NavigationLink(AppStrings.localized("Squads", language: appLanguage)) { SquadsView() }
                NavigationLink(AppStrings.localized("Autopilots", language: appLanguage)) { AutopilotsView() }
                NavigationLink(AppStrings.localized("Runtimes", language: appLanguage)) { RuntimesView() }
                NavigationLink(AppStrings.localized("Skills", language: appLanguage)) { SkillsView() }
                NavigationLink(AppStrings.localized("Feedback", language: appLanguage)) { FeedbackView() }
            }

            Section {
                Button(AppStrings.localized("Log Out", language: appLanguage), role: .destructive) {
                    showingLogoutConfirmation = true
                }
            }
        }
        .navigationTitle(AppStrings.localized("Settings", language: appLanguage))
        .destructiveConfirmation(
            logoutConfirmation,
            isPresented: $showingLogoutConfirmation
        ) {
            Task {
                await WebSocketActor.shared.disconnect()
                authSession.logout()
            }
        }
    }

    private var logoutConfirmation: DestructiveConfirmation {
        DestructiveConfirmation.logout(workspaceName: authSession.currentWorkspace?.name)
    }

    private var workspaceSelection: Binding<String> {
        Binding(
            get: { authSession.currentWorkspace?.id ?? "" },
            set: { workspaceId in
                guard let workspace = authSession.workspaces.first(where: { $0.id == workspaceId }) else { return }
                authSession.setWorkspace(workspace)
            }
        )
    }

    private var languageSelection: Binding<AppLanguage> {
        Binding(
            get: { languageSettings.language },
            set: { languageSettings.language = $0 }
        )
    }
}

#endif
