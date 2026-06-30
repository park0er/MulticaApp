import Foundation

public actor WorkspaceMetadataCache {
    public static let shared = WorkspaceMetadataCache()

    private struct CacheKey: Hashable {
        let clientId: UUID
        let workspaceId: String
    }

    private var membersByKey: [CacheKey: [WorkspaceMember]] = [:]
    private var activeAgentsByKey: [CacheKey: [Agent]] = [:]
    private var allAgentsByKey: [CacheKey: [Agent]] = [:]
    private var activeSquadsByKey: [CacheKey: [Squad]] = [:]
    private var allSquadsByKey: [CacheKey: [Squad]] = [:]
    private var projectsByKey: [CacheKey: [Project]] = [:]

    public init() {}

    public func members(workspaceId: String, api: APIClient) async throws -> [WorkspaceMember] {
        let key = CacheKey(clientId: api.cacheIdentifier, workspaceId: workspaceId)
        if let cached = membersByKey[key] {
            return cached
        }
        let loaded = try await api.listMembers(workspaceId: workspaceId)
        membersByKey[key] = loaded
        return loaded
    }

    public func agents(
        workspaceId: String,
        includeArchived: Bool = false,
        api: APIClient
    ) async throws -> [Agent] {
        let key = CacheKey(clientId: api.cacheIdentifier, workspaceId: workspaceId)
        if includeArchived, let cached = allAgentsByKey[key] {
            return cached
        }
        if !includeArchived, let cached = activeAgentsByKey[key] {
            return cached
        }

        let loaded = try await api.listAgents(workspaceId: workspaceId, includeArchived: includeArchived)
        if includeArchived {
            allAgentsByKey[key] = loaded
            activeAgentsByKey[key] = loaded.filter { $0.archivedAt == nil }
        } else {
            activeAgentsByKey[key] = loaded
        }
        return includeArchived ? loaded : loaded.filter { $0.archivedAt == nil }
    }

    public func projects(workspaceId: String, api: APIClient) async throws -> [Project] {
        let key = CacheKey(clientId: api.cacheIdentifier, workspaceId: workspaceId)
        if let cached = projectsByKey[key] {
            return cached
        }

        let limit = 50
        var offset = 0
        var allProjects: [Project] = []
        while true {
            let page = try await api.listProjects(workspaceId: workspaceId, limit: limit, offset: offset)
            allProjects.append(contentsOf: page.items)
            offset += page.items.count
            let shouldContinue = page.total.map { offset < $0 } ?? page.hasMore
            guard shouldContinue, !page.items.isEmpty else { break }
        }

        projectsByKey[key] = allProjects
        return allProjects
    }

    public func squads(
        workspaceId: String,
        includeArchived: Bool = false,
        api: APIClient
    ) async throws -> [Squad] {
        let key = CacheKey(clientId: api.cacheIdentifier, workspaceId: workspaceId)
        if includeArchived, let cached = allSquadsByKey[key] {
            return cached
        }
        if !includeArchived, let cached = activeSquadsByKey[key] {
            return cached
        }

        let loaded = (try? await api.listSquads(workspaceId: workspaceId, includeArchived: includeArchived)) ?? []
        if includeArchived {
            allSquadsByKey[key] = loaded
            activeSquadsByKey[key] = loaded.filter { $0.archivedAt == nil }
        } else {
            activeSquadsByKey[key] = loaded
        }
        return includeArchived ? loaded : loaded.filter { $0.archivedAt == nil }
    }

    public func project(id: String, workspaceId: String, api: APIClient) async throws -> Project {
        let key = CacheKey(clientId: api.cacheIdentifier, workspaceId: workspaceId)
        if let cached = projectsByKey[key]?.first(where: { $0.id == id }) {
            return cached
        }
        let loaded = try await api.getProject(id: id, workspaceId: workspaceId)
        projectsByKey[key, default: []].append(loaded)
        return loaded
    }

    public func invalidate(workspaceId: String, api: APIClient) {
        let key = CacheKey(clientId: api.cacheIdentifier, workspaceId: workspaceId)
        membersByKey.removeValue(forKey: key)
        activeAgentsByKey.removeValue(forKey: key)
        allAgentsByKey.removeValue(forKey: key)
        activeSquadsByKey.removeValue(forKey: key)
        allSquadsByKey.removeValue(forKey: key)
        projectsByKey.removeValue(forKey: key)
    }

    /// Best-effort live presence for every agent in the workspace, keyed by
    /// agent id. Combines the (cached) agent list with the runtime list and the
    /// active-task snapshot, then derives the same working/idle/offline buckets
    /// used by the Agents page. Presence is volatile, so this is computed fresh
    /// each call (not cached) and never throws — a failure yields an empty map
    /// so callers simply render avatars without a status dot.
    public func agentPresence(workspaceId: String, api: APIClient) async -> [String: AgentPresenceSummary] {
        async let agentsResult = try? agents(workspaceId: workspaceId, includeArchived: true, api: api)
        async let runtimesResult = try? api.listRuntimes(workspaceId: workspaceId)
        async let snapshotResult = try? api.getAgentTaskSnapshot(workspaceId: workspaceId)
        let agents = await agentsResult ?? []
        let runtimes = await runtimesResult ?? []
        let tasks = await snapshotResult ?? []
        guard !agents.isEmpty else { return [:] }
        return AgentPresenceSummary.buildMap(agents: agents, runtimes: runtimes, tasks: tasks)
    }

    public func removeAll() {
        membersByKey.removeAll()
        activeAgentsByKey.removeAll()
        allAgentsByKey.removeAll()
        activeSquadsByKey.removeAll()
        allSquadsByKey.removeAll()
        projectsByKey.removeAll()
    }
}
