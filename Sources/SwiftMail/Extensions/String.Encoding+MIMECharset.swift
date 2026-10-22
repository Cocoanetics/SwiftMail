// String.Encoding+MIMECharset.swift
// Resolve a MIME charset label to the encoding received mail is decoded with.

import Foundation
import SwiftCross

#if canImport(CoreFoundation) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
import CoreFoundation
#endif

extension String.Encoding {
    /// Resolve a MIME `charset` label for decoding received mail.
    ///
    /// Resolves through `init(ianaCharsetName:)`, then swaps a legacy CJK
    /// charset for the superset senders actually write under its label, as
    /// the WHATWG Encoding Standard has browsers do: GB2312 and GBK text
    /// decodes as GB18030, EUC-KR text as Windows-949. Mail labelled `gb2312`
    /// routinely carries GBK characters (an en dash is `A8 43`, which GB2312
    /// lacks), and a strict decoder rejects the whole encoded-word or body
    /// over that one character. Each superset decodes every well-formed
    /// sequence of its subset to the same character, apart from GB2312's
    /// `A1 A4` and `A1 AA`, which become U+00B7 and U+2014 as they do in
    /// browsers, and a few GBK private-use code points, which become the
    /// characters GB18030 has since assigned them.
    ///
    /// The declared charset wins, as in browsers: text that is really UTF-8
    /// but labelled `gb2312` or `euc-kr` now decodes in the superset rather
    /// than failing the strict decode and falling back to UTF-8.
    ///
    /// Big5 is left alone: Apple's Big5-HKSCS decoder turns some common Big5
    /// punctuation into private-use sequences.
    ///
    /// For decoding only. An encoder must not emit bytes outside the charset
    /// its label names.
    public init?(mimeCharset label: String) {
        guard let encoding = String.Encoding(ianaCharsetName: label) else {
            return nil
        }
        self = Self.decodingSupersets[encoding] ?? encoding
    }

    /// The superset each strict legacy CJK encoding is decoded with.
    private static let decodingSupersets: [String.Encoding: String.Encoding] = {
        #if canImport(CoreFoundation) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        let gb18030 = coreFoundationEncoding(.GB_18030_2000)
        return [
            coreFoundationEncoding(.EUC_CN): gb18030,
            coreFoundationEncoding(.GBK_95): gb18030,
            coreFoundationEncoding(.dosChineseSimplif): gb18030,
            coreFoundationEncoding(.EUC_KR): coreFoundationEncoding(.dosKorean),
            // Japanese: mail labelled Shift_JIS is almost always CP932 (①, ㈱, 髙),
            // and ISO-2022-JP often carries NEC/IBM extensions.
            .shiftJIS: coreFoundationEncoding(.dosJapanese),
            coreFoundationEncoding(.shiftJIS): coreFoundationEncoding(.dosJapanese),
            .iso2022JP: coreFoundationEncoding(.ISO_2022_JP_2)
        ]
        #else
        // Without CoreFoundation these charsets have no converter to widen;
        // SwiftCross resolves them to a `.utf8` placeholder.
        return [:]
        #endif
    }()

    #if canImport(CoreFoundation) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
    private static func coreFoundationEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
    #endif
}

extension String.Encoding {
    /// ISO-2022-JP with the NEC/IBM extensions Japanese mailers emit.
    static var iso2022JPExtended: String.Encoding? {
        #if canImport(CoreFoundation) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        return coreFoundationEncoding(.ISO_2022_JP_2)
        #else
        return nil
        #endif
    }

    /// Legacy 8-bit Japanese encodings tried before the Latin fallbacks for
    /// unlabelled or mislabelled mail: CP932, then EUC-JP.
    static var japaneseFallbacks: [String.Encoding] {
        #if canImport(CoreFoundation) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        return [
            coreFoundationEncoding(.dosJapanese),
            coreFoundationEncoding(.EUC_JP)
        ]
        #else
        return []
        #endif
    }
}

extension String {
    /// Decodes unlabelled ISO-2022-JP. Being 7-bit it is also valid UTF-8, so
    /// it has to be recognised before UTF-8 is tried; the `ESC $` that switches
    /// to a Japanese character set is the evidence, and UTF-8 text has none.
    static func iso2022JP(_ data: Data) -> String? {
        let escape: UInt8 = 0x1B
        let dollar: UInt8 = 0x24
        guard let encoding = String.Encoding.iso2022JPExtended,
              zip(data, data.dropFirst()).contains(where: { $0 == escape && $1 == dollar }) else {
            return nil
        }
        return String(data: data, encoding: encoding)
    }

    /// Decodes unlabelled 8-bit bytes as legacy Japanese only when the result
    /// actually reads as Japanese, so Latin-1 text keeps its Latin fallback.
    static func plausibleJapanese(_ data: Data) -> String? {
        for encoding in String.Encoding.japaneseFallbacks {
            if let text = String(data: data, encoding: encoding), text.readsAsJapanese(in: encoding) {
                return text
            }
        }
        return nil
    }

    /// In CP932 every byte from 0xA1 to 0xDF is a half-width katakana, which
    /// covers the Latin-1 capitals and symbols (Ä → ﾄ, ° → ｰ), so half-width
    /// katakana is no evidence of Japanese. Nor is an ideograph whose two bytes
    /// both read as Latin letters: "é" "l" "è" "v" in "élève" pair into two
    /// kanji. Full-width kana (led by 0x82/0x83 in CP932, 0xA4/0xA5 in EUC-JP,
    /// bytes Latin text practically never carries) or two other ideographs in
    /// a row are.
    private func readsAsJapanese(in encoding: String.Encoding) -> Bool {
        var ideographRun = 0
        for scalar in unicodeScalars {
            if (0x3041...0x30FF).contains(scalar.value) {        // Hiragana and Katakana
                return true
            }
            if (0x4E00...0x9FFF).contains(scalar.value) {        // CJK Unified Ideographs
                if Self.spellsLatinLetters(scalar, in: encoding) { continue }
                ideographRun += 1
                if ideographRun >= 2 { return true }
            } else {
                ideographRun = 0
            }
        }
        return false
    }

    /// Whether every byte of `scalar` in `encoding` is a letter in Latin-1 or
    /// Windows-1252, the reading the bytes get if they are not Japanese.
    private static func spellsLatinLetters(_ scalar: Unicode.Scalar, in encoding: String.Encoding) -> Bool {
        guard let bytes = String(scalar).data(using: encoding) else { return false }
        return bytes.allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)    // ASCII letters
                || [0x83, 0x8A, 0x8C, 0x8E, 0x9A, 0x9C, 0x9E, 0x9F].contains(byte) // ƒ Š Œ Ž š œ ž Ÿ
                || ((0xC0...0xFF).contains(byte) && byte != 0xD7 && byte != 0xF7)  // À to ÿ, but × and ÷
        }
    }
}
