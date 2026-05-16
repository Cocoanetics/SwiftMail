import Foundation
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import CoreFoundation
#endif

/// Internal helper describing a contiguous run of MIME encoded-word matches that
/// can be merged before being decoded with the same charset/encoding.
struct MIMEEncodedWordRun {
    let charset: String
    let encoding: String
    let stringEncoding: String.Encoding
    var bytes: Data
    var originalText: String
}
