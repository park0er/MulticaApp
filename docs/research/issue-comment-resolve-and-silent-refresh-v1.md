# Issues 评论解决 + 无感后台刷新 技术方案 v1

日期：2026-06-29
范围：Multi-Casual iOS App —— Issue 评论「以此回复解决评论」功能，以及 Inbox / Issue 列表 / Issue 详情的「无感后台刷新」。
关联代码：`Multi-Casual/Models/Models.swift`、`Multi-Casual/Core/Network/APIClient.swift`、`Multi-Casual/Core/Cache/PaginatedLoader.swift`、`Multi-Casual/Features/Issues/*`、`Multi-Casual/Features/Inbox/*`。
参考来源：multica 官方源码 `/Users/park0er/coding/multica-web-source`（server / apps/mobile / apps/web）。

## 一、背景与目标

用户提出三点诉求：

1. **评论解决**：参考 multica 最新 web 端，在 Issue 评论里增加「以此回复解决评论」一类的按钮，能把某条回复标记为该评论线程的「已解决答案」。
2. **后台刷新**：支持后台刷新收件箱（Inbox）和 Issue 列表 / 详情。
3. **无感刷新**：自动刷新时绝不能把现有列表搞坏（清空、闪空、转圈）；只有用户手动下拉刷新时才允许显示转圈。自动刷新必须无感。

核心目标：把「刷新」从「清空重建」改成「后台静默合并」，并补齐评论解决能力。

## 二、调研结论

### 2.1 评论解决：官方实现已确认

从 server 源码 `server/internal/handler/comment.go` 与 `server/pkg/db/generated/comment.sql.go` 确认：

- `POST /api/comments/{id}/resolve`：把指定评论标记为已解决，写入 `resolved_at` / `resolved_by_type` / `resolved_by_id`。
- `DELETE /api/comments/{id}/resolve`：取消解决，清空上述三字段。
- **单解决不变量（single-resolution invariant）**：一个线程同一时刻最多只有一条已解决评论。resolve 时会在同一事务里清掉同线程其它评论的 `resolved_at`（`ClearOtherThreadResolutions`），所以「以此回复解决」会自动替换掉线程里旧的已解决答案。
- **目标可以是任意评论**（根评论或任意回复），`loadCommentForActor` 不限制 root。这与 web v0.3.19 changelog「Issue conversations can now resolve a specific reply」「Each Issue discussion thread now keeps only one resolved answer at a time」一致。
- 实时事件：`comment:resolved`（目标评论）、`comment:unresolved`（被替换掉的旧答案 + 主动 unresolve）。

官方 mobile（`apps/mobile`）实现要点（可作 UI 参考，但其「root only」注释是过时的，server 实际支持任意评论）：

- `api.resolveComment` / `api.unresolveComment`（`apps/mobile/data/api.ts`）。
- `useResolveComment(issueId)` mutation：乐观把 `resolved_at` 置为 now/null，失败回滚，成功后 invalidate timeline（`apps/mobile/data/mutations/issues.ts`）。
- WS `comment:resolved` / `comment:unresolved` 实时打补丁（`apps/mobile/data/realtime/use-issue-realtime.ts`）。
- 已解决线程默认折叠成一行 `ResolvedThreadBar`，点击就地展开（`apps/mobile/components/issue/comment-card.tsx`）。
- 长按菜单项「Resolve Thread / Unresolve Thread」。

### 2.2 iOS 现状差距

| 项 | 现状 | 差距 |
|---|---|---|
| Comment 模型 | `Models.swift:1919` 仅有 id/content/authorId/authorType/parentId/issueId/attachments/reactions/createdAt | 缺 `resolvedAt` / `resolvedByType` / `resolvedByID` |
| APIClient | `APIClient.swift` 有 addComment/updateComment/deleteComment/addReaction/removeReaction | 无 resolve/unresolve 方法 |
| IssueDetailVM | 有评论线程 `displayedCommentThreads`（root + replies）、回复/编辑/删除/反应 | 无解决动作、无已解决态展示 |
| CommentRowView | 椭圆菜单含回复/编辑/删除 + 反应 | 无「以此回复解决」入口、无已解决徽标 |
| 实时 | `WebSocketActor` 已存在，仅 Chat/AgentLive 使用 | Issue 详情未订阅 `comment:resolved` 等事件 |

### 2.3 刷新：现状就是「清空重建」

- `IssueListViewModel.refresh()`（`IssueListViewModel.swift:189`）= `resetPagination()` + `loadNext()`。`resetPagination()` 调 `loader.reset()` + `resetBuckets()`，**先把 items 清空**再重拉。
- `InboxViewModel.refresh()`（`InboxViewModel.swift:75`）= `loader.reset()` + `loadNext()`，同样先清空。
- `IssueDetailViewModel.loadComments()`（`IssueDetailViewModel.swift:695`）= `commentLoader.reset()` + 加载，先清空。
- 自动刷新触发点：两个列表都有 30s `autoRefreshTask` 调 `refreshIfIdle()`；`scenePhase == .active` 也调 `refreshIfIdle()`；workspace 变更调 `refresh()`。这些全部走「清空重建」路径。
- 结果：每 30 秒、每次回到前台，列表先变空/转圈再填回来 —— 正是用户说的「很卡、列表被搞坏」。

## 三、方案 A：评论解决（以此回复解决评论）

设计原则：对齐 server 语义 —— 任意评论可解决、每线程单解、解决即替换。UI 上把「以此回复解决」做成回复上的一等动作，并把已解决线程折叠成一行。

### A1. 数据模型（`Models.swift`）

`Comment` 增加三个可空字段，复用 snake_case CodingKeys：

```swift
public let resolvedAt: Date?
public let resolvedByType: String?
public let resolvedByID: String?
// CodingKeys: resolvedAt = "resolved_at", resolvedByType = "resolved_by_type", resolvedByID = "resolved_by_id"
```

`init(from:)` 用 `decodeIfPresent`。`replacingReactions` 风格补一个 `replacingResolved(at:byType:byID:)`（或直接在 VM 里 copy）。`TimelineEntry` 已有 `commentType`，可选地也加 `resolvedAt` 以便 timeline 模式展示，但首版可只改 `Comment`。

### A2. API 客户端（`APIClient.swift`）

新增两个方法，与 server 路径对齐：

```swift
public func resolveComment(commentId: String, workspaceId: String? = nil) async throws -> Comment {
    try await request("POST", path: "api/comments/\(commentId)/resolve",
                      queryItems: workspaceQuery(workspaceId))
}
public func unresolveComment(commentId: String, workspaceId: String? = nil) async throws -> Comment {
    let _: EmptyResponse = try await request("DELETE", path: "api/comments/\(commentId)/resolve",
                      queryItems: workspaceQuery(workspaceId))
    // server 实际返回更新后的 Comment；若 DELETE 走 EmptyResponse 则本地把字段清空
}
```

注意：server 的 DELETE 也返回更新后的 Comment（见 `commentToResponse`）。若现有 `request` 对 DELETE 默认按 `EmptyResponse` 解码，需要让 `unresolveComment` 显式按 `Comment` 解码，避免本地态与服务器态漂移。

### A3. ViewModel（`IssueDetailViewModel.swift`）

1. 线程解决态：`CommentThread` 增加 `var resolvedReply: Comment?`（线程内 `resolvedAt != nil` 的那条；至多一条）。在 `displayedCommentThreads` 计算时填充。
2. 解决动作：

```swift
public func resolveComment(commentId: String) async {
    guard let workspaceId = resolvedWorkspaceId else { return }
    // 乐观：先把同线程其它评论 resolvedAt 清空、把本条置 now
    applyResolveOptimistic(commentId: commentId, resolved: true)
    do {
        let updated = try await api.resolveComment(commentId: commentId, workspaceId: workspaceId)
        applyResolvedComment(updated)            // 用服务器权威值覆盖
    } catch {
        revertResolveOptimistic()                // 回滚
        lastError = error
    }
}
public func unresolveComment(commentId: String) async { /* 对称：乐观清空 → DELETE → 权威覆盖 */ }
```

3. 合并辅助：`applyResolvedComment(_:)` 把返回的 Comment 按 id 替换进 `commentLoader.items`，并**清掉同线程其它评论的 resolved 字段**（与 server 单解不变量一致，避免本地出现两条已解决）。复用现有 `threadRootCommentId(for:)`（`IssueDetailViewModel.swift:1062` 附近）定位线程。
4. 编辑/删除评论后保持解决态：`deleteComment` 若删的是已解决答案，线程自动回到未解决（server 侧已处理，本地按返回或重拉合并即可）。

### A4. UI（`IssueDetailView.swift`）

1. **入口**：在 `CommentRowView` 的椭圆 `Menu`（现有编辑/删除/反应处）里，对**任意评论**增加：
   - 未解决时：「以此回复解决」/「Resolve with this reply」（根评论可显示「解决此线程」/「Resolve thread」）。
   - 已解决时：「取消解决」/「Unresolve」。
   - 通过新增闭包 `onResolve: (String, Bool) async -> Void` 下发到 `commentRow`，再接到 VM。
2. **已解决徽标**：`CommentRowView` 当 `comment.resolvedAt != nil` 时，在头像/名字行右侧显示一个 `checkmark.circle.fill`（klein 蓝）+ 「已解决」小标，整条加一条左侧色条做视觉强调。这是「最终答案」的可见性。
3. **折叠条（ResolvedThreadBar）**：线程有已解决答案时，线程顶部渲染一行折叠条：「✓ 此线程已解决 · <解决者> · <时间>」，带「展开/折叠」与「跳到答案」。默认折叠线程体只保留折叠条 + 已解决答案；点击展开全部回复。无已解决答案时维持现状。
4. **乐观反馈**：点击后立即翻转徽标/折叠条（乐观），失败回滚并 toast。触觉反馈 `sensoryFeedback`。
5. 可达性：解决按钮加 `accessibilityIdentifier("CommentResolveButton-\(comment.id)")`，徽标加 `accessibilityLabel("已解决")`。

### A5. 实时（可选 · 第二阶段）

Issue 详情当前不订阅 WS。第二阶段可让 `IssueDetailViewModel` 通过 `WebSocketActor.subscribe(to: "comment:resolved")` / `"comment:unresolved"` 接收推送，解析 payload 里的 Comment，直接 `applyResolvedComment`。收益：多端协作时解决态即时同步，不必等下一次拉取。第一阶段靠「乐观 + 下次静默刷新」已可用，故 WS 列为增强项。

### A6. 边界与权限

- 权限：server 已做 workspace member 校验（`loadCommentForActor`）；客户端按现有评论编辑权限同等放行，不做额外限制。
- 并发：乐观更新期间禁用同一评论的解决按钮（`isResolving[commentId]` 防重入）。
- 删除已解决答案：依赖 server 单解不变量，本地合并时以「线程内至多一条 resolvedAt != nil」为不变式，发现多条以服务器最新返回为准。
- 离线/失败：回滚乐观态，错误走现有 `lastError` 通道，不阻塞列表。

### A7. 本地化

`Localizable.strings`（en + zh-Hans）新增：`Resolve with this reply` / `以此回复解决`、`Resolve thread` / `解决此线程`、`Unresolve` / `取消解决`、`Resolved` / `已解决`、`This thread is resolved` / `此线程已解决`。

## 四、方案 B：无感后台刷新（Inbox + Issue 列表 + Issue 详情）

### B1. 设计原则

1. **「刷新」不再等于「清空」**。任何刷新（自动 / 下拉 / 回前台）都不先把 items 清空；始终保留现有内容，等新数据回来后**就地合并/替换**。
2. **两类加载状态分离**：
   - `isLoading`：首次加载（尚无任何内容）或分页加载更多 —— 仅此时允许 `ProgressView` / 空态判断。
   - `isRefreshing`：后台静默刷新 —— **永不**触发空态、**永不**显示转圈、**永不**清空列表。
3. **只有手动下拉可转圈**：`.refreshable` 走系统下拉转圈（系统自身覆盖层，不动列表内容）。自动刷新（定时器、回前台、workspace 变更）一律走 `silentRefresh()`。
4. **保留用户上下文**：静默合并时保留选中、折叠的状态分组、滚动位置、已加载的更深分页。

### B2. PaginatedLoader 增强（`Core/Cache/PaginatedLoader.swift`）

新增「就地刷新首页」能力，不动 `isLoading`、不清空：

```swift
public var isRefreshing = false

/// 静默刷新第一页：拉 offset=0，把首页内容就地替换/合并，保留更深分页。
/// 全程不触发 isLoading、不清空 items。
public func silentRefreshFirstPage(fetch: (Int) async throws -> PageResponse<T>) async throws {
    isRefreshing = true
    defer { isRefreshing = false }
    let page = try await fetch(0)
    let freshIds = Set(page.items.map { $0.id })
    // 保留首页范围之外、已加载的更深层条目（按 id 去重）
    let tail = items.filter { !freshIds.contains($0.id) }
    items = page.items + tail
    // offset/hasMore 以首页为准：若首页未满或 server 报告无更多，则重置分页游标
    offset = page.items.count
    hasMore = page.hasMore
}
```

说明：此方法假设「首页大小」稳定。对按状态分组的列表（Issue 列表），合并按状态分别在 VM 里做（见 B3）。`reset()` 仍保留，仅用于真正的上下文切换（workspace 切换且需要清空旧工作区数据时）。

### B3. 列表 ViewModel 改造

**IssueListViewModel**（按状态分组，状态各带 offset）：

- 新增 `public func silentRefresh() async`：对每个 `IssueStatus.listCases` 并发拉首页（offset=0），按 id 就地合并进 `issuesByStatus[status]`：首页新条目覆盖/插入，首页之外已加载的更深层条目保留；重算 `offsetsByStatus` / `pageHasMoreByStatus` / `loader.items`（`syncFlatIssues`）。全程 `isRefreshing=true`，**不调** `resetPagination()`、**不**清空。
- `refresh()` 改为「保留下拉语义」：不再先 `resetPagination()`；改为直接 `silentRefresh()`。下拉转圈由 `.refreshable` 系统层提供，内容不被清空。仅在「首次加载且 items 为空」时才允许走 `loadNext()` 的 `isLoading` 路径显示首屏 ProgressView。
- `refreshIfIdle()`（自动触发入口）改为调 `silentRefresh()`，去掉对 `isLoading` 的硬阻塞改为「`isRefreshing` 时跳过」。
- 真正需要清空的场景（workspace 切换到不同工作区）：单独保留 `fullReset()`，且**先拉新数据成功后再替换**，或仅在确实切换工作区时清空（避免空窗）。
- 空态/ProgressView 守卫（`IssueListView`）：空态条件改为 `!hasLoadedFirstPages && items.isEmpty && !isRefreshing`；列表 ProgressView 仅 `!hasLoadedFirstPages && isLoading`。`isRefreshing` 期间一律不改变现有展示。

**InboxViewModel**：

- 新增 `silentRefresh()`：`loader.silentRefreshFirstPage { offset in api.listInbox(...) }`，复用 `deduplicateInboxItems`。
- `refresh()` 不再 `loader.reset()`，改为 `silentRefresh()`；`refreshIfIdle()` 调 `silentRefresh()`。
- `InboxView` 的空态/ProgressView 守卫同上：仅首屏 `isLoading` 显示 ProgressView；`isRefreshing` 不闪空。

### B4. Issue 详情改造（`IssueDetailViewModel`）

- 新增 `silentRefreshComments()`：`commentLoader.silentRefreshFirstPage { offset in api.listComments(...) }`，合并后重算 `displayedCommentThreads`。**不**调 `commentLoader.reset()`。
- `loadComments()`（首屏）保持现状（首次清空+加载合理）；之后的刷新一律走 `silentRefreshComments()`。
- Issue 本体、timeline、active tasks、agent runs 等也可加 `silentRefresh*()`：后台重拉后**就地替换**，不切 `isLoading`。首版优先做 comments + issue 本体 + timeline。
- 详情页 `onAppear` 已是首屏加载（保留）；新增「回前台 / 定时」静默刷新触发（详情页可加一个低频 30–60s 静默刷新，或仅在 `scenePhase == .active` 时刷一次）。

### B5. UI 状态机（不闪空、不转圈）

统一规则，落地到 Issue 列表 / Inbox / 详情评论三处：

| 场景 | isLoading | isRefreshing | 展示 |
|---|---|---|---|
| 首次进入，无数据 | true | false | 首屏 ProgressView |
| 已有数据 + 自动刷新 | false | true | **原列表不变**，无转圈 |
| 已有数据 + 下拉刷新 | false | false | 系统下拉转圈（覆盖层），内容不变 |
| 已有数据 + 空结果返回 | false | false | 保持原列表（不闪空态）；可选「已最新」轻提示 |
| 首次加载失败 | false | false | 错误重试视图 |

关键：**空态判断必须同时要求 `!isRefreshing` 且「从未成功加载过」**，否则后台刷新途中网络抖动返回空会把列表误判成空。

### B6. 实时补充（可选 · 第二阶段）

`WebSocketActor` 已具备 `subscribe(to:)`。第二阶段可让 Issue 详情订阅 `comment:resolved` / `comment:unresolved` / issue 更新事件，Inbox/列表订阅 inbox/issue 变更事件，做到「改动即同步」，进一步降低对轮询的依赖。第一阶段以「30s + 回前台静默刷新」达成无感即可。

### B7. 边界

- 合并去重：所有静默合并按 `id` 去重，新值覆盖旧值字段。
- 排序：合并后按当前 `sortOption` / `sortDirection` 重新排序，避免顺序抖动。
- 选中/折叠：合并只替换数据，不动 `selectedIssueIds` / `collapsedStatusSections`。
- 分页一致性：首页刷新若 `hasMore` 变化，重置对应状态游标；已加载的更深页条目按 id 保留，下次「加载更多」从新 offset 继续。
- workspace 切换：仍需清空（上下文不同），但改为「新数据到位再替换」以消除空窗。
- 失败静默：`silentRefresh` 失败只记 `lastError`（可选轻提示），不回滚已有列表（因为没清空过）。

## 五、实施步骤与优先级

**P0 · 无感刷新（先做，独立可交付，用户体感最强）**

1. `PaginatedLoader` 增加 `isRefreshing` + `silentRefreshFirstPage`。
2. `InboxViewModel` / `IssueListViewModel` 增加 `silentRefresh()`；`refresh()`/`refreshIfIdle()` 改走静默路径；空态/ProgressView 守卫加 `!isRefreshing`。
3. `IssueDetailViewModel` 增加 `silentRefreshComments()` + 详情本体静默刷新；自动触发改走静默路径。
4. 验证：30s 定时、回前台、workspace 切换三种触发下，列表不闪空、不转圈；下拉仍转圈。

**P1 · 评论解决**

5. `Comment` 模型加 `resolvedAt` / `resolvedByType` / `resolvedByID`。
6. `APIClient` 加 `resolveComment` / `unresolveComment`（DELETE 按 Comment 解码）。
7. `IssueDetailViewModel` 加解决动作 + 乐观更新 + 单解不变量合并；`CommentThread.resolvedReply`。
8. `CommentRowView` 椭圆菜单加「以此回复解决 / 取消解决」+ 已解决徽标；线程加 `ResolvedThreadBar` 折叠条。
9. 本地化；可达性标识。

**P2 · 实时增强（可选）**

10. Issue 详情订阅 `comment:resolved` / `comment:unresolved`；Inbox/列表订阅相关事件。

每完成一个 P0/P1 子项做一次本地 commit（符合频繁 checkpoint）。

## 六、风险与回滚

- **合并语义回归**：静默合并若去重/排序不当会造成条目丢失或跳动。对策：合并单元加单测（按 id 合并、保留深页、重排序稳定）；线上灰度先只改 Inbox，再改 Issue 列表。
- **DELETE 解码漂移**：若 `unresolveComment` 误用 `EmptyResponse`，本地态会与 server 不一致。对策：显式按 `Comment` 解码，并以服务器返回为权威。
- **单解不变量本地破坏**：乐观更新需同步清同线程旧答案；单测覆盖「线程内 resolve 第二条 → 第一条 resolvedAt 被清」。
- **性能**：静默刷新不改首屏路径，额外成本仅一次首页请求（与现状相同频率），无新增轮询。
- **回滚**：P0 与 P1 相互独立；P0 出问题可回退到 `refresh()` 清空路径（行为退回现状，无数据风险）。P1 出问题可隐藏菜单项，不影响阅读。

## 七、验收清单

- [ ] 自动刷新（30s / 回前台）时，Inbox 与 Issue 列表内容不闪空、不转圈、滚动位置不跳。
- [ ] 手动下拉刷新显示系统转圈，松手后内容更新。
- [ ] workspace 切换无空窗（新数据到位再替换）。
- [ ] Issue 详情评论后台刷新不清空已有评论。
- [ ] 任意回复可点「以此回复解决」，徽标立即出现（乐观），失败回滚。
- [ ] 同线程解决第二条时，第一条自动取消解决（单解）。
- [ ] 已解决线程折叠为一行，可展开、可跳到答案。
- [ ] 「取消解决」可还原线程。
- [ ] en / zh-Hans 文案齐全；解决按钮有 accessibilityIdentifier。
