#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

public struct AgentsView: View {
    @Environment(APIClient.self) private var api
    @Environment(AuthSession.self) private var authSession
    @Environment(\.appLanguage) private var appLanguage
    @State private var viewModel: AgentsViewModel?
    @State private var showCreateSheet = false
    @State private var editingAgent: Agent?
    @State private var pendingArchiveAgent: Agent?
    @State private var pendingCancelTasksAgent: Agent?
    @State private var isArchivedAgentsExpanded = false

    public init() {}

    public var body: some View {
        Group {
            if let vm = viewModel {
                List {
                    if vm.isLoading && vm.agents.isEmpty {
                        ProgressView()
                    } else if vm.agents.isEmpty && vm.errorMessage == nil {
                        ContentUnavailableView(
                            AppStrings.localized("No Agents", language: appLanguage),
                            systemImage: "bolt",
                            description: Text(AppStrings.localized("This workspace has no agents yet.", language: appLanguage))
                        )
                    } else {
                        ForEach(vm.activeAgents) { agent in
                            agentNavigationRow(agent: agent, vm: vm)
                        }

                        if !vm.archivedAgents.isEmpty {
                            Section {
                                DisclosureGroup(isExpanded: $isArchivedAgentsExpanded) {
                                    ForEach(vm.archivedAgents) { agent in
                                        agentNavigationRow(agent: agent, vm: vm)
                                    }
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "archivebox")
                                            .foregroundStyle(.secondary)
                                        MarkdownText("Archived Agents")
                                            .font(.body.weight(.semibold))
                                        Spacer()
                                        MarkdownText(vm.archivedAgents.count.formatted())
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .accessibilityIdentifier("ArchivedAgentsDisclosure")
                            }
                        }
                    }

                    if let lastActionMessage = vm.lastActionMessage {
                        Section {
                            MarkdownText(lastActionMessage).font(.caption).foregroundStyle(.secondary)
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
                        Button {
                            showCreateSheet = true
                        } label: {
                            Label(AppStrings.localized("New Agent", language: appLanguage), systemImage: "plus")
                        }
                        .accessibilityIdentifier("AgentsNewButton")
                    }
                }
                .sheet(isPresented: $showCreateSheet) {
                    AgentFormSheet(agent: nil, viewModel: vm)
                        .presentationDragIndicator(.visible)
                }
                .sheet(item: $editingAgent) { agent in
                    AgentFormSheet(agent: agent, viewModel: vm)
                        .presentationDragIndicator(.visible)
                }
                .destructiveConfirmation(
                    DestructiveConfirmation.archiveAgent(name: pendingArchiveAgent?.name ?? ""),
                    isPresented: archiveConfirmationBinding
                ) {
                    guard let agent = pendingArchiveAgent else { return }
                    Task {
                        await vm.archiveAgent(id: agent.id)
                        pendingArchiveAgent = nil
                    }
                } onCancel: {
                    pendingArchiveAgent = nil
                }
                .destructiveConfirmation(
                    DestructiveConfirmation.cancelAgentTasks(name: pendingCancelTasksAgent?.name ?? ""),
                    isPresented: cancelTasksConfirmationBinding
                ) {
                    guard let agent = pendingCancelTasksAgent else { return }
                    Task {
                        _ = await vm.cancelAgentTasks(id: agent.id)
                        pendingCancelTasksAgent = nil
                    }
                } onCancel: {
                    pendingCancelTasksAgent = nil
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(AppStrings.localized("Agents", language: appLanguage))
        .onAppear {
            if viewModel == nil {
                let vm = AgentsViewModel(api: api, authSession: authSession)
                viewModel = vm
                Task { await vm.load() }
            }
        }
        .onChange(of: authSession.currentWorkspace?.id) { _, _ in
            guard let viewModel else { return }
            Task { await viewModel.load() }
        }
    }

    private var archiveConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingArchiveAgent != nil },
            set: { if !$0 { pendingArchiveAgent = nil } }
        )
    }

    private var cancelTasksConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingCancelTasksAgent != nil },
            set: { if !$0 { pendingCancelTasksAgent = nil } }
        )
    }

    private func agentNavigationRow(agent: Agent, vm: AgentsViewModel) -> some View {
        NavigationLink {
            AgentDetailView(agent: agent, listViewModel: vm)
        } label: {
            AgentRow(
                agent: agent,
                presence: vm.presenceByAgentId[agent.id],
                runCount: vm.runCountsByAgentId[agent.id]
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if vm.canManageAgent(agent) {
                if agent.archivedAt == nil {
                    Button(role: .destructive) {
                        pendingArchiveAgent = agent
                    } label: {
                        Label(AppStrings.localized("Archive", language: appLanguage), systemImage: "archivebox")
                    }
                } else {
                    Button {
                        Task { await vm.restoreAgent(id: agent.id) }
                    } label: {
                        Label(AppStrings.localized("Restore", language: appLanguage), systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if vm.canManageAgent(agent) {
                Button {
                    pendingCancelTasksAgent = agent
                } label: {
                    Label(AppStrings.localized("Cancel Tasks", language: appLanguage), systemImage: "xmark.circle")
                }
                .tint(.orange)
            }
        }
    }
}

private struct AgentRow: View {
    let agent: Agent
    let presence: AgentPresenceSummary?
    let runCount: Int?
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentAvatarView(agent: agent, size: 30, presence: presence)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    MarkdownText(agent.name).font(.body.weight(.semibold))
                    if agent.archivedAt != nil {
                        MarkdownText("Archived")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if !agent.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownText(agent.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    MarkdownText(agent.status.capitalized)
                    MarkdownText(agent.visibility.capitalized)
                    if let presence {
                        MarkdownText(presence.displayText(language: appLanguage))
                    }
                    if let runCount {
                        MarkdownText("Runs \(runCount.formatted())")
                    }
                    if let model = agent.model, !model.isEmpty {
                        MarkdownText(model)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AgentDetailView: View {
    let agent: Agent
    let listViewModel: AgentsViewModel

    @Environment(APIClient.self) private var api
    @Environment(AuthSession.self) private var authSession
    @Environment(\.appLanguage) private var appLanguage
    @State private var currentAgent: Agent
    @State private var detailViewModel: AgentDetailViewModel?
    @State private var editingAgent: Agent?

    init(agent: Agent, listViewModel: AgentsViewModel) {
        self.agent = agent
        self.listViewModel = listViewModel
        _currentAgent = State(initialValue: agent)
    }

    var body: some View {
        Group {
            if let vm = detailViewModel {
                List {
                    Section("Agent Detail") {
                        HStack {
                            Spacer()
                            AgentAvatarView(agent: currentAgent, size: 72, presence: listViewModel.presenceByAgentId[currentAgent.id])
                            Spacer()
                        }
                        MarkdownLabeledContent("Name", value: currentAgent.name)
                        if !currentAgent.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MarkdownLabeledContent("Description", value: currentAgent.description)
                        }
                        MarkdownLabeledContent("Status", value: currentAgent.status.capitalized)
                        if let presence = listViewModel.presenceByAgentId[currentAgent.id] {
                            MarkdownLabeledContent("Presence", value: presence.displayText(language: appLanguage))
                        }
                        if let runtimeName = vm.runtimeName {
                            MarkdownLabeledContent("Runtime", value: runtimeName)
                        } else if !currentAgent.runtimeId.isEmpty {
                            MarkdownLabeledContent("Runtime", value: currentAgent.runtimeId)
                        }
                        if let ownerName = vm.ownerName {
                            MarkdownLabeledContent("Owner", value: ownerName)
                        }
                        if let model = currentAgent.model, !model.isEmpty {
                            MarkdownLabeledContent("Model", value: model)
                        }
                        MarkdownLabeledContent("Visibility", value: currentAgent.visibility.capitalized)
                        MarkdownLabeledContent("Max Tasks", value: currentAgent.maxConcurrentTasks.formatted())
                        if let createdAt = currentAgent.createdAt {
                            MarkdownLabeledContent("Created", value: createdAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let updatedAt = currentAgent.updatedAt {
                            MarkdownLabeledContent("Updated", value: updatedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }

                    Section("Activity") {
                        if vm.isLoading && vm.activeTasks.isEmpty {
                            ProgressView()
                        } else if vm.activeTasks.isEmpty {
                            MarkdownText("No active tasks.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(vm.activeTasks.prefix(5)) { task in
                                AgentTaskRow(task: task)
                            }
                        }
                    }

                    Section("Last 30 Days") {
                        if let activityErrorMessage = vm.activityErrorMessage {
                            MarkdownText(activityErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if vm.activitySummary.totalRuns == 0 {
                            MarkdownText("No runs in the last 30 days.")
                                .foregroundStyle(.secondary)
                        } else {
                            MarkdownLabeledContent("Runs", value: vm.activitySummary.totalRuns.formatted())
                            MarkdownLabeledContent("Success", value: "\(vm.activitySummary.successPercent)%")
                            if vm.activitySummary.failedRuns > 0 {
                                MarkdownLabeledContent("Failed", value: vm.activitySummary.failedRuns.formatted())
                            }
                            if let averageDurationSeconds = vm.activitySummary.averageDurationSeconds {
                                MarkdownLabeledContent(
                                    "Average Duration",
                                    value: formatAgentDuration(seconds: averageDurationSeconds)
                                )
                            }
                        }
                    }

                    Section("Recent Work") {
                        if vm.isLoading && vm.recentTasks.isEmpty {
                            ProgressView()
                        } else if vm.recentTasks.isEmpty {
                            MarkdownText("No recent workflow tasks.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(vm.recentTasks.prefix(10)) { task in
                                AgentTaskRow(task: task)
                            }
                        }
                    }

                    Section("Instructions") {
                        if currentAgent.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            MarkdownText("No instructions configured.")
                                .foregroundStyle(.secondary)
                        } else {
                            MarkdownText(currentAgent.instructions)
                        }
                    }

                    Section("Skills") {
                        if currentAgent.skills.isEmpty {
                            MarkdownText("No skills attached.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(currentAgent.skills) { skill in
                                VStack(alignment: .leading, spacing: 2) {
                                    MarkdownText(skill.name)
                                    if !skill.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        MarkdownText(skill.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    Section("Environment") {
                        if currentAgent.customEnvRedacted {
                            MarkdownText("Environment values are redacted.")
                                .foregroundStyle(.secondary)
                        } else if currentAgent.customEnv.isEmpty {
                            MarkdownText("No custom environment variables.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(currentAgent.customEnv.keys.sorted(), id: \.self) { key in
                                MarkdownLabeledContent(key, value: currentAgent.customEnv[key]?.displayString ?? "")
                            }
                        }
                    }

                    Section("Custom Args") {
                        if currentAgent.customArgs.isEmpty {
                            MarkdownText("No custom arguments.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(currentAgent.customArgs, id: \.self) { arg in
                                MarkdownText(arg)
                                    .font(.system(.body, design: .monospaced))
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
                .refreshable { await vm.load() }
            } else {
                ProgressView()
            }
        }
        .markdownNavigationTitle(currentAgent.name)
        .toolbar {
            if listViewModel.canManageAgent(currentAgent) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editingAgent = currentAgent
                    } label: {
                        Label("Edit Agent", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("AgentDetailEditButton")
                }
            }
        }
        .sheet(item: $editingAgent) { agent in
            AgentFormSheet(agent: agent, viewModel: listViewModel) { updated in
                currentAgent = updated
                detailViewModel = AgentDetailViewModel(agent: updated, api: api, authSession: authSession)
                Task { await detailViewModel?.load() }
            }
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            if detailViewModel == nil {
                let vm = AgentDetailViewModel(agent: currentAgent, api: api, authSession: authSession)
                detailViewModel = vm
                Task { await vm.load() }
            }
        }
    }
}

private struct AgentAvatarView: View {
    let agent: Agent
    let size: CGFloat
    var presence: AgentPresenceSummary? = nil

    var body: some View {
        AvatarView(
            name: agent.name,
            avatarUrl: agent.avatarUrl,
            kind: .agent,
            size: size,
            statusDot: agent.archivedAt == nil ? presence?.avatarStatusDot : nil
        )
    }
}

private struct AgentTaskRow: View {
    let task: AgentTask

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                MarkdownText(task.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.body.weight(.medium))
                Spacer()
                if let completedAt = task.completedAt {
                    MarkdownText(completedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let startedAt = task.startedAt {
                    MarkdownText(startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !task.issueId.isEmpty {
                MarkdownText(task.issueId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = task.error, !error.isEmpty {
                MarkdownText(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

private func formatAgentDuration(seconds: Int) -> String {
    if seconds < 60 {
        return "\(max(1, seconds))s"
    }
    if seconds < 3600 {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return "\(minutes)m \(String(format: "%02d", remainder))s"
    }
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    return "\(hours)h \(minutes)m"
}

private struct AgentFormSheet: View {
    let agent: Agent?
    let viewModel: AgentsViewModel
    var onSave: ((Agent) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var instructions: String
    @State private var runtimeId: String
    @State private var visibility: String
    @State private var maxConcurrentTasks: Int
    @State private var model: String
    @State private var avatarUrl: String
    @State private var customEnvText: String
    @State private var customArgsText: String
    @State private var selectedSkillIds: Set<String>
    @State private var isLoadingSkills = false
    @State private var isShowingAvatarImporter = false
    @State private var validationError: String?

    init(agent: Agent?, viewModel: AgentsViewModel, onSave: ((Agent) -> Void)? = nil) {
        self.agent = agent
        self.viewModel = viewModel
        self.onSave = onSave
        _name = State(initialValue: agent?.name ?? "")
        _description = State(initialValue: agent?.description ?? "")
        _instructions = State(initialValue: agent?.instructions ?? "")
        _runtimeId = State(initialValue: agent?.runtimeId ?? viewModel.runtimes.first?.id ?? "")
        _visibility = State(initialValue: agent?.visibility ?? "workspace")
        _maxConcurrentTasks = State(initialValue: agent?.maxConcurrentTasks ?? 1)
        _model = State(initialValue: agent?.model ?? "gpt")
        _avatarUrl = State(initialValue: agent?.avatarUrl ?? "")
        _customEnvText = State(initialValue: AgentFormDraft.environmentText(from: agent?.customEnv ?? [:]))
        _customArgsText = State(initialValue: AgentFormDraft.argsText(from: agent?.customArgs ?? []))
        _selectedSkillIds = State(initialValue: agent.flatMap { viewModel.assignedSkillIdsByAgentId[$0.id] } ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("AgentNameField")
                    TextField("Model", text: $model)
                    TextField("Avatar URL", text: $avatarUrl)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityIdentifier("AgentAvatarURLField")
                    Button {
                        isShowingAvatarImporter = true
                    } label: {
                        if viewModel.isMutating {
                            ProgressView()
                        } else {
                            Label("Upload Avatar", systemImage: "photo")
                        }
                    }
                    .disabled(viewModel.isMutating)
                    .accessibilityIdentifier("AgentAvatarUploadButton")
                    TextEditor(text: $description)
                        .frame(minHeight: 80)
                        .accessibilityIdentifier("AgentDescriptionEditor")
                    TextEditor(text: $instructions)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("AgentInstructionsEditor")
                }

                Section("Runtime") {
                    if !viewModel.runtimes.isEmpty {
                        Picker("Runtime", selection: $runtimeId) {
                            ForEach(viewModel.runtimes) { runtime in
                                MarkdownText("\(runtime.name) (\(runtime.status))").tag(runtime.id)
                            }
                        }
                    } else {
                        MarkdownLabeledContent("Runtime", value: agent?.runtimeId ?? "")
                    }

                    Picker("Visibility", selection: $visibility) {
                        Text("Workspace").tag("workspace")
                        Text("Private").tag("private")
                    }

                    Stepper("Max Tasks: \(maxConcurrentTasks)", value: $maxConcurrentTasks, in: 1...20)
                }

                Section("Environment") {
                    if agent?.customEnvRedacted == true {
                        MarkdownText("Existing values are redacted. Leave this empty to keep them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    TextEditor(text: $customEnvText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .accessibilityIdentifier("AgentCustomEnvEditor")
                }

                Section("Custom Args") {
                    TextEditor(text: $customArgsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .accessibilityIdentifier("AgentCustomArgsEditor")
                }

                Section("Skills") {
                    if isLoadingSkills {
                        ProgressView()
                    } else if viewModel.skills.isEmpty {
                        MarkdownText("No skills in this workspace.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.skills) { skill in
                            Toggle(isOn: skillSelectionBinding(for: skill.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    MarkdownText(skill.name)
                                    if !skill.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        MarkdownText(skill.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if let validationError {
                    Section {
                        MarkdownText(validationError).font(.caption).foregroundStyle(.red)
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        MarkdownText(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(agent == nil ? "New Agent" : "Edit Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if viewModel.isMutating {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("AgentSaveButton")
                }
            }
        }
        .task { await loadSkills() }
        .fileImporter(
            isPresented: $isShowingAvatarImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleAvatarImport(result)
        }
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (agent != nil || !runtimeId.isEmpty) &&
        !viewModel.isMutating
    }

    private func submit() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAvatarUrl = avatarUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCustomEnvText = customEnvText.trimmingCharacters(in: .whitespacesAndNewlines)
        let customEnv: [String: String]?
        let customArgs = AgentFormDraft.parseCustomArgs(customArgsText)

        do {
            if agent?.customEnvRedacted == true && trimmedCustomEnvText.isEmpty {
                customEnv = nil
            } else {
                customEnv = try AgentFormDraft.parseCustomEnvironment(customEnvText)
            }
            validationError = nil
        } catch {
            validationError = error.localizedDescription
            return
        }

        let saved: Agent?
        if let agent {
            saved = await viewModel.updateAgent(
                id: agent.id,
                name: trimmedName,
                description: trimmedDescription,
                instructions: trimmedInstructions,
                runtimeId: runtimeId,
                visibility: visibility,
                maxConcurrentTasks: maxConcurrentTasks,
                model: trimmedModel,
                avatarUrl: trimmedAvatarUrl.isEmpty ? nil : trimmedAvatarUrl,
                customEnv: customEnv,
                customArgs: customArgs,
                skillIds: selectedSkillIds
            )
        } else {
            saved = await viewModel.createAgent(
                name: trimmedName,
                description: trimmedDescription,
                instructions: trimmedInstructions,
                runtimeId: runtimeId,
                visibility: visibility,
                maxConcurrentTasks: maxConcurrentTasks,
                model: trimmedModel,
                avatarUrl: trimmedAvatarUrl.isEmpty ? nil : trimmedAvatarUrl,
                customEnv: customEnv,
                customArgs: customArgs,
                skillIds: selectedSkillIds
            )
        }

        if saved != nil {
            if let saved {
                onSave?(saved)
            }
            dismiss()
        }
    }

    private func loadSkills() async {
        guard !isLoadingSkills else { return }
        isLoadingSkills = true
        defer { isLoadingSkills = false }
        await viewModel.loadSkillOptions(for: agent?.id)
        if let agent {
            selectedSkillIds = viewModel.assignedSkillIdsByAgentId[agent.id] ?? []
        }
    }

    private func handleAvatarImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let payload = try AttachmentImport.payload(from: url)
            Task {
                if let agent {
                    if let updated = await viewModel.uploadAvatar(
                        for: agent,
                        filename: payload.filename,
                        data: payload.data,
                        contentType: payload.contentType
                    ) {
                        avatarUrl = updated.avatarUrl ?? ""
                    }
                } else if let uploadedUrl = await viewModel.uploadAvatarFile(
                    filename: payload.filename,
                    data: payload.data,
                    contentType: payload.contentType
                ) {
                    avatarUrl = uploadedUrl
                }
            }
        } catch {
            validationError = error.localizedDescription
        }
    }

    private func skillSelectionBinding(for skillId: String) -> Binding<Bool> {
        Binding(
            get: { selectedSkillIds.contains(skillId) },
            set: { isSelected in
                if isSelected {
                    selectedSkillIds.insert(skillId)
                } else {
                    selectedSkillIds.remove(skillId)
                }
            }
        )
    }
}
#endif
