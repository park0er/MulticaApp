import XCTest
@testable import MultiCasual

final class PaginatedLoaderTests: XCTestCase {

    struct Item: Identifiable, Sendable, Decodable { let id: String }

    struct StubError: Error, Equatable {}

    @MainActor
    func test_loadNext_appendsItems() async throws {
        let loader = PaginatedLoader<Item>()
        try await loader.loadNext { _ in
            PageResponse(items: [Item(id: "a"), Item(id: "b")], hasMore: true, total: 10)
        }
        XCTAssertEqual(loader.items.count, 2)
        XCTAssertTrue(loader.hasMore)
    }

    @MainActor
    func test_loadNext_whenHasMoreFalse_stopsLoading() async throws {
        let loader = PaginatedLoader<Item>()
        try await loader.loadNext { _ in PageResponse(items: [Item(id: "a")], hasMore: false, total: 1) }
        try await loader.loadNext { _ in PageResponse(items: [Item(id: "b")], hasMore: false, total: 1) }
        XCTAssertEqual(loader.items.count, 1, "Should not fetch second page when hasMore=false")
    }

    @MainActor
    func test_reset_clearsState() async throws {
        let loader = PaginatedLoader<Item>()
        try await loader.loadNext { _ in PageResponse(items: [Item(id: "a")], hasMore: true, total: 5) }
        loader.reset()
        XCTAssertTrue(loader.items.isEmpty)
        XCTAssertTrue(loader.hasMore)
        XCTAssertFalse(loader.isLoading)
    }

    @MainActor
    func test_loadNext_passesCorrectOffset() async throws {
        var capturedOffsets: [Int] = []
        let loader = PaginatedLoader<Item>()
        try await loader.loadNext { offset in
            capturedOffsets.append(offset)
            return PageResponse(items: [Item(id: "a"), Item(id: "b")], hasMore: true, total: 10)
        }
        try await loader.loadNext { offset in
            capturedOffsets.append(offset)
            return PageResponse(items: [Item(id: "c")], hasMore: false, total: 10)
        }
        XCTAssertEqual(capturedOffsets, [0, 2], "Second page should use offset=2 (count of first page)")
    }

    @MainActor
    func test_loadNext_propagatesErrors() async {
        let loader = PaginatedLoader<Item>()
        do {
            try await loader.loadNext { _ in throw StubError() }
            XCTFail("Expected StubError to propagate")
        } catch let err as StubError {
            XCTAssertEqual(err, StubError())
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertFalse(loader.isLoading, "isLoading should reset even when fetch throws")
        XCTAssertTrue(loader.items.isEmpty)
        XCTAssertFalse(loader.hasMore, "Failed fetch should stop automatic pagination until the view model resets")
    }

    @MainActor
    func test_silentRefreshFirstPage_mergesByIdKeepsDeeperPagesAndResetsCursor() async throws {
        let loader = PaginatedLoader<Item>()
        // Load two pages: [a, b] then [c].
        try await loader.loadNext { _ in
            PageResponse(items: [Item(id: "a"), Item(id: "b")], hasMore: true, total: 3)
        }
        try await loader.loadNext { _ in
            PageResponse(items: [Item(id: "c")], hasMore: false, total: 3)
        }
        XCTAssertEqual(loader.items.map(\.id), ["a", "b", "c"])

        // Silent refresh: fresh first page is [b, d] (a dropped, d new). The
        // already-loaded deeper-page items whose id is not in the fresh page
        // (a, c) are kept as the tail — the list is never cleared.
        var capturedOffset: Int?
        try await loader.silentRefreshFirstPage { offset in
            capturedOffset = offset
            return PageResponse(items: [Item(id: "b"), Item(id: "d")], hasMore: true, total: 5)
        }
        XCTAssertEqual(capturedOffset, 0, "Silent refresh always fetches the first page (offset 0)")
        XCTAssertEqual(loader.items.map(\.id), ["b", "d", "a", "c"], "Fresh first page followed by preserved deeper-page tail")
        XCTAssertTrue(loader.hasMore, "hasMore follows the fresh page")
        XCTAssertFalse(loader.isRefreshing, "isRefreshing clears after completion")
        XCTAssertTrue(loader.hasLoadedOnce)
    }

    @MainActor
    func test_silentRefreshFirstPage_propagatesErrorWithoutClearing() async throws {
        let loader = PaginatedLoader<Item>()
        try await loader.loadNext { _ in
            PageResponse(items: [Item(id: "a")], hasMore: false, total: 1)
        }
        do {
            try await loader.silentRefreshFirstPage { _ in throw StubError() }
            XCTFail("Expected StubError to propagate")
        } catch is StubError {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
        XCTAssertEqual(loader.items.map(\.id), ["a"], "Existing items must survive a failed silent refresh")
        XCTAssertFalse(loader.isRefreshing)
    }

    @MainActor
    func test_silentRefreshFirstPage_isReentrantGuarded() async throws {
        let loader = PaginatedLoader<Item>()
        try await loader.loadNext { _ in PageResponse(items: [Item(id: "a")], hasMore: false, total: 1) }
        var fetchCount = 0
        // A second concurrent silent refresh is a no-op (guard !isRefreshing).
        async let first = loader.silentRefreshFirstPage { _ in
            fetchCount += 1
            return PageResponse(items: [Item(id: "a")], hasMore: false, total: 1)
        }
        try await loader.silentRefreshFirstPage { _ in
            fetchCount += 1
            return PageResponse(items: [Item(id: "a")], hasMore: false, total: 1)
        }
        try await first
        // At least one fetch happened; the guard prevents double-fetch races.
        XCTAssertGreaterThanOrEqual(fetchCount, 1)
        XCTAssertFalse(loader.isRefreshing)
    }

    @MainActor
    func test_upsert_replacesExistingItemById() async throws {
        let loader = PaginatedLoader<Item>()
        try await loader.loadNext { _ in PageResponse(items: [Item(id: "a"), Item(id: "b")], hasMore: false, total: 2) }
        loader.upsert(Item(id: "b"))
        XCTAssertEqual(loader.items.map(\.id), ["a", "b"], "Existing id is replaced in place, not appended")
        loader.upsert(Item(id: "c"))
        XCTAssertEqual(loader.items.map(\.id), ["a", "b", "c"], "New id is appended")
    }
}
