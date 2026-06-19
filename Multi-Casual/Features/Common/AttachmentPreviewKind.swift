import Foundation

public enum AttachmentPreviewKind: Equatable, Sendable {
    case image
    case pdf
    case video
    case audio
    case markdown
    case html
    case text(language: String?)
    case unsupported

    public init(contentType: String, filename: String) {
        let normalizedContentType = Self.normalizeContentType(contentType)
        let ext = Self.fileExtension(filename)

        if normalizedContentType == "application/pdf" || ext == "pdf" {
            self = .pdf
        } else if normalizedContentType.hasPrefix("video/") || Self.videoExtensions.contains(ext) {
            self = .video
        } else if normalizedContentType.hasPrefix("audio/") || Self.audioExtensions.contains(ext) {
            self = .audio
        } else if normalizedContentType.hasPrefix("image/") || Self.imageExtensions.contains(ext) {
            self = .image
        } else if normalizedContentType == "text/markdown" || ext == "md" || ext == "markdown" {
            self = .markdown
        } else if normalizedContentType == "text/html" || ext == "html" || ext == "htm" {
            self = .html
        } else if Self.isTextLike(contentType: normalizedContentType, filename: filename, ext: ext) {
            self = .text(language: Self.language(for: filename, contentType: normalizedContentType))
        } else {
            self = .unsupported
        }
    }

    public var isInlinePreviewable: Bool {
        switch self {
        case .markdown, .html, .text:
            return true
        case .image, .pdf, .video, .audio, .unsupported:
            return false
        }
    }

    private static let textContentTypes: Set<String> = [
        "application/json",
        "application/javascript",
        "application/xml",
        "application/x-yaml",
        "application/yaml",
        "application/toml",
        "application/x-sh",
        "application/x-httpd-php",
    ]

    private static let textExtensions: Set<String> = [
        "md", "markdown", "txt", "log", "csv", "tsv",
        "html", "htm", "json", "xml",
        "yml", "yaml", "toml", "ini", "conf",
        "sh", "bash", "zsh",
        "py", "rb", "go", "rs",
        "ts", "tsx", "js", "jsx", "mjs", "cjs",
        "css", "scss", "sass", "less",
        "sql",
        "java", "kt", "swift",
        "c", "cc", "cpp", "h", "hpp",
        "cs", "php", "lua", "vim",
    ]

    private static let textBasenames: Set<String> = ["dockerfile", "makefile"]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "ogv"]
    private static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "ogg", "oga", "flac", "aac", "opus"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico", "svg"]

    private static let extensionLanguageMap: [String: String] = [
        "md": "markdown", "markdown": "markdown",
        "txt": "plaintext", "log": "plaintext",
        "html": "xml", "htm": "xml", "xml": "xml", "svg": "xml",
        "css": "css", "scss": "scss", "sass": "sass", "less": "less",
        "json": "json", "yml": "yaml", "yaml": "yaml", "toml": "ini", "ini": "ini", "conf": "ini",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "py": "python", "rb": "ruby", "go": "go", "rs": "rust",
        "ts": "typescript", "tsx": "typescript", "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "java": "java", "kt": "kotlin", "swift": "swift",
        "c": "c", "cc": "cpp", "cpp": "cpp", "h": "c", "hpp": "cpp",
        "cs": "csharp", "php": "php", "lua": "lua", "vim": "vim", "sql": "sql",
        "csv": "plaintext", "tsv": "plaintext",
    ]

    private static let basenameLanguageMap: [String: String] = [
        "dockerfile": "dockerfile",
        "makefile": "makefile",
    ]

    private static let contentTypeLanguageMap: [String: String] = [
        "application/json": "json",
        "application/javascript": "javascript",
        "application/xml": "xml",
        "application/x-yaml": "yaml",
        "application/yaml": "yaml",
        "application/toml": "ini",
        "application/x-sh": "bash",
        "application/x-httpd-php": "php",
    ]

    private static func normalizeContentType(_ contentType: String) -> String {
        let trimmed = contentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let semi = trimmed.firstIndex(of: ";") {
            return String(trimmed[..<semi]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func fileExtension(_ filename: String) -> String {
        let base = basename(filename)
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
        return String(base[base.index(after: dot)...])
    }

    private static func basename(_ filename: String) -> String {
        filename
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? ""
    }

    private static func isTextLike(contentType: String, filename: String, ext: String) -> Bool {
        if contentType.hasPrefix("text/") { return true }
        if textContentTypes.contains(contentType) { return true }
        if textExtensions.contains(ext) { return true }
        return textBasenames.contains(basename(filename))
    }

    private static func language(for filename: String, contentType: String) -> String? {
        let ext = fileExtension(filename)
        if let language = extensionLanguageMap[ext] { return language }
        if let language = contentTypeLanguageMap[contentType] { return language }
        return basenameLanguageMap[basename(filename)]
    }
}
