# Issues 附件原生预览渲染器调研 v1

日期：2026-06-19  
范围：Multica iOS App 的 issue / comment / reply 附件浏览体验，重点支持 Markdown、HTML/XML/text 在 App 内直接预览。

## 结论

可行，而且后端和官方 Web 端已经基本铺好了路。推荐 iOS 侧做一个统一的 `AttachmentPreviewView` / sheet：附件行不再只打开下载链接，而是先按 `contentType + filename` 分类；Markdown 走原生 `MarkdownText` 渲染，HTML 走 `WKWebView` 沙箱渲染，XML/代码/普通文本走只读文本/代码视图。文件仍保留“下载 / 分享 / 外部打开”入口。

优先级建议：

1. **第一阶段**：支持 `.md/.markdown`、`.html/.htm`、`.xml`、`.json`、`.txt`、常见源码文本。
2. **第二阶段**：复用同一个预览框架补 PDF、图片、音视频的 App 内预览。
3. **第三阶段**：给 Markdown 增强代码块、表格、图片点击、内部链接跳转。

## 当前 iOS 现状

仓库：`/Users/park0er/coding/MulticaApp`

已具备：

- `Attachment` 模型已有 `filename`、`downloadUrl`、`contentType`、`sizeBytes`、`issueId/commentId` 等字段。
- `Issue`、`Comment`、timeline entry 都已经能 decode `attachments`。
- Issue detail 的附件列表统一在 `AttachmentListView` / `AttachmentRowView`。
- 当前附件行的主动作是 `Link(destination: URL(...downloadUrl...))`，所以系统倾向下载/跳外部处理。
- iOS 已有 `MarkdownText` 和 `MarkdownRenderer`，issue description / comments 里已经在用 Markdown 渲染。
- `APIClient` 目前有 `uploadFile`、`listAttachments`、`deleteAttachment`，但还没有 `GET /api/attachments/{id}/content` 的客户端方法。

核心缺口：

- 附件点击没有进入 App 内 preview sheet。
- iOS 没有读取文本附件 body 的 API 方法。
- 没有附件类型分类器，即 Web 端 `getPreviewKind(contentType, filename)` 的 Swift 等价物。
- HTML 预览需要明确安全边界，不能直接把下载 URL 放给系统浏览器。

## 官方 Web 端参考

本地官方源码已更新：`/Users/park0er/coding/multica-web-source`，远端为 `https://github.com/multica-ai/multica`。

关键实现：

- `packages/views/editor/utils/preview.ts`
  - 定义 `PreviewKind = image | pdf | video | audio | markdown | html | text`。
  - 用 `contentType + filename extension + basename` 分类。
  - Markdown：`text/markdown` 或 `.md/.markdown`。
  - HTML：`text/html` 或 `.html/.htm`。
  - XML/SVG/JSON/YAML/源码等归入 `text`。
- `packages/views/editor/attachment-preview-modal.tsx`
  - 统一 modal 框架，媒体用 `download_url`，文本类走 API 获取正文。
  - Markdown 用现有 `ReadonlyContent` 渲染。
  - HTML 用 iframe `srcdoc` 渲染。
- `packages/views/editor/html-preview-body.tsx`
  - 单一 HTML 预览组件。
  - iframe sandbox 只允许 `allow-scripts`，刻意不允许 `allow-same-origin`。
  - 附带 fragment navigation shim，修复 iframe 内锚点点击。
- `server/internal/handler/file.go`
  - 已有 `GET /api/attachments/{id}/content`。
  - 文本预览上限 2 MB。
  - 非文本白名单返回 415，超大返回 413。
  - 返回 `text/plain; charset=utf-8`，并用 `X-Original-Content-Type` 暴露原 MIME，避免浏览器把恶意 HTML 直接当文档执行。

这个设计可以直接迁移到 iOS：媒体继续用 signed `downloadUrl`；Markdown/HTML/XML/text 通过 authenticated `/content` 代理读取文本。

## 推荐 iOS 方案

### 1. 类型分类器

新增 Swift 等价的 `AttachmentPreviewKind`：

- `image`
- `pdf`
- `video`
- `audio`
- `markdown`
- `html`
- `text(language: String?)`
- `unsupported`

判断顺序建议跟 Web 保持一致：PDF/video/audio → image → markdown → html → text-like → unsupported。

### 2. APIClient 增加文本内容接口

新增：

```swift
public func getAttachmentContent(id: String, workspaceId: String? = nil) async throws -> String
```

路径：`api/attachments/{id}/content`。复用已有 `request` 管线，确保 bearer token、workspace slug、错误处理一致。

错误映射建议：

- 413：提示“文件太大，无法内联预览，可下载查看”。
- 415：提示“此文件类型暂不支持预览”。
- 404/403：提示“附件不可用或无权限”。

### 3. 统一预览入口

把 `AttachmentRowView` 的主点击从 `Link` 改成 `Button`：

- 可预览：打开 `.sheet(item:)` 或 `.navigationDestination` 展示 `AttachmentPreviewView`。
- 不可预览：保留当前外部 URL 行为或弹出操作菜单。
- 行尾保留下载/分享按钮，避免用户找不到原始文件。

推荐用 `.sheet(item:)`，选中附件就是 sheet state，避免多个 boolean。

### 4. Markdown 渲染

第一版直接复用 `MarkdownText`：

- `AttachmentMarkdownPreview` 在 `.task(id: attachment.id)` 中加载正文。
- 加载成功后 `ScrollView { MarkdownText(content) }`。
- 失败显示 `ErrorRetryView`。
- 顶部工具栏显示文件名、大小、下载按钮。

注意：现有 `MarkdownText` 对复杂 GFM 表格、代码高亮、图片等能力可能不如 Web。第一阶段先达成“手机内可读”，第二阶段再增强。

### 5. HTML 渲染

用 `WKWebView`，不要用系统 Safari 直接打开 signed URL。

推荐安全边界：

- 文本 body 仍来自 `/api/attachments/{id}/content`。
- 用 `WKWebView.loadHTMLString(content, baseURL: nil)`。
- 使用非持久 `WKWebsiteDataStore.nonPersistent()`。
- 禁用不必要的导航：`WKNavigationDelegate` 拦截外链，外部 URL 走确认后 `openURL`。
- 默认允许附件 HTML 内 JS，与 Web 的 iframe `sandbox="allow-scripts"` 对齐；如果担心风险，可第一版禁 JS，并给“启用交互预览”开关。
- 不给 cookie/localStorage 持久环境，避免附件 HTML 读 App 登录态。

iOS 没有 Web iframe sandbox 的完全等价物，但 `WKWebView` + non-persistent store + baseURL nil + navigation policy 可以做到足够接近。

### 6. XML / text / code 渲染

XML 不建议当 HTML 执行，应该归入 `text`：

- XML/SVG/HTML 源码查看可用 monospaced `Text` / `TextEditor` / 自定义 `ScrollView`。
- `.html/.htm` 默认走 rendered HTML；可提供“查看源码”切换。
- `.xml/.svg` 默认查看源码；SVG 如果用户强烈需要可后续增加 rendered SVG 模式。
- 源码高亮第一版可以先不做，保留等宽字体、复制、横向滚动即可。

## 代码落点建议

- `Multi-Casual/Features/Common/AttachmentPreviewKind.swift`：Swift 版分类器，配单元测试。
- `Multi-Casual/Core/Network/APIClient.swift`：增加 `getAttachmentContent`。
- `Multi-Casual/Features/Common/AttachmentPreviewView.swift`：统一 preview sheet，包括加载态、错误态、下载/分享动作。
- `Multi-Casual/Features/Common/HTMLAttachmentPreview.swift`：`UIViewRepresentable` 包装 `WKWebView`。
- `Multi-Casual/Features/Issues/IssueDetailView.swift`：`AttachmentRowView` 改为打开 preview；issue/comment/reply 附件自动复用。
- `Multi-CasualTests/Core/AttachmentPreviewKindTests.swift`：对齐 Web 的分类规则。
- `Multi-CasualTests/Core/APIClientTests.swift`：覆盖 `/api/attachments/{id}/content`。

## 风险和取舍

- **HTML 安全**：HTML 是用户上传内容，必须隔离。不要把 App token 注入 WebView，不要给持久 cookie，不要允许任意顶层跳转。
- **大文件性能**：沿用后端 2 MB 上限；iOS 侧也可以在 `sizeBytes` 上提前提示。
- **CORS / Content-Disposition**：不要直接 fetch `downloadUrl` 获取文本，按 Web 方案走 `/content`，否则会遇到 CloudFront CORS 和 attachment disposition。
- **Web/iOS 规则漂移**：Web 已经有手写白名单。iOS 初期也只能手写同步；后续可把 preview type table 抽成共享 JSON，由 Web / server / iOS 生成。
- **Markdown 能力差异**：iOS `AttributedString(markdown:)` 能力有限；已有 `MarkdownText` 已补了一部分块级渲染，但仍不等同 Web 的完整 `ReadonlyContent`。

## 建议开发顺序

1. 写 `AttachmentPreviewKind` + 测试，保证 `.md/.html/.xml/.json/.swift/.txt` 分类正确。
2. 给 `APIClient` 加 `getAttachmentContent` + mock 测试。
3. 做 `AttachmentPreviewView` 的 markdown/text 两类，先不碰 HTML。
4. 接入 `IssueDetailView` 附件行，完成 issue/comment/reply 统一入口。
5. 加 `WKWebView` HTML rendered preview，附带源码/下载 fallback。
6. 最后跑 SwiftPM tests 和 Xcode build。

## 推荐下一步

建议先做一个小 PR/commit：只包含分类器、API 方法、Markdown/text 预览和 Issues 附件入口。HTML `WKWebView` 可以放同一 PR 的第二个 commit，或者单独 PR，因为安全策略需要更仔细 review。
