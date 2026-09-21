// MSGCorpusTests.swift
// Parses every `.msg` in a directory named by SWIFTMAIL_MSG_CORPUS.
//
// Real Outlook output is the only way to know the parser handles what Outlook
// actually writes, and those files are usually someone's mail, so none ship
// with the repository. Point the variable at a directory of `.msg` files and
// these run; leave it unset and they skip.
//
//   SWIFTMAIL_MSG_CORPUS=/path/to/messages swift test --filter MSGCorpusTests

import Testing
import Foundation
@testable import SwiftMail

@Suite("MSG Corpus", .tags(.mime), .timeLimit(.minutes(5)))
struct MSGCorpusTests {

    static var corpusDirectory: String? {
        ProcessInfo.processInfo.environment["SWIFTMAIL_MSG_CORPUS"]
    }

    static var messageFiles: [URL] {
        guard let corpusDirectory else { return [] }
        let root = URL(fileURLWithPath: corpusDirectory)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "msg" }
            .sorted { $0.path < $1.path }
    }

    @Test("Every file in the corpus parses into a usable message",
          .enabled(if: MSGCorpusTests.corpusDirectory != nil))
    func testCorpusParses() throws {
        let files = Self.messageFiles
        try #require(!files.isEmpty, "SWIFTMAIL_MSG_CORPUS names no .msg files")

        for file in files {
            let message = try MSGParser.parse(try Data(contentsOf: file))
            let label = file.lastPathComponent

            // An envelope a client could show.
            #expect(message.subject?.isEmpty == false, "no subject in \(label)")
            #expect(message.from?.isEmpty == false, "no sender in \(label)")
            #expect(message.date != nil, "no date in \(label)")
            #expect(!message.to.isEmpty, "no recipients in \(label)")

            // A body in at least one representation.
            #expect(!message.bodies.isEmpty, "no body parts in \(label)")

            // Sections are unique, so a consumer addressing "2.1" gets one part.
            let sections = message.parts.map(\.section.description)
            #expect(Set(sections).count == sections.count, "duplicate section numbers in \(label)")

            // Every part that claims bytes has them.
            for part in message.parts where part.contentType != "message/rfc822" {
                #expect(part.data != nil, "part \(part.section) of \(label) has no data")
            }
        }
    }

    @Test("A recovered HTML body is well-formed HTML, not RTF",
          .enabled(if: MSGCorpusTests.corpusDirectory != nil))
    func testCorpusHTMLRecovery() throws {
        for file in Self.messageFiles {
            let message = try MSGParser.parse(try Data(contentsOf: file))
            guard let html = message.htmlBody else { continue }
            let label = file.lastPathComponent

            #expect(html.lowercased().contains("<html"), "no <html> in recovered body of \(label)")
            #expect(html.lowercased().contains("</html>"), "unterminated recovered body of \(label)")
            // The give-away that de-encapsulation was skipped or half-done.
            #expect(!html.contains("\\htmlrtf"), "RTF control words leaked into \(label)")
            #expect(!html.contains("{\\rtf1"), "RTF header leaked into \(label)")
            #expect(!html.contains("\\fonttbl"), "font table leaked into \(label)")
        }
    }
}
