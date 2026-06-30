import XCTest
@testable import MultiCasual

@MainActor
final class InboxViewModelTests: XCTestCase {
    func test_inboxRowsNavigateBeforeMarkingRead() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Multi-Casual/Features/Inbox/InboxView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertFalse(
            source.contains(".simultaneousGesture(TapGesture().onEnded"),
            "Inbox row taps should not attach a simultaneous gesture to NavigationLink because updating row state can cancel navigation."
        )
        XCTAssertTrue(
            source.contains(".task { await vm.markReadIfNeeded(id: item.id) }"),
            "Inbox items should be marked read after the IssueDetailView destination appears, preserving tap-to-open behavior."
        )
    }

    func test_inboxViewAutoRefreshesWhileVisibleAndActive() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sourceURL = root.appendingPathComponent("Multi-Casual/Features/Inbox/InboxView.swift")
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(
            source.contains("@State private var autoRefreshTask: Task<Void, Never>?"),
            "Inbox should own a cancellable auto-refresh task while the view is visible."
        )
        XCTAssertTrue(
            source.contains("private let autoRefreshIntervalNanoseconds"),
            "Inbox should define an explicit refresh interval instead of relying only on manual pull-to-refresh."
        )
        XCTAssertTrue(
            source.contains("startAutoRefresh()"),
            "Inbox should start auto-refresh from appearance and active scene transitions."
        )
        XCTAssertTrue(
            source.contains("stopAutoRefresh()"),
            "Inbox should stop auto-refresh when hidden or inactive to avoid background churn."
        )
        XCTAssertTrue(
            source.contains("await viewModel?.refreshIfIdle()"),
            "Inbox auto-refresh should call refreshIfIdle so it does not overlap an existing load."
        )
    }

    func test_markRead_updatesItemAndUnreadCount() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                Self.assertInboxListQuery(req)
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "test")
                return Self.response(for: req, body: Self.inboxItemJSON(read: false, archived: false))
            case "/api/inbox/n1/read":
                XCTAssertEqual(req.url?.query, "workspace_id=w1")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "test")
                return Self.response(for: req, body: Self.singleInboxItemJSON(read: true, archived: false))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        await vm.markRead(id: "n1")

        XCTAssertEqual(vm.loader.items.first?.read, true)
        XCTAssertEqual(vm.unreadCount, 0)
        XCTAssertNil(vm.lastError)
    }

    func test_markReadIfNeededOptimisticallyMarksUnreadItemOnOpen() async throws {
        var readRequestCount = 0
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                return Self.response(for: req, body: Self.inboxItemJSON(read: false, archived: false))
            case "/api/inbox/n1/read":
                readRequestCount += 1
                XCTAssertEqual(req.url?.query, "workspace_id=w1")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "test")
                return Self.response(for: req, body: Self.singleInboxItemJSON(read: true, archived: false))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        await vm.markReadIfNeeded(id: "n1")
        await vm.markReadIfNeeded(id: "n1")

        XCTAssertEqual(readRequestCount, 1)
        XCTAssertEqual(vm.loader.items.first?.read, true)
        XCTAssertEqual(vm.unreadCount, 0)
        XCTAssertTrue(vm.markingReadIds.isEmpty)
        XCTAssertNil(vm.lastError)
    }

    func test_confirmPendingArchive_removesItemAndRecomputesUnreadCount() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                Self.assertInboxListQuery(req)
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "test")
                return Self.response(for: req, body: Self.inboxItemJSON(read: false, archived: false))
            case "/api/inbox/n1/archive":
                XCTAssertEqual(req.url?.query, "workspace_id=w1")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "test")
                return Self.response(for: req, body: Self.singleInboxItemJSON(read: false, archived: true))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.requestArchive(id: "n1")
        await vm.confirmPendingArchive()

        XCTAssertTrue(vm.loader.items.isEmpty)
        XCTAssertEqual(vm.unreadCount, 0)
        XCTAssertNil(vm.lastError)
    }

    func test_requestArchive_storesPendingItemWithoutArchiving() async throws {
        var didCallArchive = false
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                return Self.response(for: req, body: Self.inboxItemJSON(read: false, archived: false))
            case "/api/inbox/n1/archive":
                didCallArchive = true
                return Self.response(for: req, body: Self.singleInboxItemJSON(read: false, archived: true))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.requestArchive(id: "n1")

        XCTAssertEqual(vm.pendingArchiveItem?.id, "n1")
        XCTAssertFalse(didCallArchive)
        XCTAssertEqual(vm.loader.items.map(\.id), ["n1"])
    }

    func test_confirmPendingArchive_archivesAndClearsPendingItem() async throws {
        var archiveRequestCount = 0
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                return Self.response(for: req, body: Self.inboxItemJSON(read: false, archived: false))
            case "/api/inbox/n1/archive":
                archiveRequestCount += 1
                return Self.response(for: req, body: Self.singleInboxItemJSON(read: false, archived: true))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.requestArchive(id: "n1")
        await vm.confirmPendingArchive()

        XCTAssertNil(vm.pendingArchiveItem)
        XCTAssertEqual(archiveRequestCount, 1)
        XCTAssertTrue(vm.loader.items.isEmpty)
        XCTAssertEqual(vm.unreadCount, 0)
    }

    func test_cancelPendingArchive_clearsPendingItemWithoutArchiving() async throws {
        var didCallArchive = false
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                return Self.response(for: req, body: Self.inboxItemJSON(read: false, archived: false))
            case "/api/inbox/n1/archive":
                didCallArchive = true
                return Self.response(for: req, body: Self.singleInboxItemJSON(read: false, archived: true))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.requestArchive(id: "n1")
        vm.cancelPendingArchive()

        XCTAssertNil(vm.pendingArchiveItem)
        XCTAssertFalse(didCallArchive)
        XCTAssertEqual(vm.loader.items.map(\.id), ["n1"])
    }

    func test_loadNext_deduplicatesInboxItemsByIssueKeepingNewestActiveItem() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                let body = Self.inboxItemsJSON([
                    Self.inboxItemJSON(
                        id: "old",
                        issueId: "i1",
                        title: "Old PAR-73 update",
                        read: false,
                        archived: false,
                        createdAt: "2026-01-01T00:00:00Z"
                    ),
                    Self.inboxItemJSON(
                        id: "new",
                        issueId: "i1",
                        title: "Newest PAR-73 update",
                        read: false,
                        archived: false,
                        createdAt: "2026-01-02T00:00:00Z"
                    ),
                    Self.inboxItemJSON(
                        id: "archived-newest",
                        issueId: "i2",
                        title: "Archived update",
                        read: false,
                        archived: true,
                        createdAt: "2026-01-03T00:00:00Z"
                    ),
                    Self.inboxItemJSON(
                        id: "other",
                        issueId: "i3",
                        title: "Other issue update",
                        read: true,
                        archived: false,
                        createdAt: "2026-01-01T12:00:00Z"
                    )
                ])
                return Self.response(for: req, body: body)
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()

        XCTAssertEqual(vm.loader.items.map(\.id), ["new", "other"])
        XCTAssertEqual(vm.unreadCount, 1)
        XCTAssertNil(vm.lastError)
    }

    func test_markAllRead_marksVisibleActiveItemsReadAndRecomputesUnreadCount() async throws {
        var didCallMarkAll = false
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                let body = Self.inboxItemsJSON([
                    Self.inboxItemJSON(
                        id: "n1",
                        issueId: "i1",
                        title: "First update",
                        read: false,
                        archived: false,
                        createdAt: "2026-01-01T00:00:00Z"
                    ),
                    Self.inboxItemJSON(
                        id: "n2",
                        issueId: "i2",
                        title: "Second update",
                        read: false,
                        archived: false,
                        createdAt: "2026-01-02T00:00:00Z"
                    )
                ])
                return Self.response(for: req, body: body)
            case "/api/inbox/mark-all-read":
                didCallMarkAll = true
                XCTAssertEqual(req.url?.query, "workspace_id=w1")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "test")
                return Self.response(for: req, body: Data(#"{"count":2}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        XCTAssertEqual(vm.unreadCount, 2)

        await vm.markAllRead()

        XCTAssertTrue(didCallMarkAll)
        XCTAssertEqual(vm.loader.items.map(\.read), [true, true])
        XCTAssertEqual(vm.unreadCount, 0)
        XCTAssertNil(vm.lastError)
    }

    func test_confirmPendingBulkArchiveAll_removesVisibleItemsAndRecomputesUnreadCount() async throws {
        var didCallArchiveAll = false
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                let body = Self.inboxItemsJSON([
                    Self.inboxItemJSON(id: "n1", issueId: "i1", title: "Unread update", read: false, archived: false, createdAt: "2026-01-01T00:00:00Z"),
                    Self.inboxItemJSON(id: "n2", issueId: "i2", title: "Read update", read: true, archived: false, createdAt: "2026-01-02T00:00:00Z")
                ])
                return Self.response(for: req, body: body)
            case "/api/inbox/archive-all":
                didCallArchiveAll = true
                XCTAssertEqual(req.url?.query, "workspace_id=w1")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "test")
                return Self.response(for: req, body: Data(#"{"count":2}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.requestBulkArchive(.all)
        await vm.confirmPendingBulkArchive()

        XCTAssertTrue(didCallArchiveAll)
        XCTAssertNil(vm.pendingBulkArchiveAction)
        XCTAssertTrue(vm.loader.items.isEmpty)
        XCTAssertEqual(vm.unreadCount, 0)
        XCTAssertNil(vm.lastError)
    }

    func test_confirmPendingBulkArchiveRead_removesOnlyReadItems() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                let body = Self.inboxItemsJSON([
                    Self.inboxItemJSON(id: "unread", issueId: "i1", title: "Unread update", read: false, archived: false, createdAt: "2026-01-02T00:00:00Z"),
                    Self.inboxItemJSON(id: "read", issueId: "i2", title: "Read update", read: true, archived: false, createdAt: "2026-01-01T00:00:00Z")
                ])
                return Self.response(for: req, body: body)
            case "/api/inbox/archive-all-read":
                XCTAssertEqual(req.url?.query, "workspace_id=w1")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "test")
                return Self.response(for: req, body: Data(#"{"count":1}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.requestBulkArchive(.read)
        await vm.confirmPendingBulkArchive()

        XCTAssertEqual(vm.loader.items.map(\.id), ["unread"])
        XCTAssertEqual(vm.unreadCount, 1)
        XCTAssertNil(vm.lastError)
    }

    func test_confirmPendingBulkArchiveCompleted_removesDoneItems() async throws {
        let client = makeClient { req in
            switch req.url?.path {
            case "/api/inbox":
                let body = Self.inboxItemsJSON([
                    Self.inboxItemJSON(id: "done", issueId: "i1", title: "Done issue", issueStatus: "done", read: false, archived: false, createdAt: "2026-01-02T00:00:00Z"),
                    Self.inboxItemJSON(id: "todo", issueId: "i2", title: "Todo issue", issueStatus: "todo", read: false, archived: false, createdAt: "2026-01-01T00:00:00Z")
                ])
                return Self.response(for: req, body: body)
            case "/api/inbox/archive-completed":
                XCTAssertEqual(req.url?.query, "workspace_id=w1")
                XCTAssertEqual(req.value(forHTTPHeaderField: "X-Workspace-Slug"), "test")
                return Self.response(for: req, body: Data(#"{"count":1}"#.utf8))
            default:
                XCTFail("Unexpected request: \(req.url?.absoluteString ?? "")")
                return Self.response(for: req, body: Data("{}".utf8), status: 404)
            }
        }
        let vm = InboxViewModel(api: client, authSession: makeAuthSession())

        await vm.loadNext()
        vm.requestBulkArchive(.completed)
        await vm.confirmPendingBulkArchive()

        XCTAssertEqual(vm.loader.items.map(\.id), ["todo"])
        XCTAssertEqual(vm.unreadCount, 1)
        XCTAssertNil(vm.lastError)
    }

    private func makeClient(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            if path == "/api/runtimes" || path == "/api/agent-task-snapshot"
                || path == "/api/agents" || path.hasSuffix("/members") {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("[]".utf8))
            }
            return try handler(req)
        }
        return APIClient(session: URLSession(configuration: config), token: "test-token")
    }

    private func makeAuthSession() -> AuthSession {
        let suiteName = "InboxViewModelTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let session = AuthSession(userDefaults: userDefaults)
        try! session.login(
            user: User(id: "u1", email: "test@example.com", name: "Test", avatarUrl: nil),
            workspaces: [Workspace(id: "w1", name: "Test Workspace", slug: "test", issuePrefix: "TST")],
            token: "test-token"
        )
        return session
    }

    private static func inboxItemJSON(read: Bool, archived: Bool) -> Data {
        Data("[\(String(data: singleInboxItemJSON(read: read, archived: archived), encoding: .utf8)!)]".utf8)
    }

    private static func singleInboxItemJSON(read: Bool, archived: Bool) -> Data {
        """
        {"id":"n1","workspace_id":"w1","recipient_type":"member","recipient_id":"u1",
         "actor_type":null,"actor_id":null,"type":"new_comment","severity":"attention",
         "issue_id":"i1","title":"PAR-73 updated","body":null,"issue_status":"todo",
         "read":\(read),"archived":\(archived),"created_at":"2026-01-01T00:00:00Z",
         "details":{"identifier":"PAR-73"}}
        """.data(using: .utf8)!
    }

    private static func inboxItemsJSON(_ items: [String]) -> Data {
        Data("[\(items.joined(separator: ","))]".utf8)
    }

    private static func inboxItemJSON(
        id: String,
        issueId: String,
        title: String,
        issueStatus: String = "todo",
        read: Bool,
        archived: Bool,
        createdAt: String
    ) -> String {
        """
        {"id":"\(id)","workspace_id":"w1","recipient_type":"member","recipient_id":"u1",
         "actor_type":null,"actor_id":null,"type":"new_comment","severity":"attention",
         "issue_id":"\(issueId)","title":"\(title)","body":null,"issue_status":"\(issueStatus)",
         "read":\(read),"archived":\(archived),"created_at":"\(createdAt)",
         "details":{"identifier":"PAR-73"}}
        """
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

    private static func assertInboxListQuery(
        _ request: URLRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            XCTFail("Missing URL", file: file, line: line)
            return
        }
        let queryItems = components.queryItems ?? []
        XCTAssertEqual(queryItems.first(where: { $0.name == "workspace_id" })?.value, "w1", file: file, line: line)
        XCTAssertEqual(queryItems.first(where: { $0.name == "limit" })?.value, "50", file: file, line: line)
        XCTAssertEqual(queryItems.first(where: { $0.name == "offset" })?.value, "0", file: file, line: line)
    }
}
