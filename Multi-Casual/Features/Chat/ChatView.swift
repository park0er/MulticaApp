#if canImport(SwiftUI) && canImport(UIKit)
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

public struct ChatView: View {
    @Environment(APIClient.self) private var api
    @Environment(AuthSession.self) private var authSession
    @State private var viewModel: ChatViewModel?

    public init() {}

    public var body: some View {
        Group {
            if let vm = viewModel {
                List {
                    if vm.isLoading && vm.sessions.isEmpty {
                        ProgressView()
                    } else if vm.sessions.isEmpty && vm.errorMessage == nil {
                        ContentUnavailableView(
                            "No Chats",
                            systemImage: "message",
                            description: Text("Start a chat with an agent in this workspace.")
                        )
                    } else {
                        ForEach(vm.sessions) { session in
                            NavigationLink {
                                ChatSessionDetailView(viewModel: vm, session: session)
                            } label: {
                                ChatSessionRow(
                                    session: session,
                                    agentName: vm.agentName(for: session.agentId),
                                    agentAvatarUrl: vm.agentAvatarUrl(for: session.agentId),
                                    agentStatusDot: vm.agentStatusDot(for: session.agentId),
                                    pendingCount: vm.pendingTaskCount(for: session)
                                )
                            }
                        }
                    }

                    if let errorMessage = vm.errorMessage {
                        Section {
                            ErrorRetryView(message: errorMessage) {
                                Task { await vm.load() }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await vm.load() }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            ChatSessionDetailView(viewModel: vm, session: vm.draftSessionPreview)
                        } label: {
                            Label("New Chat", systemImage: "plus")
                        }
                        .accessibilityIdentifier("ChatNewButton")
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Chat")
        .onAppear {
            if viewModel == nil {
                let vm = ChatViewModel(api: api, authSession: authSession)
                viewModel = vm
                Task { await vm.load() }
            }
        }
        .onChange(of: authSession.currentWorkspace?.id) { _, _ in
            guard let viewModel else { return }
            Task { await viewModel.load() }
        }
    }
}

private struct ChatSessionRow: View {
    let session: ChatSession
    let agentName: String
    var agentAvatarUrl: String? = nil
    var agentStatusDot: AvatarView.StatusDot? = nil
    let pendingCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(name: agentName, avatarUrl: agentAvatarUrl, kind: .agent, size: 28, statusDot: agentStatusDot)
                .overlay(alignment: .topLeading) {
                    if session.hasUnread {
                        Circle().fill(Color.accentColor).frame(width: 8, height: 8).offset(x: -2, y: -2)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    MarkdownText(session.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if session.hasUnread {
                        Text("Unread")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                MarkdownText(agentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    MarkdownText(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if pendingCount > 0 {
                        Text("Running")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension ChatViewModel {
    var draftSessionPreview: ChatSession {
        let agentId = selectedSession?.agentId ?? agents.first?.id ?? ""
        return ChatSession(
            id: Self.draftSessionId,
            workspaceId: "",
            agentId: agentId,
            creatorId: "",
            title: "New Chat",
            status: .active,
            hasUnread: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

private struct ChatSessionDetailView: View {
    @Bindable var viewModel: ChatViewModel
    let session: ChatSession
    @Environment(AuthSession.self) private var authSession
    @State private var draft = ""
    @State private var didStartDraftSession = false
    @State private var subscriptionTask: Task<Void, Never>?
    @State private var selectedDraftAgentId: String?
    @State private var showAttachmentImporter = false
    @State private var selectedImageItem: PhotosPickerItem?
    @FocusState private var isComposerFocused: Bool

    private var isDraftSessionView: Bool {
        session.id == ChatViewModel.draftSessionId && (didStartDraftSession || viewModel.isDraftSession)
    }

    private var activeDraftAgentId: String {
        selectedDraftAgentId ?? viewModel.selectedSession?.agentId ?? session.agentId
    }

    var body: some View {
        List {
            Section {
                if isDraftSessionView {
                    Picker("Agent", selection: Binding(
                        get: { activeDraftAgentId },
                        set: { newValue in
                            selectedDraftAgentId = newValue
                            viewModel.startDraftSession(agentId: newValue)
                        }
                    )) {
                        ForEach(viewModel.agents) { agent in
                            MarkdownText(agent.name).tag(agent.id)
                        }
                    }
                    .disabled(viewModel.agents.isEmpty || viewModel.isCreating || viewModel.isSending)
                    .accessibilityIdentifier("ChatAgentPicker")
                } else {
                    MarkdownLabeledContent("Agent", value: viewModel.agentName(for: session.agentId))
                }
                if !isDraftSessionView, let pending = viewModel.pendingTask, let status = pending.status {
                    MarkdownLabeledContent("Task", value: status.capitalized)
                    Button(role: .destructive) {
                        Task { await viewModel.cancelPendingTask() }
                    } label: {
                        MarkdownIconLabel(viewModel.isCancellingTask ? "Cancelling" : "Cancel Task", systemImage: "xmark.circle")
                    }
                    .disabled(viewModel.isCancellingTask || pending.taskId?.isEmpty != false)
                    .accessibilityIdentifier("ChatCancelPendingTaskButton")
                }
            }

            Section("Messages") {
                if isDraftSessionView && viewModel.messages.isEmpty {
                    ChatWelcomeView(agentName: viewModel.agentName(for: activeDraftAgentId)) { prompt in
                        send(prompt)
                    }
                } else if viewModel.messages.isEmpty && viewModel.errorMessage == nil {
                    MarkdownText("No messages yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.messages) { message in
                        ChatMessageRow(
                            message: message,
                            timeline: viewModel.timelineItems(for: message)
                        )
                    }
                    if viewModel.shouldShowLiveTimeline {
                        ChatLiveTimelineRow(
                            pendingTask: viewModel.pendingTask,
                            timeline: viewModel.visibleTimelineItems,
                            isLoading: viewModel.isSending || viewModel.isLoadingTimeline,
                            errorMessage: viewModel.timelineError
                        )
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    ErrorRetryView(message: errorMessage) {
                        Task { await viewModel.loadMessages() }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.isCreating || viewModel.isSending || (!isDraftSessionView && viewModel.visiblePendingTaskId != nil) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        MarkdownText(viewModel.isCreating ? "Creating chat" : viewModel.isSending ? "Sending message" : "Agent is responding")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !isDraftSessionView && viewModel.visiblePendingTaskId != nil {
                            Button("Cancel") {
                                Task { await viewModel.cancelPendingTask() }
                            }
                            .font(.caption.weight(.semibold))
                            .disabled(viewModel.isCancellingTask)
                            .accessibilityIdentifier("ChatComposerCancelTaskButton")
                        }
                    }
                }
                if !viewModel.draftAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(viewModel.draftAttachments) { attachment in
                                Label {
                                    MarkdownText(attachment.filename)
                                        .font(.caption)
                                } icon: {
                                    Image(systemName: "paperclip")
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.secondary.opacity(0.1), in: Capsule())

                                Button {
                                    viewModel.removeDraftAttachment(id: attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("Remove \(attachment.filename)")
                                .accessibilityIdentifier("ChatDraftAttachmentRemoveButton-\(attachment.id)")
                            }
                        }
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if isComposerFocused {
                        PhotosPicker(
                            selection: $selectedImageItem,
                            matching: .images
                        ) {
                            if viewModel.isUploadingAttachment {
                                ProgressView()
                            } else {
                                Image(systemName: "photo.circle")
                                    .font(.title3)
                            }
                        }
                        .disabled(viewModel.isUploadingAttachment || viewModel.isSending || viewModel.isCreating)
                        .accessibilityIdentifier("ChatAddImageButton")

                        Button {
                            showAttachmentImporter = true
                        } label: {
                            if viewModel.isUploadingAttachment {
                                ProgressView()
                            } else {
                                Image(systemName: "paperclip.circle")
                                    .font(.title3)
                            }
                        }
                        .disabled(viewModel.isUploadingAttachment || viewModel.isSending || viewModel.isCreating)
                        .accessibilityIdentifier("ChatAddAttachmentButton")
                    }

                    GrowingComposerTextField(
                        placeholder: "Message",
                        text: $draft,
                        isExpanded: isComposerFocused,
                        minLines: 3,
                        maxLines: 8,
                        accessibilityIdentifier: "ChatMessageField"
                    )
                    .focused($isComposerFocused)
                    if isComposerFocused {
                        Button {
                            isComposerFocused = false
                            dismissChatKeyboard()
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.title3)
                        }
                        .accessibilityLabel("Dismiss Keyboard")
                        .accessibilityIdentifier("ChatDismissKeyboardButton")
                    }
                    Button { send(draft) } label: {
                        Image(systemName: viewModel.isSending ? "hourglass" : "paperplane.fill")
                    }
                    .disabled(viewModel.isSending || viewModel.isCreating || viewModel.isUploadingAttachment || !canSend)
                    .accessibilityIdentifier("ChatSendButton")
                }
            }
            .padding()
            .background(.bar)
            .fileImporter(
                isPresented: $showAttachmentImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleAttachmentImport(result)
            }
            .onChange(of: selectedImageItem) { _, item in
                handleImageSelection(item)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !isDraftSessionView {
                    Button(role: .destructive) {
                        Task { await viewModel.archiveSelectedSession() }
                    } label: {
                        Image(systemName: "archivebox")
                    }
                    .accessibilityIdentifier("ChatArchiveButton")
                }
            }
        }
        .markdownNavigationTitle(isDraftSessionView ? "New Chat" : session.title)
        .task {
            if session.id == ChatViewModel.draftSessionId {
                didStartDraftSession = true
                selectedDraftAgentId = selectedDraftAgentId ?? session.agentId
                viewModel.startDraftSession(agentId: session.agentId)
            } else {
                await viewModel.selectSession(session)
            }
            subscribeToWebSocket()
        }
        .onDisappear {
            subscriptionTask?.cancel()
            subscriptionTask = nil
        }
    }

    private func subscribeToWebSocket() {
        subscriptionTask?.cancel()
        guard let token = authSession.token(),
              let workspaceId = authSession.currentWorkspace?.id,
              !workspaceId.isEmpty
        else { return }
        subscriptionTask = Task {
            await WebSocketActor.shared.connect(token: token, workspaceId: workspaceId)
            for await event in await WebSocketActor.shared.subscribe(to: "task:message") {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    viewModel.applyRealtimeTaskMessage(taskId: event.taskId, payload: event.payload)
                }
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.draftAttachments.isEmpty
    }

    private func send(_ content: String) {
        let outgoing = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outgoing.isEmpty || !viewModel.draftAttachments.isEmpty else { return }
        if session.id == ChatViewModel.draftSessionId, !viewModel.isDraftSession {
            viewModel.startDraftSession(agentId: selectedDraftAgentId ?? session.agentId)
        }
        Task {
            let sent = await viewModel.sendMessage(outgoing)
            if sent {
                didStartDraftSession = false
                isComposerFocused = false
                if draft == content { draft = "" }
            }
            if !sent, draft.isEmpty { draft = outgoing }
        }
    }

    private func handleAttachmentImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let payload = try AttachmentImport.payload(from: url)
            Task {
                await viewModel.uploadDraftAttachment(
                    filename: payload.filename,
                    data: payload.data,
                    contentType: payload.contentType
                )
            }
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func handleImageSelection(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { selectedImageItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentImportError.unreadableImage
                }
                let payload = try AttachmentImport.imagePayload(
                    data: data,
                    contentType: item.supportedContentTypes.first,
                    filenamePrefix: "chat-image"
                )
                await viewModel.uploadDraftAttachment(
                    filename: payload.filename,
                    data: payload.data,
                    contentType: payload.contentType
                )
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

private func dismissChatKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

private struct ChatWelcomeView: View {
    let agentName: String
    let onSelectPrompt: (String) -> Void

    private let prompts = [
        "Summarize what changed recently in this workspace.",
        "Help me plan the next task step by step.",
        "Review open issues and suggest priorities."
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Welcome to Chat", systemImage: "sparkles")
                .font(.headline)
            MarkdownText("Start a new conversation with \(agentName). Choose a starter question or write your own message below.")
                .foregroundStyle(.secondary)
            ForEach(prompts, id: \.self) { prompt in
                Button { onSelectPrompt(prompt) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.up.right.circle")
                        MarkdownText(prompt)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("ChatWelcomeView")
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    let timeline: [TimelineItem]

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble(alignment: .leading, color: Color.secondary.opacity(0.12))
                Spacer(minLength: 32)
            } else {
                Spacer(minLength: 32)
                bubble(alignment: .trailing, color: Color.accentColor.opacity(0.14))
            }
        }
        .listRowSeparator(.hidden)
    }

    private func bubble(alignment: HorizontalAlignment, color: Color) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            if message.role == .assistant, !timeline.isEmpty {
                ChatTimelineView(items: timeline)
            } else {
                MarkdownText(message.content)
                    .font(.body)
            }
            if !message.attachments.isEmpty {
                VStack(spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        ChatAttachmentRowView(attachment: attachment)
                    }
                }
            }
            if let failureReason = message.failureReason, !failureReason.isEmpty {
                MarkdownText(failureReason)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let elapsedMs = message.elapsedMs {
                MarkdownText("Replied in \(max(1, elapsedMs / 1000))s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(color, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 320, alignment: message.role == .assistant ? .leading : .trailing)
    }
}

private struct ChatAttachmentRowView: View {
    let attachment: Attachment

    var body: some View {
        Group {
            if let url = URL(string: attachment.downloadUrl.isEmpty ? attachment.url : attachment.downloadUrl) {
                Link(destination: url) { rowContent }
            } else {
                rowContent
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                MarkdownText(attachment.filename)
                    .font(.caption.bold())
                    .lineLimit(1)
                MarkdownText(fileDetails)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var iconName: String {
        if attachment.contentType.hasPrefix("image/") { return "photo" }
        if attachment.contentType == "application/pdf" { return "doc.richtext" }
        return "paperclip"
    }

    private var fileDetails: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(attachment.sizeBytes))
    }
}

private struct ChatLiveTimelineRow: View {
    let pendingTask: ChatPendingTask?
    let timeline: [TimelineItem]
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    MarkdownText(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    MarkdownText(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if timeline.isEmpty {
                    MarkdownText(isLoading ? "Loading agent activity" : "Waiting for agent updates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ChatTimelineView(items: timeline)
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 320, alignment: .leading)
            Spacer(minLength: 32)
        }
        .listRowSeparator(.hidden)
    }

    private var statusText: String {
        if let status = pendingTask?.status, !status.isEmpty {
            switch status {
            case "queued", "pending":
                return "Agent queued"
            case "running", "in_progress":
                return "Agent running"
            default:
                return "Agent \(status.replacingOccurrences(of: "_", with: " "))"
            }
        }
        return "Thinking"
    }
}

private struct ChatTimelineView: View {
    let items: [TimelineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items) { item in
                ChatTimelineItemRow(item: item)
            }
        }
    }
}

private struct ChatTimelineItemRow: View {
    let item: TimelineItem

    var body: some View {
        switch item.type {
        case .text:
            MarkdownText(item.content ?? item.summary)
                .font(.body)
        case .toolUse:
            DisclosureGroup {
                if let input = item.input, !input.isEmpty {
                    TimelinePreformattedBlock(title: "Tool Input", text: formattedJSON(input))
                }
            } label: {
                timelineLabel(icon: "wrench", title: item.tool ?? "Tool Use", subtitle: item.summary)
            }
            .font(.caption)
        case .toolResult:
            DisclosureGroup {
                TimelinePreformattedBlock(title: "Tool Output", text: item.output ?? "")
            } label: {
                timelineLabel(icon: "checkmark.circle", title: item.tool ?? "Result", subtitle: item.summary)
            }
            .font(.caption)
        case .thinking:
            DisclosureGroup {
                TimelinePreformattedBlock(title: "Thinking", text: item.content ?? "")
            } label: {
                timelineLabel(icon: "brain", title: "Thinking", subtitle: item.summary)
            }
            .font(.caption)
        case .error:
            timelineLabel(icon: "exclamationmark.triangle", title: "Error", subtitle: item.summary)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func timelineLabel(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .frame(width: 16)
            MarkdownText(title)
                .font(.caption.weight(.semibold))
            if !subtitle.isEmpty, subtitle != title {
                MarkdownText(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func formattedJSON(_ value: [String: JSONValue]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return value.map { "\($0.key): \($0.value.displayString)" }.joined(separator: "\n") }
        return text
    }
}

private struct TimelinePreformattedBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownText(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: true) {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 4)
    }
}

#endif
