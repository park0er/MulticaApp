import Foundation
import Observation

@Observable
@MainActor
public final class IssueListViewModel {
    public enum Scope: String, CaseIterable, Identifiable {
        case all
        case assignedToMe
        case createdByMe
        case myAgents

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .all: return "All"
            case .assignedToMe: return "Assigned"
            case .createdByMe: return "Created"
            case .myAgents: return "My Agents"
            }
        }

        public var emptyTitle: String {
            switch self {
            case .all: return "No Issues"
            case .assignedToMe: return "No Assigned Issues"
            case .createdByMe: return "No Created Issues"
            case .myAgents: return "No Agent Issues"
            }
        }

        public var emptyDescription: String {
            switch self {
            case .all:
                return "There are no issues in this workspace."
            case .assignedToMe:
                return "Issues assigned to you will appear here."
            case .createdByMe:
                return "Issues you create will appear here."
            case .myAgents:
                return "Issues assigned to agents you own will appear here."
            }
        }

        public var isPersonal: Bool { self != .all }
    }

    public enum ViewMode { case list, board }
    public enum SortOption: String, CaseIterable {
        case position
        case number
        case priority
        case updated
        case created
        case title

        public var displayName: String {
            switch self {
            case .position: return "Default"
            case .number: return "Number"
            case .priority: return "Priority"
            case .updated: return "Updated"
            case .created: return "Created"
            case .title: return "Title"
            }
        }
    }

    public enum SortDirection: String, CaseIterable {
        case ascending
        case descending

        public var displayName: String {
            switch self {
            case .ascending: return "Ascending"
            case .descending: return "Descending"
            }
        }

        public var icon: String {
            switch self {
            case .ascending: return "arrow.up"
            case .descending: return "arrow.down"
            }
        }
    }

    public static let pageSize = 50
    public let loader = PaginatedLoader<Issue>()
    public var viewMode: ViewMode = .list
    public var showCreateSheet = false
    public var lastError: Error?
    public var priorityFilter: IssuePriority?
    public var searchQuery = ""
    public var isSearching: Bool { !searchQuery.isEmpty }
    public var searchResults: [Issue] { loader.items }
    public var scope: Scope
    public var isSelectionMode = false
    public var isLoadingBatchAssignees = false
    public private(set) var batchAssigneeOptions: [IssueAssigneeOption] = []
    public private(set) var selectedIssueIds: Set<String> = []
    public private(set) var sortOption: SortOption = .position
    public private(set) var sortDirection: SortDirection = .ascending
    public private(set) var issuesByStatus: [IssueStatus: [Issue]] = [:]
    public private(set) var childProgressByParentIssueId: [String: ChildIssueProgressEntry] = [:]

    private let api: APIClient
    private let authSession: AuthSession
    private var offsetsByStatus: [IssueStatus: Int] = [:]
    private var totalsByStatus: [IssueStatus: Int] = [:]
    private var pageHasMoreByStatus: [IssueStatus: Bool] = [:]
    private var isLoading = false
    /// True while a background silent refresh is in flight. UI MUST NOT show a
    /// spinner or empty state while this is true — existing items stay on screen.
    public private(set) var isRefreshing = false
    private var pendingLoadAfterCurrent = false
    private var hasLoadedFirstPages = false
    private var searchSourceOffset = 0

    private struct ServerFilter {
        var assigneeId: String?
        var assigneeIds: [String]?
        var creatorId: String?
        var matchesNothing = false
    }

    public init(api: APIClient, authSession: AuthSession, scope: Scope = .all) {
        self.api = api
        self.authSession = authSession
        self.scope = scope
    }

    public func loadNext() async {
        guard let wsId = authSession.currentWorkspace?.id else {
            lastError = UserVisibleError("Pick a workspace before opening Issues.")
            return
        }
        guard loader.hasMore else { return }
        if isLoading {
            pendingLoadAfterCurrent = true
            return
        }
        isLoading = true
        do {
            if !searchQuery.isEmpty {
                try await loadSearchPage(workspaceId: wsId)
            } else if !hasLoadedFirstPages {
                try await loadFirstPages(workspaceId: wsId)
            } else if let status = nextStatusWithMore() {
                let offset = offsetsByStatus[status, default: 0]
                let filter = try await serverFilter(workspaceId: wsId)
                if filter.matchesNothing {
                    loader.hasMore = false
                } else {
                    let page = try await api.listIssues(
                        workspaceId: wsId,
                        status: status,
                        priority: priorityFilter,
                        assigneeId: filter.assigneeId,
                        assigneeIds: filter.assigneeIds,
                        creatorId: filter.creatorId,
                        limit: Self.pageSize,
                        offset: offset
                    )
                    append(page, for: status)
                }
            } else {
                loader.hasMore = false
            }
            lastError = nil
        } catch {
            if Self.isCancellation(error) || pendingLoadAfterCurrent {
                if pendingLoadAfterCurrent {
                    loader.hasMore = true
                } else {
                    loader.hasMore = false
                }
                lastError = nil
            } else {
                loader.hasMore = false
                lastError = error
            }
        }
        isLoading = false
        if pendingLoadAfterCurrent {
            pendingLoadAfterCurrent = false
            await loadNext()
        }
    }

    /// Deliberate reload for context switches (workspace / scope / filter /
    /// create). Fetches fresh first pages into temp buckets, then swaps the
    /// live state atomically — the list never shows an empty window while the
    /// fetch is in flight (old data stays until the new data is ready).
    public func refresh() async {
        guard let wsId = authSession.currentWorkspace?.id else {
            lastError = UserVisibleError("Pick a workspace before opening Issues.")
            return
        }
        guard !isSearching else { return }
        do {
            try await reloadFirstPages(workspaceId: wsId)
            lastError = nil
        } catch {
            lastError = error
        }
    }

    /// Pull-to-refresh: the system `.refreshable` overlay shows its own spinner.
    /// Merges the first page in place (keeps already-loaded deeper pages) and
    /// never clears the list. Falls back to a first load if nothing is loaded.
    public func pullToRefresh() async {
        if hasLoadedFirstPages {
            await silentRefresh()
        } else {
            await loadNext()
        }
    }

    /// Background auto-refresh (timer / scenePhase). Re-fetches the first page
    /// of every status and merges in place by id — never clears the list, never
    /// shows a spinner. Already-loaded deeper pages are preserved; pagination
    /// cursors reset to the fresh first page so "load more" stays correct.
    public func silentRefresh() async {
        guard let wsId = authSession.currentWorkspace?.id else { return }
        guard !isRefreshing, !isSearching, !isLoading else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let filter = try await serverFilter(workspaceId: wsId)
            guard !filter.matchesNothing else { return }
            for status in IssueStatus.listCases {
                let page = try await api.listIssues(
                    workspaceId: wsId,
                    status: status,
                    priority: priorityFilter,
                    assigneeId: filter.assigneeId,
                    assigneeIds: filter.assigneeIds,
                    creatorId: filter.creatorId,
                    limit: Self.pageSize,
                    offset: 0
                )
                mergeFirstPage(page, for: status)
            }
            try await loadChildProgress(workspaceId: wsId)
            syncFlatIssues()
            lastError = nil
        } catch {
            // Silent failure: keep existing items. A subsequent refresh retries.
        }
    }

    public func refreshIfIdle() async {
        guard !isRefreshing, !isSearching else { return }
        await silentRefresh()
    }

    public func setSearchQuery(_ query: String) async {
        guard scope == .all else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != searchQuery else { return }
        searchQuery = trimmed
        resetPagination()
        await loadNext()
    }

    public func setScope(_ nextScope: Scope) async {
        guard nextScope != scope, nextScope != .all else { return }
        scope = nextScope
        clearSelection()
        resetPagination()
        await loadNext()
    }

    public func setSortOption(_ option: SortOption) {
        sortOption = option
        syncFlatIssues()
    }

    public func setSortDirection(_ direction: SortDirection) {
        sortDirection = direction
        syncFlatIssues()
    }

    public func setPriorityFilter(_ priority: IssuePriority?) async {
        priorityFilter = priority
        await refresh()
    }

    public func toggleSelection(issueId: String) {
        if selectedIssueIds.contains(issueId) {
            selectedIssueIds.remove(issueId)
        } else {
            selectedIssueIds.insert(issueId)
        }
        if selectedIssueIds.isEmpty {
            isSelectionMode = false
        }
    }

    public func clearSelection() {
        selectedIssueIds.removeAll()
        isSelectionMode = false
    }

    public func batchUpdateSelected(
        status: IssueStatus? = nil,
        priority: IssuePriority? = nil,
        assigneeType: String? = nil,
        assigneeId: String? = nil
    ) async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            lastError = UserVisibleError("Pick a workspace before updating Issues.")
            return
        }
        let ids = selectedIssueIds.sorted()
        guard !ids.isEmpty else { return }
        do {
            _ = try await api.batchUpdateIssues(
                ids: ids,
                workspaceId: workspaceId,
                status: status,
                priority: priority,
                assigneeType: assigneeType,
                assigneeId: assigneeId
            )
            applyBatchUpdate(ids: Set(ids), status: status, priority: priority, assigneeType: assigneeType, assigneeId: assigneeId)
            clearSelection()
            lastError = nil
            for id in ids {
                await DataStore.shared.invalidateIssue(id)
            }
        } catch {
            lastError = error
        }
    }

    public func loadBatchAssigneeOptions() async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            lastError = UserVisibleError("Pick a workspace before updating Issues.")
            return
        }
        guard !isLoadingBatchAssignees else { return }

        isLoadingBatchAssignees = true
        defer { isLoadingBatchAssignees = false }

        do {
            async let members = WorkspaceMetadataCache.shared.members(workspaceId: workspaceId, api: api)
            async let agents = WorkspaceMetadataCache.shared.agents(workspaceId: workspaceId, api: api)
            async let squads = WorkspaceMetadataCache.shared.squads(workspaceId: workspaceId, api: api)

            let loadedMembers = try await members
            let loadedAgents = try await agents
            let loadedSquads = try await squads
            batchAssigneeOptions = loadedMembers.map {
                IssueAssigneeOption(
                    id: "member:\($0.userId)",
                    type: "member",
                    assigneeId: $0.userId,
                    displayName: $0.name,
                    subtitle: $0.email
                )
            } + loadedAgents.map {
                IssueAssigneeOption(
                    id: "agent:\($0.id)",
                    type: "agent",
                    assigneeId: $0.id,
                    displayName: $0.name,
                    subtitle: "Agent"
                )
            } + loadedSquads.map {
                IssueAssigneeOption(
                    id: "squad:\($0.id)",
                    type: "squad",
                    assigneeId: $0.id,
                    displayName: $0.name,
                    subtitle: $0.description.isEmpty ? "Squad" : "Squad · \($0.description)"
                )
            }
            lastError = nil
        } catch {
            lastError = error
        }
    }

    public func batchAssignSelected(optionId: String) async {
        if batchAssigneeOptions.isEmpty {
            await loadBatchAssigneeOptions()
        }
        guard let option = batchAssigneeOptions.first(where: { $0.id == optionId }) else { return }
        await batchUpdateSelected(assigneeType: option.type, assigneeId: option.assigneeId)
    }

    public func batchDeleteSelected() async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            lastError = UserVisibleError("Pick a workspace before updating Issues.")
            return
        }
        let ids = selectedIssueIds.sorted()
        guard !ids.isEmpty else { return }
        do {
            _ = try await api.batchDeleteIssues(ids: ids, workspaceId: workspaceId)
            removeIssues(withIds: Set(ids))
            clearSelection()
            lastError = nil
            for id in ids {
                await DataStore.shared.invalidateIssue(id)
            }
        } catch {
            lastError = error
        }
    }

    public func updateStatus(issueId: String, to status: IssueStatus) async {
        guard let wsId = authSession.currentWorkspace?.id else {
            lastError = UserVisibleError("Pick a workspace before updating Issues.")
            return
        }
        do {
            let updated = try await api.updateIssue(id: issueId, workspaceId: wsId, status: status)
            replaceIssue(updated)
            lastError = nil
            await DataStore.shared.invalidateIssue(issueId)
        } catch {
            lastError = error
        }
    }

    public func moveIssue(issueId: String, to status: IssueStatus, beforeIssueId: String? = nil) async {
        guard IssueStatus.boardCases.contains(status) else { return }
        guard let wsId = authSession.currentWorkspace?.id else {
            lastError = UserVisibleError("Pick a workspace before updating Issues.")
            return
        }
        guard let currentIssue = IssueStatus.listCases
            .compactMap({ issuesByStatus[$0]?.first(where: { $0.id == issueId }) })
            .first
        else { return }
        var targetIssues = issuesByStatus[status, default: []].filter { $0.id != issueId }
        let insertIndex: Int
        if let beforeIssueId, let targetIndex = targetIssues.firstIndex(where: { $0.id == beforeIssueId }) {
            insertIndex = targetIndex
        } else {
            insertIndex = targetIssues.count
        }

        let movedIssue = currentIssue.replacing(
            status: status,
            priority: currentIssue.priority,
            assigneeType: currentIssue.assigneeType,
            assigneeId: currentIssue.assigneeId,
            position: insertIndex
        )
        targetIssues.insert(movedIssue, at: min(insertIndex, targetIssues.count))

        let previousBuckets = issuesByStatus
        for bucketStatus in IssueStatus.listCases {
            issuesByStatus[bucketStatus]?.removeAll { $0.id == issueId }
        }
        issuesByStatus[status] = renumbered(targetIssues)
        resetPaginationCountsFromBuckets()
        syncFlatIssues()

        do {
            let updated = try await api.updateIssue(id: issueId, workspaceId: wsId, status: status, position: insertIndex)
            replaceIssue(updated, preferredIndex: insertIndex)
            lastError = nil
            await DataStore.shared.invalidateIssue(issueId)
        } catch {
            issuesByStatus = previousBuckets
            resetPaginationCountsFromBuckets()
            syncFlatIssues()
            lastError = error
        }
    }

    public func issues(for status: IssueStatus) -> [Issue] {
        sorted(issuesByStatus[status] ?? [])
    }

    public func childProgressText(for issue: Issue) -> String? {
        guard let progress = childProgressByParentIssueId[issue.id], progress.total > 0 else {
            return nil
        }
        return "\(progress.done)/\(progress.total)"
    }

    private func loadFirstPages(workspaceId: String) async throws {
        resetBuckets()
        let filter = try await serverFilter(workspaceId: workspaceId)
        if filter.matchesNothing {
            hasLoadedFirstPages = true
            syncFlatIssues()
            return
        }
        for status in IssueStatus.listCases {
            let page = try await api.listIssues(
                workspaceId: workspaceId,
                status: status,
                priority: priorityFilter,
                assigneeId: filter.assigneeId,
                assigneeIds: filter.assigneeIds,
                creatorId: filter.creatorId,
                limit: Self.pageSize,
                offset: 0
            )
            append(page, for: status)
        }
        try await loadChildProgress(workspaceId: workspaceId)
        hasLoadedFirstPages = true
        syncFlatIssues()
    }

    private func serverFilter(workspaceId: String) async throws -> ServerFilter {
        switch scope {
        case .all:
            return ServerFilter()
        case .assignedToMe:
            guard let userId = authSession.currentUser?.id else {
                throw UserVisibleError("Sign in before opening My Issues.")
            }
            return ServerFilter(assigneeId: userId)
        case .createdByMe:
            guard let userId = authSession.currentUser?.id else {
                throw UserVisibleError("Sign in before opening My Issues.")
            }
            return ServerFilter(creatorId: userId)
        case .myAgents:
            guard let userId = authSession.currentUser?.id else {
                throw UserVisibleError("Sign in before opening My Issues.")
            }
            let agentIds = try await WorkspaceMetadataCache.shared.agents(workspaceId: workspaceId, api: api)
                .filter { $0.ownerId == userId }
                .map(\.id)
                .sorted()
            guard !agentIds.isEmpty else {
                return ServerFilter(matchesNothing: true)
            }
            return ServerFilter(assigneeIds: agentIds)
        }
    }

    private func loadSearchPage(workspaceId: String) async throws {
        let query = searchQuery
        let plan = searchPlan(for: query)
        let offset = plan.requiresLocalFilter ? searchSourceOffset : loader.items.count
        loader.isLoading = true
        defer { loader.isLoading = false }
        let page = try await api.searchIssues(
            workspaceId: workspaceId,
            query: plan.serverQuery,
            limit: Self.pageSize,
            offset: offset,
            includeClosed: true
        )
        guard searchQuery == query else { return }
        let visibleItems = plan.requiresLocalFilter
            ? page.items.filter { issueMatches($0, query: query) }
            : page.items
        loader.items.append(contentsOf: visibleItems)
        if plan.requiresLocalFilter {
            searchSourceOffset = offset + page.items.count
        }
        loader.hasMore = page.inferringHasMore(fromOffset: offset).hasMore
        rebuildBucketsFromLoadedItems()
    }

    private func searchPlan(for query: String) -> (serverQuery: String, requiresLocalFilter: Bool) {
        guard query.count == 3, query.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
            return (query, false)
        }
        return (String(query.prefix(2)), true)
    }

    private func issueMatches(_ issue: Issue, query: String) -> Bool {
        [issue.identifier, issue.title, issue.description ?? ""].contains {
            $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func loadChildProgress(workspaceId: String) async throws {
        childProgressByParentIssueId = try await fetchChildProgressMap(workspaceId: workspaceId)
    }

    /// Fetches the child-issue progress map without writing it to live state, so
    /// callers (e.g. `reloadFirstPages`) can stage it and swap atomically.
    private func fetchChildProgressMap(workspaceId: String) async throws -> [String: ChildIssueProgressEntry] {
        let response = try await api.getChildIssueProgress(workspaceId: workspaceId)
        return Dictionary(uniqueKeysWithValues: response.progress.map { ($0.parentIssueId, $0) })
    }

    private func append(_ page: PageResponse<Issue>, for status: IssueStatus) {
        issuesByStatus[status, default: []].append(contentsOf: page.items)
        issuesByStatus[status] = orderedByPosition(issuesByStatus[status, default: []])
        offsetsByStatus[status] = issuesByStatus[status, default: []].count
        if let total = page.total {
            totalsByStatus[status] = total
        }
        pageHasMoreByStatus[status] = page.hasMore
        syncFlatIssues()
    }

    /// Fetch fresh first pages into temp buckets, then swap the live state
    /// atomically. Used by `refresh()` for context switches so the list never
    /// shows an empty window — old data stays visible until the new data lands.
    private func reloadFirstPages(workspaceId: String) async throws {
        let filter = try await serverFilter(workspaceId: workspaceId)
        var buckets: [IssueStatus: [Issue]] = [:]
        var offsets: [IssueStatus: Int] = [:]
        var totals: [IssueStatus: Int] = [:]
        var hasMore: [IssueStatus: Bool] = [:]
        var progress = childProgressByParentIssueId
        if !filter.matchesNothing {
            for status in IssueStatus.listCases {
                let page = try await api.listIssues(
                    workspaceId: workspaceId,
                    status: status,
                    priority: priorityFilter,
                    assigneeId: filter.assigneeId,
                    assigneeIds: filter.assigneeIds,
                    creatorId: filter.creatorId,
                    limit: Self.pageSize,
                    offset: 0
                )
                buckets[status] = orderedByPosition(page.items)
                offsets[status] = page.items.count
                if let total = page.total { totals[status] = total }
                hasMore[status] = page.hasMore
            }
            progress = try await fetchChildProgressMap(workspaceId: workspaceId)
        }
        // Atomic swap — old data stays on screen until this assignment lands.
        issuesByStatus = buckets
        offsetsByStatus = offsets
        totalsByStatus = totals
        pageHasMoreByStatus = hasMore
        childProgressByParentIssueId = progress
        hasLoadedFirstPages = true
        syncFlatIssues()
    }

    /// Merge a freshly-fetched first page for one status into the live bucket,
    /// keeping already-loaded deeper-page items (by id) as the tail. Resets that
    /// status's pagination cursor to the fresh page so "load more" stays correct.
    private func mergeFirstPage(_ page: PageResponse<Issue>, for status: IssueStatus) {
        let freshIds = Set(page.items.map { $0.id })
        let tail = (issuesByStatus[status] ?? []).filter { !freshIds.contains($0.id) }
        issuesByStatus[status] = orderedByPosition(page.items + tail)
        offsetsByStatus[status] = page.items.count
        if let total = page.total { totalsByStatus[status] = total }
        pageHasMoreByStatus[status] = page.hasMore
    }

    private func syncFlatIssues() {
        guard searchQuery.isEmpty else { return }
        let issues = IssueStatus.listCases.flatMap { issuesByStatus[$0] ?? [] }
        loader.items = sorted(issues)
        loader.hasMore = IssueStatus.listCases.contains { statusHasMore($0) }
    }

    private func replaceIssue(_ issue: Issue, preferredIndex: Int? = nil) {
        let previousStatus = IssueStatus.listCases.first { status in
            issuesByStatus[status]?.contains { $0.id == issue.id } == true
        }

        for status in IssueStatus.listCases {
            issuesByStatus[status]?.removeAll { $0.id == issue.id }
        }
        if IssueStatus.listCases.contains(issue.status) {
            var bucket = issuesByStatus[issue.status, default: []]
            if let preferredIndex {
                bucket.insert(issue, at: min(max(0, preferredIndex), bucket.count))
            } else {
                bucket.append(issue)
                bucket = orderedByPosition(bucket)
            }
            issuesByStatus[issue.status] = renumbered(bucket)
        }
        reconcilePaginationAfterReplacingIssue(from: previousStatus, to: issue.status)
        syncFlatIssues()
    }

    private func applyBatchUpdate(
        ids: Set<String>,
        status: IssueStatus?,
        priority: IssuePriority?,
        assigneeType: String?,
        assigneeId: String?
    ) {
        var patched: [Issue] = []
        for bucketStatus in IssueStatus.listCases {
            let existing = issuesByStatus[bucketStatus] ?? []
            issuesByStatus[bucketStatus] = existing.compactMap { issue in
                guard ids.contains(issue.id) else { return issue }
                patched.append(
                    issue.replacing(
                        status: status ?? issue.status,
                        priority: priority ?? issue.priority,
                        assigneeType: assigneeType ?? issue.assigneeType,
                        assigneeId: assigneeId ?? issue.assigneeId
                    )
                )
                return nil
            }
        }
        for issue in patched where IssueStatus.listCases.contains(issue.status) {
            issuesByStatus[issue.status, default: []].append(issue)
        }
        resetPaginationCountsFromBuckets()
        syncFlatIssues()
    }

    private func removeIssues(withIds ids: Set<String>) {
        for status in IssueStatus.listCases {
            issuesByStatus[status]?.removeAll { ids.contains($0.id) }
        }
        resetPaginationCountsFromBuckets()
        syncFlatIssues()
    }

    private func resetPaginationCountsFromBuckets() {
        for status in IssueStatus.listCases {
            let count = issuesByStatus[status, default: []].count
            offsetsByStatus[status] = count
            totalsByStatus[status] = count
            pageHasMoreByStatus[status] = false
        }
    }

    private func reconcilePaginationAfterReplacingIssue(from previousStatus: IssueStatus?, to newStatus: IssueStatus) {
        var affectedStatuses = Set<IssueStatus>()
        if let previousStatus {
            affectedStatuses.insert(previousStatus)
        }
        if IssueStatus.listCases.contains(newStatus) {
            affectedStatuses.insert(newStatus)
        }

        for status in affectedStatuses {
            offsetsByStatus[status] = issuesByStatus[status, default: []].count
        }

        guard let previousStatus, previousStatus != newStatus else { return }
        if let total = totalsByStatus[previousStatus] {
            totalsByStatus[previousStatus] = max(0, total - 1)
        }
        if IssueStatus.listCases.contains(newStatus), let total = totalsByStatus[newStatus] {
            totalsByStatus[newStatus] = total + 1
        }
    }

    private func sorted(_ issues: [Issue]) -> [Issue] {
        let sortedIssues: [Issue]
        switch sortOption {
        case .position:
            sortedIssues = issues
        case .number:
            sortedIssues = issues.sorted { lhs, rhs in
                if lhs.number == rhs.number {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.number < rhs.number
            }
        case .priority:
            sortedIssues = issues.sorted { lhs, rhs in
                if lhs.priority.sortRank == rhs.priority.sortRank {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.priority.sortRank < rhs.priority.sortRank
            }
        case .updated:
            sortedIssues = issues.sorted { $0.updatedAt < $1.updatedAt }
        case .created:
            sortedIssues = issues.sorted { $0.createdAt < $1.createdAt }
        case .title:
            sortedIssues = issues.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }

        switch sortDirection {
        case .ascending:
            return sortedIssues
        case .descending:
            return sortedIssues.reversed()
        }
    }

    private func statusHasMore(_ status: IssueStatus) -> Bool {
        let loaded = issuesByStatus[status, default: []].count
        if let total = totalsByStatus[status] {
            return loaded < total
        }
        return pageHasMoreByStatus[status] ?? false
    }

    private func renumbered(_ issues: [Issue]) -> [Issue] {
        issues.enumerated().map { index, issue in
            issue.replacing(
                status: issue.status,
                priority: issue.priority,
                assigneeType: issue.assigneeType,
                assigneeId: issue.assigneeId,
                position: index
            )
        }
    }

    private func orderedByPosition(_ issues: [Issue]) -> [Issue] {
        issues.enumerated().sorted { lhs, rhs in
            let leftPosition = lhs.element.position ?? Double(lhs.offset)
            let rightPosition = rhs.element.position ?? Double(rhs.offset)
            if leftPosition == rightPosition {
                return lhs.element.updatedAt > rhs.element.updatedAt
            }
            return leftPosition < rightPosition
        }.map(\.element)
    }

    private func nextStatusWithMore() -> IssueStatus? {
        IssueStatus.listCases.first { statusHasMore($0) }
    }

    private func resetPagination() {
        loader.reset()
        resetBuckets()
        searchSourceOffset = 0
        hasLoadedFirstPages = false
        lastError = nil
    }

    private func resetBuckets() {
        issuesByStatus = [:]
        childProgressByParentIssueId = [:]
        offsetsByStatus = [:]
        totalsByStatus = [:]
        pageHasMoreByStatus = [:]
    }

    private func rebuildBucketsFromLoadedItems() {
        resetBuckets()
        for issue in loader.items where IssueStatus.listCases.contains(issue.status) {
            issuesByStatus[issue.status, default: []].append(issue)
        }
        resetPaginationCountsFromBuckets()
        if searchQuery.isEmpty {
            loader.items = sorted(loader.items)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        if case APIClient.APIError.networkError(let underlying) = error {
            return isCancellation(underlying)
        }
        return false
    }
}

private extension IssuePriority {
    var sortRank: Int {
        switch self {
        case .urgent: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .noPriority: return 4
        case .unknown: return 5
        }
    }
}

private extension Issue {
    func replacing(
        status: IssueStatus,
        priority: IssuePriority,
        assigneeType: String?,
        assigneeId: String?,
        position: Int? = nil
    ) -> Issue {
        Issue(
            id: id,
            identifier: identifier,
            number: number,
            title: title,
            description: description,
            status: status,
            priority: priority,
            assigneeId: assigneeId,
            assigneeType: assigneeType,
            parentIssueId: parentIssueId,
            projectId: projectId,
            workspaceId: workspaceId,
            dueDate: dueDate,
            attachments: attachments,
            position: position.map(Double.init) ?? self.position,
            labels: labels,
            reactions: reactions,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
