#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

public struct IssueEditSheet: View {
    public let issue: Issue
    public let onSave: (Issue) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(APIClient.self) private var api
    @Environment(AuthSession.self) private var authSession
    @State private var viewModel: IssueEditViewModel?
    @State private var descriptionMentionQuery: String?
    @State private var descriptionMentionTrigger = MentionTriggerSession()

    public init(issue: Issue, onSave: @escaping (Issue) -> Void) {
        self.issue = issue
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    Form {
                        Section("Issue") {
                            TextField("Title", text: Binding(
                                get: { vm.title },
                                set: { vm.title = $0 }
                            ))
                            .accessibilityIdentifier("IssueEditTitleField")

                            TextEditor(text: Binding(
                                get: { vm.description },
                                set: { vm.description = $0 }
                            ))
                            .frame(minHeight: 120)
                            .accessibilityIdentifier("IssueEditDescriptionEditor")
                            .onChange(of: vm.description) { _, newValue in
                                descriptionMentionQuery = descriptionMentionTrigger.update(
                                    draft: newValue,
                                    candidatesAvailable: !vm.mentionCandidates.isEmpty
                                )
                            }

                            Button {
                                descriptionMentionQuery = ""
                            } label: {
                                Label("Mention", systemImage: "at")
                            }
                            .disabled(vm.mentionCandidates.isEmpty)
                        }

                        Section("Properties") {
                            Picker("Status", selection: Binding(
                                get: { vm.status },
                                set: { vm.status = $0 }
                            )) {
                                ForEach(vm.statusOptions, id: \.self) { status in
                                    MarkdownText(status.displayName).tag(status)
                            }
                        }
                        .pickerStyle(.navigationLink)

                        Picker("Priority", selection: Binding(
                            get: { vm.priority },
                            set: { vm.priority = $0 }
                        )) {
                                ForEach(vm.priorityOptions, id: \.self) { priority in
                                MarkdownText(priority.displayName).tag(priority)
                            }
                        }
                        .pickerStyle(.navigationLink)

                            Picker("Assignee", selection: Binding(
                                get: { vm.selectedAssigneeOptionId },
                                set: { vm.selectedAssigneeOptionId = $0 }
                            )) {
                                Text("Unassigned").tag(IssueEditViewModel.noAssigneeId)
                                ForEach(vm.assigneeOptions) { option in
                                    MarkdownText(option.displayName).tag(option.id)
                                }
                            }
                            .accessibilityIdentifier("IssueEditAssigneePicker")
                            .accessibilityValue(
                                vm.isLoadingOptions
                                    ? "Loading assignees"
                                    : "Assignee options loaded: \(vm.assigneeOptions.count)"
                            )
                            .pickerStyle(.navigationLink)
                            .disabled(vm.isLoadingOptions)

                            Picker("Project", selection: Binding(
                                get: { vm.selectedProjectId },
                                set: { vm.selectedProjectId = $0 }
                            )) {
                                Text("No Project").tag(IssueEditViewModel.noProjectId)
                                ForEach(vm.projects) { project in
                                    MarkdownText(project.name).tag(project.id)
                                }
                        }
                        .disabled(vm.isLoadingOptions)
                        .pickerStyle(.navigationLink)

                            Toggle("Due Date", isOn: Binding(
                                get: { vm.includesDueDate },
                                set: { vm.includesDueDate = $0 }
                            ))

                            if vm.includesDueDate {
                                DatePicker(
                                    "Date",
                                    selection: Binding(get: { vm.dueDate }, set: { vm.dueDate = $0 }),
                                    displayedComponents: .date
                                )
                            }
                        }

                        if !vm.labels.isEmpty {
                            Section("Labels") {
                                ForEach(vm.labels) { label in
                                    Toggle(isOn: Binding(
                                        get: { vm.selectedLabelIds.contains(label.id) },
                                        set: { vm.toggleLabel(label, isSelected: $0) }
                                    )) {
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(Color(hex: label.color) ?? .secondary)
                                                .frame(width: 10, height: 10)
                                            MarkdownText(label.name)
                                        }
                                    }
                                }
                            }
                        }

                        if vm.isLoadingOptions {
                            Section {
                                ProgressView("Loading workspace options")
                            }
                        }

                        if let errorMessage = vm.errorMessage {
                            Section {
                                ErrorRetryView(message: errorMessage) {
                                    Task { await vm.loadOptions() }
                                }
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Edit Issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if viewModel?.isSubmitting == true {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(viewModel?.canSubmit != true)
                    .accessibilityIdentifier("IssueEditSaveButton")
            }
        }
        .sheet(isPresented: Binding(
            get: { descriptionMentionQuery != nil && viewModel?.mentionCandidates.isEmpty == false },
            set: {
                if !$0 {
                    descriptionMentionTrigger.dismissCurrentTrigger()
                    descriptionMentionQuery = nil
                }
            }
        )) {
            if let vm = viewModel {
                MentionCandidatePickerSheet(candidates: vm.mentionCandidates, query: Binding(
                    get: { descriptionMentionQuery ?? "" },
                    set: { descriptionMentionQuery = $0 }
                ), presence: vm.presenceByAgentId) { candidate in
                    IssueDetailViewModel.appendMention(
                        candidate,
                        to: &vm.description,
                        mentions: &vm.descriptionMentions
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
        .task {
                if viewModel == nil {
                    let vm = IssueEditViewModel(issue: issue, api: api, authSession: authSession)
                    viewModel = vm
                    await vm.loadOptions()
                }
            }
        }
    }

    private func submit() async {
        guard let updated = await viewModel?.submit() else { return }
        onSave(updated)
        dismiss()
    }
}
#endif
