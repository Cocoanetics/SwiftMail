// AttachmentMIMETypeTests.swift
// The Content-Type an attachment declares when the caller does not name one.

import Testing
import Foundation
@testable import SwiftMail

@Suite("Attachment MIME Types", .tags(.core), .timeLimit(.minutes(1)))
struct AttachmentMIMETypeTests {

    /// Write `data` to a temporary file with the given extension and attach it.
    private func attachment(named filename: String, mimeType: String? = nil) throws -> SwiftMail.Attachment {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swiftmail-\(UUID().uuidString)-\(filename)")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try SwiftMail.Attachment(fileURL: url, mimeType: mimeType)
    }

    @Test("Modern Office documents declare their OOXML types")
    func testOOXMLTypes() {
        // These were declared as their pre-2007 equivalents, so a client that
        // trusts Content-Type over the filename could offer to convert a
        // Word 97 document that was never one.
        #expect(SwiftMail.Attachment.mimeType(for: "docx")
                == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(SwiftMail.Attachment.mimeType(for: "xlsx")
                == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        #expect(SwiftMail.Attachment.mimeType(for: "pptx")
                == "application/vnd.openxmlformats-officedocument.presentationml.presentation")
    }

    @Test("Legacy Office documents keep their legacy types")
    func testLegacyOfficeTypes() {
        #expect(SwiftMail.Attachment.mimeType(for: "doc") == "application/msword")
        #expect(SwiftMail.Attachment.mimeType(for: "xls") == "application/vnd.ms-excel")
        #expect(SwiftMail.Attachment.mimeType(for: "ppt") == "application/vnd.ms-powerpoint")
    }

    @Test("Types the old table never listed no longer fall through to octet-stream")
    func testPreviouslyUnlistedTypes() {
        #expect(SwiftMail.Attachment.mimeType(for: "csv") == "text/csv")
        #expect(SwiftMail.Attachment.mimeType(for: "rtf") == "application/rtf")
        #expect(SwiftMail.Attachment.mimeType(for: "json") == "application/json")
        #expect(SwiftMail.Attachment.mimeType(for: "eml") == "message/rfc822")
        #expect(SwiftMail.Attachment.mimeType(for: "ics") == "text/calendar")
        #expect(SwiftMail.Attachment.mimeType(for: "xml") == "application/xml")
    }

    @Test("Pinned types are identical on every platform")
    func testPinnedTypesDoNotVaryByPlatform() {
        // `UTType` is Apple's database on Apple platforms and SwiftCross's own
        // table elsewhere, and they disagree on exactly these. Pinning is what
        // keeps a .rtf attachment from being announced differently depending
        // on the machine that composed the message.
        #expect(SwiftMail.Attachment.mimeType(for: "rtf") == "application/rtf")
        #expect(SwiftMail.Attachment.mimeType(for: "xml") == "application/xml")
        #expect(SwiftMail.Attachment.mimeType(for: "md") == "text/markdown")
    }

    @Test("Markdown is pinned, since one platform's database does not know it")
    func testMarkdown() {
        #expect(SwiftMail.Attachment.mimeType(for: "md") == "text/markdown")
        #expect(SwiftMail.Attachment.mimeType(for: "markdown") == "text/markdown")
    }

    @Test("Every type the old table got right is unchanged")
    func testNoRegressionForPreviouslyCorrectEntries() {
        // The replaced lookup was right about these; swapping the source of
        // the answer must not quietly move any of them.
        let unchanged = [
            "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png",
            "gif": "image/gif", "svg": "image/svg+xml", "pdf": "application/pdf",
            "txt": "text/plain", "html": "text/html", "htm": "text/html",
            "zip": "application/zip"
        ]
        for (pathExtension, expected) in unchanged {
            #expect(SwiftMail.Attachment.mimeType(for: pathExtension) == expected, "\(pathExtension)")
        }
    }

    @Test("An unknown extension is still octet-stream")
    func testUnknownExtension() {
        #expect(SwiftMail.Attachment.mimeType(for: "definitely-not-a-real-extension") == "application/octet-stream")
        #expect(SwiftMail.Attachment.mimeType(for: "") == "application/octet-stream")
    }

    @Test("Extension matching ignores case")
    func testCaseInsensitivity() {
        #expect(SwiftMail.Attachment.mimeType(for: "DOCX")
                == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(SwiftMail.Attachment.mimeType(for: "PDF") == "application/pdf")
        #expect(SwiftMail.Attachment.mimeType(for: "MD") == "text/markdown")
    }

    @Test("Initializing from a file URL derives the type from its extension")
    func testFileURLInitializer() throws {
        let docx = try attachment(named: "report.docx")
        #expect(docx.mimeType == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(docx.filename.hasSuffix("report.docx"))

        let csv = try attachment(named: "codes.csv")
        #expect(csv.mimeType == "text/csv")
    }

    @Test("An explicit mimeType still wins over the derived one")
    func testExplicitMIMETypeOverrides() throws {
        let attachment = try attachment(named: "report.docx", mimeType: "application/octet-stream")
        #expect(attachment.mimeType == "application/octet-stream")
    }
}
