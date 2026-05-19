import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    import CoreFoundation
#endif

/// Resolve a charset label (e.g. "utf-8", "ISO-8859-1", "windows-1252", "cp932")
/// to a `String.Encoding`. Returns `nil` if unknown or not text (e.g. "binary").
///
/// Five layered detection strategies — see helpers below:
///  - normalize case, separators, quotes (``normalizeCharsetLabel``)
///  - alias odd or ambiguous labels to canonical IANA names (``charsetAliases``)
///  - reject explicit "no text" labels
///  - try CoreFoundation's IANA mapping (macOS/iOS family)
///  - fall back to a hand-maintained label -> String.Encoding table (Linux)
public func stringEncoding(for rawCharset: String) -> String.Encoding? {
    guard !rawCharset.isEmpty else { return nil }
    let label = canonicalCharsetLabel(rawCharset)

    switch label {
        case "binary", "x-binary":
            return nil
        default:
            break
    }

    if let cfEncoding = coreFoundationEncoding(forIANAName: label) {
        return cfEncoding
    }
    return knownCharsetEncodings[label]
}

/// Apply trim/lowercase/separator normalization plus the alias lookup so the
/// rest of `stringEncoding(for:)` can deal in canonical IANA names.
private func canonicalCharsetLabel(_ rawCharset: String) -> String {
    var label = rawCharset
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        .lowercased()
    // Collapse underscores to hyphens (e.g. "ks_c_5601-1987"), squeeze runs of
    // whitespace/hyphens, and strip weird postfixes seen in the wild.
    label = label.replacingOccurrences(of: "_", with: "-")
    label = label.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    label = label.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    if label.hasSuffix("$esc") { label = String(label.dropLast(4)) }
    return charsetAliases[label] ?? label
}

/// CoreFoundation's IANA-name table covers most charsets on Apple platforms.
/// Returns `nil` on Linux (no CoreFoundation) or when the name isn't known.
private func coreFoundationEncoding(forIANAName label: String) -> String.Encoding? {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let cfEnc = CFStringConvertIANACharSetNameToEncoding(label as CFString)
        guard cfEnc != kCFStringEncodingInvalidId else { return nil }
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String.Encoding(rawValue: nsEnc)
    #else
        return nil
    #endif
}

/// Map odd or ambiguous labels to known-good IANA names.
private let charsetAliases: [String: String] = [
    // UTF variants & typos
    "utf8": "utf-8",
    "utf8mb4": "utf-8",
    "utf-7": "utf-7",
    "utf7": "utf-7",
    "utf-16le": "utf-16le",
    "utf-16be": "utf-16be",
    "utf-32le": "utf-32le",
    "utf-32be": "utf-32be",

    // ASCII
    "us-ascii": "us-ascii",
    "iso646-us": "us-ascii",
    "ascii": "us-ascii",

    // Latin-1 family
    "latin1": "iso-8859-1",
    "latin-1": "iso-8859-1",
    "cp1252": "windows-1252",
    "windows-1252": "windows-1252",
    "win-1252": "windows-1252",

    // Other Windows code pages seen in your data
    "windows-1250": "windows-1250",
    "windows-1251": "windows-1251",
    "windows-1253": "windows-1253",
    "windows-1254": "windows-1254",
    "windows-1255": "windows-1255",
    "windows-1256": "windows-1256",
    "windows-1257": "windows-1257",
    "windows-1258": "windows-1258",

    // Shift-JIS & friends
    "shift_jis": "shift_jis",
    "shift-jis": "shift_jis",
    "sjis": "shift_jis",
    "cp932": "shift_jis",

    // ISO-2022-JP oddities
    "iso-2022-jp": "iso-2022-jp",
    "_iso-2022-jp": "iso-2022-jp",

    // EUC encodings
    "euc-jp": "euc-jp",
    "euc-kr": "euc-kr",

    // Korean aliases
    "ks-c-5601-1987": "euc-kr",
    "ks-c-5601_1987": "euc-kr",
    "ks-c-5601": "euc-kr",
    "ks-c-5601-1992": "euc-kr",
    "ks_c_5601-1987": "euc-kr",   // from your list

    // Chinese encodings
    "gb2312": "gb2312",
    "gbk": "gbk",
    "gb18030": "gb18030",
    "big5": "big5",

    // KOI8
    "koi8-r": "koi8-r",

    // Misc seen in the wild
    "iso-8859-15": "iso-8859-15",
    "iso-8859-2": "iso-8859-2",
    "iso-8859-5": "iso-8859-5",
    "iso-8859-6": "iso-8859-6",
    "iso-8859-7": "iso-8859-7",
    "iso-8859-8": "iso-8859-8",
    "iso-8859-8-i": "iso-8859-8-i",
    "iso-8859-9": "iso-8859-9",
    "tis-620": "tis-620",
    "macroman": "macintosh",
    "gbk/gb2312": "gbk" // just in case
]

/// Hand-maintained label -> ``String.Encoding`` map for the encodings that
/// String.Encoding actually exposes. Used as the fallback when
/// CoreFoundation's IANA mapping isn't available (Linux).
private let knownCharsetEncodings: [String: String.Encoding] = [
    // UTF variants
    "utf-8": .utf8,
    "utf-16": .utf16,       // platform-endian with BOM
    "utf-16le": .utf16LittleEndian,
    "utf-16be": .utf16BigEndian,
    "utf-32": .utf32,       // platform-endian with BOM
    "utf-32le": .utf32LittleEndian,
    "utf-32be": .utf32BigEndian,

    // ASCII
    "us-ascii": .ascii,

    // ISO Latin family (only the ones that exist in String.Encoding)
    "iso-8859-1": .isoLatin1,
    "iso-8859-2": .isoLatin2,

    // Windows code pages (only the ones that exist in String.Encoding)
    "windows-1250": .windowsCP1250,
    "windows-1251": .windowsCP1251,
    "windows-1252": .windowsCP1252,
    "windows-1253": .windowsCP1253,
    "windows-1254": .windowsCP1254,

    // Japanese encodings
    "shift_jis": .shiftJIS,
    "euc-jp": .japaneseEUC,
    "iso-2022-jp": .iso2022JP,

    // Korean encodings (fallback to UTF-8 for unsupported encodings)
    "euc-kr": .utf8,

    // Chinese encodings (fallback to UTF-8 for unsupported encodings)
    "gb2312": .utf8,
    "gbk": .utf8,
    "gb18030": .utf8,
    "big5": .utf8,

    // Other encodings (fallback to UTF-8 for unsupported encodings)
    "koi8-r": .utf8,
    "macintosh": .utf8
]

// MARK: - String Extension for Backward Compatibility

extension String {
    /// Convert a charset name to a Swift Encoding with robust normalization
    /// - Parameter charset: The charset name to convert
    /// - Returns: The corresponding String.Encoding, or .utf8 if not recognized
    static func encodingFromCharset(_ charset: String) -> String.Encoding {
        return stringEncoding(for: charset) ?? .utf8
    }
}
