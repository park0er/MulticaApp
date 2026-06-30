import XCTest
@testable import MultiCasual

@MainActor
final class IssueCreateViewModelTests: XCTestCase {
    private let workspace = Workspace(id: "w1", name: "Workspace", slug: "workspace", issuePrefix: "PAR")

    func test_loadOptions_buildsAssigneeAndProjectChoices() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/workspaces/w1/members":
                let json = """
                [{"id":"m1","workspace_id":"w1","user_id":"u1","role":"owner",
                  "created_at":"2026-01-01T00:00:00Z","name":"Parker",
                  "email":"p@example.com","avatar_url":null}]
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/agents":
                let json = """
                [{"id":"a1","workspace_id":"w1","runtime_id":"r1","name":"Codex",
                  "description":"","instructions":"","avatar_url":null,"runtime_mode":"cloud",
                  "runtime_config":{},"custom_env":{},"custom_args":[],"custom_env_redacted":false,
                  "visibility":"workspace","status":"active","max_concurrent_tasks":1,
                  "model":"gpt","owner_id":null,"skills":[],"created_at":"2026-01-01T00:00:00Z",
                  "updated_at":"2026-01-01T00:00:00Z","archived_at":null,"archived_by":null}]
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/squads":
                let json = #"{"squads":[{"id":"s1","workspace_id":"w1","name":"Design Squad","description":"Design","avatar_url":null,"agent_ids":[],"member_ids":[],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","archived_at":null}]}"#.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/projects":
                let json = """
                {"projects":[{
                    "id":"p1","workspace_id":"w1","title":"iOS MVP","description":null,
                    "icon":null,"status":"in_progress","priority":"none",
                    "lead_type":null,"lead_id":null,
                    "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
                    "issue_count":2,"done_count":1
                }],"total":1}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueCreateViewModel(api: client, authSession: makeSession())

        await vm.loadOptions()

        XCTAssertEqual(vm.assigneeOptions.map(\.id), ["member:u1", "agent:a1", "squad:s1"])
        XCTAssertEqual(vm.assigneeOptions.map(\.displayName), ["Parker", "Codex", "Design Squad"])
        XCTAssertEqual(vm.quickCreateAgentOptions.map(\.assigneeId), ["a1"])
        XCTAssertEqual(vm.selectedQuickCreateAgentId, "a1")
        XCTAssertEqual(vm.projects.map(\.id), ["p1"])
        XCTAssertNil(vm.errorMessage)
    }

    func test_quickCreateRequiresWorkspacePromptAndAgentBeforeCallingBackend() async throws {
        var didRequest = false
        let client = makeClient { req in
            didRequest = true
            return Self.response(for: req, body: Data(#"{"task_id":"task1"}"#.utf8))
        }
        let vmWithoutWorkspace = IssueCreateViewModel(api: client, authSession: makeSession(includeWorkspace: false))

        let missingWorkspace = await vmWithoutWorkspace.submitQuickCreate()
        XCTAssertFalse(missingWorkspace)
        XCTAssertEqual(vmWithoutWorkspace.errorMessage, "Pick a workspace before creating with an agent.")

        let vm = IssueCreateViewModel(api: client, authSession: makeSession())
        vm.quickCreatePrompt = "   "
        let missingPrompt = await vm.submitQuickCreate()
        XCTAssertFalse(missingPrompt)
        XCTAssertEqual(vm.errorMessage, "Describe what the agent should create.")

        vm.quickCreatePrompt = "Create this"
        vm.selectedQuickCreateAgentId = nil
        let missingAgent = await vm.submitQuickCreate()
        XCTAssertFalse(missingAgent)
        XCTAssertEqual(vm.errorMessage, "Pick an agent before creating with agent.")
        XCTAssertFalse(didRequest)
    }

    func test_quickCreateTrimsPromptAndStoresTaskResult() async throws {
        var capturedBody: [String: Any]?
        let client = makeClient { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/api/issues/quick-create")
            XCTAssertEqual(req.url?.query, "workspace_id=w1")
            capturedBody = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
            return Self.response(for: req, body: Data(#"{"task_id":"task1"}"#.utf8))
        }
        let vm = IssueCreateViewModel(api: client, authSession: makeSession())
        vm.quickCreatePrompt = "  **Create** issue from prompt  "
        vm.selectedQuickCreateAgentId = "a1"

        let submitted = await vm.submitQuickCreate()

        XCTAssertTrue(submitted)
        XCTAssertEqual(capturedBody?["agent_id"] as? String, "a1")
        XCTAssertEqual(capturedBody?["prompt"] as? String, "**Create** issue from prompt")
        XCTAssertEqual(vm.quickCreateTaskId, "task1")
        XCTAssertEqual(vm.quickCreateSuccessMessage, "Sent to agent. You'll get an inbox notification when it's done.")
        XCTAssertEqual(vm.quickCreatePrompt, "")
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isQuickCreating)
    }

    func test_loadOptions_paginatesProjectChoices() async throws {
        var projectOffsets: [String?] = []
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/agents":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            case "/api/projects":
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let offset = components?.queryItems?.first(where: { $0.name == "offset" })?.value ?? "0"
                projectOffsets.append(offset)
                let title = offset == "0" ? "First page" : "Second page"
                let id = offset == "0" ? "p1" : "p2"
                let json = """
                {"projects":[{
                    "id":"\(id)","workspace_id":"w1","title":"\(title)","description":null,
                    "icon":null,"status":"in_progress","priority":"none",
                    "lead_type":null,"lead_id":null,
                    "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
                    "issue_count":2,"done_count":1
                }],"total":2}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueCreateViewModel(api: client, authSession: makeSession())

        await vm.loadOptions()

        XCTAssertEqual(projectOffsets, ["0", "1"])
        XCTAssertEqual(vm.projects.map { $0.id }, ["p1", "p2"])
        XCTAssertNil(vm.errorMessage)
    }

    func test_submitSendsSelectedDesktopFields() async throws {
        let dueDate = Date(timeIntervalSince1970: 1_778_025_600)
        var body: [String: Any] = [:]
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            let json = """
            {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":"D",
             "status":"in_review","priority":"urgent","assignee_id":"a1","assignee_type":"agent",
             "project_id":"p1","workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
             "updated_at":"2026-01-01T00:00:00Z"}
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueCreateViewModel(api: client, authSession: makeSession())
        vm.title = " T "
        vm.description = " D "
        vm.status = .inReview
        vm.priority = .urgent
        vm.assigneeOptions = [
            IssueAssigneeOption(id: "agent:a1", type: "agent", assigneeId: "a1", displayName: "Codex", subtitle: "Agent")
        ]
        vm.selectedAssigneeOptionId = "agent:a1"
        vm.projects = [Project(id: "p1", name: "iOS MVP", description: nil, workspaceId: "w1", createdAt: Date())]
        vm.selectedProjectId = "p1"
        vm.includesDueDate = true
        vm.dueDate = dueDate

        let created = await vm.submit()

        XCTAssertTrue(created)
        XCTAssertEqual(body["title"] as? String, "T")
        XCTAssertEqual(body["description"] as? String, "D")
        XCTAssertEqual(body["workspace_id"] as? String, "w1")
        XCTAssertEqual(body["status"] as? String, "in_review")
        XCTAssertEqual(body["priority"] as? String, "urgent")
        XCTAssertEqual(body["assignee_type"] as? String, "agent")
        XCTAssertEqual(body["assignee_id"] as? String, "a1")
        XCTAssertEqual(body["project_id"] as? String, "p1")
        XCTAssertEqual(body["due_date"] as? String, "2026-05-06T00:00:00Z")
        XCTAssertNil(vm.errorMessage)
    }

    func test_submitUsesUserIdForMemberAssignee() async throws {
        var body: [String: Any] = [:]
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            let json = """
            {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
             "status":"todo","priority":"none","assignee_id":"u1","assignee_type":"member",
             "project_id":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
             "updated_at":"2026-01-01T00:00:00Z"}
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueCreateViewModel(api: client, authSession: makeSession())
        vm.title = "Assign to member"
        vm.assigneeOptions = [
            IssueAssigneeOption(
                id: "member:u1",
                type: "member",
                assigneeId: "u1",
                displayName: "Parker",
                subtitle: "p@example.com"
            )
        ]
        vm.selectedAssigneeOptionId = "member:u1"

        let created = await vm.submit()

        XCTAssertTrue(created)
        XCTAssertEqual(body["assignee_type"] as? String, "member")
        XCTAssertEqual(body["assignee_id"] as? String, "u1")
        XCTAssertFalse(body.values.contains { ($0 as? String) == "m1" }, "Create Issue should use user_id for member assignees, not workspace member id.")
        XCTAssertNil(vm.errorMessage)
    }

    func test_submitIncludesParentIssueIdForSubIssueCreation() async throws {
        var body: [String: Any] = [:]
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            let json = """
            {"id":"c1","identifier":"PAR-2","number":2,"title":"Child","description":null,
             "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
             "parent_issue_id":"p0","project_id":null,"workspace_id":"w1",
             "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueCreateViewModel(api: client, authSession: makeSession(), parentIssueId: "p0")
        vm.title = "Child"

        let created = await vm.submit()

        XCTAssertTrue(created)
        XCTAssertEqual(body["parent_issue_id"] as? String, "p0")
        XCTAssertNil(vm.errorMessage)
    }

    func test_uploadAttachmentAndSubmitIncludesAttachmentIds() async throws {
        var requests: [String] = []
        var createBody: [String: Any] = [:]
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/upload-file"):
                let body = String(data: MockURLProtocol.bodyData(for: req), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains(#"name="file"; filename="spec.md""#))
                XCTAssertTrue(body.contains("Attachment body"))
                let json = """
                {"id":"att1","workspace_id":"w1","issue_id":null,"comment_id":null,
                 "uploader_type":"member","uploader_id":"u1","filename":"spec.md",
                 "url":"https://cdn.example/spec.md","download_url":"https://cdn.example/spec.md",
                 "content_type":"text/markdown","size_bytes":15,"created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("POST", "/api/issues"):
                createBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                let json = """
                {"id":"i1","identifier":"PAR-1","number":1,"title":"With attachment","description":null,
                 "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
                 "project_id":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueCreateViewModel(api: client, authSession: makeSession())
        vm.title = "With attachment"

        let uploaded = await vm.uploadAttachment(
            filename: "spec.md",
            data: Data("Attachment body".utf8),
            contentType: "text/markdown"
        )
        let created = await vm.submit()

        XCTAssertTrue(uploaded)
        XCTAssertTrue(created)
        XCTAssertEqual(vm.attachments.map(\.id), ["att1"])
        XCTAssertEqual(createBody["attachment_ids"] as? [String], ["att1"])
        XCTAssertEqual(requests, ["POST /api/upload-file", "POST /api/issues"])
        XCTAssertNil(vm.errorMessage)
    }

    private func makeSession(workspace override: Workspace? = nil, includeWorkspace: Bool = true) -> AuthSession {
        let session = AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.issue-create.test"))
        guard includeWorkspace else {
            session.currentWorkspace = nil
            session.workspaces = []
            return session
        }
        let currentWorkspace = override ?? workspace
        session.currentWorkspace = currentWorkspace
        session.workspaces = [currentWorkspace]
        return session
    }

    private func makeClient(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            switch req.url?.path {
            case "/api/runtimes", "/api/agent-task-snapshot":
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            default:
                return try handler(req)
            }
        }
        return APIClient(session: URLSession(configuration: config), token: "test-token")
    }

    private static func response(
        for request: URLRequest,
        body: Data,
        status: Int = 200
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
            body
        )
    }
}
