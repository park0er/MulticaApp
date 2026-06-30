import Foundation
import Observation

@Observable
@MainActor
public final class SquadDetailViewModel {
    public private(set) var squad: Squad
    public private(set) var members: [SquadMember] = []
    public private(set) var agents: [Agent] = []
    public private(set) var workspaceMembers: [WorkspaceMember] = []
    public private(set) var memberStatusById: [String: SquadMemberStatus] = [:]
    /// Live agent presence keyed by agent id, used for the member status dot so
    /// online agents read green — identical to the Agents list (the server
    /// status bucket is kept only for the text label / active issues).
    public private(set) var presenceByAgentId: [String: AgentPresenceSummary] = [:]
    public var isLoading = false
    public var isMutating = false
    public var errorMessage: String?

    private let api: APIClient
    private let authSession: AuthSession

    public init(squad: Squad, api: APIClient, authSession: AuthSession) {
        self.squad = squad
        self.api = api
        self.authSession = authSession
    }

    private var workspaceId: String? { authSession.currentWorkspace?.id }

    public func load() async {
        guard let workspaceId else {
            errorMessage = "Pick a workspace before opening a squad."
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let squadResult = api.getSquad(id: squad.id, workspaceId: workspaceId)
            async let membersResult = api.listSquadMembers(squadId: squad.id, workspaceId: workspaceId)
            async let agentsResult = api.listAgents(workspaceId: workspaceId)
            async let wsMembersResult = api.listMembers(workspaceId: workspaceId)
            squad = try await squadResult
            members = try await membersResult
            agents = try await agentsResult
            workspaceMembers = try await wsMembersResult
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadMemberStatus()
    }

    /// Presence snapshot is non-fatal: a failure leaves rows without a status
    /// pill rather than blocking the page.
    private func loadMemberStatus() async {
        guard let workspaceId else { return }
        async let presenceResult = WorkspaceMetadataCache.shared.agentPresence(workspaceId: workspaceId, api: api)
        do {
            let response = try await api.getSquadMemberStatus(squadId: squad.id, workspaceId: workspaceId)
            var map: [String: SquadMemberStatus] = [:]
            for entry in response.members { map[entry.memberId] = entry }
            memberStatusById = map
        } catch {
            // keep whatever we had; presence is an enhancement.
        }
        presenceByAgentId = await presenceResult
    }

    public func status(for member: SquadMember) -> SquadMemberStatus? {
        memberStatusById[member.memberId]
    }

    // MARK: - Display helpers

    public func entityName(type: String, id: String) -> String {
        if type == "agent" {
            return agents.first(where: { $0.id == id })?.name ?? String(id.prefix(8))
        }
        return workspaceMembers.first(where: { $0.userId == id })?.name ?? String(id.prefix(8))
    }

    public func entityAvatarUrl(type: String, id: String) -> String? {
        if type == "agent" {
            return agents.first(where: { $0.id == id })?.avatarUrl
        }
        return workspaceMembers.first(where: { $0.userId == id })?.avatarUrl
    }

    public func isLeader(_ member: SquadMember) -> Bool {
        member.memberType == "agent" && squad.leaderId == member.memberId
    }

    /// Agents not yet in the squad, available to add. Mirrors web `availableAgents`.
    public var availableAgents: [Agent] {
        agents.filter { agent in
            agent.archivedAt == nil && !members.contains { $0.memberType == "agent" && $0.memberId == agent.id }
        }
    }

    /// Workspace members not yet in the squad. Mirrors web `availableMembers`.
    public var availableWorkspaceMembers: [WorkspaceMember] {
        workspaceMembers.filter { wm in
            !members.contains { $0.memberType == "member" && $0.memberId == wm.userId }
        }
    }

    // MARK: - Squad field edits

    public func updateName(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorMessage = "Enter a squad name."; return }
        await updateSquad { try await api.updateSquad(id: squad.id, name: trimmed, workspaceId: workspaceId) }
    }

    public func updateDescription(_ description: String) async {
        await updateSquad { try await api.updateSquad(id: squad.id, description: description, workspaceId: workspaceId) }
    }

    public func updateInstructions(_ instructions: String) async {
        await updateSquad { try await api.updateSquad(id: squad.id, instructions: instructions, workspaceId: workspaceId) }
    }

    public func updateAvatar(url: String) async {
        await updateSquad { try await api.updateSquad(id: squad.id, avatarUrl: url, workspaceId: workspaceId) }
    }

    public func setLeader(agentId: String) async {
        await updateSquad { try await api.updateSquad(id: squad.id, leaderId: agentId, workspaceId: workspaceId) }
    }

    public func uploadAvatarFile(filename: String, data: Data, contentType: String) async -> String? {
        guard let workspaceId else { errorMessage = "Pick a workspace first."; return nil }
        do {
            let attachment = try await api.uploadFile(filename: filename, data: data, contentType: contentType, workspaceId: workspaceId)
            await updateAvatar(url: attachment.url)
            return attachment.url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Member edits

    /// Add a member with an optional per-squad role/description.
    public func addMember(type: String, id: String, role: String) async {
        guard let workspaceId else { return }
        await mutateMembers {
            _ = try await api.addSquadMember(
                squadId: squad.id,
                memberType: type,
                memberId: id,
                role: role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : role.trimmingCharacters(in: .whitespacesAndNewlines),
                workspaceId: workspaceId
            )
        }
    }

    public func removeMember(_ member: SquadMember) async {
        guard let workspaceId else { return }
        await mutateMembers {
            try await api.removeSquadMember(squadId: squad.id, memberType: member.memberType, memberId: member.memberId, workspaceId: workspaceId)
        }
    }

    /// Edit a member's per-squad role/description (the free-text line shown
    /// under each member on the web squad detail page).
    public func updateMemberRole(_ member: SquadMember, role: String) async {
        guard let workspaceId else { return }
        await mutateMembers {
            _ = try await api.updateSquadMemberRole(
                squadId: squad.id,
                memberType: member.memberType,
                memberId: member.memberId,
                role: role.trimmingCharacters(in: .whitespacesAndNewlines),
                workspaceId: workspaceId
            )
        }
    }

    // MARK: - Mutation plumbing

    private func updateSquad(_ operation: () async throws -> Squad) async {
        guard !isMutating else { return }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            squad = try await operation()
            if let workspaceId { await WorkspaceMetadataCache.shared.invalidate(workspaceId: workspaceId, api: api) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mutateMembers(_ operation: () async throws -> Void) async {
        guard !isMutating, let workspaceId else { return }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            try await operation()
            members = try await api.listSquadMembers(squadId: squad.id, workspaceId: workspaceId)
            await WorkspaceMetadataCache.shared.invalidate(workspaceId: workspaceId, api: api)
            await loadMemberStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
