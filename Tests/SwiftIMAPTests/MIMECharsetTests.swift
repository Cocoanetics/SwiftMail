// MIMECharsetTests.swift
// Tests for resolving MIME charset labels when decoding received mail

import Foundation
import SwiftCross
import Testing
@testable import SwiftMail

@Suite("MIME Charset Resolution Tests", .tags(.mime, .decoding))
struct MIMECharsetTests {

    @Test("Labels outside the legacy CJK family resolve as their IANA name does")
    func otherLabelsAreUnchanged() {
        for label in ["utf-8", "UTF-8", "iso-8859-1", "windows-1252", "shift_jis", "big5", "koi8-r"] {
            #expect(String.Encoding(mimeCharset: label) == String.Encoding(ianaCharsetName: label))
        }
        #expect(String.Encoding(mimeCharset: "x-no-such-charset") == nil)
        #expect(String.Encoding(mimeCharset: "binary") == nil)
    }

    #if canImport(Darwin)

    // `A8 43` is the en dash in GBK and GB18030; GB2312 has no such
    // character. Mail labelled `gb2312` carries it all the same.
    private static let gbkEnDash: [UInt8] = [0xA8, 0x43]
    // "中文" in GB2312, which GBK and GB18030 encode identically.
    private static let gb2312Zhongwen: [UInt8] = [0xD6, 0xD0, 0xCE, 0xC4]
    // "똠방": `8C 63` exists only in Windows-949, `B9 E6` in EUC-KR too.
    private static let cp949Text: [UInt8] = [0x8C, 0x63, 0xB9, 0xE6]

    @Test("A gb2312 encoded-word holding a GBK character decodes")
    func gb2312EncodedWordWithGBKCharacterDecodes() {
        // "Report \u{2013} draft" with the en dash as `A8 43`.
        #expect("=?gb2312?B?UmVwb3J0IKhDIGRyYWZ0?=".decodeMIMEHeader() == "Report \u{2013} draft")
        #expect("=?GB2312?Q?=D6=D0=CE=C4=A8=43?=".decodeMIMEHeader() == "中文\u{2013}")
    }

    @Test("A split gb2312 subject decodes across its encoded-words")
    func splitGB2312SubjectDecodes() {
        let raw = "=?gb2312?B?UmVwb3J0IKhDIGRyYWZ0?=\r\n =?gb2312?B?IGZvciByZXZpZXc=?="
        #expect(raw.decodeMIMEHeader() == "Report \u{2013} draft for review")
    }

    @Test("GB2312 text keeps decoding to the same characters")
    func gb2312TextIsUnchanged() {
        #expect("=?gb2312?B?1tDOxA==?=".decodeMIMEHeader() == "中文")
        #expect("=?gbk?B?1tDOxA==?=".decodeMIMEHeader() == "中文")
    }

    @Test("Every gb2312 and GBK label decodes as GB18030")
    func gbLabelsResolveToGB18030() {
        let gb18030 = String.Encoding(ianaCharsetName: "gb18030")
        for label in ["gb2312", "GB2312", "euc-cn", "csgb2312", "chinese", "gbk", "x-gbk", "cp936", "windows-936"] {
            #expect(String.Encoding(mimeCharset: label) == gb18030, "\(label)")
        }
    }

    @Test("An euc-kr encoded-word holding a Windows-949 syllable decodes")
    func eucKREncodedWordWithCP949SyllableDecodes() {
        #expect("=?euc-kr?B?jGO55g==?=".decodeMIMEHeader() == "똠방")
        #expect(String.Encoding(mimeCharset: "euc-kr") == String.Encoding(mimeCharset: "ks_c_5601-1987"))
    }

    @Test("A gb2312 body holding a GBK character decodes in its charset")
    func gb2312BodyWithGBKCharacterDecodes() throws {
        let headers = [
            "From: sender@example.com",
            "To: recipient@example.com",
            "Subject: GB2312 Body",
            "Content-Type: text/plain; charset=gb2312",
            "Content-Transfer-Encoding: 8bit",
            "",
            ""
        ].joined(separator: "\r\n")
        var data = Data(headers.utf8)
        data.append(contentsOf: Self.gb2312Zhongwen + Self.gbkEnDash)

        let message = try Message(emlData: data)

        #expect(message.parts.count == 1)
        guard message.parts.count == 1 else { return }
        #expect(message.parts[0].textContent == "中文\u{2013}")
    }

    @Test("An euc-kr body holding a Windows-949 syllable decodes in its charset")
    func eucKRBodyWithCP949SyllableDecodes() {
        let part = MessagePart(
            sectionString: "1",
            contentType: "text/plain; charset=euc-kr",
            data: Data(Self.cp949Text)
        )
        #expect(part.textContent == "똠방")
    }

    @Test("A gb2312 extended filename holding a GBK character decodes")
    func gb2312ExtendedFilenameWithGBKCharacterDecodes() {
        let header = "attachment; filename=\"fallback.pdf\"; filename*=gb2312''%D6%D0%CE%C4%A8%43.pdf"
        #expect(EMLParser.extractFilename(from: header) == "中文\u{2013}.pdf")
    }

    @Test("A gb2312 quoted-printable body holding a GBK character decodes in its charset")
    func gb2312QuotedPrintableContentDecodes() {
        let content = [
            "Content-Type: text/plain; charset=gb2312",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "=D6=D0=CE=C4=A8=43"
        ].joined(separator: "\n")
        #expect(content.decodeQuotedPrintableContent().contains("中文\u{2013}"))
    }

    @Test("A detected gb2312 or euc-kr charset is the superset it is decoded with")
    func detectedCharsetIsDecodingSuperset() {
        let gb18030 = String.Encoding(ianaCharsetName: "gb18030")
        let cp949 = String.Encoding(mimeCharset: "euc-kr")
        #expect("Content-Type: text/html; charset=gb2312\n\nbody".detectCharsetEncoding() == gb18030)
        #expect("<html><head><meta charset=gb2312></head></html>".detectCharsetEncoding() == gb18030)
        let metaHTTPEquiv = "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=euc-kr\">"
        #expect(metaHTTPEquiv.detectCharsetEncoding() == cp949)
        #expect(String(data: Data(Self.cp949Text), encoding: "<meta charset=euc-kr>".detectCharsetEncoding()) == "똠방")
    }

    @Test("RTF and Outlook code pages 936 and 949 decode as their supersets")
    func rtfCodePagesDecodeAsSupersets() {
        let gbText = Data(Self.gb2312Zhongwen + Self.gbkEnDash)
        #expect(String(data: gbText, encoding: RTFDeencapsulation.encoding(forCodePage: 936)) == "中文\u{2013}")
        #expect(String(data: Data(Self.cp949Text), encoding: RTFDeencapsulation.encoding(forCodePage: 949)) == "똠방")

        let rtf = Data(#"{\rtf1\ansi\ansicpg949\fromhtml1 \'8c\'63\'b9\'e6}"#.utf8)
        #expect(RTFDeencapsulation.html(from: rtf).contains("똠방"))
    }

    /// Strict EUC-CN read `B0 40` (GBK "癅") as a different character instead
    /// of failing, so trying it first would still show wrong text.
    @Test("Bytes strict GB2312 misread decode as GB18030 reads them")
    func gb2312MisreadBytesDecodeAsGB18030() {
        #expect("=?gb2312?B?sEA=?=".decodeMIMEHeader() == "\u{7645}")
        #expect("=?gb2312?B?1tCwQA==?=".decodeMIMEHeader() == "中\u{7645}")
        // `A1 A4` is the middle dot in GB18030, as browsers decode it.
        #expect("=?gb2312?B?oaQ=?=".decodeMIMEHeader() == "\u{00B7}")
        // `A3 A0`, private use in GBK, is the ideographic space in GB18030.
        #expect("=?gbk?B?o6A=?=".decodeMIMEHeader() == "\u{3000}")

        let part = MessagePart(
            sectionString: "1",
            contentType: "text/plain; charset=gb2312",
            data: Data(Self.gb2312Zhongwen + [0xB0, 0x40])
        )
        #expect(part.textContent == "中文\u{7645}")
    }

    /// The declared charset wins, as in browsers and Thunderbird: UTF-8 bytes
    /// mislabelled gb2312 decode as GB18030 rather than being re-read as UTF-8.
    @Test("UTF-8 text mislabelled gb2312 decodes in the declared charset")
    func mislabelledUTF8DecodesInDeclaredCharset() {
        // "发票" written as UTF-8 under a gb2312 label.
        #expect("=?gb2312?B?5Y+R56Wo?=".decodeMIMEHeader() == "鍙戠エ")
    }

    #endif
}
