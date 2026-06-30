#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

/// Squad detail / edit screen, mirroring the web squad-detail-page:
/// identity (avatar / name / description), leader, an editable Members list
/// where each member carries a free-text role/description, and Instructions.
public struct SquadDetailView: View {
    @Environment(APIClient.self) private var api
    @Environment(AuthSession.self) private var authSession
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.dismiss) private var dismiss

    private let initialSquad: Squad
    private let onChange: (() -> Void)?

    @State private var viewModel: SquadDetailViewModel?
    @State private var name: String = ""
    @State private var descriptionText: String = ""
    @State private var instructions: String = ""
    @State private var roleDrafts: [String: String] = [:]
    @State private var isShowingAvatarImporter = false
    @State private var showAddMember = false

    public init(squad: Squad, onChange: (() -> Void)? = nil) {
        self.initialSquad = squad
        self.onChange = onChange
    }

    public var body: some View {
        Group {
            if let vm = viewModel {
                Form {
                    identitySection(vm)
                    leaderSection(vm)
                    membersSection(vm)
                    instructionsSection(vm)
                    if let errorMessage = vm.errorMessage {
                        Section {
                            MarkdownText(errorMessage).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                .fileImporter(
                    isPresented: $isShowingAvatarImporter,
                    allowedContentTypes: [.image],
                    allowsMultipleSelection: false
                ) { result in handleAvatarImport(result, vm: vm) }
                .sheet(isPresented: $showAddMember) {
                    AddSquadMemberSheet(viewModel: vm)
                        .presentationDragIndicator(.visible)
                }
                .onChange(of: vm.members) { _, _ in
                    syncDrafts(vm)
                    onChange?()
                }
                .onChange(of: vm.squad) { _, newSquad in
                    name = newSquad.name
                    descriptionText = newSquad.description
                    instructions = newSquad.instructions
                    onChange?()
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(name.isEmpty ? initialSquad.name : name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if viewModel == nil {
                let vm = SquadDetailViewModel(squad: initialSquad, api: api, authSession: authSession)
                viewModel = vm
                name = initialSquad.name
                descriptionText = initialSquad.description
                instructions = initialSquad.instructions
                Task {
                    await vm.load()
                    name = vm.squad.name
                    descriptionText = vm.squad.description
                    instructions = vm.squad.instructions
                    syncDrafts(vm)
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func identitySection(_ vm: SquadDetailViewModel) -> some View {
        Section(AppStrings.localized("Squad", language: appLanguage)) {
            HStack(spacing: 12) {
                AvatarView(name: name.isEmpty ? "?" : name, avatarUrl: vm.squad.avatarUrl, kind: .agent, size: 56)
                Button {
                    isShowingAvatarImporter = true
                } label: {
                    if vm.isMutating {
                        ProgressView()
                    } else {
                        Label(AppStrings.localized("Upload Avatar", language: appLanguage), systemImage: "photo")
                    }
                }
                .disabled(vm.isMutating)
                .accessibilityIdentifier("SquadDetailAvatarUpload")
            }
            TextField(AppStrings.localized("Name", language: appLanguage), text: $name)
                .accessibilityIdentifier("SquadDetailNameField")
                .onSubmit { Task { await vm.updateName(name) } }
            TextField(AppStrings.localized("Description", language: appLanguage), text: $descriptionText, axis: .vertical)
                .lineLimit(1...5)
                .accessibilityIdentifier("SquadDetailDescriptionField")
                .onSubmit { Task { await vm.updateDescription(descriptionText) } }
            if name != vm.squad.name || descriptionText != vm.squad.description {
                Button(AppStrings.localized("Save", language: appLanguage)) {
                    Task {
                        if name != vm.squad.name { await vm.updateName(name) }
                        if descriptionText != vm.squad.description { await vm.updateDescription(descriptionText) }
                    }
                }
                .disabled(vm.isMutating)
            }
        }
    }

    @ViewBuilder
    private func leaderSection(_ vm: SquadDetailViewModel) -> some View {
        let agentMembers = vm.members.filter { $0.memberType == "agent" }
        if !agentMembers.isEmpty {
            Section(AppStrings.localized("Leader", language: appLanguage)) {
                Picker(AppStrings.localized("Leader", language: appLanguage), selection: Binding(
                    get: { vm.squad.leaderId ?? "" },
                    set: { newId in if !newId.isEmpty, newId != vm.squad.leaderId { Task { await vm.setLeader(agentId: newId) } } }
                )) {
                    ForEach(agentMembers, id: \.id) { member in
                        MarkdownText(vm.entityName(type: "agent", id: member.memberId)).tag(member.memberId)
                    }
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("SquadDetailLeaderPicker")
            }
        }
    }

    @ViewBuilder
    private func membersSection(_ vm: SquadDetailViewModel) -> some View {
        Section {
            ForEach(vm.members, id: \.id) { member in
                memberRow(member, vm: vm)
            }
            Button {
                showAddMember = true
            } label: {
                Label(AppStrings.localized("Add Member", language: appLanguage), systemImage: "person.badge.plus")
            }
            .disabled(vm.isMutating)
            .accessibilityIdentifier("SquadDetailAddMember")
        } header: {
            MarkdownText("\(AppStrings.localized("Members", language: appLanguage)) (\(vm.members.count))")
        }
    }

    @ViewBuilder
    private func memberRow(_ member: SquadMember, vm: SquadDetailViewModel) -> some View {
        let status = vm.status(for: member)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AvatarView(
                    name: vm.entityName(type: member.memberType, id: member.memberId),
                    avatarUrl: vm.entityAvatarUrl(type: member.memberType, id: member.memberId),
                    kind: member.memberType == "agent" ? .agent : .user,
                    size: 28,
                    statusDot: member.memberType == "agent" ? vm.presenceByAgentId[member.memberId]?.avatarStatusDot : nil
                )
                MarkdownText(vm.entityName(type: member.memberType, id: member.memberId))
                    .font(.body.weight(.medium))
                if vm.isLeader(member) {
                    MarkdownIconLabel(AppStrings.localized("Leader", language: appLanguage), systemImage: "crown.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if member.memberType == "agent", let label = statusLabel(status?.status) {
                    MarkdownText(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    MarkdownText(member.memberType == "agent" ? "Agent" : AppStrings.localized("Member", language: appLanguage))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // The free-text per-member role / description (web's RoleEditor).
            TextField(
                AppStrings.localized("Role / description", language: appLanguage),
                text: roleBinding(for: member),
                axis: .vertical
            )
            .font(.caption)
            .lineLimit(1...4)
            .accessibilityIdentifier("SquadMemberRole-\(member.id)")
            .onSubmit { commitRole(member, vm: vm) }
            if (roleDrafts[member.id] ?? "") != (member.role) {
                Button(AppStrings.localized("Save", language: appLanguage)) {
                    commitRole(member, vm: vm)
                }
                .font(.caption)
                .disabled(vm.isMutating)
            }
            if let issue = status?.activeIssues.first {
                MarkdownIconLabel("\(issue.identifier) \(issue.title)", systemImage: "smallcircle.filled.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if member.memberType == "agent",
               let last = status?.lastActiveAt,
               (status?.status ?? "") != "working" {
                MarkdownText("\(AppStrings.localized("Last active", language: appLanguage)) \(Self.relativeTime(last))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !vm.isLeader(member) {
                Button(role: .destructive) {
                    Task { await vm.removeMember(member) }
                } label: {
                    Label(AppStrings.localized("Delete", language: appLanguage), systemImage: "trash")
                }
                .disabled(vm.isMutating)
            }
            if member.memberType == "agent" && !vm.isLeader(member) {
                Button {
                    Task { await vm.setLeader(agentId: member.memberId) }
                } label: {
                    Label(AppStrings.localized("Make Leader", language: appLanguage), systemImage: "crown")
                }
                .tint(.orange)
            }
        }
    }

    @ViewBuilder
    private func instructionsSection(_ vm: SquadDetailViewModel) -> some View {
        Section(AppStrings.localized("Instructions", language: appLanguage)) {
            TextField(
                AppStrings.localized("Instructions", language: appLanguage),
                text: $instructions,
                axis: .vertical
            )
            .lineLimit(3...12)
            .accessibilityIdentifier("SquadDetailInstructionsField")
            if instructions != vm.squad.instructions {
                Button(AppStrings.localized("Save", language: appLanguage)) {
                    Task { await vm.updateInstructions(instructions) }
                }
                .disabled(vm.isMutating)
            }
        }
    }

    // MARK: - Helpers

    private func roleBinding(for member: SquadMember) -> Binding<String> {
        Binding(
            get: { roleDrafts[member.id] ?? member.role },
            set: { roleDrafts[member.id] = $0 }
        )
    }

    private func commitRole(_ member: SquadMember, vm: SquadDetailViewModel) {
        let next = roleDrafts[member.id] ?? member.role
        guard next != member.role else { return }
        Task { await vm.updateMemberRole(member, role: next) }
    }

    private func syncDrafts(_ vm: SquadDetailViewModel) {
        var drafts: [String: String] = [:]
        for member in vm.members { drafts[member.id] = member.role }
        roleDrafts = drafts
    }

    private func statusLabel(_ status: String?) -> String? {
        guard let status, !status.isEmpty else { return nil }
        let key: String
        switch status {
        case "working": key = "Working"
        case "idle": key = "Idle"
        case "offline": key = "Offline"
        case "unstable": key = "Unstable"
        case "archived": key = "Archived"
        default: return nil
        }
        return AppStrings.localized(key, language: appLanguage)
    }

    private static func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func handleAvatarImport(_ result: Result<[URL], Error>, vm: SquadDetailViewModel) {
        do {
            guard let url = try result.get().first else { return }
            let payload = try AttachmentImport.payload(from: url)
            Task {
                _ = await vm.uploadAvatarFile(filename: payload.filename, data: payload.data, contentType: payload.contentType)
            }
        } catch {
            vm.errorMessage = error.localizedDescription
        }
    }
}

/// Two-step add-member sheet: pick an agent or workspace member, then an
/// optional role / description. Mirrors the web AddMemberDialog.
private struct AddSquadMemberSheet: View {
    let viewModel: SquadDetailViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage
    @State private var selectedType = "agent"
    @State private var selectedId = ""
    @State private var role = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(AppStrings.localized("Member", language: appLanguage)) {
                    Picker(AppStrings.localized("Member", language: appLanguage), selection: selectionBinding) {
                        Text(AppStrings.localized("Select a member or agent", language: appLanguage)).tag("")
                        let agents = viewModel.availableAgents
                        if !agents.isEmpty {
                            Section("Agents") {
                                ForEach(agents) { agent in
                                    MarkdownText(agent.name).tag("agent:\(agent.id)")
                                }
                            }
                        }
                        let members = viewModel.availableWorkspaceMembers
                        if !members.isEmpty {
                            Section(AppStrings.localized("Members", language: appLanguage)) {
                                ForEach(members) { member in
                                    MarkdownText(member.name).tag("member:\(member.userId)")
                                }
                            }
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("AddSquadMemberPicker")
                }
                Section(AppStrings.localized("Role / description", language: appLanguage)) {
                    TextField(
                        AppStrings.localized("Role / description", language: appLanguage),
                        text: $role,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .accessibilityIdentifier("AddSquadMemberRole")
                }
            }
            .navigationTitle(AppStrings.localized("Add Member", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.localized("Cancel", language: appLanguage)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppStrings.localized("Add", language: appLanguage)) {
                        Task {
                            await viewModel.addMember(type: selectedType, id: selectedId, role: role)
                            dismiss()
                        }
                    }
                    .disabled(selectedId.isEmpty || viewModel.isMutating)
                    .accessibilityIdentifier("AddSquadMemberConfirm")
                }
            }
        }
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { selectedId.isEmpty ? "" : "\(selectedType):\(selectedId)" },
            set: { tag in
                let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    selectedType = parts[0]
                    selectedId = parts[1]
                } else {
                    selectedId = ""
                }
            }
        )
    }
}

#endif
