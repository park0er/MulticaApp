#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

public struct IssueListView: View {
    @Environment(AuthSession.self) private var authSession
    @Environment(APIClient.self) private var api
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: IssueListViewModel?
    @State private var showingBatchDeleteConfirmation = false
    @State private var searchText = ""
    @State private var collapsedStatusSections: Set<IssueStatus> = []
    @State private var autoRefreshTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    private let initialScope: IssueListViewModel.Scope
    private let autoRefreshIntervalNanoseconds: UInt64 = 30_000_000_000
    private let searchDebounceNanoseconds: UInt64 = 350_000_000

    public init(scope: IssueListViewModel.Scope = .all) {
        self.initialScope = scope
    }

    public var body: some View {
        Group {
            if let vm = viewModel {
                VStack(spacing: 0) {
                    if initialScope.isPersonal {
                        Picker(AppStrings.localized("My Issues Scope", language: appLanguage), selection: Binding(
                            get: { vm.scope },
                            set: { nextScope in Task { await vm.setScope(nextScope) } }
                        )) {
                            MarkdownText(AppStrings.localized(IssueListViewModel.Scope.assignedToMe.displayName, language: appLanguage)).tag(IssueListViewModel.Scope.assignedToMe)
                            MarkdownText(AppStrings.localized(IssueListViewModel.Scope.createdByMe.displayName, language: appLanguage)).tag(IssueListViewModel.Scope.createdByMe)
                            MarkdownText(AppStrings.localized(IssueListViewModel.Scope.myAgents.displayName, language: appLanguage)).tag(IssueListViewModel.Scope.myAgents)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("MyIssuesScopePicker")
                        Divider()
                    }
                    Group {
                        if vm.isSearching {
                            listView(vm: vm)
                        } else {
                            switch vm.viewMode {
                            case .list: listView(vm: vm)
                            case .board: boardView(vm: vm)
                            }
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            if vm.isSelectionMode {
                                vm.clearSelection()
                            } else {
                                vm.isSelectionMode = true
                                vm.viewMode = .list
                            }
                        } label: {
                            Image(systemName: vm.isSelectionMode ? "xmark.circle" : "checkmark.circle")
                        }
                        .accessibilityIdentifier("IssueSelectionToggle")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button {
                                Task { await vm.setPriorityFilter(nil) }
                            } label: {
                                Label(AppStrings.localized("All Priorities", language: appLanguage), systemImage: vm.priorityFilter == nil ? "checkmark" : "line.3.horizontal.decrease.circle")
                            }
                            ForEach(IssuePriority.allCases.filter { $0 != .unknown }, id: \.self) { priority in
                                Button {
                                    Task { await vm.setPriorityFilter(priority) }
                                } label: {
                                    MarkdownIconLabel(AppStrings.localized(priority.displayName, language: appLanguage), systemImage: vm.priorityFilter == priority ? "checkmark" : "flag")
                                }
                            }
                        } label: {
                            Image(systemName: vm.priorityFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        }
                        .accessibilityIdentifier("IssuePriorityFilterMenu")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Section(AppStrings.localized("Sort by", language: appLanguage)) {
                                ForEach(IssueListViewModel.SortOption.allCases, id: \.self) { option in
                                    Button {
                                        vm.setSortOption(option)
                                    } label: {
                                        MarkdownIconLabel(AppStrings.localized(option.displayName, language: appLanguage), systemImage: vm.sortOption == option ? "checkmark" : "arrow.up.arrow.down")
                                    }
                                }
                            }
                            Section(AppStrings.localized("Direction", language: appLanguage)) {
                                ForEach(IssueListViewModel.SortDirection.allCases, id: \.self) { direction in
                                    Button {
                                        vm.setSortDirection(direction)
                                    } label: {
                                        MarkdownIconLabel(AppStrings.localized(direction.displayName, language: appLanguage), systemImage: vm.sortDirection == direction ? "checkmark" : direction.icon)
                                    }
                                    .accessibilityIdentifier("IssueSortDirection-\(direction.rawValue)")
                                }
                            }
                        } label: {
                            Image(systemName: vm.sortDirection == .ascending ? "arrow.up.arrow.down" : "arrow.up.arrow.down.circle.fill")
                        }
                        .accessibilityIdentifier("IssueSortMenu")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { vm.viewMode = vm.viewMode == .list ? .board : .list } label: {
                            Image(systemName: vm.viewMode == .list ? "square.grid.2x2" : "list.bullet")
                        }
                        .accessibilityIdentifier("IssueViewModeToggle")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { vm.showCreateSheet = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                    }
                }
                .sheet(isPresented: Binding(
                    get: { vm.showCreateSheet },
                    set: { vm.showCreateSheet = $0 }
                )) {
                    IssueCreateSheet { vm.showCreateSheet = false; Task { await vm.refresh() } }
                        .presentationDragIndicator(.visible)
                }
                .refreshable { await vm.pullToRefresh() }
                .issueSearchable(
                    enabled: initialScope == .all,
                    text: $searchText,
                    submit: { scheduleSearch(query: searchText, immediately: true) },
                    change: { newValue in scheduleSearch(query: newValue) }
                )
                .safeAreaInset(edge: .bottom) {
                    if vm.isSelectionMode && !vm.selectedIssueIds.isEmpty {
                        IssueBatchActionBar(
                            selectedCount: vm.selectedIssueIds.count,
                            assigneeOptions: vm.batchAssigneeOptions,
                            isLoadingAssignees: vm.isLoadingBatchAssignees,
                            onClear: { vm.clearSelection() },
                            onLoadAssignees: { Task { await vm.loadBatchAssigneeOptions() } },
                            onStatus: { status in Task { await vm.batchUpdateSelected(status: status) } },
                            onPriority: { priority in Task { await vm.batchUpdateSelected(priority: priority) } },
                            onAssignee: { option in Task { await vm.batchAssignSelected(optionId: option.id) } },
                            onDelete: { showingBatchDeleteConfirmation = true }
                        )
                    }
                }
                .destructiveConfirmation(
                    DestructiveConfirmation.deleteIssues(count: vm.selectedIssueIds.count),
                    isPresented: $showingBatchDeleteConfirmation
                ) {
                    Task { await vm.batchDeleteSelected() }
                }
            } else { ProgressView() }
        }
        .navigationTitle(AppStrings.localized(initialScope.isPersonal ? "My Issues" : "Issues", language: appLanguage))
        .onAppear {
            if viewModel == nil {
                viewModel = IssueListViewModel(api: api, authSession: authSession, scope: initialScope)
                Task { await viewModel?.loadNext() }
                #if DEBUG
                if ProcessInfo.processInfo.environment["MULTI_CASUAL_DEBUG_OPEN_CREATE_SHEET"] == "1" {
                    viewModel?.showCreateSheet = true
                }
                #endif
            }
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
            cancelSearchTask()
        }
        .onChange(of: authSession.currentWorkspace?.id) { _, _ in
            guard let viewModel else { return }
            Task { await viewModel.refresh() }
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

    private func scheduleSearch(query: String, immediately: Bool = false) {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            if !immediately {
                do {
                    try await Task.sleep(nanoseconds: searchDebounceNanoseconds)
                } catch {
                    return
                }
            }
            await viewModel?.setSearchQuery(query)
        }
    }

    private func cancelSearchTask() {
        searchTask?.cancel()
        searchTask = nil
    }

    private func listView(vm: IssueListViewModel) -> some View {
        List {
            // Empty state only when a first load has finished with no items — never
            // during a background silent refresh, so the list never flashes empty.
            if vm.loader.items.isEmpty && !vm.loader.hasMore && !vm.loader.isLoading
                && !vm.isRefreshing && vm.lastError == nil {
                ContentUnavailableView(
                    AppStrings.localized(vm.scope.emptyTitle, language: appLanguage),
                    systemImage: initialScope.isPersonal ? "person.crop.circle.badge.checkmark" : "checklist",
                    description: Text(MarkdownRenderer.attributedString(from: AppStrings.localized(vm.scope.emptyDescription, language: appLanguage)))
                )
            }
            if vm.isSearching {
                ForEach(vm.searchResults) { issue in
                    issueListRow(issue: issue, vm: vm)
                }
            } else {
                ForEach(IssueStatus.listCases, id: \.self) { status in
                    let issues = vm.issues(for: status)
                    if !issues.isEmpty {
                        Section {
                            if !collapsedStatusSections.contains(status) {
                                ForEach(issues) { issue in
                                    issueListRow(issue: issue, vm: vm)
                                }
                            }
                        } header: {
                            Button {
                                toggleStatusSection(status)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: collapsedStatusSections.contains(status) ? "chevron.right" : "chevron.down")
                                        .frame(width: 12)
                                    Image(systemName: status.icon)
                                    MarkdownText(AppStrings.localized(status.displayName, language: appLanguage))
                                    MarkdownText("(\(issues.count))")
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .accessibilityIdentifier("IssueStatusSectionHeader-\(status.rawValue)")
                            .accessibilityLabel("\(AppStrings.localized(status.displayName, language: appLanguage)) status section")
                            .accessibilityValue(collapsedStatusSections.contains(status) ? "Collapsed" : "Expanded")
                        }
                    }
                }
            }
            if vm.loader.hasMore { ProgressView().onAppear { Task { await vm.loadNext() } } }
            if let error = vm.lastError {
                ErrorRetryView(message: error.localizedDescription) {
                    Task { await vm.refresh() }
                }
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func issueListRow(issue: Issue, vm: IssueListViewModel) -> some View {
        if vm.isSelectionMode {
            Button {
                vm.toggleSelection(issueId: issue.id)
            } label: {
                IssueSelectableRowView(
                    issue: issue,
                    childProgressText: vm.childProgressText(for: issue),
                    isSelected: vm.selectedIssueIds.contains(issue.id)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("IssueSelectionRow-\(issue.identifier)")
        } else {
            NavigationLink(destination: IssueDetailView(issueId: issue.id)) {
                IssueRowView(issue: issue, childProgressText: vm.childProgressText(for: issue))
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if issue.status != .done {
                    Button {
                        Task { await vm.updateStatus(issueId: issue.id, to: .done) }
                    } label: {
                        Label(AppStrings.localized("Done", language: appLanguage), systemImage: "checkmark.circle")
                    }
                    .tint(.green)
                }
            }
        }
    }

    private func boardView(vm: IssueListViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(IssueStatus.boardCases, id: \.self) { status in
                    let issues = vm.issues(for: status)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: status.icon)
                            MarkdownText(AppStrings.localized(status.displayName, language: appLanguage)).font(.caption.bold())
                            MarkdownText("(\(issues.count))").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                            NavigationLink(destination: IssueDetailView(issueId: issue.id)) {
                                BoardCardView(issue: issue, childProgressText: vm.childProgressText(for: issue))
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .onDrag { NSItemProvider(object: issue.id as NSString) }
                            .onDrop(
                                of: [UTType.text],
                                delegate: IssueBoardDropDelegate(
                                    targetStatus: status,
                                    beforeIssueId: issue.id,
                                    viewModel: vm
                                )
                            )
                            .contextMenu {
                                if index > 0 {
                                    Button {
                                        Task { await vm.moveIssue(issueId: issue.id, to: status, beforeIssueId: issues[index - 1].id) }
                                    } label: {
                                        MarkdownIconLabel(AppStrings.localized("Move Up", language: appLanguage), systemImage: "arrow.up")
                                    }
                                    .accessibilityIdentifier("IssueBoardMoveUp-\(issue.identifier)")
                                }
                                if index < issues.count - 1 {
                                    Button {
                                        let beforeIssueId = index + 2 < issues.count ? issues[index + 2].id : nil
                                        Task { await vm.moveIssue(issueId: issue.id, to: status, beforeIssueId: beforeIssueId) }
                                    } label: {
                                        MarkdownIconLabel(AppStrings.localized("Move Down", language: appLanguage), systemImage: "arrow.down")
                                    }
                                    .accessibilityIdentifier("IssueBoardMoveDown-\(issue.identifier)")
                                }
                                Menu {
                                    ForEach(IssueStatus.boardCases.filter { $0 != status }, id: \.self) { targetStatus in
                                        Button {
                                            Task { await vm.moveIssue(issueId: issue.id, to: targetStatus) }
                                        } label: {
                                            MarkdownIconLabel(AppStrings.localized(targetStatus.displayName, language: appLanguage), systemImage: targetStatus.icon)
                                        }
                                    }
                                } label: {
                                    MarkdownIconLabel(AppStrings.localized("Move to Status", language: appLanguage), systemImage: "arrow.left.arrow.right")
                                }
                            }
                        }
                    }
                    .frame(width: 260).padding(8)
                    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [UTType.text],
                        delegate: IssueBoardDropDelegate(
                            targetStatus: status,
                            beforeIssueId: nil,
                            viewModel: vm
                        )
                    )
                    .accessibilityIdentifier("IssueBoardColumn-\(status.rawValue)")
                }
            }.padding()
        }
        .overlay(alignment: .topLeading) {
            if let error = vm.lastError {
                ErrorRetryView(message: error.localizedDescription) {
                    Task { await vm.refresh() }
                }
                    .padding()
            }
        }
    }

    private func toggleStatusSection(_ status: IssueStatus) {
        if collapsedStatusSections.contains(status) {
            collapsedStatusSections.remove(status)
        } else {
            collapsedStatusSections.insert(status)
        }
    }
}

private struct IssueBoardDropDelegate: DropDelegate {
    let targetStatus: IssueStatus
    let beforeIssueId: String?
    let viewModel: IssueListViewModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let issueId = object as? String ?? (object as? NSString)?.description,
                  issueId != beforeIssueId
            else { return }
            Task { @MainActor in
                await viewModel.moveIssue(issueId: issueId, to: targetStatus, beforeIssueId: beforeIssueId)
            }
        }
        return true
    }
}

private extension View {
    @ViewBuilder
    func issueSearchable(
        enabled: Bool,
        text: Binding<String>,
        submit: @escaping () -> Void,
        change: @escaping (String) -> Void
    ) -> some View {
        if enabled {
            self
                .searchable(text: text, prompt: "Search issues")
                .onSubmit(of: .search, submit)
                .onChange(of: text.wrappedValue) { _, newValue in change(newValue) }
        } else {
            self
        }
    }
}

private struct IssueBatchActionBar: View {
    let selectedCount: Int
    let assigneeOptions: [IssueAssigneeOption]
    let isLoadingAssignees: Bool
    let onClear: () -> Void
    let onLoadAssignees: () -> Void
    let onStatus: (IssueStatus) -> Void
    let onPriority: (IssuePriority) -> Void
    let onAssignee: (IssueAssigneeOption) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClear) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Clear Selection")

            MarkdownText("\(selectedCount) selected")
                .font(.caption.weight(.semibold))
                .frame(minWidth: 76, alignment: .leading)

            Menu {
                ForEach(IssueStatus.displayCases, id: \.self) { status in
                    Button {
                        onStatus(status)
                    } label: {
                        MarkdownText(status.displayName)
                    }
                }
            } label: {
                Label("Status", systemImage: "circle.dashed")
            }
            .accessibilityIdentifier("IssueBatchStatusMenu")

            Menu {
                ForEach(IssuePriority.allCases.filter { $0 != .unknown }, id: \.self) { priority in
                    Button {
                        onPriority(priority)
                    } label: {
                        MarkdownText(priority.displayName)
                    }
                }
            } label: {
                Label("Priority", systemImage: "flag")
            }
            .accessibilityIdentifier("IssueBatchPriorityMenu")

            Menu {
                if isLoadingAssignees {
                    Label("Loading", systemImage: "hourglass")
                }
                ForEach(assigneeOptions) { option in
                    Button {
                        onAssignee(option)
                    } label: {
                        MarkdownIconLabel(option.displayName, systemImage: option.type == "agent" ? "bolt.circle" : "person.circle")
                    }
                }
            } label: {
                Label("Assignee", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("IssueBatchAssigneeMenu")
            .accessibilityValue(isLoadingAssignees ? "Loading assignees" : "Assignee options loaded: \(assigneeOptions.count)")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete Selected Issues")
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .task {
            if assigneeOptions.isEmpty {
                onLoadAssignees()
            }
        }
    }
}

public struct IssueRowView: View {
    public let issue: Issue
    public let childProgressText: String?
    public init(issue: Issue, childProgressText: String? = nil) {
        self.issue = issue
        self.childProgressText = childProgressText
    }
    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: issue.status.icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                MarkdownText(issue.identifier).font(.caption).foregroundStyle(.secondary)
                MarkdownText(issue.title).font(.body)
            }
            Spacer(minLength: 8)
            if let childProgressText {
                MarkdownIconLabel(childProgressText, systemImage: "checklist")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.1), in: Capsule())
                    .accessibilityLabel("Sub-issues \(childProgressText)")
            }
        }.padding(.vertical, 4)
    }
}

private struct IssueSelectableRowView: View {
    let issue: Issue
    let childProgressText: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 20)
            IssueRowView(issue: issue, childProgressText: childProgressText)
        }
    }
}

struct BoardCardView: View {
    let issue: Issue
    let childProgressText: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MarkdownText(issue.identifier).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                if let childProgressText {
                    MarkdownIconLabel(childProgressText, systemImage: "checklist")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("Sub-issues \(childProgressText)")
                }
            }
            MarkdownText(issue.title).font(.subheadline).lineLimit(2)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .accessibilityIdentifier("IssueBoardCard-\(issue.identifier)")
    }
}
#endif
