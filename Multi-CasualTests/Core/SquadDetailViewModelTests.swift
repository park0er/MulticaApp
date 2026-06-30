import XCTest
@testable import MultiCasual

@MainActor
final class SquadDetailViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func test_loadFetchesSquadMembersAgentsAndWorkspaceMembers() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/squads/s1":
                return Self.response(for: req, body: Self.squadJSON())
            case "/api/squads/s1/members":
                return Self.response(for: req, body: Self.membersJSON())
            case "/api/agents":
                return Self.response(for: req, body: Self.agentsJSON())
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/squads/s1/members/status":
                return Self.response(for: req, body: Self.statusJSON())
            default:
                XCTFail("Unexpected: \(req.url?.path ?? "")")
                return Self.response(for: req, body: Data(), status: 404)
            }
        }
        let vm = SquadDetailViewModel(squad: Self.seedSquad(), api: client, authSession: makeSession())

        await vm.load()

        XCTAssertEqual(vm.members.map(\.memberId), ["a1"])
        XCTAssertEqual(vm.members.first?.role, "leader, can also review")
        XCTAssertEqual(vm.entityName(type: "agent", id: "a1"), "Codex")
        XCTAssertTrue(vm.isLeader(vm.members[0]))
        XCTAssertEqual(vm.status(for: vm.members[0])?.status, "working")
        XCTAssertEqual(vm.status(for: vm.members[0])?.activeIssues.first?.identifier, "PAR-1")
        XCTAssertNil(vm.errorMessage)
    }
    func test_updateMemberRoleEditsDescriptionAndReloads() async throws {
        var patched: [String: Any]?
        var memberListCalls = 0
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/squads/s1"):
                return Self.response(for: req, body: Self.squadJSON())
            case ("GET", "/api/squads/s1/members"):
                memberListCalls += 1
                let role = memberListCalls == 1 ? "old" : "技术能力比 mimo 更强"
                return Self.response(for: req, body: Self.membersJSON(role: role))
            case ("GET", "/api/agents"):
                return Self.response(for: req, body: Self.agentsJSON())
            case ("GET", "/api/workspaces/w1/members"):
                return Self.response(for: req, body: Data("[]".utf8))
            case ("GET", "/api/squads/s1/members/status"):
                return Self.response(for: req, body: Self.statusJSON())
            case ("PATCH", "/api/squads/s1/members/role"):
                patched = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
                return Self.response(for: req, body: Self.membersJSON(role: "技术能力比 mimo 更强").dropArray())
            default:
                XCTFail("Unexpected: \(req.httpMethod ?? "") \(req.url?.path ?? "")")
                return Self.response(for: req, body: Data(), status: 404)
            }
        }
        let vm = SquadDetailViewModel(squad: Self.seedSquad(), api: client, authSession: makeSession())
        await vm.load()

        await vm.updateMemberRole(vm.members[0], role: "技术能力比 mimo 更强")

        XCTAssertEqual(patched?["role"] as? String, "技术能力比 mimo 更强")
        XCTAssertEqual(patched?["member_id"] as? String, "a1")
        XCTAssertEqual(vm.members.first?.role, "技术能力比 mimo 更强")
        XCTAssertNil(vm.errorMessage)
    }

    func test_addMemberPostsRoleAndReloads() async throws {
        var posted: [String: Any]?
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/squads/s1"):
                return Self.response(for: req, body: Self.squadJSON())
            case ("GET", "/api/squads/s1/members"):
                return Self.response(for: req, body: Self.membersJSON())
            case ("GET", "/api/agents"):
                return Self.response(for: req, body: Self.agentsJSON())
            case ("GET", "/api/workspaces/w1/members"):
                return Self.response(for: req, body: Data("[]".utf8))
            case ("GET", "/api/squads/s1/members/status"):
                return Self.response(for: req, body: Self.statusJSON())
            case ("POST", "/api/squads/s1/members"):
                posted = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
                return Self.response(for: req, body: #"{"member_type":"member","member_id":"u2","role":"helper"}"#.data(using: .utf8)!)
            default:
                XCTFail("Unexpected: \(req.httpMethod ?? "") \(req.url?.path ?? "")")
                return Self.response(for: req, body: Data(), status: 404)
            }
        }
        let vm = SquadDetailViewModel(squad: Self.seedSquad(), api: client, authSession: makeSession())
        await vm.load()

        await vm.addMember(type: "member", id: "u2", role: "helper")

        XCTAssertEqual(posted?["member_type"] as? String, "member")
        XCTAssertEqual(posted?["member_id"] as? String, "u2")
        XCTAssertEqual(posted?["role"] as? String, "helper")
        XCTAssertNil(vm.errorMessage)
    }

    func test_setLeaderUpdatesSquad() async throws {
        var put: [String: Any]?
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/squads/s1"):
                return Self.response(for: req, body: Self.squadJSON())
            case ("GET", "/api/squads/s1/members"):
                return Self.response(for: req, body: Self.membersJSON())
            case ("GET", "/api/agents"):
                return Self.response(for: req, body: Self.agentsJSON())
            case ("GET", "/api/workspaces/w1/members"):
                return Self.response(for: req, body: Data("[]".utf8))
            case ("GET", "/api/squads/s1/members/status"):
                return Self.response(for: req, body: Self.statusJSON())
            case ("PUT", "/api/squads/s1"):
                put = try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]
                return Self.response(for: req, body: Self.squadJSON(leaderId: "a9"))
            default:
                XCTFail("Unexpected: \(req.httpMethod ?? "") \(req.url?.path ?? "")")
                return Self.response(for: req, body: Data(), status: 404)
            }
        }
        let vm = SquadDetailViewModel(squad: Self.seedSquad(), api: client, authSession: makeSession())
        await vm.load()

        await vm.setLeader(agentId: "a9")

        XCTAssertEqual(put?["leader_id"] as? String, "a9")
        XCTAssertEqual(vm.squad.leaderId, "a9")
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Helpers

    private static func seedSquad() -> Squad {
        Squad(id: "s1", workspaceId: "w1", name: "Research", leaderId: "a1")
    }

    private func makeSession() -> AuthSession {
        let session = AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.squad-detail.test"))
        let workspace = Workspace(id: "w1", name: "Workspace", slug: "workspace", issuePrefix: "W")
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

    private static func response(for request: URLRequest, body: Data, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
    }

    private static func squadJSON(leaderId: String = "a1") -> Data {
        """
        {"id":"s1","workspace_id":"w1","name":"Research","description":"","instructions":"",
         "avatar_url":null,"leader_id":"\(leaderId)","agent_ids":[],"member_ids":[],
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","archived_at":null}
        """.data(using: .utf8)!
    }

    private static func membersJSON(role: String = "leader, can also review") -> Data {
        """
        [{"id":"sm1","squad_id":"s1","member_type":"agent","member_id":"a1","role":"\(role)","created_at":"2026-01-01T00:00:00Z"}]
        """.data(using: .utf8)!
    }

    private static func statusJSON() -> Data {
        """
        {"members":[{"member_type":"agent","member_id":"a1","status":"working",
          "active_issues":[{"issue_id":"i1","identifier":"PAR-1","title":"Do work","issue_status":"in_progress"}],
          "last_active_at":"2026-01-01T00:00:00Z"}]}
        """.data(using: .utf8)!
    }

    private static func agentsJSON() -> Data {
        """
        [{"id":"a1","workspace_id":"w1","runtime_id":"r1","name":"Codex",
          "description":"Agent","instructions":"","avatar_url":null,
          "runtime_mode":"cloud","runtime_config":{},"custom_env":{},"custom_args":[],
          "custom_env_redacted":false,"visibility":"workspace","status":"active",
          "max_concurrent_tasks":1,"model":"gpt","owner_id":null,"skills":[],
          "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
          "archived_at":null,"archived_by":null}]
        """.data(using: .utf8)!
    }
}

private extension Data {
    /// Turn a one-element JSON array body into the single-object body, for
    /// endpoints that return the object rather than the list.
    func dropArray() -> Data {
        guard let s = String(data: self, encoding: .utf8) else { return self }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return self }
        return Data(trimmed.dropFirst().dropLast().utf8)
    }
}
