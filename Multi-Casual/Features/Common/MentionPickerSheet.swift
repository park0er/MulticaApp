#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct MentionCandidatePickerSheet: View {
    let candidates: [MentionCandidate]
    @Binding var query: String
    var presence: [String: AgentPresenceSummary] = [:]
    let onSelect: (MentionCandidate) -> Void
    var onCancel: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage

    private var filteredCandidates: [MentionCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed) ||
            $0.subtitle.localizedCaseInsensitiveContains(trimmed) ||
            $0.type.displayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField(AppStrings.localized("Search", language: appLanguage), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .padding()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredCandidates) { candidate in
                            mentionCandidateButton(candidate)
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
            .navigationTitle(AppStrings.localized("Mention", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.localized("Cancel", language: appLanguage)) {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
    }

    private func mentionCandidateButton(_ candidate: MentionCandidate) -> some View {
        Button {
            onSelect(candidate)
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: candidate.displayName, avatarUrl: candidate.avatarUrl, kind: avatarKind(for: candidate), size: 32, statusDot: statusDot(for: candidate))
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.displayName)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(candidate.type.displayName)
                            .font(.caption2.weight(.bold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(typeColor(candidate.type).opacity(0.15), in: Capsule())
                            .foregroundStyle(typeColor(candidate.type))
                        Text(candidate.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    private func statusDot(for candidate: MentionCandidate) -> AvatarView.StatusDot? {
        guard candidate.type == .agent else { return nil }
        return presence[candidate.entityId]?.avatarStatusDot
    }


    private func avatarKind(for candidate: MentionCandidate) -> AvatarView.Kind {
        switch candidate.type {
        case .person: .user
        case .agent: .agent
        case .squad: .user
        }
    }

    private func typeColor(_ type: MentionEntityType) -> Color {
        switch type {
        case .person: .blue
        case .agent: .purple
        case .squad: .orange
        }
    }
}
#endif
