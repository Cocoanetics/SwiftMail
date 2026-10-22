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
    /// Legacy Japanese encodings tried before the Latin fallbacks for unlabelled
    /// or mislabelled mail: ISO-2022-JP (with extensions), CP932, then EUC-JP.
    static var japaneseFallbacks: [String.Encoding] {
        #if canImport(CoreFoundation) && (os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS))
        return [
            coreFoundationEncoding(.ISO_2022_JP_2),
            coreFoundationEncoding(.dosJapanese),
            coreFoundationEncoding(.EUC_JP)
        ]
        #else
        return []
        #endif
    }
}

extension String {
    /// Decodes unlabelled bytes as legacy Japanese only when the result actually
    /// reads as Japanese (contains kana or kanji), so Latin-1 bytes such as NEL
    /// are not misread as CP932 symbols.
    static func plausibleJapanese(_ data: Data) -> String? {
        for encoding in String.Encoding.japaneseFallbacks {
            guard let text = String(data: data, encoding: encoding) else { continue }
            let hasJapanese = text.unicodeScalars.contains { scalar in
                (0x3040...0x30FF).contains(scalar.value)      // Hiragana and Katakana
                    || (0x4E00...0x9FFF).contains(scalar.value) // CJK Unified Ideographs
                    || (0xFF66...0xFF9F).contains(scalar.value) // Half-width Katakana
            }
            if hasJapanese { return text }
        }
        return nil
    }
}
