import Foundation

/// Resolve a charset label (e.g. "utf-8", "ISO-8859-1", "windows-1252", "cp932")
/// to a `String.Encoding`. Returns `nil` if unknown or not text (e.g. "binary").
///
/// This function:
///  - normalizes case, separators, quotes
///  - fixes common aliases/typos
///  - uses CoreFoundation's IANA mapping where possible (macOS/iOS)
///  - supports encodings that exist only as raw NSStringEncoding values (e.g. UTF-7)
public func stringEncoding(for rawCharset: String) -> String.Encoding? {
    // 1) Quick reject: clearly not a text charset
    if rawCharset.isEmpty { return nil }

    // 2) Normalize (lowercased, trim, unify separators, strip quotes)
    var label = rawCharset
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        .lowercased()

    // Collapse underscores to hyphens (e.g. "ks_c_5601-1987")
    label = label.replacingOccurrences(of: "_", with: "-")
    // Collapse multiple spaces/hyphens
    label = label.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    label = label.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)

    // Strip weird postfixes seen in the wild (e.g. "_iso-2022-jp$esc")
    if label.hasSuffix("$esc") { label = String(label.dropLast(4)) }

    // 3) Alias fixes to canonical IANA names
    // Map odd or ambiguous labels to known good IANA names
    let aliasToIANA: [String: String] = [
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

    // Some labels arrive with weird casing (e.g. "Windows-1252", "UTF8", "ISO-8859-1")
    // After lowercasing, most map via aliasToIANA or IANA converter.
    if let mapped = aliasToIANA[label] {
        label = mapped
    }

    // 4) Hard "no text" cases
    switch label {
    case "binary", "x-binary":
        return nil
    default:
        break
    }

    // 5) Try CoreFoundation's IANA name -> CFStringEncoding -> NSStringEncoding
    // This covers the majority of charsets, including windows-125x, iso-2022-jp, euc-kr, gbk, gb18030, big5, koi8-r, etc.
    #if canImport(CoreFoundation)
    let cfEnc = CFStringConvertIANACharSetNameToEncoding(label as CFString)
    if cfEnc != kCFStringEncodingInvalidId {
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
        return String.Encoding(rawValue: nsEnc)
    }
    #endif

    // 6) Final bespoke fallbacks for UTF-16/32 LE/BE labels that some systems emit
    switch label {
    case "utf-8": return .utf8
    case "utf-16": return .utf16       // platform-endian with BOM
    case "utf-16le": return .utf16LittleEndian
    case "utf-16be": return .utf16BigEndian
    case "utf-32": return .utf32       // platform-endian with BOM
    case "utf-32le": return .utf32LittleEndian
    case "utf-32be": return .utf32BigEndian
    case "us-ascii": return .ascii
    case "iso-8859-1": return .isoLatin1
    case "iso-8859-2": return .isoLatin2
    default:
        return nil
    }
}

// MARK: - String Extension for Backward Compatibility

extension String {
    /// Convert a charset name to a Swift Encoding with robust normalization
    /// - Parameter charset: The charset name to convert
    /// - Returns: The corresponding String.Encoding, or .utf8 if not recognized
    static func encodingFromCharset(_ charset: String) -> String.Encoding {
        return stringEncoding(for: charset) ?? .utf8
    }
}
