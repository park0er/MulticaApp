import XCTest
@testable import MultiCasual

@MainActor
final class SquadsViewModelTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func test_loadFetchesSquadsAndAgentsForCurrentWorkspace() async throws {
        var paths: [String] = []
        let client = makeClient { req in
            paths.append(req.url?.path ?? "")
            switch req.url?.path {
            case "/api/squads":
                XCTAssertEqual(req.url?.query, "workspace_id=w1")
                return Self.response(for: req, body: Self.squadsArrayJSON())
            case "/api/agents":
                return Self.response(for: req, body: Self.agentsArrayJSON())
            default:
                XCTFail("Unexpected request: \(req.url?.path ?? "")")
                return Self.response(for: req, body: Data(), status: 404)
            }
        }
        let vm = SquadsViewModel(api: client, authSession: makeSession())

        await vm.load()

        XCTAssertEqual(vm.squads.map(\.id), ["s1"])
        XCTAssertEqual(vm.agents.map(\.id), ["a1"])
        XCTAssertEqual(vm.leaderName(for: vm.squads[0]), "Codex")
        XCTAssertTrue(paths.contains("/api/squads"))
        XCTAssertTrue(paths.contains("/api/agents"))
        XCTAssertNil(vm.errorMessage)
    }

    func test_createUpdateAndDeleteKeepListInSync() async throws {
        var requests: [String] = []
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/squads"):
                return Self.response(for: req, body: Self.squadJSON(id: "s2", name: "Mobile", leaderId: "a1"))
            case ("PUT", "/api/squads/s1"):
                return Self.response(for: req, body: Self.squadJSON(id: "s1", name: "Renamed", leaderId: "a1"))
            case ("DELETE", "/api/squads/s2"):
                return Self.response(for: req, body: Data(), status: 204)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data(), status: 404)
            }
        }
        let vm = SquadsViewModel(api: client, authSession: makeSession())

        let created = await vm.createSquad(name: " Mobile ", description: "iOS", leaderId: "a1", avatarUrl: nil)
        let updated = await vm.updateSquad(id: "s1", name: "Renamed", description: "", instructions: "x", leaderId: "a1")
        await vm.deleteSquad(id: "s2")

        XCTAssertEqual(created?.id, "s2")
        XCTAssertEqual(updated?.name, "Renamed")
        XCTAssertEqual(vm.squads.map(\.id), ["s1"])
        XCTAssertEqual(requests, [
            "POST /api/squads",
            "PUT /api/squads/s1",
            "DELETE /api/squads/s2",
        ])
        XCTAssertNil(vm.errorMessage)
    }

    func test_createRequiresLeaderAndName() async {
        var didRequest = false
        let client = makeClient { req in
            didRequest = true
            return Self.response(for: req, body: Data(), status: 500)
        }
        let vm = SquadsViewModel(api: client, authSession: makeSession())

        let missingLeader = await vm.createSquad(name: "Team", description: "", leaderId: "", avatarUrl: nil)
        XCTAssertNil(missingLeader)
        XCTAssertEqual(vm.errorMessage, "Pick a leader agent for the squad.")

        let missingName = await vm.createSquad(name: "  ", description: "", leaderId: "a1", avatarUrl: nil)
        XCTAssertNil(missingName)
        XCTAssertEqual(vm.errorMessage, "Enter a squad name.")

        XCTAssertFalse(didRequest)
    }

    func test_missingWorkspaceShowsActionableErrorAndSkipsRequest() async {
        var didRequest = false
        let client = makeClient { req in
            didRequest = true
            return Self.response(for: req, body: Data(), status: 500)
        }
        let vm = SquadsViewModel(api: client, authSession: AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.squads.empty.test")))

        await vm.load()

        XCTAssertFalse(didRequest)
        XCTAssertEqual(vm.errorMessage, "Pick a workspace before managing squads.")
    }

    private func makeSession() -> AuthSession {
        let session = AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.squads.test"))
        let workspace = Workspace(id: "w1", name: "Workspace", slug: "workspace", issuePrefix: "W")
        session.currentWorkspace = workspace
        session.workspaces = [workspace]
        return session
    }

    private func makeClient(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = handler
        return APIClient(session: URLSession(configuration: config), token: "test-token")
    }

    private static func response(for request: URLRequest, body: Data, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
    }

    private static func squadJSON(id: String, name: String, leaderId: String) -> Data {
        """
        {"id":"\(id)","workspace_id":"w1","name":"\(name)","description":"",
         "instructions":"","avatar_url":null,"leader_id":"\(leaderId)",
         "agent_ids":[],"member_ids":[],
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","archived_at":null}
        """.data(using: .utf8)!
    }

    private static func squadsArrayJSON() -> Data {
        Data("[\(String(data: squadJSON(id: "s1", name: "Design", leaderId: "a1"), encoding: .utf8)!)]".utf8)
    }

    private static func agentsArrayJSON() -> Data {
        """
        [{"id":"a1","workspace_id":"w1","runtime_id":"r1","name":"Codex",
          "description":"Agent","instructions":"Do work","avatar_url":null,
          "runtime_mode":"cloud","runtime_config":{},"custom_env":{},"custom_args":[],
          "custom_env_redacted":false,"visibility":"workspace","status":"active",
          "max_concurrent_tasks":1,"model":"gpt","owner_id":null,"skills":[],
          "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z",
          "archived_at":null,"archived_by":null}]
        """.data(using: .utf8)!
    }
}
