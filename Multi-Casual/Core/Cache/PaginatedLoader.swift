import Foundation
import Observation

@Observable
@MainActor
public final class PaginatedLoader<T: Identifiable & Sendable & Decodable> {
    public var items: [T] = []
    public var isLoading = false
    /// Background silent refresh. Set while the first page is being re-fetched
    /// in place without clearing the list. UI MUST NOT show a spinner or empty
    /// state while this is true — the existing items stay on screen.
    public var isRefreshing = false
    public var hasMore = true
    /// True once at least one page has been loaded successfully, so callers can
    /// distinguish "first load, no data yet" (show spinner) from "had data, now
    /// refreshing" (keep showing data).
    public private(set) var hasLoadedOnce = false
    private var offset = 0

    public init() {}

    /// Loads the next page. Errors are **not** swallowed — they propagate to the
    /// caller (typically a ViewModel) which can surface them in UI state.
    public func loadNext(fetch: (Int) async throws -> PageResponse<T>) async throws {
        guard hasMore && !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let page: PageResponse<T>
        do {
            page = try await fetch(offset)
        } catch {
            hasMore = false
            throw error
        }
        items.append(contentsOf: page.items)
        offset += page.items.count
        hasMore = page.hasMore
        hasLoadedOnce = true
    }

    public func reset() {
        items = []
        offset = 0
        hasMore = true
        isLoading = false
        isRefreshing = false
    }

    /// Silently refresh the first page in place: fetch offset 0, replace the
    /// first page's worth of items with the fresh page, and keep any
    /// already-loaded deeper-page items (by id) as the tail. Never clears
    /// `items`, never sets `isLoading`. Sets `isRefreshing` so callers can guard
    /// empty-state / spinner logic. Used for background auto-refresh so the list
    /// never flashes empty or shows a spinner; manual pull-to-refresh keeps its
    /// own system spinner and may also call this.
    ///
    /// Merge semantics: fresh first-page items replace same-id existing items
    /// (field updates); items whose id is not in the fresh page are kept as the
    /// tail (preserves already-loaded deeper pages); the pagination cursor
    /// (`offset`) is reset to the fresh page size and `hasMore` follows the
    /// fresh page so "load more" stays correct after a silent refresh.
    public func silentRefreshFirstPage(fetch: (Int) async throws -> PageResponse<T>) async throws {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let page = try await fetch(0)
        let freshIds = Set(page.items.map { $0.id })
        // Keep already-loaded deeper-page items whose id did not come back in
        // the fresh first page. They may still be valid; the next "load more"
        // reconciles from the reset offset.
        let tail = items.filter { !freshIds.contains($0.id) }
        items = page.items + tail
        offset = page.items.count
        hasMore = page.hasMore
        hasLoadedOnce = true
    }

    /// Replace or insert a single item by id (used after optimistic / server
    /// mutations so the list reflects the new value without a full reload).
    public func upsert(_ item: T) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }
}
