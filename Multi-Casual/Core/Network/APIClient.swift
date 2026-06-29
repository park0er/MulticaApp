import Foundation
import Observation

@Observable
public final class APIClient: @unchecked Sendable {
    public static let defaultRequestTimeout: TimeInterval = 45
    public let cacheIdentifier = UUID()

    public struct CountResponse: Codable, Sendable {
        public let count: Int
    }

    public struct FeedbackResponse: Codable, Equatable, Sendable {
        public let id: String
        public let createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case createdAt = "created_at"
        }
    }

    public struct QuickCreateIssueResponse: Codable, Equatable, Sendable {
        public let taskId: String

        enum CodingKeys: String, CodingKey {
            case taskId = "task_id"
        }
    }

    public struct IssuedCLIToken: Codable, Equatable, Sendable {
        public let token: String
    }

    public struct AppConfig: Codable, Equatable, Sendable {
        public let cdnDomain: String
        public let allowSignup: Bool
        public let googleClientId: String?
        public let posthogKey: String?
        public let posthogHost: String?

        enum CodingKeys: String, CodingKey {
            case cdnDomain = "cdn_domain"
            case allowSignup = "allow_signup"
            case googleClientId = "google_client_id"
            case posthogKey = "posthog_key"
            case posthogHost = "posthog_host"
        }
    }

    public struct ReorderPinItem: Codable, Equatable, Sendable {
        public let itemType: PinnedItemType
        public let itemId: String

        public init(itemType: PinnedItemType, itemId: String) {
            self.itemType = itemType
            self.itemId = itemId
        }

        enum CodingKeys: String, CodingKey {
            case itemType = "item_type"
            case itemId = "item_id"
        }
    }

    public struct BatchUpdateIssuesResponse: Codable, Sendable {
        public let updated: Int
    }

    public struct BatchDeleteIssuesResponse: Codable, Sendable {
        public let deleted: Int
    }

    public enum APIError: Error, @unchecked Sendable {
        case unauthorized
        case notFound
        case missingWorkspace
        case serverError(Int, body: String)
        case decodingError(underlying: Error, body: String)
        case networkError(Error)
        case timeout
    }

    private let session: URLSession
    private let baseURL: URL
    private let requestTimeoutNanoseconds: UInt64
    private var tokenProvider: @Sendable () -> String?
    private var workspaceIdProvider: @Sendable () async -> String?
    private var workspaceSlugProvider: @Sendable () async -> String?

    /// Shared decoder — ISO8601 dates, single allocation across all requests.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Shared encoder — single allocation across all requests.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    // Production init: token provider runs off the main actor because
    // AuthSession.token() is nonisolated (Keychain access is thread-safe).
    public convenience init(
        session: URLSession = .shared,
        baseURL: URL = AppEnvironment.current.apiBaseURL,
        requestTimeout: TimeInterval = APIClient.defaultRequestTimeout,
        authSession: AuthSession
    ) {
        self.init(
            session: session,
            baseURL: baseURL,
            requestTimeout: requestTimeout,
            tokenProvider: { authSession.token() },
            workspaceSlugProvider: { await MainActor.run { authSession.currentWorkspace?.slug } },
            workspaceIdProvider: { await MainActor.run { authSession.currentWorkspace?.id } }
        )
    }

    // Test/flexible init
    public init(
        session: URLSession = .shared,
        baseURL: URL = AppEnvironment.current.apiBaseURL,
        requestTimeout: TimeInterval = APIClient.defaultRequestTimeout,
        token: String? = nil,
        tokenProvider: (@Sendable () -> String?)? = nil,
        workspaceSlugProvider: (@Sendable () async -> String?)? = nil,
        workspaceIdProvider: (@Sendable () async -> String?)? = nil
    ) {
        self.session = session
        self.baseURL = baseURL
        self.requestTimeoutNanoseconds = UInt64(requestTimeout * 1_000_000_000)
        if let token {
            self.tokenProvider = { token }
        } else {
            self.tokenProvider = tokenProvider ?? { nil }
        }
        self.workspaceIdProvider = workspaceIdProvider ?? { nil }
        self.workspaceSlugProvider = workspaceSlugProvider ?? { nil }
    }

    /// Reconfigure the token provider after initial construction.
    /// Used by the app root to wire the environment-injected APIClient to AuthSession.
    public func configure(authSession: AuthSession) {
        self.tokenProvider = { authSession.token() }
        self.workspaceIdProvider = { await MainActor.run { authSession.currentWorkspace?.id } }
        self.workspaceSlugProvider = { await MainActor.run { authSession.currentWorkspace?.slug } }
    }

    // MARK: - Core request

    private func request<T: Decodable>(
        _ method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: (any Encodable)? = nil
    ) async throws -> T {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.serverError(-1, body: "Invalid base URL: \(baseURL) + \(path)")
        }
        let finalQueryItems = try await queryItemsWithWorkspaceIfNeeded(
            path: path,
            queryItems: queryItems,
            headers: headers
        )
        if !finalQueryItems.isEmpty { components.queryItems = finalQueryItems }
        guard let url = components.url else {
            throw APIError.serverError(-1, body: "Invalid URL components for path \(path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        req.setValue("ios", forHTTPHeaderField: "X-Client-Platform")
        req.setValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "debug",
                     forHTTPHeaderField: "X-Client-Version")
        req.setValue(ProcessInfo.processInfo.operatingSystemVersionString, forHTTPHeaderField: "X-Client-OS")
        if let token = tokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let workspaceSlug = await workspaceSlugProvider(), !workspaceSlug.isEmpty {
            req.setValue(workspaceSlug, forHTTPHeaderField: "X-Workspace-Slug")
        }
        for (field, value) in headers where !value.isEmpty {
            req.setValue(value, forHTTPHeaderField: field)
        }
        if let body {
            req.httpBody = try APIClient.encoder.encode(body)
        }

        #if DEBUG
        let debugNetworkLog = ProcessInfo.processInfo.environment["MULTI_CASUAL_DEBUG_NETWORK_LOG"] == "1"
        if debugNetworkLog {
            let headerKeys = req.allHTTPHeaderFields?.keys.sorted().joined(separator: ",") ?? ""
            NSLog("Multi-CasualAPI request \(method) \(url.path) query=\(url.query ?? "") headers=\(headerKeys)")
        }
        #endif

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await responseData(for: req)
        } catch {
            if let apiError = error as? APIError {
                throw apiError
            }
            #if DEBUG
            if debugNetworkLog {
                NSLog("Multi-CasualAPI network error \(method) \(url.path): \(error.localizedDescription)")
            }
            #endif
            throw APIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.serverError(-1, body: "Non-HTTP response: \(response)")
        }
        #if DEBUG
        if debugNetworkLog {
            NSLog("Multi-CasualAPI response \(method) \(url.path) status=\(http.statusCode) bytes=\(data.count)")
        }
        #endif
        switch http.statusCode {
        case 200...299: break
        case 401: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(http.statusCode, body: body)
        }

        if data.isEmpty, T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }

        do {
            return try APIClient.decoder.decode(T.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
            throw APIError.decodingError(underlying: error, body: body)
        }
    }

    private func responseData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { [session] in
                try await session.data(for: request)
            }
            group.addTask { [requestTimeoutNanoseconds] in
                try await Task.sleep(nanoseconds: requestTimeoutNanoseconds)
                throw APIError.timeout
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw APIError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func queryItemsWithWorkspaceIfNeeded(
        path: String,
        queryItems: [URLQueryItem],
        headers: [String: String] = [:]
    ) async throws -> [URLQueryItem] {
        guard isWorkspaceScopedPath(path) else {
            return queryItems
        }
        if queryItems.contains(where: { $0.name == "workspace_id" || $0.name == "workspace_slug" }) {
            return queryItems
        }
        if let headerSlug = headers["X-Workspace-Slug"], !headerSlug.isEmpty {
            return queryItems
        }
        if let workspaceId = await workspaceIdProvider(), !workspaceId.isEmpty {
            return queryItems + [.init(name: "workspace_id", value: workspaceId)]
        }
        if let workspaceSlug = await workspaceSlugProvider(), !workspaceSlug.isEmpty {
            return queryItems + [.init(name: "workspace_slug", value: workspaceSlug)]
        }
        throw APIError.missingWorkspace
    }

    private func isWorkspaceScopedPath(_ path: String) -> Bool {
        if path.hasPrefix("api/workspaces/") {
            return true
        }
        let scopedPrefixes = [
            "api/assignee-frequency",
            "api/issues",
            "api/tasks",
            "api/labels",
            "api/projects",
            "api/autopilots",
            "api/pins",
            "api/attachments",
            "api/upload-file",
            "api/comments",
            "api/agents",
            "api/squads",
            "api/skills",
            "api/usage",
            "api/runtimes",
            "api/agent-task-snapshot",
            "api/agent-activity-30d",
            "api/agent-run-counts",
            "api/chat",
            "api/inbox",
            "api/notification-preferences",
            "api/feedback",
            "api/devices",
        ]
        return scopedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    // MARK: - Auth endpoints

    private struct SendCodeRequest: Encodable { let email: String }
    private struct VerifyCodeRequest: Encodable { let email: String; let code: String }
    private struct TokenResponse: Decodable { let token: String }
    private struct EmptyResponse: Decodable {}
    private struct UpdateMeRequest: Encodable {
        let name: String?
        let avatarUrl: String?

        enum CodingKeys: String, CodingKey {
            case name
            case avatarUrl = "avatar_url"
        }
    }
    private struct RegisterPushTokenRequest: Encodable {
        let token: String
        let platform: String = "apns"
    }
    private struct UpdateWorkspaceRequest: Encodable {
        let name: String
        let description: String?
        let context: String?
        let repos: [WorkspaceRepo]

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            if let description {
                try container.encode(description, forKey: .description)
            } else {
                try container.encodeNil(forKey: .description)
            }
            if let context {
                try container.encode(context, forKey: .context)
            } else {
                try container.encodeNil(forKey: .context)
            }
            try container.encode(repos, forKey: .repos)
        }

        enum CodingKeys: String, CodingKey {
            case name, description, context, repos
        }
    }
    private struct CreateWorkspaceRequest: Encodable {
        let name: String
        let slug: String
        let description: String?
        let context: String?
    }
    private struct CreateMemberRequest: Encodable {
        let email: String
        let role: String
    }
    private struct UpdateMemberRequest: Encodable {
        let role: String
    }
    private struct SkillMutationRequest: Encodable {
        let name: String
        let description: String
        let content: String
    }
    private struct SkillImportRequest: Encodable {
        let url: String
    }
    private struct SetAgentSkillsRequest: Encodable {
        let skillIds: [String]

        enum CodingKeys: String, CodingKey {
            case skillIds = "skill_ids"
        }
    }
    private struct CreateAutopilotRequest: Encodable {
        let title: String
        let description: String?
        let assigneeId: String
        let executionMode: String
        let issueTitleTemplate: String?

        enum CodingKeys: String, CodingKey {
            case title, description
            case assigneeId = "assignee_id"
            case executionMode = "execution_mode"
            case issueTitleTemplate = "issue_title_template"
        }
    }
    private struct UpdateAutopilotRequest: Encodable {
        let title: String
        let description: String?
        let assigneeId: String
        let status: String
        let executionMode: String
        let issueTitleTemplate: String?

        enum CodingKeys: String, CodingKey {
            case title, description, status
            case assigneeId = "assignee_id"
            case executionMode = "execution_mode"
            case issueTitleTemplate = "issue_title_template"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try encodeNullable(description, to: &container, forKey: .description)
            try container.encode(assigneeId, forKey: .assigneeId)
            try container.encode(status, forKey: .status)
            try container.encode(executionMode, forKey: .executionMode)
            try encodeNullable(issueTitleTemplate, to: &container, forKey: .issueTitleTemplate)
        }

        private func encodeNullable<Value: Encodable>(
            _ value: Value?,
            to container: inout KeyedEncodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) throws {
            if let value {
                try container.encode(value, forKey: key)
            } else {
                try container.encodeNil(forKey: key)
            }
        }
    }
    private struct UpdateNotificationPreferencesRequest: Encodable {
        let preferences: NotificationPreferences
    }
    private struct CreateFeedbackRequest: Encodable {
        let message: String
        let url: String?
        let workspaceId: String

        enum CodingKeys: String, CodingKey {
            case message, url
            case workspaceId = "workspace_id"
        }
    }
    private struct CreatePersonalAccessTokenRequest: Encodable {
        let name: String
        let expiresInDays: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case expiresInDays = "expires_in_days"
        }
    }
    private struct CreateChatSessionRequest: Encodable {
        let agentId: String
        let title: String?

        enum CodingKeys: String, CodingKey {
            case agentId = "agent_id"
            case title
        }
    }
    private struct SendChatMessageRequest: Encodable {
        let content: String
        let attachmentIds: [String]?

        enum CodingKeys: String, CodingKey {
            case content
            case attachmentIds = "attachment_ids"
        }
    }
    private struct CreateProjectRequest: Encodable {
        let title: String
        let description: String?
        let status: ProjectStatus
        let priority: IssuePriority
        let icon: String?
        let leadType: String?
        let leadId: String?
        let resources: [CreateProjectResourceRequest]?

        enum CodingKeys: String, CodingKey {
            case title, description, status, priority, icon, resources
            case leadType = "lead_type"
            case leadId = "lead_id"
        }
    }

    private struct CreateProjectResourceRequest: Encodable {
        let resourceType: String
        let resourceRef: [String: JSONValue]
        let label: String?
        let position: Int?

        enum CodingKeys: String, CodingKey {
            case resourceType = "resource_type"
            case resourceRef = "resource_ref"
            case label, position
        }
    }

    private struct UpdateProjectRequest: Encodable {
        let title: String
        let description: String?
        let status: ProjectStatus
        let priority: IssuePriority
        let icon: String?
        let leadType: String?
        let leadId: String?

        enum CodingKeys: String, CodingKey {
            case title, description, status, priority, icon
            case leadType = "lead_type"
            case leadId = "lead_id"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            if let description {
                try container.encode(description, forKey: .description)
            } else {
                try container.encodeNil(forKey: .description)
            }
            try container.encode(status, forKey: .status)
            try container.encode(priority, forKey: .priority)
            if let icon {
                try container.encode(icon, forKey: .icon)
            } else {
                try container.encodeNil(forKey: .icon)
            }
            if let leadType {
                try container.encode(leadType, forKey: .leadType)
            } else {
                try container.encodeNil(forKey: .leadType)
            }
            if let leadId {
                try container.encode(leadId, forKey: .leadId)
            } else {
                try container.encodeNil(forKey: .leadId)
            }
        }
    }
    private struct CreatePinRequest: Encodable {
        let itemType: PinnedItemType
        let itemId: String

        enum CodingKeys: String, CodingKey {
            case itemType = "item_type"
            case itemId = "item_id"
        }
    }
    private struct ReorderPinsRequest: Encodable {
        struct Item: Encodable {
            let itemType: PinnedItemType
            let itemId: String
            let position: Int

            enum CodingKeys: String, CodingKey {
                case itemType = "item_type"
                case itemId = "item_id"
                case position
            }
        }

        let items: [Item]
    }
    private struct CreateAutopilotTriggerRequest: Encodable {
        let kind: String
        let cronExpression: String?
        let timezone: String?
        let label: String?

        enum CodingKeys: String, CodingKey {
            case kind, timezone, label
            case cronExpression = "cron_expression"
        }
    }
    private struct UpdateAutopilotTriggerRequest: Encodable {
        let enabled: Bool?
        let cronExpression: String?
        let timezone: String?
        let label: String?

        enum CodingKeys: String, CodingKey {
            case enabled, timezone, label
            case cronExpression = "cron_expression"
        }
    }
    private struct RuntimeUpdateRequest: Encodable {
        let targetVersion: String

        enum CodingKeys: String, CodingKey {
            case targetVersion = "target_version"
        }
    }
    private struct RuntimeLocalSkillImportRequestBody: Encodable {
        let skillKey: String
        let name: String?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case skillKey = "skill_key"
            case name, description
        }
    }

    public struct AgentCancelResponse: Codable, Sendable {
        public let count: Int

        enum CodingKeys: String, CodingKey {
            case count = "cancelled"
        }
    }

    private struct ActiveTasksResponse: Codable, Sendable {
        let tasks: [AgentTask]
    }

    public func sendCode(email: String) async throws {
        let _: EmptyResponse = try await request("POST", path: "auth/send-code",
                                                  body: SendCodeRequest(email: email))
    }

    public func verifyCode(email: String, code: String) async throws -> String {
        let resp: TokenResponse = try await request("POST", path: "auth/verify-code",
                                                     body: VerifyCodeRequest(email: email, code: code))
        return resp.token
    }

    public func logout() async throws {
        let _: EmptyResponse = try await request("POST", path: "auth/logout")
    }

    public func issueCliToken() async throws -> IssuedCLIToken {
        try await request("POST", path: "api/cli-token")
    }

    public func getConfig() async throws -> AppConfig {
        try await request("GET", path: "api/config")
    }

    public func getMe() async throws -> User {
        try await request("GET", path: "api/me")
    }

    public func updateMe(name: String? = nil, avatarUrl: String? = nil) async throws -> User {
        try await request(
            "PATCH",
            path: "api/me",
            body: UpdateMeRequest(name: name, avatarUrl: avatarUrl)
        )
    }

    // GET /api/workspaces returns a bare JSON array, not an object wrapper.
    // Confirmed via desktop client consumer and real response body (PAR-72).
    public func listWorkspaces() async throws -> [Workspace] {
        try await request("GET", path: "api/workspaces")
    }

    public func createWorkspace(name: String, slug: String, description: String? = nil, context: String? = nil) async throws -> Workspace {
        try await request(
            "POST",
            path: "api/workspaces",
            body: CreateWorkspaceRequest(name: name, slug: slug, description: description, context: context)
        )
    }

    public func getWorkspace(id: String, workspaceId: String? = nil) async throws -> Workspace {
        try await request("GET", path: "api/workspaces/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func updateWorkspace(
        id: String,
        workspaceId: String? = nil,
        name: String,
        description: String?,
        context: String?,
        repos: [WorkspaceRepo]
    ) async throws -> Workspace {
        try await request(
            "PATCH",
            path: "api/workspaces/\(id)",
            queryItems: workspaceQuery(workspaceId),
            body: UpdateWorkspaceRequest(
                name: name,
                description: description,
                context: context,
                repos: repos
            )
        )
    }

    public func leaveWorkspace(id: String) async throws {
        let _: EmptyResponse = try await request(
            "POST",
            path: "api/workspaces/\(id)/leave",
            queryItems: workspaceQuery(id)
        )
    }

    public func deleteWorkspace(id: String) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/workspaces/\(id)",
            queryItems: workspaceQuery(id)
        )
    }

    public func listMyInvitations() async throws -> [Invitation] {
        try await request("GET", path: "api/invitations")
    }

    public func getInvitation(id: String) async throws -> Invitation {
        try await request("GET", path: "api/invitations/\(id)")
    }

    public func acceptInvitation(id: String) async throws -> WorkspaceMember {
        try await request("POST", path: "api/invitations/\(id)/accept")
    }

    public func declineInvitation(id: String) async throws {
        let _: EmptyResponse = try await request("POST", path: "api/invitations/\(id)/decline")
    }

    public func registerPushToken(_ token: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request(
            "PUT",
            path: "api/devices/push-token",
            queryItems: workspaceQuery(workspaceId),
            body: RegisterPushTokenRequest(token: token)
        )
    }

    // MARK: - File Uploads

    public func uploadFile(
        filename: String,
        data: Data,
        contentType: String,
        issueId: String? = nil,
        commentId: String? = nil,
        workspaceId: String? = nil
    ) async throws -> Attachment {
        let path = "api/upload-file"
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.serverError(-1, body: "Invalid base URL: \(baseURL) + \(path)")
        }
        let queryItems = try await queryItemsWithWorkspaceIfNeeded(
            path: path,
            queryItems: workspaceQuery(workspaceId)
        )
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.serverError(-1, body: "Invalid URL components for path \(path)")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        req.setValue("ios", forHTTPHeaderField: "X-Client-Platform")
        req.setValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "debug",
                     forHTTPHeaderField: "X-Client-Version")
        req.setValue(ProcessInfo.processInfo.operatingSystemVersionString, forHTTPHeaderField: "X-Client-OS")
        if let token = tokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let workspaceSlug = await workspaceSlugProvider(), !workspaceSlug.isEmpty {
            req.setValue(workspaceSlug, forHTTPHeaderField: "X-Workspace-Slug")
        }
        req.httpBody = multipartBody(
            boundary: boundary,
            file: (filename: filename, data: data, contentType: contentType),
            fields: [
                ("issue_id", issueId),
                ("comment_id", commentId),
            ]
        )

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await responseData(for: req)
        } catch {
            if let apiError = error as? APIError {
                throw apiError
            }
            throw APIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.serverError(-1, body: "Non-HTTP response: \(response)")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(http.statusCode, body: body)
        }

        do {
            return try APIClient.decoder.decode(Attachment.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
            throw APIError.decodingError(underlying: error, body: body)
        }
    }

    public func listAttachments(issueId: String, workspaceId: String? = nil) async throws -> [Attachment] {
        try await request(
            "GET",
            path: "api/issues/\(issueId)/attachments",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func deleteAttachment(id: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/attachments/\(id)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func getAttachmentContent(id: String, workspaceId: String? = nil) async throws -> String {
        let path = "api/attachments/\(id)/content"
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.serverError(-1, body: "Invalid base URL: \(baseURL) + \(path)")
        }
        let queryItems = try await queryItemsWithWorkspaceIfNeeded(
            path: path,
            queryItems: workspaceQuery(workspaceId)
        )
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw APIError.serverError(-1, body: "Invalid URL components for path \(path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        req.setValue("ios", forHTTPHeaderField: "X-Client-Platform")
        req.setValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "debug",
                     forHTTPHeaderField: "X-Client-Version")
        req.setValue(ProcessInfo.processInfo.operatingSystemVersionString, forHTTPHeaderField: "X-Client-OS")
        if let token = tokenProvider() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let workspaceSlug = await workspaceSlugProvider(), !workspaceSlug.isEmpty {
            req.setValue(workspaceSlug, forHTTPHeaderField: "X-Workspace-Slug")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await responseData(for: req)
        } catch {
            if let apiError = error as? APIError {
                throw apiError
            }
            throw APIError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.serverError(-1, body: "Non-HTTP response: \(response)")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.serverError(http.statusCode, body: body)
        }

        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func multipartBody(
        boundary: String,
        file: (filename: String, data: Data, contentType: String),
        fields: [(name: String, value: String?)]
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for field in fields {
            guard let value = field.value, !value.isEmpty else { continue }
            body.appendString("--\(boundary)\(lineBreak)")
            body.appendString("Content-Disposition: form-data; name=\"\(field.name)\"\(lineBreak)\(lineBreak)")
            body.appendString("\(value)\(lineBreak)")
        }

        body.appendString("--\(boundary)\(lineBreak)")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.filename)\"\(lineBreak)")
        body.appendString("Content-Type: \(file.contentType)\(lineBreak)\(lineBreak)")
        body.append(file.data)
        body.appendString(lineBreak)
        body.appendString("--\(boundary)--\(lineBreak)")
        return body
    }

    // MARK: - Issues

    private struct CreateIssueRequest: Encodable {
        let title: String
        let description: String?
        let workspaceId: String
        let status: IssueStatus?
        let priority: IssuePriority?
        let assigneeType: String?
        let assigneeId: String?
        let projectId: String?
        let parentIssueId: String?
        let dueDate: String?
        let attachmentIds: [String]?
        enum CodingKeys: String, CodingKey {
            case title, description, status, priority
            case workspaceId = "workspace_id"
            case assigneeType = "assignee_type"
            case assigneeId = "assignee_id"
            case projectId = "project_id"
            case parentIssueId = "parent_issue_id"
            case dueDate = "due_date"
            case attachmentIds = "attachment_ids"
        }
    }

    private struct QuickCreateIssueRequest: Encodable {
        let agentId: String
        let prompt: String

        enum CodingKeys: String, CodingKey {
            case agentId = "agent_id"
            case prompt
        }
    }

    private struct UpdateIssueRequest: Encodable {
        let status: IssueStatus?
        let priority: IssuePriority?
        let position: Int?
    }

    private struct BatchIssueUpdates: Encodable {
        let status: IssueStatus?
        let priority: IssuePriority?
        let assigneeType: String?
        let assigneeId: String?

        enum CodingKeys: String, CodingKey {
            case status, priority
            case assigneeType = "assignee_type"
            case assigneeId = "assignee_id"
        }
    }

    private struct BatchUpdateIssuesRequest: Encodable {
        let issueIds: [String]
        let updates: BatchIssueUpdates

        enum CodingKeys: String, CodingKey {
            case issueIds = "issue_ids"
            case updates
        }
    }

    private struct BatchDeleteIssuesRequest: Encodable {
        let issueIds: [String]

        enum CodingKeys: String, CodingKey {
            case issueIds = "issue_ids"
        }
    }

    private struct UpdateIssueDetailsRequest: Encodable {
        let title: String
        let description: String?
        let status: IssueStatus
        let priority: IssuePriority
        let assigneeType: String?
        let assigneeId: String?
        let projectId: String?
        let dueDate: String?

        enum CodingKeys: String, CodingKey {
            case title, description, status, priority
            case assigneeType = "assignee_type"
            case assigneeId = "assignee_id"
            case projectId = "project_id"
            case dueDate = "due_date"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(title, forKey: .title)
            try encodeNullable(description, to: &container, forKey: .description)
            try container.encode(status, forKey: .status)
            try container.encode(priority, forKey: .priority)
            try encodeNullable(assigneeType, to: &container, forKey: .assigneeType)
            try encodeNullable(assigneeId, to: &container, forKey: .assigneeId)
            try encodeNullable(projectId, to: &container, forKey: .projectId)
            try encodeNullable(dueDate, to: &container, forKey: .dueDate)
        }

        private func encodeNullable<Value: Encodable>(
            _ value: Value?,
            to container: inout KeyedEncodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) throws {
            if let value {
                try container.encode(value, forKey: key)
            } else {
                try container.encodeNil(forKey: key)
            }
        }
    }

    public func listIssues(
        workspaceId: String,
        status: IssueStatus? = nil,
        priority: IssuePriority? = nil,
        projectId: String? = nil,
        assigneeId: String? = nil,
        assigneeIds: [String]? = nil,
        creatorId: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> PageResponse<Issue> {
        var queryItems: [URLQueryItem] = [
            .init(name: "workspace_id", value: workspaceId),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ]
        if let status {
            queryItems.append(.init(name: "status", value: status.rawValue))
        }
        if let priority {
            queryItems.append(.init(name: "priority", value: priority.rawValue))
        }
        if let projectId {
            queryItems.append(.init(name: "project_id", value: projectId))
        }
        if let assigneeId {
            queryItems.append(.init(name: "assignee_id", value: assigneeId))
        }
        if let assigneeIds, !assigneeIds.isEmpty {
            queryItems.append(.init(name: "assignee_ids", value: assigneeIds.joined(separator: ",")))
        }
        if let creatorId {
            queryItems.append(.init(name: "creator_id", value: creatorId))
        }
        return try await request("GET", path: "api/issues", queryItems: queryItems)
    }

    public func searchIssues(
        workspaceId: String,
        query: String,
        limit: Int = 50,
        offset: Int = 0,
        includeClosed: Bool = false
    ) async throws -> PageResponse<Issue> {
        var queryItems: [URLQueryItem] = [
            .init(name: "q", value: query),
            .init(name: "workspace_id", value: workspaceId),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ]
        if includeClosed {
            queryItems.append(.init(name: "include_closed", value: "true"))
        }
        return try await request("GET", path: "api/issues/search", queryItems: queryItems)
    }

    public func getIssue(id: String, workspaceId: String? = nil) async throws -> Issue {
        try await request("GET", path: "api/issues/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func createIssue(
        title: String,
        description: String?,
        workspaceId: String,
        status: IssueStatus? = nil,
        priority: IssuePriority? = nil,
        assigneeType: String? = nil,
        assigneeId: String? = nil,
        projectId: String? = nil,
        parentIssueId: String? = nil,
        dueDate: String? = nil,
        attachmentIds: [String]? = nil
    ) async throws -> Issue {
        try await request("POST", path: "api/issues",
                          queryItems: workspaceQuery(workspaceId),
                          body: CreateIssueRequest(
                            title: title,
                            description: description,
                            workspaceId: workspaceId,
                            status: status,
                            priority: priority,
                            assigneeType: assigneeType,
                            assigneeId: assigneeId,
                            projectId: projectId,
                            parentIssueId: parentIssueId,
                            dueDate: dueDate,
                            attachmentIds: attachmentIds?.isEmpty == false ? attachmentIds : nil
                          ))
    }

    public func quickCreateIssue(agentId: String, prompt: String, workspaceId: String) async throws -> QuickCreateIssueResponse {
        try await request(
            "POST",
            path: "api/issues/quick-create",
            queryItems: workspaceQuery(workspaceId),
            body: QuickCreateIssueRequest(agentId: agentId, prompt: prompt)
        )
    }

    public func listComments(issueId: String, workspaceId: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> PageResponse<Comment> {
        let page: PageResponse<Comment> = try await request("GET", path: "api/issues/\(issueId)/comments", queryItems: [
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ] + workspaceQuery(workspaceId))
        return page.inferringHasMore(fromOffset: offset)
    }

    private struct AddCommentRequest: Encodable {
        let content: String
        let type: String
        let parentId: String?
        let attachmentIds: [String]?
        let suppressAgentIds: [String]?

        enum CodingKeys: String, CodingKey {
            case content, type
            case parentId = "parent_id"
            case attachmentIds = "attachment_ids"
            case suppressAgentIds = "suppress_agent_ids"
        }
    }

    private struct UpdateCommentRequest: Encodable {
        let content: String
    }

    private struct LabelMutationRequest: Encodable {
        let name: String
        let color: String
    }

    private struct AttachLabelRequest: Encodable {
        let labelId: String
        enum CodingKeys: String, CodingKey { case labelId = "label_id" }
    }

    private struct CreateSquadRequest: Encodable {
        let name: String
        let description: String?
        let leaderId: String
        let avatarUrl: String?

        enum CodingKeys: String, CodingKey {
            case name, description
            case leaderId = "leader_id"
            case avatarUrl = "avatar_url"
        }
    }

    private struct UpdateSquadRequest: Encodable {
        let name: String?
        let description: String?
        let instructions: String?
        let leaderId: String?
        let avatarUrl: String?

        enum CodingKeys: String, CodingKey {
            case name, description, instructions
            case leaderId = "leader_id"
            case avatarUrl = "avatar_url"
        }
    }

    private struct SquadMemberMutationRequest: Encodable {
        let memberType: String
        let memberId: String
        let role: String?

        enum CodingKeys: String, CodingKey {
            case memberType = "member_type"
            case memberId = "member_id"
            case role
        }
    }

    private struct IssueSubscriberMutationRequest: Encodable {
        let userId: String?
        let userType: String?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case userType = "user_type"
        }
    }

    private struct ReactionRequest: Encodable {
        let emoji: String
    }

    public func addComment(
        issueId: String,
        content: String,
        parentId: String? = nil,
        attachmentIds: [String]? = nil,
        suppressAgentIds: [String]? = nil,
        workspaceId: String? = nil
    ) async throws -> Comment {
        try await request("POST", path: "api/issues/\(issueId)/comments",
                          queryItems: workspaceQuery(workspaceId),
                          body: AddCommentRequest(
                            content: content,
                            type: "comment",
                            parentId: parentId,
                            attachmentIds: attachmentIds?.isEmpty == false ? attachmentIds : nil,
                            suppressAgentIds: suppressAgentIds?.isEmpty == false ? suppressAgentIds : nil
                          ))
    }

    public func listTimeline(issueId: String, workspaceId: String? = nil) async throws -> [TimelineEntry] {
        try await request("GET", path: "api/issues/\(issueId)/timeline", queryItems: workspaceQuery(workspaceId))
    }

    public func getIssueUsage(issueId: String, workspaceId: String? = nil) async throws -> IssueUsageSummary {
        try await request("GET", path: "api/issues/\(issueId)/usage", queryItems: workspaceQuery(workspaceId))
    }

    public func updateComment(commentId: String, content: String, workspaceId: String? = nil) async throws -> Comment {
        try await request(
            "PUT",
            path: "api/comments/\(commentId)",
            queryItems: workspaceQuery(workspaceId),
            body: UpdateCommentRequest(content: content)
        )
    }

    public func deleteComment(commentId: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request("DELETE", path: "api/comments/\(commentId)", queryItems: workspaceQuery(workspaceId))
    }

    /// Mark a comment as the resolved answer of its thread. The server enforces a
    /// single-resolution invariant per thread: resolving this comment clears any
    /// other resolution in the same thread atomically. The target may be a root
    /// comment or any reply ("resolve with this reply"). Returns the updated
    /// comment with authoritative resolved_at / resolved_by_* fields.
    public func resolveComment(commentId: String, workspaceId: String? = nil) async throws -> Comment {
        try await request("POST", path: "api/comments/\(commentId)/resolve", queryItems: workspaceQuery(workspaceId))
    }

    /// Clear the resolve state on a comment (un-resolve the thread). The server
    /// returns the updated comment; we decode it as `Comment` (not EmptyResponse)
    /// so local state stays in sync with the authoritative server value.
    public func unresolveComment(commentId: String, workspaceId: String? = nil) async throws -> Comment {
        try await request("DELETE", path: "api/comments/\(commentId)/resolve", queryItems: workspaceQuery(workspaceId))
    }

    public func updateIssue(
        id: String,
        workspaceId: String? = nil,
        status: IssueStatus? = nil,
        priority: IssuePriority? = nil,
        position: Int? = nil
    ) async throws -> Issue {
        try await request(
            "PUT",
            path: "api/issues/\(id)",
            queryItems: workspaceQuery(workspaceId),
            body: UpdateIssueRequest(status: status, priority: priority, position: position)
        )
    }

    public func updateIssueDetails(
        id: String,
        workspaceId: String? = nil,
        title: String,
        description: String?,
        status: IssueStatus,
        priority: IssuePriority,
        assigneeType: String?,
        assigneeId: String?,
        projectId: String?,
        dueDate: String?
    ) async throws -> Issue {
        try await request(
            "PUT",
            path: "api/issues/\(id)",
            queryItems: workspaceQuery(workspaceId),
            body: UpdateIssueDetailsRequest(
                title: title,
                description: description,
                status: status,
                priority: priority,
                assigneeType: assigneeType,
                assigneeId: assigneeId,
                projectId: projectId,
                dueDate: dueDate
            )
        )
    }

    public func deleteIssue(id: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request("DELETE", path: "api/issues/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func batchUpdateIssues(
        ids: [String],
        workspaceId: String? = nil,
        status: IssueStatus? = nil,
        priority: IssuePriority? = nil,
        assigneeType: String? = nil,
        assigneeId: String? = nil
    ) async throws -> BatchUpdateIssuesResponse {
        try await request(
            "POST",
            path: "api/issues/batch-update",
            queryItems: workspaceQuery(workspaceId),
            body: BatchUpdateIssuesRequest(
                issueIds: ids,
                updates: BatchIssueUpdates(
                    status: status,
                    priority: priority,
                    assigneeType: assigneeType,
                    assigneeId: assigneeId
                )
            )
        )
    }

    public func batchDeleteIssues(ids: [String], workspaceId: String? = nil) async throws -> BatchDeleteIssuesResponse {
        try await request(
            "POST",
            path: "api/issues/batch-delete",
            queryItems: workspaceQuery(workspaceId),
            body: BatchDeleteIssuesRequest(issueIds: ids)
        )
    }

    public func listLabels(workspaceId: String? = nil) async throws -> ListLabelsResponse {
        try await request("GET", path: "api/labels", queryItems: workspaceQuery(workspaceId))
    }

    public func getLabel(id: String, workspaceId: String? = nil) async throws -> IssueLabel {
        try await request("GET", path: "api/labels/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func createLabel(name: String, color: String, workspaceId: String? = nil) async throws -> IssueLabel {
        try await request(
            "POST",
            path: "api/labels",
            queryItems: workspaceQuery(workspaceId),
            body: LabelMutationRequest(name: name, color: color)
        )
    }

    public func updateLabel(id: String, name: String, color: String, workspaceId: String? = nil) async throws -> IssueLabel {
        try await request(
            "PUT",
            path: "api/labels/\(id)",
            queryItems: workspaceQuery(workspaceId),
            body: LabelMutationRequest(name: name, color: color)
        )
    }

    public func deleteLabel(id: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request("DELETE", path: "api/labels/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func listLabelsForIssue(issueId: String, workspaceId: String? = nil) async throws -> IssueLabelsResponse {
        try await request("GET", path: "api/issues/\(issueId)/labels", queryItems: workspaceQuery(workspaceId))
    }

    public func attachLabel(issueId: String, labelId: String, workspaceId: String? = nil) async throws -> IssueLabelsResponse {
        try await request(
            "POST",
            path: "api/issues/\(issueId)/labels",
            queryItems: workspaceQuery(workspaceId),
            body: AttachLabelRequest(labelId: labelId)
        )
    }

    public func detachLabel(issueId: String, labelId: String, workspaceId: String? = nil) async throws -> IssueLabelsResponse {
        try await request("DELETE", path: "api/issues/\(issueId)/labels/\(labelId)", queryItems: workspaceQuery(workspaceId))
    }

    public func listPins(workspaceId: String? = nil, workspaceSlug: String? = nil) async throws -> [PinnedItem] {
        try await request(
            "GET",
            path: "api/pins",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug)
        )
    }

    public func createPin(
        itemType: PinnedItemType,
        itemId: String,
        workspaceId: String? = nil,
        workspaceSlug: String? = nil
    ) async throws -> PinnedItem {
        try await request(
            "POST",
            path: "api/pins",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug),
            body: CreatePinRequest(itemType: itemType, itemId: itemId)
        )
    }

    public func deletePin(
        itemType: PinnedItemType,
        itemId: String,
        workspaceId: String? = nil,
        workspaceSlug: String? = nil
    ) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/pins/\(itemType.rawValue)/\(itemId)",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug)
        )
    }

    public func reorderPins(
        items: [ReorderPinItem],
        workspaceId: String? = nil,
        workspaceSlug: String? = nil
    ) async throws {
        let requestItems = items.enumerated().map { index, item in
            ReorderPinsRequest.Item(itemType: item.itemType, itemId: item.itemId, position: index)
        }
        let _: EmptyResponse = try await request(
            "PUT",
            path: "api/pins/reorder",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug),
            body: ReorderPinsRequest(items: requestItems)
        )
    }

    public func listIssueSubscribers(issueId: String, workspaceId: String? = nil) async throws -> [IssueSubscriber] {
        try await request("GET", path: "api/issues/\(issueId)/subscribers", queryItems: workspaceQuery(workspaceId))
    }

    public func subscribeToIssue(
        issueId: String,
        userId: String? = nil,
        userType: String? = nil,
        workspaceId: String? = nil
    ) async throws {
        let _: EmptyResponse = try await request(
            "POST",
            path: "api/issues/\(issueId)/subscribe",
            queryItems: workspaceQuery(workspaceId),
            body: IssueSubscriberMutationRequest(userId: userId, userType: userType)
        )
    }

    public func unsubscribeFromIssue(
        issueId: String,
        userId: String? = nil,
        userType: String? = nil,
        workspaceId: String? = nil
    ) async throws {
        let _: EmptyResponse = try await request(
            "POST",
            path: "api/issues/\(issueId)/unsubscribe",
            queryItems: workspaceQuery(workspaceId),
            body: IssueSubscriberMutationRequest(userId: userId, userType: userType)
        )
    }

    public func addReaction(commentId: String, emoji: String, workspaceId: String? = nil) async throws -> Reaction {
        try await request(
            "POST",
            path: "api/comments/\(commentId)/reactions",
            queryItems: workspaceQuery(workspaceId),
            body: ReactionRequest(emoji: emoji)
        )
    }

    public func removeReaction(commentId: String, emoji: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/comments/\(commentId)/reactions",
            queryItems: workspaceQuery(workspaceId),
            body: ReactionRequest(emoji: emoji)
        )
    }

    public func addIssueReaction(issueId: String, emoji: String, workspaceId: String? = nil) async throws -> IssueReaction {
        try await request(
            "POST",
            path: "api/issues/\(issueId)/reactions",
            queryItems: workspaceQuery(workspaceId),
            body: ReactionRequest(emoji: emoji)
        )
    }

    public func removeIssueReaction(issueId: String, emoji: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/issues/\(issueId)/reactions",
            queryItems: workspaceQuery(workspaceId),
            body: ReactionRequest(emoji: emoji)
        )
    }

    public func listChildIssues(issueId: String, workspaceId: String? = nil) async throws -> [Issue] {
        let response: ChildIssuesResponse = try await request(
            "GET",
            path: "api/issues/\(issueId)/children",
            queryItems: workspaceQuery(workspaceId)
        )
        return response.issues
    }

    public func getChildIssueProgress(workspaceId: String? = nil) async throws -> ChildIssueProgressResponse {
        try await request("GET", path: "api/issues/child-progress", queryItems: workspaceQuery(workspaceId))
    }

    public func listAgentRuns(issueId: String, workspaceId: String? = nil) async throws -> [AgentTask] {
        try await request("GET", path: "api/issues/\(issueId)/task-runs", queryItems: workspaceQuery(workspaceId))
    }

    public func getActiveTasksForIssue(issueId: String, workspaceId: String? = nil) async throws -> [AgentTask] {
        let response: ActiveTasksResponse = try await request(
            "GET",
            path: "api/issues/\(issueId)/active-task",
            queryItems: workspaceQuery(workspaceId)
        )
        return response.tasks
    }

    public func cancelTask(issueId: String, taskId: String, workspaceId: String? = nil) async throws -> AgentTask {
        try await request(
            "POST",
            path: "api/issues/\(issueId)/tasks/\(taskId)/cancel",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func listRunMessages(taskId: String, workspaceId: String? = nil) async throws -> [TaskMessage] {
        try await request("GET", path: "api/tasks/\(taskId)/messages", queryItems: workspaceQuery(workspaceId))
    }

    // MARK: - Workspace people and agents

    public func listMembers(workspaceId: String) async throws -> [WorkspaceMember] {
        try await request(
            "GET",
            path: "api/workspaces/\(workspaceId)/members",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func createMember(workspaceId: String, email: String, role: String) async throws -> Invitation {
        try await request(
            "POST",
            path: "api/workspaces/\(workspaceId)/members",
            queryItems: workspaceQuery(workspaceId),
            body: CreateMemberRequest(email: email, role: role)
        )
    }

    public func updateMember(workspaceId: String, memberId: String, role: String) async throws -> WorkspaceMember {
        try await request(
            "PATCH",
            path: "api/workspaces/\(workspaceId)/members/\(memberId)",
            queryItems: workspaceQuery(workspaceId),
            body: UpdateMemberRequest(role: role)
        )
    }

    public func deleteMember(workspaceId: String, memberId: String) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/workspaces/\(workspaceId)/members/\(memberId)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func listWorkspaceInvitations(workspaceId: String) async throws -> [Invitation] {
        try await request(
            "GET",
            path: "api/workspaces/\(workspaceId)/invitations",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func revokeInvitation(workspaceId: String, invitationId: String) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/workspaces/\(workspaceId)/invitations/\(invitationId)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    private struct AgentMutationRequest: Encodable {
        let name: String
        let description: String
        let instructions: String
        let runtimeId: String?
        let visibility: String
        let maxConcurrentTasks: Int
        let model: String
        let avatarUrl: String?
        let customEnv: [String: String]?
        let customArgs: [String]?

        enum CodingKeys: String, CodingKey {
            case name, description, instructions, visibility, model
            case runtimeId = "runtime_id"
            case maxConcurrentTasks = "max_concurrent_tasks"
            case avatarUrl = "avatar_url"
            case customEnv = "custom_env"
            case customArgs = "custom_args"
        }
    }

    private struct AgentAvatarUpdateRequest: Encodable {
        let avatarUrl: String

        enum CodingKeys: String, CodingKey {
            case avatarUrl = "avatar_url"
        }
    }

    private struct ListSquadsResponse: Decodable {
        let squads: [Squad]

        enum CodingKeys: String, CodingKey {
            case squads
        }

        init(from decoder: Decoder) throws {
            if let array = try? [Squad](from: decoder) {
                squads = array
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            squads = try container.decodeIfPresent([Squad].self, forKey: .squads) ?? []
        }
    }

    public func listAgents(workspaceId: String, includeArchived: Bool = false) async throws -> [Agent] {
        var queryItems = workspaceQuery(workspaceId)
        if includeArchived {
            queryItems.append(.init(name: "include_archived", value: "true"))
        }
        return try await request("GET", path: "api/agents", queryItems: queryItems)
    }

    public func listSquads(workspaceId: String, includeArchived: Bool = false) async throws -> [Squad] {
        var queryItems = workspaceQuery(workspaceId)
        if includeArchived {
            queryItems.append(.init(name: "include_archived", value: "true"))
        }
        let response: ListSquadsResponse = try await request("GET", path: "api/squads", queryItems: queryItems)
        return response.squads
    }

    public func getSquad(id: String, workspaceId: String? = nil) async throws -> Squad {
        try await request("GET", path: "api/squads/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func createSquad(
        name: String,
        description: String? = nil,
        leaderId: String,
        avatarUrl: String? = nil,
        workspaceId: String? = nil
    ) async throws -> Squad {
        try await request(
            "POST",
            path: "api/squads",
            queryItems: workspaceQuery(workspaceId),
            body: CreateSquadRequest(
                name: name,
                description: description,
                leaderId: leaderId,
                avatarUrl: avatarUrl
            )
        )
    }

    public func updateSquad(
        id: String,
        name: String? = nil,
        description: String? = nil,
        instructions: String? = nil,
        leaderId: String? = nil,
        avatarUrl: String? = nil,
        workspaceId: String? = nil
    ) async throws -> Squad {
        try await request(
            "PUT",
            path: "api/squads/\(id)",
            queryItems: workspaceQuery(workspaceId),
            body: UpdateSquadRequest(
                name: name,
                description: description,
                instructions: instructions,
                leaderId: leaderId,
                avatarUrl: avatarUrl
            )
        )
    }

    public func deleteSquad(id: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request("DELETE", path: "api/squads/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    /// Adds a member (agent or workspace member) to a squad. Mirrors the web
    /// CreateSquadModal which posts each selected member after the squad is
    /// created. `memberType` is "agent" or "member"; for agents `memberId` is
    /// the agent id, for members it is the user id.
    @discardableResult
    public func addSquadMember(
        squadId: String,
        memberType: String,
        memberId: String,
        role: String? = nil,
        workspaceId: String? = nil
    ) async throws -> SquadMember {
        try await request(
            "POST",
            path: "api/squads/\(squadId)/members",
            queryItems: workspaceQuery(workspaceId),
            body: SquadMemberMutationRequest(memberType: memberType, memberId: memberId, role: role)
        )
    }

    public func listSquadMembers(squadId: String, workspaceId: String? = nil) async throws -> [SquadMember] {
        try await request("GET", path: "api/squads/\(squadId)/members", queryItems: workspaceQuery(workspaceId))
    }

    public func removeSquadMember(
        squadId: String,
        memberType: String,
        memberId: String,
        workspaceId: String? = nil
    ) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/squads/\(squadId)/members",
            queryItems: workspaceQuery(workspaceId),
            body: SquadMemberMutationRequest(memberType: memberType, memberId: memberId, role: nil)
        )
    }

    /// Updates a member's per-squad role/description. The web surfaces this
    /// `role` string as a free-text description line on the squad detail page.
    @discardableResult
    public func updateSquadMemberRole(
        squadId: String,
        memberType: String,
        memberId: String,
        role: String,
        workspaceId: String? = nil
    ) async throws -> SquadMember {
        try await request(
            "PATCH",
            path: "api/squads/\(squadId)/members/role",
            queryItems: workspaceQuery(workspaceId),
            body: SquadMemberMutationRequest(memberType: memberType, memberId: memberId, role: role)
        )
    }

    public func getAgent(id: String, workspaceId: String? = nil) async throws -> Agent {
        try await request("GET", path: "api/agents/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func createAgent(
        name: String,
        description: String,
        instructions: String,
        runtimeId: String,
        visibility: String,
        maxConcurrentTasks: Int,
        model: String,
        avatarUrl: String? = nil,
        customEnv: [String: String]? = nil,
        customArgs: [String]? = nil,
        workspaceId: String? = nil
    ) async throws -> Agent {
        try await request(
            "POST",
            path: "api/agents",
            queryItems: workspaceQuery(workspaceId),
            body: AgentMutationRequest(
                name: name,
                description: description,
                instructions: instructions,
                runtimeId: runtimeId,
                visibility: visibility,
                maxConcurrentTasks: maxConcurrentTasks,
                model: model,
                avatarUrl: avatarUrl,
                customEnv: customEnv,
                customArgs: customArgs
            )
        )
    }

    public func updateAgent(
        id: String,
        name: String,
        description: String,
        instructions: String,
        runtimeId: String? = nil,
        visibility: String,
        maxConcurrentTasks: Int,
        model: String,
        avatarUrl: String? = nil,
        customEnv: [String: String]? = nil,
        customArgs: [String]? = nil,
        workspaceId: String? = nil
    ) async throws -> Agent {
        try await request(
            "PUT",
            path: "api/agents/\(id)",
            queryItems: workspaceQuery(workspaceId),
            body: AgentMutationRequest(
                name: name,
                description: description,
                instructions: instructions,
                runtimeId: runtimeId,
                visibility: visibility,
                maxConcurrentTasks: maxConcurrentTasks,
                model: model,
                avatarUrl: avatarUrl,
                customEnv: customEnv,
                customArgs: customArgs
            )
        )
    }

    public func updateAgentAvatar(id: String, avatarUrl: String, workspaceId: String? = nil) async throws -> Agent {
        try await request(
            "PUT",
            path: "api/agents/\(id)",
            queryItems: workspaceQuery(workspaceId),
            body: AgentAvatarUpdateRequest(avatarUrl: avatarUrl)
        )
    }

    public func archiveAgent(id: String, workspaceId: String? = nil) async throws -> Agent {
        try await request("POST", path: "api/agents/\(id)/archive", queryItems: workspaceQuery(workspaceId))
    }

    public func restoreAgent(id: String, workspaceId: String? = nil) async throws -> Agent {
        try await request("POST", path: "api/agents/\(id)/restore", queryItems: workspaceQuery(workspaceId))
    }

    public func cancelAgentTasks(id: String, workspaceId: String? = nil) async throws -> AgentCancelResponse {
        try await request("POST", path: "api/agents/\(id)/cancel-tasks", queryItems: workspaceQuery(workspaceId))
    }

    public func listAgentTasks(agentId: String, workspaceId: String? = nil) async throws -> [AgentTask] {
        try await request("GET", path: "api/agents/\(agentId)/tasks", queryItems: workspaceQuery(workspaceId))
    }

    public func getAgentTaskSnapshot(workspaceId: String? = nil) async throws -> [AgentTask] {
        try await request("GET", path: "api/agent-task-snapshot", queryItems: workspaceQuery(workspaceId))
    }

    public func getWorkspaceAgentActivity30d(workspaceId: String? = nil) async throws -> [AgentActivityBucket] {
        try await request("GET", path: "api/agent-activity-30d", queryItems: workspaceQuery(workspaceId))
    }

    public func getWorkspaceAgentRunCounts(workspaceId: String? = nil) async throws -> [AgentRunCount] {
        try await request("GET", path: "api/agent-run-counts", queryItems: workspaceQuery(workspaceId))
    }

    public func listRuntimes(workspaceId: String) async throws -> [AgentRuntime] {
        try await request("GET", path: "api/runtimes", queryItems: workspaceQuery(workspaceId))
    }

    public func getRuntimeUsage(id: String, workspaceId: String? = nil, days: Int = 30) async throws -> [RuntimeUsage] {
        try await request(
            "GET",
            path: "api/runtimes/\(id)/usage",
            queryItems: [.init(name: "days", value: String(days))] + workspaceQuery(workspaceId)
        )
    }

    public func getRuntimeTaskActivity(id: String, workspaceId: String? = nil) async throws -> [RuntimeHourlyActivity] {
        try await request(
            "GET",
            path: "api/runtimes/\(id)/activity",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func getRuntimeUsageByAgent(id: String, workspaceId: String? = nil, days: Int = 30) async throws -> [RuntimeUsageByAgent] {
        try await request(
            "GET",
            path: "api/runtimes/\(id)/usage/by-agent",
            queryItems: [.init(name: "days", value: String(days))] + workspaceQuery(workspaceId)
        )
    }

    public func getRuntimeUsageByHour(id: String, workspaceId: String? = nil, days: Int = 30) async throws -> [RuntimeUsageByHour] {
        try await request(
            "GET",
            path: "api/runtimes/\(id)/usage/by-hour",
            queryItems: [.init(name: "days", value: String(days))] + workspaceQuery(workspaceId)
        )
    }

    public func initiateRuntimeUpdate(id: String, targetVersion: String, workspaceId: String? = nil) async throws -> RuntimeUpdate {
        try await request(
            "POST",
            path: "api/runtimes/\(id)/update",
            queryItems: workspaceQuery(workspaceId),
            body: RuntimeUpdateRequest(targetVersion: targetVersion)
        )
    }

    public func getRuntimeUpdateResult(id: String, updateId: String, workspaceId: String? = nil) async throws -> RuntimeUpdate {
        try await request(
            "GET",
            path: "api/runtimes/\(id)/update/\(updateId)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func initiateListRuntimeModels(id: String, workspaceId: String? = nil) async throws -> RuntimeModelListRequest {
        try await request(
            "POST",
            path: "api/runtimes/\(id)/models",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func getRuntimeModelListResult(id: String, requestId: String, workspaceId: String? = nil) async throws -> RuntimeModelListRequest {
        try await request(
            "GET",
            path: "api/runtimes/\(id)/models/\(requestId)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func initiateListRuntimeLocalSkills(id: String, workspaceId: String? = nil) async throws -> RuntimeLocalSkillListRequest {
        try await request(
            "POST",
            path: "api/runtimes/\(id)/local-skills",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func getRuntimeLocalSkillListResult(id: String, requestId: String, workspaceId: String? = nil) async throws -> RuntimeLocalSkillListRequest {
        try await request(
            "GET",
            path: "api/runtimes/\(id)/local-skills/\(requestId)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func initiateImportRuntimeLocalSkill(
        id: String,
        skillKey: String,
        name: String?,
        description: String?,
        workspaceId: String? = nil
    ) async throws -> RuntimeLocalSkillImportRequest {
        try await request(
            "POST",
            path: "api/runtimes/\(id)/local-skills/import",
            queryItems: workspaceQuery(workspaceId),
            body: RuntimeLocalSkillImportRequestBody(skillKey: skillKey, name: name, description: description)
        )
    }

    public func getRuntimeLocalSkillImportResult(id: String, requestId: String, workspaceId: String? = nil) async throws -> RuntimeLocalSkillImportRequest {
        try await request(
            "GET",
            path: "api/runtimes/\(id)/local-skills/import/\(requestId)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func deleteRuntime(id: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request("DELETE", path: "api/runtimes/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    // MARK: - Skills

    public func listSkills(workspaceId: String? = nil) async throws -> [Skill] {
        try await request("GET", path: "api/skills", queryItems: workspaceQuery(workspaceId))
    }

    public func getSkill(id: String, workspaceId: String? = nil) async throws -> Skill {
        try await request("GET", path: "api/skills/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func createSkill(name: String, description: String, content: String, workspaceId: String? = nil) async throws -> Skill {
        try await request(
            "POST",
            path: "api/skills",
            queryItems: workspaceQuery(workspaceId),
            body: SkillMutationRequest(name: name, description: description, content: content)
        )
    }

    public func updateSkill(id: String, name: String, description: String, content: String, workspaceId: String? = nil) async throws -> Skill {
        try await request(
            "PUT",
            path: "api/skills/\(id)",
            queryItems: workspaceQuery(workspaceId),
            body: SkillMutationRequest(name: name, description: description, content: content)
        )
    }

    public func importSkill(url: String, workspaceId: String? = nil) async throws -> Skill {
        try await request(
            "POST",
            path: "api/skills/import",
            queryItems: workspaceQuery(workspaceId),
            body: SkillImportRequest(url: url)
        )
    }

    public func deleteSkill(id: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request("DELETE", path: "api/skills/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func listAgentSkills(agentId: String, workspaceId: String? = nil) async throws -> [Skill] {
        try await request("GET", path: "api/agents/\(agentId)/skills", queryItems: workspaceQuery(workspaceId))
    }

    public func setAgentSkills(agentId: String, skillIds: [String], workspaceId: String? = nil) async throws {
        let sortedSkillIds = skillIds.sorted()
        let _: EmptyResponse = try await request(
            "PUT",
            path: "api/agents/\(agentId)/skills",
            queryItems: workspaceQuery(workspaceId),
            body: SetAgentSkillsRequest(skillIds: sortedSkillIds)
        )
    }

    // MARK: - Autopilots

    public func listAutopilots(status: String? = nil, workspaceId: String? = nil) async throws -> ListAutopilotsResponse {
        var queryItems = workspaceQuery(workspaceId)
        if let status, !status.isEmpty {
            queryItems.append(.init(name: "status", value: status))
        }
        return try await request("GET", path: "api/autopilots", queryItems: queryItems)
    }

    public func getAutopilot(id: String, workspaceId: String? = nil) async throws -> GetAutopilotResponse {
        try await request("GET", path: "api/autopilots/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func createAutopilot(
        title: String,
        description: String?,
        assigneeId: String,
        executionMode: String,
        issueTitleTemplate: String?,
        workspaceId: String? = nil
    ) async throws -> Autopilot {
        try await request(
            "POST",
            path: "api/autopilots",
            queryItems: workspaceQuery(workspaceId),
            body: CreateAutopilotRequest(
                title: title,
                description: description,
                assigneeId: assigneeId,
                executionMode: executionMode,
                issueTitleTemplate: issueTitleTemplate
            )
        )
    }

    public func updateAutopilot(
        id: String,
        title: String,
        description: String?,
        assigneeId: String,
        status: String,
        executionMode: String,
        issueTitleTemplate: String?,
        workspaceId: String? = nil
    ) async throws -> Autopilot {
        try await request(
            "PATCH",
            path: "api/autopilots/\(id)",
            queryItems: workspaceQuery(workspaceId),
            body: UpdateAutopilotRequest(
                title: title,
                description: description,
                assigneeId: assigneeId,
                status: status,
                executionMode: executionMode,
                issueTitleTemplate: issueTitleTemplate
            )
        )
    }

    public func deleteAutopilot(id: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request("DELETE", path: "api/autopilots/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func triggerAutopilot(id: String, workspaceId: String? = nil) async throws -> AutopilotRun {
        try await request("POST", path: "api/autopilots/\(id)/trigger", queryItems: workspaceQuery(workspaceId))
    }

    public func listAutopilotRuns(id: String, workspaceId: String? = nil, limit: Int = 50, offset: Int = 0) async throws -> ListAutopilotRunsResponse {
        try await request("GET", path: "api/autopilots/\(id)/runs", queryItems: workspaceQuery(workspaceId) + [
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ])
    }

    public func createAutopilotTrigger(
        autopilotId: String,
        kind: String,
        cronExpression: String?,
        timezone: String?,
        label: String?,
        workspaceId: String? = nil
    ) async throws -> AutopilotTrigger {
        try await request(
            "POST",
            path: "api/autopilots/\(autopilotId)/triggers",
            queryItems: workspaceQuery(workspaceId),
            body: CreateAutopilotTriggerRequest(
                kind: kind,
                cronExpression: cronExpression,
                timezone: timezone,
                label: label
            )
        )
    }

    public func updateAutopilotTrigger(
        autopilotId: String,
        triggerId: String,
        enabled: Bool?,
        cronExpression: String?,
        timezone: String?,
        label: String?,
        workspaceId: String? = nil
    ) async throws -> AutopilotTrigger {
        try await request(
            "PATCH",
            path: "api/autopilots/\(autopilotId)/triggers/\(triggerId)",
            queryItems: workspaceQuery(workspaceId),
            body: UpdateAutopilotTriggerRequest(
                enabled: enabled,
                cronExpression: cronExpression,
                timezone: timezone,
                label: label
            )
        )
    }

    public func deleteAutopilotTrigger(autopilotId: String, triggerId: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/autopilots/\(autopilotId)/triggers/\(triggerId)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    // MARK: - Chat

    public func listChatSessions(status: String? = nil, workspaceId: String? = nil) async throws -> [ChatSession] {
        var queryItems = workspaceQuery(workspaceId)
        if let status, !status.isEmpty {
            queryItems.append(.init(name: "status", value: status))
        }
        return try await request("GET", path: "api/chat/sessions", queryItems: queryItems)
    }

    public func getChatSession(id: String, workspaceId: String? = nil) async throws -> ChatSession {
        try await request("GET", path: "api/chat/sessions/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func createChatSession(agentId: String, title: String? = nil, workspaceId: String? = nil) async throws -> ChatSession {
        try await request(
            "POST",
            path: "api/chat/sessions",
            queryItems: workspaceQuery(workspaceId),
            body: CreateChatSessionRequest(agentId: agentId, title: title)
        )
    }

    public func archiveChatSession(id: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/chat/sessions/\(id)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func listChatMessages(sessionId: String, workspaceId: String? = nil) async throws -> [ChatMessage] {
        try await request(
            "GET",
            path: "api/chat/sessions/\(sessionId)/messages",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func sendChatMessage(
        sessionId: String,
        content: String,
        attachmentIds: [String] = [],
        workspaceId: String? = nil
    ) async throws -> SendChatMessageResponse {
        try await request(
            "POST",
            path: "api/chat/sessions/\(sessionId)/messages",
            queryItems: workspaceQuery(workspaceId),
            body: SendChatMessageRequest(content: content, attachmentIds: attachmentIds.isEmpty ? nil : attachmentIds)
        )
    }

    public func getPendingChatTask(sessionId: String, workspaceId: String? = nil) async throws -> ChatPendingTask {
        try await request(
            "GET",
            path: "api/chat/sessions/\(sessionId)/pending-task",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func listPendingChatTasks(workspaceId: String? = nil) async throws -> PendingChatTasksResponse {
        try await request("GET", path: "api/chat/pending-tasks", queryItems: workspaceQuery(workspaceId))
    }

    public func markChatSessionRead(sessionId: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request(
            "POST",
            path: "api/chat/sessions/\(sessionId)/read",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func cancelTaskById(taskId: String, workspaceId: String? = nil) async throws {
        let _: EmptyResponse = try await request(
            "POST",
            path: "api/tasks/\(taskId)/cancel",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    // MARK: - Personal Access Tokens

    public func listPersonalAccessTokens() async throws -> [PersonalAccessToken] {
        try await request("GET", path: "api/tokens")
    }

    public func createPersonalAccessToken(name: String, expiresInDays: Int?) async throws -> CreatedPersonalAccessToken {
        try await request(
            "POST",
            path: "api/tokens",
            body: CreatePersonalAccessTokenRequest(name: name, expiresInDays: expiresInDays)
        )
    }

    public func revokePersonalAccessToken(id: String) async throws {
        let _: EmptyResponse = try await request("DELETE", path: "api/tokens/\(id)")
    }

    // MARK: - Notification Preferences

    public func getNotificationPreferences(workspaceId: String? = nil) async throws -> NotificationPreferenceResponse {
        try await request(
            "GET",
            path: "api/notification-preferences",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func updateNotificationPreferences(
        _ preferences: NotificationPreferences,
        workspaceId: String? = nil
    ) async throws -> NotificationPreferenceResponse {
        try await request(
            "PUT",
            path: "api/notification-preferences",
            queryItems: workspaceQuery(workspaceId),
            body: UpdateNotificationPreferencesRequest(preferences: preferences)
        )
    }

    // MARK: - Feedback

    public func createFeedback(message: String, url: String? = nil, workspaceId: String) async throws -> FeedbackResponse {
        try await request(
            "POST",
            path: "api/feedback",
            queryItems: workspaceQuery(workspaceId),
            body: CreateFeedbackRequest(message: message, url: url, workspaceId: workspaceId)
        )
    }

    // MARK: - Inbox

    public func listInbox(
        workspaceId: String? = nil,
        workspaceSlug: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) async throws -> PageResponse<InboxItem> {
        var queryItems = workspaceQuery(workspaceId)
        if let limit {
            queryItems.append(.init(name: "limit", value: "\(limit)"))
        }
        if let offset {
            queryItems.append(.init(name: "offset", value: "\(offset)"))
        }
        return try await request(
            "GET",
            path: "api/inbox",
            queryItems: queryItems,
            headers: workspaceHeaders(workspaceSlug)
        )
    }

    public func markInboxRead(id: String, workspaceId: String? = nil, workspaceSlug: String? = nil) async throws -> InboxItem {
        try await request(
            "POST",
            path: "api/inbox/\(id)/read",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug)
        )
    }

    public func archiveInbox(id: String, workspaceId: String? = nil, workspaceSlug: String? = nil) async throws -> InboxItem {
        try await request(
            "POST",
            path: "api/inbox/\(id)/archive",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug)
        )
    }

    public func getUnreadInboxCount(workspaceId: String? = nil, workspaceSlug: String? = nil) async throws -> CountResponse {
        try await request(
            "GET",
            path: "api/inbox/unread-count",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug)
        )
    }

    public func markAllInboxRead(workspaceId: String? = nil, workspaceSlug: String? = nil) async throws -> CountResponse {
        try await request(
            "POST",
            path: "api/inbox/mark-all-read",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug)
        )
    }

    public func archiveAllInbox(workspaceId: String? = nil, workspaceSlug: String? = nil) async throws -> CountResponse {
        try await request(
            "POST",
            path: "api/inbox/archive-all",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug)
        )
    }

    public func archiveAllReadInbox(workspaceId: String? = nil, workspaceSlug: String? = nil) async throws -> CountResponse {
        try await request(
            "POST",
            path: "api/inbox/archive-all-read",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug)
        )
    }

    public func archiveCompletedInbox(workspaceId: String? = nil, workspaceSlug: String? = nil) async throws -> CountResponse {
        try await request(
            "POST",
            path: "api/inbox/archive-completed",
            queryItems: workspaceQuery(workspaceId),
            headers: workspaceHeaders(workspaceSlug)
        )
    }

    // MARK: - Projects

    public func listProjects(workspaceId: String, limit: Int = 50, offset: Int = 0) async throws -> PageResponse<Project> {
        let page: PageResponse<Project> = try await request("GET", path: "api/projects", queryItems: [
            .init(name: "workspace_id", value: workspaceId),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ])
        return page.inferringHasMore(fromOffset: offset)
    }

    public func searchProjects(
        workspaceId: String,
        query: String,
        limit: Int = 50,
        offset: Int = 0,
        includeClosed: Bool = false
    ) async throws -> PageResponse<Project> {
        var queryItems: [URLQueryItem] = [
            .init(name: "q", value: query),
            .init(name: "workspace_id", value: workspaceId),
            .init(name: "limit", value: "\(limit)"),
            .init(name: "offset", value: "\(offset)"),
        ]
        if includeClosed {
            queryItems.append(.init(name: "include_closed", value: "true"))
        }
        let page: PageResponse<Project> = try await request("GET", path: "api/projects/search", queryItems: queryItems)
        return page.inferringHasMore(fromOffset: offset)
    }

    public func getProject(id: String, workspaceId: String? = nil) async throws -> Project {
        try await request("GET", path: "api/projects/\(id)", queryItems: workspaceQuery(workspaceId))
    }

    public func createProject(
        title: String,
        description: String?,
        workspaceId: String,
        status: ProjectStatus,
        priority: IssuePriority,
        icon: String? = nil,
        leadType: String? = nil,
        leadId: String? = nil,
        resourceURLs: [String] = []
    ) async throws -> Project {
        try await request(
            "POST",
            path: "api/projects",
            queryItems: workspaceQuery(workspaceId),
            body: CreateProjectRequest(
                title: title,
                description: description,
                status: status,
                priority: priority,
                icon: icon,
                leadType: leadType,
                leadId: leadId,
                resources: projectResourceRequests(from: resourceURLs)
            )
        )
    }

    public func updateProject(
        id: String,
        workspaceId: String,
        title: String,
        description: String?,
        status: ProjectStatus,
        priority: IssuePriority,
        icon: String? = nil,
        leadType: String? = nil,
        leadId: String? = nil
    ) async throws -> Project {
        try await request(
            "PUT",
            path: "api/projects/\(id)",
            queryItems: workspaceQuery(workspaceId),
            body: UpdateProjectRequest(
                title: title,
                description: description,
                status: status,
                priority: priority,
                icon: icon,
                leadType: leadType,
                leadId: leadId
            )
        )
    }

    public func deleteProject(id: String, workspaceId: String) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/projects/\(id)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    public func listProjectResources(projectId: String, workspaceId: String? = nil) async throws -> PageResponse<ProjectResource> {
        try await request("GET", path: "api/projects/\(projectId)/resources", queryItems: workspaceQuery(workspaceId))
    }

    public func createProjectResource(
        projectId: String,
        workspaceId: String,
        resourceType: String,
        resourceRef: [String: JSONValue],
        label: String? = nil,
        position: Int? = nil
    ) async throws -> ProjectResource {
        try await request(
            "POST",
            path: "api/projects/\(projectId)/resources",
            queryItems: workspaceQuery(workspaceId),
            body: CreateProjectResourceRequest(
                resourceType: resourceType,
                resourceRef: resourceRef,
                label: label,
                position: position
            )
        )
    }

    public func deleteProjectResource(projectId: String, resourceId: String, workspaceId: String) async throws {
        let _: EmptyResponse = try await request(
            "DELETE",
            path: "api/projects/\(projectId)/resources/\(resourceId)",
            queryItems: workspaceQuery(workspaceId)
        )
    }

    private func projectResourceRequests(from urls: [String]) -> [CreateProjectResourceRequest]? {
        let resources = urls
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map {
                CreateProjectResourceRequest(
                    resourceType: "github_repo",
                    resourceRef: ["url": .string($0)],
                    label: nil,
                    position: nil
                )
            }
        return resources.isEmpty ? nil : resources
    }

    private func workspaceQuery(_ workspaceId: String?) -> [URLQueryItem] {
        guard let workspaceId, !workspaceId.isEmpty else { return [] }
        return [.init(name: "workspace_id", value: workspaceId)]
    }

    private func workspaceHeaders(_ workspaceSlug: String?) -> [String: String] {
        guard let workspaceSlug, !workspaceSlug.isEmpty else { return [:] }
        return ["X-Workspace-Slug": workspaceSlug]
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

// MARK: - Localized error messages

extension APIClient.APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "You're signed out. Please sign in again."
        case .notFound:
            return "The requested resource was not found."
        case .missingWorkspace:
            return "Pick a workspace before loading this data."
        case .serverError(let status, let body):
            if let decoded = Self.decodeBackendMessage(body) {
                return decoded
            }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Server error (\(status)). Please try again."
            }
            let preview = trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
            return "Server error (\(status)): \(preview)"
        case .decodingError(let underlying, let body):
            let preview = body.count > 300 ? String(body.prefix(300)) + "…" : body
            let detail = Self.decodingErrorPath(underlying)
            return "Couldn't parse server response\(detail). Raw: \(preview)"
        case .networkError(let error):
            return "Network problem: \(error.localizedDescription)"
        case .timeout:
            return "The server took too long to respond. Please try again."
        }
    }

    private static func decodeBackendMessage(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let s = obj["error"] as? String, !s.isEmpty { return s }
        if let s = obj["message"] as? String, !s.isEmpty { return s }
        return nil
    }

    /// Pull the failing JSON key path out of a Swift `DecodingError` so the
    /// error message points at the exact field that didn't match, e.g.
    /// " (missing key 'name' at user)" or " (type mismatch at workspaces[0].slug)".
    private static func decodingErrorPath(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return "" }
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decodingError {
        case .keyNotFound(let key, let ctx):
            let loc = path(ctx); return " (missing key '\(key.stringValue)'\(loc.isEmpty ? "" : " at \(loc)"))"
        case .typeMismatch(_, let ctx):
            return " (type mismatch at \(path(ctx)))"
        case .valueNotFound(_, let ctx):
            return " (null value at \(path(ctx)))"
        case .dataCorrupted(let ctx):
            let loc = path(ctx); return loc.isEmpty ? " (corrupted body)" : " (corrupted at \(loc))"
        @unknown default:
            return ""
        }
    }
}
