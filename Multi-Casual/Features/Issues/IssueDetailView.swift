#if canImport(SwiftUI) && canImport(UIKit)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

public struct IssueDetailView: View {
    public let issueId: String
    @Environment(AuthSession.self) private var authSession
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appLanguage) private var appLanguage
    @State private var viewModel: IssueDetailViewModel?
    @State private var showEditIssue = false
    @State private var showCreateSubIssue = false
    @State private var showSubscribers = false
    @State private var showCommentAttachmentImporter = false
    @State private var selectedCommentImageItem: PhotosPickerItem?
    @State private var showDeleteIssueConfirmation = false
    @State private var showCancelTaskConfirmation = false
    @State private var showDeleteAttachmentConfirmation = false
    @State private var pendingCancelTask: AgentTask?
    @State private var pendingDeleteAttachment: Attachment?
    @State private var selectedPreviewAttachment: Attachment?
    @State private var selectedTranscript: AgentTranscriptSelection?
    @State private var issueReferenceTarget: IssueReferenceNavigationTarget?
    @State private var issueReferenceError: String?
    @State private var pinViewModel: PinToggleViewModel?
    @State private var isAgentWorkExpanded = false
    @State private var activeReplyTarget: IssueReplyTarget?
    @State private var replyDraft = ""
    @State private var replyDraftMentions: [IssueDetailViewModel.MentionDraftToken] = []
    @State private var commentMentionQuery: String?
    @State private var replyMentionQuery: String?
    @State private var commentMentionTrigger = MentionTriggerSession()
    @State private var replyMentionTrigger = MentionTriggerSession()
    @State private var replyAttachmentError: String?
    @State private var showReplyAttachmentImporter = false
    @State private var selectedReplyImageItem: PhotosPickerItem?
    /// Resolved threads the user has expanded. Resolved threads default to a
    /// collapsed one-line bar; tapping expands them here. Unresolved threads
    /// always render in full.
    @State private var expandedResolvedThreads: Set<String> = []
    @FocusState private var composerFocus: IssueComposerFocus?
    @State private var autoRefreshTask: Task<Void, Never>?
    private let autoRefreshIntervalNanoseconds: UInt64 = 60_000_000_000

    public init(issueId: String) { self.issueId = issueId }

    public var body: some View {
        Group {
            if let vm = viewModel { content(vm: vm) }
            else { ProgressView() }
        }
        .markdownNavigationTitle(viewModel?.issue?.identifier ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $issueReferenceTarget) { target in
            IssueDetailView(issueId: target.issueId)
        }
        .environment(\.openURL, OpenURLAction { url in
            handleMarkdownURL(url)
        })
        .onAppear {
            if viewModel == nil {
                viewModel = IssueDetailViewModel(
                    issueId: issueId,
                    workspaceId: authSession.currentWorkspace?.id,
                    api: api
                )
                let pinVM = PinToggleViewModel(itemType: .issue, itemId: issueId, api: api, authSession: authSession)
                pinViewModel = pinVM
                Task {
                    await pinVM.load()
                    await viewModel?.loadInitialData()
                }
            }
            startAutoRefresh()
        }
        .onDisappear {
            stopAutoRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await viewModel?.silentRefresh() }
                startAutoRefresh()
            default:
                stopAutoRefresh()
            }
        }
        .sheet(item: $selectedTranscript) { selection in
            AgentTranscriptView(taskId: selection.taskId, workspaceId: selection.workspaceId ?? viewModel?.resolvedWorkspaceId)
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedPreviewAttachment) { attachment in
            AttachmentPreviewView(attachment: attachment, workspaceId: viewModel?.resolvedWorkspaceId)
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEditIssue) {
            if let vm = viewModel, let issue = vm.issue {
                IssueEditSheet(issue: issue) { updated in
                    Task { await vm.applyUpdatedIssue(updated) }
                }
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSubscribers) {
            if let vm = viewModel {
                SubscriberManagementView(vm: vm)
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showCreateSubIssue) {
            if let vm = viewModel, let issue = vm.issue {
                IssueCreateSheet(parentIssue: issue) {
                    Task {
                        await vm.loadIssueRelations()
                        await vm.loadIssue()
                    }
                }
                .presentationDragIndicator(.visible)
            }
        }
        .toolbar {
            if viewModel?.issue != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let pinViewModel {
                        Button {
                            Task { await pinViewModel.toggle() }
                        } label: {
                            MarkdownIconLabel(
                                pinViewModel.isPinned ? "Unpin Issue" : "Pin Issue",
                                systemImage: pinViewModel.isPinned ? "pin.slash" : "pin"
                            )
                        }
                        .disabled(pinViewModel.isLoading)
                        .accessibilityIdentifier("IssueDetailPinButton")
                    }
                    Button {
                        showEditIssue = true
                    } label: {
                        Label(AppStrings.localized("Edit Issue", language: appLanguage), systemImage: "pencil")
                    }
                    .accessibilityIdentifier("IssueDetailEditButton")
                    Button(role: .destructive) {
                        showDeleteIssueConfirmation = true
                    } label: {
                        Label(AppStrings.localized("Delete Issue", language: appLanguage), systemImage: "trash")
                    }
                    .disabled(viewModel?.isDeletingIssue == true)
                    .accessibilityIdentifier("IssueDetailDeleteButton")
                }
            }
        }
        .destructiveConfirmation(
            deleteIssueConfirmation,
            isPresented: $showDeleteIssueConfirmation
        ) {
            Task {
                await viewModel?.deleteIssue()
                if viewModel?.didDeleteIssue == true {
                    dismiss()
                }
            }
        }
        .destructiveConfirmation(
            cancelTaskConfirmation,
            isPresented: $showCancelTaskConfirmation,
            onConfirm: {
                guard let taskId = pendingCancelTask?.id else { return }
                Task {
                    await viewModel?.cancelActiveTask(id: taskId)
                    pendingCancelTask = nil
                }
            },
            onCancel: {
                pendingCancelTask = nil
            }
        )
        .destructiveConfirmation(
            deleteAttachmentConfirmation,
            isPresented: $showDeleteAttachmentConfirmation,
            onConfirm: {
                guard let attachment = pendingDeleteAttachment else { return }
                Task {
                    await viewModel?.deleteAttachment(id: attachment.id)
                    pendingDeleteAttachment = nil
                }
            },
            onCancel: {
                pendingDeleteAttachment = nil
            }
        )
        .alert(AppStrings.localized("Issue not found", language: appLanguage), isPresented: Binding(
            get: { issueReferenceError != nil },
            set: { if !$0 { issueReferenceError = nil } }
        )) {
            Button(AppStrings.localized("OK", language: appLanguage), role: .cancel) {
                issueReferenceError = nil
            }
        } message: {
            Text(issueReferenceError ?? "")
        }
    }

    @ViewBuilder
    private func content(vm: IssueDetailViewModel) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let error = vm.error {
                        ErrorMessageRow(message: error) {
                            Task { await vm.loadIssueAndMetadata() }
                        }
                    }
                    if let deleteIssueError = vm.deleteIssueError {
                        ErrorMessageRow(message: deleteIssueError)
                    }
                    if let issue = vm.issue {
                        issueHeader(issue: issue, vm: vm, currentUserId: authSession.currentUser?.id)
                    }
                    Divider()
                    latestProgressSection(vm: vm)
                    Divider()
                    subIssuesSection(vm: vm)
                    Divider()
                    subscribersSection(vm: vm, currentUserId: authSession.currentUser?.id)
                    Divider()
                    commentsSection(vm: vm, currentUserId: authSession.currentUser?.id)
                    Divider()
                    if vm.didLoadUsage || vm.usageError != nil || vm.isLoadingUsage {
                        usageSection(vm: vm)
                        Divider()
                    }
                    if vm.didLoadActiveTasks || vm.activeTasksError != nil || vm.isLoadingActiveTasks ||
                        vm.didLoadAgentRuns || vm.agentRunsError != nil || vm.isLoadingAgentRuns {
                        agentWorkDetailsSection(vm: vm)
                        Divider()
                    }
                    if vm.didLoadTimeline || vm.timelineError != nil || vm.isLoadingTimeline {
                        timelineSection(vm: vm)
                    }
                }.padding(.vertical)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("IssueDetailScrollView")
            if let activeReplyTarget {
                replyInputBar(vm: vm, target: activeReplyTarget)
            } else {
                commentInputBar(vm: vm)
            }
        }
    }

    private var deleteIssueConfirmation: DestructiveConfirmation {
        DestructiveConfirmation.deleteIssue(
            identifier: viewModel?.issue?.identifier,
            title: viewModel?.issue?.title
        )
    }

    private var cancelTaskConfirmation: DestructiveConfirmation {
        DestructiveConfirmation.cancelTask(id: pendingCancelTask?.id ?? "")
    }

    private var deleteAttachmentConfirmation: DestructiveConfirmation {
        DestructiveConfirmation.deleteAttachment(filename: pendingDeleteAttachment?.filename ?? "")
    }

    private func issueHeader(issue: Issue, vm: IssueDetailViewModel, currentUserId: String?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            MarkdownText(issue.title).font(.title2.bold())
            if let parentIssue = vm.parentIssue {
                NavigationLink {
                    IssueDetailView(issueId: parentIssue.id)
                } label: {
                    HStack(spacing: 6) {
                        Text("Sub-issue of")
                            .font(.caption.weight(.medium))
                        Image(systemName: parentIssue.status.icon)
                        MarkdownText(parentIssue.identifier)
                            .font(.caption.monospacedDigit())
                        MarkdownText(parentIssue.title)
                            .font(.caption)
                            .lineLimit(1)
                        if !vm.parentSiblingIssues.isEmpty {
                            MarkdownText(vm.parentChildProgressText)
                                .font(.caption2.monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 12) {
                Menu {
                    ForEach(IssueStatus.displayCases, id: \.self) { status in
                        Button {
                            Task { await vm.updateStatus(status) }
                        } label: {
                            MarkdownIconLabel(status.displayName, systemImage: status.icon)
                        }
                    }
                } label: {
                    MarkdownIconLabel(issue.status.displayName, systemImage: issue.status.icon)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                .disabled(vm.isUpdatingIssue)

                Menu {
                    ForEach(IssuePriority.allCases.filter { $0 != .unknown }, id: \.self) { priority in
                        Button {
                            Task { await vm.updatePriority(priority) }
                        } label: {
                            MarkdownIconLabel(priority.displayName, systemImage: "flag")
                        }
                    }
                } label: {
                    MarkdownIconLabel(issue.priority.displayName, systemImage: "flag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(vm.isUpdatingIssue)
            }
            if let desc = issue.description, !desc.isEmpty {
                MarkdownText(desc).font(.body)
            }
            ReactionBarView(badges: issueReactionBadges(issue.reactions, currentUserId: currentUserId)) { emoji in
                Task { await vm.toggleIssueReaction(emoji: emoji, currentUserId: currentUserId) }
            }
            if !issue.labels.isEmpty {
                LabelWrapView(labels: issue.labels)
            }
            if !issue.attachments.isEmpty {
                AttachmentListView(
                    attachments: issue.attachments,
                    deletingAttachmentIds: vm.deletingAttachmentIds,
                    onPreview: { selectedPreviewAttachment = $0 }
                ) { attachment in
                    pendingDeleteAttachment = attachment
                    showDeleteAttachmentConfirmation = true
                }
            }
            if let attachmentsError = vm.attachmentsError {
                ErrorMessageRow(message: attachmentsError) {
                    Task { await vm.loadAttachments() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                detailLine(
                    icon: "person.crop.circle",
                    title: "Assignee",
                    value: assigneeText(issue: issue, vm: vm)
                )
                detailLine(
                    icon: "folder",
                    title: "Project",
                    value: projectText(issue: issue, vm: vm)
                )
                detailLine(
                    icon: "calendar",
                    title: "Created",
                    value: iso8601DateOnlyFormatter.string(from: issue.createdAt)
                )
                detailLine(
                    icon: "clock",
                    title: "Updated",
                    value: iso8601DateOnlyFormatter.string(from: issue.updatedAt)
                )
            }
            if let metadataError = vm.metadataError {
                ErrorMessageRow(message: metadataError) {
                    Task { await vm.loadMetadata() }
                }
            }
        }.padding(.horizontal)
    }

    private func detailLine(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            MarkdownText(title)
                .foregroundStyle(.secondary)
            Spacer()
            MarkdownText(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func subIssuesSection(vm: IssueDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
            MarkdownText("Sub-issues").font(.headline)
                if !vm.childIssues.isEmpty {
                    MarkdownText(vm.childProgressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.1), in: Capsule())
                }
                Spacer()
                Button {
                    showCreateSubIssue = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(vm.issue == nil)
                .accessibilityLabel("Add Sub-issue")
                .accessibilityIdentifier("IssueDetailAddSubIssueButton")
            }

            if vm.isLoadingIssueRelations && !vm.didLoadIssueRelations {
                ProgressView()
            }
            if let issueRelationsError = vm.issueRelationsError {
                ErrorMessageRow(message: issueRelationsError) {
                    Task { await vm.loadIssueRelations() }
                }
                .padding(.horizontal, -16)
            }
            if vm.didLoadIssueRelations && vm.childIssues.isEmpty && vm.issueRelationsError == nil && !vm.isLoadingIssueRelations {
                MarkdownText("No sub-issues")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(vm.childIssues) { child in
                NavigationLink {
                    IssueDetailView(issueId: child.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: child.status.icon)
                            .foregroundStyle(child.status == .done ? Color.green : Color.secondary)
                            .frame(width: 18)
                        MarkdownText(child.identifier)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        MarkdownText(child.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        if child.assigneeType != nil {
                            Image(systemName: child.assigneeType == "agent" ? "bolt.circle" : "person.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func assigneeText(issue: Issue, vm: IssueDetailViewModel) -> String {
        guard let assigneeId = issue.assigneeId, let assigneeType = issue.assigneeType else {
            return "Unassigned"
        }
        return vm.assigneeDisplayName ?? "\(assigneeType.capitalized) \(assigneeId.prefix(8))"
    }

    private func projectText(issue: Issue, vm: IssueDetailViewModel) -> String {
        guard let projectId = issue.projectId else {
            return "No Project"
        }
        return vm.projectDisplayName ?? String(projectId.prefix(8))
    }

    private func issueReactionBadges(_ reactions: [IssueReaction], currentUserId: String?) -> [ReactionBadge] {
        let emojis = Array(Set(reactions.map(\.emoji))).sorted()
        return emojis.map { emoji in
            let matching = reactions.filter { $0.emoji == emoji }
            return ReactionBadge(
                emoji: emoji,
                count: matching.count,
                isSelected: matching.contains { $0.actorType == "member" && $0.actorId == currentUserId }
            )
        }
    }

    private func subscribersSection(vm: IssueDetailViewModel, currentUserId: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MarkdownText("Subscribers").font(.headline)
                Spacer()
                if let currentUserId {
                    Button {
                        Task { await vm.toggleSubscriber(userId: currentUserId, userType: "member") }
                    } label: {
                        MarkdownText(vm.isSubscribed(userId: currentUserId, userType: "member") ? "Unsubscribe" : "Subscribe")
                            .font(.caption)
                    }
                    .disabled(vm.isLoadingSubscribers)
                    .accessibilityIdentifier("IssueDetailSubscribeButton")
                }
                Button {
                    showSubscribers = true
                } label: {
                    Image(systemName: "person.2.badge.gearshape")
                }
                .disabled(vm.isLoadingSubscribers)
                .accessibilityLabel("Manage Subscribers")
                .accessibilityIdentifier("IssueDetailManageSubscribersButton")
            }

            if vm.isLoadingSubscribers && !vm.didLoadSubscribers {
                ProgressView()
            }
            if let subscribersError = vm.subscribersError {
                ErrorMessageRow(message: subscribersError) {
                    Task { await vm.loadSubscribers() }
                }
                .padding(.horizontal, -16)
            }
            if vm.didLoadSubscribers && vm.subscribers.isEmpty && vm.subscribersError == nil && !vm.isLoadingSubscribers {
                MarkdownText("No subscribers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !vm.subscribers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.subscribers) { subscriber in
                            SubscriberChip(
                                subscriber: subscriber,
                                name: vm.displayName(for: subscriber),
                                avatarUrl: vm.avatarURL(for: subscriber)
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func commentsSection(vm: IssueDetailViewModel, currentUserId: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MarkdownText("Comments").font(.headline)
                Spacer()
                Picker("Sort", selection: Binding(
                    get: { vm.commentSortOrder },
                    set: { vm.setCommentSortOrder($0) }
                )) {
                    ForEach(IssueDetailViewModel.CommentSortOrder.allCases) { order in
                        MarkdownText(order.displayName).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("IssueCommentSortPicker")
            }
            .padding(.horizontal)

            if let commentsError = vm.commentsError {
                ErrorMessageRow(message: commentsError) {
                    Task { await vm.loadComments() }
                }
            }
            if vm.didLoadComments && vm.commentLoader.items.isEmpty && vm.commentsError == nil && !vm.isLoadingComments {
                ContentUnavailableView("No Comments", systemImage: "text.bubble", description: Text("This issue has no comments yet."))
                    .padding(.horizontal)
            }
            if vm.isLoadingComments && vm.commentLoader.items.isEmpty {
                ProgressView().padding()
            }
            let markdownContext = vm.commentMarkdownContext(issuePrefix: authSession.currentWorkspace?.issuePrefix)
            ForEach(vm.displayedCommentThreads) { thread in
                resolvedThreadView(thread: thread, vm: vm, currentUserId: currentUserId, markdownContext: markdownContext)
            }
            if vm.didLoadComments && vm.commentLoader.hasMore {
                ProgressView().onAppear {
                    Task { await vm.loadMoreComments() }
                }
            }
        }
        .accessibilityIdentifier("IssueDetailCommentsSection")
    }

    private func commentRow(
        _ comment: Comment,
        vm: IssueDetailViewModel,
        currentUserId: String?,
        markdownContext: MarkdownRenderContext,
        isResolution: Bool = false
    ) -> some View {
        CommentRowView(
            comment: comment,
            authorDisplayName: vm.commentAuthorName(for: comment),
            authorAvatarUrl: vm.commentAuthorAvatarURL(for: comment),
            currentUserId: currentUserId,
            markdownContext: markdownContext,
            onStartReply: { comment in
                startReply(to: comment, authorDisplayName: vm.commentAuthorName(for: comment))
            },
            onEdit: { commentId, content in
                await vm.updateComment(commentId: commentId, content: content)
            },
            onDelete: { commentId in
                await vm.deleteComment(commentId: commentId)
            },
            onPreviewAttachment: { selectedPreviewAttachment = $0 },
            onResolve: { commentId, resolve in
                if resolve {
                    await vm.resolveComment(commentId: commentId)
                } else {
                    await vm.unresolveComment(commentId: commentId)
                }
            },
            isResolving: vm.resolvingCommentIds.contains(comment.id),
            isResolution: isResolution
        )
    }

    /// Renders a comment thread with the web's two-case resolution display:
    ///   - root resolved ("Resolve thread"): the WHOLE thread folds into one
    ///     ResolvedThreadBar; expand shows root + every reply.
    ///   - reply resolved ("Resolve thread with comment"): root stays visible,
    ///     the resolution reply is pinned at the bottom with a Resolution badge,
    ///     and the OTHER replies fold behind a CommentsFoldBar between them.
    ///   - none: root + all replies (normal).
    @ViewBuilder
    private func resolvedThreadView(thread: IssueDetailViewModel.CommentThread, vm: IssueDetailViewModel, currentUserId: String?, markdownContext: MarkdownRenderContext) -> some View {
        let isExpanded = expandedResolvedThreads.contains(thread.id)
        switch thread.resolutionKind {
        case .none:
            VStack(alignment: .leading, spacing: 4) {
                commentRow(thread.root, vm: vm, currentUserId: currentUserId, markdownContext: markdownContext)
                ForEach(thread.replies) { reply in
                    commentRow(reply, vm: vm, currentUserId: currentUserId, markdownContext: markdownContext)
                        .padding(.leading, 28)
                }
            }
        case .root:
            VStack(alignment: .leading, spacing: 4) {
                if !isExpanded {
                    ResolvedThreadBar(
                        count: 1 + thread.replies.count,
                        resolverName: vm.resolverDisplayName(for: thread.root),
                        language: appLanguage
                    ) {
                        expandedResolvedThreads.insert(thread.id)
                    }
                    .padding(.horizontal)
                } else {
                    CollapseResolvedBar(language: appLanguage) {
                        expandedResolvedThreads.remove(thread.id)
                    }
                    .padding(.horizontal)
                    commentRow(thread.root, vm: vm, currentUserId: currentUserId, markdownContext: markdownContext)
                    ForEach(thread.replies) { reply in
                        commentRow(reply, vm: vm, currentUserId: currentUserId, markdownContext: markdownContext)
                            .padding(.leading, 28)
                    }
                }
            }
        case .reply(let resolution):
            let otherReplies = thread.replies.filter { $0.id != resolution.id }
            VStack(alignment: .leading, spacing: 4) {
                commentRow(thread.root, vm: vm, currentUserId: currentUserId, markdownContext: markdownContext)
                if !isExpanded && !otherReplies.isEmpty {
                    CommentsFoldBar(
                        count: otherReplies.count,
                        language: appLanguage
                    ) {
                        expandedResolvedThreads.insert(thread.id)
                    }
                    .padding(.leading, 28)
                } else {
                    CollapseResolvedBar(language: appLanguage) {
                        expandedResolvedThreads.remove(thread.id)
                    }
                    .padding(.leading, 28)
                    ForEach(otherReplies) { reply in
                        commentRow(reply, vm: vm, currentUserId: currentUserId, markdownContext: markdownContext)
                            .padding(.leading, 28)
                    }
                }
                commentRow(resolution, vm: vm, currentUserId: currentUserId, markdownContext: markdownContext, isResolution: true)
                    .padding(.leading, 28)
            }
        }
    }

    private func latestProgressSection(vm: IssueDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownText("Latest Progress").font(.headline)
            if vm.isLoadingActiveTasks || vm.isLoadingAgentRuns || vm.isLoadingTimeline {
                HStack(spacing: 8) {
                    ProgressView()
                    MarkdownText("Loading latest progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let task = vm.activeTasks.first {
                progressRow(
                    icon: "bolt.circle.fill",
                    title: "Active agent task",
                    subtitle: task.status.capitalized,
                    taskId: task.id,
                    workspaceId: vm.resolvedWorkspaceId
                )
            } else if let run = vm.agentRuns.first {
                progressRow(
                    icon: run.status == "failed" ? "exclamationmark.triangle" : "bolt.circle",
                    title: "Latest agent run",
                    subtitle: run.status.capitalized,
                    taskId: run.id,
                    workspaceId: vm.resolvedWorkspaceId
                )
            } else if let entry = vm.timelineActivities.first {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        MarkdownText(vm.timelineActorName(for: entry))
                            .font(.subheadline.weight(.semibold))
                        MarkdownText(vm.activityText(for: entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    MarkdownText(iso8601DateOnlyFormatter.string(from: entry.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                MarkdownText("No progress updates yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .accessibilityIdentifier("IssueDetailLatestProgressSection")
    }

    private func progressRow(
        icon: String,
        title: String,
        subtitle: String,
        taskId: String,
        workspaceId: String?
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                MarkdownText(title)
                    .font(.subheadline.weight(.semibold))
                MarkdownText(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                selectedTranscript = AgentTranscriptSelection(taskId: taskId, workspaceId: workspaceId)
            } label: {
                Label(AppStrings.localized("Open", language: appLanguage), systemImage: "arrow.up.right")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("IssueDetailLatestProgressOpenButton")
        }
    }

    private func agentWorkDetailsSection(vm: IssueDetailViewModel) -> some View {
        DisclosureGroup(isExpanded: $isAgentWorkExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if vm.didLoadActiveTasks || vm.activeTasksError != nil || vm.isLoadingActiveTasks {
                    activeTasksSection(vm: vm)
                }
                if vm.didLoadAgentRuns || vm.agentRunsError != nil || vm.isLoadingAgentRuns {
                    agentRunsSection(vm: vm)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                MarkdownText("Agent Work Details").font(.headline)
                Spacer()
                MarkdownText("\(vm.activeTasks.count + vm.agentRuns.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.1), in: Capsule())
            }
        }
        .padding(.horizontal)
        .accessibilityIdentifier("IssueDetailAgentWorkDetails")
    }

    private func activeTasksSection(vm: IssueDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownText("Active Tasks").font(.subheadline.weight(.semibold)).padding(.horizontal)
            if vm.isLoadingActiveTasks {
                ProgressView().padding(.horizontal)
            }
            if let activeTasksError = vm.activeTasksError {
                ErrorMessageRow(message: activeTasksError) {
                    Task { await vm.loadActiveTasks() }
                }
            }
            if vm.didLoadActiveTasks && vm.activeTasks.isEmpty && vm.activeTasksError == nil && !vm.isLoadingActiveTasks {
                ContentUnavailableView("No Active Tasks", systemImage: "bolt.slash", description: Text("This issue has no running agent tasks."))
                    .padding(.horizontal)
            }
            ForEach(vm.activeTasks) { task in
                VStack(alignment: .leading, spacing: 8) {
                    AgentLiveView(taskId: task.id, workspaceId: vm.resolvedWorkspaceId)
                    HStack {
                        MarkdownText(task.status.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            pendingCancelTask = task
                            showCancelTaskConfirmation = true
                        } label: {
                            Label("Cancel Task", systemImage: "xmark.circle")
                        }
                        .disabled(vm.cancellingTaskIds.contains(task.id))
                    }
                    .padding(.horizontal)
                }
                .accessibilityIdentifier("IssueDetailActiveTaskRow")
            }
        }
    }

    private func agentRunsSection(vm: IssueDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownText("Agent Activity").font(.subheadline.weight(.semibold)).padding(.horizontal)
            if vm.isLoadingAgentRuns {
                ProgressView().padding(.horizontal)
            }
            if let agentRunsError = vm.agentRunsError {
                ErrorMessageRow(message: agentRunsError) {
                    Task { await vm.loadAgentRuns() }
                }
            }
            if vm.didLoadAgentRuns && vm.agentRuns.isEmpty && vm.agentRunsError == nil && !vm.isLoadingAgentRuns {
                ContentUnavailableView("No Agent Activity", systemImage: "bolt", description: Text("This issue has no agent runs yet."))
                    .padding(.horizontal)
            }
            if vm.activeTasks.isEmpty, let running = vm.agentRuns.first(where: { $0.status == "running" }) {
                AgentLiveView(taskId: running.id, workspaceId: vm.resolvedWorkspaceId)
            }
            ForEach(vm.agentRuns) { run in
                Button {
                    selectedTranscript = AgentTranscriptSelection(taskId: run.id, workspaceId: vm.resolvedWorkspaceId)
                } label: {
                    AgentRunRowView(
                        run: run,
                        agentName: vm.agentName(for: run.agentId),
                        agentAvatarUrl: vm.agentAvatarURL(for: run.agentId)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("IssueDetailAgentRun-\(run.id)")
            }
        }
    }

    private func timelineSection(vm: IssueDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownText("Activity").font(.headline).padding(.horizontal)
            if vm.isLoadingTimeline {
                ProgressView().padding(.horizontal)
            }
            if let timelineError = vm.timelineError {
                ErrorMessageRow(message: timelineError) {
                    Task { await vm.loadTimeline() }
                }
            }
            if vm.didLoadTimeline && vm.timelineActivities.isEmpty && vm.timelineError == nil && !vm.isLoadingTimeline {
                ContentUnavailableView("No Activity", systemImage: "clock", description: Text("This issue has no activity yet."))
                    .padding(.horizontal)
            }
            ForEach(vm.timelineActivities) { entry in
                TimelineActivityRow(
                    entry: entry,
                    actorName: vm.timelineActorName(for: entry),
                    activityText: vm.activityText(for: entry, language: appLanguage)
                )
            }
        }
    }

    private func usageSection(vm: IssueDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownText("Usage").font(.headline).padding(.horizontal)
            if vm.isLoadingUsage {
                ProgressView().padding(.horizontal)
            }
            if let usageError = vm.usageError {
                ErrorMessageRow(message: usageError) {
                    Task { await vm.loadUsage() }
                }
            }
            if let usage = vm.usage {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownText(vm.usageSummaryText(language: appLanguage))
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        UsageMetricView(title: "Input", value: usage.totalInputTokens)
                        UsageMetricView(title: "Output", value: usage.totalOutputTokens)
                        UsageMetricView(title: "Cache", value: usage.totalCacheReadTokens + usage.totalCacheWriteTokens)
                    }
                }
                .padding(.horizontal)
            }
            if vm.didLoadUsage && vm.usage == nil && vm.usageError == nil && !vm.isLoadingUsage {
                ContentUnavailableView("No Usage", systemImage: "chart.bar", description: Text("This issue has no recorded task usage."))
                    .padding(.horizontal)
            }
        }
    }

    private func commentInputBar(vm: IssueDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !vm.commentAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.commentAttachments) { attachment in
                            Label {
                                MarkdownText(attachment.filename)
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "paperclip")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                    .padding(.horizontal)
                }
            }

            HStack(spacing: composerFocus == .comment ? 12 : 8) {
                if composerFocus == .comment {
                    PhotosPicker(
                        selection: $selectedCommentImageItem,
                        matching: .images
                    ) {
                        if vm.isUploadingCommentAttachment {
                            ProgressView()
                        } else {
                            Image(systemName: "photo.circle")
                                .font(.title3)
                        }
                    }
                    .disabled(vm.isUploadingCommentAttachment || vm.isSubmittingComment)
                    .accessibilityIdentifier("IssueDetailAddCommentImageButton")

                    Button {
                        showCommentAttachmentImporter = true
                    } label: {
                        if vm.isUploadingCommentAttachment {
                            ProgressView()
                        } else {
                            Image(systemName: "paperclip.circle")
                                .font(.title3)
                        }
                    }
                    .disabled(vm.isUploadingCommentAttachment || vm.isSubmittingComment)
                    .accessibilityIdentifier("IssueDetailAddCommentAttachmentButton")

                    MentionPicker(candidates: vm.mentionCandidates) { candidate in
                        vm.appendMention(candidate)
                        commentMentionTrigger.reset()
                        focusComposer(.comment)
                    }
                    .disabled(vm.mentionCandidates.isEmpty || vm.isSubmittingComment)
                    .accessibilityIdentifier("IssueDetailAgentMentionButton")
                }

                GrowingComposerTextField(
                    placeholder: AppStrings.localized("Add a comment…", language: appLanguage),
                    text: Binding(get: { vm.commentDraft }, set: { vm.commentDraft = $0 }),
                    isExpanded: composerFocus == .comment,
                    minLines: 3,
                    maxLines: 8,
                    background: .secondary.opacity(0.10),
                    accessibilityIdentifier: "IssueDetailCommentInput"
                )
                .focused($composerFocus, equals: .comment)
                .onChange(of: vm.commentDraft) { _, newValue in
                    commentMentionQuery = commentMentionTrigger.update(
                        draft: newValue,
                        candidatesAvailable: !vm.mentionCandidates.isEmpty
                    )
                }

                if composerFocus == .comment {
                    Button {
                        composerFocus = nil
                        dismissIssueDetailKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.title3)
                    }
                    .accessibilityLabel(AppStrings.localized("Dismiss Keyboard", language: appLanguage))
                    .accessibilityIdentifier("IssueDetailDismissKeyboardButton")
                }

                Button {
                    Task {
                        if await vm.submitComment() {
                            composerFocus = nil
                        }
                    }
                } label: {
                    if vm.isSubmittingComment { ProgressView() }
                    else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(vm.canSubmitComment ? Color.blue : Color.secondary)
                    }
                }
                .disabled(!vm.canSubmitComment)
                .accessibilityIdentifier("IssueDetailCommentSendButton")
            }
        }
        .padding(.horizontal).padding(.vertical, 8).background(.background)
        .overlay(alignment: .top) { Divider() }
        .fileImporter(
            isPresented: $showCommentAttachmentImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleCommentAttachmentImport(result, vm: vm)
        }
        .onChange(of: selectedCommentImageItem) { _, item in
            handleCommentImageSelection(item, vm: vm)
        }
        .sheet(isPresented: Binding(
            get: { commentMentionQuery != nil && !vm.mentionCandidates.isEmpty },
            set: { isPresented in
                if !isPresented {
                    commentMentionTrigger.dismissCurrentTrigger()
                    commentMentionQuery = nil
                }
            }
        )) {
            MentionCandidatePickerSheet(candidates: vm.mentionCandidates, query: Binding(
                get: { commentMentionQuery ?? "" },
                set: { commentMentionQuery = $0 }
            ), presence: vm.presenceByAgentId) { candidate in
                vm.appendMention(candidate)
                commentMentionTrigger.reset()
                commentMentionQuery = nil
            } onCancel: {
                commentMentionTrigger.dismissCurrentTrigger()
                commentMentionQuery = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func replyInputBar(vm: IssueDetailViewModel, target: IssueReplyTarget) -> some View {
        let replyAttachments = vm.replyAttachments[target.commentId] ?? []
        let isUploadingReplyAttachment = vm.uploadingReplyAttachmentIds.contains(target.commentId)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                MarkdownText("Replying to \(target.authorDisplayName)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }

            if !replyAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(replyAttachments) { attachment in
                            Label {
                                MarkdownText(attachment.filename)
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "paperclip")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.secondary.opacity(0.1), in: Capsule())
                        }
                    }
                }
            }

            if let replyAttachmentError {
                MarkdownText(replyAttachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: composerFocus == .reply ? 12 : 8) {
                if composerFocus == .reply {
                    PhotosPicker(
                        selection: $selectedReplyImageItem,
                        matching: .images
                    ) {
                        if isUploadingReplyAttachment {
                            ProgressView()
                        } else {
                            Image(systemName: "photo.circle")
                                .font(.title3)
                        }
                    }
                    .disabled(isUploadingReplyAttachment || vm.isSubmittingComment)
                    .accessibilityIdentifier("CommentReplyAddImageButton")

                    Button {
                        showReplyAttachmentImporter = true
                    } label: {
                        if isUploadingReplyAttachment {
                            ProgressView()
                        } else {
                            Image(systemName: "paperclip.circle")
                                .font(.title3)
                        }
                    }
                    .disabled(isUploadingReplyAttachment || vm.isSubmittingComment)
                    .accessibilityIdentifier("CommentReplyAddAttachmentButton")

                    MentionPicker(candidates: vm.mentionCandidates) { candidate in
                        IssueDetailViewModel.appendMention(candidate, to: &replyDraft, mentions: &replyDraftMentions)
                        replyMentionTrigger.reset()
                        focusComposer(.reply)
                    }
                    .disabled(vm.mentionCandidates.isEmpty || vm.isSubmittingComment)
                    .accessibilityIdentifier("CommentReplyAgentMentionButton")
                }

                GrowingComposerTextField(
                    placeholder: AppStrings.localized("Reply…", language: appLanguage),
                    text: $replyDraft,
                    isExpanded: composerFocus == .reply,
                    minLines: 3,
                    maxLines: 8,
                    background: Color.accentColor.opacity(0.08),
                    accessibilityIdentifier: "IssueDetailReplyInput"
                )
                    .focused($composerFocus, equals: .reply)
                    .onChange(of: replyDraft) { _, newValue in
                        replyMentionQuery = replyMentionTrigger.update(
                            draft: newValue,
                            candidatesAvailable: !vm.mentionCandidates.isEmpty
                        )
                    }

                if composerFocus == .reply {
                    Button {
                        composerFocus = nil
                        dismissIssueDetailKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.title3)
                    }
                    .accessibilityLabel(AppStrings.localized("Dismiss Keyboard", language: appLanguage))
                    .accessibilityIdentifier("CommentReplyDismissKeyboardButton")
                }

                Button {
                    Task { await submitActiveReply(vm: vm, target: target) }
                } label: {
                    if vm.isSubmittingComment {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSubmitReply(vm: vm, target: target) ? Color.blue : Color.secondary)
                    }
                }
                .disabled(!canSubmitReply(vm: vm, target: target) || isUploadingReplyAttachment)
                .accessibilityIdentifier("IssueDetailReplySendButton")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.background)
        .overlay(alignment: .top) { Divider() }
        .fileImporter(
            isPresented: $showReplyAttachmentImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            handleReplyAttachmentImport(result, vm: vm, target: target)
        }
        .onChange(of: selectedReplyImageItem) { _, item in
            handleReplyImageSelection(item, vm: vm, target: target)
        }
        .sheet(isPresented: Binding(
            get: { replyMentionQuery != nil && !vm.mentionCandidates.isEmpty },
            set: { isPresented in
                if !isPresented {
                    replyMentionTrigger.dismissCurrentTrigger()
                    replyMentionQuery = nil
                }
            }
        )) {
            MentionCandidatePickerSheet(candidates: vm.mentionCandidates, query: Binding(
                get: { replyMentionQuery ?? "" },
                set: { replyMentionQuery = $0 }
            )) { candidate in
                IssueDetailViewModel.appendMention(candidate, to: &replyDraft, mentions: &replyDraftMentions)
                replyMentionTrigger.reset()
                replyMentionQuery = nil
            } onCancel: {
                replyMentionTrigger.dismissCurrentTrigger()
                replyMentionQuery = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
                await viewModel?.silentRefresh()
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    private func startReply(to comment: Comment, authorDisplayName: String) {
        activeReplyTarget = IssueReplyTarget(commentId: comment.id, authorDisplayName: authorDisplayName)
        replyDraft = ""
        replyDraftMentions = []
        replyMentionQuery = nil
        replyAttachmentError = nil
        focusComposer(.reply)
    }

    private func cancelActiveReply(vm: IssueDetailViewModel) {
        if let activeReplyTarget {
            vm.replyAttachments[activeReplyTarget.commentId] = []
        }
        activeReplyTarget = nil
        replyDraft = ""
        replyDraftMentions = []
        replyMentionQuery = nil
        replyAttachmentError = nil
        selectedReplyImageItem = nil
        composerFocus = nil
        dismissIssueDetailKeyboard()
    }

    private func canSubmitReply(vm: IssueDetailViewModel, target: IssueReplyTarget) -> Bool {
        (
            !replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !(vm.replyAttachments[target.commentId] ?? []).isEmpty
        ) &&
        !vm.isSubmittingComment &&
        !vm.uploadingReplyAttachmentIds.contains(target.commentId)
    }

    private func submitActiveReply(vm: IssueDetailViewModel, target: IssueReplyTarget) async {
        let content = IssueDetailViewModel.serializeMentionDraft(
            replyDraft,
            mentions: replyDraftMentions
        )
        let submitted = await vm.submitReply(parentId: target.commentId, content: content)
        if submitted {
            activeReplyTarget = nil
            replyDraft = ""
            replyDraftMentions = []
            replyMentionQuery = nil
            replyAttachmentError = nil
            selectedReplyImageItem = nil
            composerFocus = nil
        }
    }

    private func handleReplyAttachmentImport(
        _ result: Result<[URL], Error>,
        vm: IssueDetailViewModel,
        target: IssueReplyTarget
    ) {
        do {
            guard let url = try result.get().first else { return }
            let payload = try AttachmentImport.payload(from: url)
            replyAttachmentError = nil
            Task {
                let uploaded = await vm.uploadReplyAttachment(
                    parentId: target.commentId,
                    filename: payload.filename,
                    data: payload.data,
                    contentType: payload.contentType
                )
                if !uploaded {
                    replyAttachmentError = AppStrings.localized("Upload failed.", language: appLanguage)
                }
            }
        } catch {
            replyAttachmentError = error.localizedDescription
        }
    }

    private func handleReplyImageSelection(
        _ item: PhotosPickerItem?,
        vm: IssueDetailViewModel,
        target: IssueReplyTarget
    ) {
        guard let item else { return }
        Task { @MainActor in
            defer { selectedReplyImageItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentImportError.unreadableImage
                }
                let payload = try AttachmentImport.imagePayload(
                    data: data,
                    contentType: item.supportedContentTypes.first { $0.conforms(to: .image) },
                    filenamePrefix: "reply-image"
                )
                replyAttachmentError = nil
                let uploaded = await vm.uploadReplyAttachment(
                    parentId: target.commentId,
                    filename: payload.filename,
                    data: payload.data,
                    contentType: payload.contentType
                )
                if !uploaded {
                    replyAttachmentError = AppStrings.localized("Upload failed.", language: appLanguage)
                }
            } catch {
                replyAttachmentError = error.localizedDescription
            }
        }
    }

    private func focusComposer(_ focus: IssueComposerFocus) {
        Task { @MainActor in
            await Task.yield()
            composerFocus = focus
        }
    }

    private func handleCommentAttachmentImport(_ result: Result<[URL], Error>, vm: IssueDetailViewModel) {
        do {
            guard let url = try result.get().first else { return }
            let payload = try AttachmentImport.payload(from: url)
            Task {
                await vm.uploadCommentAttachment(
                    filename: payload.filename,
                    data: payload.data,
                    contentType: payload.contentType
                )
            }
        } catch {
            vm.error = error.localizedDescription
        }
    }

    private func handleCommentImageSelection(_ item: PhotosPickerItem?, vm: IssueDetailViewModel) {
        guard let item else { return }
        Task { @MainActor in
            defer { selectedCommentImageItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentImportError.unreadableImage
                }
                let payload = try AttachmentImport.imagePayload(
                    data: data,
                    contentType: item.supportedContentTypes.first { $0.conforms(to: .image) },
                    filenamePrefix: "comment-image"
                )
                await vm.uploadCommentAttachment(
                    filename: payload.filename,
                    data: payload.data,
                    contentType: payload.contentType
                )
            } catch {
                vm.error = error.localizedDescription
            }
        }
    }

    private func handleMarkdownURL(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "mention", url.host == "issue" {
            guard let rawIssueId = url.pathComponents.dropFirst().first,
                  let targetIssueId = rawIssueId.removingPercentEncoding,
                  !targetIssueId.isEmpty
            else {
                return .handled
            }
            Task { await openIssueId(targetIssueId) }
            return .handled
        }

        if url.scheme == "mention" {
            return .handled
        }
        guard url.scheme == "multi-casual",
              url.host == "issue-reference",
              let rawIdentifier = url.pathComponents.dropFirst().first,
              let identifier = rawIdentifier.removingPercentEncoding
        else {
            return .systemAction
        }

        Task { await openIssueReference(identifier) }
        return .handled
    }

    @MainActor
    private func openIssueReference(_ identifier: String) async {
        guard let vm = viewModel else { return }
        do {
            let issue = try await vm.resolveIssueReference(identifier)
            guard issue.id != issueId else { return }
            issueReferenceTarget = IssueReferenceNavigationTarget(issueId: issue.id, identifier: issue.identifier)
        } catch {
            issueReferenceError = error.localizedDescription
        }
    }

    @MainActor
    private func openIssueId(_ targetIssueId: String) async {
        let normalizedIssueId = targetIssueId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedIssueId.isEmpty, normalizedIssueId != issueId else { return }
        issueReferenceTarget = IssueReferenceNavigationTarget(issueId: normalizedIssueId, identifier: normalizedIssueId)
    }
}

private struct AgentTranscriptSelection: Identifiable {
    let taskId: String
    let workspaceId: String?

    var id: String { "\(workspaceId ?? "current"):\(taskId)" }
}

private struct IssueReferenceNavigationTarget: Identifiable, Hashable {
    let issueId: String
    let identifier: String

    var id: String { issueId }
}

private struct IssueReplyTarget: Identifiable, Hashable {
    let commentId: String
    let authorDisplayName: String

    var id: String { commentId }
}

private enum IssueComposerFocus: Hashable {
    case comment
    case reply
}

private func dismissIssueDetailKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private struct ErrorMessageRow: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        Group {
            if let retry {
                ErrorRetryView(message: message, retry: retry)
            } else {
                MarkdownText(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
    }
}

public struct CommentRowView: View {
    public let comment: Comment
    let authorDisplayName: String
    let authorAvatarUrl: String?
    let currentUserId: String?
    let markdownContext: MarkdownRenderContext
    let onStartReply: (Comment) -> Void
    let onEdit: (String, String) async -> Bool
    let onDelete: (String) async -> Bool
    let onPreviewAttachment: (Attachment) -> Void
    /// Resolve / unresolve this comment as the thread's answer. `resolve` true =
    /// mark resolved, false = unresolve. Available on any comment (root or reply).
    let onResolve: (String, Bool) async -> Void
    let isResolving: Bool
    /// True when this comment is the thread's pinned resolution ("Resolve
    /// thread with comment"). Renders a stronger green "Resolution" badge so the
    /// conclusion stays visually distinct from the folded middle replies.
    let isResolution: Bool

    @State private var isEditing = false
    @State private var editDraft = ""
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false
    @Environment(\.appLanguage) private var appLanguage
    @FocusState private var isEditFocused: Bool

    public init(
        comment: Comment,
        authorDisplayName: String? = nil,
        authorAvatarUrl: String? = nil,
        currentUserId: String? = nil,
        markdownContext: MarkdownRenderContext = .empty,
        onStartReply: @escaping (Comment) -> Void = { _ in },
        onEdit: @escaping (String, String) async -> Bool = { _, _ in false },
        onDelete: @escaping (String) async -> Bool = { _ in false },
        onPreviewAttachment: @escaping (Attachment) -> Void = { _ in },
        onResolve: @escaping (String, Bool) async -> Void = { _, _ in },
        isResolving: Bool = false,
        isResolution: Bool = false
    ) {
        self.comment = comment
        self.authorDisplayName = authorDisplayName ?? (comment.authorType == "agent" ? "Agent" : "Member")
        self.authorAvatarUrl = authorAvatarUrl
        self.currentUserId = currentUserId
        self.markdownContext = markdownContext
        self.onStartReply = onStartReply
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onPreviewAttachment = onPreviewAttachment
        self.onResolve = onResolve
        self.isResolving = isResolving
        self.isResolution = isResolution
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AvatarView(
                    name: authorDisplayName,
                    avatarUrl: authorAvatarUrl,
                    kind: comment.authorType == "agent" ? .agent : .user,
                    size: 24
                )
                MarkdownText(authorDisplayName).font(.caption.bold())
                if comment.isResolved {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                        MarkdownText(AppStrings.localized(isResolution ? "Resolution" : "Resolved", language: appLanguage)).font(.caption2.bold())
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12), in: Capsule())
                    .accessibilityIdentifier("CommentResolvedBadge-\(comment.id)")
                }
                Spacer()
                MarkdownText(iso8601DateTimeFormatter.string(from: comment.createdAt)).font(.caption2).foregroundStyle(.secondary)
                if currentUserId != nil {
                    Button {
                        onStartReply(comment)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrowshape.turn.up.left")
                            Text(AppStrings.localized("Reply", language: appLanguage))
                        }
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("CommentInlineReplyButton")
                }
                if canEdit || canDelete || canResolve {
                    Menu {
                        if canResolve {
                            Button {
                                Task { await onResolve(comment.id, !comment.isResolved) }
                            } label: {
                                Label(
                                    AppStrings.localized(
                                        comment.isResolved ? "Unresolve" : resolveMenuTitle,
                                        language: appLanguage
                                    ),
                                    systemImage: comment.isResolved ? "minus.circle" : "checkmark.circle"
                                )
                            }
                            .disabled(isResolving)
                            .accessibilityIdentifier("CommentResolveButton-\(comment.id)")
                        }

                        if canEdit {
                            Button {
                                editDraft = comment.content
                                isEditing = true
                                focusEdit()
                            } label: {
                                Label(AppStrings.localized("Edit", language: appLanguage), systemImage: "pencil")
                            }
                        }

                        if canDelete {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Label(AppStrings.localized("Delete", language: appLanguage), systemImage: "trash")
                            }
                        }
                    } label: {
                        if isResolving {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "ellipsis.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(AppStrings.localized("Comment Actions", language: appLanguage))
                }
            }
            if isEditing {
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $editDraft)
                        .frame(minHeight: 88)
                        .padding(8)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .focused($isEditFocused)
                        .accessibilityIdentifier("CommentEditEditor")
                    HStack(spacing: 8) {
                        Button(AppStrings.localized("Cancel", language: appLanguage)) {
                            editDraft = ""
                            isEditing = false
                            isEditFocused = false
                        }
                        .buttonStyle(.borderless)

                        Button {
                            Task { await saveEdit() }
                        } label: {
                            if isSaving {
                                ProgressView()
                            } else {
                                Text(AppStrings.localized("Save", language: appLanguage))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } else {
                MarkdownText(comment.content, context: markdownContext).font(.body)
            }
            if !comment.attachments.isEmpty {
                AttachmentListView(attachments: comment.attachments, onPreview: onPreviewAttachment)
            }
        }.padding(.horizontal).padding(.vertical, 6)
            .alert(AppStrings.localized("Delete Comment", language: appLanguage), isPresented: $showDeleteConfirmation) {
                Button(AppStrings.localized("Delete", language: appLanguage), role: .destructive) {
                    Task {
                        isSaving = true
                        _ = await onDelete(comment.id)
                        isSaving = false
                    }
                }
                Button(AppStrings.localized("Cancel", language: appLanguage), role: .cancel) {}
            } message: {
                Text(AppStrings.localized("This comment and its replies will be deleted.", language: appLanguage))
            }
    }

    private var canEdit: Bool {
        comment.authorType == "member" && comment.authorId == currentUserId
    }

    private var canDelete: Bool {
        comment.authorId == currentUserId
    }

    /// Any signed-in workspace member can resolve / unresolve a comment thread.
    private var canResolve: Bool {
        currentUserId != nil
    }

    /// Root comments show "Resolve Thread" (whole-thread fold); replies show
    /// "Resolve Thread with Comment" (root + resolution visible, middle folds).
    /// Matches web's `resolve_thread_action` / `resolve_with_comment_action`.
    private var resolveMenuTitle: String {
        comment.parentId == nil ? "Resolve Thread" : "Resolve Thread with Comment"
    }

    private func focusEdit() {
        Task { @MainActor in
            await Task.yield()
            isEditFocused = true
        }
    }

    private func saveEdit() async {
        isSaving = true
        defer { isSaving = false }
        let saved = await onEdit(comment.id, editDraft)
        if saved {
            editDraft = ""
            isEditing = false
            isEditFocused = false
        }
    }

}

/// One-line bar shown at the top of a resolved comment thread. Defaults to
/// Whole-thread fold — the ROOT comment is resolved ("Resolve thread"). The
/// entire thread (root + every reply) collapses into this one bar; tapping
/// expands to show the full thread. Mirrors web's `ResolvedThreadBar`.
private struct ResolvedThreadBar: View {
    let count: Int
    let resolverName: String
    let language: AppLanguage
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                MarkdownText(AppStrings.localized("N resolved comments", language: language, count: count))
                    .font(.caption.bold())
                MarkdownText("·")
                MarkdownText(resolverName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ResolvedThreadBar")
        .accessibilityLabel(AppStrings.localized("This thread is resolved", language: language))
        .accessibilityValue("Collapsed")
    }
}

/// Middle fold — a REPLY is the resolution ("Resolve thread with comment").
/// The root and the resolution reply stay visible; the OTHER replies fold
/// behind this bar, which sits between them. Mirrors web's `CommentsFoldBar`.
private struct CommentsFoldBar: View {
    let count: Int
    let language: AppLanguage
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                MarkdownText(AppStrings.localized("N comments folded", language: language, count: count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("CommentsFoldBar")
        .accessibilityLabel(AppStrings.localized("N comments folded", language: language, count: count))
        .accessibilityValue("Collapsed")
    }
}

/// Shown at the top of an EXPANDED resolved thread so the user can fold it
/// back up. Mirrors web's sticky "Collapse" affordance. Tapping re-collapses
/// the thread (root-resolution folds the whole thread back to ResolvedThreadBar;
/// reply-resolution re-hides the middle replies behind CommentsFoldBar).
private struct CollapseResolvedBar: View {
    let language: AppLanguage
    let onCollapse: () -> Void

    var body: some View {
        Button(action: onCollapse) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                    .font(.caption2)
                MarkdownText(AppStrings.localized("Collapse", language: language))
                    .font(.caption.bold())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("CollapseResolvedBar")
        .accessibilityLabel(AppStrings.localized("Collapse", language: language))
    }
}

private let quickReactionEmojis = ["👍", "👀", "🚀", "❤️", "🎉"]
private struct MentionPicker: View {
    let candidates: [MentionCandidate]
    let onSelect: (MentionCandidate) -> Void
    @Environment(\.appLanguage) private var appLanguage
    @State private var isPickerPresented = false
    @State private var query = ""

    var body: some View {
        Button {
            isPickerPresented = true
        } label: {
            Image(systemName: "at")
                .font(.title3)
                .foregroundStyle(candidates.isEmpty ? Color.secondary : Color.accentColor)
        }
        .disabled(candidates.isEmpty)
        .accessibilityLabel(AppStrings.localized("Mention", language: appLanguage))
        .sheet(isPresented: $isPickerPresented) {
            MentionCandidatePickerSheet(candidates: candidates, query: $query) { candidate in
                onSelect(candidate)
                query = ""
                isPickerPresented = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct ReactionBadge: Identifiable {
    let emoji: String
    let count: Int
    let isSelected: Bool

    var id: String { emoji }
}

private struct ReactionBarView: View {
    let badges: [ReactionBadge]
    let onToggle: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(badges) { badge in
                Button {
                    onToggle(badge.emoji)
                } label: {
                    MarkdownText("\(badge.emoji) \(badge.count)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            badge.isSelected ? Color.blue.opacity(0.16) : Color.secondary.opacity(0.1),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            Menu {
                ForEach(quickReactionEmojis, id: \.self) { emoji in
                    Button {
                        onToggle(emoji)
                    } label: {
                        MarkdownText(emoji)
                    }
                }
            } label: {
                Image(systemName: "face.smiling")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.secondary.opacity(0.08), in: Capsule())
            }
            .accessibilityLabel("Add Reaction")
        }
    }
}

private struct SubscriberChip: View {
    let subscriber: IssueSubscriber
    let name: String
    let avatarUrl: String?

    var body: some View {
        HStack(spacing: 5) {
            AvatarView(
                name: name,
                avatarUrl: avatarUrl,
                kind: subscriber.userType == "agent" ? .agent : .user,
                size: 18
            )
            MarkdownText(name)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.1), in: Capsule())
    }
}

private struct SubscriberManagementView: View {
    @Bindable var vm: IssueDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        NavigationStack {
            List {
                let activeAgents = vm.subscriberAgents.filter { $0.archivedAt == nil }
                if vm.subscriberMembers.isEmpty && activeAgents.isEmpty {
                    Section {
                        if vm.isLoadingSubscribers {
                            ProgressView()
                        } else {
                            Text(AppStrings.localized("No people or agents available", language: appLanguage))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !vm.subscriberMembers.isEmpty {
                    Section("Members") {
                        ForEach(uniqueMembers(vm.subscriberMembers)) { member in
                            SubscriberToggleRow(
                                title: member.name,
                                subtitle: member.email,
                                avatarUrl: member.avatarUrl,
                                kind: .user,
                                isSelected: vm.isSubscribed(userId: member.userId, userType: "member"),
                                isLoading: vm.isLoadingSubscribers
                            ) {
                                Task { await vm.toggleSubscriber(userId: member.userId, userType: "member") }
                            }
                        }
                    }
                }
                if !activeAgents.isEmpty {
                    Section("Agents") {
                        ForEach(activeAgents) { agent in
                            SubscriberToggleRow(
                                title: agent.name,
                                subtitle: agent.status.capitalized,
                                avatarUrl: agent.avatarUrl,
                                kind: .agent,
                                isSelected: vm.isSubscribed(userId: agent.id, userType: "agent"),
                                isLoading: vm.isLoadingSubscribers
                            ) {
                                Task { await vm.toggleSubscriber(userId: agent.id, userType: "agent") }
                            }
                        }
                    }
                }
                if let subscribersError = vm.subscribersError {
                    Section {
                        ErrorMessageRow(message: subscribersError) {
                            Task { await vm.loadSubscribers() }
                        }
                        .padding(.horizontal, -16)
                    }
                }
            }
            .navigationTitle(AppStrings.localized("Subscribers", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppStrings.localized("Done", language: appLanguage)) { dismiss() }
                }
            }
            .task {
                if !vm.didLoadSubscribers {
                    await vm.loadSubscribers()
                }
            }
        }
    }

    private func uniqueMembers(_ members: [WorkspaceMember]) -> [WorkspaceMember] {
        var seen = Set<String>()
        return members.filter { member in
            guard !seen.contains(member.userId) else { return false }
            seen.insert(member.userId)
            return true
        }
    }
}

private struct SubscriberToggleRow: View {
    let title: String
    let subtitle: String
    let avatarUrl: String?
    let kind: AvatarView.Kind
    let isSelected: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AvatarView(name: title, avatarUrl: avatarUrl, kind: kind, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    MarkdownText(title)
                        .font(.body)
                        .lineLimit(1)
                    MarkdownText(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }
}

private struct AttachmentListView: View {
    let attachments: [Attachment]
    var deletingAttachmentIds: Set<String> = []
    var onPreview: ((Attachment) -> Void)?
    var onDelete: ((Attachment) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(attachments) { attachment in
                AttachmentRowView(
                    attachment: attachment,
                    isDeleting: deletingAttachmentIds.contains(attachment.id),
                    onPreview: onPreview,
                    onDelete: onDelete
                )
            }
        }
    }
}

private struct LabelWrapView: View {
    let labels: [IssueLabel]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels) { label in
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: label.color) ?? .secondary)
                            .frame(width: 8, height: 8)
                        MarkdownText(label.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.1), in: Capsule())
                }
            }
        }
    }
}

private struct AttachmentRowView: View {
    let attachment: Attachment
    var isDeleting = false
    var onPreview: ((Attachment) -> Void)?
    var onDelete: ((Attachment) -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let onPreview {
                    Button {
                        onPreview(attachment)
                    } label: {
                        rowContent
                    }
                } else if let url = URL(string: attachment.downloadUrl.isEmpty ? attachment.url : attachment.downloadUrl) {
                    Link(destination: url) {
                        rowContent
                    }
                } else {
                    rowContent
                }
            }
            .buttonStyle(.plain)

            if let onDelete {
                Button(role: .destructive) {
                    onDelete(attachment)
                } label: {
                    if isDeleting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "trash")
                    }
                }
                .disabled(isDeleting)
                .accessibilityLabel("Delete \(attachment.filename)")
                .accessibilityIdentifier("AttachmentDeleteButton-\(attachment.id)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                MarkdownText(attachment.filename)
                    .font(.caption.bold())
                    .lineLimit(1)
                MarkdownText(fileDetails)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: onPreview == nil ? "arrow.down.circle" : "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var iconName: String {
        if attachment.contentType.hasPrefix("image/") { return "photo" }
        if attachment.contentType == "application/pdf" { return "doc.richtext" }
        return "paperclip"
    }

    private var fileDetails: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(attachment.sizeBytes))
    }
}

public struct AgentRunRowView: View {
    public let run: AgentTask
    public let agentName: String?
    public let agentAvatarUrl: String?

    public init(run: AgentTask, agentName: String? = nil, agentAvatarUrl: String? = nil) {
        self.run = run
        self.agentName = agentName
        self.agentAvatarUrl = agentAvatarUrl
    }

    public var body: some View {
        HStack {
            if let agentName {
                AvatarView(name: agentName, avatarUrl: agentAvatarUrl, kind: .agent, size: 28)
            } else {
                Image(systemName: statusIcon).foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                MarkdownText(agentName ?? "Agent run").font(.subheadline.bold())
                MarkdownText(run.startedAt.map(iso8601DisplayFormatter.string(from:)) ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
    }

    private var statusIcon: String {
        switch run.status {
        case "completed": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "running": return "circle.dotted"
        default: return "clock"
        }
    }

    private var statusColor: Color {
        switch run.status {
        case "completed": return .green
        case "failed": return .red
        case "running": return .blue
        default: return .secondary
        }
    }
}

private struct TimelineActivityRow: View {
    let entry: TimelineEntry
    let actorName: String
    let activityText: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    MarkdownText(actorName)
                        .font(.caption.weight(.semibold))
                    MarkdownText(iso8601DateOnlyFormatter.string(from: entry.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                MarkdownText(activityText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch entry.action {
        case "status_changed":
            return "circle.dotted"
        case "priority_changed":
            return "flag"
        case "assignee_changed":
            return "person.crop.circle"
        case "due_date_changed":
            return "calendar"
        case "task_completed":
            return "checkmark.circle"
        case "task_failed":
            return "exclamationmark.triangle"
        default:
            return "clock"
        }
    }
}

private struct UsageMetricView: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MarkdownText(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            MarkdownText(value.formatted())
                .font(.caption.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
