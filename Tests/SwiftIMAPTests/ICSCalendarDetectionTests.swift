import Foundation
import Testing
@testable import SwiftMail
import NIOIMAPCore
import NIO

/// Tests for ICS/text/calendar detection, body filtering, and suggestedFilename.
struct ICSCalendarDetectionTests {

    // MARK: - Helpers

    private func emptyFields() -> BodyStructure.Fields {
        BodyStructure.Fields(parameters: [:], id: nil, contentDescription: nil, encoding: nil, octetCount: 0)
    }

    // MARK: - Bodies filter tests

    @Test
    func bodiesExcludesTextCalendar() {
        let header = MessageInfo(sequenceNumber: SequenceNumber(1))
        let plainPart = MessagePart(section: Section([1]), contentType: "text/plain")
        let htmlPart = MessagePart(section: Section([2]), contentType: "text/html")
        let calendarPart = MessagePart(section: Section([3]), contentType: "text/calendar; method=REQUEST")
        let message = Message(header: header, parts: [plainPart, htmlPart, calendarPart])

        let bodies = message.bodies
        #expect(bodies.count == 2)
        #expect(bodies[0].contentType == "text/plain")
        #expect(bodies[1].contentType == "text/html")
    }

    @Test
    func bodiesExcludesTextCSV() {
        let header = MessageInfo(sequenceNumber: SequenceNumber(1))
        let plainPart = MessagePart(section: Section([1]), contentType: "text/plain")
        let csvPart = MessagePart(section: Section([2]), contentType: "text/csv")
        let message = Message(header: header, parts: [plainPart, csvPart])

        let bodies = message.bodies
        #expect(bodies.count == 1)
        #expect(bodies[0].contentType == "text/plain")
    }

    // MARK: - Attachments filter tests

    @Test
    func textCalendarIsAttachmentWithoutDisposition() {
        // text/calendar without explicit "attachment" disposition should still be an attachment
        let header = MessageInfo(sequenceNumber: SequenceNumber(1))
        let plainPart = MessagePart(section: Section([1]), contentType: "text/plain")
        let calendarPart = MessagePart(section: Section([2]), contentType: "text/calendar; method=REQUEST", filename: "invite.ics")
        let message = Message(header: header, parts: [plainPart, calendarPart])

        let attachments = message.attachments
        #expect(attachments.count == 1)
        #expect(attachments[0].contentType.hasPrefix("text/calendar"))
    }

    @Test
    func textCalendarIsAttachmentEvenWithoutFilename() {
        // text/calendar with no filename and no disposition should still be detected as attachment
        let header = MessageInfo(sequenceNumber: SequenceNumber(1))
        let calendarPart = MessagePart(section: Section([1]), contentType: "text/calendar")
        let message = Message(header: header, parts: [calendarPart])

        let attachments = message.attachments
        #expect(attachments.count == 1)
    }

    // MARK: - Default invite.ics filename

    @Test
    func defaultInviteICSFilename() {
        // text/calendar with no filename in BODYSTRUCTURE should default to "invite.ics"
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "calendar", lineCount: 5)
        var fields = emptyFields()
        fields.parameters["method"] = "REQUEST"
        let part = BodyStructure.Singlepart(kind: .text(text), fields: fields)
        let structure = BodyStructure.singlepart(part)

        let parts = Array<MessagePart>(structure)

        #expect(parts.count == 1)
        #expect(parts[0].filename == "invite.ics")
    }

    @Test
    func explicitFilenameOverridesDefault() {
        // text/calendar with an explicit filename should keep the explicit one
        let text = BodyStructure.Singlepart.Text(mediaSubtype: "calendar", lineCount: 5)
        var fields = emptyFields()
        fields.parameters["name"] = "meeting.ics"
        let part = BodyStructure.Singlepart(kind: .text(text), fields: fields)
        let structure = BodyStructure.singlepart(part)

        let parts = Array<MessagePart>(structure)

        #expect(parts[0].filename == "meeting.ics")
    }

    // MARK: - suggestedFilename strips charset params

    @Test
    func suggestedFilenameStripsCharsetParams() {
        // Part with contentType "text/html; charset=utf-8" and no filename
        let part = MessagePart(section: Section([1]), contentType: "text/html; charset=utf-8")

        let suggested = part.suggestedFilename
        // Should produce a proper extension (html), not "dat"
        #expect(suggested.hasSuffix(".html"), "Expected .html extension, got: \(suggested)")
    }

    @Test
    func suggestedFilenameWithoutParamsStillWorks() {
        let part = MessagePart(section: Section([2]), contentType: "image/png")

        let suggested = part.suggestedFilename
        #expect(suggested.hasSuffix(".png"), "Expected .png extension, got: \(suggested)")
    }

    @Test
    func suggestedFilenameUsesExplicitFilename() {
        let part = MessagePart(section: Section([1]), contentType: "text/html; charset=utf-8", filename: "report.html")

        let suggested = part.suggestedFilename
        #expect(suggested == "report.html")
    }
}
