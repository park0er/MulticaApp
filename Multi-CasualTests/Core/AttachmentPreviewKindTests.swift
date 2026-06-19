import XCTest
@testable import MultiCasual

final class AttachmentPreviewKindTests: XCTestCase {
    func test_detectsMediaBeforeTextLikeTypes() {
        XCTAssertEqual(AttachmentPreviewKind(contentType: "application/pdf", filename: "brief"), .pdf)
        XCTAssertEqual(AttachmentPreviewKind(contentType: "video/mp4", filename: "clip"), .video)
        XCTAssertEqual(AttachmentPreviewKind(contentType: "audio/mpeg", filename: "voice"), .audio)
        XCTAssertEqual(AttachmentPreviewKind(contentType: "image/svg+xml", filename: "diagram.svg"), .image)
    }

    func test_detectsMarkdownAndHTMLByContentTypeOrExtension() {
        XCTAssertEqual(AttachmentPreviewKind(contentType: "text/markdown", filename: "notes.txt"), .markdown)
        XCTAssertEqual(AttachmentPreviewKind(contentType: "text/plain", filename: "plan.md"), .markdown)
        XCTAssertEqual(AttachmentPreviewKind(contentType: "text/html; charset=utf-8", filename: "report.txt"), .html)
        XCTAssertEqual(AttachmentPreviewKind(contentType: "text/plain", filename: "report.htm"), .html)
    }

    func test_detectsTextLikeFilesWithLanguages() {
        XCTAssertEqual(AttachmentPreviewKind(contentType: "application/json", filename: "payload.bin"), .text(language: "json"))
        XCTAssertEqual(AttachmentPreviewKind(contentType: "text/plain", filename: "model.swift"), .text(language: "swift"))
        XCTAssertEqual(AttachmentPreviewKind(contentType: "application/xml", filename: "feed.xml"), .text(language: "xml"))
        XCTAssertEqual(AttachmentPreviewKind(contentType: "", filename: "Dockerfile"), .text(language: "dockerfile"))
        XCTAssertEqual(AttachmentPreviewKind(contentType: "application/octet-stream", filename: "archive.zip"), .unsupported)
    }
}
