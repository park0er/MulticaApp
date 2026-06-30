import Foundation
import Observation

public enum InboxBulkArchiveAction: Equatable, Sendable {
    case all
    case read
    case completed

    public var menuTitle: String {
        switch self {
        case .all: "Archive All"
        case .read: "Archive Read"
        case .completed: "Archive Completed"
        }
    }

    public var confirmationTitle: String {
        switch self {
        case .all: "Archive all notifications?"
        case .read: "Archive read notifications?"
        case .completed: "Archive completed notifications?"
        }
    }

    public var confirmationMessage: String {
        switch self {
        case .all: "All notifications will be removed from Inbox."
        case .read: "All read notifications will be removed from Inbox."
        case .completed: "Notifications for completed issues will be removed from Inbox."
        }
    }
}

@Observable
@MainActor
public final class InboxViewModel {
    public let loader = PaginatedLoader<InboxItem>()
    public var lastError: Error?
    public var unreadCount: Int = 0
    public var pendingArchiveItem: InboxItem?
    public var pendingBulkArchiveAction: InboxBulkArchiveAction?
    public var markingReadIds: Set<String> = []
    /// Workspace directory + presence for rendering actor avatars on rows.
    public private(set) var membersById: [String: WorkspaceMember] = [:]
    public private(set) var agentsById: [String: Agent] = [:]
    public private(set) var presenceByAgentId: [String: AgentPresenceSummary] = [:]
    private let pageSize = 50
    private let api: APIClient
    private let authSession: AuthSession

    public init(api: APIClient, authSession: AuthSession) {
        self.api = api
        self.authSession = authSession
    }

    /// Loads the member/agent directory + agent presence used to render row
    /// avatars. Best-effort: failures simply leave rows with a fallback glyph.
    public func loadDirectory() async {
        guard let workspaceId = authSession.currentWorkspace?.id else { return }
        async let membersResult = try? WorkspaceMetadataCache.shared.members(workspaceId: workspaceId, api: api)
        async let agentsResult = try? WorkspaceMetadataCache.shared.agents(workspaceId: workspaceId, includeArchived: true, api: api)
        async let presenceResult = WorkspaceMetadataCache.shared.agentPresence(workspaceId: workspaceId, api: api)
        let members = await membersResult ?? []
        let agents = await agentsResult ?? []
        membersById = Dictionary(members.map { ($0.userId, $0) }, uniquingKeysWith: { first, _ in first })
        agentsById = Dictionary(agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        presenceByAgentId = await presenceResult
    }

    public func actorName(for item: InboxItem) -> String {
        guard let id = item.avatarActorId else { return "" }
        if item.avatarActorType == "agent" { return agentsById[id]?.name ?? "Agent" }
        return membersById[id]?.name ?? "Member"
    }

    public func actorAvatarUrl(for item: InboxItem) -> String? {
        guard let id = item.avatarActorId else { return nil }
        if item.avatarActorType == "agent" { return agentsById[id]?.avatarUrl }
        return membersById[id]?.avatarUrl
    }

    public func actorPresence(for item: InboxItem) -> AgentPresenceSummary? {
        guard item.avatarActorType == "agent", let id = item.avatarActorId else { return nil }
        return presenceByAgentId[id]
    }

    public func loadNext() async {
        guard let workspace = authSession.currentWorkspace else {
            lastError = UserVisibleError("Pick a workspace before opening Inbox.")
            return
        }
        do {
            let pageSize = self.pageSize
            try await loader.loadNext { [api, workspace, pageSize] offset in
                return try await api.listInbox(
                    workspaceId: workspace.id,
                    workspaceSlug: workspace.slug,
                    limit: pageSize,
                    offset: offset
                )
            }
            loader.items = Self.deduplicateInboxItems(loader.items)
            lastError = nil
            updateUnreadCount()
        } catch {
            lastError = error
        }
        await loadDirectory()
    }

    /// Manual / pull-to-refresh path. The system `.refreshable` overlay shows
    /// its own spinner; we never clear the existing items. First-ever load
    /// (no data yet) falls through to the full load; otherwise refresh silently
    /// in place so the list never flashes empty.
    public func refresh() async {
        if loader.hasLoadedOnce {
            await silentRefresh()
        } else {
            loader.reset()
            await loadNext()
        }
    }

    /// Background auto-refresh (timer / scenePhase / workspace change). Pulls
    /// the first page and merges in place by id — never clears the list, never
    /// shows a spinner. UI MUST gate empty-state and spinner on `isLoading`
    /// (not `isRefreshing`).
    public func silentRefresh() async {
        guard let workspace = authSession.currentWorkspace, !loader.isRefreshing else { return }
        let pageSize = self.pageSize
        do {
            try await loader.silentRefreshFirstPage { [api, workspace, pageSize] offset in
                try await api.listInbox(
                    workspaceId: workspace.id,
                    workspaceSlug: workspace.slug,
                    limit: pageSize,
                    offset: offset
                )
            }
            loader.items = Self.deduplicateInboxItems(loader.items)
            lastError = nil
            updateUnreadCount()
        } catch {
            // Silent failure: keep existing items, do not flash an error for a
            // background refresh. A subsequent refresh retries.
        }
        await loadDirectory()
    }

    public func refreshIfIdle() async {
        guard !loader.isLoading else { return }
        guard !loader.isLoading, !loader.isRefreshing else { return }
        await silentRefresh()
    }

    public func markRead(id: String) async {
        guard let workspace = authSession.currentWorkspace else {
            lastError = UserVisibleError("Pick a workspace before updating Inbox.")
            return
        }
        do {
            let updated = try await api.markInboxRead(id: id, workspaceId: workspace.id, workspaceSlug: workspace.slug)
            if let index = loader.items.firstIndex(where: { $0.id == id }) {
                loader.items[index] = updated
            }
            updateUnreadCount()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    public func markReadIfNeeded(id: String) async {
        guard let index = loader.items.firstIndex(where: { $0.id == id }),
              !loader.items[index].read,
              !markingReadIds.contains(id)
        else { return }
        guard let workspace = authSession.currentWorkspace else {
            lastError = UserVisibleError("Pick a workspace before updating Inbox.")
            return
        }

        let previousItem = loader.items[index]
        loader.items[index] = Self.markedRead(previousItem)
        updateUnreadCount()
        markingReadIds.insert(id)
        defer { markingReadIds.remove(id) }

        do {
            let updated = try await api.markInboxRead(id: id, workspaceId: workspace.id, workspaceSlug: workspace.slug)
            if let updatedIndex = loader.items.firstIndex(where: { $0.id == id }) {
                loader.items[updatedIndex] = updated
            }
            updateUnreadCount()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    public func markAllRead() async {
        guard let workspace = authSession.currentWorkspace else {
            lastError = UserVisibleError("Pick a workspace before updating Inbox.")
            return
        }
        do {
            _ = try await api.markAllInboxRead(workspaceId: workspace.id, workspaceSlug: workspace.slug)
            loader.items = loader.items.map(Self.markedRead)
            updateUnreadCount()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    public func requestArchive(id: String) {
        pendingArchiveItem = loader.items.first { $0.id == id }
    }

    public func cancelPendingArchive() {
        pendingArchiveItem = nil
    }

    public func requestBulkArchive(_ action: InboxBulkArchiveAction) {
        pendingBulkArchiveAction = action
    }

    public func cancelPendingBulkArchive() {
        pendingBulkArchiveAction = nil
    }

    public func confirmPendingArchive() async {
        guard let item = pendingArchiveItem else { return }
        await archive(id: item.id)
        pendingArchiveItem = nil
    }

    public func confirmPendingBulkArchive() async {
        guard let action = pendingBulkArchiveAction else { return }
        await archiveBulk(action)
        pendingBulkArchiveAction = nil
    }

    public var pendingArchiveConfirmation: DestructiveConfirmation {
        DestructiveConfirmation.archiveInboxItem(issueTitle: pendingArchiveItem?.issueTitle ?? "")
    }

    public var pendingBulkArchiveConfirmation: DestructiveConfirmation {
        DestructiveConfirmation.archiveInboxBulk(pendingBulkArchiveAction ?? .all)
    }

    private func archive(id: String) async {
        guard let workspace = authSession.currentWorkspace else {
            lastError = UserVisibleError("Pick a workspace before updating Inbox.")
            return
        }
        do {
            _ = try await api.archiveInbox(id: id, workspaceId: workspace.id, workspaceSlug: workspace.slug)
            loader.items.removeAll { $0.id == id }
            updateUnreadCount()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    private func archiveBulk(_ action: InboxBulkArchiveAction) async {
        guard let workspace = authSession.currentWorkspace else {
            lastError = UserVisibleError("Pick a workspace before updating Inbox.")
            return
        }
        do {
            switch action {
            case .all:
                _ = try await api.archiveAllInbox(workspaceId: workspace.id, workspaceSlug: workspace.slug)
                loader.items.removeAll()
            case .read:
                _ = try await api.archiveAllReadInbox(workspaceId: workspace.id, workspaceSlug: workspace.slug)
                loader.items.removeAll { $0.read }
            case .completed:
                _ = try await api.archiveCompletedInbox(workspaceId: workspace.id, workspaceSlug: workspace.slug)
                loader.items.removeAll { $0.issueStatus == .done }
            }
            updateUnreadCount()
            lastError = nil
        } catch {
            lastError = error
        }
    }

    private func updateUnreadCount() {
        unreadCount = loader.items.filter { !$0.read && !$0.archived }.count
    }

    private static func markedRead(_ item: InboxItem) -> InboxItem {
        InboxItem(
            id: item.id,
            issueId: item.issueId,
            issueIdentifier: item.issueIdentifier,
            issueTitle: item.issueTitle,
            type: item.type,
            body: item.body,
            severity: item.severity,
            issueStatus: item.issueStatus,
            read: true,
            archived: item.archived,
            createdAt: item.createdAt
        )
    }

    private static func deduplicateInboxItems(_ items: [InboxItem]) -> [InboxItem] {
        let active = items.filter { !$0.archived }
        let groups = Dictionary(grouping: active) { item in
            item.issueId.isEmpty ? item.id : item.issueId
        }

        return groups.values.compactMap { group in
            group.max { $0.createdAt < $1.createdAt }
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}
