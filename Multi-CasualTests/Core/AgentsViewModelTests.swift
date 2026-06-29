import XCTest
@testable import MultiCasual

@MainActor
final class AgentsViewModelTests: XCTestCase {
    private let workspace = Workspace(id: "w1", name: "Workspace", slug: "workspace", issuePrefix: "PAR")

    func test_loadFetchesArchivedAgentsAndRuntimes() async throws {
        var requestURLs: [URL] = []
        let client = makeClient { req in
            requestURLs.append(req.url!)
            switch req.url?.path {
            case "/api/agents":
                XCTAssertTrue(req.url?.absoluteString.contains("include_archived=true") ?? false)
                return Self.response(for: req, body: Self.agentListJSON())
            case "/api/runtimes":
                return Self.response(for: req, body: Self.runtimeListJSON())
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Self.membersJSON())
            case "/api/agent-task-snapshot":
                return Self.response(for: req, body: Self.agentTasksJSON())
            case "/api/agent-run-counts":
                return Self.response(for: req, body: Self.agentRunCountsJSON())
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = AgentsViewModel(api: client, authSession: makeSession())

        await vm.load()

        XCTAssertEqual(vm.agents.map(\.id), ["a1"])
        XCTAssertEqual(vm.runtimes.map(\.id), ["r1"])
        XCTAssertEqual(vm.presenceByAgentId["a1"]?.availability, .online)
        XCTAssertEqual(vm.presenceByAgentId["a1"]?.workload, .working)
        XCTAssertEqual(vm.presenceByAgentId["a1"]?.runningCount, 1)
        XCTAssertEqual(vm.runCountsByAgentId["a1"], 7)
        XCTAssertTrue(requestURLs.allSatisfy { $0.absoluteString.contains("workspace_id=w1") })
        XCTAssertNil(vm.errorMessage)
    }

    func test_agentsSplitActiveAndArchivedForListPresentation() throws {
        let active = Self.makeAgent(id: "a1", name: "Active", avatarUrl: nil)
        let archived = Self.makeAgent(
            id: "a2",
            name: "Archived",
            avatarUrl: nil,
            archivedAt: "2026-05-14T00:00:00Z"
        )
        let vm = AgentsViewModel(api: makeClient { req in
            XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
            return Self.response(for: req, body: Data("{}".utf8), status: 404)
        }, authSession: makeSession())
        vm.agents = [archived, active]

        XCTAssertEqual(vm.activeAgents.map(\.id), ["a1"])
        XCTAssertEqual(vm.archivedAgents.map(\.id), ["a2"])
    }

    func test_createAndUpdateReplaceAgentInList() async throws {
        var requests: [(String, String)] = []
        var requestURLs: [URL] = []
        var bodies: [[String: Any]] = []
        let client = makeClient { req in
            requests.append((req.httpMethod ?? "", req.url?.path ?? ""))
            requestURLs.append(req.url!)
            bodies.append((try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]) ?? [:])
            let name = req.httpMethod == "POST" ? "Created" : "Updated"
            return Self.response(for: req, body: Self.agentJSON(id: "a1", name: name))
        }
        let vm = AgentsViewModel(api: client, authSession: makeSession())

        let created = await vm.createAgent(
            name: "Created",
            description: "",
            instructions: "",
            runtimeId: "r1",
            visibility: "workspace",
            maxConcurrentTasks: 1,
            model: "gpt",
            avatarUrl: "https://cdn.example/agents/created.png",
            customEnv: ["ANTHROPIC_BASE_URL": "https://example.com"],
            customArgs: ["--verbose"]
        )
        let updated = await vm.updateAgent(
            id: "a1",
            name: "Updated",
            description: "D",
            instructions: "I",
            runtimeId: "r2",
            visibility: "private",
            maxConcurrentTasks: 2,
            model: "gpt-5",
            avatarUrl: "https://cdn.example/agents/updated.png",
            customEnv: ["OPENAI_API_KEY": "sk-test"],
            customArgs: ["--debug"]
        )

        XCTAssertEqual(created?.name, "Created")
        XCTAssertEqual(updated?.name, "Updated")
        XCTAssertEqual(vm.agents.map(\.name), ["Updated"])
        XCTAssertEqual(requests.map { "\($0.0) \($0.1)" }, ["POST /api/agents", "PUT /api/agents/a1"])
        XCTAssertTrue(requestURLs.allSatisfy { $0.absoluteString.contains("workspace_id=w1") })
        XCTAssertEqual(bodies[0]["avatar_url"] as? String, "https://cdn.example/agents/created.png")
        XCTAssertEqual((bodies[0]["custom_env"] as? [String: String])?["ANTHROPIC_BASE_URL"], "https://example.com")
        XCTAssertEqual(bodies[0]["custom_args"] as? [String], ["--verbose"])
        XCTAssertEqual(bodies[1]["runtime_id"] as? String, "r2")
        XCTAssertEqual(bodies[1]["avatar_url"] as? String, "https://cdn.example/agents/updated.png")
        XCTAssertEqual((bodies[1]["custom_env"] as? [String: String])?["OPENAI_API_KEY"], "sk-test")
        XCTAssertEqual(bodies[1]["custom_args"] as? [String], ["--debug"])
        XCTAssertNil(vm.errorMessage)
    }

    func test_uploadAvatarUploadsFileAndUpdatesAgentAvatarURL() async throws {
        var requests: [(String, String)] = []
        var updateBody: [String: Any] = [:]
        let client = makeClient { req in
            requests.append((req.httpMethod ?? "", req.url?.path ?? ""))
            XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/upload-file"):
                XCTAssertTrue(req.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") ?? false)
                return Self.response(for: req, body: Self.attachmentJSON(url: "https://cdn.example/avatar.png"))
            case ("PUT", "/api/agents/a1"):
                updateBody = (try? JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any]) ?? [:]
                return Self.response(for: req, body: Self.agentJSON(id: "a1", name: "Codex", avatarUrl: "https://cdn.example/avatar.png"))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = AgentsViewModel(api: client, authSession: makeSession())
        let agent = Self.makeAgent(id: "a1", name: "Codex", avatarUrl: nil)
        vm.agents = [agent]

        let updated = await vm.uploadAvatar(
            for: agent,
            filename: "avatar.png",
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            contentType: "image/png"
        )

        XCTAssertEqual(requests.map { "\($0.0) \($0.1)" }, ["POST /api/upload-file", "PUT /api/agents/a1"])
        XCTAssertEqual(updated?.avatarUrl, "https://cdn.example/avatar.png")
        XCTAssertEqual(vm.agents.first?.avatarUrl, "https://cdn.example/avatar.png")
        XCTAssertEqual(updateBody["avatar_url"] as? String, "https://cdn.example/avatar.png")
        XCTAssertNil(vm.errorMessage)
    }

    func test_agentPermissionsMatchDesktopOwnerOrWorkspaceAdmin() async throws {
        let adminClient = makeClient { req in
            switch req.url?.path {
            case "/api/agents":
                return Self.response(for: req, body: Self.twoAgentsJSON())
            case "/api/runtimes":
                return Self.response(for: req, body: Self.runtimeListJSON())
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Self.membersJSON(userId: "u2", role: "admin"))
            case "/api/agent-task-snapshot", "/api/agent-run-counts":
                return Self.response(for: req, body: Data("[]".utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let adminVM = AgentsViewModel(api: adminClient, authSession: makeSession(userId: "u2"))

        await adminVM.load()

        XCTAssertTrue(adminVM.canManageAgent(adminVM.agents[0]))
        XCTAssertTrue(adminVM.canManageAgent(adminVM.agents[1]))

        let memberClient = makeClient { req in
            switch req.url?.path {
            case "/api/agents":
                return Self.response(for: req, body: Self.twoAgentsJSON())
            case "/api/runtimes":
                return Self.response(for: req, body: Self.runtimeListJSON())
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Self.membersJSON(userId: "u3", role: "member"))
            case "/api/agent-task-snapshot", "/api/agent-run-counts":
                return Self.response(for: req, body: Data("[]".utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let memberVM = AgentsViewModel(api: memberClient, authSession: makeSession(userId: "u3"))

        await memberVM.load()

        XCTAssertFalse(memberVM.canManageAgent(memberVM.agents[0]))
        XCTAssertTrue(memberVM.canManageAgent(memberVM.agents[1]))
    }

    func testArchiveRestoreAndCancelTasksSurfaceResults() async throws {
        var requestURLs: [URL] = []
        let client = makeClient { req in
            requestURLs.append(req.url!)
            switch req.url?.path {
            case "/api/agents/a1/archive", "/api/agents/a1/restore":
                return Self.response(for: req, body: Self.agentJSON(id: "a1", name: "Codex"))
            case "/api/agents/a1/cancel-tasks":
                return Self.response(for: req, body: #"{"cancelled":3}"#.data(using: .utf8)!)
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = AgentsViewModel(api: client, authSession: makeSession())

        await vm.archiveAgent(id: "a1")
        await vm.restoreAgent(id: "a1")
        let cancelled = await vm.cancelAgentTasks(id: "a1")

        XCTAssertEqual(cancelled, 3)
        XCTAssertEqual(vm.agents.map(\.id), ["a1"])
        XCTAssertTrue(requestURLs.allSatisfy { $0.absoluteString.contains("workspace_id=w1") })
        XCTAssertNil(vm.errorMessage)
    }

    func test_loadSkillOptionsFetchesAvailableAndAssignedSkills() async throws {
        var requests: [String] = []
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch req.url?.path {
            case "/api/skills":
                return Self.response(for: req, body: "[\(String(data: Self.skillJSON(id: "s1", name: "Writer"), encoding: .utf8)!),\(String(data: Self.skillJSON(id: "s2", name: "Reviewer"), encoding: .utf8)!)]".data(using: .utf8)!)
            case "/api/agents/a1/skills":
                return Self.response(for: req, body: "[\(String(data: Self.skillJSON(id: "s2", name: "Reviewer"), encoding: .utf8)!)]".data(using: .utf8)!)
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = AgentsViewModel(api: client, authSession: makeSession())

        await vm.loadSkillOptions(for: "a1")

        XCTAssertEqual(vm.skills.map(\.id), ["s2", "s1"])
        XCTAssertEqual(vm.assignedSkillIdsByAgentId["a1"], Set(["s2"]))
        XCTAssertEqual(Set(requests), Set(["GET /api/skills", "GET /api/agents/a1/skills"]))
        XCTAssertNil(vm.errorMessage)
    }

    func test_agentDetailLoadsOwnerRuntimeAndTasks() async throws {
        var requests: [String] = []
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch req.url?.path {
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Self.membersJSON())
            case "/api/runtimes":
                return Self.response(for: req, body: Self.runtimeListJSON())
            case "/api/agents/a1/tasks":
                XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
                return Self.response(for: req, body: Self.agentTasksJSON())
            case "/api/agent-activity-30d":
                XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
                return Self.response(for: req, body: Self.agentActivityJSON())
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let agent = try decoder.decode(Agent.self, from: Self.agentJSON(id: "a1", name: "Codex", ownerId: "u1"))
        let vm = AgentDetailViewModel(agent: agent, api: client, authSession: makeSession())

        await vm.load()

        XCTAssertEqual(Set(requests), Set([
            "GET /api/workspaces/w1/members",
            "GET /api/runtimes",
            "GET /api/agents/a1/tasks",
            "GET /api/agent-activity-30d",
        ]))
        XCTAssertEqual(vm.ownerName, "Parker")
        XCTAssertEqual(vm.runtimeName, "MacBook")
        XCTAssertEqual(vm.activeTasks.map(\.id), ["t2"])
        XCTAssertEqual(vm.recentTasks.map(\.id), ["t1"])
        XCTAssertEqual(vm.activitySummary.totalRuns, 4)
        XCTAssertEqual(vm.activitySummary.failedRuns, 1)
        XCTAssertEqual(vm.activitySummary.successPercent, 75)
        XCTAssertEqual(vm.activitySummary.averageDurationSeconds, 300)
        XCTAssertNil(vm.errorMessage)
    }

    func test_agentActivitySummaryFiltersToAgentAndLast30Days() {
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-01-31T00:00:00Z")!
        let tasks = [
            AgentTask(
                id: "recent",
                issueId: "i1",
                status: "completed",
                startedAt: formatter.date(from: "2026-01-30T00:00:00Z"),
                completedAt: formatter.date(from: "2026-01-30T00:10:00Z"),
                error: nil,
                agentId: "a1"
            ),
            AgentTask(
                id: "old",
                issueId: "i2",
                status: "completed",
                startedAt: formatter.date(from: "2025-12-01T00:00:00Z"),
                completedAt: formatter.date(from: "2025-12-01T00:30:00Z"),
                error: nil,
                agentId: "a1"
            ),
        ]
        let buckets = [
            AgentActivityBucket(agentId: "a1", bucketAt: "2026-01-30T00:00:00Z", taskCount: 3, failedCount: 1),
            AgentActivityBucket(agentId: "a2", bucketAt: "2026-01-30T00:00:00Z", taskCount: 9, failedCount: 9),
        ]

        let summary = AgentActivitySummary.summarize(buckets, agentId: "a1", tasks: tasks, now: now)

        XCTAssertEqual(summary.totalRuns, 3)
        XCTAssertEqual(summary.failedRuns, 1)
        XCTAssertEqual(summary.successPercent, 67)
        XCTAssertEqual(summary.averageDurationSeconds, 600)
    }

    func test_agentPresenceSummaryDerivesAvailabilityAndWorkload() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onlineAgent = try decoder.decode(Agent.self, from: Self.agentJSON(id: "a1", name: "Codex"))
        let offlineAgent = try decoder.decode(Agent.self, from: Self.agentJSON(id: "a2", name: "Reviewer", runtimeId: "r2"))
        let runningTask = AgentTask(id: "t1", issueId: "i1", status: "running", startedAt: nil, completedAt: nil, error: nil, agentId: "a1")
        let queuedTask = AgentTask(id: "t2", issueId: "i2", status: "queued", startedAt: nil, completedAt: nil, error: nil, agentId: "a2")
        let summaries = AgentPresenceSummary.buildMap(
            agents: [onlineAgent, offlineAgent],
            runtimes: [
                AgentRuntime(id: "r1", workspaceId: "w1", name: "MacBook", runtimeMode: "local", provider: "claude", status: "online")
            ],
            tasks: [runningTask, queuedTask]
        )

        XCTAssertEqual(summaries["a1"]?.availability, .online)
        XCTAssertEqual(summaries["a1"]?.workload, .working)
        XCTAssertEqual(summaries["a1"]?.displayText, "Online • Working 1/1")
        XCTAssertEqual(summaries["a2"]?.availability, .offline)
        XCTAssertEqual(summaries["a2"]?.workload, .queued)
        XCTAssertEqual(summaries["a2"]?.displayText, "Offline • Queued 1/1")
    }

    func test_avatarStatusDotMapsPresenceBuckets() {
        func summary(_ availability: AgentAvailability, _ workload: AgentWorkload) -> AgentPresenceSummary {
            AgentPresenceSummary(availability: availability, workload: workload, runningCount: 0, queuedCount: 0, capacity: 1)
        }
        XCTAssertEqual(summary(.offline, .idle).avatarStatusDot, .offline)
        XCTAssertEqual(summary(.unstable, .working).avatarStatusDot, .unstable)
        XCTAssertEqual(summary(.online, .working).avatarStatusDot, .working)
        XCTAssertEqual(summary(.online, .queued).avatarStatusDot, .working)
        XCTAssertEqual(summary(.online, .idle).avatarStatusDot, .online)
    }

    func test_updateAgentSavesSkillAssignments() async throws {
        var requests: [String] = []
        var skillBody: [String: Any] = [:]
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("PUT", "/api/agents/a1"):
                return Self.response(for: req, body: Self.agentJSON(id: "a1", name: "Updated"))
            case ("PUT", "/api/agents/a1/skills"):
                skillBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return Self.response(for: req, body: Data(), status: 204)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = AgentsViewModel(api: client, authSession: makeSession())

        let updated = await vm.updateAgent(
            id: "a1",
            name: "Updated",
            description: "D",
            instructions: "I",
            runtimeId: "r2",
            visibility: "private",
            maxConcurrentTasks: 2,
            model: "gpt-5",
            skillIds: Set(["s2", "s1"])
        )

        XCTAssertEqual(updated?.name, "Updated")
        XCTAssertEqual(vm.assignedSkillIdsByAgentId["a1"], Set(["s1", "s2"]))
        XCTAssertEqual(skillBody["skill_ids"] as? [String], ["s1", "s2"])
        XCTAssertEqual(requests, ["PUT /api/agents/a1", "PUT /api/agents/a1/skills"])
        XCTAssertNil(vm.errorMessage)
    }

    func test_agentFormDraftParsesCustomEnvironmentAndArgs() throws {
        let env = try AgentFormDraft.parseCustomEnvironment(
            """
            ANTHROPIC_BASE_URL=https://example.com
            OPENAI_API_KEY = sk-test

            EMPTY=
            """
        )
        let args = AgentFormDraft.parseCustomArgs("--verbose\n--model gpt-5  --debug")

        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "https://example.com")
        XCTAssertEqual(env["OPENAI_API_KEY"], "sk-test")
        XCTAssertEqual(env["EMPTY"], "")
        XCTAssertEqual(args, ["--verbose", "--model", "gpt-5", "--debug"])
    }

    func test_agentFormDraftRejectsDuplicateEnvironmentKeys() throws {
        XCTAssertThrowsError(
            try AgentFormDraft.parseCustomEnvironment(
                """
                OPENAI_API_KEY=one
                OPENAI_API_KEY=two
                """
            )
        ) { error in
            XCTAssertEqual(error as? AgentFormDraft.ValidationError, .duplicateEnvironmentKey("OPENAI_API_KEY"))
        }
    }

    func test_agentFormDraftFormatsExistingEnvironmentAndArgs() {
        let envText = AgentFormDraft.environmentText(from: [
            "B": .string("two"),
            "A": .string("one"),
            "OBJECT": .object(["x": .string("ignored")]),
        ])
        let argsText = AgentFormDraft.argsText(from: ["--model", "gpt-5"])

        XCTAssertEqual(envText, "A=one\nB=two")
        XCTAssertEqual(argsText, "--model\ngpt-5")
    }

    private func makeSession(userId: String = "u1") -> AuthSession {
        let session = AuthSession(keychain: KeychainStore(service: "ai.multi-casual.app.agents.test"))
        session.currentUser = User(id: userId, email: "\(userId)@example.com", name: userId, avatarUrl: nil)
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

    private static func agentListJSON() -> Data {
        "[\(String(data: agentJSON(id: "a1", name: "Codex"), encoding: .utf8)!)]".data(using: .utf8)!
    }

    private static func twoAgentsJSON() -> Data {
        """
        [
          \(String(data: agentJSON(id: "a1", name: "Codex", ownerId: "u1"), encoding: .utf8)!),
          \(String(data: agentJSON(id: "a2", name: "Reviewer", ownerId: "u3"), encoding: .utf8)!)
        ]
        """.data(using: .utf8)!
    }

    private static func makeAgent(
        id: String,
        name: String,
        avatarUrl: String?,
        archivedAt: String? = nil
    ) -> Agent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(
            Agent.self,
            from: agentJSON(id: id, name: name, avatarUrl: avatarUrl, archivedAt: archivedAt)
        )
    }

    private static func agentJSON(
        id: String,
        name: String,
        ownerId: String? = nil,
        runtimeId: String = "r1",
        avatarUrl: String? = nil,
        archivedAt: String? = nil
    ) -> Data {
        let ownerJSON = ownerId.map { "\"\($0)\"" } ?? "null"
        let avatarJSON = avatarUrl.map { "\"\($0)\"" } ?? "null"
        let archivedAtJSON = archivedAt.map { "\"\($0)\"" } ?? "null"
        return """
        {"id":"\(id)","workspace_id":"w1","runtime_id":"\(runtimeId)","name":"\(name)",
          "description":"**Markdown** description","instructions":"Be useful","avatar_url":\(avatarJSON),"runtime_mode":"cloud",
          "runtime_config":{},"custom_env":{},"custom_args":[],"custom_env_redacted":false,
          "visibility":"workspace","status":"idle","max_concurrent_tasks":1,
          "model":"gpt","owner_id":\(ownerJSON),"skills":[],"created_at":"2026-01-01T00:00:00Z",
          "updated_at":"2026-01-01T00:00:00Z","archived_at":\(archivedAtJSON),"archived_by":null}
        """.data(using: .utf8)!
    }

    private static func attachmentJSON(url: String) -> Data {
        """
        {"id":"att1","workspace_id":"w1","issue_id":null,"comment_id":null,
         "uploader_type":"member","uploader_id":"u1","filename":"avatar.png",
         "url":"\(url)","download_url":"\(url)",
         "content_type":"image/png","size_bytes":4,"created_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
    }

    private static func runtimeListJSON() -> Data {
        """
        [{"id":"r1","workspace_id":"w1","daemon_id":null,"name":"MacBook",
          "runtime_mode":"cloud","provider":"multica","launch_header":"",
          "status":"online","device_info":"","metadata":{},"owner_id":null,
          "last_seen_at":null,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]
        """.data(using: .utf8)!
    }

    private static func membersJSON() -> Data {
        membersJSON(userId: "u1", role: "owner")
    }

    private static func membersJSON(userId: String, role: String) -> Data {
        """
        [{"id":"m1","workspace_id":"w1","user_id":"\(userId)","role":"\(role)",
          "name":"Parker","email":"\(userId)@example.com","avatar_url":null}]
        """.data(using: .utf8)!
    }

    private static func agentTasksJSON() -> Data {
        """
        [
          {"id":"t1","agent_id":"a1","issue_id":"i1","status":"completed",
           "started_at":"2026-06-06T00:00:00Z","completed_at":"2026-06-06T00:05:00Z","error":null},
          {"id":"t2","agent_id":"a1","issue_id":"i2","status":"running",
           "started_at":"2026-06-06T01:00:00Z","completed_at":null,"error":null}
        ]
        """.data(using: .utf8)!
    }

    private static func agentActivityJSON() -> Data {
        """
        [
          {"agent_id":"a1","bucket_at":"2026-01-01T00:00:00Z","task_count":4,"failed_count":1},
          {"agent_id":"a2","bucket_at":"2026-01-01T00:00:00Z","task_count":8,"failed_count":8}
        ]
        """.data(using: .utf8)!
    }

    private static func agentRunCountsJSON() -> Data {
        """
        [
          {"agent_id":"a1","run_count":7},
          {"agent_id":"a2","run_count":2}
        ]
        """.data(using: .utf8)!
    }

    private static func skillJSON(id: String, name: String) -> Data {
        """
        {"id":"\(id)","workspace_id":"w1","name":"\(name)","description":"**Useful** skill",
         "content":"# Skill","config":{},"files":[],"created_by":"u1",
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        """.data(using: .utf8)!
    }
}
