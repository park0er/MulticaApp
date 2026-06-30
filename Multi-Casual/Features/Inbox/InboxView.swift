#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

public struct InboxView: View {
    @Environment(APIClient.self) private var api
    @Environment(AuthSession.self) private var authSession
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: InboxViewModel?
    @State private var observedWorkspaceId: String?
    @State private var showingArchiveConfirmation = false
    @State private var showingBulkArchiveConfirmation = false
    @State private var autoRefreshTask: Task<Void, Never>?

    private let autoRefreshIntervalNanoseconds: UInt64 = 30_000_000_000

    public init() {}

    public var body: some View {
        Group {
            if let vm = viewModel {
                List {
                    // Empty state only when a first load has finished with no items —
                    // never during a background silent refresh (which never clears
                    // items anyway), so the list never flashes empty.
                    if vm.loader.items.isEmpty && !vm.loader.hasMore && !vm.loader.isLoading
                        && !vm.loader.isRefreshing && vm.lastError == nil {
                        ContentUnavailableView(
                            AppStrings.localized("No Inbox Items", language: appLanguage),
                            systemImage: "tray",
                            description: Text(AppStrings.localized("There are no active notifications in this workspace.", language: appLanguage))
                        )
                    }
                    ForEach(vm.loader.items) { item in
                        NavigationLink {
                            IssueDetailView(issueId: item.issueId)
                                .task { await vm.markReadIfNeeded(id: item.id) }
                        } label: {
                            InboxRow(
                                item: item,
                                actorName: vm.actorName(for: item),
                                actorAvatarUrl: vm.actorAvatarUrl(for: item),
                                actorKind: item.avatarActorType == "agent" ? .agent : .user,
                                actorStatusDot: vm.actorPresence(for: item)?.avatarStatusDot
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                vm.requestArchive(id: item.id)
                                showingArchiveConfirmation = vm.pendingArchiveItem != nil
                            } label: {
                                Label(AppStrings.localized("Archive", language: appLanguage), systemImage: "archivebox")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if !item.read {
                                Button {
                                    Task { await vm.markRead(id: item.id) }
                                } label: {
                                    Label(AppStrings.localized("Read", language: appLanguage), systemImage: "envelope.open")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                    if vm.loader.hasMore {
                        ProgressView().onAppear { Task { await vm.loadNext() } }
                    }
                    if let error = vm.lastError {
                        ErrorRetryView(message: error.localizedDescription) {
                            Task { await vm.refresh() }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await vm.refresh() }
                .destructiveConfirmation(
                    vm.pendingArchiveConfirmation,
                    isPresented: $showingArchiveConfirmation
                ) {
                    Task { await vm.confirmPendingArchive() }
                } onCancel: {
                    vm.cancelPendingArchive()
                }
                .destructiveConfirmation(
                    vm.pendingBulkArchiveConfirmation,
                    isPresented: $showingBulkArchiveConfirmation
                ) {
                    Task { await vm.confirmPendingBulkArchive() }
                } onCancel: {
                    vm.cancelPendingBulkArchive()
                }
            } else { ProgressView() }
        }
        .navigationTitle(AppStrings.localized("Inbox", language: appLanguage))
        .toolbar {
            if let vm = viewModel {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        ChatView()
                    } label: {
                        Label(AppStrings.localized("Chat", language: appLanguage), systemImage: "message")
                    }
                    .accessibilityIdentifier("InboxChatButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await vm.markAllRead() }
                        } label: {
                            Label(AppStrings.localized("Mark All Read", language: appLanguage), systemImage: "envelope.open")
                        }
                        .disabled(vm.unreadCount == 0 || vm.loader.isLoading)
                        .accessibilityIdentifier("InboxMarkAllReadButton")

                        Button(role: .destructive) {
                            vm.requestBulkArchive(.read)
                            showingBulkArchiveConfirmation = true
                        } label: {
                            MarkdownIconLabel(AppStrings.localized(InboxBulkArchiveAction.read.menuTitle, language: appLanguage), systemImage: "archivebox")
                        }
                        .disabled(!vm.loader.items.contains { $0.read } || vm.loader.isLoading)

                        Button(role: .destructive) {
                            vm.requestBulkArchive(.completed)
                            showingBulkArchiveConfirmation = true
                        } label: {
                            MarkdownIconLabel(AppStrings.localized(InboxBulkArchiveAction.completed.menuTitle, language: appLanguage), systemImage: "checkmark.circle")
                        }
                        .disabled(!vm.loader.items.contains { $0.issueStatus == .done } || vm.loader.isLoading)

                        Button(role: .destructive) {
                            vm.requestBulkArchive(.all)
                            showingBulkArchiveConfirmation = true
                        } label: {
                            MarkdownIconLabel(AppStrings.localized(InboxBulkArchiveAction.all.menuTitle, language: appLanguage), systemImage: "archivebox.fill")
                        }
                        .disabled(vm.loader.items.isEmpty || vm.loader.isLoading)
                    } label: {
                        Label(AppStrings.localized("Inbox Actions", language: appLanguage), systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("InboxActionsMenu")
                }
            }
        }
        .onAppear {
            if viewModel == nil {
                observedWorkspaceId = authSession.currentWorkspace?.id
                viewModel = InboxViewModel(api: api, authSession: authSession)
                Task { await viewModel?.loadNext() }
            }
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .onChange(of: authSession.currentWorkspace?.id) { _, newValue in
            guard observedWorkspaceId != newValue else { return }
            observedWorkspaceId = newValue
            Task { await viewModel?.refresh() }
            startAutoRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await viewModel?.refreshIfIdle() }
                startAutoRefresh()
            default:
                stopAutoRefresh()
            }
        }
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        autoRefreshTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: autoRefreshIntervalNanoseconds)
                } catch {
                    break
                }
                if Task.isCancelled { break }
                await viewModel?.refreshIfIdle()
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }
}

private struct InboxRow: View {
    let item: InboxItem
    var actorName: String = ""
    var actorAvatarUrl: String? = nil
    var actorKind: AvatarView.Kind = .user
    var actorStatusDot: AvatarView.StatusDot? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: actorName, avatarUrl: actorAvatarUrl, kind: actorKind, size: 30, statusDot: actorStatusDot)
                .padding(.top, 2)
            content
        }
        .padding(.vertical, 6)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let identifier = displayIdentifier {
                    MarkdownText(identifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                MarkdownText(displayType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                MarkdownText(item.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(item.read ? Color.clear : Color.accentColor)
                    .frame(width: 8, height: 8)
                    .overlay {
                        if item.read {
                            Circle().stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                        }
                    }
                MarkdownText(item.issueTitle)
                    .fontWeight(item.read ? .regular : .semibold)
                    .lineLimit(2)
            }

            if let body = item.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                MarkdownText(body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                MarkdownText(item.read ? "Read" : "Unread")
                if item.issueStatus != .unknown {
                    MarkdownText(item.issueStatus.displayName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var displayType: String {
        item.type
            .split(separator: "_")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private var displayIdentifier: String? {
        guard !item.issueIdentifier.isEmpty, item.issueIdentifier != item.issueId else { return nil }
        return item.issueIdentifier
    }
}
#endif
