import XCTest
@testable import MultiCasual

// URLProtocol stub for intercepting requests without a real server
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func bodyData(for request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead <= 0 { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@MainActor
final class APIClientTests: XCTestCase {
    var client: APIClient!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        client = APIClient(session: session, token: "test-token")
    }

    func test_defaultRequestTimeoutAllowsSlowWorkspaceResponses() {
        XCTAssertGreaterThanOrEqual(APIClient.defaultRequestTimeout, 45)
    }

    func test_getMe_decodesUser() async throws {
        let json = """
        {"id":"u1","email":"test@example.com","name":"Test User","avatar_url":null}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let user = try await client.getMe()
        XCTAssertEqual(user.id, "u1")
        XCTAssertEqual(user.email, "test@example.com")
    }

    func test_clientUsesInjectedBaseURLForSelfHostedEnvironment() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        var capturedURL: URL?

        MockURLProtocol.handler = { req in
            capturedURL = req.url
            return Self.response(
                req,
                body: #"{"id":"u1","email":"p@xiaomi.com","name":"Parker"}"#.data(using: .utf8)!
            )
        }

        let client = APIClient(
            session: session,
            baseURL: AppEnvironment.xiaomi.apiBaseURL,
            token: "test-token"
        )

        _ = try await client.getMe()

        XCTAssertEqual(capturedURL?.scheme, "http")
        XCTAssertEqual(capturedURL?.host, "staging-multica.ad.xiaomi.srv")
        XCTAssertEqual(capturedURL?.path, "/api/me")
    }

    func test_updateMe_usesDesktopEndpointAndBody() async throws {
        var body: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "PATCH")
            XCTAssertEqual(req.url?.path, "/api/me")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            let response = """
            {"id":"u1","email":"p@example.com","name":"Parker Updated","avatar_url":"https://cdn.example/avatar.png"}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }

        let user = try await client.updateMe(name: "Parker Updated", avatarUrl: "https://cdn.example/avatar.png")

        XCTAssertEqual(body["name"] as? String, "Parker Updated")
        XCTAssertEqual(body["avatar_url"] as? String, "https://cdn.example/avatar.png")
        XCTAssertEqual(user.name, "Parker Updated")
        XCTAssertEqual(user.avatarUrl, "https://cdn.example/avatar.png")
    }

    func test_userScopedUtilityEndpointsMatchDesktopPaths() async throws {
        var requests: [(method: String?, path: String, query: String?)] = []
        MockURLProtocol.handler = { req in
            requests.append((req.httpMethod, req.url?.path ?? "", req.url?.query))
            let body: Data
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/auth/logout"):
                body = Data()
            case ("POST", "/api/cli-token"):
                body = #"{"token":"cli-token"}"#.data(using: .utf8)!
            case ("GET", "/api/config"):
                body = """
                {"cdn_domain":"cdn.multica.ai","allow_signup":true,"google_client_id":"google","posthog_key":"ph","posthog_host":"https://ph.example"}
                """.data(using: .utf8)!
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                body = Data("{}".utf8)
            }
            let status = req.url?.path == "/auth/logout" ? 204 : 200
            return (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }

        try await client.logout()
        let token = try await client.issueCliToken()
        let config = try await client.getConfig()

        XCTAssertEqual(requests.map { "\($0.method ?? "") \($0.path)" }, [
            "POST /auth/logout",
            "POST /api/cli-token",
            "GET /api/config",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.query == nil })
        XCTAssertEqual(token.token, "cli-token")
        XCTAssertEqual(config.cdnDomain, "cdn.multica.ai")
        XCTAssertTrue(config.allowSignup)
        XCTAssertEqual(config.googleClientId, "google")
        XCTAssertEqual(config.posthogKey, "ph")
        XCTAssertEqual(config.posthogHost, "https://ph.example")
    }

    func test_getMe_sendsDesktopStyleClientHeaders() async throws {
        let json = """
        {"id":"u1","email":"test@example.com","name":"Test User","avatar_url":null}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNotNil(req.value(forHTTPHeaderField: "X-Request-ID"))
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Client-Platform"), "ios")
            XCTAssertNotNil(req.value(forHTTPHeaderField: "X-Client-Version"))
            XCTAssertNotNil(req.value(forHTTPHeaderField: "X-Client-OS"))
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.getMe()
    }

    func test_requestTimeout_surfacesLocalizedAPIError() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        client = APIClient(session: session, requestTimeout: 0.01, token: "test-token")
        MockURLProtocol.handler = { req in
            Thread.sleep(forTimeInterval: 0.2)
            let json = """
            {"id":"u1","email":"test@example.com","name":"Test User","avatar_url":null}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        do {
            _ = try await client.getMe()
            XCTFail("Expected timeout")
        } catch APIClient.APIError.timeout {
            XCTAssertEqual(APIClient.APIError.timeout.localizedDescription, "The server took too long to respond. Please try again.")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_unauthorized_throwsAuthError() async {
        MockURLProtocol.handler = { req in
            return (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await client.getMe()
            XCTFail("Expected error")
        } catch APIClient.APIError.unauthorized {
            // pass
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_listIssues_sendsWorkspaceIdParam() async throws {
        let json = """
        {"issues":[],"has_more":false,"total":0}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        _ = try await client.listIssues(workspaceId: "ws1", limit: 50, offset: 0)
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=ws1") ?? false)
        XCTAssertTrue(capturedURL?.absoluteString.contains("limit=50") ?? false)
    }

    func test_listIssues_sendsStatusParamWhenProvided() async throws {
        let json = """
        {"issues":[],"has_more":false,"total":0}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.listIssues(workspaceId: "ws1", status: .inProgress, limit: 50, offset: 0)

        XCTAssertTrue(capturedURL?.absoluteString.contains("status=in_progress") ?? false)
    }

    func test_listIssues_sendsProjectIdParamWhenProvided() async throws {
        let json = """
        {"issues":[],"has_more":false,"total":0}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.listIssues(workspaceId: "ws1", projectId: "p1", limit: 50, offset: 0)

        XCTAssertTrue(capturedURL?.absoluteString.contains("project_id=p1") ?? false)
    }

    func test_listIssues_sendsPriorityParamWhenProvided() async throws {
        let json = """
        {"issues":[],"has_more":false,"total":0}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.listIssues(workspaceId: "ws1", priority: .urgent, limit: 50, offset: 0)

        XCTAssertTrue(capturedURL?.absoluteString.contains("priority=urgent") ?? false)
    }

    func test_listIssues_sendsMyIssuesFilterParamsWhenProvided() async throws {
        let json = """
        {"issues":[],"has_more":false,"total":0}
        """.data(using: .utf8)!
        var capturedQueries: [[URLQueryItem]] = []
        MockURLProtocol.handler = { req in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            capturedQueries.append(components?.queryItems ?? [])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.listIssues(workspaceId: "ws1", assigneeId: "u1", limit: 50, offset: 0)
        _ = try await client.listIssues(workspaceId: "ws1", assigneeIds: ["a2", "a1"], limit: 50, offset: 0)
        _ = try await client.listIssues(workspaceId: "ws1", creatorId: "u1", limit: 50, offset: 0)

        XCTAssertEqual(capturedQueries[0].first(where: { $0.name == "assignee_id" })?.value, "u1")
        XCTAssertEqual(capturedQueries[1].first(where: { $0.name == "assignee_ids" })?.value, "a2,a1")
        XCTAssertEqual(capturedQueries[2].first(where: { $0.name == "creator_id" })?.value, "u1")
    }

    func test_listIssuesDecodesIssuesWrapperWithoutItemsKey() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/issues")
            let json = """
            {"issues":[{
              "id":"a77e75ff-59d4-4a42-a267-7be40a49141b",
              "workspace_id":"7f97e6b9-2db3-489c-a270-4e4c6d354469",
              "number":206,
              "identifier":"PAR-206",
              "title":"研究一下 motion",
              "description":"动效说是可以用 https://motion.dev/",
              "status":"in_progress",
              "priority":"none",
              "assignee_id":null,
              "assignee_type":null,
              "project_id":null,
              "created_at":"2026-06-05T00:00:00Z",
              "updated_at":"2026-06-05T00:00:00Z"
            }],"has_more":false,"total":1}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let page = try await client.listIssues(workspaceId: "7f97e6b9-2db3-489c-a270-4e4c6d354469")

        XCTAssertEqual(page.items.map(\.identifier), ["PAR-206"])
        XCTAssertEqual(page.items.first?.status, .inProgress)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.total, 1)
    }

    func test_searchIssuesAndProjectsUseDesktopSearchEndpoints() async throws {
        var requests: [(path: String, queryItems: [URLQueryItem])] = []
        MockURLProtocol.handler = { req in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            requests.append((req.url?.path ?? "", components?.queryItems ?? []))
            switch req.url?.path {
            case "/api/issues/search":
                let json = #"{"issues":[],"has_more":false,"total":0}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            case "/api/projects/search":
                let json = #"{"projects":[],"has_more":false,"total":0}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        _ = try await client.searchIssues(workspaceId: "w1", query: "markdown issue", limit: 25, offset: 5, includeClosed: true)
        _ = try await client.searchProjects(workspaceId: "w1", query: "mobile app", limit: 10, offset: 0)

        XCTAssertEqual(requests.map(\.path), ["/api/issues/search", "/api/projects/search"])
        XCTAssertEqual(requests[0].queryItems.first(where: { $0.name == "q" })?.value, "markdown issue")
        XCTAssertEqual(requests[0].queryItems.first(where: { $0.name == "workspace_id" })?.value, "w1")
        XCTAssertEqual(requests[0].queryItems.first(where: { $0.name == "limit" })?.value, "25")
        XCTAssertEqual(requests[0].queryItems.first(where: { $0.name == "offset" })?.value, "5")
        XCTAssertEqual(requests[0].queryItems.first(where: { $0.name == "include_closed" })?.value, "true")
        XCTAssertEqual(requests[1].queryItems.first(where: { $0.name == "q" })?.value, "mobile app")
        XCTAssertEqual(requests[1].queryItems.first(where: { $0.name == "workspace_id" })?.value, "w1")
        XCTAssertEqual(requests[1].queryItems.first(where: { $0.name == "limit" })?.value, "10")
    }

    func test_searchIssuesDecodesIssuesWrapperWithFractionalPosition() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/issues/search")
            let json = """
            {"issues":[{
              "id":"i1","identifier":"PAR-1","number":1,"title":"Search result","description":null,
              "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
              "project_id":null,"workspace_id":"w1","position":-1.5,
              "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"
            }],"has_more":false,"total":1}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let page = try await client.searchIssues(workspaceId: "w1", query: "PAR-1")

        XCTAssertEqual(page.items.map(\.identifier), ["PAR-1"])
        XCTAssertEqual(page.items.first?.position, -1.5)
    }

    func test_quickCreateIssueUsesDesktopEndpointAndBody() async throws {
        var capturedURL: URL?
        var capturedBody: [String: Any]?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            capturedBody = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/issues/quick-create")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            let json = #"{"task_id":"task1"}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json
            )
        }

        let response = try await client.quickCreateIssue(
            agentId: "agent1",
            prompt: "Create an issue from this prompt",
            workspaceId: "w1"
        )

        XCTAssertEqual(response.taskId, "task1")
        XCTAssertEqual(capturedURL?.query, "workspace_id=w1")
        XCTAssertEqual(capturedBody?["agent_id"] as? String, "agent1")
        XCTAssertEqual(capturedBody?["prompt"] as? String, "Create an issue from this prompt")
    }

    func test_getIssue_sendsWorkspaceIdParamWhenProvided() async throws {
        let json = """
        {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
         "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
        "project_id":null,"workspace_id":"w1","position":4,"created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.getIssue(id: "i1", workspaceId: "w1")

        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_configuredClientSendsCurrentWorkspaceSlugHeader() async throws {
        let json = """
        {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
         "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
         "project_id":null,"workspace_id":"w1","position":4,"created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let session = AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.api-client.test"))
        session.currentWorkspace = Workspace(id: "w1", name: "park0er", slug: "park0er", issuePrefix: "PAR")

        client.configure(authSession: session)

        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.getIssue(id: "i1")
    }

    func test_configuredClientInjectsCurrentWorkspaceIdForWorkspaceScopedRequests() async throws {
        let json = """
        {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
         "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
         "project_id":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let session = AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.api-client.inject-workspace.test"))
        session.currentWorkspace = Workspace(id: "w1", name: "park0er", slug: "park0er", issuePrefix: "PAR")

        client.configure(authSession: session)

        MockURLProtocol.handler = { req in
            let components = try XCTUnwrap(URLComponents(url: req.url!, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "workspace_id" })?.value, "w1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.getIssue(id: "i1")
    }

    func test_authSessionInitializerInjectsCurrentWorkspaceScope() async throws {
        let json = """
        {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
         "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
         "project_id":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let session = AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.api-client.init-workspace.test"))
        session.currentWorkspace = Workspace(id: "w1", name: "park0er", slug: "park0er", issuePrefix: "PAR")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let scopedClient = APIClient(session: URLSession(configuration: config), authSession: session)

        MockURLProtocol.handler = { req in
            let components = try XCTUnwrap(URLComponents(url: req.url!, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "workspace_id" })?.value, "w1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await scopedClient.getIssue(id: "i1")
    }

    func test_workspaceScopedRequestWithoutWorkspaceFailsBeforeNetwork() async throws {
        MockURLProtocol.handler = { req in
            XCTFail("Workspace-scoped request should not hit backend without workspace: \(req.url?.absoluteString ?? "")")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                #"{"error":"workspace_id or workspace_slug is required"}"#.data(using: .utf8)!
            )
        }

        do {
            _ = try await client.getIssue(id: "i1")
            XCTFail("Expected missing workspace error")
        } catch APIClient.APIError.missingWorkspace {
            XCTAssertEqual(
                APIClient.APIError.missingWorkspace.localizedDescription,
                "Pick a workspace before loading this data."
            )
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func test_configuredClientInjectsWorkspaceSlugQueryWhenIdIsUnavailable() async throws {
        let json = """
        {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
         "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
         "project_id":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let slugScopedClient = APIClient(
            session: session,
            token: "test-token",
            workspaceSlugProvider: { "park0er" },
            workspaceIdProvider: { nil }
        )

        MockURLProtocol.handler = { req in
            let components = try XCTUnwrap(URLComponents(url: req.url!, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "workspace_slug" })?.value, "park0er")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await slugScopedClient.getIssue(id: "i1")
    }

    func test_configuredClientDoesNotInjectWorkspaceIdForUserScopedRequests() async throws {
        let session = AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.api-client.user-scope.test"))
        session.currentWorkspace = Workspace(id: "w1", name: "park0er", slug: "park0er", issuePrefix: "PAR")

        client.configure(authSession: session)

        MockURLProtocol.handler = { req in
            let components = try XCTUnwrap(URLComponents(url: req.url!, resolvingAgainstBaseURL: false))
            XCTAssertNil(components.queryItems?.first(where: { $0.name == "workspace_id" }))
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                #"{"id":"u1","email":"u@example.com","name":"User","avatar_url":null}"#.data(using: .utf8)!
            )
        }

        _ = try await client.getMe()
    }

    func test_registerPushTokenSendsWorkspaceId() async throws {
        var capturedURL: URL?
        var body: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await client.registerPushToken("apns-token", workspaceId: "w1")

        XCTAssertEqual(capturedURL?.path, "/api/devices/push-token")
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(body["token"] as? String, "apns-token")
        XCTAssertEqual(body["platform"] as? String, "apns")
    }

    func test_registerPushTokenUsesConfiguredWorkspaceWhenNotProvided() async throws {
        let session = AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.api-client.push-workspace.test"))
        session.currentWorkspace = Workspace(id: "w1", name: "park0er", slug: "park0er", issuePrefix: "PAR")
        client.configure(authSession: session)

        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await client.registerPushToken("apns-token")

        XCTAssertEqual(capturedURL?.path, "/api/devices/push-token")
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_getAndUpdateWorkspaceUseDesktopPaths() async throws {
        var requests: [(method: String?, path: String, query: String?, body: [String: Any]?)] = []
        let workspaceJSON = """
        {"id":"w1","name":"Workspace","slug":"workspace","description":"Docs",
         "context":"Use **Markdown**","issue_prefix":"PAR",
         "repos":[{"url":"https://github.com/multica-ai/multica","default_branch_hint":"main"}]}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            let bodyData = MockURLProtocol.bodyData(for: req)
            let body = bodyData.isEmpty ? nil : try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            requests.append((req.httpMethod, req.url?.path ?? "", req.url?.query, body))
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/workspaces/w1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, workspaceJSON)
            case ("PATCH", "/api/workspaces/w1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, workspaceJSON)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let fetched = try await client.getWorkspace(id: "w1", workspaceId: "w1")
        let updated = try await client.updateWorkspace(
            id: "w1",
            workspaceId: "w1",
            name: "Workspace",
            description: "Docs",
            context: "Use **Markdown**",
            repos: [WorkspaceRepo(url: "https://github.com/multica-ai/multica", defaultBranchHint: "main")]
        )

        XCTAssertEqual(fetched.context, "Use **Markdown**")
        XCTAssertEqual(updated.repos.first?.defaultBranchHint, "main")
        XCTAssertEqual(requests.map(\.method), ["GET", "PATCH"])
        XCTAssertEqual(requests.map(\.path), ["/api/workspaces/w1", "/api/workspaces/w1"])
        XCTAssertTrue(requests.allSatisfy { $0.query == "workspace_id=w1" })
        XCTAssertEqual(requests[1].body?["name"] as? String, "Workspace")
        XCTAssertEqual(requests[1].body?["description"] as? String, "Docs")
        XCTAssertEqual(requests[1].body?["context"] as? String, "Use **Markdown**")
        let repos = requests[1].body?["repos"] as? [[String: Any]]
        XCTAssertEqual(repos?.first?["url"] as? String, "https://github.com/multica-ai/multica")
        XCTAssertEqual(repos?.first?["default_branch_hint"] as? String, "main")
    }

    func test_workspaceLifecycleAndMyInvitationEndpointsUseDesktopPaths() async throws {
        var requests: [(method: String?, path: String, query: String?, body: [String: Any]?)] = []
        let workspaceJSON = """
        {"id":"w2","name":"Beta","slug":"beta","description":"D",
         "context":"C","issue_prefix":"BET","repos":[]}
        """.data(using: .utf8)!
        let invitationJSON = """
        {"id":"inv1","workspace_id":"w2","inviter_id":"u1","invitee_email":"me@example.com",
         "invitee_user_id":null,"role":"member","status":"pending",
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
         "expires_at":"2026-02-01T00:00:00Z","workspace_name":"Beta",
         "inviter_name":"Parker","inviter_email":"p@example.com"}
        """.data(using: .utf8)!
        let memberJSON = """
        {"id":"m1","workspace_id":"w2","user_id":"u2","role":"member",
         "created_at":"2026-01-01T00:00:00Z","name":"Me",
         "email":"me@example.com","avatar_url":null}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            let bodyData = MockURLProtocol.bodyData(for: req)
            let body = bodyData.isEmpty ? nil : try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            requests.append((req.httpMethod, req.url?.path ?? "", req.url?.query, body))
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/workspaces"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, workspaceJSON)
            case ("POST", "/api/workspaces/w1/leave"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            case ("DELETE", "/api/workspaces/w1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            case ("GET", "/api/invitations"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, "[\(String(data: invitationJSON, encoding: .utf8)!)]".data(using: .utf8)!)
            case ("GET", "/api/invitations/inv1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, invitationJSON)
            case ("POST", "/api/invitations/inv1/accept"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, memberJSON)
            case ("POST", "/api/invitations/inv1/decline"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let created = try await client.createWorkspace(name: "Beta", slug: "beta", description: "D", context: "C")
        try await client.leaveWorkspace(id: "w1")
        try await client.deleteWorkspace(id: "w1")
        let invitations = try await client.listMyInvitations()
        let invitation = try await client.getInvitation(id: "inv1")
        let member = try await client.acceptInvitation(id: "inv1")
        try await client.declineInvitation(id: "inv1")

        XCTAssertEqual(created.slug, "beta")
        XCTAssertEqual(invitations.first?.email, "me@example.com")
        XCTAssertEqual(invitation.workspaceName, "Beta")
        XCTAssertEqual(member.workspaceId, "w2")
        XCTAssertEqual(requests.map { "\($0.method ?? "") \($0.path)" }, [
            "POST /api/workspaces",
            "POST /api/workspaces/w1/leave",
            "DELETE /api/workspaces/w1",
            "GET /api/invitations",
            "GET /api/invitations/inv1",
            "POST /api/invitations/inv1/accept",
            "POST /api/invitations/inv1/decline",
        ])
        XCTAssertEqual(requests[0].body?["name"] as? String, "Beta")
        XCTAssertEqual(requests[0].body?["slug"] as? String, "beta")
        XCTAssertEqual(requests[0].body?["description"] as? String, "D")
        XCTAssertEqual(requests[0].body?["context"] as? String, "C")
        XCTAssertEqual(requests[1].query, "workspace_id=w1")
        XCTAssertEqual(requests[2].query, "workspace_id=w1")
    }

    func test_createIssue_sendsDesktopCreateFields() async throws {
        let json = """
        {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":"D",
         "status":"backlog","priority":"high","assignee_id":"a1","assignee_type":"agent",
         "parent_issue_id":"p0","project_id":"p1","workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        var capturedURL: URL?
        var body: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/issues")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.createIssue(
            title: "T",
            description: "D",
            workspaceId: "w1",
            status: .backlog,
            priority: .high,
            assigneeType: "agent",
            assigneeId: "a1",
            projectId: "p1",
            parentIssueId: "p0",
            dueDate: "2026-05-07T00:00:00Z"
        )

        XCTAssertEqual(body["workspace_id"] as? String, "w1")
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(body["status"] as? String, "backlog")
        XCTAssertEqual(body["priority"] as? String, "high")
        XCTAssertEqual(body["assignee_type"] as? String, "agent")
        XCTAssertEqual(body["assignee_id"] as? String, "a1")
        XCTAssertEqual(body["project_id"] as? String, "p1")
        XCTAssertEqual(body["parent_issue_id"] as? String, "p0")
        XCTAssertEqual(body["due_date"] as? String, "2026-05-07T00:00:00Z")
    }

    func test_childIssueEndpoints_matchDesktopPaths() async throws {
        var requests: [String] = []
        var childIssuesURL: URL?
        var childProgressURL: URL?
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch req.url?.path {
            case "/api/issues/i1/children":
                childIssuesURL = req.url
                let json = """
                {"issues":[{"id":"c1","identifier":"PAR-2","number":2,"title":"Child","description":null,
                 "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
                 "parent_issue_id":"i1","project_id":null,"workspace_id":"w1",
                 "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            case "/api/issues/child-progress":
                childProgressURL = req.url
                let json = #"{"progress":[{"parent_issue_id":"i1","total":3,"done":1}]}"#.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let children = try await client.listChildIssues(issueId: "i1", workspaceId: "w1")
        let progress = try await client.getChildIssueProgress(workspaceId: "w1")

        XCTAssertEqual(children.map(\.id), ["c1"])
        XCTAssertEqual(children.first?.parentIssueId, "i1")
        XCTAssertTrue(childIssuesURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertTrue(childProgressURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(progress.progress.map(\.parentIssueId), ["i1"])
        XCTAssertEqual(progress.progress.first?.done, 1)
        XCTAssertEqual(requests, [
            "GET /api/issues/i1/children",
            "GET /api/issues/child-progress",
        ])
    }

    func test_listInbox_decodesBareArrayResponse() async throws {
        let json = """
        [{
            "id":"n1","workspace_id":"w1","recipient_type":"member","recipient_id":"u1",
            "actor_type":null,"actor_id":null,"type":"new_comment","severity":"attention",
            "issue_id":"i1","title":"PAR-73 updated","body":null,"issue_status":"todo",
            "read":false,"archived":false,"created_at":"2026-01-01T00:00:00Z",
            "details":{"identifier":"PAR-73"}
        }]
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/inbox")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let page = try await client.listInbox(workspaceId: "w1", workspaceSlug: "park0er")

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.issueTitle, "PAR-73 updated")
        XCTAssertEqual(capturedURL?.query, "workspace_id=w1")
    }

    func test_listInbox_sendsPaginationWhenProvided() async throws {
        MockURLProtocol.handler = { req in
            let url = try XCTUnwrap(req.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let queryItems = components.queryItems ?? []
            XCTAssertEqual(url.path, "/api/inbox")
            XCTAssertEqual(queryItems.first(where: { $0.name == "workspace_id" })?.value, "w1")
            XCTAssertEqual(queryItems.first(where: { $0.name == "limit" })?.value, "50")
            XCTAssertEqual(queryItems.first(where: { $0.name == "offset" })?.value, "100")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("[]".utf8)
            )
        }

        _ = try await client.listInbox(
            workspaceId: "w1",
            workspaceSlug: "park0er",
            limit: 50,
            offset: 100
        )
    }

    func test_markInboxRead_usesDesktopReadEndpoint() async throws {
        let json = """
        {"id":"n1","workspace_id":"w1","recipient_type":"member","recipient_id":"u1",
         "actor_type":null,"actor_id":null,"type":"new_comment","severity":"attention",
         "issue_id":"i1","title":"PAR-73 updated","body":null,"issue_status":"todo",
         "read":true,"archived":false,"created_at":"2026-01-01T00:00:00Z",
         "details":{"identifier":"PAR-73"}}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/inbox/n1/read")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let item = try await client.markInboxRead(id: "n1", workspaceId: "w1", workspaceSlug: "park0er")

        XCTAssertTrue(item.read)
        XCTAssertEqual(capturedURL?.query, "workspace_id=w1")
    }

    func test_archiveInbox_usesDesktopArchiveEndpoint() async throws {
        let json = """
        {"id":"n1","workspace_id":"w1","recipient_type":"member","recipient_id":"u1",
         "actor_type":null,"actor_id":null,"type":"new_comment","severity":"attention",
         "issue_id":"i1","title":"PAR-73 updated","body":null,"issue_status":"todo",
         "read":true,"archived":true,"created_at":"2026-01-01T00:00:00Z",
         "details":{"identifier":"PAR-73"}}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/inbox/n1/archive")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let item = try await client.archiveInbox(id: "n1", workspaceId: "w1", workspaceSlug: "park0er")

        XCTAssertTrue(item.archived)
        XCTAssertEqual(capturedURL?.query, "workspace_id=w1")
    }

    func test_markAllInboxRead_usesDesktopBulkEndpoint() async throws {
        let json = #"{"count":3}"#.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/inbox/mark-all-read")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let response = try await client.markAllInboxRead(workspaceId: "w1", workspaceSlug: "park0er")

        XCTAssertEqual(response.count, 3)
        XCTAssertEqual(capturedURL?.query, "workspace_id=w1")
    }

    func test_archiveAllInbox_usesDesktopBulkEndpoint() async throws {
        let json = #"{"count":3}"#.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/inbox/archive-all")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let response = try await client.archiveAllInbox(workspaceId: "w1", workspaceSlug: "park0er")

        XCTAssertEqual(response.count, 3)
        XCTAssertEqual(capturedURL?.query, "workspace_id=w1")
    }

    func test_archiveAllReadInbox_usesDesktopBulkEndpoint() async throws {
        let json = #"{"count":2}"#.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/inbox/archive-all-read")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let response = try await client.archiveAllReadInbox(workspaceId: "w1", workspaceSlug: "park0er")

        XCTAssertEqual(response.count, 2)
        XCTAssertEqual(capturedURL?.query, "workspace_id=w1")
    }

    func test_archiveCompletedInbox_usesDesktopBulkEndpoint() async throws {
        let json = #"{"count":1}"#.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/inbox/archive-completed")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let response = try await client.archiveCompletedInbox(workspaceId: "w1", workspaceSlug: "park0er")

        XCTAssertEqual(response.count, 1)
        XCTAssertEqual(capturedURL?.query, "workspace_id=w1")
    }

    func test_getUnreadInboxCount_usesDesktopEndpoint() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"count":4}"#.utf8))
        }

        let response = try await client.getUnreadInboxCount(workspaceId: "w1", workspaceSlug: "park0er")

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/inbox/unread-count")
        XCTAssertEqual(capturedRequest?.url?.query, "workspace_id=w1")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
        XCTAssertEqual(response.count, 4)
    }

    func test_notificationPreferenceEndpointsUseDesktopShape() async throws {
        var requests: [(method: String, path: String, body: [String: Any]?)] = []
        MockURLProtocol.handler = { req in
            let requestBody = MockURLProtocol.bodyData(for: req)
            let body = requestBody.isEmpty
                ? nil
                : (try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            requests.append((req.httpMethod ?? "", req.url?.path ?? "", body))
            let json = """
            {"workspace_id":"w1","preferences":{"comments":"muted","agent_activity":"all"}}
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json
            )
        }

        let loaded = try await client.getNotificationPreferences(workspaceId: "w1")
        let updated = try await client.updateNotificationPreferences(
            NotificationPreferences(comments: .muted, agentActivity: .all),
            workspaceId: "w1"
        )

        XCTAssertEqual(loaded.workspaceId, "w1")
        XCTAssertEqual(loaded.preferences.comments, .muted)
        XCTAssertEqual(updated.preferences.agentActivity, .all)
        XCTAssertEqual(requests.map { "\($0.method) \($0.path)" }, [
            "GET /api/notification-preferences",
            "PUT /api/notification-preferences",
        ])
        XCTAssertEqual((requests[1].body?["preferences"] as? [String: String])?["comments"], "muted")
        XCTAssertEqual((requests[1].body?["preferences"] as? [String: String])?["agent_activity"], "all")
    }

    func test_createFeedbackUsesDesktopShapeAndWorkspaceScope() async throws {
        var capturedURL: URL?
        var capturedBody: [String: Any]?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            let requestBody = MockURLProtocol.bodyData(for: req)
            capturedBody = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/feedback")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            let json = """
            {"id":"fb1","created_at":"2026-05-07T00:00:00Z"}
            """.data(using: .utf8)!
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                json
            )
        }

        let response = try await client.createFeedback(
            message: "Issue detail needs Markdown",
            url: "https://app.multica.ai/issues/1",
            workspaceId: "w1"
        )

        XCTAssertEqual(response.id, "fb1")
        XCTAssertEqual(capturedURL?.query, "workspace_id=w1")
        XCTAssertEqual(capturedBody?["message"] as? String, "Issue detail needs Markdown")
        XCTAssertEqual(capturedBody?["url"] as? String, "https://app.multica.ai/issues/1")
        XCTAssertEqual(capturedBody?["workspace_id"] as? String, "w1")
    }

    func test_personalAccessTokenEndpointsUseDesktopShape() async throws {
        var requests: [(method: String, path: String, body: [String: Any]?)] = []
        MockURLProtocol.handler = { req in
            let requestBody = MockURLProtocol.bodyData(for: req)
            let body = requestBody.isEmpty
                ? nil
                : (try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            requests.append((req.httpMethod ?? "", req.url?.path ?? "", body))

            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/tokens"):
                let json = """
                [{"id":"t1","name":"CLI","token_prefix":"mul_abc12345","expires_at":null,"last_used_at":null,"created_at":"2026-05-01T00:00:00Z"}]
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            case ("POST", "/api/tokens"):
                let json = """
                {"id":"t2","name":"Mobile","token_prefix":"mul_xyz12345","expires_at":"2026-08-01T00:00:00Z","last_used_at":null,"created_at":"2026-05-01T00:00:00Z","token":"mul_xyz123456789"}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, json)
            case ("DELETE", "/api/tokens/t1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.path ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let tokens = try await client.listPersonalAccessTokens()
        let created = try await client.createPersonalAccessToken(name: "Mobile", expiresInDays: 90)
        try await client.revokePersonalAccessToken(id: "t1")

        XCTAssertEqual(tokens.first?.tokenPrefix, "mul_abc12345")
        XCTAssertEqual(created.token, "mul_xyz123456789")
        XCTAssertEqual(requests.map { "\($0.method) \($0.path)" }, [
            "GET /api/tokens",
            "POST /api/tokens",
            "DELETE /api/tokens/t1",
        ])
        XCTAssertEqual(requests[1].body?["name"] as? String, "Mobile")
        XCTAssertEqual(requests[1].body?["expires_in_days"] as? Int, 90)
    }

    func test_listComments_decodesBareArrayResponse() async throws {
        let json = """
        [{"id":"c1","content":"Hi","author_id":"u1","author_type":"member",
          "parent_id":null,"issue_id":"i1","created_at":"2026-01-01T00:00:00Z"}]
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/issues/i1/comments")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let page = try await client.listComments(issueId: "i1", workspaceId: "w1")

        XCTAssertEqual(page.items.map(\.id), ["c1"])
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_listComments_infersHasMoreFromTotalWhenWrapperOmitsFlag() async throws {
        let json = """
        {"comments":[{"id":"c1","content":"Hi","author_id":"u1","author_type":"member",
          "parent_id":null,"issue_id":"i1","created_at":"2026-01-01T00:00:00Z"}],
         "total":2}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/issues/i1/comments")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let page = try await client.listComments(issueId: "i1", workspaceId: "w1", limit: 1, offset: 0)

        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.items.map(\.id), ["c1"])
    }

    func test_addComment_sendsDesktopCommentType() async throws {
        let json = """
        {"id":"c1","content":"Hi","author_id":"u1","author_type":"member",
         "parent_id":null,"issue_id":"i1","created_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        var capturedURL: URL?
        var body: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/issues/i1/comments")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.addComment(issueId: "i1", content: "Hi", workspaceId: "w1")

        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(body["content"] as? String, "Hi")
        XCTAssertEqual(body["type"] as? String, "comment")
    }

    func test_uploadFile_usesDesktopMultipartEndpoint() async throws {
        let json = """
        {"id":"att1","workspace_id":"w1","issue_id":"i1","comment_id":null,
         "uploader_type":"member","uploader_id":"u1","filename":"spec.md",
         "url":"https://cdn.example/spec.md","download_url":"https://cdn.example/spec.md",
         "content_type":"text/markdown","size_bytes":11,"created_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        var capturedBody = ""
        var capturedContentType = ""
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/upload-file")
            XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
            capturedContentType = req.value(forHTTPHeaderField: "Content-Type") ?? ""
            capturedBody = String(data: MockURLProtocol.bodyData(for: req), encoding: .utf8) ?? ""
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let attachment = try await client.uploadFile(
            filename: "spec.md",
            data: Data("hello world".utf8),
            contentType: "text/markdown",
            issueId: "i1",
            workspaceId: "w1"
        )

        XCTAssertEqual(attachment.id, "att1")
        XCTAssertTrue(capturedContentType.hasPrefix("multipart/form-data; boundary="))
        XCTAssertTrue(capturedBody.contains(#"name="file"; filename="spec.md""#))
        XCTAssertTrue(capturedBody.contains("Content-Type: text/markdown"))
        XCTAssertTrue(capturedBody.contains("hello world"))
        XCTAssertTrue(capturedBody.contains(#"name="issue_id""#))
        XCTAssertTrue(capturedBody.contains("i1"))
    }

    func test_attachmentEndpointsUseDesktopPathsAndWorkspaceScope() async throws {
        var requests: [(method: String?, path: String, query: String?)] = []
        MockURLProtocol.handler = { req in
            requests.append((req.httpMethod, req.url?.path ?? "", req.url?.query))
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/issues/i1/attachments"):
                let json = """
                [{"id":"att1","workspace_id":"w1","issue_id":"i1","comment_id":null,
                  "uploader_type":"member","uploader_id":"u1","filename":"spec.md",
                  "url":"https://cdn.example/spec.md","download_url":"https://cdn.example/spec.md",
                  "content_type":"text/markdown","size_bytes":11,"created_at":"2026-01-01T00:00:00Z"}]
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
            case ("DELETE", "/api/attachments/att1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let attachments = try await client.listAttachments(issueId: "i1", workspaceId: "w1")
        try await client.deleteAttachment(id: "att1", workspaceId: "w1")

        XCTAssertEqual(attachments.map(\.id), ["att1"])
        XCTAssertEqual(requests.map(\.method), ["GET", "DELETE"])
        XCTAssertEqual(requests.map(\.path), ["/api/issues/i1/attachments", "/api/attachments/att1"])
        XCTAssertEqual(requests.map(\.query), ["workspace_id=w1", "workspace_id=w1"])
    }

    func test_getAttachmentContent_fetchesPlainTextPreviewBody() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertEqual(req.url?.path, "/api/attachments/att1/content")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return Self.response(req, body: "# Preview\n\nHello".data(using: .utf8)!)
        }

        let content = try await client.getAttachmentContent(id: "att1", workspaceId: "w1")

        XCTAssertEqual(content, "# Preview\n\nHello")
    }

    func test_createIssue_sendsAttachmentIds() async throws {
        var body: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/issues")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            let json = """
            {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
             "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
             "project_id":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
             "updated_at":"2026-01-01T00:00:00Z"}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.createIssue(
            title: "T",
            description: nil,
            workspaceId: "w1",
            attachmentIds: ["att1", "att2"]
        )

        XCTAssertEqual(body["attachment_ids"] as? [String], ["att1", "att2"])
    }

    func test_addComment_sendsAttachmentIds() async throws {
        let json = """
        {"id":"c1","content":"Hi","author_id":"u1","author_type":"member",
         "parent_id":null,"issue_id":"i1","created_at":"2026-01-01T00:00:00Z",
         "attachments":[]}
        """.data(using: .utf8)!
        var body: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/issues/i1/comments")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.addComment(
            issueId: "i1",
            content: "Hi",
            attachmentIds: ["att1"],
            workspaceId: "w1"
        )

        XCTAssertEqual(body["attachment_ids"] as? [String], ["att1"])
    }

    func test_listTimeline_decodesDesktopActivityEntries() async throws {
        let json = """
        [{"type":"activity","id":"a1","actor_type":"member","actor_id":"u1",
          "created_at":"2026-01-01T00:00:00Z","action":"status_changed",
          "details":{"from":"todo","to":"done"}},
         {"type":"comment","id":"c1","actor_type":"agent","actor_id":"agent1",
          "created_at":"2026-01-02T00:00:00Z","content":"**Done**","parent_id":null,
          "comment_type":"comment"}]
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/issues/i1/timeline")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let entries = try await client.listTimeline(issueId: "i1", workspaceId: "w1")

        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(entries.map(\.id), ["a1", "c1"])
        XCTAssertEqual(entries.first?.action, "status_changed")
        XCTAssertEqual(entries.first?.detailString("to"), "done")
        XCTAssertEqual(entries.last?.content, "**Done**")
    }

    func test_getIssueUsage_decodesDesktopSummary() async throws {
        let json = """
        {"total_input_tokens":1200,"total_output_tokens":340,
         "total_cache_read_tokens":50,"total_cache_write_tokens":10,
         "task_count":3}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/issues/i1/usage")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let usage = try await client.getIssueUsage(issueId: "i1", workspaceId: "w1")

        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(usage.taskCount, 3)
        XCTAssertEqual(usage.totalInputTokens, 1_200)
        XCTAssertEqual(usage.totalOutputTokens, 340)
        XCTAssertEqual(usage.totalCacheReadTokens, 50)
        XCTAssertEqual(usage.totalCacheWriteTokens, 10)
    }

    func test_updateIssue_sendsWorkspaceIdAndMutableFields() async throws {
        let json = """
        {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
         "status":"in_review","priority":"urgent","assignee_id":null,"assignee_type":null,
         "project_id":null,"workspace_id":"w1","position":4,"created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-02T00:00:00Z"}
        """.data(using: .utf8)!
        var capturedURL: URL?
        var body: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "PUT")
            XCTAssertEqual(req.url?.path, "/api/issues/i1")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let issue = try await client.updateIssue(id: "i1", workspaceId: "w1", status: .inReview, priority: .urgent, position: 4)

        XCTAssertEqual(issue.status, .inReview)
        XCTAssertEqual(issue.priority, .urgent)
        XCTAssertEqual(issue.position, 4)
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(body["status"] as? String, "in_review")
        XCTAssertEqual(body["priority"] as? String, "urgent")
        XCTAssertEqual(body["position"] as? Int, 4)
    }

    func test_deleteIssue_usesDesktopEndpoint() async throws {
        var capturedMethod: String?
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedMethod = req.httpMethod
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/issues/i1")
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await client.deleteIssue(id: "i1", workspaceId: "w1")

        XCTAssertEqual(capturedMethod, "DELETE")
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_batchUpdateIssues_usesDesktopEndpointAndBody() async throws {
        var body: [String: Any] = [:]
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/issues/batch-update")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"updated":2}"#.utf8)
            )
        }

        let response = try await client.batchUpdateIssues(
            ids: ["i1", "i2"],
            workspaceId: "w1",
            status: .done,
            priority: .urgent
        )

        XCTAssertEqual(response.updated, 2)
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(body["issue_ids"] as? [String], ["i1", "i2"])
        let updates = body["updates"] as? [String: Any]
        XCTAssertEqual(updates?["status"] as? String, "done")
        XCTAssertEqual(updates?["priority"] as? String, "urgent")
    }

    func test_batchDeleteIssues_usesDesktopEndpointAndBody() async throws {
        var body: [String: Any] = [:]
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/issues/batch-delete")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"deleted":2}"#.utf8)
            )
        }

        let response = try await client.batchDeleteIssues(ids: ["i1", "i2"], workspaceId: "w1")

        XCTAssertEqual(response.deleted, 2)
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(body["issue_ids"] as? [String], ["i1", "i2"])
    }

    func test_updateIssueDetails_sendsEditableFieldsAndNulls() async throws {
        let json = """
        {"id":"i1","identifier":"PAR-1","number":1,"title":"Updated","description":null,
         "status":"blocked","priority":"high","assignee_id":null,"assignee_type":null,
         "project_id":null,"due_date":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-02T00:00:00Z"}
        """.data(using: .utf8)!
        var capturedURL: URL?
        var body: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "PUT")
            XCTAssertEqual(req.url?.path, "/api/issues/i1")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let issue = try await client.updateIssueDetails(
            id: "i1",
            workspaceId: "w1",
            title: "Updated",
            description: nil,
            status: .blocked,
            priority: .high,
            assigneeType: nil,
            assigneeId: nil,
            projectId: nil,
            dueDate: nil
        )

        XCTAssertEqual(issue.title, "Updated")
        XCTAssertNil(issue.description)
        XCTAssertNil(issue.assigneeId)
        XCTAssertNil(issue.projectId)
        XCTAssertNil(issue.dueDate)
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(body["title"] as? String, "Updated")
        XCTAssertTrue(body.keys.contains("description"))
        XCTAssertTrue(body["description"] is NSNull)
        XCTAssertEqual(body["status"] as? String, "blocked")
        XCTAssertEqual(body["priority"] as? String, "high")
        XCTAssertTrue(body.keys.contains("assignee_type"))
        XCTAssertTrue(body["assignee_type"] is NSNull)
        XCTAssertTrue(body.keys.contains("assignee_id"))
        XCTAssertTrue(body["assignee_id"] is NSNull)
        XCTAssertTrue(body.keys.contains("project_id"))
        XCTAssertTrue(body["project_id"] is NSNull)
        XCTAssertTrue(body.keys.contains("due_date"))
        XCTAssertTrue(body["due_date"] is NSNull)
    }

    func test_listAgentRuns_decodesBareArrayResponse() async throws {
        let json = """
        [{
            "id":"t1","agent_id":"a1","runtime_id":"r1","issue_id":"i1",
            "status":"running","priority":0,"dispatched_at":null,
            "started_at":"2026-01-01T00:00:00Z","completed_at":null,
            "result":null,"error":null,"created_at":"2026-01-01T00:00:00Z"
        }]
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/issues/i1/task-runs")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let runs = try await client.listAgentRuns(issueId: "i1", workspaceId: "w1")

        XCTAssertEqual(runs.map(\.id), ["t1"])
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_getActiveTasksForIssue_usesDesktopEndpoint() async throws {
        let json = """
        {"tasks":[{
            "id":"t1","agent_id":"a1","runtime_id":"r1","issue_id":"i1",
            "status":"running","priority":0,"dispatched_at":null,
            "started_at":"2026-01-01T00:00:00Z","completed_at":null,
            "result":null,"error":null,"created_at":"2026-01-01T00:00:00Z"
        }]}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/issues/i1/active-task")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let tasks = try await client.getActiveTasksForIssue(issueId: "i1", workspaceId: "w1")

        XCTAssertEqual(tasks.map(\.id), ["t1"])
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_cancelIssueTask_usesDesktopEndpoint() async throws {
        let json = """
        {"id":"t1","agent_id":"a1","runtime_id":"r1","issue_id":"i1",
         "status":"cancelled","priority":0,"dispatched_at":null,
         "started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:01:00Z",
         "result":null,"error":null,"created_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        var capturedURL: URL?
        var capturedMethod: String?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            capturedMethod = req.httpMethod
            XCTAssertEqual(req.url?.path, "/api/issues/i1/tasks/t1/cancel")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let task = try await client.cancelTask(issueId: "i1", taskId: "t1", workspaceId: "w1")

        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertEqual(task.status, "cancelled")
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_listRunMessages_decodesBareArrayResponse() async throws {
        let json = """
        [{"task_id":"t1","issue_id":"i1","seq":7,"type":"text","content":"done"}]
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/tasks/t1/messages")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let messages = try await client.listRunMessages(taskId: "t1", workspaceId: "w1")

        XCTAssertEqual(messages.first?.id, "t1:7")
        XCTAssertEqual(messages.first?.seq, 7)
        XCTAssertEqual(messages.first?.content, "done")
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_listProjects_decodesProjectsWrapper() async throws {
        let json = """
        {"projects":[{
            "id":"p1","workspace_id":"w1","title":"iOS MVP","description":null,
            "icon":null,"status":"in_progress","priority":"none",
            "lead_type":null,"lead_id":null,
            "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
            "issue_count":2,"done_count":1
        }],"total":1}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/projects")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let page = try await client.listProjects(workspaceId: "w1")

        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.items.first?.name, "iOS MVP")
    }

    func test_listProjects_infersHasMoreFromTotalWhenWrapperOmitsFlag() async throws {
        let json = """
        {"projects":[{
            "id":"p1","workspace_id":"w1","title":"iOS MVP","description":null,
            "icon":null,"status":"in_progress","priority":"none",
            "lead_type":null,"lead_id":null,
            "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
            "issue_count":2,"done_count":1
        }],"total":2}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/projects")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let page = try await client.listProjects(workspaceId: "w1", limit: 1, offset: 0)

        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.items.map(\.id), ["p1"])
    }

    func test_listProjectResources_decodesResourcesWrapper() async throws {
        let json = """
        {"resources":[{
            "id":"r1","project_id":"p1","workspace_id":"w1","resource_type":"github_repo",
            "resource_ref":{"url":"https://github.com/multica-ai/multica","default_branch_hint":"main"},
            "label":null,"position":0,"created_at":"2026-01-01T00:00:00Z","created_by":null
        }],"total":1}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/projects/p1/resources")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let page = try await client.listProjectResources(projectId: "p1", workspaceId: "w1")

        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.items.first?.displayTitle, "https://github.com/multica-ai/multica")
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_projectResourceMutationEndpointsUseDesktopPathsAndBody() async throws {
        var requests: [(method: String?, path: String, workspaceId: String?, body: [String: Any]?)] = []
        let resourceJSON = """
        {"id":"r1","project_id":"p1","workspace_id":"w1","resource_type":"github_repo",
         "resource_ref":{"url":"https://github.com/multica-ai/multica"},"label":"Multi-Casual",
         "position":3,"created_at":"2026-01-01T00:00:00Z","created_by":null}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            let bodyData = MockURLProtocol.bodyData(for: req)
            let body = bodyData.isEmpty ? nil : try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            requests.append((
                req.httpMethod,
                req.url?.path ?? "",
                components?.queryItems?.first(where: { $0.name == "workspace_id" })?.value,
                body
            ))
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/projects/p1/resources"):
                return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, resourceJSON)
            case ("DELETE", "/api/projects/p1/resources/r1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let resource = try await client.createProjectResource(
            projectId: "p1",
            workspaceId: "w1",
            resourceType: "github_repo",
            resourceRef: ["url": .string("https://github.com/multica-ai/multica")],
            label: "Multi-Casual",
            position: 3
        )
        try await client.deleteProjectResource(projectId: "p1", resourceId: "r1", workspaceId: "w1")

        XCTAssertEqual(resource.id, "r1")
        XCTAssertEqual(requests.map(\.method), ["POST", "DELETE"])
        XCTAssertEqual(requests.map(\.path), ["/api/projects/p1/resources", "/api/projects/p1/resources/r1"])
        XCTAssertEqual(requests.map(\.workspaceId), ["w1", "w1"])
        XCTAssertEqual(requests[0].body?["resource_type"] as? String, "github_repo")
        XCTAssertEqual((requests[0].body?["resource_ref"] as? [String: Any])?["url"] as? String, "https://github.com/multica-ai/multica")
        XCTAssertEqual(requests[0].body?["label"] as? String, "Multi-Casual")
        XCTAssertEqual(requests[0].body?["position"] as? Int, 3)
    }

    func test_getProject_sendsWorkspaceIdParamWhenProvided() async throws {
        let json = """
        {"id":"p1","workspace_id":"w1","title":"iOS MVP","description":null,
         "icon":null,"status":"in_progress","priority":"none",
         "lead_type":null,"lead_id":null,"created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-01T00:00:00Z","issue_count":2,"done_count":1}
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/projects/p1")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        _ = try await client.getProject(id: "p1", workspaceId: "w1")

        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_projectMutationEndpointsUseDesktopPaths() async throws {
        var requests: [(method: String?, path: String, body: [String: Any]?)] = []
        let projectJSON = """
        {"id":"p1","workspace_id":"w1","title":"Edited Project","description":"**Docs**",
         "icon":null,"status":"paused","priority":"high",
         "lead_type":null,"lead_id":null,"created_at":"2026-01-01T00:00:00Z",
         "updated_at":"2026-01-01T00:00:00Z","issue_count":0,"done_count":0}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            let body: [String: Any]?
            let data = MockURLProtocol.bodyData(for: req)
            if !data.isEmpty {
                body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } else {
                body = nil
            }
            requests.append((req.httpMethod, req.url?.path ?? "", body))
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/projects"),
                 ("PUT", "/api/projects/p1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, projectJSON)
            case ("DELETE", "/api/projects/p1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
        }

        _ = try await client.createProject(
            title: "Edited Project",
            description: "**Docs**",
            workspaceId: "w1",
            status: .paused,
            priority: .high,
            icon: "📱",
            leadType: "agent",
            leadId: "a1",
            resourceURLs: ["https://github.com/multica-ai/multica"]
        )
        _ = try await client.updateProject(
            id: "p1",
            workspaceId: "w1",
            title: "Edited Project",
            description: nil,
            status: .paused,
            priority: .high,
            icon: nil,
            leadType: nil,
            leadId: nil
        )
        try await client.deleteProject(id: "p1", workspaceId: "w1")

        XCTAssertEqual(requests.map(\.method), ["POST", "PUT", "DELETE"])
        XCTAssertEqual(requests.map(\.path), ["/api/projects", "/api/projects/p1", "/api/projects/p1"])
        XCTAssertEqual(requests[0].body?["title"] as? String, "Edited Project")
        XCTAssertEqual(requests[0].body?["description"] as? String, "**Docs**")
        XCTAssertEqual(requests[0].body?["status"] as? String, "paused")
        XCTAssertEqual(requests[0].body?["priority"] as? String, "high")
        XCTAssertEqual(requests[0].body?["icon"] as? String, "📱")
        XCTAssertEqual(requests[0].body?["lead_type"] as? String, "agent")
        XCTAssertEqual(requests[0].body?["lead_id"] as? String, "a1")
        let resources = requests[0].body?["resources"] as? [[String: Any]]
        XCTAssertEqual(resources?.first?["resource_type"] as? String, "github_repo")
        XCTAssertEqual((resources?.first?["resource_ref"] as? [String: Any])?["url"] as? String, "https://github.com/multica-ai/multica")
        XCTAssertTrue(requests[1].body?["description"] is NSNull)
        XCTAssertTrue(requests[1].body?["icon"] is NSNull)
        XCTAssertTrue(requests[1].body?["lead_type"] is NSNull)
        XCTAssertTrue(requests[1].body?["lead_id"] is NSNull)
    }

    func test_pinEndpointsUseDesktopPathsAndWorkspaceScope() async throws {
        var requests: [(method: String?, path: String, query: String?, workspaceSlug: String?, body: [String: Any]?)] = []
        let pinJSON = """
        {"id":"pin1","workspace_id":"w1","user_id":"u1","item_type":"issue","item_id":"i1",
         "position":1,"created_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            let body: [String: Any]?
            let data = MockURLProtocol.bodyData(for: req)
            if !data.isEmpty {
                body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            } else {
                body = nil
            }
            requests.append((req.httpMethod, req.url?.path ?? "", req.url?.query, req.value(forHTTPHeaderField: "X-Workspace-Slug"), body))
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/pins"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[\(String(data: pinJSON, encoding: .utf8)!)]".utf8))
            case ("POST", "/api/pins"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, pinJSON)
            case ("DELETE", "/api/pins/issue/i1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
        }

        let pins = try await client.listPins(workspaceId: "w1", workspaceSlug: "park0er")
        _ = try await client.createPin(itemType: .issue, itemId: "i1", workspaceId: "w1", workspaceSlug: "park0er")
        try await client.deletePin(itemType: .issue, itemId: "i1", workspaceId: "w1", workspaceSlug: "park0er")

        XCTAssertEqual(pins.first?.itemType, .issue)
        XCTAssertEqual(requests.map(\.method), ["GET", "POST", "DELETE"])
        XCTAssertEqual(requests.map(\.path), ["/api/pins", "/api/pins", "/api/pins/issue/i1"])
        XCTAssertEqual(requests.map(\.query), ["workspace_id=w1", "workspace_id=w1", "workspace_id=w1"])
        XCTAssertEqual(requests.map(\.workspaceSlug), ["park0er", "park0er", "park0er"])
        XCTAssertEqual(requests[1].body?["item_type"] as? String, "issue")
        XCTAssertEqual(requests[1].body?["item_id"] as? String, "i1")
    }

    func test_reorderPinsUsesDesktopEndpointAndBody() async throws {
        var capturedRequest: URLRequest?
        var body: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            capturedRequest = req
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await client.reorderPins(
            items: [
                .init(itemType: .project, itemId: "p1"),
                .init(itemType: .issue, itemId: "i1"),
            ],
            workspaceId: "w1",
            workspaceSlug: "park0er"
        )

        XCTAssertEqual(capturedRequest?.httpMethod, "PUT")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/pins/reorder")
        XCTAssertEqual(capturedRequest?.url?.query, "workspace_id=w1")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "X-Workspace-Slug"), "park0er")
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0]["item_type"] as? String, "project")
        XCTAssertEqual(items[0]["item_id"] as? String, "p1")
        XCTAssertEqual(items[0]["position"] as? Int, 0)
        XCTAssertEqual(items[1]["item_type"] as? String, "issue")
        XCTAssertEqual(items[1]["item_id"] as? String, "i1")
        XCTAssertEqual(items[1]["position"] as? Int, 1)
    }

    func test_listMembers_decodesWorkspaceMembers() async throws {
        let json = """
        [{"id":"m1","workspace_id":"w1","user_id":"u1","role":"owner",
          "created_at":"2026-01-01T00:00:00Z","name":"Parker",
          "email":"p@example.com","avatar_url":null}]
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/workspaces/w1/members")
            XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let members = try await client.listMembers(workspaceId: "w1")

        XCTAssertEqual(members.first?.name, "Parker")
    }

    func test_workspaceMemberMutationEndpointsUseDesktopPaths() async throws {
        var requests: [(method: String?, path: String, query: String?, body: [String: Any]?)] = []
        let memberJSON = """
        {"id":"m1","workspace_id":"w1","user_id":"u1","role":"admin",
         "created_at":"2026-01-01T00:00:00Z","name":"Parker",
         "email":"p@example.com","avatar_url":null}
        """.data(using: .utf8)!
        let invitationJSON = """
        {"id":"inv1","workspace_id":"w1","email":"new@example.com","role":"member",
         "status":"pending","created_at":"2026-01-01T00:00:00Z","expires_at":null}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            let bodyData = MockURLProtocol.bodyData(for: req)
            let body = bodyData.isEmpty ? nil : try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            requests.append((req.httpMethod, req.url?.path ?? "", req.url?.query, body))
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/workspaces/w1/members"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, invitationJSON)
            case ("PATCH", "/api/workspaces/w1/members/m1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, memberJSON)
            case ("DELETE", "/api/workspaces/w1/members/m1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let invitation = try await client.createMember(workspaceId: "w1", email: "new@example.com", role: "member")
        let member = try await client.updateMember(workspaceId: "w1", memberId: "m1", role: "admin")
        try await client.deleteMember(workspaceId: "w1", memberId: "m1")

        XCTAssertEqual(invitation.email, "new@example.com")
        XCTAssertEqual(member.role, "admin")
        XCTAssertEqual(requests.map(\.method), ["POST", "PATCH", "DELETE"])
        XCTAssertEqual(requests.map(\.path), [
            "/api/workspaces/w1/members",
            "/api/workspaces/w1/members/m1",
            "/api/workspaces/w1/members/m1",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.query == "workspace_id=w1" })
        XCTAssertEqual(requests[0].body?["email"] as? String, "new@example.com")
        XCTAssertEqual(requests[0].body?["role"] as? String, "member")
        XCTAssertEqual(requests[1].body?["role"] as? String, "admin")
    }

    func test_workspaceInvitationEndpointsUseDesktopPaths() async throws {
        var requests: [(method: String?, path: String, query: String?)] = []
        let invitationJSON = """
        {"id":"inv1","workspace_id":"w1","email":"new@example.com","role":"member",
         "status":"pending","created_at":"2026-01-01T00:00:00Z","expires_at":null}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            requests.append((req.httpMethod, req.url?.path ?? "", req.url?.query))
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/workspaces/w1/invitations"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[\(String(data: invitationJSON, encoding: .utf8)!)]".utf8))
            case ("DELETE", "/api/workspaces/w1/invitations/inv1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let invitations = try await client.listWorkspaceInvitations(workspaceId: "w1")
        try await client.revokeInvitation(workspaceId: "w1", invitationId: "inv1")

        XCTAssertEqual(invitations.map(\.id), ["inv1"])
        XCTAssertEqual(requests.map { "\($0.method ?? "") \($0.path)" }, [
            "GET /api/workspaces/w1/invitations",
            "DELETE /api/workspaces/w1/invitations/inv1",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.query == "workspace_id=w1" })
    }

    func test_listAgents_decodesWorkspaceAgents() async throws {
        let json = """
        [{"id":"a1","workspace_id":"w1","runtime_id":"r1","name":"Codex",
          "description":"","instructions":"","avatar_url":null,"runtime_mode":"cloud",
          "runtime_config":{},"custom_env":{},"custom_args":[],"custom_env_redacted":false,
          "visibility":"workspace","status":"active","max_concurrent_tasks":1,
          "model":"gpt","owner_id":null,"skills":[],"created_at":"2026-01-01T00:00:00Z",
          "updated_at":"2026-01-01T00:00:00Z","archived_at":null,"archived_by":null}]
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/agents")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let agents = try await client.listAgents(workspaceId: "w1")

        XCTAssertEqual(agents.first?.name, "Codex")
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_listAgents_canIncludeArchivedAgents() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/agents")
            XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
            XCTAssertTrue(req.url?.absoluteString.contains("include_archived=true") ?? false)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
        }

        let agents = try await client.listAgents(workspaceId: "w1", includeArchived: true)

        XCTAssertTrue(agents.isEmpty)
    }

    func test_listSquads_decodesWorkspaceSquads() async throws {
        let json = #"{"squads":[{"id":"s1","workspace_id":"w1","name":"Design Squad","description":"Design","avatar_url":null,"agent_ids":["a1"],"member_ids":["u1"],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","archived_at":null}]}"#.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/squads")
            XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
            XCTAssertTrue(req.url?.absoluteString.contains("include_archived=true") ?? false)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let squads = try await client.listSquads(workspaceId: "w1", includeArchived: true)

        XCTAssertEqual(squads.map(\.id), ["s1"])
        XCTAssertEqual(squads.first?.name, "Design Squad")
        XCTAssertEqual(squads.first?.agentIds, ["a1"])
        XCTAssertEqual(squads.first?.memberIds, ["u1"])
    }

    func test_getSquad_usesIdEndpointAndWorkspaceScope() async throws {
        var capturedRequest: URLRequest?
        let json = #"{"id":"s1","workspace_id":"w1","name":"Design Squad","description":"Design","instructions":"Be helpful","avatar_url":null,"leader_id":"a1","agent_ids":["a1"],"member_ids":[],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","archived_at":null}"#.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            capturedRequest = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let squad = try await client.getSquad(id: "s1", workspaceId: "w1")

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/squads/s1")
        XCTAssertEqual(capturedRequest?.url?.query, "workspace_id=w1")
        XCTAssertEqual(squad.name, "Design Squad")
        XCTAssertEqual(squad.leaderId, "a1")
        XCTAssertEqual(squad.instructions, "Be helpful")
    }

    func test_createSquad_postsLeaderAndName() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?
        let json = #"{"id":"s2","workspace_id":"w1","name":"Mobile","description":"iOS team","leader_id":"a1","agent_ids":[],"member_ids":[],"archived_at":null}"#.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            capturedRequest = req
            capturedBody = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let squad = try await client.createSquad(
            name: "Mobile",
            description: "iOS team",
            leaderId: "a1",
            workspaceId: "w1"
        )

        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/squads")
        XCTAssertEqual(capturedRequest?.url?.query, "workspace_id=w1")
        XCTAssertEqual(capturedBody?["name"] as? String, "Mobile")
        XCTAssertEqual(capturedBody?["description"] as? String, "iOS team")
        XCTAssertEqual(capturedBody?["leader_id"] as? String, "a1")
        XCTAssertEqual(squad.id, "s2")
    }

    func test_updateSquad_putsPartialFields() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?
        let json = #"{"id":"s1","workspace_id":"w1","name":"Renamed","description":"","instructions":"New instructions","leader_id":"a2","agent_ids":[],"member_ids":[],"archived_at":null}"#.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            capturedRequest = req
            capturedBody = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let squad = try await client.updateSquad(
            id: "s1",
            name: "Renamed",
            instructions: "New instructions",
            leaderId: "a2",
            workspaceId: "w1"
        )

        XCTAssertEqual(capturedRequest?.httpMethod, "PUT")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/squads/s1")
        XCTAssertEqual(capturedRequest?.url?.query, "workspace_id=w1")
        XCTAssertEqual(capturedBody?["name"] as? String, "Renamed")
        XCTAssertEqual(capturedBody?["instructions"] as? String, "New instructions")
        XCTAssertEqual(capturedBody?["leader_id"] as? String, "a2")
        // description was nil and must be omitted from the partial update body.
        XCTAssertNil(capturedBody?["avatar_url"])
        XCTAssertEqual(squad.name, "Renamed")
        XCTAssertEqual(squad.instructions, "New instructions")
    }

    func test_deleteSquad_usesDeleteVerb() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await client.deleteSquad(id: "s1", workspaceId: "w1")

        XCTAssertEqual(capturedRequest?.httpMethod, "DELETE")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/squads/s1")
        XCTAssertEqual(capturedRequest?.url?.query, "workspace_id=w1")
    }

    func test_addSquadMember_postsMemberTypeAndId() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?
        let json = #"{"member_type":"member","member_id":"u2","role":"member","squad_id":"s1","created_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            capturedRequest = req
            capturedBody = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let member = try await client.addSquadMember(
            squadId: "s1",
            memberType: "member",
            memberId: "u2",
            role: "member",
            workspaceId: "w1"
        )

        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/squads/s1/members")
        XCTAssertEqual(capturedRequest?.url?.query, "workspace_id=w1")
        XCTAssertEqual(capturedBody?["member_type"] as? String, "member")
        XCTAssertEqual(capturedBody?["member_id"] as? String, "u2")
        XCTAssertEqual(capturedBody?["role"] as? String, "member")
        XCTAssertEqual(member.memberId, "u2")
        XCTAssertEqual(member.memberType, "member")
    }

    func test_listSquadMembers_decodesRoleField() async throws {
        var capturedRequest: URLRequest?
        let json = #"[{"id":"sm1","squad_id":"s1","member_type":"agent","member_id":"a1","role":"leader, can also review","created_at":"2026-01-01T00:00:00Z"}]"#.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            capturedRequest = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let members = try await client.listSquadMembers(squadId: "s1", workspaceId: "w1")

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/squads/s1/members")
        XCTAssertEqual(members.first?.memberId, "a1")
        XCTAssertEqual(members.first?.role, "leader, can also review")
    }

    func test_removeSquadMember_sendsDeleteWithBody() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            capturedBody = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await client.removeSquadMember(squadId: "s1", memberType: "agent", memberId: "a1", workspaceId: "w1")

        XCTAssertEqual(capturedRequest?.httpMethod, "DELETE")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/squads/s1/members")
        XCTAssertEqual(capturedBody?["member_type"] as? String, "agent")
        XCTAssertEqual(capturedBody?["member_id"] as? String, "a1")
        XCTAssertNil(capturedBody?["role"])
    }

    func test_updateSquadMemberRole_patchesRoleText() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?
        let json = #"{"id":"sm1","squad_id":"s1","member_type":"agent","member_id":"a1","role":"能力很一般，可以凑数打杂","created_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            capturedRequest = req
            capturedBody = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let member = try await client.updateSquadMemberRole(
            squadId: "s1",
            memberType: "agent",
            memberId: "a1",
            role: "能力很一般，可以凑数打杂",
            workspaceId: "w1"
        )

        XCTAssertEqual(capturedRequest?.httpMethod, "PATCH")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/squads/s1/members/role")
        XCTAssertEqual(capturedBody?["member_type"] as? String, "agent")
        XCTAssertEqual(capturedBody?["member_id"] as? String, "a1")
        XCTAssertEqual(capturedBody?["role"] as? String, "能力很一般，可以凑数打杂")
        XCTAssertEqual(member.role, "能力很一般，可以凑数打杂")
    }

    func test_getSquadMemberStatus_decodesBucketsAndActiveIssues() async throws {
        var capturedRequest: URLRequest?
        let json = """
        {"members":[
          {"member_type":"agent","member_id":"a1","status":"working",
           "active_issues":[{"issue_id":"i1","identifier":"PAR-1","title":"Do work","issue_status":"in_progress"}],
           "last_active_at":"2026-01-01T00:00:00Z"},
          {"member_type":"member","member_id":"u1","status":null,"active_issues":[],"last_active_at":null}
        ]}
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            capturedRequest = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let resp = try await client.getSquadMemberStatus(squadId: "s1", workspaceId: "w1")

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/squads/s1/members/status")
        XCTAssertEqual(resp.members.count, 2)
        XCTAssertEqual(resp.members.first?.status, "working")
        XCTAssertEqual(resp.members.first?.activeIssues.first?.identifier, "PAR-1")
        XCTAssertNil(resp.members.last?.status)
    }

    func test_getAgentUsesDesktopEndpointAndWorkspaceScope() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            let json = """
            {"id":"a1","workspace_id":"w1","runtime_id":"r1","name":"Codex",
              "description":"Agent","instructions":"Do work","avatar_url":null,
              "runtime_mode":"cloud","runtime_config":{},"custom_env":{},"custom_args":[],
              "custom_env_redacted":false,"visibility":"workspace","status":"active",
              "max_concurrent_tasks":1,"model":"gpt","owner_id":null,"skills":[],
              "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
              "archived_at":null,"archived_by":null}
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let agent = try await client.getAgent(id: "a1", workspaceId: "w1")

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/agents/a1")
        XCTAssertEqual(capturedRequest?.url?.query, "workspace_id=w1")
        XCTAssertEqual(agent.name, "Codex")
        XCTAssertEqual(agent.instructions, "Do work")
    }

    func test_listAgentTasks_usesDesktopEndpoint() async throws {
        let json = """
        [{"id":"t1","agent_id":"a1","issue_id":"i1","status":"completed",
          "started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:02:00Z","error":null}]
        """.data(using: .utf8)!
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let tasks = try await client.listAgentTasks(agentId: "a1", workspaceId: "w1")

        XCTAssertEqual(capturedURL?.path, "/api/agents/a1/tasks")
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(tasks.map(\.id), ["t1"])
        XCTAssertEqual(tasks.first?.agentId, "a1")
    }

    func test_createAgent_sendsDesktopFields() async throws {
        var body: [String: Any] = [:]
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/agents")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            let json = Self.agentJSON(id: "a1", name: "Codex")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let agent = try await client.createAgent(
            name: "Codex",
            description: "Helps with code",
            instructions: "Be concise",
            runtimeId: "r1",
            visibility: "workspace",
            maxConcurrentTasks: 2,
            model: "gpt-5",
            avatarUrl: "https://cdn.example/agents/codex.png",
            customEnv: ["ANTHROPIC_BASE_URL": "https://example.com"],
            customArgs: ["--verbose", "--model", "gpt-5"],
            workspaceId: "w1"
        )

        XCTAssertEqual(agent.name, "Codex")
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(body["name"] as? String, "Codex")
        XCTAssertEqual(body["description"] as? String, "Helps with code")
        XCTAssertEqual(body["instructions"] as? String, "Be concise")
        XCTAssertEqual(body["runtime_id"] as? String, "r1")
        XCTAssertEqual(body["visibility"] as? String, "workspace")
        XCTAssertEqual(body["max_concurrent_tasks"] as? Int, 2)
        XCTAssertEqual(body["model"] as? String, "gpt-5")
        XCTAssertEqual(body["avatar_url"] as? String, "https://cdn.example/agents/codex.png")
        XCTAssertEqual((body["custom_env"] as? [String: String])?["ANTHROPIC_BASE_URL"], "https://example.com")
        XCTAssertEqual(body["custom_args"] as? [String], ["--verbose", "--model", "gpt-5"])
    }

    func test_updateArchiveRestoreAndCancelAgentUseDesktopEndpoints() async throws {
        var requests: [(String, String)] = []
        var requestURLs: [URL] = []
        var updateBody: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            requests.append((req.httpMethod ?? "", req.url?.path ?? ""))
            requestURLs.append(req.url!)
            let body: Data
            if req.url?.path == "/api/agents/a1/cancel-tasks" {
                body = #"{"cancelled":2}"#.data(using: .utf8)!
            } else {
                if req.url?.path == "/api/agents/a1", req.httpMethod == "PUT" {
                    updateBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                }
                body = Self.agentJSON(id: "a1", name: "Updated")
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        _ = try await client.updateAgent(
            id: "a1",
            name: "Updated",
            description: "",
            instructions: "",
            runtimeId: "r2",
            visibility: "private",
            maxConcurrentTasks: 1,
            model: "gpt-5",
            avatarUrl: "https://cdn.example/agents/updated.png",
            customEnv: ["OPENAI_API_KEY": "sk-test"],
            customArgs: ["--debug"],
            workspaceId: "w1"
        )
        _ = try await client.archiveAgent(id: "a1", workspaceId: "w1")
        _ = try await client.restoreAgent(id: "a1", workspaceId: "w1")
        let cancelled = try await client.cancelAgentTasks(id: "a1", workspaceId: "w1")

        XCTAssertEqual(requests.map { "\($0.0) \($0.1)" }, [
            "PUT /api/agents/a1",
            "POST /api/agents/a1/archive",
            "POST /api/agents/a1/restore",
            "POST /api/agents/a1/cancel-tasks",
        ])
        XCTAssertTrue(requestURLs.allSatisfy { $0.absoluteString.contains("workspace_id=w1") })
        XCTAssertEqual(cancelled.count, 2)
        XCTAssertEqual(updateBody["runtime_id"] as? String, "r2")
        XCTAssertEqual(updateBody["avatar_url"] as? String, "https://cdn.example/agents/updated.png")
        XCTAssertEqual((updateBody["custom_env"] as? [String: String])?["OPENAI_API_KEY"], "sk-test")
        XCTAssertEqual(updateBody["custom_args"] as? [String], ["--debug"])
    }

    func test_listRuntimes_decodesWorkspaceRuntimes() async throws {
        let json = """
        [{"id":"r1","workspace_id":"w1","daemon_id":null,"name":"MacBook",
          "runtime_mode":"cloud","provider":"multica","launch_header":"",
          "status":"online","device_info":"","metadata":{},"owner_id":null,
          "last_seen_at":null,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]
        """.data(using: .utf8)!
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/api/runtimes")
            XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let runtimes = try await client.listRuntimes(workspaceId: "w1")

        XCTAssertEqual(runtimes.first?.name, "MacBook")
        XCTAssertEqual(runtimes.first?.status, "online")
    }

    func test_deleteRuntime_usesDesktopEndpoint() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }

        try await client.deleteRuntime(id: "r1", workspaceId: "w1")

        XCTAssertEqual(capturedRequest?.httpMethod, "DELETE")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/runtimes/r1")
        XCTAssertTrue(capturedRequest?.url?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_getRuntimeUsage_usesDesktopEndpoint() async throws {
        let json = """
        [{"runtime_id":"r1","date":"2026-01-01","provider":"anthropic","model":"claude-sonnet-4",
          "input_tokens":1000,"output_tokens":2000,"cache_read_tokens":300,"cache_write_tokens":400}]
        """.data(using: .utf8)!
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }

        let usage = try await client.getRuntimeUsage(id: "r1", workspaceId: "w1", days: 30)

        XCTAssertEqual(capturedRequest?.url?.path, "/api/runtimes/r1/usage")
        XCTAssertTrue(capturedRequest?.url?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertTrue(capturedRequest?.url?.absoluteString.contains("days=30") ?? false)
        XCTAssertEqual(usage.first?.model, "claude-sonnet-4")
        XCTAssertEqual(usage.first?.totalTokens, 3700)
    }

    func test_runtimeTelemetryEndpointsUseDesktopPaths() async throws {
        var requests: [String] = []
        var queries: [String] = []
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            queries.append(req.url?.query ?? "")
            let body: Data
            switch req.url?.path {
            case "/api/runtimes/r1/activity":
                body = """
                [{"hour":"2026-01-01T00:00:00Z","queued":1,"running":2,"completed":3,"failed":4,"cancelled":5}]
                """.data(using: .utf8)!
            case "/api/runtimes/r1/usage/by-agent":
                body = """
                [{"agent_id":"a1","agent_name":"Codex","input_tokens":100,"output_tokens":200,
                  "cache_read_tokens":30,"cache_write_tokens":40}]
                """.data(using: .utf8)!
            case "/api/runtimes/r1/usage/by-hour":
                body = """
                [{"hour":"2026-01-01T00:00:00Z","input_tokens":10,"output_tokens":20,
                  "cache_read_tokens":3,"cache_write_tokens":4}]
                """.data(using: .utf8)!
            default:
                XCTFail("Unexpected request \(req.url?.absoluteString ?? "")")
                body = Data("{}".utf8)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let activity = try await client.getRuntimeTaskActivity(id: "r1", workspaceId: "w1")
        let byAgent = try await client.getRuntimeUsageByAgent(id: "r1", workspaceId: "w1", days: 30)
        let byHour = try await client.getRuntimeUsageByHour(id: "r1", workspaceId: "w1", days: 30)

        XCTAssertEqual(requests, [
            "GET /api/runtimes/r1/activity",
            "GET /api/runtimes/r1/usage/by-agent",
            "GET /api/runtimes/r1/usage/by-hour",
        ])
        XCTAssertTrue(queries.allSatisfy { $0.contains("workspace_id=w1") })
        XCTAssertTrue(queries[1].contains("days=30"))
        XCTAssertTrue(queries[2].contains("days=30"))
        XCTAssertEqual(activity.first?.totalTasks, 15)
        XCTAssertEqual(byAgent.first?.agentName, "Codex")
        XCTAssertEqual(byAgent.first?.totalTokens, 370)
        XCTAssertEqual(byHour.first?.totalTokens, 37)
    }

    func test_getWorkspaceAgentActivity30d_usesDesktopEndpoint() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            let body = """
            [{"agent_id":"a1","bucket_at":"2026-01-01T00:00:00Z","task_count":4,"failed_count":1}]
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let buckets = try await client.getWorkspaceAgentActivity30d(workspaceId: "w1")

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/agent-activity-30d")
        XCTAssertTrue(capturedRequest?.url?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(buckets.first?.agentId, "a1")
        XCTAssertEqual(buckets.first?.taskCount, 4)
        XCTAssertEqual(buckets.first?.failedCount, 1)
    }

    func test_getWorkspaceAgentRunCounts_usesDesktopEndpoint() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            let body = """
            [{"agent_id":"a1","run_count":7}]
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let counts = try await client.getWorkspaceAgentRunCounts(workspaceId: "w1")

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/agent-run-counts")
        XCTAssertTrue(capturedRequest?.url?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(counts.first?.agentId, "a1")
        XCTAssertEqual(counts.first?.runCount, 7)
    }

    func test_getAgentTaskSnapshot_usesDesktopEndpoint() async throws {
        var capturedRequest: URLRequest?
        MockURLProtocol.handler = { req in
            capturedRequest = req
            let body = """
            [{"id":"t1","agent_id":"a1","issue_id":"i1","status":"running",
              "started_at":"2026-05-06T00:00:00Z","completed_at":null,"error":null}]
            """.data(using: .utf8)!
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let tasks = try await client.getAgentTaskSnapshot(workspaceId: "w1")

        XCTAssertEqual(capturedRequest?.httpMethod, "GET")
        XCTAssertEqual(capturedRequest?.url?.path, "/api/agent-task-snapshot")
        XCTAssertTrue(capturedRequest?.url?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertEqual(tasks.first?.agentId, "a1")
        XCTAssertEqual(tasks.first?.status, "running")
    }

    func test_runtimeModelAndLocalSkillRequestEndpointsUseDesktopPaths() async throws {
        var requests: [String] = []
        var queries: [String] = []
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            queries.append(req.url?.query ?? "")
            let body: Data
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/runtimes/r1/models"):
                body = """
                {"id":"models-1","runtime_id":"r1","status":"completed",
                 "models":[{"id":"m1","name":"gpt-5.1","provider":"openai"}]}
                """.data(using: .utf8)!
            case ("GET", "/api/runtimes/r1/models/models-1"):
                body = """
                {"id":"models-1","runtime_id":"r1","status":"completed",
                 "models":[{"id":"m1","name":"gpt-5.1","provider":"openai"}]}
                """.data(using: .utf8)!
            case ("POST", "/api/runtimes/r1/local-skills"):
                body = """
                {"id":"skills-1","runtime_id":"r1","status":"completed",
                 "skills":[{"id":"s1","name":"Writer","path":"/skills/writer"}]}
                """.data(using: .utf8)!
            case ("GET", "/api/runtimes/r1/local-skills/skills-1"):
                body = """
                {"id":"skills-1","runtime_id":"r1","status":"completed",
                 "skills":[{"id":"s1","name":"Writer","path":"/skills/writer"}]}
                """.data(using: .utf8)!
            default:
                XCTFail("Unexpected request \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                body = Data("{}".utf8)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let modelRequest = try await client.initiateListRuntimeModels(id: "r1", workspaceId: "w1")
        let modelResult = try await client.getRuntimeModelListResult(id: "r1", requestId: "models-1", workspaceId: "w1")
        let skillRequest = try await client.initiateListRuntimeLocalSkills(id: "r1", workspaceId: "w1")
        let skillResult = try await client.getRuntimeLocalSkillListResult(id: "r1", requestId: "skills-1", workspaceId: "w1")

        XCTAssertEqual(requests, [
            "POST /api/runtimes/r1/models",
            "GET /api/runtimes/r1/models/models-1",
            "POST /api/runtimes/r1/local-skills",
            "GET /api/runtimes/r1/local-skills/skills-1",
        ])
        XCTAssertTrue(queries.allSatisfy { $0.contains("workspace_id=w1") })
        XCTAssertEqual(modelRequest.models.map(\.name), ["gpt-5.1"])
        XCTAssertEqual(modelResult.status, "completed")
        XCTAssertEqual(skillRequest.skills.map(\.name), ["Writer"])
        XCTAssertEqual(skillResult.status, "completed")
    }

    func test_runtimeUpdateAndLocalSkillImportEndpointsUseDesktopPaths() async throws {
        var requests: [String] = []
        var queries: [String] = []
        var bodies: [[String: Any]] = []
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            queries.append(req.url?.query ?? "")
            let bodyData = MockURLProtocol.bodyData(for: req)
            if !bodyData.isEmpty,
               let object = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] {
                bodies.append(object)
            }
            let body: Data
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/runtimes/r1/update"):
                body = """
                {"id":"update-1","runtime_id":"r1","status":"pending",
                 "target_version":"v1.2.3","created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
            case ("GET", "/api/runtimes/r1/update/update-1"):
                body = """
                {"id":"update-1","runtime_id":"r1","status":"completed",
                 "target_version":"v1.2.3","output":"Updated",
                 "created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
            case ("POST", "/api/runtimes/r1/local-skills/import"):
                body = """
                {"id":"import-1","runtime_id":"r1","skill_key":"review-helper",
                 "name":"Review Helper","description":"Review pull requests",
                 "status":"pending","created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
            case ("GET", "/api/runtimes/r1/local-skills/import/import-1"):
                body = """
                {"id":"import-1","runtime_id":"r1","skill_key":"review-helper",
                 "name":"Review Helper","description":"Review pull requests",
                 "status":"completed","skill":{"id":"s1","workspace_id":"w1",
                 "name":"Review Helper","description":"Review pull requests",
                 "content":"# Review Helper","config":{},"files":[],
                 "created_by":"u1","created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-01T00:00:00Z"},
                 "created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
            default:
                XCTFail("Unexpected request \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                body = Data("{}".utf8)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let update = try await client.initiateRuntimeUpdate(id: "r1", targetVersion: "v1.2.3", workspaceId: "w1")
        let updateResult = try await client.getRuntimeUpdateResult(id: "r1", updateId: "update-1", workspaceId: "w1")
        let skillImport = try await client.initiateImportRuntimeLocalSkill(
            id: "r1",
            skillKey: "review-helper",
            name: "Review Helper",
            description: "Review pull requests",
            workspaceId: "w1"
        )
        let skillImportResult = try await client.getRuntimeLocalSkillImportResult(id: "r1", requestId: "import-1", workspaceId: "w1")

        XCTAssertEqual(requests, [
            "POST /api/runtimes/r1/update",
            "GET /api/runtimes/r1/update/update-1",
            "POST /api/runtimes/r1/local-skills/import",
            "GET /api/runtimes/r1/local-skills/import/import-1",
        ])
        XCTAssertTrue(queries.allSatisfy { $0.contains("workspace_id=w1") })
        XCTAssertEqual(bodies.first?["target_version"] as? String, "v1.2.3")
        XCTAssertEqual(bodies.last?["skill_key"] as? String, "review-helper")
        XCTAssertEqual(update.targetVersion, "v1.2.3")
        XCTAssertEqual(updateResult.output, "Updated")
        XCTAssertEqual(skillImport.skillKey, "review-helper")
        XCTAssertEqual(skillImportResult.skill?.name, "Review Helper")
    }

    func test_skillEndpointsUseDesktopPaths() async throws {
        var requests: [String] = []
        var requestURLs: [URL] = []
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            requestURLs.append(req.url!)
            if req.httpMethod == "DELETE" {
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
            let body: Data
            if req.url?.path == "/api/skills", req.httpMethod == "GET" {
                body = "[\(String(data: Self.skillJSON(id: "s1", name: "Writer"), encoding: .utf8)!)]".data(using: .utf8)!
            } else {
                body = Self.skillJSON(id: "s1", name: "Writer")
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let skills = try await client.listSkills(workspaceId: "w1")
        _ = try await client.getSkill(id: "s1", workspaceId: "w1")
        _ = try await client.createSkill(name: "Writer", description: "D", content: "C", workspaceId: "w1")
        _ = try await client.updateSkill(id: "s1", name: "Writer", description: "D2", content: "C2", workspaceId: "w1")
        _ = try await client.importSkill(url: "https://example.com/skill", workspaceId: "w1")
        try await client.deleteSkill(id: "s1", workspaceId: "w1")

        XCTAssertEqual(skills.map(\.id), ["s1"])
        XCTAssertEqual(requests, [
            "GET /api/skills",
            "GET /api/skills/s1",
            "POST /api/skills",
            "PUT /api/skills/s1",
            "POST /api/skills/import",
            "DELETE /api/skills/s1",
        ])
        XCTAssertTrue(requestURLs.allSatisfy { $0.absoluteString.contains("workspace_id=w1") })
    }

    func test_agentSkillEndpointsUseDesktopPaths() async throws {
        var requests: [String] = []
        var body: [String: Any] = [:]
        let skillJSON = Self.skillJSON(id: "s1", name: "Writer")
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/agents/a1/skills"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[\(String(data: skillJSON, encoding: .utf8)!)]".utf8))
            case ("PUT", "/api/agents/a1/skills"):
                body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
        }

        let skills = try await client.listAgentSkills(agentId: "a1", workspaceId: "w1")
        try await client.setAgentSkills(agentId: "a1", skillIds: ["s1", "s2"], workspaceId: "w1")

        XCTAssertEqual(skills.map(\.id), ["s1"])
        XCTAssertEqual(requests, ["GET /api/agents/a1/skills", "PUT /api/agents/a1/skills"])
        XCTAssertEqual(body["skill_ids"] as? [String], ["s1", "s2"])
    }

    func test_autopilotEndpointsUseDesktopPaths() async throws {
        var requests: [String] = []
        var requestURLs: [URL] = []
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")?\(req.url?.query ?? "")")
            requestURLs.append(req.url!)
            let path = req.url?.path
            if req.httpMethod == "DELETE" {
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            let body: Data
            switch path {
            case "/api/autopilots" where req.httpMethod == "GET":
                body = #"{"autopilots":[\#(String(data: Self.autopilotJSON(id: "ap1", title: "Daily triage"), encoding: .utf8)!)],"total":1}"#.data(using: .utf8)!
            case "/api/autopilots/ap1":
                if req.httpMethod == "GET" {
                    body = #"{"autopilot":\#(String(data: Self.autopilotJSON(id: "ap1", title: "Daily triage"), encoding: .utf8)!),"triggers":[]}"#.data(using: .utf8)!
                } else {
                    body = Self.autopilotJSON(id: "ap1", title: "Daily triage")
                }
            case "/api/autopilots/ap1/runs":
                body = #"{"runs":[\#(String(data: Self.autopilotRunJSON(id: "run1"), encoding: .utf8)!)],"total":1}"#.data(using: .utf8)!
            case "/api/autopilots/ap1/triggers":
                body = Self.autopilotTriggerJSON(id: "tr1")
            case "/api/autopilots/ap1/triggers/tr1":
                body = Self.autopilotTriggerJSON(id: "tr1")
            case "/api/autopilots/ap1/trigger":
                body = Self.autopilotRunJSON(id: "run1")
            default:
                body = Self.autopilotJSON(id: "ap1", title: "Daily triage")
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let list = try await client.listAutopilots(status: "active", workspaceId: "w1")
        _ = try await client.getAutopilot(id: "ap1", workspaceId: "w1")
        _ = try await client.createAutopilot(title: "Daily triage", description: "D", assigneeId: "a1", executionMode: "create_issue", issueTitleTemplate: "T", workspaceId: "w1")
        _ = try await client.updateAutopilot(id: "ap1", title: "Daily triage", description: nil, assigneeId: "a1", status: "paused", executionMode: "run_only", issueTitleTemplate: nil, workspaceId: "w1")
        try await client.deleteAutopilot(id: "ap1", workspaceId: "w1")
        _ = try await client.triggerAutopilot(id: "ap1", workspaceId: "w1")
        let runs = try await client.listAutopilotRuns(id: "ap1", workspaceId: "w1", limit: 10, offset: 20)
        _ = try await client.createAutopilotTrigger(autopilotId: "ap1", kind: "schedule", cronExpression: "0 9 * * *", timezone: "UTC", label: "Morning", workspaceId: "w1")
        _ = try await client.updateAutopilotTrigger(autopilotId: "ap1", triggerId: "tr1", enabled: false, cronExpression: nil, timezone: nil, label: nil, workspaceId: "w1")
        try await client.deleteAutopilotTrigger(autopilotId: "ap1", triggerId: "tr1", workspaceId: "w1")

        XCTAssertEqual(list.autopilots.map(\.id), ["ap1"])
        XCTAssertEqual(runs.runs.map(\.id), ["run1"])
        XCTAssertEqual(requests.map { $0.split(separator: "?").first.map(String.init) ?? $0 }, [
            "GET /api/autopilots",
            "GET /api/autopilots/ap1",
            "POST /api/autopilots",
            "PATCH /api/autopilots/ap1",
            "DELETE /api/autopilots/ap1",
            "POST /api/autopilots/ap1/trigger",
            "GET /api/autopilots/ap1/runs",
            "POST /api/autopilots/ap1/triggers",
            "PATCH /api/autopilots/ap1/triggers/tr1",
            "DELETE /api/autopilots/ap1/triggers/tr1",
        ])
        XCTAssertTrue(requestURLs.allSatisfy { $0.absoluteString.contains("workspace_id=w1") })
    }

    func test_labelEndpointsUseDesktopPaths() async throws {
        var requests: [String] = []
        var requestURLs: [URL] = []
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            requestURLs.append(req.url!)
            if req.httpMethod == "DELETE", req.url?.path == "/api/labels/l1" {
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            let body: Data
            switch req.url?.path {
            case "/api/labels" where req.httpMethod == "GET":
                body = #"{"labels":[\#(String(data: Self.labelJSON(id: "l1", name: "bug"), encoding: .utf8)!)],"total":1}"#.data(using: .utf8)!
            case "/api/issues/i1/labels":
                body = #"{"labels":[\#(String(data: Self.labelJSON(id: "l1", name: "bug"), encoding: .utf8)!)]}"#.data(using: .utf8)!
            case "/api/issues/i1/labels/l1":
                body = #"{"labels":[]}"#.data(using: .utf8)!
            default:
                body = Self.labelJSON(id: "l1", name: "bug")
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let list = try await client.listLabels(workspaceId: "w1")
        _ = try await client.getLabel(id: "l1", workspaceId: "w1")
        _ = try await client.createLabel(name: "bug", color: "#ef4444", workspaceId: "w1")
        _ = try await client.updateLabel(id: "l1", name: "bug", color: "#dc2626", workspaceId: "w1")
        try await client.deleteLabel(id: "l1", workspaceId: "w1")
        let issueLabels = try await client.listLabelsForIssue(issueId: "i1", workspaceId: "w1")
        _ = try await client.attachLabel(issueId: "i1", labelId: "l1", workspaceId: "w1")
        _ = try await client.detachLabel(issueId: "i1", labelId: "l1", workspaceId: "w1")

        XCTAssertEqual(list.labels.map(\.id), ["l1"])
        XCTAssertEqual(issueLabels.labels.map(\.id), ["l1"])
        XCTAssertEqual(requests, [
            "GET /api/labels",
            "GET /api/labels/l1",
            "POST /api/labels",
            "PUT /api/labels/l1",
            "DELETE /api/labels/l1",
            "GET /api/issues/i1/labels",
            "POST /api/issues/i1/labels",
            "DELETE /api/issues/i1/labels/l1",
        ])
        XCTAssertTrue(requestURLs.allSatisfy { $0.absoluteString.contains("workspace_id=w1") })
    }

    func test_issueSubscriberEndpointsUseDesktopPaths() async throws {
        var requests: [String] = []
        var requestURLs: [URL] = []
        var subscribeBody: [String: Any] = [:]
        var unsubscribeBody: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            requestURLs.append(req.url!)
            switch req.url?.path {
            case "/api/issues/i1/subscribers":
                let body = """
                [{"issue_id":"i1","user_type":"member","user_id":"u1","reason":"manual",
                  "created_at":"2026-01-01T00:00:00Z"}]
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            case "/api/issues/i1/subscribe":
                subscribeBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            case "/api/issues/i1/unsubscribe":
                unsubscribeBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let subscribers = try await client.listIssueSubscribers(issueId: "i1", workspaceId: "w1")
        try await client.subscribeToIssue(issueId: "i1", userId: "u2", userType: "member", workspaceId: "w1")
        try await client.unsubscribeFromIssue(issueId: "i1", userId: "a1", userType: "agent", workspaceId: "w1")

        XCTAssertEqual(subscribers.map(\.id), ["member:u1"])
        XCTAssertEqual(subscribeBody["user_id"] as? String, "u2")
        XCTAssertEqual(subscribeBody["user_type"] as? String, "member")
        XCTAssertEqual(unsubscribeBody["user_id"] as? String, "a1")
        XCTAssertEqual(unsubscribeBody["user_type"] as? String, "agent")
        XCTAssertEqual(requests, [
            "GET /api/issues/i1/subscribers",
            "POST /api/issues/i1/subscribe",
            "POST /api/issues/i1/unsubscribe",
        ])
        XCTAssertTrue(requestURLs.allSatisfy { $0.absoluteString.contains("workspace_id=w1") })
    }

    func test_reactionEndpointsUseDesktopPaths() async throws {
        var requests: [String] = []
        var requestURLs: [URL] = []
        var bodies: [[String: Any]] = []
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            requestURLs.append(req.url!)
            switch req.url?.path {
            case "/api/comments/c1/reactions":
                bodies.append(try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:])
                if req.httpMethod == "DELETE" {
                    return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
                }
                let body = """
                {"id":"r1","comment_id":"c1","actor_type":"member","actor_id":"u1",
                 "emoji":"👍","created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            case "/api/issues/i1/reactions":
                bodies.append(try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:])
                if req.httpMethod == "DELETE" {
                    return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
                }
                let body = """
                {"id":"ir1","issue_id":"i1","actor_type":"member","actor_id":"u1",
                 "emoji":"👀","created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let commentReaction = try await client.addReaction(commentId: "c1", emoji: "👍", workspaceId: "w1")
        try await client.removeReaction(commentId: "c1", emoji: "👍", workspaceId: "w1")
        let issueReaction = try await client.addIssueReaction(issueId: "i1", emoji: "👀", workspaceId: "w1")
        try await client.removeIssueReaction(issueId: "i1", emoji: "👀", workspaceId: "w1")

        XCTAssertEqual(commentReaction.id, "r1")
        XCTAssertEqual(issueReaction.id, "ir1")
        XCTAssertEqual(bodies.compactMap { $0["emoji"] as? String }, ["👍", "👍", "👀", "👀"])
        XCTAssertEqual(requests, [
            "POST /api/comments/c1/reactions",
            "DELETE /api/comments/c1/reactions",
            "POST /api/issues/i1/reactions",
            "DELETE /api/issues/i1/reactions",
        ])
        XCTAssertTrue(requestURLs.allSatisfy { $0.absoluteString.contains("workspace_id=w1") })
    }

    func test_commentMutationEndpointsUseDesktopPaths() async throws {
        var requests: [String] = []
        var requestURLs: [URL] = []
        var updateBody: [String: Any] = [:]
        MockURLProtocol.handler = { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            requestURLs.append(req.url!)
            switch (req.httpMethod, req.url?.path) {
            case ("PUT", "/api/comments/c1"):
                updateBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                let body = """
                {"id":"c1","content":"Updated **markdown**","author_id":"u1","author_type":"member",
                 "parent_id":null,"issue_id":"i1","created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            case ("DELETE", "/api/comments/c1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                return (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let comment = try await client.updateComment(commentId: "c1", content: "Updated **markdown**", workspaceId: "w1")
        try await client.deleteComment(commentId: "c1", workspaceId: "w1")

        XCTAssertEqual(comment.content, "Updated **markdown**")
        XCTAssertEqual(updateBody["content"] as? String, "Updated **markdown**")
        XCTAssertEqual(requests, [
            "PUT /api/comments/c1",
            "DELETE /api/comments/c1",
        ])
        XCTAssertTrue(requestURLs.allSatisfy { $0.absoluteString.contains("workspace_id=w1") })
    }

    private static func agentJSON(id: String, name: String) -> Data {
        """
        {"id":"\(id)","workspace_id":"w1","runtime_id":"r1","name":"\(name)",
          "description":"","instructions":"","avatar_url":null,"runtime_mode":"cloud",
          "runtime_config":{},"custom_env":{},"custom_args":[],"custom_env_redacted":false,
          "visibility":"workspace","status":"idle","max_concurrent_tasks":1,
          "model":"gpt","owner_id":null,"skills":[],"created_at":"2026-01-01T00:00:00Z",
          "updated_at":"2026-01-01T00:00:00Z","archived_at":null,"archived_by":null}
        """.data(using: .utf8)!
    }

    private static func skillJSON(id: String, name: String) -> Data {
        """
        {"id":"\(id)","workspace_id":"w1","name":"\(name)","description":"**D**",
         "content":"# Skill","config":{},"files":[],"created_by":"u1",
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
    }

    private static func autopilotJSON(id: String, title: String) -> Data {
        """
        {"id":"\(id)","workspace_id":"w1","title":"\(title)","description":"**D**",
         "assignee_id":"a1","status":"active","execution_mode":"create_issue",
         "issue_title_template":"T","created_by_type":"member","created_by_id":"u1",
         "last_run_at":null,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
    }

    private static func autopilotTriggerJSON(id: String) -> Data {
        """
        {"id":"\(id)","autopilot_id":"ap1","kind":"schedule","enabled":true,
         "cron_expression":"0 9 * * *","timezone":"UTC","next_run_at":null,
         "webhook_token":null,"label":"Morning","last_fired_at":null,
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
    }

    private static func autopilotRunJSON(id: String) -> Data {
        """
        {"id":"\(id)","autopilot_id":"ap1","trigger_id":null,"source":"manual",
         "status":"running","issue_id":null,"task_id":"t1","triggered_at":"2026-01-01T00:00:00Z",
         "completed_at":null,"failure_reason":null,"trigger_payload":{},"result":null,
         "created_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
    }

    private static func labelJSON(id: String, name: String) -> Data {
        """
        {"id":"\(id)","workspace_id":"w1","name":"\(name)","color":"#ef4444",
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
    }

    private static func response(_ request: URLRequest, body: Data, status: Int = 200) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            body
        )
    }

    private static func chatSessionJSON(id: String) -> Data {
        """
        {"id":"\(id)","workspace_id":"w1","agent_id":"a1","creator_id":"u1",
         "title":"Launch **Plan**","status":"active","has_unread":true,
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:01:00Z"}
        """.data(using: .utf8)!
    }

    private static func chatSessionsJSON() -> Data {
        "[\(String(data: chatSessionJSON(id: "c1"), encoding: .utf8)!)]".data(using: .utf8)!
    }

    private static func chatMessagesJSON() -> Data {
        """
        [
          {"id":"m1","chat_session_id":"c1","role":"user","content":"Hello **agent**",
           "task_id":null,"created_at":"2026-01-01T00:00:01Z","failure_reason":null,"elapsed_ms":null},
          {"id":"m2","chat_session_id":"c1","role":"assistant","content":"Done",
           "task_id":"t1","created_at":"2026-01-01T00:00:02Z","failure_reason":null,"elapsed_ms":1000}
        ]
        """.data(using: .utf8)!
    }

    private static func sendChatMessageJSON() -> Data {
        """
        {"message_id":"m3","task_id":"t2","created_at":"2026-01-01T00:00:03Z"}
        """.data(using: .utf8)!
    }

    private static func chatPendingTaskJSON() -> Data {
        """
        {"task_id":"t2","status":"running","created_at":"2026-01-01T00:00:03Z"}
        """.data(using: .utf8)!
    }

    private static func pendingChatTasksJSON() -> Data {
        """
        {"tasks":[{"task_id":"t2","status":"running","chat_session_id":"c1"}]}
        """.data(using: .utf8)!
    }

    func test_sendCode_usesAuthSendCodePath() async throws {
        var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        try await client.sendCode(email: "x@y.com")
        XCTAssertEqual(capturedPath, "/auth/send-code",
            "sendCode must not use the /api/ prefix — backend auth endpoints are rooted at /auth/*")
    }

    func test_verifyCode_usesAuthVerifyCodePath() async throws {
        let json = """
        {"token":"t"}
        """.data(using: .utf8)!
        var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        _ = try await client.verifyCode(email: "x@y.com", code: "123456")
        XCTAssertEqual(capturedPath, "/auth/verify-code")
    }

    func test_chatEndpointsUseDesktopPathsAndWorkspaceScope() async throws {
        var requests: [(method: String?, path: String, workspaceId: String?, body: [String: Any]?)] = []
        MockURLProtocol.handler = { req in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            let body = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
            requests.append((
                req.httpMethod,
                req.url?.path ?? "",
                components?.queryItems?.first(where: { $0.name == "workspace_id" })?.value,
                body ?? nil
            ))
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/chat/sessions"):
                return Self.response(req, body: Self.chatSessionsJSON())
            case ("GET", "/api/chat/sessions/c1"):
                return Self.response(req, body: Self.chatSessionJSON(id: "c1"))
            case ("POST", "/api/chat/sessions"):
                return Self.response(req, body: Self.chatSessionJSON(id: "c2"))
            case ("DELETE", "/api/chat/sessions/c1"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            case ("GET", "/api/chat/sessions/c1/messages"):
                return Self.response(req, body: Self.chatMessagesJSON())
            case ("POST", "/api/chat/sessions/c1/messages"):
                return Self.response(req, body: Self.sendChatMessageJSON())
            case ("GET", "/api/chat/sessions/c1/pending-task"):
                return Self.response(req, body: Self.chatPendingTaskJSON())
            case ("GET", "/api/chat/pending-tasks"):
                return Self.response(req, body: Self.pendingChatTasksJSON())
            case ("POST", "/api/chat/sessions/c1/read"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            case ("POST", "/api/tasks/t2/cancel"):
                return (HTTPURLResponse(url: req.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(req, body: Data("{}".utf8))
            }
        }

        _ = try await client.listChatSessions(workspaceId: "w1")
        _ = try await client.getChatSession(id: "c1", workspaceId: "w1")
        _ = try await client.createChatSession(agentId: "a1", title: "Launch", workspaceId: "w1")
        try await client.archiveChatSession(id: "c1", workspaceId: "w1")
        _ = try await client.listChatMessages(sessionId: "c1", workspaceId: "w1")
        _ = try await client.sendChatMessage(
            sessionId: "c1",
            content: "Hello **agent**",
            attachmentIds: ["att1", "att2"],
            workspaceId: "w1"
        )
        _ = try await client.getPendingChatTask(sessionId: "c1", workspaceId: "w1")
        _ = try await client.listPendingChatTasks(workspaceId: "w1")
        try await client.markChatSessionRead(sessionId: "c1", workspaceId: "w1")
        try await client.cancelTaskById(taskId: "t2", workspaceId: "w1")

        XCTAssertEqual(
            requests.map { "\($0.method ?? "") \($0.path)" },
            [
                "GET /api/chat/sessions",
                "GET /api/chat/sessions/c1",
                "POST /api/chat/sessions",
                "DELETE /api/chat/sessions/c1",
                "GET /api/chat/sessions/c1/messages",
                "POST /api/chat/sessions/c1/messages",
                "GET /api/chat/sessions/c1/pending-task",
                "GET /api/chat/pending-tasks",
                "POST /api/chat/sessions/c1/read",
                "POST /api/tasks/t2/cancel",
            ]
        )
        XCTAssertTrue(requests.allSatisfy { $0.workspaceId == "w1" })
        XCTAssertEqual(requests[2].body?["agent_id"] as? String, "a1")
        XCTAssertEqual(requests[2].body?["title"] as? String, "Launch")
        XCTAssertEqual(requests[5].body?["content"] as? String, "Hello **agent**")
        XCTAssertEqual(requests[5].body?["attachment_ids"] as? [String], ["att1", "att2"])
    }

    // MARK: - APIError LocalizedError

    func test_apiError_unauthorized_localizesToSignOutPrompt() {
        XCTAssertEqual(
            APIClient.APIError.unauthorized.errorDescription,
            "You're signed out. Please sign in again."
        )
    }

    func test_apiError_serverError_withJSONErrorField_surfacesBackendMessage() {
        let body = #"{"error":"Invalid verification code"}"#
        XCTAssertEqual(
            APIClient.APIError.serverError(400, body: body).errorDescription,
            "Invalid verification code"
        )
    }

    func test_apiError_serverError_withPlainText_includesStatusAndPreview() {
        XCTAssertEqual(
            APIClient.APIError.serverError(500, body: "something broke").errorDescription,
            "Server error (500): something broke"
        )
    }

    func test_apiError_serverError_withEmptyBody_fallsBackToGenericMessage() {
        XCTAssertEqual(
            APIClient.APIError.serverError(503, body: "").errorDescription,
            "Server error (503). Please try again."
        )
    }
}
