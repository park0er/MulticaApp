import Foundation
import Observation

@Observable
@MainActor
public final class ChatViewModel {
    public static let draftSessionId = "__draft_chat_session__"

    public var sessions: [ChatSession] = []
    public var members: [WorkspaceMember] = []
    public var agents: [Agent] = []
    public var squads: [Squad] = []
    /// Live presence per agent id, used to render status dots on chat rows.
    public var presenceByAgentId: [String: AgentPresenceSummary] = [:]
    public var messages: [ChatMessage] = []
    public var draftAttachments: [Attachment] = []
    public var selectedSession: ChatSession?
    public var pendingTasks = PendingChatTasksResponse(tasks: [])
    public var pendingTask: ChatPendingTask?
    public var taskTimelines: [String: [TimelineItem]] = [:]
    public var errorMessage: String?
    public var timelineError: String?
    public var isLoading = false
    public var isSending = false
    public var isCreating = false
    public var isCancellingTask = false
    public var isLoadingTimeline = false
    public var isUploadingAttachment = false

    public var isDraftSession: Bool {
        selectedSession?.id == Self.draftSessionId
    }

    public static func titleFromFirstMessage(_ content: String) -> String {
        let firstLine = content
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? content
        let collapsed = firstLine
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "Attachment" }
        let maxLength = 80
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private let api: APIClient
    private let authSession: AuthSession

    public init(api: APIClient, authSession: AuthSession) {
        self.api = api
        self.authSession = authSession
    }

    public func load() async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before opening Chat."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let loadedSessions = api.listChatSessions(workspaceId: workspaceId)
            async let loadedMembers = WorkspaceMetadataCache.shared.members(workspaceId: workspaceId, api: api)
            async let loadedAgents = api.listAgents(workspaceId: workspaceId)
            async let loadedSquads = WorkspaceMetadataCache.shared.squads(workspaceId: workspaceId, api: api)
            async let loadedPending = api.listPendingChatTasks(workspaceId: workspaceId)
            sessions = try await loadedSessions.sorted { $0.updatedAt > $1.updatedAt }
            members = try await loadedMembers
            agents = try await loadedAgents.filter { $0.archivedAt == nil }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            squads = try await loadedSquads.filter { $0.archivedAt == nil }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            pendingTasks = try await loadedPending
        } catch {
            errorMessage = error.localizedDescription
        }
        presenceByAgentId = await WorkspaceMetadataCache.shared.agentPresence(workspaceId: workspaceId, api: api)
    }

    public var messageMarkdownContext: MarkdownRenderContext {
        var displayNames: [String: String] = [:]
        for member in members {
            displayNames["mention://member/\(member.userId)"] = member.name
            displayNames["mention://member/\(member.id)"] = member.name
            displayNames["mention://user/\(member.userId)"] = member.name
            displayNames["mention://user/\(member.id)"] = member.name
        }
        for agent in agents {
            displayNames["mention://agent/\(agent.id)"] = agent.name
        }
        for squad in squads {
            displayNames["mention://squad/\(squad.id)"] = squad.name
        }
        return MarkdownRenderContext(mentionDisplayNamesByURL: displayNames)
    }

    public func selectSession(_ session: ChatSession) async {
        selectedSession = session
        if session.id == Self.draftSessionId {
            messages = []
            draftAttachments = []
            pendingTask = nil
            taskTimelines = [:]
            errorMessage = nil
            return
        }
        await loadMessages()
    }

    public func startDraftSession(agentId: String? = nil) {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before opening Chat."
            return
        }
        let resolvedAgentId = agentId ?? selectedSession?.agentId ?? agents.first?.id
        guard let resolvedAgentId, !resolvedAgentId.isEmpty else {
            errorMessage = "Add an agent before starting a chat."
            return
        }
        selectedSession = ChatSession(
            id: Self.draftSessionId,
            workspaceId: workspaceId,
            agentId: resolvedAgentId,
            creatorId: authSession.currentUser?.id ?? "",
            title: "New Chat",
            status: .active,
            hasUnread: false,
            createdAt: Date(),
            updatedAt: Date()
        )
        messages = []
        pendingTask = nil
        timelineError = nil
        errorMessage = nil
    }

    public func loadMessages() async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before opening Chat."
            return
        }
        guard let session = selectedSession else { return }
        guard session.id != Self.draftSessionId else { return }
        errorMessage = nil

        do {
            async let loadedMessages = api.listChatMessages(sessionId: session.id, workspaceId: workspaceId)
            async let loadedPending = api.getPendingChatTask(sessionId: session.id, workspaceId: workspaceId)
            let sortedMessages = try await loadedMessages.sorted { $0.createdAt < $1.createdAt }
            let loadedPendingTask = try await loadedPending
            guard selectedSession?.id == session.id else { return }
            messages = sortedMessages
            pendingTask = loadedPendingTask
            try await api.markChatSessionRead(sessionId: session.id, workspaceId: workspaceId)
            markSessionRead(session.id)
            await loadVisibleTaskTimelines(workspaceId: workspaceId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func createSession(agentId: String, title: String?) async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before opening Chat."
            return
        }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        do {
            let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let session = try await api.createChatSession(
                agentId: agentId,
                title: trimmedTitle?.isEmpty == true ? nil : trimmedTitle,
                workspaceId: workspaceId
            )
            upsert(session)
            selectedSession = session
            await loadMessages()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func archiveSelectedSession() async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before opening Chat."
            return
        }
        guard let session = selectedSession else { return }
        errorMessage = nil

        do {
            try await api.archiveChatSession(id: session.id, workspaceId: workspaceId)
            sessions.removeAll { $0.id == session.id }
            selectedSession = nil
            messages = []
            draftAttachments = []
            pendingTask = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func sendMessage(_ content: String, attachments: [Attachment]? = nil) async -> Bool {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before opening Chat."
            return false
        }
        guard let initialSession = selectedSession else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingAttachments = attachments ?? draftAttachments
        guard !trimmed.isEmpty || !outgoingAttachments.isEmpty else { return false }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        do {
            let session: ChatSession
            if initialSession.id == Self.draftSessionId {
                isCreating = true
                defer { isCreating = false }
                session = try await api.createChatSession(agentId: initialSession.agentId, title: Self.titleFromFirstMessage(trimmed), workspaceId: workspaceId)
                upsert(session)
                selectedSession = session
            } else {
                session = initialSession
            }
            let response = try await api.sendChatMessage(
                sessionId: session.id,
                content: trimmed,
                attachmentIds: outgoingAttachments.map(\.id),
                workspaceId: workspaceId
            )
            let optimistic = ChatMessage(
                id: response.messageId,
                chatSessionId: session.id,
                role: .user,
                content: trimmed,
                taskId: response.taskId,
                createdAt: response.createdAt,
                attachments: outgoingAttachments
            )
            if !messages.contains(where: { $0.id == optimistic.id }) {
                messages.append(optimistic)
            }
            draftAttachments = []
            pendingTask = try await api.getPendingChatTask(sessionId: session.id, workspaceId: workspaceId)
            await loadVisibleTaskTimelines(workspaceId: workspaceId)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func uploadDraftAttachment(filename: String, data: Data, contentType: String) async -> Bool {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before uploading an attachment."
            return false
        }
        guard !data.isEmpty else {
            errorMessage = "Attachment is empty."
            return false
        }

        isUploadingAttachment = true
        errorMessage = nil
        defer { isUploadingAttachment = false }

        do {
            let attachment = try await api.uploadFile(
                filename: filename,
                data: data,
                contentType: contentType,
                workspaceId: workspaceId
            )
            draftAttachments.append(attachment)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func removeDraftAttachment(id: String) {
        draftAttachments.removeAll { $0.id == id }
    }

    public func cancelPendingTask() async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before opening Chat."
            return
        }
        guard let taskId = pendingTask?.taskId, !taskId.isEmpty else { return }
        guard !isCancellingTask else { return }

        isCancellingTask = true
        errorMessage = nil
        defer { isCancellingTask = false }

        do {
            try await api.cancelTaskById(taskId: taskId, workspaceId: workspaceId)
            pendingTask = nil
            pendingTasks = try await api.listPendingChatTasks(workspaceId: workspaceId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func agentName(for agentId: String) -> String {
        agents.first { $0.id == agentId }?.name ?? String(agentId.prefix(8))
    }

    public func agentAvatarUrl(for agentId: String) -> String? {
        agents.first { $0.id == agentId }?.avatarUrl
    }

    public func agentStatusDot(for agentId: String) -> AvatarView.StatusDot? {
        presenceByAgentId[agentId]?.avatarStatusDot
    }

    public func pendingTaskCount(for session: ChatSession) -> Int {
        pendingTasks.tasks.filter { $0.chatSessionId == session.id }.count
    }

    public var visiblePendingTaskId: String? {
        guard let taskId = pendingTask?.taskId, !taskId.isEmpty else { return nil }
        let assistantMessageAlreadyPersisted = messages.contains {
            $0.role == .assistant && $0.taskId == taskId
        }
        return assistantMessageAlreadyPersisted ? nil : taskId
    }

    public var visibleTimelineItems: [TimelineItem] {
        guard let taskId = visiblePendingTaskId else { return [] }
        return taskTimelines[taskId] ?? []
    }

    public var shouldShowLiveTimeline: Bool {
        isSending || visiblePendingTaskId != nil
    }

    public func timelineItems(for message: ChatMessage) -> [TimelineItem] {
        guard let taskId = message.taskId, !taskId.isEmpty else { return [] }
        return taskTimelines[taskId] ?? []
    }

    public func loadTimeline(taskId: String, workspaceId: String? = nil) async {
        guard !taskId.isEmpty else { return }
        let resolvedWorkspaceId = workspaceId ?? authSession.currentWorkspace?.id
        guard let resolvedWorkspaceId, !resolvedWorkspaceId.isEmpty else {
            timelineError = "Pick a workspace before viewing agent progress."
            return
        }

        isLoadingTimeline = true
        timelineError = nil
        defer { isLoadingTimeline = false }

        do {
            taskTimelines[taskId] = try await api.listRunMessages(taskId: taskId, workspaceId: resolvedWorkspaceId)
                .map(TimelineItem.init(from:))
                .sorted { $0.id < $1.id }
        } catch {
            timelineError = error.localizedDescription
        }
    }

    public func applyRealtimeTaskMessage(taskId: String?, payload: Data) {
        guard let taskId, !taskId.isEmpty else { return }
        do {
            let message = try JSONDecoder().decode(TaskMessage.self, from: payload)
            timelineError = nil
            upsertTimelineItem(TimelineItem(from: message), taskId: taskId)
        } catch {
            timelineError = "Could not decode live chat update: \(error.localizedDescription)"
        }
    }

    private func upsert(_ session: ChatSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    private func markSessionRead(_ sessionId: String) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        let read = ChatSession(
            id: session.id,
            workspaceId: session.workspaceId,
            agentId: session.agentId,
            creatorId: session.creatorId,
            title: session.title,
            status: session.status,
            hasUnread: false,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt
        )
        upsert(read)
    }

    private func loadVisibleTaskTimelines(workspaceId: String) async {
        let taskIds = Set(
            messages.compactMap(\.taskId) +
            [pendingTask?.taskId].compactMap { $0 }
        ).filter { !$0.isEmpty }

        for taskId in taskIds {
            await loadTimeline(taskId: taskId, workspaceId: workspaceId)
        }
    }

    private func upsertTimelineItem(_ item: TimelineItem, taskId: String) {
        var timeline = taskTimelines[taskId] ?? []
        if let index = timeline.firstIndex(where: { $0.id == item.id }) {
            timeline[index] = item
        } else {
            timeline.append(item)
        }
        timeline.sort { $0.id < $1.id }
        taskTimelines[taskId] = timeline
    }
}
