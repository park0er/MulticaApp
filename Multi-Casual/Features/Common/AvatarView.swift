#if canImport(SwiftUI)
import SwiftUI

public enum AvatarURLResolver {
    public static func url(from rawValue: String?, baseURL: URL = AppEnvironment.current.apiBaseURL) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }
        if trimmed.hasPrefix("//"), let scheme = baseURL.scheme {
            return URL(string: "\(scheme):\(trimmed)")
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }
}

public struct AvatarView: View {
    public enum Kind {
        case user
        case agent
    }

    /// Small presence dot rendered at the avatar's bottom-trailing corner,
    /// mirroring the web ActorAvatar `showStatusDot`. Semantic cases keep the
    /// color mapping centralized so every call site reads identically.
    public enum StatusDot: Sendable {
        case working   // actively running a task
        case online    // reachable but idle
        case idle      // no presence signal but registered
        case unstable  // runtime recently lost
        case offline   // runtime offline / missing

        public var color: Color {
            switch self {
            case .working: return .green
            case .online: return Color.green.opacity(0.5)
            case .idle: return Color.secondary.opacity(0.5)
            case .unstable: return .orange
            case .offline: return Color.secondary.opacity(0.5)
            }
        }
    }

    private let name: String
    private let avatarUrl: String?
    private let kind: Kind
    private let size: CGFloat
    private let statusDot: StatusDot?

    public init(name: String, avatarUrl: String?, kind: Kind = .user, size: CGFloat, statusDot: StatusDot? = nil) {
        self.name = name
        self.avatarUrl = avatarUrl
        self.kind = kind
        self.size = size
        self.statusDot = statusDot
    }

    public var body: some View {
        Group {
            if let url = AvatarURLResolver.url(from: avatarUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(8, size * 0.26), style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if let statusDot {
                let dot = max(7, size * 0.3)
                Circle()
                    .fill(statusDot.color)
                    .frame(width: dot, height: dot)
                    .overlay(Circle().stroke(Self.dotRingColor, lineWidth: max(1.5, dot * 0.18)))
                    .offset(x: dot * 0.2, y: dot * 0.2)
            }
        }
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(8, size * 0.26), style: .continuous)
                .fill(kind == .agent ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.14))
            if let initials {
                Text(initials)
                    .font(.system(size: max(11, size * 0.38), weight: .semibold))
                    .foregroundStyle(kind == .agent ? Color.accentColor : Color.secondary)
            } else {
                Image(systemName: kind == .agent ? "bolt.fill" : "person.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(kind == .agent ? Color.accentColor : Color.secondary)
            }
        }
    }

    private static var dotRingColor: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.white
        #endif
    }

    private var initials: String? {
        let parts = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "@" || $0 == "." })
            .prefix(2)
            .compactMap(\.first)
        guard !parts.isEmpty else { return nil }
        return String(parts).uppercased()
    }
}

public extension AgentPresenceSummary {
    /// Maps the derived presence to the avatar's status-dot semantics, matching
    /// the web ActorAvatar dot: offline/unstable take precedence over workload,
    /// an online agent running work shows green, online-but-idle shows a dim dot.
    var avatarStatusDot: AvatarView.StatusDot {
        switch availability {
        case .offline: return .offline
        case .unstable: return .unstable
        case .online: return workload == .idle ? .online : .working
        }
    }
}
#endif
