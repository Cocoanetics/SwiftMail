// RTFCompression.swift
// Decompression for `PR_RTF_COMPRESSED` (MS-OXRTFCP).
//
// Outlook stores the rich-text body of a `.msg` in a compressed stream whose
// 16-byte header says which of two forms follows: `LZFu`, an LZ77 variant over
// a 4096-byte ring dictionary preloaded with the most common RTF control
// words, or `MELA`, the same header with the RTF stored verbatim.

import Foundation

enum RTFCompression {

    /// The dictionary the compressor starts from (MS-OXRTFCP §2.1.3.1.2).
    ///
    /// Both sides preload these 207 bytes, so a back-reference in the very
    /// first control byte can already name `{\rtf1\ansi` without it having
    /// appeared in the output.
    static let initialDictionary: [UInt8] = Array(
        ("{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}"
         + "{\\f0\\fnil \\froman \\fswiss \\fmodern \\fscript "
         + "\\fdecor MS Sans SerifSymbolArialTimes New RomanCourier"
         + "{\\colortbl\\red0\\green0\\blue0\r\n"
         + "\\par \\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx").utf8
    )

    fileprivate static let dictionarySize = 4096

    private static let compressedMagic: UInt32 = 0x7546_5A4C   // "LZFu"
    private static let uncompressedMagic: UInt32 = 0x414C_454D // "MELA"

    /// Decompress a `PR_RTF_COMPRESSED` stream into RTF bytes.
    ///
    /// - Parameter data: The full stream, header included.
    /// - Returns: The RTF source.
    static func decompress(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else {
            throw MSGParserError.malformedRTF("compressed stream shorter than its header")
        }

        let compressedSize = Int(uint32(bytes, 0))
        let uncompressedSize = Int(uint32(bytes, 4))

        switch uint32(bytes, 8) {
            case uncompressedMagic:
                // The header is present but the body was never compressed.
                let end = min(16 + max(0, uncompressedSize), bytes.count)
                return end > 16 ? Data(bytes[16..<end]) : Data()

            case compressedMagic:
                // COMPSIZE counts every byte after itself, so the payload ends
                // at 4 + COMPSIZE — clamped to what the stream actually holds,
                // because a truncated body should still yield what survived.
                let end = min(max(16, 4 + compressedSize), bytes.count)
                var expander = Expander(source: Array(bytes[16..<end]), uncompressedSize: uncompressedSize)
                return expander.run()

            case let magic:
                throw MSGParserError.malformedRTF("unknown compression magic 0x\(String(magic, radix: 16))")
        }
    }

    fileprivate static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

// MARK: - Expansion

private extension RTFCompression {

    /// The LZ77 expansion itself: control bytes whose bits pick, for each of
    /// the next eight tokens, a literal byte or a back-reference into the ring
    /// dictionary.
    struct Expander {
        let source: [UInt8]
        let uncompressedSize: Int

        var dictionary: [UInt8]
        var writePosition: Int
        var out: [UInt8] = []
        var index = 0

        init(source: [UInt8], uncompressedSize: Int) {
            self.source = source
            self.uncompressedSize = uncompressedSize

            var dictionary = [UInt8](repeating: 0, count: RTFCompression.dictionarySize)
            dictionary.replaceSubrange(0..<RTFCompression.initialDictionary.count,
                                       with: RTFCompression.initialDictionary)
            self.dictionary = dictionary
            self.writePosition = RTFCompression.initialDictionary.count

            // The declared size is a hint from an untrusted file, so it sizes
            // the buffer but never bounds the loop on its own; input
            // exhaustion does.
            out.reserveCapacity(min(max(0, uncompressedSize), 1 << 24))
        }

        mutating func run() -> Data {
            while index < source.count {
                let control = source[index]
                index += 1

                for bit in 0..<8 {
                    guard index < source.count else { return Data(out) }

                    let more = control & (1 << bit) == 0 ? appendLiteral() : appendReference()
                    guard more else { return Data(out) }

                    if uncompressedSize > 0 && out.count >= uncompressedSize { return Data(out) }
                }
            }
            return Data(out)
        }

        /// Emit one literal byte. Always continues.
        private mutating func appendLiteral() -> Bool {
            emit(source[index])
            index += 1
            return true
        }

        /// Emit a run copied out of the dictionary. Returns false at the
        /// end-of-stream marker.
        private mutating func appendReference() -> Bool {
            guard index + 1 < source.count else { return false }
            let high = UInt16(source[index])
            let low = UInt16(source[index + 1])
            index += 2

            let offset = Int((high << 4) | (low >> 4))
            let length = Int(low & 0x0F) + 2

            // A reference to the current write position is the end-of-stream
            // marker, not a copy.
            guard offset != writePosition else { return false }

            for step in 0..<length {
                emit(dictionary[(offset + step) % RTFCompression.dictionarySize])
            }
            return true
        }

        /// Append a byte to the output and to the ring dictionary behind it.
        private mutating func emit(_ byte: UInt8) {
            out.append(byte)
            dictionary[writePosition] = byte
            writePosition = (writePosition + 1) % RTFCompression.dictionarySize
        }
    }
}
