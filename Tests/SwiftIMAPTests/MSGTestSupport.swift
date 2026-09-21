// MSGTestSupport.swift
// Builders that produce a real `.msg` in memory, so the parser can be tested
// end to end without shipping someone's mail as a fixture.

import Foundation
@testable import SwiftMail

// MARK: - LZFu compression

/// One unit of an LZFu stream.
enum LZFuToken {
    case literal(UInt8)
    /// A copy of `length` bytes from `offset` in the ring dictionary.
    case reference(offset: Int, length: Int)
}

/// Build a `PR_RTF_COMPRESSED` stream from tokens.
///
/// Outlook's compressor is not needed to exercise the decompressor: literals
/// and back-references terminated by the offset-equals-write-position marker
/// are valid LZFu by construction.
func lzfuCompress(_ tokens: [LZFuToken], uncompressedSize: Int) -> Data {
    var payload: [UInt8] = []
    var writePosition = RTFCompression.initialDictionary.count

    var index = 0
    while index < tokens.count {
        let group = Array(tokens[index..<min(index + 8, tokens.count)])
        var control: UInt8 = 0
        var body: [UInt8] = []
        for (bit, token) in group.enumerated() {
            switch token {
                case .literal(let byte):
                    body.append(byte)
                    writePosition = (writePosition + 1) % 4096
                case .reference(let offset, let length):
                    control |= UInt8(1 << bit)
                    body.append(UInt8((offset >> 4) & 0xFF))
                    body.append(UInt8(((offset & 0x0F) << 4) | ((length - 2) & 0x0F)))
                    writePosition = (writePosition + length) % 4096
            }
        }
        payload.append(control)
        payload.append(contentsOf: body)
        index += 8
    }

    // End of stream: a back-reference naming the current write position.
    payload.append(0x01)
    payload.append(UInt8((writePosition >> 4) & 0xFF))
    payload.append(UInt8((writePosition & 0x0F) << 4))

    var stream = Data()
    stream.append(contentsOf: littleEndian32(UInt32(payload.count + 12)))
    stream.append(contentsOf: littleEndian32(UInt32(uncompressedSize)))
    stream.append(contentsOf: littleEndian32(0x7546_5A4C))  // "LZFu"
    stream.append(contentsOf: littleEndian32(0))            // CRC, which readers do not check
    stream.append(contentsOf: payload)
    return stream
}

/// Compress RTF as literals only — valid output, just not small.
func lzfuCompress(rtf: Data) -> Data {
    lzfuCompress([UInt8](rtf).map { .literal($0) }, uncompressedSize: rtf.count)
}

func littleEndian32(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
}

func littleEndian16(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
}

// MARK: - Compound file writing

/// A node in the compound file being built.
indirect enum CFBNode {
    case stream(name: String, data: Data)
    case storage(name: String, children: [CFBNode])

    var name: String {
        switch self {
            case .stream(let name, _): return name
            case .storage(let name, _): return name
        }
    }
}

/// Writes a minimal MS-CFB container: 512-byte sectors, every stream in the
/// mini stream, and children linked as a right-leaning chain rather than a
/// balanced red-black tree. Readers traverse the sibling pointers either way,
/// and keeping the writer this small keeps the fixture readable.
struct CompoundFileBuilder {

    private static let sectorSize = 512
    private static let miniSectorSize = 64
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF
    private static let fatSector: UInt32 = 0xFFFF_FFFD

    /// Flattened directory entries, built depth-first from the root's children.
    private struct Entry {
        var name: String
        var kind: UInt8          // 1 storage, 2 stream, 5 root
        var child: UInt32 = freeSector
        var rightSibling: UInt32 = freeSector
        var startSector: UInt32 = endOfChain
        var size: Int = 0
    }

    /// How the small streams were packed into the root entry's mini stream.
    private struct MiniLayout {
        var stream: [UInt8] = []
        var fat: [UInt32] = []
    }

    /// - Parameter leadingFreeSlots: free directory slots to insert between
    ///   the root and the first real entry, with every pointer shifted past
    ///   them. Real files accumulate these when an entry is deleted. A reader
    ///   that compacts them away renumbers the entries after them and resolves
    ///   child/sibling pointers to the wrong storage, so a fixture with them
    ///   is the only way to tell the two behaviours apart.
    static func build(root children: [CFBNode], leadingFreeSlots: Int = 0) -> Data {
        var (entries, payloads) = flatten(children)
        if leadingFreeSlots > 0 { insertFreeSlots(leadingFreeSlots, into: &entries) }
        let mini = layOutMiniStream(entries: &entries, payloads: payloads)
        return serialize(entries: entries, mini: mini)
    }

    private static func insertFreeSlots(_ count: Int, into entries: inout [Entry]) {
        for index in entries.indices {
            if entries[index].child != freeSector { entries[index].child += UInt32(count) }
            if entries[index].rightSibling != freeSector { entries[index].rightSibling += UInt32(count) }
        }
        entries.insert(contentsOf: repeatElement(Entry(name: "", kind: 0), count: count), at: 1)
    }

    /// Walk the node tree into the flat directory the format stores, linking
    /// each storage's children through right siblings.
    private static func flatten(_ children: [CFBNode]) -> ([Entry], [Int: Data]) {
        var entries: [Entry] = [Entry(name: "Root Entry", kind: 5)]
        var payloads: [Int: Data] = [:]

        func append(_ node: CFBNode) -> Int {
            switch node {
                case .stream(let name, let data):
                    entries.append(Entry(name: name, kind: 2, size: data.count))
                    payloads[entries.count - 1] = data
                    return entries.count - 1
                case .storage(let name, let children):
                    entries.append(Entry(name: name, kind: 1))
                    let index = entries.count - 1
                    link(children, into: index)
                    return index
            }
        }

        func link(_ children: [CFBNode], into parent: Int) {
            var previous: Int?
            for node in children {
                let index = append(node)
                if let previous {
                    entries[previous].rightSibling = UInt32(index)
                } else {
                    entries[parent].child = UInt32(index)
                }
                previous = index
            }
        }

        link(children, into: 0)
        return (entries, payloads)
    }

    /// Pack every stream into 64-byte mini sectors and record its chain.
    ///
    /// Streams are taken in directory order, and `payloads` is keyed by the
    /// index `flatten` assigned, so inserted free slots are skipped by the
    /// `kind == 2` filter and the remaining stream order is unchanged.
    private static func layOutMiniStream(entries: inout [Entry], payloads: [Int: Data]) -> MiniLayout {
        var mini = MiniLayout()
        var streamOrder = payloads.keys.sorted().makeIterator()

        for index in entries.indices where entries[index].kind == 2 {
            guard let key = streamOrder.next(), let payload = payloads[key], !payload.isEmpty else { continue }
            let first = mini.stream.count / miniSectorSize
            mini.stream.append(contentsOf: [UInt8](payload))
            // Pad to a whole mini sector so the next stream starts aligned.
            while mini.stream.count % miniSectorSize != 0 { mini.stream.append(0) }
            let last = mini.stream.count / miniSectorSize - 1

            for sector in first..<last { mini.fat.append(UInt32(sector + 1)) }
            mini.fat.append(endOfChain)
            entries[index].startSector = UInt32(first)
        }
        return mini
    }

    /// Lay the regions out in sectors, build the FAT, and emit the file.
    private static func serialize(entries: [Entry], mini: MiniLayout) -> Data {
        var entries = entries

        let miniStreamSectors = sectorCount(bytes: mini.stream.count)
        let miniFATSectors = sectorCount(bytes: mini.fat.count * 4)
        let directorySectors = sectorCount(bytes: entries.count * 128)

        // The FAT has to describe itself, so its size is a fixpoint.
        var fatSectors = 1
        while true {
            let total = miniStreamSectors + miniFATSectors + directorySectors + fatSectors
            let needed = max(1, sectorCount(bytes: total * 4))
            if needed == fatSectors { break }
            fatSectors = needed
        }

        let miniFATStart = miniStreamSectors
        let directoryStart = miniFATStart + miniFATSectors
        let fatStart = directoryStart + directorySectors

        entries[0].startSector = miniStreamSectors > 0 ? 0 : endOfChain
        entries[0].size = mini.stream.count

        var fat = [UInt32](repeating: freeSector, count: fatStart + fatSectors)
        func chainRegion(start: Int, count: Int) {
            guard count > 0 else { return }
            for sector in start..<(start + count - 1) { fat[sector] = UInt32(sector + 1) }
            fat[start + count - 1] = endOfChain
        }
        chainRegion(start: 0, count: miniStreamSectors)
        chainRegion(start: miniFATStart, count: miniFATSectors)
        chainRegion(start: directoryStart, count: directorySectors)
        for sector in fatStart..<(fatStart + fatSectors) { fat[sector] = fatSector }

        var output = Data()
        output.append(contentsOf: header(
            fatSectorCount: fatSectors,
            firstDirectorySector: directorySectors > 0 ? directoryStart : Int(endOfChain),
            firstMiniFATSector: miniFATSectors > 0 ? miniFATStart : Int(endOfChain),
            miniFATSectorCount: miniFATSectors,
            fatSectorNumbers: Array(fatStart..<(fatStart + fatSectors))
        ))
        output.append(padded(mini.stream, toSectors: miniStreamSectors))
        output.append(padded(mini.fat.flatMap { littleEndian32($0) }, toSectors: miniFATSectors))
        output.append(padded(entries.flatMap(directoryEntryBytes), toSectors: directorySectors))
        output.append(padded(fat.flatMap { littleEndian32($0) }, toSectors: fatSectors))
        return output
    }

    // MARK: - Pieces

    private static func header(
        fatSectorCount: Int,
        firstDirectorySector: Int,
        firstMiniFATSector: Int,
        miniFATSectorCount: Int,
        fatSectorNumbers: [Int]
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes.replaceSubrange(0..<8, with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        bytes.replaceSubrange(24..<26, with: littleEndian16(0x003E))  // minor version
        bytes.replaceSubrange(26..<28, with: littleEndian16(0x0003))  // major version: 512-byte sectors
        bytes.replaceSubrange(28..<30, with: littleEndian16(0xFFFE))  // little-endian
        bytes.replaceSubrange(30..<32, with: littleEndian16(9))       // sector shift
        bytes.replaceSubrange(32..<34, with: littleEndian16(6))       // mini sector shift
        bytes.replaceSubrange(44..<48, with: littleEndian32(UInt32(fatSectorCount)))
        bytes.replaceSubrange(48..<52, with: littleEndian32(UInt32(bitPattern: Int32(firstDirectorySector))))
        bytes.replaceSubrange(56..<60, with: littleEndian32(4096))    // mini stream cutoff
        bytes.replaceSubrange(60..<64, with: littleEndian32(UInt32(bitPattern: Int32(firstMiniFATSector))))
        bytes.replaceSubrange(64..<68, with: littleEndian32(UInt32(miniFATSectorCount)))
        bytes.replaceSubrange(68..<72, with: littleEndian32(freeSector))  // no DIFAT chain
        bytes.replaceSubrange(72..<76, with: littleEndian32(0))

        // DIFAT: 109 slots in the header, unused ones left free.
        for slot in 0..<109 {
            let value = slot < fatSectorNumbers.count ? UInt32(fatSectorNumbers[slot]) : freeSector
            bytes.replaceSubrange((76 + slot * 4)..<(80 + slot * 4), with: littleEndian32(value))
        }
        return bytes
    }

    private static func directoryEntryBytes(_ entry: Entry) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 128)

        var name: [UInt8] = []
        for unit in entry.name.utf16 { name.append(contentsOf: littleEndian16(unit)) }
        name.append(contentsOf: [0, 0])  // terminator, which the length counts
        let clipped = Array(name.prefix(64))
        bytes.replaceSubrange(0..<clipped.count, with: clipped)
        bytes.replaceSubrange(64..<66, with: littleEndian16(UInt16(clipped.count)))

        bytes[66] = entry.kind
        bytes[67] = 1  // black
        bytes.replaceSubrange(68..<72, with: littleEndian32(freeSector))       // left sibling
        bytes.replaceSubrange(72..<76, with: littleEndian32(entry.rightSibling))
        bytes.replaceSubrange(76..<80, with: littleEndian32(entry.child))
        bytes.replaceSubrange(116..<120, with: littleEndian32(entry.startSector))
        bytes.replaceSubrange(120..<124, with: littleEndian32(UInt32(entry.size)))
        return bytes
    }

    private static func sectorCount(bytes: Int) -> Int {
        (bytes + sectorSize - 1) / sectorSize
    }

    private static func padded(_ bytes: [UInt8], toSectors sectors: Int) -> Data {
        var result = bytes
        let target = sectors * sectorSize
        if result.count < target { result.append(contentsOf: [UInt8](repeating: 0, count: target - result.count)) }
        return Data(result.prefix(target))
    }
}

// MARK: - MAPI fixture

/// A property to place in a `.msg` being built.
enum MAPIFixtureProperty {
    case unicode(MAPIPropertyID, String)
    case binary(MAPIPropertyID, Data)
    case int32(MAPIPropertyID, Int32)
    case systemTime(MAPIPropertyID, Date)
}

/// Build the streams for one message/attachment storage.
func mapiNodes(_ properties: [MAPIFixtureProperty], isTopLevel: Bool, extra: [CFBNode] = []) -> [CFBNode] {
    var nodes: [CFBNode] = []
    var fixed: [UInt8] = [UInt8](repeating: 0, count: isTopLevel ? 32 : 8)

    func appendFixed(id: MAPIPropertyID, type: MAPIPropertyType, value: [UInt8]) {
        fixed.append(contentsOf: littleEndian16(type.rawValue))
        fixed.append(contentsOf: littleEndian16(id.rawValue))
        fixed.append(contentsOf: littleEndian32(0))  // flags
        fixed.append(contentsOf: value + [UInt8](repeating: 0, count: max(0, 8 - value.count)))
    }

    for property in properties {
        switch property {
            case .unicode(let id, let text):
                var utf16: [UInt8] = []
                for unit in text.utf16 { utf16.append(contentsOf: littleEndian16(unit)) }
                nodes.append(.stream(name: substgName(id, .unicode), data: Data(utf16)))
            case .binary(let id, let data):
                nodes.append(.stream(name: substgName(id, .binary), data: data))
            case .int32(let id, let value):
                appendFixed(id: id, type: .int32, value: littleEndian32(UInt32(bitPattern: value)))
            case .systemTime(let id, let date):
                // FILETIME: 100ns ticks since 1601-01-01 UTC.
                let ticks = UInt64((date.timeIntervalSince1970 + 11_644_473_600) * 10_000_000)
                var value: [UInt8] = []
                for shift in stride(from: 0, to: 64, by: 8) { value.append(UInt8((ticks >> UInt64(shift)) & 0xFF)) }
                appendFixed(id: id, type: .systemTime, value: value)
        }
    }

    nodes.append(.stream(name: "__properties_version1.0", data: Data(fixed)))
    return nodes + extra
}

func substgName(_ id: MAPIPropertyID, _ type: MAPIPropertyType) -> String {
    let tag = (UInt32(id.rawValue) << 16) | UInt32(type.rawValue)
    return "__substg1.0_" + String(format: "%08X", tag)
}
