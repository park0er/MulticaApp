import Foundation
import Observation

@Observable
@MainActor
public final class SquadsViewModel {
    /// A member (agent or workspace member) chosen to be added to a squad on
    /// creation, mirroring the web CreateSquadModal's AdditionalMembersPicker.
    public struct MemberSelection: Hashable, Sendable {
        public let type: String   // "agent" or "member"
        public let id: String     // agent id, or user id for a workspace member

        public init(type: String, id: String) {
            self.type = type
            self.id = id
        }
    }

    public var squads: [Squad] = []
    /// Active agents in the workspace, used to pick a squad leader / members.
    public var agents: [Agent] = []
    /// Workspace members, selectable as additional squad members.
    public var members: [WorkspaceMember] = []
    public var isLoading = false
    public var isMutating = false
    public var errorMessage: String?

    private let api: APIClient
    private let authSession: AuthSession

    public init(api: APIClient, authSession: AuthSession) {
        self.api = api
        self.authSession = authSession
    }

    public func load() async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before managing squads."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let squadsResult = api.listSquads(workspaceId: workspaceId)
            async let agentsResult = api.listAgents(workspaceId: workspaceId)
            async let membersResult = api.listMembers(workspaceId: workspaceId)
            let loadedSquads = try await squadsResult
            let loadedAgents = try await agentsResult
            let loadedMembers = try await membersResult
            squads = loadedSquads
                .filter { $0.archivedAt == nil }
                .sorted(by: squadSort)
            agents = loadedAgents.filter { $0.archivedAt == nil }
            members = loadedMembers
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Agents eligible to lead a squad: active and attached to a runtime, matching
    /// the web LeaderPicker filter (`!a.archived_at && a.runtime_id`).
    public var leaderCandidates: [Agent] {
        agents.filter { $0.archivedAt == nil && !($0.runtimeId ?? "").isEmpty }
    }

    /// The display name for a squad's leader agent, if resolvable.
    public func leaderName(for squad: Squad) -> String? {
        guard let leaderId = squad.leaderId else { return nil }
        return agents.first(where: { $0.id == leaderId })?.name
    }

    public func createSquad(
        name: String,
        description: String,
        leaderId: String,
        avatarUrl: String?,
        memberSelections: [MemberSelection] = []
    ) async -> Squad? {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before managing squads."
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a squad name."
            return nil
        }
        guard !leaderId.isEmpty else {
            errorMessage = "Pick a leader agent for the squad."
            return nil
        }
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAvatar = avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        return await mutate(workspaceId: workspaceId) {
            let squad = try await api.createSquad(
                name: trimmedName,
                description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                leaderId: leaderId,
                avatarUrl: (normalizedAvatar?.isEmpty == false) ? normalizedAvatar : nil,
                workspaceId: workspaceId
            )
            // Add any extra members after creation, best-effort (web does the
            // same with Promise.allSettled). The leader is excluded by the UI.
            for selection in memberSelections where selection.id != leaderId {
                _ = try? await api.addSquadMember(
                    squadId: squad.id,
                    memberType: selection.type,
                    memberId: selection.id,
                    role: "member",
                    workspaceId: workspaceId
                )
            }
            return squad
        }
    }

    public func updateSquad(
        id: String,
        name: String,
        description: String,
        instructions: String,
        leaderId: String?,
        avatarUrl: String?
    ) async -> Squad? {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before managing squads."
            return nil
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Enter a squad name."
            return nil
        }
        let normalizedAvatar = avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
        return await mutate(workspaceId: workspaceId) {
            try await api.updateSquad(
                id: id,
                name: trimmedName,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                instructions: instructions,
                leaderId: leaderId,
                avatarUrl: normalizedAvatar,
                workspaceId: workspaceId
            )
        }
    }

    public func deleteSquad(id: String) async {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before managing squads."
            return
        }
        guard !isMutating else { return }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }

        do {
            try await api.deleteSquad(id: id, workspaceId: workspaceId)
            squads.removeAll { $0.id == id }
            await WorkspaceMetadataCache.shared.invalidate(workspaceId: workspaceId, api: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Uploads an image and returns its hosted URL, for use as a squad avatar.
    public func uploadAvatarFile(filename: String, data: Data, contentType: String) async -> String? {
        guard let workspaceId = authSession.currentWorkspace?.id else {
            errorMessage = "Pick a workspace before uploading a squad avatar."
            return nil
        }
        guard !isMutating else { return nil }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }

        do {
            let attachment = try await api.uploadFile(
                filename: filename,
                data: data,
                contentType: contentType,
                workspaceId: workspaceId
            )
            return attachment.url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func mutate(workspaceId: String, _ operation: () async throws -> Squad) async -> Squad? {
        guard !isMutating else { return nil }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }

        do {
            let squad = try await operation()
            upsert(squad)
            await WorkspaceMetadataCache.shared.invalidate(workspaceId: workspaceId, api: api)
            return squad
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func upsert(_ squad: Squad) {
        guard squad.archivedAt == nil else {
            squads.removeAll { $0.id == squad.id }
            return
        }
        if let index = squads.firstIndex(where: { $0.id == squad.id }) {
            squads[index] = squad
        } else {
            squads.append(squad)
        }
        squads.sort(by: squadSort)
    }

    private func squadSort(_ lhs: Squad, _ rhs: Squad) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
