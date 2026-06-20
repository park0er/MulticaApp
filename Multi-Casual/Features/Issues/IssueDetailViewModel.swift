import Foundation
import Observation


@MainActor
public struct MentionTriggerSession: Sendable {
    private var dismissedTriggerStartOffset: Int?
    private var activeTriggerStartOffset: Int?

    public init() {}

    public mutating func update(draft: String, candidatesAvailable: Bool) -> String? {
        guard candidatesAvailable,
              let trigger = IssueDetailViewModel.activeMentionTrigger(in: draft)
        else {
            if IssueDetailViewModel.activeMentionTrigger(in: draft) == nil {
                dismissedTriggerStartOffset = nil
                activeTriggerStartOffset = nil
            }
            return nil
        }

        activeTriggerStartOffset = trigger.startOffset
        guard dismissedTriggerStartOffset != trigger.startOffset else { return nil }
        return trigger.query
    }

    public mutating func dismissCurrentTrigger() {
        dismissedTriggerStartOffset = activeTriggerStartOffset
    }

    public mutating func reset() {
        dismissedTriggerStartOffset = nil
        activeTriggerStartOffset = nil
    }
}

@Observable
@MainActor
public final class IssueDetailViewModel {
    public struct MentionDraftToken: Equatable, Sendable {
        public let visibleText: String
        public let markdown: String

        public init(visibleText: String, markdown: String) {
            self.visibleText = visibleText
            self.markdown = markdown
        }
    }

    public struct CommentThread: Identifiable, Sendable {
        public let root: Comment
        public let replies: [Comment]

        public var id: String { root.id }
    }

    public enum CommentSortOrder: String, CaseIterable, Identifiable {
        case ascending
        case descending

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .ascending: return "Oldest First"
            case .descending: return "Newest First"
            }
        }
    }

    public let issueId: String
    public let workspaceId: String?
    public var issue: Issue?
    public var parentIssue: Issue?
    public var childIssues: [Issue] = []
    public var parentSiblingIssues: [Issue] = []
    public var agentRuns: [AgentTask] = []
    public var activeTasks: [AgentTask] = []
    public var timelineEntries: [TimelineEntry] = []
    public var usage: IssueUsageSummary?
    public var subscribers: [IssueSubscriber] = []
    public var subscriberMembers: [WorkspaceMember] = []
    public var subscriberAgents: [Agent] = []
    public var subscriberSquads: [Squad] = []
    public let commentLoader = PaginatedLoader<Comment>()
    public private(set) var commentSortOrder: CommentSortOrder = .descending
    public var commentDraft = ""
    public var commentDraftMentions: [MentionDraftToken] = []
    public var commentAttachments: [Attachment] = []
    public var replyAttachments: [String: [Attachment]] = [:]
    public var isSubmittingComment = false
    public var isUploadingCommentAttachment = false
    public var uploadingReplyAttachmentIds: Set<String> = []
    public var isLoadingIssue = false
    public var isLoadingComments = false
    public var isLoadingAgentRuns = false
    public var isLoadingActiveTasks = false
    public var isLoadingTimeline = false
    public var isLoadingUsage = false
    public var isLoadingSubscribers = false
    public var isLoadingIssueRelations = false
    public var isLoadingAttachments = false
    public var isDeletingIssue = false
    public var cancellingTaskIds: Set<String> = []
    public var deletingAttachmentIds: Set<String> = []
    public var didLoadComments = false
    public var didLoadAgentRuns = false
    public var didLoadActiveTasks = false
    public var didLoadTimeline = false
    public var didLoadUsage = false
    public var didLoadSubscribers = false
    public var didLoadIssueRelations = false
    public var error: String?
    public var commentsError: String?
    public var agentRunsError: String?
    public var activeTasksError: String?
    public var timelineError: String?
    public var usageError: String?
    public var subscribersError: String?
    public var issueRelationsError: String?
    public var attachmentsError: String?
    public var metadataError: String?
    public var deleteIssueError: String?
    public var didDeleteIssue = false
    public var assigneeDisplayName: String?
    public var projectDisplayName: String?
    public var isUpdatingIssue = false

    private let api: APIClient

    public var resolvedWorkspaceId: String? {
        workspaceId ?? issue?.workspaceId
    }

    public init(issueId: String, workspaceId: String? = nil, api: APIClient) {
        self.issueId = issueId
        self.workspaceId = workspaceId
        self.api = api
    }

    public var canSubmitComment: Bool {
        (
            !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !commentAttachments.isEmpty
        ) &&
        !isSubmittingComment &&
        !isUploadingCommentAttachment
    }

    public var childProgressText: String {
        "\(doneCount(in: childIssues))/\(childIssues.count)"
    }

    public var parentChildProgressText: String {
        "\(doneCount(in: parentSiblingIssues))/\(parentSiblingIssues.count)"
    }

    public var timelineActivities: [TimelineEntry] {
        timelineEntries.filter { $0.type == .activity }
    }

    public var displayedComments: [Comment] {
        commentLoader.items.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id :
                (commentSortOrder == .ascending ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt)
        }
    }

    public var displayedCommentThreads: [CommentThread] {
        let commentsById = Dictionary(uniqueKeysWithValues: commentLoader.items.map { ($0.id, $0) })
        let rootIdsByCommentId = Dictionary(uniqueKeysWithValues: commentLoader.items.map {
            ($0.id, rootCommentId(for: $0, commentsById: commentsById))
        })
        let rootComments = commentLoader.items.filter { rootIdsByCommentId[$0.id] == $0.id }
        let sortedRoots = sortRootComments(rootComments)

        return sortedRoots.map { root in
            let replies = commentLoader.items
                .filter { $0.id != root.id && rootIdsByCommentId[$0.id] == root.id }
                .sorted { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt { return lhs.id < rhs.id }
                    return commentSortOrder == .ascending
                        ? lhs.createdAt < rhs.createdAt
                        : lhs.createdAt > rhs.createdAt
                }
            return CommentThread(root: root, replies: replies)
        }
    }

    public var usageSummaryText: String {
        usageSummaryText(language: .english)
    }

    public func usageSummaryText(language: AppLanguage) -> String {
        guard let usage else { return AppStrings.localized("No usage recorded", language: language) }
        let taskUnit = usage.taskCount == 1 ? "task" : "tasks"
        if language == .zhHans {
            return "\(formatTokenCount(usage.totalTokens)) tokens，跨 \(usage.taskCount) 个任务"
        }
        return "\(formatTokenCount(usage.totalTokens)) tokens across \(usage.taskCount) \(taskUnit)"
    }

    public var mentionCandidates: [MentionCandidate] {
        let people = subscriberMembers.map {
            MentionCandidate(
                type: .person,
                entityId: $0.userId,
                displayName: $0.name,
                subtitle: $0.email,
                avatarUrl: $0.avatarUrl
            )
        }
        let agents = subscriberAgents
            .filter { $0.archivedAt == nil }
            .map {
                MentionCandidate(
                    type: .agent,
                    entityId: $0.id,
                    displayName: $0.name,
                    subtitle: "Agent",
                    avatarUrl: $0.avatarUrl
                )
            }
        let squads = subscriberSquads
            .filter { $0.archivedAt == nil }
            .map {
                MentionCandidate(
                    type: .squad,
                    entityId: $0.id,
                    displayName: $0.name,
                    subtitle: $0.description.isEmpty ? "Squad" : "Squad · \($0.description)",
                    avatarUrl: $0.avatarUrl
                )
            }
        return (people + agents + squads).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    public func commentMarkdownContext(issuePrefix: String?) -> MarkdownRenderContext {
        var mentionDisplayNames: [String: String] = [:]
        for member in subscriberMembers {
            mentionDisplayNames["mention://member/\(member.userId)"] = member.name
            mentionDisplayNames["mention://member/\(member.id)"] = member.name
            mentionDisplayNames["mention://user/\(member.userId)"] = member.name
            mentionDisplayNames["mention://user/\(member.id)"] = member.name
        }
        for agent in subscriberAgents {
            mentionDisplayNames["mention://agent/\(agent.id)"] = agent.name
        }
        for squad in subscriberSquads {
            mentionDisplayNames["mention://squad/\(squad.id)"] = squad.name
        }

        let resolvedPrefix = issuePrefix?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? issuePrefix
            : issue?.identifier.split(separator: "-").first.map(String.init)

        return MarkdownRenderContext(
            mentionDisplayNamesByURL: mentionDisplayNames,
            issueReferencePrefixes: resolvedPrefix.map { [$0] } ?? []
        )
    }

    public func appendMention(_ candidate: MentionCandidate) {
        Self.appendMention(candidate, to: &commentDraft, mentions: &commentDraftMentions)
    }

    public func serializedCommentDraft() -> String {
        Self.serializeMentionDraft(commentDraft, mentions: commentDraftMentions)
    }

    public static func appendMention(
        _ candidate: MentionCandidate,
        to draft: inout String,
        mentions: inout [MentionDraftToken]
    ) {
        if replaceActiveMentionTrigger(with: candidate, in: &draft, mentions: &mentions) {
            return
        }
        let visible = candidate.visibleText
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedDraft.isEmpty {
            draft = "\(visible) "
        } else if draft.last?.isWhitespace == true {
            draft += "\(visible) "
        } else {
            draft += " \(visible) "
        }
        let token = MentionDraftToken(visibleText: visible, markdown: mentionMarkdown(candidate))
        if !mentions.contains(token) {
            mentions.append(token)
        }
    }

    @discardableResult
    public static func replaceActiveMentionTrigger(
        with candidate: MentionCandidate,
        in draft: inout String,
        mentions: inout [MentionDraftToken]
    ) -> Bool {
        guard let range = activeMentionTriggerRange(in: draft) else { return false }
        let insertion = candidate.visibleText + " "
        draft.replaceSubrange(range, with: insertion)
        let token = MentionDraftToken(visibleText: candidate.visibleText, markdown: mentionMarkdown(candidate))
        if !mentions.contains(token) {
            mentions.append(token)
        }
        return true
    }

    public struct ActiveMentionTrigger: Sendable, Equatable {
        public let query: String
        public let startOffset: Int
    }

    public static func activeMentionQuery(in draft: String) -> String? {
        activeMentionTrigger(in: draft)?.query
    }

    public static func activeMentionTrigger(in draft: String) -> ActiveMentionTrigger? {
        guard let range = activeMentionTriggerRange(in: draft) else { return nil }
        return ActiveMentionTrigger(
            query: String(draft[range].dropFirst()),
            startOffset: draft.distance(from: draft.startIndex, to: range.lowerBound)
        )
    }

    private static func activeMentionTriggerRange(in draft: String) -> Range<String.Index>? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        let afterAt = draft.index(after: atIndex)
        let query = draft[afterAt...]
        guard !query.contains(where: { $0.isWhitespace || $0 == "[" || $0 == "]" || $0 == "(" || $0 == ")" }) else {
            return nil
        }
        if atIndex > draft.startIndex {
            let beforeAt = draft[draft.index(before: atIndex)]
            guard beforeAt.isWhitespace || beforeAt == "(" || beforeAt == "[" else { return nil }
        }
        return atIndex..<draft.endIndex
    }

    public static func serializeMentionDraft(_ draft: String, mentions: [MentionDraftToken]) -> String {
        mentions
            .sorted { $0.visibleText.count > $1.visibleText.count }
            .reduce(draft) { rendered, mention in
                rendered.replacingOccurrences(of: mention.visibleText, with: mention.markdown)
            }
    }

    public static func mentionMarkdown(_ candidate: MentionCandidate) -> String {
        mentionMarkdown(type: candidate.type.payloadType, entityId: candidate.entityId, label: candidate.displayName)
    }

    private static func agentMentionMarkdown(agentId: String, label: String) -> String {
        mentionMarkdown(type: MentionEntityType.agent.payloadType, entityId: agentId, label: label)
    }

    private static func mentionMarkdown(type: String, entityId: String, label: String) -> String {
        let escapedLabel = label
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[@\(escapedLabel)](mention://\(type)/\(entityId))"
    }

    public func loadInitialData() async {
        await loadIssue()
        guard issue != nil, error == nil else { return }
        async let metadata: Void = loadMetadata()
        async let relations: Void = loadIssueRelations()
        async let comments: Void = loadComments()
        async let agentRuns: Void = loadAgentRuns()
        async let activeTasks: Void = loadActiveTasks()
        async let timeline: Void = loadTimeline()
        async let usage: Void = loadUsage()
        async let subscribers: Void = loadSubscribers()
        async let attachments: Void = loadAttachments()
        _ = await (metadata, relations, comments, agentRuns, activeTasks, timeline, usage, subscribers, attachments)
    }

    public func loadIssue() async {
        isLoadingIssue = true
        error = nil
        defer { isLoadingIssue = false }
        do {
            issue = try await api.getIssue(id: issueId, workspaceId: resolvedWorkspaceId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func loadIssueAndMetadata() async {
        await loadIssue()
        guard issue != nil, error == nil else { return }
        async let metadata: Void = loadMetadata()
        async let relations: Void = loadIssueRelations()
        _ = await (metadata, relations)
    }

    public func loadIssueRelations() async {
        guard let issue else { return }
        isLoadingIssueRelations = true
        issueRelationsError = nil
        defer { isLoadingIssueRelations = false }

        do {
            let workspaceId = resolvedWorkspaceId
            childIssues = try await api.listChildIssues(issueId: issue.id, workspaceId: workspaceId)
            if let parentIssueId = issue.parentIssueId {
                parentIssue = try await api.getIssue(id: parentIssueId, workspaceId: workspaceId)
                parentSiblingIssues = try await api.listChildIssues(issueId: parentIssueId, workspaceId: workspaceId)
            } else {
                parentIssue = nil
                parentSiblingIssues = []
            }
            didLoadIssueRelations = true
        } catch {
            childIssues = []
            parentIssue = nil
            parentSiblingIssues = []
            didLoadIssueRelations = true
            issueRelationsError = error.localizedDescription
        }
    }

    public func loadAttachments() async {
        isLoadingAttachments = true
        attachmentsError = nil
        defer { isLoadingAttachments = false }

        do {
            let attachments = try await api.listAttachments(issueId: issueId, workspaceId: resolvedWorkspaceId)
            if let issue {
                self.issue = issue.replacingAttachments(attachments)
            }
        } catch {
            attachmentsError = error.localizedDescription
        }
    }

    public func deleteAttachment(id: String) async {
        guard !deletingAttachmentIds.contains(id) else { return }
        deletingAttachmentIds.insert(id)
        attachmentsError = nil
        defer { deletingAttachmentIds.remove(id) }

        do {
            try await api.deleteAttachment(id: id, workspaceId: resolvedWorkspaceId)
            if let issue {
                self.issue = issue.replacingAttachments(issue.attachments.filter { $0.id != id })
            }
            await DataStore.shared.invalidateIssue(issueId)
        } catch {
            attachmentsError = error.localizedDescription
        }
    }

    public func loadMetadata() async {
        guard let issue, let workspaceId = resolvedWorkspaceId else { return }
        metadataError = nil
        assigneeDisplayName = nil
        projectDisplayName = nil

        do {
            async let members = WorkspaceMetadataCache.shared.members(workspaceId: workspaceId, api: api)
            async let agents = WorkspaceMetadataCache.shared.agents(
                workspaceId: workspaceId,
                includeArchived: true,
                api: api
            )
            async let squads = WorkspaceMetadataCache.shared.squads(
                workspaceId: workspaceId,
                includeArchived: true,
                api: api
            )
            async let projects = WorkspaceMetadataCache.shared.projects(workspaceId: workspaceId, api: api)

            let loadedMembers = try await members
            let loadedAgents = try await agents
            let loadedSquads = try await squads
            let loadedProjects = try await projects
            subscriberMembers = loadedMembers
            subscriberAgents = loadedAgents
            subscriberSquads = loadedSquads

            if let assigneeId = issue.assigneeId, let assigneeType = issue.assigneeType {
                switch assigneeType {
                case "member":
                    assigneeDisplayName = loadedMembers.first { $0.userId == assigneeId || $0.id == assigneeId }?.name
                case "agent":
                    assigneeDisplayName = loadedAgents.first { $0.id == assigneeId }?.name
                case "squad":
                    assigneeDisplayName = loadedSquads.first { $0.id == assigneeId }?.name
                default:
                    assigneeDisplayName = nil
                }
            }

            if let projectId = issue.projectId {
                if let project = loadedProjects.first(where: { $0.id == projectId }) {
                    projectDisplayName = project.name
                } else {
                    projectDisplayName = try await WorkspaceMetadataCache.shared.project(
                        id: projectId,
                        workspaceId: workspaceId,
                        api: api
                    ).name
                }
            }
        } catch {
            metadataError = error.localizedDescription
        }
    }

    public func resolveIssueReference(_ identifier: String) async throws -> Issue {
        guard let workspaceId = resolvedWorkspaceId else {
            throw UserVisibleError("Pick a workspace before opening Issues.")
        }
        let normalizedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = try await api.searchIssues(
            workspaceId: workspaceId,
            query: normalizedIdentifier,
            limit: 10,
            offset: 0,
            includeClosed: true
        )
        if let exact = page.items.first(where: { $0.identifier.caseInsensitiveCompare(normalizedIdentifier) == .orderedSame }) {
            return exact
        }
        throw UserVisibleError("Issue \(normalizedIdentifier) was not found.")
    }

    public func loadSubscribers() async {
        isLoadingSubscribers = true
        subscribersError = nil
        defer { isLoadingSubscribers = false }
        do {
            subscribers = try await api.listIssueSubscribers(issueId: issueId, workspaceId: resolvedWorkspaceId)
            didLoadSubscribers = true
        } catch {
            subscribers = []
            didLoadSubscribers = true
            subscribersError = error.localizedDescription
        }
    }

    public func isSubscribed(userId: String, userType: String) -> Bool {
        subscribers.contains { $0.userId == userId && $0.userType == userType }
    }

    public func displayName(for subscriber: IssueSubscriber) -> String {
        switch subscriber.userType {
        case "member":
            return subscriberMembers.first { $0.userId == subscriber.userId || $0.id == subscriber.userId }?.name
                ?? "成员 \(subscriber.userId.prefix(8))"
        case "agent":
            return subscriberAgents.first { $0.id == subscriber.userId }?.name
                ?? "Agent \(subscriber.userId.prefix(8))"
        case "squad":
            return subscriberSquads.first { $0.id == subscriber.userId }?.name
                ?? "Squad \(subscriber.userId.prefix(8))"
        default:
            return "\(subscriber.userType.capitalized) \(subscriber.userId.prefix(8))"
        }
    }

    public func avatarURL(for subscriber: IssueSubscriber) -> String? {
        switch subscriber.userType {
        case "member":
            return subscriberMembers.first { $0.userId == subscriber.userId || $0.id == subscriber.userId }?.avatarUrl
        case "agent":
            return subscriberAgents.first { $0.id == subscriber.userId }?.avatarUrl
        case "squad":
            return subscriberSquads.first { $0.id == subscriber.userId }?.avatarUrl
        default:
            return nil
        }
    }

    public func setCommentSortOrder(_ order: CommentSortOrder) {
        commentSortOrder = order
    }

    public func commentAuthorName(for comment: Comment) -> String {
        switch comment.authorType {
        case "member":
            return subscriberMembers.first { $0.userId == comment.authorId || $0.id == comment.authorId }?.name
                ?? "成员 \(comment.authorId.prefix(8))"
        case "agent":
            return subscriberAgents.first { $0.id == comment.authorId }?.name
                ?? "Agent \(comment.authorId.prefix(8))"
        case "squad":
            return subscriberSquads.first { $0.id == comment.authorId }?.name
                ?? "Squad \(comment.authorId.prefix(8))"
        default:
            return "\(comment.authorType.capitalized) \(comment.authorId.prefix(8))"
        }
    }

    public func commentAuthorAvatarURL(for comment: Comment) -> String? {
        switch comment.authorType {
        case "member":
            return subscriberMembers.first { $0.userId == comment.authorId || $0.id == comment.authorId }?.avatarUrl
        case "agent":
            return subscriberAgents.first { $0.id == comment.authorId }?.avatarUrl
        case "squad":
            return subscriberSquads.first { $0.id == comment.authorId }?.avatarUrl
        default:
            return nil
        }
    }

    public func agentName(for agentId: String?) -> String? {
        guard let agentId, !agentId.isEmpty else { return nil }
        return subscriberAgents.first { $0.id == agentId }?.name ?? "Agent \(agentId.prefix(8))"
    }

    public func agentAvatarURL(for agentId: String?) -> String? {
        guard let agentId, !agentId.isEmpty else { return nil }
        return subscriberAgents.first { $0.id == agentId }?.avatarUrl
    }

    public func toggleSubscriber(userId: String, userType: String) async {
        guard !isLoadingSubscribers else { return }
        isLoadingSubscribers = true
        subscribersError = nil
        let currentlySubscribed = isSubscribed(userId: userId, userType: userType)
        do {
            let workspaceId = resolvedWorkspaceId
            if currentlySubscribed {
                try await api.unsubscribeFromIssue(issueId: issueId, userId: userId, userType: userType, workspaceId: workspaceId)
            } else {
                try await api.subscribeToIssue(issueId: issueId, userId: userId, userType: userType, workspaceId: workspaceId)
            }
            isLoadingSubscribers = false
            await loadSubscribers()
        } catch {
            isLoadingSubscribers = false
            subscribersError = error.localizedDescription
        }
    }

    public func toggleIssueReaction(emoji: String, currentUserId: String?) async {
        guard let currentUserId, let currentIssue = issue else { return }
        error = nil
        let existing = currentIssue.reactions.first {
            $0.emoji == emoji && $0.actorType == "member" && $0.actorId == currentUserId
        }

        do {
            if existing != nil {
                try await api.removeIssueReaction(issueId: issueId, emoji: emoji, workspaceId: resolvedWorkspaceId)
                issue = currentIssue.replacingReactions(
                    currentIssue.reactions.filter {
                        !($0.emoji == emoji && $0.actorType == "member" && $0.actorId == currentUserId)
                    }
                )
            } else {
                let reaction = try await api.addIssueReaction(issueId: issueId, emoji: emoji, workspaceId: resolvedWorkspaceId)
                issue = currentIssue.replacingReactions(currentIssue.reactions + [reaction])
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func toggleCommentReaction(commentId: String, emoji: String, currentUserId: String?) async {
        guard let currentUserId,
              let index = commentLoader.items.firstIndex(where: { $0.id == commentId })
        else { return }
        error = nil
        let comment = commentLoader.items[index]
        let existing = comment.reactions.first {
            $0.emoji == emoji && $0.actorType == "member" && $0.actorId == currentUserId
        }

        do {
            if existing != nil {
                try await api.removeReaction(commentId: commentId, emoji: emoji, workspaceId: resolvedWorkspaceId)
                commentLoader.items[index] = comment.replacingReactions(
                    comment.reactions.filter {
                        !($0.emoji == emoji && $0.actorType == "member" && $0.actorId == currentUserId)
                    }
                )
            } else {
                let reaction = try await api.addReaction(commentId: commentId, emoji: emoji, workspaceId: resolvedWorkspaceId)
                commentLoader.items[index] = comment.replacingReactions(comment.reactions + [reaction])
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func loadComments() async {
        didLoadComments = false
        commentLoader.reset()
        await loadMoreComments()
    }

    public func loadMoreComments() async {
        isLoadingComments = true
        commentsError = nil
        defer { isLoadingComments = false }
        do {
            let workspaceId = resolvedWorkspaceId
            try await commentLoader.loadNext { [api, issueId, workspaceId] offset in
                try await api.listComments(issueId: issueId, workspaceId: workspaceId, limit: 50, offset: offset)
            }
            didLoadComments = true
        } catch {
            commentsError = error.localizedDescription
        }
    }

    public func loadAgentRuns() async {
        isLoadingAgentRuns = true
        agentRunsError = nil
        defer { isLoadingAgentRuns = false }
        do {
            agentRuns = try await api.listAgentRuns(issueId: issueId, workspaceId: resolvedWorkspaceId)
            didLoadAgentRuns = true
        } catch {
            agentRuns = []
            didLoadAgentRuns = true
            agentRunsError = error.localizedDescription
        }
    }

    public func loadActiveTasks() async {
        isLoadingActiveTasks = true
        activeTasksError = nil
        defer { isLoadingActiveTasks = false }
        do {
            activeTasks = try await api.getActiveTasksForIssue(issueId: issueId, workspaceId: resolvedWorkspaceId)
            didLoadActiveTasks = true
        } catch {
            activeTasks = []
            didLoadActiveTasks = true
            activeTasksError = error.localizedDescription
        }
    }

    public func cancelActiveTask(id taskId: String) async {
        guard !cancellingTaskIds.contains(taskId) else { return }
        cancellingTaskIds.insert(taskId)
        activeTasksError = nil
        defer { cancellingTaskIds.remove(taskId) }

        do {
            let cancelled = try await api.cancelTask(issueId: issueId, taskId: taskId, workspaceId: resolvedWorkspaceId)
            activeTasks.removeAll { $0.id == taskId }
            if let index = agentRuns.firstIndex(where: { $0.id == taskId }) {
                agentRuns[index] = cancelled
            } else {
                agentRuns.insert(cancelled, at: 0)
            }
        } catch {
            activeTasksError = error.localizedDescription
        }
    }

    public func loadTimeline() async {
        isLoadingTimeline = true
        timelineError = nil
        defer { isLoadingTimeline = false }
        do {
            timelineEntries = try await api.listTimeline(issueId: issueId, workspaceId: resolvedWorkspaceId)
            didLoadTimeline = true
        } catch {
            timelineEntries = []
            didLoadTimeline = true
            timelineError = error.localizedDescription
        }
    }

    public func loadUsage() async {
        isLoadingUsage = true
        usageError = nil
        defer { isLoadingUsage = false }
        do {
            usage = try await api.getIssueUsage(issueId: issueId, workspaceId: resolvedWorkspaceId)
            didLoadUsage = true
        } catch {
            usage = nil
            didLoadUsage = true
            usageError = error.localizedDescription
        }
    }

    public func refreshLatestProgress() async {
        async let activeTasks: Void = loadActiveTasks()
        async let agentRuns: Void = loadAgentRuns()
        async let timeline: Void = loadTimeline()
        _ = await (activeTasks, agentRuns, timeline)
    }

    public func deleteIssue() async {
        isDeletingIssue = true
        deleteIssueError = nil
        defer { isDeletingIssue = false }
        do {
            try await api.deleteIssue(id: issueId, workspaceId: resolvedWorkspaceId)
            didDeleteIssue = true
        } catch {
            didDeleteIssue = false
            deleteIssueError = error.localizedDescription
        }
    }

    public func activityText(for entry: TimelineEntry) -> String {
        activityText(for: entry, language: .english)
    }

    public func activityText(for entry: TimelineEntry, language: AppLanguage) -> String {
        if language == .zhHans {
            return zhHansActivityText(for: entry)
        }
        switch entry.action {
        case "created":
            return "created this issue"
        case "status_changed":
            return "changed status from \(statusLabel(entry.detailString("from"))) to \(statusLabel(entry.detailString("to")))"
        case "priority_changed":
            return "changed priority from \(priorityLabel(entry.detailString("from"))) to \(priorityLabel(entry.detailString("to")))"
        case "assignee_changed":
            if entry.detailString("to_id") == nil, entry.detailString("from_id") != nil {
                return "removed assignee"
            }
            if let toType = entry.detailString("to_type"), let toId = entry.detailString("to_id") {
                return "assigned to \(toType.capitalized) \(toId.prefix(8))"
            }
            return "changed assignee"
        case "due_date_changed":
            guard let dueDate = entry.detailString("to"), !dueDate.isEmpty else {
                return "removed due date"
            }
            return "set due date to \(shortDate(dueDate))"
        case "title_changed":
            return "renamed this issue from \"\(entry.detailString("from") ?? "?")\" to \"\(entry.detailString("to") ?? "?")\""
        case "description_updated":
            return "updated the description"
        case "task_completed":
            return "completed the task"
        case "task_failed":
            return "task failed"
        case .some(let action):
            return action.replacingOccurrences(of: "_", with: " ").capitalized
        case .none:
            return "updated this issue"
        }
    }

    private func zhHansActivityText(for entry: TimelineEntry) -> String {
        switch entry.action {
        case "created":
            return "创建了此 Issue"
        case "status_changed":
            return "将状态从 \(statusLabel(entry.detailString("from"), language: .zhHans)) 改为 \(statusLabel(entry.detailString("to"), language: .zhHans))"
        case "priority_changed":
            return "将优先级从 \(priorityLabel(entry.detailString("from"), language: .zhHans)) 改为 \(priorityLabel(entry.detailString("to"), language: .zhHans))"
        case "assignee_changed":
            if entry.detailString("to_id") == nil, entry.detailString("from_id") != nil {
                return "移除了负责人"
            }
            if let toType = entry.detailString("to_type"), let toId = entry.detailString("to_id") {
                let typeName = toType == "member" ? "成员" : AppStrings.localized(toType.capitalized, language: .zhHans)
                return "分配给 \(typeName) \(toId.prefix(8))"
            }
            return "修改了负责人"
        case "due_date_changed":
            guard let dueDate = entry.detailString("to"), !dueDate.isEmpty else {
                return "移除了截止日期"
            }
            return "将截止日期设为 \(shortDate(dueDate))"
        case "title_changed":
            return "将标题从「\(entry.detailString("from") ?? "?")」改为「\(entry.detailString("to") ?? "?")」"
        case "description_updated":
            return "更新了描述"
        case "task_completed":
            return "完成了任务"
        case "task_failed":
            return "任务失败"
        case .some(let action):
            return AppStrings.localized(action.replacingOccurrences(of: "_", with: " ").capitalized, language: .zhHans)
        case .none:
            return "更新了此 Issue"
        }
    }

    public func timelineActorName(for entry: TimelineEntry) -> String {
        switch entry.actorType {
        case "member":
            return subscriberMembers.first { $0.userId == entry.actorId || $0.id == entry.actorId }?.name
                ?? "成员 \(entry.actorId.prefix(8))"
        case "agent":
            return subscriberAgents.first { $0.id == entry.actorId }?.name
                ?? "Agent \(entry.actorId.prefix(8))"
        case "squad":
            return subscriberSquads.first { $0.id == entry.actorId }?.name
                ?? "Squad \(entry.actorId.prefix(8))"
        default:
            return "\(entry.actorType.capitalized) \(entry.actorId.prefix(8))"
        }
    }

    @discardableResult
    public func submitComment() async -> Bool {
        let content = serializedCommentDraft().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || !commentAttachments.isEmpty else { return false }
        guard await submitComment(content: content, parentId: nil) else { return false }
        commentDraft = ""
        commentDraftMentions = []
        commentAttachments = []
        return true
    }

    public func cancelCommentDraft() {
        commentDraft = ""
        commentDraftMentions = []
        commentAttachments = []
    }

    public func uploadCommentAttachment(filename: String, data: Data, contentType: String) async -> Bool {
        guard !data.isEmpty else {
            error = "Attachment is empty."
            return false
        }
        guard !isUploadingCommentAttachment else { return false }

        isUploadingCommentAttachment = true
        error = nil
        defer { isUploadingCommentAttachment = false }

        do {
            let attachment = try await api.uploadFile(
                filename: filename,
                data: data,
                contentType: contentType,
                issueId: issueId,
                workspaceId: resolvedWorkspaceId
            )
            commentAttachments.append(attachment)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public func uploadReplyAttachment(parentId: String, filename: String, data: Data, contentType: String) async -> Bool {
        guard !data.isEmpty else {
            error = "Attachment is empty."
            return false
        }
        guard !uploadingReplyAttachmentIds.contains(parentId) else { return false }

        uploadingReplyAttachmentIds.insert(parentId)
        error = nil
        defer { uploadingReplyAttachmentIds.remove(parentId) }

        do {
            let attachment = try await api.uploadFile(
                filename: filename,
                data: data,
                contentType: contentType,
                issueId: issueId,
                workspaceId: resolvedWorkspaceId
            )
            replyAttachments[parentId, default: []].append(attachment)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public func submitReply(parentId: String, content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = replyAttachments[parentId] ?? []
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        let routed = routedReplyContentAndSuppressions(content: trimmed, parentId: parentId)
        let didSubmit = await submitComment(
            content: routed.content,
            parentId: parentId,
            attachmentParentId: parentId,
            suppressAgentIds: routed.suppressAgentIds
        )
        if didSubmit {
            replyAttachments[parentId] = []
        }
        return didSubmit
    }

    public func updateComment(commentId: String, content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        error = nil
        do {
            let updated = try await api.updateComment(commentId: commentId, content: trimmed, workspaceId: resolvedWorkspaceId)
            if let index = commentLoader.items.firstIndex(where: { $0.id == commentId }) {
                commentLoader.items[index] = updated
            }
            await DataStore.shared.invalidateIssue(issueId)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public func deleteComment(commentId: String) async -> Bool {
        error = nil
        do {
            try await api.deleteComment(commentId: commentId, workspaceId: resolvedWorkspaceId)
            let removedIds = descendantCommentIds(of: commentId).union([commentId])
            commentLoader.items.removeAll { removedIds.contains($0.id) }
            await DataStore.shared.invalidateIssue(issueId)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func submitComment(
        content: String,
        parentId: String?,
        attachmentParentId: String? = nil,
        suppressAgentIds: [String]? = nil
    ) async -> Bool {
        isSubmittingComment = true; defer { isSubmittingComment = false }
        do {
            let comment = try await api.addComment(
                issueId: issueId,
                content: content,
                parentId: parentId,
                attachmentIds: attachmentIds(forParentId: attachmentParentId ?? parentId),
                suppressAgentIds: suppressAgentIds,
                workspaceId: resolvedWorkspaceId
            )
            commentLoader.items.append(comment)
            async let issueRefresh: Void = loadIssue()
            async let progressRefresh: Void = refreshLatestProgress()
            _ = await (issueRefresh, progressRefresh)
            await DataStore.shared.invalidateIssue(issueId)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func sortRootComments(_ comments: [Comment]) -> [Comment] {
        comments.sorted {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return commentSortOrder == .ascending ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt
        }
    }

    private func sortCommentsAscending(_ lhs: Comment, _ rhs: Comment) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
    }

    private func rootCommentId(for comment: Comment, commentsById: [String: Comment]) -> String {
        var current = comment
        var visited = Set<String>()
        while let parentId = current.parentId, let parent = commentsById[parentId], !visited.contains(parent.id) {
            visited.insert(current.id)
            current = parent
        }
        return current.id
    }

    private func threadRootCommentId(for commentId: String) -> String {
        let commentsById = Dictionary(uniqueKeysWithValues: commentLoader.items.map { ($0.id, $0) })
        guard let comment = commentsById[commentId] else { return commentId }
        return rootCommentId(for: comment, commentsById: commentsById)
    }

    private func routedReplyContentAndSuppressions(content: String, parentId: String) -> (content: String, suppressAgentIds: [String]?) {
        guard let parent = commentLoader.items.first(where: { $0.id == parentId }),
              parent.authorType == "agent",
              !content.contains("mention://")
        else {
            return (content, nil)
        }
        let targetAgentId = parent.authorId
        let targetAgentName = subscriberAgents.first { $0.id == targetAgentId }?.name ?? "Agent \(targetAgentId.prefix(8))"
        let routedContent = "\(content) \(Self.agentMentionMarkdown(agentId: targetAgentId, label: targetAgentName))"
        let suppressions = defaultReplySuppressions(except: targetAgentId)
        return (routedContent, suppressions.isEmpty ? nil : suppressions)
    }

    private func defaultReplySuppressions(except targetAgentId: String) -> [String] {
        guard let issue else { return [] }
        var ids = Set<String>()
        if issue.assigneeType == "agent", let assigneeId = issue.assigneeId {
            ids.insert(assigneeId)
        }
        if issue.assigneeType == "squad",
           let squadId = issue.assigneeId,
           let leaderId = subscriberSquads.first(where: { $0.id == squadId })?.leaderId {
            ids.insert(leaderId)
        }
        ids.remove(targetAgentId)
        return Array(ids)
    }

    private func descendantCommentIds(of commentId: String) -> Set<String> {
        var ids = Set<String>()
        var changed = true
        while changed {
            changed = false
            for comment in commentLoader.items {
                guard let parentId = comment.parentId,
                      (parentId == commentId || ids.contains(parentId)),
                      !ids.contains(comment.id)
                else { continue }
                ids.insert(comment.id)
                changed = true
            }
        }
        return ids
    }

    private func attachmentIds(forParentId parentId: String?) -> [String]? {
        let attachments = parentId.flatMap { replyAttachments[$0] } ?? commentAttachments
        return attachments.isEmpty ? nil : attachments.map(\.id)
    }

    public func updateStatus(_ status: IssueStatus) async {
        await updateIssue(status: status, priority: nil)
    }

    public func updatePriority(_ priority: IssuePriority) async {
        await updateIssue(status: nil, priority: priority)
    }

    public func applyUpdatedIssue(_ updated: Issue) async {
        issue = updated
        await DataStore.shared.invalidateIssue(updated.id)
        await loadMetadata()
        await loadIssueRelations()
    }

    private func updateIssue(status: IssueStatus?, priority: IssuePriority?) async {
        guard !isUpdatingIssue else { return }
        isUpdatingIssue = true
        error = nil
        defer { isUpdatingIssue = false }

        do {
            issue = try await api.updateIssue(
                id: issueId,
                workspaceId: resolvedWorkspaceId,
                status: status,
                priority: priority
            )
            await DataStore.shared.invalidateIssue(issueId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func doneCount(in issues: [Issue]) -> Int {
        issues.filter { $0.status == .done }.count
    }

    private func statusLabel(_ raw: String?) -> String {
        statusLabel(raw, language: .english)
    }

    private func statusLabel(_ raw: String?, language: AppLanguage) -> String {
        guard let raw else { return "?" }
        let label = IssueStatus(rawValue: raw)?.displayName ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
        return AppStrings.localized(label, language: language)
    }

    private func priorityLabel(_ raw: String?) -> String {
        priorityLabel(raw, language: .english)
    }

    private func priorityLabel(_ raw: String?, language: AppLanguage) -> String {
        guard let raw else { return "?" }
        let label = IssuePriority(rawValue: raw)?.displayName ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
        return AppStrings.localized(label, language: language)
    }

    private func shortDate(_ raw: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: raw) else { return raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func formatTokenCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
