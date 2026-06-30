import XCTest
@testable import MultiCasual

@MainActor
final class IssueEditViewModelTests: XCTestCase {
    private let workspace = Workspace(id: "w1", name: "Workspace", slug: "workspace", issuePrefix: "PAR")

    func test_loadOptionsBuildsAssigneeAndProjectChoicesAndKeepsCurrentSelections() async throws {
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
            case "/api/labels":
                let json = """
                {"labels":[{
                    "id":"l1","workspace_id":"w1","name":"bug","color":"#ef4444",
                    "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"
                }],"total":1}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let selectedLabel = IssueLabel(
            id: "l1",
            workspaceId: "w1",
            name: "bug",
            color: "#ef4444",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let vm = IssueEditViewModel(
            issue: issue(assigneeType: "agent", assigneeId: "a1", projectId: "p1", labels: [selectedLabel]),
            api: client,
            authSession: makeSession()
        )

        await vm.loadOptions()

        XCTAssertEqual(vm.assigneeOptions.map(\.id), ["member:u1", "agent:a1"])
        XCTAssertEqual(vm.selectedAssigneeOptionId, "agent:a1")
        XCTAssertEqual(vm.projects.map(\.id), ["p1"])
        XCTAssertEqual(vm.selectedProjectId, "p1")
        XCTAssertEqual(vm.labels.map(\.id), ["l1"])
        XCTAssertEqual(vm.selectedLabelIds, ["l1"])
        XCTAssertNil(vm.errorMessage)
    }

    func test_loadOptionsKeepsAssigneeChoicesWhenSecondaryOptionsFail() async throws {
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
            case "/api/projects", "/api/labels":
                return Self.response(for: req, body: Data(#"{"error":"temporary failure"}"#.utf8), status: 500)
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueEditViewModel(
            issue: issue(assigneeType: nil, assigneeId: nil, projectId: nil),
            api: client,
            authSession: makeSession()
        )

        await vm.loadOptions()

        XCTAssertEqual(vm.assigneeOptions.map(\.id), ["member:u1", "agent:a1"])
        XCTAssertNil(vm.selectedAssignee)
        XCTAssertEqual(vm.selectedAssigneeOptionId, IssueEditViewModel.noAssigneeId)
        XCTAssertEqual(vm.projects.map(\.id), [])
        XCTAssertEqual(vm.labels.map(\.id), [])
        XCTAssertEqual(vm.errorMessage, "Some workspace options could not be loaded.")
    }

    func test_submitSyncsIssueLabelsAndReturnsUpdatedLabels() async throws {
        var requests: [(String, String)] = []
        let client = makeClient { req in
            requests.append((req.httpMethod ?? "", req.url?.path ?? ""))
            switch (req.httpMethod, req.url?.path) {
            case ("PUT", "/api/issues/i1"):
                let json = """
                {"id":"i1","identifier":"PAR-1","number":1,"title":"Original","description":"Body",
                 "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
                 "project_id":null,"due_date":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-02T00:00:00Z","labels":[]}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("POST", "/api/issues/i1/labels"):
                let json = """
                {"labels":[{"id":"l2","workspace_id":"w1","name":"feature","color":"#22c55e",
                 "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("DELETE", "/api/issues/i1/labels/l1"):
                let json = """
                {"labels":[{"id":"l2","workspace_id":"w1","name":"feature","color":"#22c55e",
                 "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let original = IssueLabel(
            id: "l1",
            workspaceId: "w1",
            name: "bug",
            color: "#ef4444",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let replacement = IssueLabel(
            id: "l2",
            workspaceId: "w1",
            name: "feature",
            color: "#22c55e",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let vm = IssueEditViewModel(
            issue: issue(assigneeType: nil, assigneeId: nil, projectId: nil, labels: [original]),
            api: client,
            authSession: makeSession()
        )
        vm.labels = [original, replacement]
        vm.selectedLabelIds = ["l2"]

        let updated = await vm.submit()

        XCTAssertEqual(updated?.labels.map(\.id), ["l2"])
        XCTAssertEqual(requests.map { "\($0.0) \($0.1)" }, [
            "PUT /api/issues/i1",
            "POST /api/issues/i1/labels",
            "DELETE /api/issues/i1/labels/l1",
        ])
        XCTAssertNil(vm.errorMessage)
    }

    func test_submitUpdatesIssueAndCanClearAssigneeAndProject() async throws {
        var body: [String: Any] = [:]
        let client = makeClient { req in
            XCTAssertEqual(req.httpMethod, "PUT")
            XCTAssertEqual(req.url?.path, "/api/issues/i1")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            let json = """
            {"id":"i1","identifier":"PAR-1","number":1,"title":"Updated","description":null,
             "status":"in_review","priority":"urgent","assignee_id":null,"assignee_type":null,
             "project_id":null,"due_date":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
             "updated_at":"2026-01-02T00:00:00Z"}
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueEditViewModel(issue: issue(assigneeType: "member", assigneeId: "u1", projectId: "p1"), api: client, authSession: makeSession())
        vm.title = " Updated "
        vm.description = " \n "
        vm.status = .inReview
        vm.priority = .urgent
        vm.selectedAssigneeOptionId = IssueEditViewModel.noAssigneeId
        vm.selectedProjectId = IssueEditViewModel.noProjectId
        vm.includesDueDate = false

        let updated = await vm.submit()

        XCTAssertEqual(updated?.title, "Updated")
        XCTAssertEqual(body["title"] as? String, "Updated")
        XCTAssertTrue(body["description"] is NSNull)
        XCTAssertEqual(body["status"] as? String, "in_review")
        XCTAssertEqual(body["priority"] as? String, "urgent")
        XCTAssertTrue(body["assignee_type"] is NSNull)
        XCTAssertTrue(body["assignee_id"] is NSNull)
        XCTAssertTrue(body["project_id"] is NSNull)
        XCTAssertTrue(body["due_date"] is NSNull)
        XCTAssertNil(vm.errorMessage)
    }

    func test_submitCanReassignIssueToDifferentMember() async throws {
        var body: [String: Any] = [:]
        let client = makeClient { req in
            XCTAssertEqual(req.httpMethod, "PUT")
            XCTAssertEqual(req.url?.path, "/api/issues/i1")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            let json = """
            {"id":"i1","identifier":"PAR-1","number":1,"title":"Original","description":"Body",
             "status":"todo","priority":"none","assignee_id":"u2","assignee_type":"member",
             "project_id":null,"due_date":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
             "updated_at":"2026-01-02T00:00:00Z"}
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueEditViewModel(issue: issue(assigneeType: "member", assigneeId: "u1", projectId: nil), api: client, authSession: makeSession())
        vm.assigneeOptions = [
            IssueAssigneeOption(id: "member:u1", type: "member", assigneeId: "u1", displayName: "Parker", subtitle: "p@example.com"),
            IssueAssigneeOption(id: "member:u2", type: "member", assigneeId: "u2", displayName: "Alice", subtitle: "a@example.com"),
        ]
        vm.selectedAssigneeOptionId = "member:u2"

        let updated = await vm.submit()

        XCTAssertEqual(updated?.assigneeType, "member")
        XCTAssertEqual(updated?.assigneeId, "u2")
        XCTAssertEqual(body["assignee_type"] as? String, "member")
        XCTAssertEqual(body["assignee_id"] as? String, "u2")
        XCTAssertNil(vm.errorMessage)
    }

    func test_submitCanReassignIssueToAgent() async throws {
        var body: [String: Any] = [:]
        let client = makeClient { req in
            XCTAssertEqual(req.httpMethod, "PUT")
            XCTAssertEqual(req.url?.path, "/api/issues/i1")
            body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
            let json = """
            {"id":"i1","identifier":"PAR-1","number":1,"title":"Original","description":"Body",
             "status":"todo","priority":"none","assignee_id":"a1","assignee_type":"agent",
             "project_id":null,"due_date":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
             "updated_at":"2026-01-02T00:00:00Z"}
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueEditViewModel(issue: issue(assigneeType: "member", assigneeId: "u1", projectId: nil), api: client, authSession: makeSession())
        vm.assigneeOptions = [
            IssueAssigneeOption(id: "member:u1", type: "member", assigneeId: "u1", displayName: "Parker", subtitle: "p@example.com"),
            IssueAssigneeOption(id: "agent:a1", type: "agent", assigneeId: "a1", displayName: "Codex", subtitle: "Agent"),
        ]
        vm.selectedAssigneeOptionId = "agent:a1"

        let updated = await vm.submit()

        XCTAssertEqual(updated?.assigneeType, "agent")
        XCTAssertEqual(updated?.assigneeId, "a1")
        XCTAssertEqual(body["assignee_type"] as? String, "agent")
        XCTAssertEqual(body["assignee_id"] as? String, "a1")
        XCTAssertNil(vm.errorMessage)
    }

    func test_submitPreservesExistingAssigneeAndProjectWhenOptionsFailToLoad() async throws {
        var body: [String: Any] = [:]
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/issues/i1":
                XCTAssertEqual(req.httpMethod, "PUT")
                body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                let json = """
                {"id":"i1","identifier":"PAR-1","number":1,"title":"Renamed","description":"Body",
                 "status":"todo","priority":"none","assignee_id":"a1","assignee_type":"agent",
                 "project_id":"p1","due_date":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-02T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueEditViewModel(issue: issue(assigneeType: "agent", assigneeId: "a1", projectId: "p1"), api: client, authSession: makeSession())
        vm.title = "Renamed"
        vm.assigneeOptions = []
        vm.projects = []

        let updated = await vm.submit()

        XCTAssertEqual(updated?.assigneeType, "agent")
        XCTAssertEqual(updated?.assigneeId, "a1")
        XCTAssertEqual(updated?.projectId, "p1")
        XCTAssertEqual(body["assignee_type"] as? String, "agent")
        XCTAssertEqual(body["assignee_id"] as? String, "a1")
        XCTAssertEqual(body["project_id"] as? String, "p1")
        XCTAssertNil(vm.errorMessage)
    }

    private func issue(
        assigneeType: String?,
        assigneeId: String?,
        projectId: String?,
        labels: [IssueLabel] = []
    ) -> Issue {
        Issue(
            id: "i1",
            identifier: "PAR-1",
            number: 1,
            title: "Original",
            description: "Body",
            status: .todo,
            priority: .noPriority,
            assigneeId: assigneeId,
            assigneeType: assigneeType,
            projectId: projectId,
            workspaceId: "w1",
            labels: labels,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeSession() -> AuthSession {
        let session = AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.issue-edit.test"))
        session.currentWorkspace = workspace
        session.workspaces = [workspace]
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
