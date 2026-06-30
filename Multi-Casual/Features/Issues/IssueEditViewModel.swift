import Foundation
import Observation

@Observable
@MainActor
public final class IssueEditViewModel {
    public static let noAssigneeId = "none"
    public static let noProjectId = "none"

    public let issueId: String
    public var title: String
    public var description: String
    public var descriptionMentions: [IssueDetailViewModel.MentionDraftToken] = []
    public var status: IssueStatus
    public var priority: IssuePriority
    public var selectedAssigneeOptionId: String
    public var selectedProjectId: String
    public var selectedLabelIds: Set<String>
    public var includesDueDate: Bool
    public var dueDate: Date
    public var assigneeOptions: [IssueAssigneeOption] = []
    public var projects: [Project] = []
    public var labels: [IssueLabel] = []
    public var isLoadingOptions = false
    public var isSubmitting = false
    public var errorMessage: String?

    private let workspaceId: String?
    private let api: APIClient
    private let dateFormatter: ISO8601DateFormatter
    private let originalLabelIds: Set<String>
    private let originalAssigneeType: String?
    private let originalAssigneeId: String?
    private let originalProjectId: String?

    public init(issue: Issue, api: APIClient, authSession: AuthSession) {
        issueId = issue.id
        workspaceId = authSession.currentWorkspace?.id ?? issue.workspaceId
        title = issue.title
        description = issue.description ?? ""
        status = issue.status
        priority = issue.priority
        originalAssigneeType = issue.assigneeType
        originalAssigneeId = issue.assigneeId
        originalProjectId = issue.projectId
        selectedAssigneeOptionId = issue.assigneeType.flatMap { type in
            issue.assigneeId.map { "\(type):\($0)" }
        } ?? Self.noAssigneeId
        selectedProjectId = issue.projectId ?? Self.noProjectId
        selectedLabelIds = Set(issue.labels.map(\.id))
        labels = issue.labels
        originalLabelIds = Set(issue.labels.map(\.id))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        dateFormatter = formatter
        if let dueDateRaw = issue.dueDate, let parsedDueDate = formatter.date(from: dueDateRaw) {
            includesDueDate = true
            dueDate = parsedDueDate
        } else {
            includesDueDate = false
            dueDate = Date()
        }
        self.api = api
    }

    public var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
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

    public func loadOptions() async {
        guard let workspaceId else {
            errorMessage = "Pick a workspace before editing an issue."
            return
        }

        isLoadingOptions = true
        errorMessage = nil
        defer { isLoadingOptions = false }

        async let membersResult = optionResult {
            try await WorkspaceMetadataCache.shared.members(workspaceId: workspaceId, api: api)
        }
        async let agentsResult = optionResult {
            try await WorkspaceMetadataCache.shared.agents(workspaceId: workspaceId, api: api)
        }
        async let squadsResult = optionResult {
            try await WorkspaceMetadataCache.shared.squads(workspaceId: workspaceId, api: api)
        }
        async let projectsResult = optionResult {
            try await WorkspaceMetadataCache.shared.projects(workspaceId: workspaceId, api: api)
        }
        async let labelsResult = optionResult {
            let response = try await api.listLabels(workspaceId: workspaceId)
            return response.labels
        }

        let members = await membersResult
        let agents = await agentsResult
        let squads = await squadsResult
        let loadedProjects = await projectsResult
        let loadedLabels = await labelsResult

        var didFail = false
        switch members {
        case .success(let loadedMembers):
            assigneeOptions = loadedMembers.map {
                IssueAssigneeOption(
                    id: "member:\($0.userId)",
                    type: "member",
                    assigneeId: $0.userId,
                    displayName: $0.name,
                    subtitle: $0.email
                )
            }
        case .failure:
            didFail = true
            assigneeOptions = []
        }

        switch agents {
        case .success(let loadedAgents):
            assigneeOptions += loadedAgents.map {
                IssueAssigneeOption(
                    id: "agent:\($0.id)",
                    type: "agent",
                    assigneeId: $0.id,
                    displayName: $0.name,
                    subtitle: "Agent"
                )
            }
        case .failure:
            didFail = true
        }

        switch squads {
        case .success(let loadedSquads):
            assigneeOptions += loadedSquads.map {
                IssueAssigneeOption(
                    id: "squad:\($0.id)",
                    type: "squad",
                    assigneeId: $0.id,
                    displayName: $0.name,
                    subtitle: $0.description.isEmpty ? "Squad" : "Squad · \($0.description)"
                )
            }
        case .failure:
            didFail = true
        }

        switch loadedProjects {
        case .success(let loadedProjects):
            projects = loadedProjects
        case .failure:
            didFail = true
            projects = []
        }

        switch loadedLabels {
        case .success(let loadedLabels):
            labels = mergeLabels(issueLabels: labels, workspaceLabels: loadedLabels)
        case .failure:
            didFail = true
        }

        if case .success = members, case .success = agents, case .success = squads,
           selectedAssigneeOptionId != Self.noAssigneeId && selectedAssignee == nil {
            selectedAssigneeOptionId = Self.noAssigneeId
        }
        if case .success = loadedProjects,
           selectedProjectId != Self.noProjectId && selectedProject == nil {
            selectedProjectId = Self.noProjectId
        }

        if didFail {
            errorMessage = "Some workspace options could not be loaded."
        }
        presenceByAgentId = await WorkspaceMetadataCache.shared.agentPresence(workspaceId: workspaceId, api: api)
    }

    public func submit() async -> Issue? {
        guard let workspaceId else {
            errorMessage = "Pick a workspace before editing an issue."
            return nil
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let trimmedDescription = IssueDetailViewModel.serializeMentionDraft(
            description,
            mentions: descriptionMentions
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let assignee = resolvedAssignee()

        do {
            let updated = try await api.updateIssueDetails(
                id: issueId,
                workspaceId: workspaceId,
                title: trimmedTitle,
                description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                status: status,
                priority: priority,
                assigneeType: assignee?.type,
                assigneeId: assignee?.assigneeId,
                projectId: resolvedProjectId(),
                dueDate: includesDueDate ? dateFormatter.string(from: dueDate) : nil
            )
            let syncedLabels = try await syncLabels()
            return updated.replacingLabels(syncedLabels ?? updated.labels)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func toggleLabel(_ label: IssueLabel, isSelected: Bool) {
        if isSelected {
            selectedLabelIds.insert(label.id)
        } else {
            selectedLabelIds.remove(label.id)
        }
    }

    private func resolvedAssignee() -> (type: String, assigneeId: String)? {
        guard selectedAssigneeOptionId != Self.noAssigneeId else { return nil }
        if let selectedAssignee {
            return (selectedAssignee.type, selectedAssignee.assigneeId)
        }
        if let originalAssigneeType,
           let originalAssigneeId,
           selectedAssigneeOptionId == "\(originalAssigneeType):\(originalAssigneeId)" {
            return (originalAssigneeType, originalAssigneeId)
        }
        return nil
    }

    private func resolvedProjectId() -> String? {
        guard selectedProjectId != Self.noProjectId else { return nil }
        if selectedProject != nil {
            return selectedProjectId
        }
        if selectedProjectId == originalProjectId {
            return originalProjectId
        }
        return nil
    }

    private func optionResult<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    private func syncLabels() async throws -> [IssueLabel]? {
        let toAttach = selectedLabelIds.subtracting(originalLabelIds).sorted()
        let toDetach = originalLabelIds.subtracting(selectedLabelIds).sorted()
        guard !toAttach.isEmpty || !toDetach.isEmpty else {
            return nil
        }

        var latestLabels: [IssueLabel]?
        for labelId in toAttach {
            latestLabels = try await api.attachLabel(issueId: issueId, labelId: labelId, workspaceId: workspaceId).labels
        }
        for labelId in toDetach {
            latestLabels = try await api.detachLabel(issueId: issueId, labelId: labelId, workspaceId: workspaceId).labels
        }
        return latestLabels
    }

    private func mergeLabels(issueLabels: [IssueLabel], workspaceLabels: [IssueLabel]) -> [IssueLabel] {
        var seen = Set<String>()
        return (issueLabels + workspaceLabels)
            .filter { label in
                if seen.contains(label.id) { return false }
                seen.insert(label.id)
                return true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
