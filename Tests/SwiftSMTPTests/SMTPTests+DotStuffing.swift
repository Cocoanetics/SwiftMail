import Foundation
@testable import SwiftMail
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPDotStuffingTests {
    // MARK: - Dot-Stuffing (RFC 5321 §4.5.2)

    @Test
    func dotStuffNoLeadingDots() {
        let input = Data("Hello\r\nWorld\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == input)
    }

    @Test
    func dotStuffLeadingDotOnFirstLine() {
        let input = Data(".hidden\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("..hidden\r\n".utf8))
    }

    @Test
    func dotStuffLeadingDotAfterCRLF() {
        let input = Data("Hello\r\n.World\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("Hello\r\n..World\r\n".utf8))
    }

    @Test
    func dotStuffMultipleLeadingDots() {
        let input = Data(".first\r\nsafe\r\n.second\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("..first\r\nsafe\r\n..second\r\n".utf8))
    }

    @Test
    func dotStuffLineThatIsJustADot() {
        // A bare ".\r\n" without stuffing would terminate DATA prematurely
        let input = Data("line1\r\n.\r\nline3\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("line1\r\n..\r\nline3\r\n".utf8))
    }

    @Test
    func dotStuffDotsInMiddleOfLineAreUntouched() {
        let input = Data("no.dots.at.start\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == input)
    }

    @Test
    func dotStuffEmptyData() {
        let input = Data()
        let output = SendContentCommand.dotStuff(input)
        #expect(output.isEmpty)
    }

    @Test
    func dotStuffConsecutiveDottedLines() {
        let input = Data(".a\r\n.b\r\n.c\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("..a\r\n..b\r\n..c\r\n".utf8))
    }
}
