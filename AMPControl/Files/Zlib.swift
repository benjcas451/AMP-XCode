import Foundation
import zlib

/// gzip and zlib streams, as Minecraft uses them for its NBT files.
enum Zlib {
    enum Container: Sendable {
        case gzip, zlib
    }

    struct Failure: Error {}

    /// Unpacks a gzip or zlib stream; which of the two is detected.
    /// Throws when the result would exceed `limit` bytes.
    static func decompress(_ data: Data, limit: Int = 64 * 1024 * 1024) throws -> Data {
        var stream = z_stream()
        // 32 on top of the window size: accept both headers.
        guard
            inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
                == Z_OK
        else { throw Failure() }
        defer { inflateEnd(&stream) }

        var input = [UInt8](data)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let bufferSize = buffer.count
        var output = Data()

        try input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = UInt32(source.count)
            while true {
                var produced = 0
                let status = buffer.withUnsafeMutableBufferPointer { target -> Int32 in
                    stream.next_out = target.baseAddress
                    stream.avail_out = UInt32(bufferSize)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    produced = bufferSize - Int(stream.avail_out)
                    return status
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw Failure() }
                output.append(contentsOf: buffer[0..<produced])
                if output.count > limit { throw Failure() }
                if status == Z_STREAM_END { break }
                // Neither progress nor an end: the stream is cut off.
                if produced == 0 && stream.avail_in == 0 { throw Failure() }
            }
        }
        return output
    }

    static func compress(_ data: Data, as container: Container) throws -> Data {
        var stream = z_stream()
        // 16 on top of the window size: write a gzip header instead of zlib's.
        let windowBits: Int32 = container == .gzip ? 15 + 16 : 15
        guard
            deflateInit2_(
                &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY,
                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw Failure() }
        defer { deflateEnd(&stream) }

        var input = [UInt8](data)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let bufferSize = buffer.count
        var output = Data()

        try input.withUnsafeMutableBufferPointer { source in
            stream.next_in = source.baseAddress
            stream.avail_in = UInt32(source.count)
            while true {
                var produced = 0
                let status = buffer.withUnsafeMutableBufferPointer { target -> Int32 in
                    stream.next_out = target.baseAddress
                    stream.avail_out = UInt32(bufferSize)
                    let status = deflate(&stream, Z_FINISH)
                    produced = bufferSize - Int(stream.avail_out)
                    return status
                }
                // Z_BUF_ERROR only says that the output buffer was full.
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw Failure()
                }
                output.append(contentsOf: buffer[0..<produced])
                if status == Z_STREAM_END { break }
                if produced == 0 { throw Failure() }
            }
        }
        return output
    }
}
