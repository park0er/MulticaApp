import Foundation
import Observation

@Observable
@MainActor
public final class SquadsViewModel {
    public var squads: [Squad] = []
    /// Active agents in the workspace, used to pick a squad leader.
    public var agents: [Agent] = []
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
            let loadedSquads = try await squadsResult
            let loadedAgents = try await agentsResult
            squads = loadedSquads
                .filter { $0.archivedAt == nil }
                .sorted(by: squadSort)
            agents = loadedAgents.filter { $0.archivedAt == nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The display name for a squad's leader agent, if resolvable.
    public func leaderName(for squad: Squad) -> String? {
        guard let leaderId = squad.leaderId else { return nil }
        return agents.first(where: { $0.id == leaderId })?.name
    }

    public func createSquad(name: String, description: String, leaderId: String, avatarUrl: String?) async -> Squad? {
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
        return await mutate(workspaceId: workspaceId) {
            try await api.createSquad(
                name: trimmedName,
                description: trimmedDescription.isEmpty ? nil : trimmedDescription,
                leaderId: leaderId,
                avatarUrl: avatarUrl,
                workspaceId: workspaceId
            )
        }
    }

    public func updateSquad(
        id: String,
        name: String,
        description: String,
        instructions: String,
        leaderId: String?
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
        return await mutate(workspaceId: workspaceId) {
            try await api.updateSquad(
                id: id,
                name: trimmedName,
                description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                instructions: instructions,
                leaderId: leaderId,
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
