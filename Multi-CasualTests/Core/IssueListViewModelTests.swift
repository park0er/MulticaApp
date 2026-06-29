import XCTest
@testable import MultiCasual

@MainActor
final class IssueListViewModelTests: XCTestCase {
    func test_issueListViewAutoRefreshesWhileVisibleAndActive() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Multi-Casual/Features/Issues/IssueListView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("@State private var autoRefreshTask: Task<Void, Never>?"))
        XCTAssertTrue(source.contains("private let autoRefreshIntervalNanoseconds"))
        XCTAssertTrue(source.contains("startAutoRefresh()"))
        XCTAssertTrue(source.contains("stopAutoRefresh()"))
        XCTAssertTrue(source.contains("await viewModel?.refreshIfIdle()"))
    }

    func test_issueSearchRunsAsSearchTextChanges() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Multi-Casual/Features/Issues/IssueListView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(
            source.contains("@State private var searchTask: Task<Void, Never>?"),
            "Issue search should debounce live text changes instead of relying only on keyboard submit."
        )
        XCTAssertTrue(
            source.contains("scheduleSearch(query: newValue)"),
            "Search text changes should schedule a real IssueListViewModel search."
        )
        XCTAssertTrue(
            source.contains("try await Task.sleep(nanoseconds: searchDebounceNanoseconds)"),
            "Live issue search should be debounced to avoid a request for every keystroke."
        )
    }

    func test_issueSearchRendersFlatResultsInServerRelevanceOrder() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Multi-Casual/Features/Issues/IssueListView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(
            source.contains("if vm.isSearching"),
            "Search mode should switch away from status-grouped rendering so server relevance is not buried under status sections."
        )
        XCTAssertTrue(
            source.contains("ForEach(vm.searchResults)"),
            "Search mode should render the flat server-ordered results."
        )
    }

    func test_loadNext_withoutWorkspaceSurfacesActionableError() async throws {
        let vm = IssueListViewModel(api: makeClient(), authSession: AuthSession(userDefaults: makeUserDefaults()))

        await vm.loadNext()

        XCTAssertEqual(vm.lastError?.localizedDescription, "Pick a workspace before opening Issues.")
    }

    func test_loadNext_fetchesFirstPageForEachIssueListStatus() async throws {
        var requestedStatuses: [String] = []
        let client = makeClient { req in
            if req.url?.path == "/api/pins" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            }
            if req.url?.path == "/api/issues/child-progress" {
                return Self.childProgressResponse(for: req, progress: [])
            }
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            guard let status = components?.queryItems?.first(where: { $0.name == "status" })?.value else {
                XCTFail("Expected status query in \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
            requestedStatuses.append(status)
            return Self.issuesResponse(for: req, status: status, total: 1)
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()

        XCTAssertEqual(requestedStatuses, ["backlog", "todo", "in_progress", "in_review", "done", "blocked", "cancelled"])
        XCTAssertEqual(vm.loader.items.map(\.status), [.backlog, .todo, .inProgress, .inReview, .done, .blocked, .cancelled])
        XCTAssertEqual(vm.issuesByStatus[.todo]?.map(\.id), ["todo-1"])
        XCTAssertEqual(vm.issuesByStatus[.cancelled]?.map(\.id), ["cancelled-1"])
        XCTAssertFalse(vm.loader.hasMore)
    }

    func test_loadNext_paginatesNextStatusBucketWithRemainingItems() async throws {
        var requested: [(status: String, offset: String?)] = []
        let client = makeClient { req in
            if req.url?.path == "/api/pins" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            }
            if req.url?.path == "/api/issues/child-progress" {
                return Self.childProgressResponse(for: req, progress: [])
            }
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            guard let status = components?.queryItems?.first(where: { $0.name == "status" })?.value else {
                XCTFail("Expected status query in \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
            let offset = components?.queryItems?.first(where: { $0.name == "offset" })?.value
            requested.append((status, offset))
            if status == "todo" && offset == "0" {
                return Self.issuesResponse(for: req, status: status, suffix: "1", total: 2)
            }
            if status == "todo" && offset == "1" {
                return Self.issuesResponse(for: req, status: status, suffix: "2", total: 2)
            }
            return Self.issuesResponse(for: req, status: status, total: 0)
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        await vm.loadNext()

        XCTAssertTrue(requested.contains { $0.status == "todo" && $0.offset == "1" })
        XCTAssertEqual(vm.issuesByStatus[.todo]?.map(\.id), ["todo-1", "todo-2"])
        XCTAssertFalse(vm.loader.hasMore)
    }

    func test_loadNext_appliesPriorityFilterToStatusBuckets() async throws {
        var requestedPriorities: [String?] = []
        let client = makeClient { req in
            if req.url?.path == "/api/pins" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            }
            if req.url?.path == "/api/issues/child-progress" {
                return Self.childProgressResponse(for: req, progress: [])
            }
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
            requestedPriorities.append(components?.queryItems?.first(where: { $0.name == "priority" })?.value)
            return Self.issuesResponse(for: req, status: status, priority: "urgent", total: 1)
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())
        vm.priorityFilter = .urgent

        await vm.loadNext()

        XCTAssertEqual(requestedPriorities, Array(repeating: "urgent", count: IssueStatus.listCases.count))
        XCTAssertEqual(Set(vm.loader.items.map(\.priority)), [.urgent])
    }

    func test_loadNextLoadsChildProgressForIssueRows() async throws {
        var requestedPaths: [String] = []
        let client = makeClient { req in
            requestedPaths.append(req.url?.path ?? "")
            if req.url?.path == "/api/pins" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            }
            if req.url?.path == "/api/issues/child-progress" {
                return Self.childProgressResponse(
                    for: req,
                    progress: [
                        #"{"parent_issue_id":"todo-1","total":3,"done":1}"#
                    ]
                )
            }
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
            if status == "todo" {
                return Self.issuesResponse(for: req, status: status, total: 1)
            }
            return Self.emptyIssuesResponse(for: req)
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()

        XCTAssertTrue(requestedPaths.contains("/api/issues/child-progress"))
        XCTAssertEqual(vm.childProgressText(for: vm.loader.items[0]), "1/3")
    }

    func test_myIssuesAssignedScopeFiltersByCurrentUserAssignee() async throws {
        var issueQueries: [[URLQueryItem]] = []
        let client = makeClient { req in
            if req.url?.path == "/api/pins" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            }
            if req.url?.path == "/api/issues/child-progress" {
                return Self.childProgressResponse(for: req, progress: [])
            }
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            issueQueries.append(components?.queryItems ?? [])
            let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
            return Self.issuesResponse(for: req, status: status, total: 0)
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession(), scope: .assignedToMe)

        await vm.loadNext()

        XCTAssertEqual(issueQueries.count, IssueStatus.listCases.count)
        XCTAssertTrue(issueQueries.allSatisfy { $0.first(where: { $0.name == "assignee_id" })?.value == "u1" })
        XCTAssertTrue(issueQueries.allSatisfy { $0.first(where: { $0.name == "creator_id" }) == nil })
    }

    func test_myIssuesCreatedScopeFiltersByCurrentUserCreator() async throws {
        var issueQueries: [[URLQueryItem]] = []
        let client = makeClient { req in
            if req.url?.path == "/api/pins" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            }
            if req.url?.path == "/api/issues/child-progress" {
                return Self.childProgressResponse(for: req, progress: [])
            }
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            issueQueries.append(components?.queryItems ?? [])
            let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
            return Self.issuesResponse(for: req, status: status, total: 0)
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession(), scope: .createdByMe)

        await vm.loadNext()

        XCTAssertEqual(issueQueries.count, IssueStatus.listCases.count)
        XCTAssertTrue(issueQueries.allSatisfy { $0.first(where: { $0.name == "creator_id" })?.value == "u1" })
        XCTAssertTrue(issueQueries.allSatisfy { $0.first(where: { $0.name == "assignee_id" }) == nil })
    }

    func test_myIssuesAgentScopeFiltersByCurrentUsersAgents() async throws {
        var issueQueries: [[URLQueryItem]] = []
        var agentRequests = 0
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/agents":
                agentRequests += 1
                return Self.response(
                    for: req,
                    body: Data("""
                    [
                        {"id":"a2","workspace_id":"w1","runtime_id":"r1","name":"Other","description":"","instructions":"","avatar_url":null,"runtime_mode":"cloud","runtime_config":{},"custom_env":{},"custom_args":[],"custom_env_redacted":false,"visibility":"workspace","status":"active","max_concurrent_tasks":1,"model":"gpt","owner_id":"u2","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","archived_at":null,"archived_by":null},
                        {"id":"a1","workspace_id":"w1","runtime_id":"r1","name":"Mine","description":"","instructions":"","avatar_url":null,"runtime_mode":"cloud","runtime_config":{},"custom_env":{},"custom_args":[],"custom_env_redacted":false,"visibility":"workspace","status":"active","max_concurrent_tasks":1,"model":"gpt","owner_id":"u1","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","archived_at":null,"archived_by":null},
                        {"id":"a3","workspace_id":"w1","runtime_id":"r1","name":"Also Mine","description":"","instructions":"","avatar_url":null,"runtime_mode":"cloud","runtime_config":{},"custom_env":{},"custom_args":[],"custom_env_redacted":false,"visibility":"workspace","status":"active","max_concurrent_tasks":1,"model":"gpt","owner_id":"u1","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","archived_at":null,"archived_by":null}
                    ]
                    """.utf8)
                )
            case "/api/pins":
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case "/api/issues/child-progress":
                return Self.childProgressResponse(for: req, progress: [])
            case "/api/issues":
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                issueQueries.append(components?.queryItems ?? [])
                let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
                return Self.issuesResponse(for: req, status: status, total: 0)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession(), scope: .myAgents)

        await vm.loadNext()

        XCTAssertEqual(agentRequests, 1)
        XCTAssertEqual(issueQueries.count, IssueStatus.listCases.count)
        XCTAssertTrue(issueQueries.allSatisfy { $0.first(where: { $0.name == "assignee_ids" })?.value == "a1,a3" })
        XCTAssertTrue(issueQueries.allSatisfy { $0.first(where: { $0.name == "assignee_id" }) == nil })
    }

    func test_searchQueryUsesDesktopSearchEndpointAndReplacesIssueBuckets() async throws {
        var requested: [(path: String, query: [URLQueryItem])] = []
        let client = makeClient { req in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            requested.append((req.url?.path ?? "", components?.queryItems ?? []))
            switch req.url?.path {
            case "/api/issues/search":
                let json = """
                {"issues":[{"id":"i1","identifier":"PAR-1","number":1,
                 "title":"Search hit","description":null,"status":"in_review","priority":"high",
                 "assignee_id":null,"assignee_type":null,"project_id":null,"workspace_id":"w1",
                 "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}],
                 "has_more":false,"total":1}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/pins":
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case "/api/issues/child-progress":
                return Self.childProgressResponse(for: req, progress: [])
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.setSearchQuery("Search hit")

        XCTAssertEqual(vm.searchQuery, "Search hit")
        XCTAssertEqual(vm.loader.items.map(\.id), ["i1"])
        XCTAssertEqual(vm.issuesByStatus[.inReview]?.map(\.id), ["i1"])
        XCTAssertFalse(vm.loader.hasMore)
        XCTAssertEqual(requested.first?.path, "/api/issues/search")
        XCTAssertEqual(requested.first?.query.first(where: { $0.name == "q" })?.value, "Search hit")
        XCTAssertEqual(requested.first?.query.first(where: { $0.name == "workspace_id" })?.value, "w1")
        XCTAssertFalse(requested.first?.query.contains(where: { $0.name == "status" }) ?? true)
        XCTAssertFalse(
            requested.map(\.path).contains("/api/issues/child-progress"),
            "Live search should match the web client and not block results behind unrelated child-progress refreshes."
        )
        XCTAssertNil(vm.lastError)
    }

    func test_searchQueryPreservesServerRelevanceOrder() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/issues/search":
                let json = """
                {"issues":[
                  {"id":"done-hit","identifier":"PAR-9","number":9,"title":"Best match","description":null,
                   "status":"done","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1","position":99,
                   "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-03T00:00:00Z"},
                  {"id":"todo-hit","identifier":"PAR-1","number":1,"title":"Lower match","description":null,
                   "status":"todo","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1","position":0,
                   "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}
                ],"has_more":false,"total":2}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/pins":
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case "/api/issues/child-progress":
                return Self.childProgressResponse(for: req, progress: [])
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())
        vm.setSortOption(.number)

        await vm.setSearchQuery("match")

        XCTAssertEqual(vm.loader.items.map(\.id), ["done-hit", "todo-hit"])
        XCTAssertEqual(vm.issues(for: .done).map(\.id), ["done-hit"])
        XCTAssertEqual(vm.issues(for: .todo).map(\.id), ["todo-hit"])
        XCTAssertNil(vm.lastError)
    }

    func test_searchQueryIncludesClosedIssuesSoDoneResearchCanBeFound() async throws {
        var includeClosed: String?
        let client = makeClient { req in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            switch req.url?.path {
            case "/api/issues/search":
                includeClosed = components?.queryItems?.first(where: { $0.name == "include_closed" })?.value
                let query = components?.queryItems?.first(where: { $0.name == "q" })?.value
                XCTAssertEqual(query, "pp")
                let json = """
                {"issues":[
                  {"id":"ppt-done","identifier":"PAR-206","number":206,"title":"PPT调研","description":null,
                   "status":"done","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1","position":99,
                   "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-03T00:00:00Z"}
                ],"has_more":false,"total":1}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/pins":
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case "/api/issues/child-progress":
                return Self.childProgressResponse(for: req, progress: [])
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.setSearchQuery("ppt")

        XCTAssertEqual(includeClosed, "true")
        XCTAssertEqual(vm.loader.items.map(\.id), ["ppt-done"])
        XCTAssertEqual(vm.issuesByStatus[.done]?.map(\.id), ["ppt-done"])
        XCTAssertNil(vm.lastError)
    }

    func test_searchQueryDoesNotRequestChildProgress() async throws {
        var requestedPaths: [String] = []
        let client = makeClient { req in
            requestedPaths.append(req.url?.path ?? "")
            switch req.url?.path {
            case "/api/issues/search":
                let json = """
                {"issues":[
                  {"id":"ppt-done","identifier":"PAR-206","number":206,"title":"PPT调研","description":null,
                   "status":"done","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1",
                   "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-03T00:00:00Z"}
                ],"has_more":false,"total":1}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/pins":
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case "/api/issues/child-progress":
                XCTFail("Search should not request child-progress.")
                return Self.childProgressResponse(for: req, progress: [])
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.setSearchQuery("ppt")

        XCTAssertEqual(vm.loader.items.map(\.id), ["ppt-done"])
        XCTAssertEqual(requestedPaths, ["/api/issues/search"])
        XCTAssertNil(vm.lastError)
    }

    func test_threeCharacterAsciiSearchUsesFastPrefixAndFiltersLocally() async throws {
        var requestedQueries: [String] = []
        let client = makeClient { req in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            switch req.url?.path {
            case "/api/issues/search":
                requestedQueries.append(components?.queryItems?.first(where: { $0.name == "q" })?.value ?? "")
                let json = """
                {"issues":[
                  {"id":"ppt-hit","identifier":"PAR-162","number":162,"title":"PPT SKILL大调研","description":null,
                   "status":"done","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1",
                   "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-03T00:00:00Z"},
                  {"id":"prefix-only","identifier":"PAR-76","number":76,"title":"App Store 上架准备","description":null,
                   "status":"done","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1",
                   "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-03T00:00:00Z"}
                ],"has_more":false,"total":2}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.setSearchQuery("ppt")

        XCTAssertEqual(requestedQueries, ["pp"])
        XCTAssertEqual(vm.loader.items.map(\.id), ["ppt-hit"])
        XCTAssertEqual(vm.issuesByStatus[.done]?.map(\.id), ["ppt-hit"])
        XCTAssertNil(vm.lastError)
    }

    func test_refreshIfIdleSkipsActiveSearch() async throws {
        var requestedQueries: [String] = []
        let client = makeClient { req in
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            switch req.url?.path {
            case "/api/issues/search":
                requestedQueries.append(components?.queryItems?.first(where: { $0.name == "q" })?.value ?? "")
                let json = """
                {"issues":[
                  {"id":"ppt-hit","identifier":"PAR-162","number":162,"title":"PPT SKILL大调研","description":null,
                   "status":"done","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1",
                   "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-03T00:00:00Z"}
                ],"has_more":false,"total":1}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.setSearchQuery("ppt")
        await vm.refreshIfIdle()

        XCTAssertEqual(requestedQueries, ["pp"])
        XCTAssertEqual(vm.loader.items.map(\.id), ["ppt-hit"])
        XCTAssertNil(vm.lastError)
    }

    func test_cancelledSearchDoesNotSurfaceAsUserVisibleError() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/issues/search":
                throw URLError(.cancelled)
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.setSearchQuery("ppt")

        XCTAssertEqual(vm.searchQuery, "ppt")
        XCTAssertNil(vm.lastError)
    }

    func test_newSearchRunsAfterCancellingInFlightSearch() async throws {
        let firstSearchStarted = DispatchSemaphore(value: 0)
        let releaseFirstSearch = DispatchSemaphore(value: 0)
        var requestedQueries: [String] = []
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/issues/search":
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                requestedQueries.append(query)
                if query == "p" {
                    firstSearchStarted.signal()
                    _ = releaseFirstSearch.wait(timeout: .now() + 2)
                    throw URLError(.cancelled)
                }
                let json = """
                {"issues":[
                  {"id":"ppt-done","identifier":"PAR-206","number":206,"title":"PPT调研","description":null,
                   "status":"done","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1",
                   "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-03T00:00:00Z"}
                ],"has_more":false,"total":1}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/pins":
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case "/api/issues/child-progress":
                return Self.childProgressResponse(for: req, progress: [])
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        let firstTask = Task { @MainActor in await vm.setSearchQuery("p") }
        let waitResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: firstSearchStarted.wait(timeout: .now() + 2))
            }
        }
        XCTAssertEqual(waitResult, .success)
        let secondTask = Task { @MainActor in await vm.setSearchQuery("ppt") }

        releaseFirstSearch.signal()
        await firstTask.value
        await secondTask.value

        XCTAssertEqual(requestedQueries, ["p", "pp"])
        XCTAssertEqual(vm.searchQuery, "ppt")
        XCTAssertEqual(vm.loader.items.map(\.id), ["ppt-done"])
        XCTAssertNil(vm.lastError)
    }

    func test_newSearchRunsAfterStaleInFlightSearchFails() async throws {
        let firstSearchStarted = DispatchSemaphore(value: 0)
        let releaseFirstSearch = DispatchSemaphore(value: 0)
        var requestedQueries: [String] = []
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/issues/search":
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
                requestedQueries.append(query)
                if query == "p" {
                    firstSearchStarted.signal()
                    _ = releaseFirstSearch.wait(timeout: .now() + 2)
                    return Self.response(for: req, body: Data(), status: 500)
                }
                let json = """
                {"issues":[
                  {"id":"ppt-done","identifier":"PAR-206","number":206,"title":"PPT调研","description":null,
                   "status":"done","priority":"none","assignee_id":null,"assignee_type":null,
                   "project_id":null,"workspace_id":"w1",
                   "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-03T00:00:00Z"}
                ],"has_more":false,"total":1}
                """.data(using: .utf8)!
                return Self.response(for: req, body: json)
            case "/api/pins":
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case "/api/issues/child-progress":
                return Self.childProgressResponse(for: req, progress: [])
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        let firstTask = Task { @MainActor in await vm.setSearchQuery("p") }
        let waitResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: firstSearchStarted.wait(timeout: .now() + 2))
            }
        }
        XCTAssertEqual(waitResult, .success)
        let secondTask = Task { @MainActor in await vm.setSearchQuery("ppt") }

        releaseFirstSearch.signal()
        await firstTask.value
        await secondTask.value

        XCTAssertEqual(requestedQueries, ["p", "pp"])
        XCTAssertEqual(vm.searchQuery, "ppt")
        XCTAssertEqual(vm.loader.items.map(\.id), ["ppt-done"])
        XCTAssertNil(vm.lastError)
    }

    func test_setSortOption_sortsLoadedIssuesByPriority() async throws {
        let client = makeClient { req in
            if req.url?.path == "/api/pins" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            }
            if req.url?.path == "/api/issues/child-progress" {
                return Self.childProgressResponse(for: req, progress: [])
            }
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
            switch status {
            case "backlog":
                return Self.issuesResponse(for: req, status: status, priority: "low", total: 1)
            case "todo":
                return Self.issuesResponse(for: req, status: status, priority: "urgent", total: 1)
            default:
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.setSortOption(.priority)

        XCTAssertEqual(vm.loader.items.map(\.priority), [.urgent, .low])
        XCTAssertEqual(vm.loader.items.map(\.id), ["todo-1", "backlog-1"])
    }

    func test_setSortDirectionReversesIssuesListSortDimension() async throws {
        let client = makeClient { req in
            if req.url?.path == "/api/pins" {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            }
            if req.url?.path == "/api/issues/child-progress" {
                return Self.childProgressResponse(for: req, progress: [])
            }
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
            if status == "todo" {
                return Self.response(
                    for: req,
                    body: Data("""
                    {"issues":[
                      {"id":"todo-1","identifier":"PAR-1","number":1,"title":"Alpha","description":null,"status":"todo","priority":"none","assignee_id":null,"assignee_type":null,"project_id":null,"workspace_id":"w1","position":0,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
                      {"id":"todo-2","identifier":"PAR-2","number":2,"title":"Beta","description":null,"status":"todo","priority":"none","assignee_id":null,"assignee_type":null,"project_id":null,"workspace_id":"w1","position":1,"created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}
                    ],"has_more":false,"total":2}
                    """.utf8)
                )
            }
            return Self.emptyIssuesResponse(for: req)
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.setSortOption(.number)

        XCTAssertEqual(vm.loader.items.map(\.id), ["todo-1", "todo-2"])

        vm.setSortDirection(.descending)

        XCTAssertEqual(vm.loader.items.map(\.id), ["todo-2", "todo-1"])
        XCTAssertEqual(vm.issues(for: .todo).map(\.id), ["todo-2", "todo-1"])
    }

    func test_updateStatus_updatesServerAndMovesIssueBetweenStatusBuckets() async throws {
        var updateRequestBody: [String: Any] = [:]
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case (_, "/api/pins"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case ("GET", "/api/issues/child-progress"):
                return Self.childProgressResponse(for: req, progress: [])
            case ("GET", "/api/issues"):
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
                if status == "todo" {
                    return Self.issuesResponse(for: req, status: status, total: 1)
                }
                return Self.emptyIssuesResponse(for: req)
            case ("PUT", "/api/issues/todo-1"):
                XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
                updateRequestBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return Self.response(
                    for: req,
                    body: Self.issueJSON(id: "todo-1", status: "done", priority: "none")
                )
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        await vm.updateStatus(issueId: "todo-1", to: IssueStatus.done)

        XCTAssertEqual(updateRequestBody["status"] as? String, "done")
        XCTAssertEqual(vm.loader.items.map { $0.status }, [IssueStatus.done])
        XCTAssertEqual(vm.issuesByStatus[IssueStatus.todo]?.map { $0.id } ?? [], [])
        XCTAssertEqual(vm.issuesByStatus[IssueStatus.done]?.map { $0.id }, ["todo-1"])
        XCTAssertFalse(vm.loader.hasMore)
        XCTAssertNil(vm.lastError)
    }

    func test_batchUpdateSelectedIssues_updatesServerAndMovesIssuesBetweenStatusBuckets() async throws {
        var updateRequestBody: [String: Any] = [:]
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case (_, "/api/pins"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case ("GET", "/api/issues/child-progress"):
                return Self.childProgressResponse(for: req, progress: [])
            case ("GET", "/api/issues"):
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
                if status == "backlog" || status == "todo" {
                    return Self.issuesResponse(for: req, status: status, total: 1)
                }
                return Self.emptyIssuesResponse(for: req)
            case ("POST", "/api/issues/batch-update"):
                updateRequestBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return Self.response(for: req, body: Data(#"{"updated":2}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.toggleSelection(issueId: "backlog-1")
        vm.toggleSelection(issueId: "todo-1")
        await vm.batchUpdateSelected(status: .done, priority: .urgent)

        XCTAssertEqual(Set(updateRequestBody["issue_ids"] as? [String] ?? []), ["backlog-1", "todo-1"])
        let updates = updateRequestBody["updates"] as? [String: Any]
        XCTAssertEqual(updates?["status"] as? String, "done")
        XCTAssertEqual(updates?["priority"] as? String, "urgent")
        XCTAssertTrue(vm.selectedIssueIds.isEmpty)
        XCTAssertEqual(vm.issuesByStatus[.backlog]?.map(\.id) ?? [], [])
        XCTAssertEqual(vm.issuesByStatus[.todo]?.map(\.id) ?? [], [])
        XCTAssertEqual(Set(vm.issuesByStatus[.done]?.map(\.id) ?? []), ["backlog-1", "todo-1"])
        XCTAssertEqual(Set(vm.loader.items.map(\.priority)), [.urgent])
        XCTAssertNil(vm.lastError)
    }

    func test_loadBatchAssigneeOptionsBuildsMemberAndAgentChoices() async throws {
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case ("GET", "/api/workspaces/w1/members"):
                return Self.response(
                    for: req,
                    body: Data(#"[{"id":"m1","workspace_id":"w1","user_id":"u1","role":"admin","created_at":"2026-01-01T00:00:00Z","email":"parker@example.com","name":"Parker","avatar_url":null}]"#.utf8)
                )
            case ("GET", "/api/agents"):
                XCTAssertTrue(req.url?.absoluteString.contains("workspace_id=w1") ?? false)
                return Self.response(
                    for: req,
                    body: Data(#"[{"id":"a1","workspace_id":"w1","runtime_id":"r1","name":"Codex","description":"","instructions":"","avatar_url":null,"runtime_mode":"cloud","runtime_config":{},"custom_env":{},"custom_args":[],"custom_env_redacted":false,"visibility":"workspace","status":"active","max_concurrent_tasks":1,"model":"gpt","owner_id":null,"skills":[],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","archived_at":null,"archived_by":null}]"#.utf8)
                )
            case ("GET", "/api/squads"):
                return Self.response(for: req, body: Data(#"{"squads":[{"id":"s1","workspace_id":"w1","name":"Design Squad","description":"Design","avatar_url":null,"agent_ids":[],"member_ids":[],"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","archived_at":null}]}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadBatchAssigneeOptions()

        XCTAssertEqual(vm.batchAssigneeOptions.map(\.id), ["member:u1", "agent:a1", "squad:s1"])
        XCTAssertEqual(vm.batchAssigneeOptions.map(\.displayName), ["Parker", "Codex", "Design Squad"])
        XCTAssertEqual(vm.batchAssigneeOptions.first?.assigneeId, "u1")
        XCTAssertNil(vm.lastError)
    }

    func test_batchAssignSelectedIssuesSendsMemberAssigneeAndPatchesRows() async throws {
        var updateRequestBody: [String: Any] = [:]
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case (_, "/api/pins"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case ("GET", "/api/issues/child-progress"):
                return Self.childProgressResponse(for: req, progress: [])
            case ("GET", "/api/issues"):
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
                if status == "todo" {
                    return Self.issuesResponse(for: req, status: status, total: 1)
                }
                return Self.emptyIssuesResponse(for: req)
            case ("GET", "/api/workspaces/w1/members"):
                return Self.response(
                    for: req,
                    body: Data(#"[{"id":"m1","workspace_id":"w1","user_id":"u1","role":"admin","created_at":"2026-01-01T00:00:00Z","email":"parker@example.com","name":"Parker","avatar_url":null}]"#.utf8)
                )
            case ("GET", "/api/agents"):
                return Self.response(for: req, body: Data("[]".utf8))
            case ("GET", "/api/squads"):
                return Self.response(for: req, body: Data(#"{"squads":[]}"#.utf8))
            case ("POST", "/api/issues/batch-update"):
                updateRequestBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return Self.response(for: req, body: Data(#"{"updated":1}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        await vm.loadBatchAssigneeOptions()
        vm.toggleSelection(issueId: "todo-1")
        await vm.batchAssignSelected(optionId: "member:u1")

        let updates = updateRequestBody["updates"] as? [String: Any]
        XCTAssertEqual(updates?["assignee_type"] as? String, "member")
        XCTAssertEqual(updates?["assignee_id"] as? String, "u1")
        XCTAssertTrue(vm.selectedIssueIds.isEmpty)
        XCTAssertEqual(vm.loader.items.first?.assigneeType, "member")
        XCTAssertEqual(vm.loader.items.first?.assigneeId, "u1")
        XCTAssertNil(vm.lastError)
    }

    func test_batchDeleteSelectedIssues_removesIssuesAndClearsSelection() async throws {
        var deleteRequestBody: [String: Any] = [:]
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case (_, "/api/pins"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case ("GET", "/api/issues/child-progress"):
                return Self.childProgressResponse(for: req, progress: [])
            case ("GET", "/api/issues"):
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
                if status == "backlog" || status == "todo" {
                    return Self.issuesResponse(for: req, status: status, total: 1)
                }
                return Self.emptyIssuesResponse(for: req)
            case ("POST", "/api/issues/batch-delete"):
                deleteRequestBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return Self.response(for: req, body: Data(#"{"deleted":2}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.toggleSelection(issueId: "backlog-1")
        vm.toggleSelection(issueId: "todo-1")
        await vm.batchDeleteSelected()

        XCTAssertEqual(Set(deleteRequestBody["issue_ids"] as? [String] ?? []), ["backlog-1", "todo-1"])
        XCTAssertTrue(vm.selectedIssueIds.isEmpty)
        XCTAssertTrue(vm.loader.items.isEmpty)
        XCTAssertEqual(vm.issuesByStatus[.backlog]?.map(\.id) ?? [], [])
        XCTAssertEqual(vm.issuesByStatus[.todo]?.map(\.id) ?? [], [])
        XCTAssertNil(vm.lastError)
    }

    func test_moveIssueToStatusUpdatesServerAndBoardBuckets() async throws {
        var updateRequestBody: [String: Any] = [:]
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case (_, "/api/pins"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case ("GET", "/api/issues/child-progress"):
                return Self.childProgressResponse(for: req, progress: [])
            case ("GET", "/api/issues"):
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
                if status == "todo" {
                    return Self.issuesResponse(for: req, status: status, total: 1)
                }
                return Self.emptyIssuesResponse(for: req)
            case ("PUT", "/api/issues/todo-1"):
                updateRequestBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return Self.response(for: req, body: Self.issueJSON(id: "todo-1", status: "in_progress", priority: "none"))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        await vm.moveIssue(issueId: "todo-1", to: .inProgress)

        XCTAssertEqual(updateRequestBody["status"] as? String, "in_progress")
        XCTAssertEqual(vm.issuesByStatus[.todo]?.map(\.id) ?? [], [])
        XCTAssertEqual(vm.issuesByStatus[.inProgress]?.map(\.id), ["todo-1"])
        XCTAssertNil(vm.lastError)
    }

    func test_moveIssueWithinStatusPersistsCustomBoardPosition() async throws {
        var updateRequestBody: [String: Any] = [:]
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case (_, "/api/pins"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case ("GET", "/api/issues/child-progress"):
                return Self.childProgressResponse(for: req, progress: [])
            case ("GET", "/api/issues"):
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
                if status == "todo" {
                    return Self.response(
                        for: req,
                        body: Data("""
                        {"issues":[
                          {"id":"todo-1","identifier":"PAR-1","number":1,"title":"First","description":null,"status":"todo","priority":"none","assignee_id":null,"assignee_type":null,"project_id":null,"workspace_id":"w1","position":0,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
                          {"id":"todo-2","identifier":"PAR-2","number":2,"title":"Second","description":null,"status":"todo","priority":"none","assignee_id":null,"assignee_type":null,"project_id":null,"workspace_id":"w1","position":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
                        ],"has_more":false,"total":2}
                        """.utf8)
                    )
                }
                return Self.emptyIssuesResponse(for: req)
            case ("PUT", "/api/issues/todo-2"):
                updateRequestBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return Self.response(for: req, body: Self.issueJSON(id: "todo-2", status: "todo", priority: "none", position: 0))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        await vm.moveIssue(issueId: "todo-2", to: .todo, beforeIssueId: "todo-1")

        XCTAssertEqual(updateRequestBody["status"] as? String, "todo")
        XCTAssertEqual(updateRequestBody["position"] as? Int, 0)
        XCTAssertEqual(vm.issuesByStatus[.todo]?.map(\.id), ["todo-2", "todo-1"])
        XCTAssertEqual(vm.loader.items.map(\.id), ["todo-2", "todo-1"])
        XCTAssertNil(vm.lastError)
    }

    func test_moveIssueWithinStatusCanAppendToEnd() async throws {
        var updateRequestBody: [String: Any] = [:]
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case (_, "/api/pins"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case ("GET", "/api/issues/child-progress"):
                return Self.childProgressResponse(for: req, progress: [])
            case ("GET", "/api/issues"):
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
                if status == "todo" {
                    return Self.response(
                        for: req,
                        body: Data("""
                        {"issues":[
                          {"id":"todo-1","identifier":"PAR-1","number":1,"title":"First","description":null,"status":"todo","priority":"none","assignee_id":null,"assignee_type":null,"project_id":null,"workspace_id":"w1","position":0,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"},
                          {"id":"todo-2","identifier":"PAR-2","number":2,"title":"Second","description":null,"status":"todo","priority":"none","assignee_id":null,"assignee_type":null,"project_id":null,"workspace_id":"w1","position":1,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
                        ],"has_more":false,"total":2}
                        """.utf8)
                    )
                }
                return Self.emptyIssuesResponse(for: req)
            case ("PUT", "/api/issues/todo-1"):
                updateRequestBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return Self.response(for: req, body: Self.issueJSON(id: "todo-1", status: "todo", priority: "none", position: 1))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        await vm.moveIssue(issueId: "todo-1", to: .todo)

        XCTAssertEqual(updateRequestBody["status"] as? String, "todo")
        XCTAssertEqual(updateRequestBody["position"] as? Int, 1)
        XCTAssertEqual(vm.issuesByStatus[.todo]?.map(\.id), ["todo-2", "todo-1"])
        XCTAssertNil(vm.lastError)
    }

    func test_moveIssueToStatusCanInsertBeforeTargetIssue() async throws {
        var updateRequestBody: [String: Any] = [:]
        let client = makeClient { req in
            switch (req.httpMethod, req.url?.path) {
            case (_, "/api/pins"):
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            case ("GET", "/api/issues/child-progress"):
                return Self.childProgressResponse(for: req, progress: [])
            case ("GET", "/api/issues"):
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                let status = components?.queryItems?.first(where: { $0.name == "status" })?.value ?? "todo"
                if status == "todo" {
                    return Self.issuesResponse(for: req, status: status, total: 1)
                }
                if status == "in_progress" {
                    return Self.issuesResponse(for: req, status: status, total: 1)
                }
                return Self.emptyIssuesResponse(for: req)
            case ("PUT", "/api/issues/todo-1"):
                updateRequestBody = try JSONSerialization.jsonObject(with: MockURLProtocol.bodyData(for: req)) as? [String: Any] ?? [:]
                return Self.response(for: req, body: Self.issueJSON(id: "todo-1", status: "in_progress", priority: "none", position: 0))
            default:
                XCTFail("Unexpected request: \(req.httpMethod ?? "") \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        await vm.moveIssue(issueId: "todo-1", to: .inProgress, beforeIssueId: "in_progress-1")

        XCTAssertEqual(updateRequestBody["status"] as? String, "in_progress")
        XCTAssertEqual(updateRequestBody["position"] as? Int, 0)
        XCTAssertEqual(vm.issuesByStatus[.todo]?.map(\.id) ?? [], [])
        XCTAssertEqual(vm.issuesByStatus[.inProgress]?.map(\.id), ["todo-1", "in_progress-1"])
        XCTAssertNil(vm.lastError)
    }

    func test_pinnedIssuesSurfaceAtTopAndAreExcludedFromStatusGroups() async throws {
        let client = makeClient { req in
            if req.url?.path == "/api/pins" {
                return Self.pinsResponse(for: req, pinned: [("done-1", 1), ("todo-1", 0)])
            }
            if req.url?.path == "/api/issues/child-progress" {
                return Self.childProgressResponse(for: req, progress: [])
            }
            let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            guard let status = components?.queryItems?.first(where: { $0.name == "status" })?.value else {
                XCTFail("Expected status query in \(req.url?.absoluteString ?? "")")
                return Self.emptyIssuesResponse(for: req)
            }
            return Self.issuesResponse(for: req, status: status, total: 1)
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()

        // Pinned issues ordered by pin position (todo-1 position 0, done-1 position 1).
        XCTAssertEqual(vm.pinnedIssues.map(\.id), ["todo-1", "done-1"])
        XCTAssertTrue(vm.isPinned("todo-1"))
        XCTAssertTrue(vm.isPinned("done-1"))
        XCTAssertFalse(vm.isPinned("backlog-1"))
        // Pinned issues are removed from their status groups to avoid duplication.
        XCTAssertEqual(vm.unpinnedIssues(for: .todo).map(\.id), [])
        XCTAssertEqual(vm.unpinnedIssues(for: .done).map(\.id), [])
        // Non-pinned statuses keep their full contents.
        XCTAssertEqual(vm.unpinnedIssues(for: .backlog).map(\.id), ["backlog-1"])
    }

    func test_togglePinAddsThenRemovesFromPinnedSet() async throws {
        var requests: [String] = []
        let client = makeClient { req in
            requests.append("\(req.httpMethod ?? "") \(req.url?.path ?? "")")
            switch (req.httpMethod, req.url?.path) {
            case (_, "/api/pins") where req.httpMethod == "GET":
                return Self.pinsResponse(for: req, pinned: [])
            case ("POST", "/api/pins"):
                return Self.response(
                    for: req,
                    body: #"{"id":"pin1","workspace_id":"w1","user_id":"u1","item_type":"issue","item_id":"todo-1","position":0,"created_at":"2026-01-01T00:00:00Z"}"#.data(using: .utf8)!
                )
            case ("DELETE", "/api/pins/issue/todo-1"):
                return Self.response(for: req, body: Data(), status: 204)
            case (_, "/api/issues/child-progress"):
                return Self.childProgressResponse(for: req, progress: [])
            default:
                let components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
                guard let status = components?.queryItems?.first(where: { $0.name == "status" })?.value else {
                    XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                    return Self.emptyIssuesResponse(for: req)
                }
                return Self.issuesResponse(for: req, status: status, total: 1)
            }
        }
        let vm = IssueListViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        XCTAssertFalse(vm.isPinned("todo-1"))

        await vm.togglePin(issueId: "todo-1")
        XCTAssertTrue(vm.isPinned("todo-1"))
        XCTAssertEqual(vm.pinnedIssues.map(\.id), ["todo-1"])

        await vm.togglePin(issueId: "todo-1")
        XCTAssertFalse(vm.isPinned("todo-1"))
        XCTAssertTrue(vm.pinnedIssues.isEmpty)

        XCTAssertTrue(requests.contains("POST /api/pins"))
        XCTAssertTrue(requests.contains("DELETE /api/pins/issue/todo-1"))
        XCTAssertNil(vm.lastError)
    }

    private static func pinsResponse(for request: URLRequest, pinned: [(String, Int)]) -> (HTTPURLResponse, Data) {
        let entries = pinned.map { itemId, position in
            #"{"id":"pin-\#(itemId)","workspace_id":"w1","user_id":"u1","item_type":"issue","item_id":"\#(itemId)","position":\#(position),"created_at":"2026-01-01T00:00:00Z"}"#
        }
        let json = "[\(entries.joined(separator: ","))]"
        return (
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            json.data(using: .utf8)!
        )
    }

    private func makeClient(handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? = nil) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = handler ?? { req in
            XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
            return (
                HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        return APIClient(session: URLSession(configuration: config), token: "test-token")
    }

    private func makeUserDefaults() -> UserDefaults {
        UserDefaults(suiteName: "IssueListViewModelTests.\(UUID().uuidString)")!
    }

    private func makeAuthSession() -> AuthSession {
        let session = AuthSession(userDefaults: makeUserDefaults())
        try! session.login(
            user: User(id: "u1", email: "u@example.com", name: "User", avatarUrl: nil),
            workspaces: [Workspace(id: "w1", name: "Workspace", slug: "workspace", issuePrefix: "PAR")],
            token: "token"
        )
        return session
    }

    private static func emptyIssuesResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            #"{"issues":[],"has_more":false,"total":0}"#.data(using: .utf8)!
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

    private static func issuesResponse(
        for request: URLRequest,
        status: String,
        suffix: String = "1",
        priority: String = "none",
        total: Int
    ) -> (HTTPURLResponse, Data) {
        let id = "\(status)-\(suffix)"
        let json = """
        {"issues":[{"id":"\(id)","identifier":"PAR-\(suffix)","number":\(suffix),
         "title":"\(status) issue","description":null,"status":"\(status)","priority":"\(priority)",
         "assignee_id":null,"assignee_type":null,"project_id":null,"workspace_id":"w1",
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}],
         "has_more":false,"total":\(total)}
        """.data(using: .utf8)!
        return (
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            json
        )
    }

    private static func issueJSON(id: String, status: String, priority: String, position: Int? = nil) -> Data {
        let positionField = position.map { #","position":\#($0)"# } ?? ""
        return """
        {"id":"\(id)","identifier":"PAR-1","number":1,
         "title":"\(status) issue","description":null,"status":"\(status)","priority":"\(priority)",
         "assignee_id":null,"assignee_type":null,"project_id":null,"workspace_id":"w1"\(positionField),
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-02T00:00:00Z"}
        """.data(using: .utf8)!
    }

    private static func childProgressResponse(for request: URLRequest, progress: [String]) -> (HTTPURLResponse, Data) {
        let json = """
        {"progress":[\(progress.joined(separator: ","))]}
        """.data(using: .utf8)!
        return (
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
            json
        )
    }
}
