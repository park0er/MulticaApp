import XCTest
@testable import MultiCasual

@MainActor
final class IssueDetailViewModelTests: XCTestCase {
    func testMentionTriggerSessionDoesNotReactivateAfterDismissUntilTriggerChanges() {
        var tracker = MentionTriggerSession()

        XCTAssertEqual(tracker.update(draft: "Email me @", candidatesAvailable: true), "")
        tracker.dismissCurrentTrigger()

        XCTAssertNil(tracker.update(draft: "Email me @p", candidatesAvailable: true))
        XCTAssertNil(tracker.update(draft: "Email me @parker", candidatesAvailable: true))
        XCTAssertNil(tracker.update(draft: "Email me parker", candidatesAvailable: true))

        XCTAssertEqual(tracker.update(draft: "Email me parker @", candidatesAvailable: true), "")
    }

    func test_displayedCommentThreadsGroupRepliesUnderRootPosts() {
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: makeClient { req in
            XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
            return Self.response(for: req, body: Data("{}".utf8), status: 500)
        })
        vm.commentLoader.items = [
            Comment(id: "r2", content: "Nested", authorId: "u3", authorType: "member", parentId: "r1", issueId: "i1", createdAt: Date(timeIntervalSince1970: 40)),
            Comment(id: "c2", content: "Second post", authorId: "u2", authorType: "member", parentId: nil, issueId: "i1", createdAt: Date(timeIntervalSince1970: 20)),
            Comment(id: "r1", content: "Reply", authorId: "u2", authorType: "member", parentId: "c1", issueId: "i1", createdAt: Date(timeIntervalSince1970: 30)),
            Comment(id: "c1", content: "First post", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: Date(timeIntervalSince1970: 10)),
        ]

        vm.setCommentSortOrder(.ascending)
        XCTAssertEqual(vm.displayedCommentThreads.map(\.root.id), ["c1", "c2"])
        // With ascending sort, replies within c1 (the first root) should be oldest-first.
        XCTAssertEqual(vm.displayedCommentThreads.first?.replies.map(\.id), ["r1", "r2"])

        vm.setCommentSortOrder(.descending)
        XCTAssertEqual(vm.displayedCommentThreads.map(\.root.id), ["c2", "c1"])
        // With descending sort, replies within c1 (the last root) should be newest-first.
        XCTAssertEqual(vm.displayedCommentThreads.last?.replies.map(\.id), ["r2", "r1"])
    }

    func test_displayedCommentsCanSwitchBetweenAscendingAndDescendingOrder() {
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: makeClient { req in
            XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
            return Self.response(for: req, body: Data("{}".utf8), status: 500)
        })
        vm.commentLoader.items = [
            Comment(id: "new", content: "New", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: Date(timeIntervalSince1970: 20)),
            Comment(id: "old", content: "Old", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: Date(timeIntervalSince1970: 10)),
        ]

        vm.setCommentSortOrder(.ascending)
        XCTAssertEqual(vm.displayedComments.map(\.id), ["old", "new"])

        vm.setCommentSortOrder(.descending)
        XCTAssertEqual(vm.displayedComments.map(\.id), ["new", "old"])
    }

    func test_loadMetadata_resolvesAssigneeAndProjectNames() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/issues/i1":
                let json = """
                {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
                 "status":"todo","priority":"none","assignee_id":"a1","assignee_type":"agent",
                 "project_id":"p1","workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Data("[]".utf8))
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
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            case "/api/issues/i1/children":
                return Self.response(for: req, body: #"{"issues":[]}"#.data(using: .utf8)!)
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadIssue()
        await vm.loadMetadata()

        XCTAssertEqual(vm.assigneeDisplayName, "Codex")
        XCTAssertEqual(vm.projectDisplayName, "iOS MVP")
        XCTAssertNil(vm.metadataError)
    }

    func test_loadMetadata_fetchesLinkedProjectByIdWhenNotInFirstProjectsPage() async throws {
        var capturedProjectURL: URL?
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/issues/i1":
                let json = """
                {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
                 "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
                 "project_id":"p51","workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/agents":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/projects":
                return Self.response(for: req, body: #"{"projects":[],"total":51}"#.data(using: .utf8)!)
            case "/api/projects/p51":
                capturedProjectURL = req.url
                let json = """
                {"id":"p51","workspace_id":"w1","title":"Page 2 Project","description":null,
                 "icon":null,"status":"planned","priority":"none",
                 "lead_type":null,"lead_id":null,"created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-01T00:00:00Z","issue_count":1,"done_count":0}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadIssue()
        await vm.loadMetadata()

        XCTAssertEqual(vm.projectDisplayName, "Page 2 Project")
        XCTAssertTrue(capturedProjectURL?.absoluteString.contains("workspace_id=w1") ?? false)
        XCTAssertNil(vm.metadataError)
    }

    func test_loadIssueAndMetadataResolvesMetadataAfterIssueRetry() async throws {
        var issueFetchCount = 0
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/issues/i1":
                issueFetchCount += 1
                if issueFetchCount == 1 {
                    return Self.response(for: req, body: Data(#"{"error":"temporary"}"#.utf8), status: 500)
                }
                let json = """
                {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
                 "status":"todo","priority":"none","assignee_id":"a1","assignee_type":"agent",
                 "project_id":"p1","workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/agents":
                let json = """
                [{"id":"a1","workspace_id":"w1","runtime_id":"r1","name":"Codex",
                  "description":"","instructions":"","avatar_url":null,"runtime_mode":"cloud",
                  "runtime_config":{},"custom_args":[],"custom_env":{},"custom_env_redacted":false,
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
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            case "/api/issues/i1/children":
                return Self.response(for: req, body: #"{"issues":[]}"#.data(using: .utf8)!)
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadIssueAndMetadata()
        XCTAssertEqual(vm.error, "temporary")
        XCTAssertNil(vm.issue)
        XCTAssertNil(vm.assigneeDisplayName)
        XCTAssertNil(vm.projectDisplayName)

        await vm.loadIssueAndMetadata()

        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.issue?.id, "i1")
        XCTAssertEqual(vm.assigneeDisplayName, "Codex")
        XCTAssertEqual(vm.projectDisplayName, "iOS MVP")
        XCTAssertNil(vm.metadataError)
    }

    func test_loadIssueAndMetadataLoadsParentAndChildIssues() async throws {
        var requests: [String] = []
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch req.url?.path {
            case "/api/issues/i1":
                let json = Self.issueJSON(
                    id: "i1",
                    identifier: "PAR-2",
                    title: "Child issue",
                    parentIssueId: "p0",
                    updatedAt: "2026-01-01T00:00:00Z"
                )
                return Self.response(for: req, body: json)
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/agents":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/projects":
                return Self.response(for: req, body: #"{"projects":[],"total":0}"#.data(using: .utf8)!)
            case "/api/issues/i1/children":
                let json = """
                {"issues":[{"id":"c1","identifier":"PAR-3","number":3,"title":"Nested child","description":null,
                 "status":"done","priority":"none","assignee_id":null,"assignee_type":null,
                 "parent_issue_id":"i1","project_id":null,"workspace_id":"w1",
                 "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/issues/p0":
                let json = Self.issueJSON(
                    id: "p0",
                    identifier: "PAR-1",
                    title: "Parent issue",
                    parentIssueId: nil,
                    updatedAt: "2026-01-01T00:00:00Z"
                )
                return Self.response(for: req, body: json)
            case "/api/issues/p0/children":
                let json = """
                {"issues":[{"id":"i1","identifier":"PAR-2","number":2,"title":"Child issue","description":null,
                 "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
                 "parent_issue_id":"p0","project_id":null,"workspace_id":"w1",
                 "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
                {"id":"s1","identifier":"PAR-4","number":4,"title":"Sibling done","description":null,
                 "status":"done","priority":"none","assignee_id":null,"assignee_type":null,
                 "parent_issue_id":"p0","project_id":null,"workspace_id":"w1",
                 "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}]}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadIssueAndMetadata()

        XCTAssertEqual(vm.parentIssue?.id, "p0")
        XCTAssertEqual(vm.childIssues.map(\.id), ["c1"])
        XCTAssertEqual(vm.parentSiblingIssues.map(\.id), ["i1", "s1"])
        XCTAssertEqual(vm.parentChildProgressText, "1/2")
        XCTAssertEqual(vm.childProgressText, "1/1")
        XCTAssertTrue(vm.didLoadIssueRelations)
        XCTAssertNil(vm.issueRelationsError)
        XCTAssertTrue(requests.contains("GET /api/issues/i1/children"))
        XCTAssertTrue(requests.contains("GET /api/issues/p0"))
        XCTAssertTrue(requests.contains("GET /api/issues/p0/children"))
    }

    func test_loadInitialDataUsesIssueWorkspaceIdForScopedDetailSectionsWhenInitWorkspaceMissing() async throws {
        let lock = NSLock()
        var workspaceByPath: [String: String?] = [:]
        var requests: [String] = []
        let client = makeClient(workspaceId: "w1") { req in
            let path = req.url?.path ?? ""
            let workspace = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "workspace_id" })?
                .value
            lock.withLock {
                workspaceByPath[path] = workspace
                requests.append("\(req.httpMethod ?? "") \(path)")
            }

            switch path {
            case "/api/issues/i1":
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-01T00:00:00Z"))
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/agents":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/projects":
                return Self.response(for: req, body: #"{"projects":[],"total":0}"#.data(using: .utf8)!)
            case "/api/issues/i1/comments":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/issues/i1/attachments":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/issues/i1/subscribers":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/issues/i1/task-runs":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/issues/i1/active-task":
                return Self.response(for: req, body: #"{"tasks":[]}"#.data(using: .utf8)!)
            case "/api/issues/i1/timeline":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/issues/i1/usage":
                let json = """
                {"total_input_tokens":0,"total_output_tokens":0,
                 "total_cache_read_tokens":0,"total_cache_write_tokens":0,
                 "task_count":0}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/issues/i1/children":
                return Self.response(for: req, body: #"{"issues":[]}"#.data(using: .utf8)!)
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: nil, api: client)

        await vm.loadInitialData()

        let (capturedWorkspaces, capturedRequests) = lock.withLock {
            (workspaceByPath, requests)
        }
        XCTAssertTrue(capturedRequests.contains("GET /api/workspaces/w1/members"))
        XCTAssertEqual(capturedWorkspaces["/api/agents"] ?? nil, "w1")
        XCTAssertEqual(capturedWorkspaces["/api/projects"] ?? nil, "w1")
        XCTAssertEqual(capturedWorkspaces["/api/issues/i1/comments"] ?? nil, "w1")
        XCTAssertEqual(capturedWorkspaces["/api/issues/i1/attachments"] ?? nil, "w1")
        XCTAssertEqual(capturedWorkspaces["/api/issues/i1/subscribers"] ?? nil, "w1")
        XCTAssertEqual(capturedWorkspaces["/api/issues/i1/task-runs"] ?? nil, "w1")
        XCTAssertEqual(capturedWorkspaces["/api/issues/i1/active-task"] ?? nil, "w1")
        XCTAssertEqual(capturedWorkspaces["/api/issues/i1/timeline"] ?? nil, "w1")
        XCTAssertEqual(capturedWorkspaces["/api/issues/i1/usage"] ?? nil, "w1")
        XCTAssertEqual(capturedWorkspaces["/api/issues/i1/children"] ?? nil, "w1")
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.commentsError)
        XCTAssertNil(vm.subscribersError)
        XCTAssertNil(vm.timelineError)
        XCTAssertNil(vm.usageError)
        XCTAssertNil(vm.issueRelationsError)
        XCTAssertNil(vm.attachmentsError)
    }

    func test_loadInitialDataStartsCoreSectionsBeforeAwaitingMetadata() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Multi-Casual/Features/Issues/IssueDetailViewModel.swift")
        let source = try String(contentsOf: sourceURL)
        let functionStart = try XCTUnwrap(source.range(of: "public func loadInitialData() async {"))
        let functionEnd = try XCTUnwrap(source[functionStart.upperBound...].range(of: "\n    public func loadIssue() async"))
        let body = String(source[functionStart.lowerBound..<functionEnd.lowerBound])
        let awaitRange = try XCTUnwrap(body.range(of: "_ = await"))
        let awaitedOffset = body.distance(from: body.startIndex, to: awaitRange.lowerBound)

        for call in [
            "async let metadata: Void = loadMetadata()",
            "async let comments: Void = loadComments()",
            "async let agentRuns: Void = loadAgentRuns()",
            "async let activeTasks: Void = loadActiveTasks()",
            "async let timeline: Void = loadTimeline()",
            "async let usage: Void = loadUsage()",
        ] {
            let callRange = try XCTUnwrap(body.range(of: call), "\(call) should be launched before the await tuple.")
            let callOffset = body.distance(from: body.startIndex, to: callRange.lowerBound)
            XCTAssertLessThan(callOffset, awaitedOffset)
        }
    }

    func test_loadAgentRuns_surfacesEndpointError() async throws {
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues/i1/task-runs")
            return Self.response(for: req, body: Data(#"{"error":"runs unavailable"}"#.utf8), status: 500)
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadAgentRuns()

        XCTAssertTrue(vm.agentRuns.isEmpty)
        XCTAssertEqual(vm.agentRunsError, "runs unavailable")
    }

    func test_loadAgentRuns_marksLoadedForEmptyResponse() async throws {
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues/i1/task-runs")
            return Self.response(for: req, body: Data("[]".utf8))
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadAgentRuns()

        XCTAssertTrue(vm.didLoadAgentRuns)
        XCTAssertTrue(vm.agentRuns.isEmpty)
        XCTAssertNil(vm.agentRunsError)
    }

    func test_loadActiveTasks_fetchesDesktopActiveTaskEndpoint() async throws {
        var capturedURL: URL?
        let client = makeClient { req in
            capturedURL = req.url
            XCTAssertEqual(req.url?.path, "/api/issues/i1/active-task")
            let json = """
            {"tasks":[{
                "id":"t1","agent_id":"a1","runtime_id":"r1","issue_id":"i1",
                "status":"running","priority":0,"dispatched_at":null,
                "started_at":"2026-01-01T00:00:00Z","completed_at":null,
                "result":null,"error":null,"created_at":"2026-01-01T00:00:00Z"
            }]}
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadActiveTasks()

        XCTAssertEqual(vm.activeTasks.map(\.id), ["t1"])
        XCTAssertTrue(vm.didLoadActiveTasks)
        XCTAssertNil(vm.activeTasksError)
        XCTAssertTrue(capturedURL?.absoluteString.contains("workspace_id=w1") ?? false)
    }

    func test_cancelActiveTask_removesActiveTaskAndRecordsReturnedRun() async throws {
        var requests: [String] = []
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/issues/i1/tasks/t1/cancel"):
                let json = """
                {"id":"t1","agent_id":"a1","runtime_id":"r1","issue_id":"i1",
                 "status":"cancelled","priority":0,"dispatched_at":null,
                 "started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:01:00Z",
                 "result":null,"error":null,"created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        vm.activeTasks = [
            AgentTask(id: "t1", issueId: "i1", status: "running", startedAt: Date(), completedAt: nil, error: nil)
        ]

        await vm.cancelActiveTask(id: "t1")

        XCTAssertEqual(requests, ["POST /api/issues/i1/tasks/t1/cancel"])
        XCTAssertTrue(vm.activeTasks.isEmpty)
        XCTAssertEqual(vm.agentRuns.first?.id, "t1")
        XCTAssertEqual(vm.agentRuns.first?.status, "cancelled")
        XCTAssertNil(vm.activeTasksError)
        XCTAssertFalse(vm.cancellingTaskIds.contains("t1"))
    }

    func test_loadTimeline_fetchesAndFormatsDesktopActivities() async throws {
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues/i1/timeline")
            let json = """
            [{"type":"activity","id":"a1","actor_type":"member","actor_id":"u1",
              "created_at":"2026-01-01T00:00:00Z","action":"status_changed",
              "details":{"from":"todo","to":"in_review"}},
             {"type":"comment","id":"c1","actor_type":"member","actor_id":"u1",
              "created_at":"2026-01-02T00:00:00Z","content":"Comment","parent_id":null,
              "comment_type":"comment"}]
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadTimeline()

        XCTAssertTrue(vm.didLoadTimeline)
        XCTAssertEqual(vm.timelineActivities.map(\.id), ["a1"])
        XCTAssertEqual(vm.activityText(for: vm.timelineActivities[0]), "changed status from Todo to In Review")
        XCTAssertNil(vm.timelineError)
    }

    func test_loadUsage_fetchesDesktopIssueUsageAndFormatsSummary() async throws {
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues/i1/usage")
            let json = """
            {"total_input_tokens":1200,"total_output_tokens":340,
             "total_cache_read_tokens":50,"total_cache_write_tokens":10,
             "task_count":3}
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadUsage()

        XCTAssertTrue(vm.didLoadUsage)
        XCTAssertEqual(vm.usage?.totalTokens, 1_600)
        XCTAssertEqual(vm.usageSummaryText, "1.6K tokens across 3 tasks")
        XCTAssertNil(vm.usageError)
    }

    func test_loadSubscribers_fetchesDesktopSubscribers() async throws {
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues/i1/subscribers")
            let json = """
            [{"issue_id":"i1","user_type":"member","user_id":"u1","reason":"manual",
              "created_at":"2026-01-01T00:00:00Z"},
             {"issue_id":"i1","user_type":"agent","user_id":"a1","reason":"assignee",
              "created_at":"2026-01-02T00:00:00Z"}]
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadSubscribers()

        XCTAssertTrue(vm.didLoadSubscribers)
        XCTAssertEqual(vm.subscribers.map(\.id), ["member:u1", "agent:a1"])
        XCTAssertNil(vm.subscribersError)
    }

    func test_loadSubscribers_surfacesEndpointError() async throws {
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues/i1/subscribers")
            return Self.response(for: req, body: Data(#"{"error":"subscribers unavailable"}"#.utf8), status: 500)
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadSubscribers()

        XCTAssertTrue(vm.didLoadSubscribers)
        XCTAssertTrue(vm.subscribers.isEmpty)
        XCTAssertEqual(vm.subscribersError, "subscribers unavailable")
    }

    func test_toggleSubscriberSubscribesAndRefreshesWhenMissing() async throws {
        var requests: [String] = []
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/issues/i1/subscribe"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                XCTAssertEqual(body["user_id"] as? String, "u1")
                XCTAssertEqual(body["user_type"] as? String, "member")
                return Self.response(for: req, body: Data(), status: 204)
            case ("GET", "/api/issues/i1/subscribers"):
                let json = """
                [{"issue_id":"i1","user_type":"member","user_id":"u1","reason":"manual",
                  "created_at":"2026-01-01T00:00:00Z"}]
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.toggleSubscriber(userId: "u1", userType: "member")

        XCTAssertEqual(vm.subscribers.map(\.id), ["member:u1"])
        XCTAssertEqual(requests, [
            "POST /api/issues/i1/subscribe",
            "GET /api/issues/i1/subscribers",
        ])
        XCTAssertNil(vm.subscribersError)
    }

    func test_toggleSubscriberUnsubscribesAndRefreshesWhenPresent() async throws {
        var requests: [String] = []
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/issues/i1/unsubscribe"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                XCTAssertEqual(body["user_id"] as? String, "a1")
                XCTAssertEqual(body["user_type"] as? String, "agent")
                return Self.response(for: req, body: Data(), status: 204)
            case ("GET", "/api/issues/i1/subscribers"):
                return Self.response(for: req, body: Data("[]".utf8))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        vm.subscribers = [
            IssueSubscriber(
                issueId: "i1",
                userType: "agent",
                userId: "a1",
                reason: "manual",
                createdAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
            )
        ]

        await vm.toggleSubscriber(userId: "a1", userType: "agent")

        XCTAssertTrue(vm.subscribers.isEmpty)
        XCTAssertEqual(requests, [
            "POST /api/issues/i1/unsubscribe",
            "GET /api/issues/i1/subscribers",
        ])
        XCTAssertNil(vm.subscribersError)
    }

    func test_toggleIssueReactionAddsAndRemovesCurrentUserReaction() async throws {
        var requests: [String] = []
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-01T00:00:00Z"))
            case ("POST", "/api/issues/i1/reactions"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                XCTAssertEqual(body["emoji"] as? String, "👍")
                let json = """
                {"id":"ir1","issue_id":"i1","actor_type":"member","actor_id":"u1",
                 "emoji":"👍","created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("DELETE", "/api/issues/i1/reactions"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                XCTAssertEqual(body["emoji"] as? String, "👍")
                return Self.response(for: req, body: Data(), status: 204)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadIssue()
        await vm.toggleIssueReaction(emoji: "👍", currentUserId: "u1")
        XCTAssertEqual(vm.issue?.reactions.map(\.id), ["ir1"])

        await vm.toggleIssueReaction(emoji: "👍", currentUserId: "u1")
        XCTAssertEqual(vm.issue?.reactions.map(\.id), [])
        XCTAssertEqual(requests, [
            "GET /api/issues/i1",
            "POST /api/issues/i1/reactions",
            "DELETE /api/issues/i1/reactions",
        ])
        XCTAssertNil(vm.error)
    }

    func test_toggleCommentReactionAddsAndRemovesCurrentUserReaction() async throws {
        var requests: [String] = []
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/comments/c1/reactions"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                XCTAssertEqual(body["emoji"] as? String, "👀")
                let json = """
                {"id":"r1","comment_id":"c1","actor_type":"member","actor_id":"u1",
                 "emoji":"👀","created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("DELETE", "/api/comments/c1/reactions"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                XCTAssertEqual(body["emoji"] as? String, "👀")
                return Self.response(for: req, body: Data(), status: 204)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        vm.commentLoader.items = [
            Comment(
                id: "c1",
                content: "Ship it",
                authorId: "u2",
                authorType: "member",
                parentId: nil,
                issueId: "i1",
                createdAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
            )
        ]

        await vm.toggleCommentReaction(commentId: "c1", emoji: "👀", currentUserId: "u1")
        XCTAssertEqual(vm.commentLoader.items.first?.reactions.map(\.id), ["r1"])

        await vm.toggleCommentReaction(commentId: "c1", emoji: "👀", currentUserId: "u1")
        XCTAssertEqual(vm.commentLoader.items.first?.reactions.map(\.id), [])
        XCTAssertEqual(requests, [
            "POST /api/comments/c1/reactions",
            "DELETE /api/comments/c1/reactions",
        ])
        XCTAssertNil(vm.error)
    }

    func test_submitReplySendsParentIdAndAppendsReply() async throws {
        var submittedParentId: String?
        var submittedContent: String?
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/issues/i1/comments"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                submittedParentId = body["parent_id"] as? String
                submittedContent = body["content"] as? String
                let json = """
                {"id":"r1","content":"Reply **markdown**","author_id":"u1","author_type":"member",
                 "parent_id":"c1","issue_id":"i1","created_at":"2026-01-02T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-02T00:00:00Z"))
            default:
                if let response = Self.emptyLatestProgressResponse(for: req) {
                    return response
                }
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        let didSubmit = await vm.submitReply(parentId: "c1", content: " \nReply **markdown** ")

        XCTAssertTrue(didSubmit)
        XCTAssertEqual(submittedParentId, "c1")
        XCTAssertEqual(submittedContent, "Reply **markdown**")
        XCTAssertEqual(vm.commentLoader.items.map(\.id), ["r1"])
        XCTAssertNil(vm.error)
    }

    func test_submitReplyInsideThreadUsesRootParentAndImplicitlyMentionsParticipatingAgent() async throws {
        var submittedParentId: String?
        var submittedContent: String?
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/issues/i1/comments"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                submittedParentId = body["parent_id"] as? String
                submittedContent = body["content"] as? String
                let json = """
                {"id":"r2","content":"Continuing","author_id":"u1","author_type":"member",
                 "parent_id":"c1","issue_id":"i1","created_at":"2026-01-03T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-03T00:00:00Z"))
            default:
                if let response = Self.emptyLatestProgressResponse(for: req) {
                    return response
                }
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        vm.subscriberAgents = [try Self.decodeAgent(id: "a1", name: "Codex")]
        vm.commentLoader.items = [
            Comment(id: "c1", content: "Please work on this", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: Date(timeIntervalSince1970: 10)),
            Comment(id: "r1", content: "Agent response", authorId: "a1", authorType: "agent", parentId: "c1", issueId: "i1", createdAt: Date(timeIntervalSince1970: 20)),
        ]

        let didSubmit = await vm.submitReply(parentId: "r1", content: " \nContinue please ")

        XCTAssertTrue(didSubmit)
        XCTAssertEqual(submittedParentId, "c1")
        XCTAssertEqual(submittedContent, "Continue please [@Codex](mention://agent/a1)")
    }

    func test_submitReplyDoesNotDuplicateExplicitAgentMention() async throws {
        var submittedContent: String?
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/issues/i1/comments"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                submittedContent = body["content"] as? String
                let json = """
                {"id":"r2","content":"Explicit","author_id":"u1","author_type":"member",
                 "parent_id":"c1","issue_id":"i1","created_at":"2026-01-03T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-03T00:00:00Z"))
            default:
                if let response = Self.emptyLatestProgressResponse(for: req) {
                    return response
                }
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        vm.subscriberAgents = [try Self.decodeAgent(id: "a1", name: "Codex")]
        vm.commentLoader.items = [
            Comment(id: "c1", content: "Please work on this", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: Date(timeIntervalSince1970: 10)),
            Comment(id: "r1", content: "Agent response", authorId: "a1", authorType: "agent", parentId: "c1", issueId: "i1", createdAt: Date(timeIntervalSince1970: 20)),
        ]

        let didSubmit = await vm.submitReply(parentId: "c1", content: "Already [@Codex](mention://agent/a1)")

        XCTAssertTrue(didSubmit)
        XCTAssertEqual(submittedContent, "Already [@Codex](mention://agent/a1)")
    }

    func test_uploadReplyAttachmentAndSubmitIncludesAttachmentIds() async throws {
        var requests: [String] = []
        var commentBody: [String: Any] = [:]
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/upload-file"):
                let body = String(data: MockURLProtocol.bodyData(for: req), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains(#"name="file"; filename="reply.png""#))
                XCTAssertTrue(body.contains("reply-png"))
                let json = """
                {"id":"att-reply","workspace_id":"w1","issue_id":"i1","comment_id":null,
                 "uploader_type":"member","uploader_id":"u1","filename":"reply.png",
                 "url":"https://cdn.example/reply.png","download_url":"https://cdn.example/reply.png",
                 "content_type":"image/png","size_bytes":9,"created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("POST", "/api/issues/i1/comments"):
                commentBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                let json = """
                {"id":"r1","content":"Reply with attachment","author_id":"u1","author_type":"member",
                 "parent_id":"c1","issue_id":"i1","created_at":"2026-01-02T00:00:00Z",
                 "attachments":[]}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-02T00:00:00Z"))
            default:
                if let response = Self.emptyLatestProgressResponse(for: req) {
                    return response
                }
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        let uploaded = await vm.uploadReplyAttachment(
            parentId: "c1",
            filename: "reply.png",
            data: Data("reply-png".utf8),
            contentType: "image/png"
        )
        let submitted = await vm.submitReply(parentId: "c1", content: "Reply with attachment")

        XCTAssertTrue(uploaded)
        XCTAssertTrue(submitted)
        XCTAssertEqual(commentBody["parent_id"] as? String, "c1")
        XCTAssertEqual(commentBody["attachment_ids"] as? [String], ["att-reply"])
        XCTAssertEqual(vm.replyAttachments["c1"]?.map(\.id) ?? [], [])
        XCTAssertEqual(Set(requests), Set([
            "POST /api/upload-file",
            "POST /api/issues/i1/comments",
            "GET /api/issues/i1",
            "GET /api/issues/i1/active-task",
            "GET /api/issues/i1/task-runs",
            "GET /api/issues/i1/timeline",
        ]))
        XCTAssertNil(vm.error)
    }

    func test_submitReplyAllowsAttachmentOnlyImageReply() async throws {
        var commentBody: [String: Any] = [:]
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/upload-file"):
                let body = String(data: MockURLProtocol.bodyData(for: req), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains(#"name="file"; filename="reply-photo.png""#))
                XCTAssertTrue(body.contains("reply-png"))
                let json = """
                {"id":"att-reply-image","workspace_id":"w1","issue_id":"i1","comment_id":null,
                 "uploader_type":"member","uploader_id":"u1","filename":"reply-photo.png",
                 "url":"https://cdn.example/reply-photo.png","download_url":"https://cdn.example/reply-photo.png",
                 "content_type":"image/png","size_bytes":9,"created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("POST", "/api/issues/i1/comments"):
                commentBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                let json = """
                {"id":"r1","content":"","author_id":"u1","author_type":"member",
                 "parent_id":"c1","issue_id":"i1","created_at":"2026-01-02T00:00:00Z",
                 "attachments":[]}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-02T00:00:00Z"))
            default:
                if let response = Self.emptyLatestProgressResponse(for: req) {
                    return response
                }
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        let uploaded = await vm.uploadReplyAttachment(
            parentId: "c1",
            filename: "reply-photo.png",
            data: Data("reply-png".utf8),
            contentType: "image/png"
        )
        let submitted = await vm.submitReply(parentId: "c1", content: " \n ")

        XCTAssertTrue(uploaded)
        XCTAssertTrue(submitted)
        XCTAssertEqual(commentBody["content"] as? String, "")
        XCTAssertEqual(commentBody["parent_id"] as? String, "c1")
        XCTAssertEqual(commentBody["attachment_ids"] as? [String], ["att-reply-image"])
        XCTAssertEqual(vm.replyAttachments["c1"]?.map(\.id) ?? [], [])
        XCTAssertNil(vm.error)
    }

    func test_updateCommentReplacesExistingComment() async throws {
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("PUT", "/api/comments/c1"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                XCTAssertEqual(body["content"] as? String, "Updated **markdown**")
                let json = """
                {"id":"c1","content":"Updated **markdown**","author_id":"u1","author_type":"member",
                 "parent_id":null,"issue_id":"i1","created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        vm.commentLoader.items = [
            Comment(
                id: "c1",
                content: "Original",
                authorId: "u1",
                authorType: "member",
                parentId: nil,
                issueId: "i1",
                createdAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
            )
        ]

        let didUpdate = await vm.updateComment(commentId: "c1", content: " Updated **markdown** ")

        XCTAssertTrue(didUpdate)
        XCTAssertEqual(vm.commentLoader.items.first?.content, "Updated **markdown**")
        XCTAssertNil(vm.error)
    }

    func test_deleteCommentRemovesCommentAndNestedReplies() async throws {
        var deletedPath: String?
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("DELETE", "/api/comments/c1"):
                deletedPath = req.url?.path
                return Self.response(for: req, body: Data(), status: 204)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let date = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        vm.commentLoader.items = [
            Comment(id: "c1", content: "Parent", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: date),
            Comment(id: "r1", content: "Reply", authorId: "u2", authorType: "member", parentId: "c1", issueId: "i1", createdAt: date),
            Comment(id: "r2", content: "Nested", authorId: "u3", authorType: "member", parentId: "r1", issueId: "i1", createdAt: date),
            Comment(id: "c2", content: "Sibling", authorId: "u4", authorType: "member", parentId: nil, issueId: "i1", createdAt: date),
        ]

        let didDelete = await vm.deleteComment(commentId: "c1")

        XCTAssertTrue(didDelete)
        XCTAssertEqual(deletedPath, "/api/comments/c1")
        XCTAssertEqual(vm.commentLoader.items.map(\.id), ["c2"])
        XCTAssertNil(vm.error)
    }

    func test_loadComments_marksLoadedForEmptyResponse() async throws {
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues/i1/comments")
            return Self.response(for: req, body: Data("[]".utf8))
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadComments()

        XCTAssertTrue(vm.didLoadComments)
        XCTAssertTrue(vm.commentLoader.items.isEmpty)
        XCTAssertNil(vm.commentsError)
    }

    func test_loadInitialDataStartsAgentRunsWithoutWaitingForSlowComments() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/issues/i1":
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-01T00:00:00Z"))
            case "/api/workspaces/w1/members":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/agents":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/projects":
                return Self.response(for: req, body: #"{"projects":[],"total":0}"#.data(using: .utf8)!)
            case "/api/issues/i1/comments":
                Thread.sleep(forTimeInterval: 2)
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/issues/i1/attachments":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/issues/i1/subscribers":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/issues/i1/task-runs":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/issues/i1/active-task":
                return Self.response(for: req, body: #"{"tasks":[]}"#.data(using: .utf8)!)
            case "/api/issues/i1/timeline":
                return Self.response(for: req, body: Data("[]".utf8))
            case "/api/issues/i1/usage":
                let json = """
                {"total_input_tokens":0,"total_output_tokens":0,
                 "total_cache_read_tokens":0,"total_cache_write_tokens":0,
                 "task_count":0}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/issues/i1/children":
                return Self.response(for: req, body: #"{"issues":[]}"#.data(using: .utf8)!)
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        let task = Task { await vm.loadInitialData() }

        let deadline = Date().addingTimeInterval(1)
        while !vm.isLoadingAgentRuns && !vm.didLoadAgentRuns && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(vm.isLoadingAgentRuns || vm.didLoadAgentRuns)
        XCTAssertFalse(vm.didLoadComments)
        await task.value
    }

    func test_loadMoreComments_appendsPaginatedCommentPages() async throws {
        var offsets: [String] = []
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues/i1/comments")
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            let offset = components?.queryItems?.first(where: { $0.name == "offset" })?.value ?? "0"
            offsets.append(offset)
            let commentId = offset == "0" ? "c1" : "c2"
            let content = offset == "0" ? "First page" : "Second page"
            let json = """
            {"comments":[{"id":"\(commentId)","content":"\(content)","author_id":"u1","author_type":"member",
              "parent_id":null,"issue_id":"i1","created_at":"2026-01-01T00:00:00Z"}],
             "total":2}
            """.data(using: .utf8)!
            return Self.response(for: req, body: json)
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadComments()
        await vm.loadMoreComments()

        XCTAssertEqual(offsets, ["0", "1"])
        XCTAssertEqual(vm.commentLoader.items.map(\.id), ["c1", "c2"])
        XCTAssertFalse(vm.commentLoader.hasMore)
        XCTAssertNil(vm.commentsError)
    }

    func test_submitComment_appendsCommentAndRefreshesIssueMetadata() async throws {
        var issueFetchCount = 0
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/issues/i1"):
                issueFetchCount += 1
                let updatedAt = issueFetchCount == 1
                    ? "2026-01-01T00:00:00Z"
                    : "2026-01-02T00:00:00Z"
                let json = Self.issueJSON(updatedAt: updatedAt)
                return Self.response(for: req, body: json)
            case ("POST", "/api/issues/i1/comments"):
                let json = """
                {"id":"c1","content":"Ship it","author_id":"u1","author_type":"member",
                 "parent_id":null,"issue_id":"i1","created_at":"2026-01-02T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                if let response = Self.emptyLatestProgressResponse(for: req) {
                    return response
                }
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadIssue()
        vm.commentDraft = "Ship it"
        await vm.submitComment()

        XCTAssertEqual(issueFetchCount, 2)
        XCTAssertEqual(vm.issue?.updatedAt, ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z"))
        XCTAssertEqual(vm.commentLoader.items.map(\.id), ["c1"])
        XCTAssertEqual(vm.commentDraft, "")
        XCTAssertNil(vm.error)
    }

    func test_submitComment_refreshesLatestProgressSources() async throws {
        var requestedPaths: [String] = []
        let client = makeClient { req in
            requestedPaths.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-02T00:00:00Z"))
            case ("POST", "/api/issues/i1/comments"):
                let json = """
                {"id":"c1","content":"@Codex please handle","author_id":"u1","author_type":"member",
                 "parent_id":null,"issue_id":"i1","created_at":"2026-01-02T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1/active-task"):
                let json = """
                {"tasks":[{
                    "id":"t1","agent_id":"a1","runtime_id":"r1","issue_id":"i1",
                    "status":"running","priority":0,"dispatched_at":null,
                    "started_at":"2026-01-02T00:00:00Z","completed_at":null,
                    "result":null,"error":null,"created_at":"2026-01-02T00:00:00Z"
                }]}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1/task-runs"):
                return Self.response(for: req, body: Data("[]".utf8))
            case ("GET", "/api/issues/i1/timeline"):
                return Self.response(for: req, body: Data("[]".utf8))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadIssue()
        vm.commentDraft = "@Codex please handle"
        await vm.submitComment()

        XCTAssertEqual(vm.activeTasks.map(\.id), ["t1"])
        XCTAssertTrue(vm.didLoadActiveTasks)
        XCTAssertTrue(vm.didLoadAgentRuns)
        XCTAssertTrue(vm.didLoadTimeline)
        XCTAssertTrue(requestedPaths.contains("GET /api/issues/i1/active-task"))
        XCTAssertTrue(requestedPaths.contains("GET /api/issues/i1/task-runs"))
        XCTAssertTrue(requestedPaths.contains("GET /api/issues/i1/timeline"))
        XCTAssertNil(vm.activeTasksError)
        XCTAssertNil(vm.agentRunsError)
        XCTAssertNil(vm.timelineError)
    }

    func test_submitComment_trimsContentBeforeSending() async throws {
        var submittedContent: String?
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/issues/i1/comments"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                submittedContent = body["content"] as? String
                let json = """
                {"id":"c1","content":"Ship it","author_id":"u1","author_type":"member",
                 "parent_id":null,"issue_id":"i1","created_at":"2026-01-02T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-02T00:00:00Z"))
            default:
                if let response = Self.emptyLatestProgressResponse(for: req) {
                    return response
                }
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        vm.commentDraft = " \nShip it\t "
        XCTAssertTrue(vm.canSubmitComment)
        await vm.submitComment()

        XCTAssertEqual(submittedContent, "Ship it")
        XCTAssertEqual(vm.commentDraft, "")
        XCTAssertNil(vm.error)
    }

    func test_appendMentionKeepsComposerReadableAndSerializesTypedMarkdown() throws {
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: makeClient { req in
            XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
            return Self.response(for: req, body: Data("{}".utf8), status: 500)
        })

        vm.commentDraft = "Please check"
        vm.appendMention(MentionCandidate(type: .agent, entityId: "a1", displayName: "David[TF]", subtitle: "Agent"))
        vm.appendMention(MentionCandidate(type: .person, entityId: "u1", displayName: "Parker", subtitle: "p@example.com"))
        vm.appendMention(MentionCandidate(type: .squad, entityId: "s1", displayName: "Design Squad", subtitle: "Squad"))

        XCTAssertEqual(vm.commentDraft, "Please check @David[TF] @Parker @Design Squad ")
        XCTAssertEqual(
            vm.serializedCommentDraft(),
            #"Please check [@David\[TF\]](mention://agent/a1) [@Parker](mention://member/u1) [@Design Squad](mention://squad/s1) "#
        )
    }

    func test_commentComposerUsesCompactKeyboardDismissControl() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Multi-Casual/Features/Issues/IssueDetailView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(
            source.contains("ToolbarItemGroup(placement: .keyboard)"),
            "The comment composer should not add a full-width keyboard toolbar that can cover the input."
        )
        XCTAssertTrue(
            source.contains("IssueDetailDismissKeyboardButton"),
            "The comment composer should expose a compact keyboard dismiss button near the editor controls."
        )
    }

    func test_mentionPickerDoesNotUseSystemMenuWithCustomRows() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Multi-Casual/Features/Issues/IssueDetailView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(
            source.contains("MentionCandidatePickerSheet"),
            "Mention choices should use a stable picker presentation so long names are not clipped by the system Menu near the keyboard."
        )
        XCTAssertFalse(
            source.contains("private struct AgentMentionMenu"),
            "Agent mention picker should not rely on a SwiftUI Menu with custom Avatar/Markdown rows."
        )
    }

    func test_commentRowsExposeReplyAsInlineAction() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Multi-Casual/Features/Issues/IssueDetailView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(
            source.contains("CommentInlineReplyButton"),
            "Reply should be visible directly on each comment row instead of hidden behind the overflow menu."
        )
        XCTAssertFalse(
            source.contains(#"Label(AppStrings.localized("Reply", language: appLanguage), systemImage: "arrowshape.turn.up.left")"#),
            "The overflow menu should not be the only Reply entry point."
        )
    }

    func test_replyUsesBottomComposerInsteadOfInlineRowEditor() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Multi-Casual/Features/Issues/IssueDetailView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(
            source.contains("activeReplyTarget"),
            "IssueDetailView should own the selected reply target so the bottom composer can switch modes."
        )
        XCTAssertTrue(
            source.contains("IssueDetailReplyInput"),
            "Reply mode should render a dedicated bottom reply input in place of the normal comment input."
        )
        XCTAssertFalse(
            source.contains("IssueDetailCancelReplyButton"),
            "The bottom reply composer should not add a second cancel button when keyboard dismissal already collapses the composer."
        )
        XCTAssertTrue(
            source.contains("CommentReplyDismissKeyboardButton"),
            "The bottom reply composer should provide keyboard dismissal as the way to collapse the expanded composer."
        )
        XCTAssertFalse(
            source.contains("if isReplying"),
            "Comment rows should not open inline reply editors that compete with the bottom composer."
        )
        XCTAssertFalse(
            source.contains("CommentReplyEditor"),
            "Reply text entry should live in the bottom composer, not inside each comment row."
        )
    }

    func test_commentMarkdownContextResolvesMemberAndAgentMentionNames() throws {
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: makeClient { req in
            XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
            return Self.response(for: req, body: Data("{}".utf8), status: 500)
        })
        vm.subscriberMembers = [
            WorkspaceMember(
                id: "m1",
                workspaceId: "w1",
                userId: "u1",
                role: "member",
                name: "Parker Zhang",
                email: "parker@example.com",
                avatarUrl: nil
            )
        ]
        vm.subscriberAgents = [
            try Self.decodeAgent(id: "a1", name: "Codex Worker")
        ]
        vm.subscriberSquads = [
            Squad(id: "s1", workspaceId: "w1", name: "Design Squad")
        ]

        let context = vm.commentMarkdownContext(issuePrefix: "PAR")

        XCTAssertEqual(context.mentionDisplayNamesByURL["mention://member/u1"], "Parker Zhang")
        XCTAssertEqual(context.mentionDisplayNamesByURL["mention://member/m1"], "Parker Zhang")
        XCTAssertEqual(context.mentionDisplayNamesByURL["mention://user/u1"], "Parker Zhang")
        XCTAssertEqual(context.mentionDisplayNamesByURL["mention://user/m1"], "Parker Zhang")
        XCTAssertEqual(context.mentionDisplayNamesByURL["mention://agent/a1"], "Codex Worker")
        XCTAssertEqual(context.mentionDisplayNamesByURL["mention://squad/s1"], "Design Squad")
        XCTAssertEqual(context.issueReferencePrefixes, ["PAR"])
    }

    func test_resolveIssueReferenceSearchesByIdentifierAndReturnsExactIssue() async throws {
        var queryItems: [URLQueryItem] = []
        let client = makeClient { req in
            XCTAssertEqual(req.url?.path, "/api/issues/search")
            queryItems = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Self.response(
                for: req,
                body: Data("""
                {"issues":[
                  {"id":"i-other","identifier":"PAR-730","number":730,"title":"Wrong","description":null,
                   "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
                  {"id":"i73","identifier":"PAR-73","number":73,"title":"Right","description":null,
                   "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
                ],"has_more":false,"total":2}
                """.utf8)
            )
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        let issue = try await vm.resolveIssueReference("PAR-73")

        XCTAssertEqual(issue.id, "i73")
        XCTAssertEqual(queryItems.first(where: { $0.name == "q" })?.value, "PAR-73")
        XCTAssertEqual(queryItems.first(where: { $0.name == "workspace_id" })?.value, "w1")
        XCTAssertEqual(queryItems.first(where: { $0.name == "include_closed" })?.value, "true")
    }

    func test_submitCommentSendsAgentMentionMarkdownForBackendTrigger() async throws {
        var submittedContent: String?
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/issues/i1/comments"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                submittedContent = body["content"] as? String
                let json = """
                {"id":"c1","content":"Mentioned","author_id":"u1","author_type":"member",
                 "parent_id":null,"issue_id":"i1","created_at":"2026-01-02T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-02T00:00:00Z"))
            default:
                if let response = Self.emptyLatestProgressResponse(for: req) {
                    return response
                }
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        let agent = try Self.decodeAgent(id: "a1", name: "Codex")

        vm.commentDraft = "Take a look"
        vm.appendMention(MentionCandidate(type: .agent, entityId: agent.id, displayName: agent.name, subtitle: "Agent"))
        XCTAssertEqual(vm.commentDraft, "Take a look @Codex ")
        await vm.submitComment()

        XCTAssertEqual(submittedContent, "Take a look [@Codex](mention://agent/a1)")
        XCTAssertEqual(vm.commentDraft, "")
        XCTAssertNil(vm.error)
    }

    func test_uploadCommentAttachmentAndSubmitIncludesAttachmentIds() async throws {
        var requests: [String] = []
        var commentBody: [String: Any] = [:]
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/upload-file"):
                let body = String(data: MockURLProtocol.bodyData(for: req), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains(#"name="file"; filename="screen.png""#))
                XCTAssertTrue(body.contains("png-data"))
                let json = """
                {"id":"att1","workspace_id":"w1","issue_id":"i1","comment_id":null,
                 "uploader_type":"member","uploader_id":"u1","filename":"screen.png",
                 "url":"https://cdn.example/screen.png","download_url":"https://cdn.example/screen.png",
                 "content_type":"image/png","size_bytes":8,"created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("POST", "/api/issues/i1/comments"):
                commentBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                let json = """
                {"id":"c1","content":"With attachment","author_id":"u1","author_type":"member",
                 "parent_id":null,"issue_id":"i1","created_at":"2026-01-02T00:00:00Z",
                 "attachments":[]}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-02T00:00:00Z"))
            default:
                if let response = Self.emptyLatestProgressResponse(for: req) {
                    return response
                }
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        vm.commentDraft = "With attachment"

        let uploaded = await vm.uploadCommentAttachment(
            filename: "screen.png",
            data: Data("png-data".utf8),
            contentType: "image/png"
        )
        await vm.submitComment()

        XCTAssertTrue(uploaded)
        XCTAssertEqual(commentBody["attachment_ids"] as? [String], ["att1"])
        XCTAssertTrue(vm.commentAttachments.isEmpty)
        XCTAssertEqual(Set(requests), Set([
            "POST /api/upload-file",
            "POST /api/issues/i1/comments",
            "GET /api/issues/i1",
            "GET /api/issues/i1/active-task",
            "GET /api/issues/i1/task-runs",
            "GET /api/issues/i1/timeline",
        ]))
        XCTAssertNil(vm.error)
    }

    func test_submitCommentAllowsAttachmentOnlyImageComment() async throws {
        var commentBody: [String: Any] = [:]
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/upload-file"):
                let body = String(data: MockURLProtocol.bodyData(for: req), encoding: .utf8) ?? ""
                XCTAssertTrue(body.contains(#"name="file"; filename="photo.png""#))
                XCTAssertTrue(body.contains("png-data"))
                let json = """
                {"id":"att-image","workspace_id":"w1","issue_id":"i1","comment_id":null,
                 "uploader_type":"member","uploader_id":"u1","filename":"photo.png",
                 "url":"https://cdn.example/photo.png","download_url":"https://cdn.example/photo.png",
                 "content_type":"image/png","size_bytes":8,"created_at":"2026-01-01T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("POST", "/api/issues/i1/comments"):
                commentBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                let json = """
                {"id":"c1","content":"","author_id":"u1","author_type":"member",
                 "parent_id":null,"issue_id":"i1","created_at":"2026-01-02T00:00:00Z",
                 "attachments":[]}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-02T00:00:00Z"))
            default:
                if let response = Self.emptyLatestProgressResponse(for: req) {
                    return response
                }
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        let uploaded = await vm.uploadCommentAttachment(
            filename: "photo.png",
            data: Data("png-data".utf8),
            contentType: "image/png"
        )
        XCTAssertTrue(uploaded)
        XCTAssertTrue(vm.canSubmitComment)

        await vm.submitComment()

        XCTAssertEqual(commentBody["content"] as? String, "")
        XCTAssertEqual(commentBody["attachment_ids"] as? [String], ["att-image"])
        XCTAssertTrue(vm.commentAttachments.isEmpty)
        XCTAssertNil(vm.error)
    }

    func test_deleteIssue_callsDesktopEndpointAndMarksDeleted() async throws {
        var capturedMethod: String?
        let client = makeClient { req in
            capturedMethod = req.httpMethod
            XCTAssertEqual(req.url?.path, "/api/issues/i1")
            return Self.response(for: req, body: Data(), status: 204)
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.deleteIssue()

        XCTAssertEqual(capturedMethod, "DELETE")
        XCTAssertTrue(vm.didDeleteIssue)
        XCTAssertNil(vm.deleteIssueError)
    }

    func test_submitComment_ignoresWhitespaceOnlyDraft() async throws {
        var requestCount = 0
        let client = makeClient { req in
            requestCount += 1
            XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
            return Self.response(for: req, body: Data("{}".utf8), status: 404)
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        vm.commentDraft = " \n\t "
        XCTAssertFalse(vm.canSubmitComment)
        await vm.submitComment()

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(vm.commentDraft, " \n\t ")
        XCTAssertFalse(vm.isSubmittingComment)
        XCTAssertNil(vm.error)
    }

    func test_updateStatus_replacesIssueWithServerResponse() async throws {
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-01T00:00:00Z"))
            case ("PUT", "/api/issues/i1"):
                let body = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                XCTAssertEqual(body["status"] as? String, "blocked")
                XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
                let json = """
                {"id":"i1","identifier":"PAR-1","number":1,"title":"T","description":null,
                 "status":"blocked","priority":"none","assignee_id":null,"assignee_type":null,
                 "project_id":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
                 "updated_at":"2026-01-02T00:00:00Z"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadIssue()
        await vm.updateStatus(.blocked)

        XCTAssertEqual(vm.issue?.status, .blocked)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isUpdatingIssue)
    }

    func test_loadAndDeleteAttachmentsKeepIssueAttachmentsInSync() async throws {
        var requests: [(method: String?, path: String, query: String?)] = []
        let client = makeClient { req in
            requests.append((req.httpMethod, req.url?.path ?? "", req.url?.query))
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/issues/i1"):
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-01T00:00:00Z"))
            case ("GET", "/api/issues/i1/attachments"):
                return Self.response(for: req, body: Self.attachmentsJSON())
            case ("DELETE", "/api/attachments/att1"):
                return Self.response(for: req, body: Data(), status: 204)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadIssue()
        await vm.loadAttachments()
        await vm.deleteAttachment(id: "att1")

        XCTAssertEqual(vm.issue?.attachments.map(\.id), ["att2"])
        XCTAssertNil(vm.attachmentsError)
        XCTAssertTrue(vm.deletingAttachmentIds.isEmpty)
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "DELETE"])
        XCTAssertEqual(requests.map(\.path), ["/api/issues/i1", "/api/issues/i1/attachments", "/api/attachments/att1"])
        XCTAssertEqual(requests.map(\.query), ["workspace_id=w1", "workspace_id=w1", "workspace_id=w1"])
    }

    func test_commentAuthorNameResolvesMemberAndAgentNamesFromMetadata() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/issues/i1":
                return Self.response(for: req, body: Self.issueJSON(updatedAt: "2026-01-01T00:00:00Z"))
            case "/api/workspaces/w1/members":
                let json = """
                [{"id":"wm1","workspace_id":"w1","user_id":"u1","name":"Parker","email":"parker@example.com","role":"admin","created_at":"2026-01-01T00:00:00Z"}]
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
                return Self.response(for: req, body: #"{"projects":[],"total":0}"#.data(using: .utf8)!)
            case "/api/squads":
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)

        await vm.loadIssue()
        await vm.loadMetadata()

        let memberComment = Comment(
            id: "c1",
            content: "hello",
            authorId: "u1",
            authorType: "member",
            parentId: nil,
            issueId: "i1",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let agentComment = Comment(
            id: "c2",
            content: "done",
            authorId: "a1",
            authorType: "agent",
            parentId: nil,
            issueId: "i1",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(vm.commentAuthorName(for: memberComment), "Parker")
        XCTAssertEqual(vm.commentAuthorName(for: agentComment), "Codex")
    }

    func test_commentThreadResolutionKind_replyResolutionPinsTheResolvedReply() {
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: makeClient { req in
            XCTFail("No network expected")
            return Self.response(for: req, body: Data("{}".utf8), status: 500)
        })
        let date = Date(timeIntervalSince1970: 10)
        vm.commentLoader.items = [
            Comment(id: "c1", content: "Root", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: date),
            Comment(id: "r1", content: "Answer", authorId: "u2", authorType: "member", parentId: "c1", issueId: "i1", createdAt: date,
                    resolvedAt: date, resolvedByType: "member", resolvedByID: "u2"),
            Comment(id: "r2", content: "Other reply", authorId: "u3", authorType: "member", parentId: "c1", issueId: "i1", createdAt: date),
        ]

        let thread = vm.displayedCommentThreads.first { $0.id == "c1" }
        // A REPLY is resolved -> kind is .reply and resolvedComment is that reply.
        guard case .reply(let resolved)? = thread?.resolutionKind else {
            XCTFail("Expected .reply resolution"); return
        }
        XCTAssertEqual(resolved.id, "r1")
        XCTAssertEqual(thread?.resolvedComment?.id, "r1")
        XCTAssertTrue(thread?.isResolved ?? false)
    }

    func test_commentThreadResolutionKind_rootResolutionFoldsTheWholeThread() {
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: makeClient { req in
            XCTFail("No network expected")
            return Self.response(for: req, body: Data("{}".utf8), status: 500)
        })
        let date = Date(timeIntervalSince1970: 10)
        vm.commentLoader.items = [
            Comment(id: "c1", content: "Root", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: date,
                    resolvedAt: date, resolvedByType: "member", resolvedByID: "u1"),
            Comment(id: "r1", content: "Answer", authorId: "u2", authorType: "member", parentId: "c1", issueId: "i1", createdAt: date),
        ]

        let thread = vm.displayedCommentThreads.first { $0.id == "c1" }
        // The ROOT is resolved -> kind is .root (whole-thread fold).
        if case .root? = thread?.resolutionKind {} else { XCTFail("Expected .root resolution") }
        XCTAssertEqual(thread?.resolvedComment?.id, "c1")
        XCTAssertTrue(thread?.isResolved ?? false)
    }

    func test_resolveComment_marksReplyResolvedAndClearsSiblingResolution() async throws {
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/comments/r2/resolve"):
                let json = """
                {"id":"r2","content":"Answer","author_id":"u3","author_type":"member",
                 "parent_id":"c1","issue_id":"i1","created_at":"2026-01-01T00:00:00Z",
                 "resolved_at":"2026-02-02T00:00:00Z","resolved_by_type":"member","resolved_by_id":"u3"}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        let date = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        vm.commentLoader.items = [
            Comment(id: "c1", content: "Root", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: date),
            Comment(id: "r1", content: "Old answer", authorId: "u2", authorType: "member", parentId: "c1", issueId: "i1", createdAt: date,
                    resolvedAt: date, resolvedByType: "member", resolvedByID: "u2"),
            Comment(id: "r2", content: "Answer", authorId: "u3", authorType: "member", parentId: "c1", issueId: "i1", createdAt: date),
        ]

        await vm.resolveComment(commentId: "r2")

        let r1 = vm.commentLoader.items.first { $0.id == "r1" }
        let r2 = vm.commentLoader.items.first { $0.id == "r2" }
        XCTAssertNotNil(r2?.resolvedAt, "r2 should be resolved")
        XCTAssertEqual(r2?.resolvedByID, "u3")
        XCTAssertNil(r1?.resolvedAt, "single-resolution: r1's old resolution should be cleared")
        XCTAssertNil(vm.error)
        XCTAssertTrue(vm.resolvingCommentIds.isEmpty, "resolve id should clear after completion")
    }

    func test_resolveComment_revertsOnFailureKeepingPriorResolution() async throws {
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("POST", "/api/comments/r2/resolve"):
                return Self.response(for: req, body: Data("{}".utf8), status: 500)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        let date = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        vm.commentLoader.items = [
            Comment(id: "c1", content: "Root", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: date),
            Comment(id: "r1", content: "Old answer", authorId: "u2", authorType: "member", parentId: "c1", issueId: "i1", createdAt: date,
                    resolvedAt: date, resolvedByType: "member", resolvedByID: "u2"),
            Comment(id: "r2", content: "Answer", authorId: "u3", authorType: "member", parentId: "c1", issueId: "i1", createdAt: date),
        ]

        await vm.resolveComment(commentId: "r2")

        let r1 = vm.commentLoader.items.first { $0.id == "r1" }
        let r2 = vm.commentLoader.items.first { $0.id == "r2" }
        XCTAssertNil(r2?.resolvedAt, "optimistic resolve on r2 should revert on failure")
        XCTAssertNotNil(r1?.resolvedAt, "r1's prior resolution should be restored")
        XCTAssertNotNil(vm.error, "failure should surface an error")
    }

    func test_unresolveComment_clearsResolveState() async throws {
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("DELETE", "/api/comments/r1/resolve"):
                let json = """
                {"id":"r1","content":"Answer","author_id":"u2","author_type":"member",
                 "parent_id":"c1","issue_id":"i1","created_at":"2026-01-01T00:00:00Z",
                 "resolved_at":null,"resolved_by_type":null,"resolved_by_id":null}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        let date = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        vm.commentLoader.items = [
            Comment(id: "c1", content: "Root", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: date),
            Comment(id: "r1", content: "Answer", authorId: "u2", authorType: "member", parentId: "c1", issueId: "i1", createdAt: date,
                    resolvedAt: date, resolvedByType: "member", resolvedByID: "u2"),
        ]

        await vm.unresolveComment(commentId: "r1")

        let r1 = vm.commentLoader.items.first { $0.id == "r1" }
        XCTAssertNil(r1?.resolvedAt, "r1 should be unresolved")
        XCTAssertNil(r1?.resolvedByID)
        XCTAssertNil(vm.error)
    }

    func test_silentRefreshComments_mergesByIdWithoutClearing() async throws {
        let date = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/issues/i1/comments"):
                // Fresh first page: c1 (updated) + a brand-new r3. r1/r2 are not
                // returned but must be preserved as already-loaded deeper items.
                let json = """
                [{"id":"c1","content":"Root updated","author_id":"u1","author_type":"member","parent_id":null,"issue_id":"i1","created_at":"2026-01-01T00:00:00Z"},
                 {"id":"r3","content":"New","author_id":"u4","author_type":"member","parent_id":"c1","issue_id":"i1","created_at":"2026-01-03T00:00:00Z"}]
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = IssueDetailViewModel(issueId: "i1", workspaceId: "w1", api: client)
        vm.commentLoader.items = [
            Comment(id: "c1", content: "Root", authorId: "u1", authorType: "member", parentId: nil, issueId: "i1", createdAt: date),
            Comment(id: "r1", content: "Reply", authorId: "u2", authorType: "member", parentId: "c1", issueId: "i1", createdAt: date),
            Comment(id: "r2", content: "Nested", authorId: "u3", authorType: "member", parentId: "r1", issueId: "i1", createdAt: date),
        ]
        vm.didLoadComments = true

        await vm.silentRefreshComments()

        let ids = vm.commentLoader.items.map(\.id)
        XCTAssertTrue(ids.contains("c1"), "c1 preserved/refreshed")
        XCTAssertTrue(ids.contains("r3"), "new r3 from fresh page merged in")
        XCTAssertTrue(ids.contains("r1") && ids.contains("r2"), "already-loaded deeper replies r1/r2 must NOT be cleared")
        XCTAssertEqual(vm.commentLoader.items.first { $0.id == "c1" }?.content, "Root updated", "c1 fields replaced with fresh values")
        XCTAssertNil(vm.commentsError)
    }

    private func makeClient(
        workspaceId: String? = nil,
        workspaceSlug: String? = nil,
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = handler
        return APIClient(
            session: URLSession(configuration: config),
            token: "test-token",
            workspaceSlugProvider: { workspaceSlug },
            workspaceIdProvider: { workspaceId }
        )
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

    private static func emptyLatestProgressResponse(for request: URLRequest) -> (HTTPURLResponse, Data)? {
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/api/issues/i1/active-task"):
            return response(for: request, body: #"{"tasks":[]}"#.data(using: .utf8)!)
        case ("GET", "/api/issues/i1/task-runs"),
             ("GET", "/api/issues/i1/timeline"):
            return response(for: request, body: Data("[]".utf8))
        default:
            return nil
        }
    }

    private static func issueJSON(
        id: String = "i1",
        identifier: String = "PAR-1",
        title: String = "T",
        parentIssueId: String? = nil,
        updatedAt: String
    ) -> Data {
        let parent = parentIssueId.map { #""\#($0)""# } ?? "null"
        return """
        {"id":"\(id)","identifier":"\(identifier)","number":1,"title":"\(title)","description":null,
         "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
         "parent_issue_id":\(parent),"project_id":null,"workspace_id":"w1","created_at":"2026-01-01T00:00:00Z",
         "updated_at":"\(updatedAt)"}
        """.data(using: .utf8)!
    }

    private static func decodeAgent(id: String, name: String) throws -> Agent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Agent.self, from: agentJSON(id: id, name: name))
    }

    private static func agentJSON(id: String, name: String) -> Data {
        """
        {"id":"\(id)","workspace_id":"w1","runtime_id":"r1","name":"\(name)",
          "description":"","instructions":"","avatar_url":null,"runtime_mode":"cloud",
          "runtime_config":{},"custom_env":{},"custom_args":[],"custom_env_redacted":false,
          "visibility":"workspace","status":"active","max_concurrent_tasks":1,
          "model":"gpt","owner_id":null,"skills":[],"created_at":"2026-01-01T00:00:00Z",
          "updated_at":"2026-01-01T00:00:00Z","archived_at":null,"archived_by":null}
        """.data(using: .utf8)!
    }

    private static func attachmentsJSON() -> Data {
        """
        [{"id":"att1","workspace_id":"w1","issue_id":"i1","comment_id":null,
          "uploader_type":"member","uploader_id":"u1","filename":"spec.md",
          "url":"https://cdn.example/spec.md","download_url":"https://cdn.example/spec.md",
          "content_type":"text/markdown","size_bytes":11,"created_at":"2026-01-01T00:00:00Z"},
         {"id":"att2","workspace_id":"w1","issue_id":"i1","comment_id":null,
          "uploader_type":"member","uploader_id":"u1","filename":"screen.png",
          "url":"https://cdn.example/screen.png","download_url":"https://cdn.example/screen.png",
          "content_type":"image/png","size_bytes":42,"created_at":"2026-01-01T00:00:00Z"}]
        """.data(using: .utf8)!
    }
}
