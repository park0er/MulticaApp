#if canImport(SwiftUI) && canImport(UIKit)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

public struct IssueCreateSheet: View {
    @Environment(AuthSession.self) private var authSession
    @Environment(APIClient.self) private var api
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void
    let parentIssue: Issue?

    @State private var viewModel: IssueCreateViewModel?

    public init(parentIssue: Issue? = nil, onCreated: @escaping () -> Void) {
        self.parentIssue = parentIssue
        self.onCreated = onCreated
    }

    public var body: some View {
        Group {
            if let viewModel {
                IssueCreateForm(
                    viewModel: viewModel,
                    onCancel: { dismiss() },
                    onCreated: {
                        onCreated()
                        dismiss()
                    }
                )
            } else {
                NavigationStack {
                    ProgressView()
                        .navigationTitle("New Issue")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .task(id: authSession.currentWorkspace?.id) {
            let vm = IssueCreateViewModel(
                api: api,
                authSession: authSession,
                parentIssueId: parentIssue?.id,
                parentIssueIdentifier: parentIssue?.identifier
            )
            viewModel = vm
            await vm.loadOptions()
        }
    }
}

private struct IssueCreateForm: View {
    @Bindable var viewModel: IssueCreateViewModel
    let onCancel: () -> Void
    let onCreated: () -> Void
    @Environment(\.appLanguage) private var appLanguage
    @State private var isShowingAttachmentImporter = false
    @State private var selectedImageItem: PhotosPickerItem?
    @State private var descriptionMentionQuery: String?
    @State private var descriptionMentionTrigger = MentionTriggerSession()

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Issue title", text: $viewModel.title)
                }

                if let parentIssueIdentifier = viewModel.parentIssueIdentifier {
                    Section("Parent Issue") {
                        MarkdownIconLabel(parentIssueIdentifier, systemImage: "arrow.triangle.branch")
                    }
                }

                Section("Description") {
                    TextEditor(text: $viewModel.description)
                        .frame(minHeight: 120)
                        .onChange(of: viewModel.description) { _, newValue in
                            descriptionMentionQuery = descriptionMentionTrigger.update(
                                draft: newValue,
                                candidatesAvailable: !viewModel.mentionCandidates.isEmpty
                            )
                        }
                    Button {
                        descriptionMentionQuery = ""
                    } label: {
                        Label("Mention", systemImage: "at")
                    }
                    .disabled(viewModel.mentionCandidates.isEmpty)
                }

                Section {
                    Picker("Agent", selection: $viewModel.selectedQuickCreateAgentId) {
                        if viewModel.quickCreateAgentOptions.isEmpty {
                            Text("No agents available").tag(String?.none)
                        } else {
                            ForEach(viewModel.quickCreateAgentOptions) { option in
                                MarkdownText(option.displayName).tag(Optional(option.assigneeId))
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .disabled(viewModel.quickCreateAgentOptions.isEmpty || viewModel.isQuickCreating)
                    .accessibilityIdentifier("IssueQuickCreateAgentPicker")

                    TextEditor(text: $viewModel.quickCreatePrompt)
                        .frame(minHeight: 100)
                        .accessibilityIdentifier("IssueQuickCreatePromptEditor")

                    Button {
                        Task {
                            _ = await viewModel.submitQuickCreate()
                        }
                    } label: {
                        if viewModel.isQuickCreating {
                            ProgressView()
                        } else {
                            Label("Send to Agent", systemImage: "paperplane")
                        }
                    }
                    .disabled(!viewModel.canQuickCreate)
                    .accessibilityIdentifier("IssueQuickCreateSendButton")

                    if let message = viewModel.quickCreateSuccessMessage {
                        MarkdownText(message)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("Create with Agent")
                } footer: {
                    MarkdownText("Describe the issue and let the selected agent create it in the background.")
                }

                Section("Details") {
                    Picker("Status", selection: $viewModel.status) {
                        ForEach(viewModel.statusOptions, id: \.self) { status in
                            MarkdownIconLabel(status.displayName, systemImage: status.icon)
                                .tag(status)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("IssueCreateStatusPicker")

                    Picker("Priority", selection: $viewModel.priority) {
                        ForEach(viewModel.priorityOptions, id: \.self) { priority in
                            MarkdownText(priority.displayName).tag(priority)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("IssueCreatePriorityPicker")
                }

                Section("Assignment") {
                    Picker("Assignee", selection: $viewModel.selectedAssigneeOptionId) {
                        Text("Unassigned").tag(IssueCreateViewModel.noAssigneeId)
                        ForEach(viewModel.assigneeOptions) { option in
                            MarkdownText(option.displayName).tag(option.id)
                        }
                    }
                    .accessibilityIdentifier("IssueCreateAssigneePicker")
                    .accessibilityValue(
                        viewModel.isLoadingOptions
                            ? "Loading assignees"
                            : "Assignee options loaded: \(viewModel.assigneeOptions.count)"
                    )
                    .pickerStyle(.navigationLink)
                    .disabled(viewModel.isLoadingOptions)

                    if let assignee = viewModel.selectedAssignee {
                        MarkdownLabeledContent(assignee.subtitle, value: assignee.type.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Project") {
                    Picker("Project", selection: $viewModel.selectedProjectId) {
                        Text("No Project").tag(IssueCreateViewModel.noProjectId)
                        ForEach(viewModel.projects) { project in
                            MarkdownText(project.name).tag(project.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("IssueCreateProjectPicker")
                }

                Section("Due Date") {
                    Toggle("Set Due Date", isOn: $viewModel.includesDueDate)
                    if viewModel.includesDueDate {
                        DatePicker(
                            "Due Date",
                            selection: $viewModel.dueDate,
                            displayedComponents: [.date]
                        )
                    }
                }

                Section("Attachments") {
                    if viewModel.attachments.isEmpty {
                        MarkdownText("No attachments selected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.attachments) { attachment in
                            HStack {
                                Image(systemName: "paperclip")
                                    .foregroundStyle(.secondary)
                                MarkdownText(attachment.filename)
                                Spacer()
                                MarkdownText(ByteCountFormatter.string(fromByteCount: Int64(attachment.sizeBytes), countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        PhotosPicker(
                            selection: $selectedImageItem,
                            matching: .images
                        ) {
                            if viewModel.isUploadingAttachment {
                                ProgressView()
                            } else {
                                Label(AppStrings.localized("Add Image", language: appLanguage), systemImage: "photo")
                            }
                        }
                        .disabled(viewModel.isUploadingAttachment || viewModel.isSubmitting)
                        .accessibilityIdentifier("IssueCreateAddImageButton")

                        Button {
                            isShowingAttachmentImporter = true
                        } label: {
                            if viewModel.isUploadingAttachment {
                                ProgressView()
                            } else {
                                Label(AppStrings.localized("Add Attachment", language: appLanguage), systemImage: "paperclip")
                            }
                        }
                        .disabled(viewModel.isUploadingAttachment || viewModel.isSubmitting)
                        .accessibilityIdentifier("IssueCreateAddAttachmentButton")
                    }
                }

                if viewModel.isLoadingOptions {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading workspace options")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = viewModel.errorMessage {
                    Section {
                        ErrorRetryView(message: error) {
                            Task { await viewModel.loadOptions() }
                        }
                    }
                }
            }
            .navigationTitle("New Issue")
            .navigationBarTitleDisplayMode(.inline)
            .fileImporter(
                isPresented: $isShowingAttachmentImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                handleAttachmentImport(result)
            }
            .onChange(of: selectedImageItem) { _, item in
                handleImageSelection(item)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            guard await viewModel.submit() else { return }
                            onCreated()
                        }
                    } label: {
                        if viewModel.isSubmitting {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(!viewModel.canSubmit)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { descriptionMentionQuery != nil && !viewModel.mentionCandidates.isEmpty },
            set: {
                if !$0 {
                    descriptionMentionTrigger.dismissCurrentTrigger()
                    descriptionMentionQuery = nil
                }
            }
        )) {
            MentionCandidatePickerSheet(candidates: viewModel.mentionCandidates, query: Binding(
                get: { descriptionMentionQuery ?? "" },
                set: { descriptionMentionQuery = $0 }
            ), presence: viewModel.presenceByAgentId) { candidate in
                IssueDetailViewModel.appendMention(
                    candidate,
                    to: &viewModel.description,
                    mentions: &viewModel.descriptionMentions
                )
                descriptionMentionTrigger.reset()
                descriptionMentionQuery = nil
            } onCancel: {
                descriptionMentionTrigger.dismissCurrentTrigger()
                descriptionMentionQuery = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func handleAttachmentImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let payload = try AttachmentImport.payload(from: url)
            Task {
                await viewModel.uploadAttachment(
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
        Task { @MainActor in
            defer { selectedImageItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentImportError.unreadableImage
                }
                let payload = try AttachmentImport.imagePayload(
                    data: data,
                    contentType: item.supportedContentTypes.first { $0.conforms(to: .image) },
                    filenamePrefix: "issue-image"
                )
                await viewModel.uploadAttachment(
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

#endif
