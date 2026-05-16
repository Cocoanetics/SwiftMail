import Foundation
import Testing
@testable import SwiftMail

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMTPDotStuffingTests {
    // MARK: - Dot-Stuffing (RFC 5321 §4.5.2)

    @Test
    func testDotStuffNoLeadingDots() {
        let input = Data("Hello\r\nWorld\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == input)
    }

    @Test
    func testDotStuffLeadingDotOnFirstLine() {
        let input = Data(".hidden\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("..hidden\r\n".utf8))
    }

    @Test
    func testDotStuffLeadingDotAfterCRLF() {
        let input = Data("Hello\r\n.World\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("Hello\r\n..World\r\n".utf8))
    }

    @Test
    func testDotStuffMultipleLeadingDots() {
        let input = Data(".first\r\nsafe\r\n.second\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("..first\r\nsafe\r\n..second\r\n".utf8))
    }

    @Test
    func testDotStuffLineThatIsJustADot() {
        // A bare ".\r\n" without stuffing would terminate DATA prematurely
        let input = Data("line1\r\n.\r\nline3\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("line1\r\n..\r\nline3\r\n".utf8))
    }

    @Test
    func testDotStuffDotsInMiddleOfLineAreUntouched() {
        let input = Data("no.dots.at.start\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == input)
    }

    @Test
    func testDotStuffEmptyData() {
        let input = Data()
        let output = SendContentCommand.dotStuff(input)
        #expect(output.isEmpty)
    }

    @Test
    func testDotStuffConsecutiveDottedLines() {
        let input = Data(".a\r\n.b\r\n.c\r\n".utf8)
        let output = SendContentCommand.dotStuff(input)
        #expect(output == Data("..a\r\n..b\r\n..c\r\n".utf8))
    }
}
