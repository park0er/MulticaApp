#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI
import UIKit
import WebKit

public struct AttachmentPreviewView: View {
    public let attachment: Attachment
    public let workspaceId: String?

    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.appLanguage) private var appLanguage
    @State private var textState: AttachmentTextState = .idle
    @State private var showHTMLSource = false

    private var previewKind: AttachmentPreviewKind {
        AttachmentPreviewKind(contentType: attachment.contentType, filename: attachment.filename)
    }

    public init(attachment: Attachment, workspaceId: String? = nil) {
        self.attachment = attachment
        self.workspaceId = workspaceId
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(attachment.filename)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(AppStrings.localized("Done", language: appLanguage)) { dismiss() }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if case .html = previewKind, textState.content != nil {
                            Button(showHTMLSource ? "Render" : "Source") {
                                showHTMLSource.toggle()
                            }
                            .accessibilityIdentifier("AttachmentPreviewSourceToggle")
                        }
                        if let url = downloadURL {
                            Button {
                                openURL(url)
                            } label: {
                                Label(AppStrings.localized("Download", language: appLanguage), systemImage: "arrow.down.circle")
                            }
                        }
                    }
                }
                .task(id: attachment.id) {
                    await loadTextIfNeeded()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch previewKind {
        case .markdown:
            loadedTextContent { text in
                ScrollView {
                    MarkdownText(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        case .html:
            loadedTextContent { text in
                ZStack {
                    HTMLAttachmentPreview(html: text) { url in
                        openURL(url)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(showHTMLSource ? 0 : 1)
                    .allowsHitTesting(!showHTMLSource)
                    .ignoresSafeArea(edges: .bottom)

                    if showHTMLSource {
                        TextAttachmentSourceView(content: text)
                    }
                }
            }
        case .text(let language):
            loadedTextContent { text in
                TextAttachmentSourceView(content: text, language: language)
            }
        case .image, .pdf, .video, .audio, .unsupported:
            fallbackContent
        }
    }

    @ViewBuilder
    private func loadedTextContent<Content: View>(@ViewBuilder content: (String) -> Content) -> some View {
        switch textState {
        case .idle, .loading:
            ProgressView("Loading preview…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let text):
            content(text)
        case .failed(let message):
            ContentUnavailableView(
                AppStrings.localized("Preview Unavailable", language: appLanguage),
                systemImage: "doc.text.magnifyingglass",
                description: Text(message)
            )
            .overlay(alignment: .bottom) {
                if let url = downloadURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label(AppStrings.localized("Open Original", language: appLanguage), systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            }
        }
    }

    private var fallbackContent: some View {
        ContentUnavailableView(
            fallbackTitle,
            systemImage: fallbackIconName,
            description: Text(AppStrings.localized("This file can still be opened or downloaded with another app.", language: appLanguage))
        )
        .overlay(alignment: .bottom) {
            if let url = downloadURL {
                Button {
                    openURL(url)
                } label: {
                    Label(AppStrings.localized("Open Original", language: appLanguage), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
    }

    private var fallbackTitle: String {
        let title: String
        switch previewKind {
        case .image:
            title = "Image Preview Coming Soon"
        case .pdf:
            title = "PDF Preview Coming Soon"
        case .video:
            title = "Video Preview Coming Soon"
        case .audio:
            title = "Audio Preview Coming Soon"
        case .unsupported:
            title = "Preview Unsupported"
        case .markdown, .html, .text:
            title = "Preview Unavailable"
        }
        return AppStrings.localized(title, language: appLanguage)
    }

    private var fallbackIconName: String {
        switch previewKind {
        case .image:
            return "photo"
        case .pdf:
            return "doc.richtext"
        case .video:
            return "play.rectangle"
        case .audio:
            return "waveform"
        default:
            return "paperclip"
        }
    }

    private var downloadURL: URL? {
        URL(string: attachment.downloadUrl.isEmpty ? attachment.url : attachment.downloadUrl)
    }

    private func loadTextIfNeeded() async {
        guard previewKind.isInlinePreviewable else { return }
        guard case .idle = textState else { return }
        textState = .loading
        do {
            let content = try await api.getAttachmentContent(id: attachment.id, workspaceId: workspaceId)
            textState = .loaded(content)
        } catch {
            textState = .failed(previewErrorMessage(for: error))
        }
    }

    private func previewErrorMessage(for error: Error) -> String {
        if case APIClient.APIError.serverError(let status, _) = error {
            switch status {
            case 413:
                return AppStrings.localized("This file is too large for inline preview. Download it to view the original.", language: appLanguage)
            case 415:
                return AppStrings.localized("This file type is not supported for inline preview.", language: appLanguage)
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

private enum AttachmentTextState: Equatable {
    case idle
    case loading
    case loaded(String)
    case failed(String)

    var content: String? {
        if case .loaded(let content) = self { return content }
        return nil
    }
}

private struct TextAttachmentSourceView: View {
    let content: String
    var language: String?

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(.secondary)
                }
                Text(content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }
}

public struct HTMLAttachmentPreview: UIViewRepresentable {
    public let html: String
    public var openExternalURL: (URL) -> Void

    public init(html: String, openExternalURL: @escaping (URL) -> Void) {
        self.html = html
        self.openExternalURL = openExternalURL
    }

    public func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.keyboardDismissMode = .interactive
        webView.scrollView.delaysContentTouches = false
        webView.scrollView.canCancelContentTouches = true
        webView.scrollView.isScrollEnabled = true
        webView.evaluateJavaScript("document.documentElement.style.webkitTouchCallout = 'none'")
        return webView
    }

    public func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.loadedHTML == html && context.coordinator.loadedWebView === webView {
            return
        }
        context.coordinator.loadedHTML = html
        context.coordinator.loadedWebView = webView
        webView.loadHTMLString(html, baseURL: nil)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(openExternalURL: openExternalURL)
    }

    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?
        var loadedWebView: WKWebView?
        private let openExternalURL: (URL) -> Void

        init(openExternalURL: @escaping (URL) -> Void) {
            self.openExternalURL = openExternalURL
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(.allow)
                return
            }
            if let url = navigationAction.request.url, !url.isFileURL {
                openExternalURL(url)
            }
            decisionHandler(.cancel)
        }

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                openExternalURL(url)
            }
            return nil
        }
    }
}
#endif
