import Foundation
import Testing

@testable import AMPControl

/// The entry `name` of a compound.
func nbtEntry(_ value: NBTValue?, _ name: String) -> NBTValue? {
    guard case .compound(let entries)? = value else { return nil }
    return entries.first { $0.name == name }?.value
}

@Suite struct NBTTests {
    // MARK: - Java Edition

    @Test func readsAGzippedJavaFile() throws {
        let file = try NBTFile(data: NBTFixtures.javaGzip)
        #expect(file.format == NBTFormat(compression: .gzip, littleEndian: false))
        #expect(file.format.label == "Java Edition (Big-Endian) · gzip")
        #expect(file.root.name == "")

        let data = nbtEntry(file.root.value, "Data")
        #expect(nbtEntry(data, "LevelName") == .string("Survival"))
        #expect(nbtEntry(data, "hardcore") == .byte(0))
        #expect(nbtEntry(data, "GameType") == .int(0))
        #expect(nbtEntry(data, "SpawnY") == .int(64))
        #expect(nbtEntry(data, "Time") == .long(123_456_789_012))
        #expect(nbtEntry(data, "BorderSize") == .double(59_999_968))
        #expect(nbtEntry(data, "rainLevel") == .float(0.25))
        #expect(nbtEntry(data, "version") == .short(19133))
        #expect(
            nbtEntry(data, "ServerBrands") == .list(.string, [.string("vanilla"), .string("paper")]))
        #expect(nbtEntry(data, "Empty") == .list(.end, []))
        #expect(nbtEntry(data, "Bytes") == .byteArray([1, -2, 3]))
        #expect(nbtEntry(data, "Ints") == .intArray([1, -2, 300_000]))
        #expect(nbtEntry(data, "Longs") == .longArray([1, -2, 5_000_000_000]))
        #expect(
            nbtEntry(data, "Pos") == .list(.double, [.double(1.5), .double(64), .double(-3.25)]))
        #expect(
            nbtEntry(nbtEntry(data, "GameRules"), "keepInventory") == .string("false"))
    }

    @Test func javaStringsUseModifiedUTF8() throws {
        let file = try NBTFile(data: NBTFixtures.javaRaw)
        let motd = nbtEntry(nbtEntry(file.root.value, "Data"), "motd")
        #expect(motd == .string("Grüße 🎮 \u{0} Ende"))

        let encoded = ModifiedUTF8.encode("a\u{0}🎮")
        #expect(encoded == [0x61, 0xC0, 0x80, 0xED, 0xA0, 0xBC, 0xED, 0xBE, 0xAE])
        #expect(ModifiedUTF8.decode(encoded[...]) == "a\u{0}🎮")
    }

    @Test func writesAJavaFileByteForByte() throws {
        let file = try NBTFile(data: NBTFixtures.javaGzip)
        let payload = try file.payload()
        #expect(Data(payload) == NBTFixtures.javaRaw)

        let stored = try file.encoded()
        #expect([UInt8](stored.prefix(2)) == [0x1F, 0x8B])
        let unpacked = try Zlib.decompress(stored)
        #expect(unpacked == NBTFixtures.javaRaw)
    }

    @Test func keepsZlibAndUncompressedJavaFilesAsTheyAre() throws {
        let zlib = try NBTFile(data: NBTFixtures.javaZlib)
        #expect(zlib.format == NBTFormat(compression: .zlib, littleEndian: false))
        let stored = try zlib.encoded()
        #expect(stored.first == 0x78)
        let unpacked = try Zlib.decompress(stored)
        #expect(unpacked == NBTFixtures.javaRaw)

        let raw = try NBTFile(data: NBTFixtures.javaRaw)
        #expect(raw.format == NBTFormat(compression: .none, littleEndian: false))
        #expect(raw.format.label == "Java Edition (Big-Endian) · unkomprimiert")
        #expect(raw.root == zlib.root)
        let rawStored = try raw.encoded()
        #expect(rawStored == NBTFixtures.javaRaw)
    }

    // MARK: - Bedrock Edition

    @Test func readsBedrockLevelDatWithItsHeader() throws {
        let file = try NBTFile(data: NBTFixtures.bedrockLevel)
        #expect(
            file.format
                == NBTFormat(compression: .none, littleEndian: true, bedrockHeaderVersion: 10))
        #expect(
            file.format.label == "Bedrock Edition (Little-Endian) · unkomprimiert · Header v10")

        let root = file.root.value
        #expect(nbtEntry(root, "LevelName") == .string("Bedrock Welt"))
        #expect(nbtEntry(root, "GameType") == .int(1))
        #expect(nbtEntry(root, "commandsEnabled") == .byte(1))
        #expect(nbtEntry(root, "RandomSeed") == .long(-4_401_562_811_211_422_621))
        #expect(nbtEntry(root, "rainLevel") == .float(0.5))
        #expect(
            nbtEntry(root, "lastOpenedWithVersion")
                == .list(.int, [.int(1), .int(21), .int(50), .int(7), .int(0)]))
        #expect(nbtEntry(nbtEntry(root, "abilities"), "mayfly") == .byte(0))

        let stored = try file.encoded()
        #expect(stored == NBTFixtures.bedrockLevel)
    }

    @Test func bedrockHeaderLengthFollowsTheContents() throws {
        var file = try NBTFile(data: NBTFixtures.bedrockLevel)
        try file.root.value.modify(at: [0]) { $0 = .string("Eine deutlich längere Welt") }
        let stored = [UInt8](try file.encoded())

        #expect(Array(stored[0..<4]) == [10, 0, 0, 0])
        let length = stored[4..<8].reversed().reduce(0) { $0 << 8 | Int($1) }
        #expect(length == stored.count - 8)
        #expect(stored.count > NBTFixtures.bedrockLevel.count)

        let reread = try NBTFile(data: Data(stored))
        #expect(reread == file)
    }

    @Test func readsLittleEndianFilesWithoutHeader() throws {
        let file = try NBTFile(data: NBTFixtures.bedrockRaw)
        #expect(file.format == NBTFormat(compression: .none, littleEndian: true))
        #expect(nbtEntry(file.root.value, "LevelName") == .string("Bedrock Welt"))
        let stored = try file.encoded()
        #expect(stored == NBTFixtures.bedrockRaw)
    }

    @Test func bothEditionsAreToldApart() throws {
        let java = try NBTFile(data: NBTFixtures.javaRaw)
        let bedrock = try NBTFile(data: NBTFixtures.bedrockRaw)
        #expect(!java.format.littleEndian)
        #expect(bedrock.format.littleEndian)
        // The other byte order does not yield a tag tree.
        #expect(throws: FileFormatError.self) {
            _ = try NBTReader.readRoot([UInt8](NBTFixtures.javaRaw), littleEndian: true)
        }
        #expect(throws: FileFormatError.self) {
            _ = try NBTReader.readRoot([UInt8](NBTFixtures.bedrockRaw), littleEndian: false)
        }
    }

    // MARK: - Invalid data

    @Test func rejectsDataThatIsNotNBT() {
        let cutOff = Data(NBTFixtures.javaRaw.dropLast())
        let tooLong = NBTFixtures.javaRaw + Data([0])
        let brokenGzip = Data(NBTFixtures.javaGzip.prefix(20))
        let candidates: [Data] = [
            Data(), Data("hello world".utf8), Data([0x1F, 0x8B, 0, 0, 0]), cutOff, tooLong,
            brokenGzip, Data(repeating: 0x0A, count: 64),
        ]
        for data in candidates {
            #expect(throws: FileFormatError.self) { _ = try NBTFile(data: data) }
        }
    }

    @Test func absurdLengthsDoNotAllocate() {
        // A compound with an int array that claims two billion entries.
        let bytes: [UInt8] = [10, 0, 0, 11, 0, 1, 0x61, 0x7F, 0xFF, 0xFF, 0xFF, 0]
        #expect(throws: FileFormatError.self) {
            _ = try NBTReader.readRoot(bytes, littleEndian: false)
        }
    }

    // MARK: - Editing

    @Test func valuesAreParsedInTheirOwnType() throws {
        #expect(try NBTValue.byte(0).parsing("true") == .byte(1))
        #expect(try NBTValue.byte(1).parsing("FALSE") == .byte(0))
        #expect(try NBTValue.short(0).parsing("-32768") == .short(-32768))
        #expect(try NBTValue.int(0).parsing(" -42 ") == .int(-42))
        #expect(try NBTValue.long(0).parsing("9223372036854775807") == .long(.max))
        #expect(try NBTValue.float(0).parsing("0,5") == .float(0.5))
        #expect(try NBTValue.double(0).parsing("1e3") == .double(1000))
        #expect(try NBTValue.string("").parsing(" a b ") == .string(" a b "))
        #expect(try NBTValue.byteArray([]).parsing("1 -2") == .byteArray([1, -2]))
        #expect(try NBTValue.intArray([]).parsing("1, 2;3 4") == .intArray([1, 2, 3, 4]))
        #expect(try NBTValue.longArray([1]).parsing("") == .longArray([]))

        #expect(throws: FileFormatError.self) { _ = try NBTValue.byte(0).parsing("128") }
        #expect(throws: FileFormatError.self) { _ = try NBTValue.int(0).parsing("1.5") }
        #expect(throws: FileFormatError.self) { _ = try NBTValue.double(0).parsing("viel") }
        #expect(throws: FileFormatError.self) { _ = try NBTValue.intArray([]).parsing("1, x") }
        #expect(throws: FileFormatError.self) { _ = try NBTValue.compound([]).parsing("x") }
    }

    @Test func valuesAreShownAsEditableText() {
        #expect(NBTValue.byte(-1).editText == "-1")
        #expect(NBTValue.float(0.25).editText == "0.25")
        #expect(NBTValue.string("a").editText == "a")
        #expect(NBTValue.intArray([1, -2]).editText == "1, -2")
        #expect(NBTValue.compound([]).editText == nil)
        #expect(NBTValue.list(.end, []).editText == nil)
        let huge = NBTValue.longArray(
            Array(repeating: 0, count: NBTValue.maxEditableArrayCount + 1))
        #expect(huge.editText == nil)
        #expect(huge.summary == "4097 Werte")
        #expect(NBTValue.compound([NBTNamedTag(name: "a", value: .int(1))]).summary == "1 Eintrag")
    }

    @Test func tagsAreReachedAndChangedByPath() throws {
        var root = try NBTFile(data: NBTFixtures.javaRaw).root.value
        #expect(root.value(at: [0, 0]) == .string("Survival"))
        #expect(root.value(at: [0, 9, 1]) == .string("paper"))
        #expect(root.value(at: [0, 99]) == nil)
        #expect(root.value(at: [0, 0, 0]) == nil)
        #expect(root.children?.map(\.name) == ["Data"])
        #expect(root.value(at: [0, 9])?.children?.map(\.name) == ["[0]", "[1]"])

        try root.modify(at: [0, 9, 1]) { $0 = .string("purpur") }
        #expect(root.value(at: [0, 9]) == .list(.string, [.string("vanilla"), .string("purpur")]))
        #expect(throws: FileFormatError.self) { try root.modify(at: [0, 99]) { _ in } }
    }

    @Test func entriesCanBeAddedAndRemoved() throws {
        var compound = NBTValue.compound([NBTNamedTag(name: "a", value: .int(1))])
        try compound.appendChild(.string("x"), name: "b")
        #expect(compound.children?.map(\.name) == ["a", "b"])
        #expect(throws: FileFormatError.self) { try compound.appendChild(.int(2), name: "a") }
        #expect(throws: FileFormatError.self) { try compound.appendChild(.int(2), name: "") }
        try compound.removeChild(at: 0)
        #expect(compound == .compound([NBTNamedTag(name: "b", value: .string("x"))]))
        #expect(throws: FileFormatError.self) { try compound.removeChild(at: 5) }

        // An empty list takes the type of its first entry and keeps it.
        var list = NBTValue.list(.end, [])
        try list.appendChild(.int(1))
        #expect(list == .list(.int, [.int(1)]))
        #expect(throws: FileFormatError.self) { try list.appendChild(.string("x")) }
        try list.removeChild(at: 0)
        #expect(list == .list(.int, []))
        try list.appendChild(.string("x"))
        #expect(list == .list(.string, [.string("x")]))
    }

    @Test func everyCreatableTypeHasAnEmptyValueThatCanBeWritten() throws {
        var entries: [NBTNamedTag] = []
        for type in NBTType.creatable {
            let value = try #require(NBTValue.empty(type))
            #expect(value.type == type)
            entries.append(NBTNamedTag(name: type.label, value: value))
        }
        #expect(NBTValue.empty(.end) == nil)
        for format in [NBTFormat.java, NBTFormat.bedrockLevel] {
            let file = NBTFile(format: format, root: NBTNamedTag(name: "", value: .compound(entries)))
            let reread = try NBTFile(data: try file.encoded())
            #expect(reread == file)
        }
    }
}

@Suite struct ZlibTests {
    private var sample: Data {
        var bytes: [UInt8] = []
        var state: UInt32 = 1
        for index in 0..<300_000 {
            state = state &* 1_664_525 &+ 1_013_904_223
            // Half noise, half repetition, to exercise more than one block.
            bytes.append(index % 2 == 0 ? UInt8(truncatingIfNeeded: state >> 24) : UInt8(index % 7))
        }
        return Data(bytes)
    }

    @Test(arguments: [Zlib.Container.gzip, .zlib])
    func compressedDataUnpacksToTheOriginal(container: Zlib.Container) throws {
        let packed = try Zlib.compress(sample, as: container)
        #expect(packed.count < sample.count)
        #expect(packed.first == (container == .gzip ? 0x1F : 0x78))
        let unpacked = try Zlib.decompress(packed)
        #expect(unpacked == sample)
    }

    @Test func emptyDataCanBePacked() throws {
        let packed = try Zlib.compress(Data(), as: .gzip)
        let unpacked = try Zlib.decompress(packed)
        #expect(unpacked.isEmpty)
    }

    @Test func brokenStreamsAreRejected() throws {
        let packed = try Zlib.compress(sample, as: .gzip)
        #expect(throws: Zlib.Failure.self) { _ = try Zlib.decompress(Data(packed.prefix(1000))) }
        #expect(throws: Zlib.Failure.self) { _ = try Zlib.decompress(Data("no stream".utf8)) }
        #expect(throws: Zlib.Failure.self) { _ = try Zlib.decompress(Data()) }
        #expect(throws: Zlib.Failure.self) { _ = try Zlib.decompress(packed, limit: 1000) }
    }
}
