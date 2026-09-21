// CompoundFile.swift
// Minimal reader for the Compound File Binary format (MS-CFB), the OLE2
// container that Outlook writes a saved `.msg` into.
//
// Only the read path needed by ``MSGParser`` is implemented: the FAT/MiniFAT
// sector chains, the directory tree, and stream extraction. Writing, the
// transaction log, and free-sector reclamation are not.
//
// Every offset here comes from a file that arrived as mail, so the reader
// treats the whole structure as hostile: sector numbers are range-checked
// before use, chain walks carry a visited set (the FAT is a linked list and a
// crafted file can point a sector at itself), and a declared stream size is
// never trusted beyond the bytes actually present.

import Foundation

/// A parsed MS-CFB container.
struct CompoundFile {

    /// What a directory entry describes.
    enum EntryKind: UInt8 {
        case unallocated = 0
        case storage = 1
        case stream = 2
        case root = 5
    }

    /// A directory entry: a storage (directory), a stream (file), or the root.
    struct Entry {
        let name: String
        let kind: EntryKind
        let startSector: UInt32
        let size: Int
        let leftSibling: UInt32
        let rightSibling: UInt32
        let child: UInt32
    }

    // Sector chain sentinels (MS-CFB §2.2). Anything >= maxRegularSector is a
    // terminator or a reserved marker, never a readable sector.
    fileprivate static let maxRegularSector: UInt32 = 0xFFFF_FFFA
    fileprivate static let noStream: UInt32 = 0xFFFF_FFFF

    private let reader: SectorReader
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: [UInt8]
    private let miniStreamCutoff: Int

    /// All directory entries, in directory-stream order. Index 0 is the root.
    let entries: [Entry]

    /// The root storage.
    var root: Entry { entries[0] }

    // MARK: - Parsing

    init(data: Data) throws {
        let bytes = [UInt8](data)
        let header = try Header(bytes: bytes)

        let reader = SectorReader(bytes: bytes, sectorSize: header.sectorSize)
        let difat = Self.readDIFAT(header: header, reader: reader)
        let fat = reader.readSectorNumbers(in: Array(difat.prefix(max(0, header.fatSectorCount))))
        let miniFAT = reader.readSectorNumbers(in: reader.chain(from: header.firstMiniFATSector, fat: fat))

        let entries = Self.readDirectory(
            reader.concatenate(reader.chain(from: header.firstDirectorySector, fat: fat))
        )
        guard let root = entries.first, root.kind == .root else {
            throw MSGParserError.malformedContainer("missing root directory entry")
        }

        // Streams below the cutoff are packed into the root entry's own stream,
        // addressed in 64-byte mini sectors through the MiniFAT.
        var miniStream = reader.concatenate(reader.chain(from: root.startSector, fat: fat))
        if miniStream.count > root.size { miniStream.removeLast(miniStream.count - root.size) }

        self.reader = reader
        self.fat = fat
        self.miniFAT = miniFAT
        self.miniStream = miniStream
        self.miniStreamCutoff = header.miniStreamCutoff
        self.entries = entries
    }

    /// Read the index of FAT sectors: 109 entries in the header, the rest in
    /// their own chain of sectors that each end with a link to the next.
    private static func readDIFAT(header: Header, reader: SectorReader) -> [UInt32] {
        var difat = header.headerDIFAT
        var next = header.firstDIFATSector
        var seen = Set<UInt32>()
        var remaining = min(header.difatSectorCount, reader.totalSectors)

        while next < maxRegularSector, remaining > 0 {
            guard seen.insert(next).inserted, let sector = reader.sector(next) else { break }
            let perSector = header.sectorSize / 4
            for slot in 0..<(perSector - 1) {
                difat.append(SectorReader.uint32(sector, slot * 4))
            }
            next = SectorReader.uint32(sector, (perSector - 1) * 4)
            remaining -= 1
        }
        return difat
    }

    /// Split the directory stream into its fixed 128-byte entries.
    private static func readDirectory(_ stream: [UInt8]) -> [Entry] {
        stride(from: 0, to: max(0, stream.count - 127), by: 128).compactMap { offset in
            directoryEntry(stream, offset: offset)
        }
    }

    private static func directoryEntry(_ stream: [UInt8], offset: Int) -> Entry? {
        guard offset + 128 <= stream.count,
              let kind = EntryKind(rawValue: stream[offset + 66]), kind != .unallocated else { return nil }

        // The name is UTF-16LE including a trailing NUL, whose two bytes the
        // declared length counts. A length outside the 64-byte field is
        // malformed, not a reason to read past it.
        let nameLength = Int(SectorReader.uint16(stream, offset + 64))
        guard nameLength >= 2, nameLength <= 64 else { return nil }
        let name = String(decodingUTF16LE: Array(stream[offset..<(offset + nameLength - 2)]))

        // v3 files store the size as 32 bits with the high word zero; a garbage
        // high word must not produce a plausible-looking huge size.
        let sizeLow = Int(SectorReader.uint32(stream, offset + 120))
        let sizeHigh = SectorReader.uint32(stream, offset + 124)

        return Entry(
            name: name,
            kind: kind,
            startSector: SectorReader.uint32(stream, offset + 116),
            size: sizeHigh == 0 ? sizeLow : Int.max,
            leftSibling: SectorReader.uint32(stream, offset + 68),
            rightSibling: SectorReader.uint32(stream, offset + 72),
            child: SectorReader.uint32(stream, offset + 76)
        )
    }

    // MARK: - Stream access

    /// The bytes of a stream entry.
    ///
    /// A declared size longer than the chain actually yields is truncated
    /// rather than treated as an error: real files from mail are occasionally
    /// short, and a partial body is more useful than a failed parse.
    func data(for entry: Entry) -> Data {
        guard entry.kind == .stream, entry.size > 0 else { return Data() }

        var out = entry.size < miniStreamCutoff
            ? miniStreamBytes(from: entry.startSector, limit: entry.size)
            : reader.concatenate(reader.chain(from: entry.startSector, fat: fat), limit: entry.size)

        if out.count > entry.size { out.removeLast(out.count - entry.size) }
        return Data(out)
    }

    /// Walk a MiniFAT chain through the mini stream.
    private func miniStreamBytes(from start: UInt32, limit: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(min(limit, miniStream.count))

        var sector = start
        var seen = Set<UInt32>()
        let miniSectorSize = 64

        while sector < Self.maxRegularSector, out.count < limit {
            guard seen.insert(sector).inserted else { break }
            let start = Int(sector) * miniSectorSize
            guard start >= 0, start < miniStream.count else { break }
            out.append(contentsOf: miniStream[start..<min(start + miniSectorSize, miniStream.count)])
            guard Int(sector) < miniFAT.count else { break }
            sector = miniFAT[Int(sector)]
        }
        return out
    }

    /// The immediate children of a storage (or the root), in no particular order.
    ///
    /// Children hang off a red-black tree rooted at `child`; the traversal is
    /// iterative with a visited set because sibling pointers in a crafted file
    /// can form a cycle.
    func children(of entry: Entry) -> [Entry] {
        var result: [Entry] = []
        var stack: [UInt32] = [entry.child]
        var seen = Set<UInt32>()

        while let index = stack.popLast() {
            guard index < Self.noStream, Int(index) < entries.count else { continue }
            guard seen.insert(index).inserted else { continue }
            let child = entries[Int(index)]
            guard child.kind != .unallocated else { continue }
            result.append(child)
            stack.append(child.leftSibling)
            stack.append(child.rightSibling)
        }
        return result
    }
}

// MARK: - Header

private extension CompoundFile {

    /// The 512-byte file header (MS-CFB §2.2).
    struct Header {
        let sectorSize: Int
        let fatSectorCount: Int
        let firstDirectorySector: UInt32
        let miniStreamCutoff: Int
        let firstMiniFATSector: UInt32
        let firstDIFATSector: UInt32
        let difatSectorCount: Int
        let headerDIFAT: [UInt32]

        init(bytes: [UInt8]) throws {
            guard bytes.count >= 512 else { throw MSGParserError.notACompoundFile }
            let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
            guard Array(bytes[0..<8]) == signature else { throw MSGParserError.notACompoundFile }

            // Sector size is a power-of-two shift: 9 (512) in v3, 12 (4096) in
            // v4. Anything else is malformed, and an unbounded shift would
            // overflow the size it computes.
            let sectorShift = Int(SectorReader.uint16(bytes, 30))
            let miniSectorShift = Int(SectorReader.uint16(bytes, 32))
            guard sectorShift == 9 || sectorShift == 12, miniSectorShift == 6 else {
                throw MSGParserError.malformedContainer(
                    "unsupported sector shift \(sectorShift)/\(miniSectorShift)"
                )
            }

            sectorSize = 1 << sectorShift
            fatSectorCount = Int(SectorReader.uint32(bytes, 44))
            firstDirectorySector = SectorReader.uint32(bytes, 48)
            miniStreamCutoff = Int(SectorReader.uint32(bytes, 56))
            firstMiniFATSector = SectorReader.uint32(bytes, 60)
            firstDIFATSector = SectorReader.uint32(bytes, 68)
            difatSectorCount = Int(SectorReader.uint32(bytes, 72))
            headerDIFAT = (0..<109).map { SectorReader.uint32(bytes, 76 + $0 * 4) }
        }
    }

    /// Sector addressing over the raw file bytes.
    struct SectorReader {
        let bytes: [UInt8]
        let sectorSize: Int

        /// The file must be a whole number of sectors past the 512-byte header;
        /// this count bounds every chain walk.
        var totalSectors: Int { max(0, (bytes.count - 512) / sectorSize) }

        /// The raw bytes of one sector, or nil when the number is out of range.
        func sector(_ number: UInt32) -> [UInt8]? {
            guard number < CompoundFile.maxRegularSector, Int(number) < totalSectors else { return nil }
            // Sector 0 begins one sector-size into the file: for 512-byte
            // sectors just past the header, and for 4096-byte sectors past the
            // header plus its zero padding.
            let start = (Int(number) + 1) * sectorSize
            guard start + sectorSize <= bytes.count else { return nil }
            return Array(bytes[start..<(start + sectorSize)])
        }

        /// Follow a FAT chain, stopping at a terminator or a cycle.
        func chain(from start: UInt32, fat: [UInt32]) -> [UInt32] {
            var result: [UInt32] = []
            var seen = Set<UInt32>()
            var sector = start

            while sector < CompoundFile.maxRegularSector, result.count <= totalSectors {
                guard seen.insert(sector).inserted else { break }
                result.append(sector)
                guard Int(sector) < fat.count else { break }
                sector = fat[Int(sector)]
            }
            return result
        }

        /// Concatenate the bytes of the given sectors, stopping once `limit`
        /// bytes are available.
        func concatenate(_ sectors: [UInt32], limit: Int = .max) -> [UInt8] {
            var out: [UInt8] = []
            for number in sectors {
                guard out.count < limit, let sector = sector(number) else { break }
                out.append(contentsOf: sector)
            }
            return out
        }

        /// Read the given sectors as a flat table of little-endian `UInt32`s,
        /// which is how the FAT and the MiniFAT are stored.
        func readSectorNumbers(in sectors: [UInt32]) -> [UInt32] {
            var table: [UInt32] = []
            table.reserveCapacity(sectors.count * (sectorSize / 4))
            for number in sectors {
                guard let sector = sector(number) else { continue }
                for slot in 0..<(sectorSize / 4) {
                    table.append(Self.uint32(sector, slot * 4))
                }
            }
            return table
        }

        static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
            guard offset + 2 <= bytes.count else { return 0 }
            return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }

        static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
            guard offset + 4 <= bytes.count else { return 0 }
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }
}

extension String {
    /// Decode UTF-16LE bytes, replacing anything unpaired rather than failing:
    /// these are directory names from an untrusted file and a bad name must not
    /// abort the parse.
    init(decodingUTF16LE bytes: [UInt8]) {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = 0
        while index + 1 < bytes.count {
            units.append(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            index += 2
        }
        self = String(decoding: units, as: UTF16.self)
    }
}
