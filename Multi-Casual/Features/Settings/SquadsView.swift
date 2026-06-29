#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

public struct SquadsView: View {
    @Environment(APIClient.self) private var api
    @Environment(AuthSession.self) private var authSession
    @Environment(\.appLanguage) private var appLanguage
    @State private var viewModel: SquadsViewModel?
    @State private var showCreateSheet = false
    @State private var editingSquad: Squad?

    public init() {}

    public var body: some View {
        Group {
            if let vm = viewModel {
                List {
                    if vm.isLoading && vm.squads.isEmpty {
                        ProgressView()
                    } else if vm.squads.isEmpty && vm.errorMessage == nil {
                        ContentUnavailableView(
                            AppStrings.localized("No Squads", language: appLanguage),
                            systemImage: "person.3",
                            description: Text(AppStrings.localized("This workspace has no squads yet.", language: appLanguage))
                        )
                    } else {
                        ForEach(vm.squads) { squad in
                            Button {
                                editingSquad = squad
                            } label: {
                                SquadRow(squad: squad, leaderName: vm.leaderName(for: squad))
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await vm.deleteSquad(id: squad.id) }
                                } label: {
                                    Label(AppStrings.localized("Delete", language: appLanguage), systemImage: "trash")
                                }
                                .disabled(vm.isMutating)
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
                        Button {
                            showCreateSheet = true
                        } label: {
                            Label(AppStrings.localized("New Squad", language: appLanguage), systemImage: "plus")
                        }
                        .accessibilityIdentifier("SquadsNewButton")
                    }
                }
                .sheet(isPresented: $showCreateSheet) {
                    SquadFormSheet(squad: nil, viewModel: vm)
                        .presentationDragIndicator(.visible)
                }
                .sheet(item: $editingSquad) { squad in
                    SquadFormSheet(squad: squad, viewModel: vm)
                        .presentationDragIndicator(.visible)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(AppStrings.localized("Squads", language: appLanguage))
        .onAppear {
            if viewModel == nil {
                let vm = SquadsViewModel(api: api, authSession: authSession)
                viewModel = vm
                Task { await vm.load() }
            }
        }
        .onChange(of: authSession.currentWorkspace?.id) { _, _ in
            Task { await viewModel?.load() }
        }
    }
}

private struct SquadRow: View {
    let squad: Squad
    let leaderName: String?

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(name: squad.name, avatarUrl: squad.avatarUrl, kind: .agent, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                MarkdownText(squad.name)
                    .font(.body.weight(.semibold))
                if let leaderName {
                    MarkdownIconLabel(leaderName, systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !squad.description.isEmpty {
                    MarkdownText(squad.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct SquadFormSheet: View {
    let squad: Squad?
    let viewModel: SquadsViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage
    @State private var name: String
    @State private var description: String
    @State private var instructions: String
    @State private var leaderId: String

    init(squad: Squad?, viewModel: SquadsViewModel) {
        self.squad = squad
        self.viewModel = viewModel
        _name = State(initialValue: squad?.name ?? "")
        _description = State(initialValue: squad?.description ?? "")
        _instructions = State(initialValue: squad?.instructions ?? "")
        _leaderId = State(initialValue: squad?.leaderId ?? "")
    }

    private var isEditing: Bool { squad != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section(AppStrings.localized("Squad", language: appLanguage)) {
                    TextField(AppStrings.localized("Name", language: appLanguage), text: $name)
                        .accessibilityIdentifier("SquadNameField")
                    TextField(AppStrings.localized("Description", language: appLanguage), text: $description, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("SquadDescriptionField")
                }

                Section(AppStrings.localized("Leader", language: appLanguage)) {
                    if viewModel.agents.isEmpty {
                        MarkdownText(AppStrings.localized("No agents available. Create an agent first.", language: appLanguage))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(AppStrings.localized("Leader", language: appLanguage), selection: $leaderId) {
                            Text(AppStrings.localized("Select a leader", language: appLanguage)).tag("")
                            ForEach(viewModel.agents) { agent in
                                MarkdownText(agent.name).tag(agent.id)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .accessibilityIdentifier("SquadLeaderPicker")
                    }
                }

                if isEditing {
                    Section(AppStrings.localized("Instructions", language: appLanguage)) {
                        TextField(
                            AppStrings.localized("Instructions", language: appLanguage),
                            text: $instructions,
                            axis: .vertical
                        )
                        .lineLimit(3...10)
                        .accessibilityIdentifier("SquadInstructionsField")
                    }
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        MarkdownText(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isEditing
                ? AppStrings.localized("Edit Squad", language: appLanguage)
                : AppStrings.localized("New Squad", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.localized("Cancel", language: appLanguage)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if viewModel.isMutating {
                            ProgressView()
                        } else {
                            Text(AppStrings.localized("Save", language: appLanguage))
                        }
                    }
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("SquadSaveButton")
                }
            }
        }
    }

    private var canSubmit: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !viewModel.isMutating else {
            return false
        }
        // Creating requires a leader; editing can keep the existing leader.
        if isEditing { return true }
        return !leaderId.isEmpty
    }

    private func submit() async {
        let saved: Squad?
        if let squad {
            saved = await viewModel.updateSquad(
                id: squad.id,
                name: name,
                description: description,
                instructions: instructions,
                leaderId: leaderId.isEmpty ? nil : leaderId
            )
        } else {
            saved = await viewModel.createSquad(
                name: name,
                description: description,
                leaderId: leaderId,
                avatarUrl: nil
            )
        }

        if saved != nil {
            dismiss()
        }
    }
}

#endif
