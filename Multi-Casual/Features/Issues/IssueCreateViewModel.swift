import Foundation
import Observation

public struct IssueAssigneeOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let type: String
    public let assigneeId: String
    public let displayName: String
    public let subtitle: String

    public init(id: String, type: String, assigneeId: String, displayName: String, subtitle: String) {
        self.id = id
        self.type = type
        self.assigneeId = assigneeId
        self.displayName = displayName
        self.subtitle = subtitle
    }
}

@Observable
@MainActor
public final class IssueCreateViewModel {
    public static let noAssigneeId = "none"
    public static let noProjectId = "none"

    public var title = ""
    public var description = ""
    public var descriptionMentions: [IssueDetailViewModel.MentionDraftToken] = []
    public var status: IssueStatus = .todo
    public var priority: IssuePriority = .noPriority
    public var selectedAssigneeOptionId = IssueCreateViewModel.noAssigneeId
    public var selectedProjectId = IssueCreateViewModel.noProjectId
    public var includesDueDate = false
    public var dueDate: Date
    public var assigneeOptions: [IssueAssigneeOption] = []
    public var projects: [Project] = []
    public var attachments: [Attachment] = []
    public var isLoadingOptions = false
    public var isSubmitting = false
    public var isQuickCreating = false
    public var isUploadingAttachment = false
    public var quickCreatePrompt = ""
    public var selectedQuickCreateAgentId: String?
    public var quickCreateTaskId: String?
    public var quickCreateSuccessMessage: String?
    public var errorMessage: String?

    private let api: APIClient
    private let authSession: AuthSession
    private let dateFormatter: ISO8601DateFormatter
    public let parentIssueId: String?
    public let parentIssueIdentifier: String?

    public init(
        api: APIClient,
        authSession: AuthSession,
        now: Date = Date(),
        parentIssueId: String? = nil,
        parentIssueIdentifier: String? = nil
    ) {
        self.api = api
        self.authSession = authSession
        self.dueDate = now
        self.parentIssueId = parentIssueId
        self.parentIssueIdentifier = parentIssueIdentifier
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.dateFormatter = formatter
    }

    public var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSubmitting &&
        !isUploadingAttachment
    }

    public var canQuickCreate: Bool {
        !quickCreatePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        selectedQuickCreateAgentId != nil &&
        !isQuickCreating &&
        !isUploadingAttachment
    }

    public var statusOptions: [IssueStatus] {
        IssueStatus.allCases.filter { $0 != .unknown }
    }

    public var priorityOptions: [IssuePriority] {
        IssuePriority.allCases.filter { $0 != .unknown }
    }

    public var selectedAssignee: IssueAssigneeOption? {
        assigneeOptions.first { $0.id == selectedAssigneeOptionId }
    }

    /// Live presence per agent id, used to render status dots in the mention picker.
    public var presenceByAgentId: [String: AgentPresenceSummary] = [:]

    public var mentionCandidates: [MentionCandidate] {
        assigneeOptions.map {
            MentionCandidate(
                type: $0.type == "agent" ? .agent : ($0.type == "squad" ? .squad : .person),
                entityId: $0.assigneeId,
                displayName: $0.displayName,
                subtitle: $0.subtitle
            )
        }
    }

    public var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId }
    }

    public var quickCreateAgentOptions: [IssueAssigneeOption] {
        assigneeOptions.filter { $0.type == "agent" }
    }

    public func loadOptions() async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before creating an issue."
            return
        }

        isLoadingOptions = true
        errorMessage = nil
        defer { isLoadingOptions = false }

        do {
            async let members = WorkspaceMetadataCache.shared.members(workspaceId: workspaceId, api: api)
            async let agents = WorkspaceMetadataCache.shared.agents(workspaceId: workspaceId, api: api)
            async let squads = WorkspaceMetadataCache.shared.squads(workspaceId: workspaceId, api: api)
            async let projectOptions = WorkspaceMetadataCache.shared.projects(workspaceId: workspaceId, api: api)

            let loadedMembers = try await members
            let loadedAgents = try await agents
            let loadedSquads = try await squads
            let loadedProjects = try await projectOptions

            assigneeOptions = loadedMembers.map {
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
            self.projects = loadedProjects

            if selectedAssigneeOptionId != Self.noAssigneeId && selectedAssignee == nil {
                selectedAssigneeOptionId = Self.noAssigneeId
            }
            if selectedProjectId != Self.noProjectId && selectedProject == nil {
                selectedProjectId = Self.noProjectId
            }
            if selectedQuickCreateAgentId == nil ||
                !quickCreateAgentOptions.contains(where: { $0.assigneeId == selectedQuickCreateAgentId }) {
                selectedQuickCreateAgentId = quickCreateAgentOptions.first?.assigneeId
            }
            applyDebugCreateDefaults()
        } catch {
            errorMessage = error.localizedDescription
        }
        presenceByAgentId = await WorkspaceMetadataCache.shared.agentPresence(workspaceId: workspaceId, api: api)
    }

    public func submit() async -> Bool {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before creating an issue."
            return false
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let trimmedDescription = IssueDetailViewModel.serializeMentionDraft(
            description,
            mentions: descriptionMentions
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let assignee = selectedAssignee
        let projectId = selectedProject?.id

        do {
            _ = try await api.createIssue(
                title: trimmedTitle,
                description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                workspaceId: workspaceId,
                status: status,
                priority: priority,
                assigneeType: assignee?.type,
                assigneeId: assignee?.assigneeId,
                projectId: projectId,
                parentIssueId: parentIssueId,
                dueDate: includesDueDate ? dateFormatter.string(from: dueDate) : nil,
                attachmentIds: attachments.map(\.id)
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func submitQuickCreate() async -> Bool {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before creating with an agent."
            quickCreateSuccessMessage = nil
            return false
        }

        let trimmedPrompt = quickCreatePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            errorMessage = "Describe what the agent should create."
            quickCreateSuccessMessage = nil
            return false
        }

        guard let agentId = selectedQuickCreateAgentId, !agentId.isEmpty else {
            errorMessage = "Pick an agent before creating with agent."
            quickCreateSuccessMessage = nil
            return false
        }
        guard !isQuickCreating else { return false }

        isQuickCreating = true
        errorMessage = nil
        quickCreateSuccessMessage = nil
        defer { isQuickCreating = false }

        do {
            let response = try await api.quickCreateIssue(
                agentId: agentId,
                prompt: trimmedPrompt,
                workspaceId: workspaceId
            )
            quickCreateTaskId = response.taskId
            quickCreateSuccessMessage = "Sent to agent. You'll get an inbox notification when it's done."
            quickCreatePrompt = ""
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func uploadAttachment(filename: String, data: Data, contentType: String) async -> Bool {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before uploading an attachment."
            return false
        }
        guard !data.isEmpty else {
            errorMessage = "Attachment is empty."
            return false
        }
        guard !isUploadingAttachment else { return false }

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
            attachments.append(attachment)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func applyDebugCreateDefaults() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment

        if title.isEmpty, let debugTitle = env["MULTI_CASUAL_DEBUG_CREATE_TITLE"], !debugTitle.isEmpty {
            title = debugTitle
        }
        if let rawStatus = env["MULTI_CASUAL_DEBUG_CREATE_STATUS"],
           let debugStatus = IssueStatus(rawValue: rawStatus),
           debugStatus != .unknown {
            status = debugStatus
        }
        if let rawPriority = env["MULTI_CASUAL_DEBUG_CREATE_PRIORITY"],
           let debugPriority = IssuePriority(rawValue: rawPriority),
           debugPriority != .unknown {
            priority = debugPriority
        }
        if let assigneeOptionId = env["MULTI_CASUAL_DEBUG_CREATE_ASSIGNEE_OPTION_ID"],
           assigneeOptions.contains(where: { $0.id == assigneeOptionId }) {
            selectedAssigneeOptionId = assigneeOptionId
        }
        if let projectId = env["MULTI_CASUAL_DEBUG_CREATE_PROJECT_ID"],
           projects.contains(where: { $0.id == projectId }) {
            selectedProjectId = projectId
        }
        if let dueDateRaw = env["MULTI_CASUAL_DEBUG_CREATE_DUE_DATE"],
           let debugDueDate = dateFormatter.date(from: dueDateRaw) {
            includesDueDate = true
            dueDate = debugDueDate
        }
        #endif
    }
}
