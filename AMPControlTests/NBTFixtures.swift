import Foundation

@testable import AMPControl

/// NBT files written by a reference implementation of the format, the same
/// tag tree in each of the ways Minecraft stores it.
///
/// Java: a root compound holding "Data" with LevelName, hardcore, GameType,
/// SpawnY, Time, BorderSize, rainLevel, version, motd, ServerBrands, Empty,
/// Bytes, Ints, Longs, Pos and GameRules. Bedrock: LevelName, GameType,
/// Difficulty, commandsEnabled, RandomSeed, rainLevel, lastOpenedWithVersion
/// and abilities directly in the root.
enum NBTFixtures {
    private static func data(_ base64: String) -> Data {
        Data(base64Encoded: base64) ?? Data()
    }

    /// Java Edition, big-endian, not compressed.
    static let javaRaw = data(
            "CgAACgAERGF0YQgACUxldmVsTmFtZQAIU3Vydml2YWwBAAhoYXJkY29yZQADAAhHYW1lVHlwZQAAAAADAAZTcGF3" +
            "blkAAABABAAEVGltZQAAABy+mRoUBgAKQm9yZGVyU2l6ZUGMnDcAAAAABQAJcmFpbkxldmVsPoAAAAIAB3ZlcnNp" +
            "b25KvQgABG1vdGQAFkdyw7zDn2Ug7aC87b6uIMCAIEVuZGUJAAxTZXJ2ZXJCcmFuZHMIAAAAAgAHdmFuaWxsYQAF" +
            "cGFwZXIJAAVFbXB0eQAAAAAABwAFQnl0ZXMAAAADAf4DCwAESW50cwAAAAMAAAAB/////gAEk+AMAAVMb25ncwAA" +
            "AAMAAAAAAAAAAf/////////+AAAAASoF8gAJAANQb3MGAAAAAz/4AAAAAAAAQFAAAAAAAADACgAAAAAAAAoACUdh" +
            "bWVSdWxlcwgADWtlZXBJbnZlbnRvcnkABWZhbHNlAAAA")

    /// The same, gzip-compressed like level.dat and player files.
    static let javaGzip = data(
            "H4sIAAAAAAAC/zVQO07DQBB9wd7ENqFDFIjCNReggxARRUERinAayhUewMLetdaOkalyADoqJCQ4AScIUaRchAuk" +
            "oaKK2Y1hpNF83nua0fMAD/YZz7kDd0gFxRc8ITjBRBVRweMGnDuuwmupCBacvgbHZUrQYaEZpPxBXOm+Y8MeR4nZ" +
            "H8xf9neb8LpShaSC6JFOn16PjIDBVTwSmyvHU2ALrYJUFklx/unATmQeYq+vlrPlG/mr99lq/uEvpn5PhOSiHZDS" +
            "7K7iIswc1GouojjmYClPSblgvSTNS3MKLbBumVNm/mysrW3YA5FvJp2NqqrWsJ+/2mBDKW7/9/jDqg2u+0P2DRfW" +
            "SGZNQzn5qTmdUV0XXl09uMaYy0lM+rWde6J0IAoSuVQl2A2PM2PMLzAFEcFrAQAA")

    /// The same in a zlib stream.
    static let javaZlib = data(
            "eJw1UDtOw0AQfcHexDahQxSIwjUXoIMQEUVBEYpwGsoVHsDC3rXWjpGpcgA6KiQkOAEnCFGkXIQLpKGiitmNYaTR" +
            "fN57mtHzAA/2Gc+5A3dIBcUXPCE4wUQVUcHjBpw7rsJrqQgWnL4Gx2VK0GGhGaT8QVzpvmPDHkeJ2R/MX/Z3m/C6" +
            "UoWkguiRTp9ej4yAwVU8Epsrx1NgC62CVBZJcf7pwE5kHmKvr5az5Rv5q/fZav7hL6Z+T4Tkoh2Q0uyu4iLMHNRq" +
            "LqI45mApT0m5YL0kzUtzCi2wbplTZv5srK1t2AORbyadjaqq1rCfv9pgQylu//f4w6oNrvtD9g0X1khmTUM5+ak5" +
            "nVFdF15dPbjGmMtJTPq1nXuidCAKErlUJdgNjzNjzC/kz2Eo")

    /// Bedrock Edition's level.dat: version 10, length, little-endian tags.
    static let bedrockLevel = data(
            "CgAAAM0AAAAKAAAICQBMZXZlbE5hbWUMAEJlZHJvY2sgV2VsdAMIAEdhbWVUeXBlAQAAAAMKAERpZmZpY3VsdHkC" +
            "AAAAAQ8AY29tbWFuZHNFbmFibGVkAQQKAFJhbmRvbVNlZWRjZCyV8YHqwgUJAHJhaW5MZXZlbAAAAD8JFQBsYXN0" +
            "T3BlbmVkV2l0aFZlcnNpb24DBQAAAAEAAAAVAAAAMgAAAAcAAAAAAAAACgkAYWJpbGl0aWVzBQgAZmx5U3BlZWTN" +
            "zEw9AQYAbWF5Zmx5AAAA")

    /// The Bedrock tags without the header.
    static let bedrockRaw = data(
            "CgAACAkATGV2ZWxOYW1lDABCZWRyb2NrIFdlbHQDCABHYW1lVHlwZQEAAAADCgBEaWZmaWN1bHR5AgAAAAEPAGNv" +
            "bW1hbmRzRW5hYmxlZAEECgBSYW5kb21TZWVkY2QslfGB6sIFCQByYWluTGV2ZWwAAAA/CRUAbGFzdE9wZW5lZFdp" +
            "dGhWZXJzaW9uAwUAAAABAAAAFQAAADIAAAAHAAAAAAAAAAoJAGFiaWxpdGllcwUIAGZseVNwZWVkzcxMPQEGAG1h" +
            "eWZseQAAAA==")
}
