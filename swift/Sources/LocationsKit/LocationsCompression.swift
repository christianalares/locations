import Foundation
import zlib

enum LocationsCompressionError: Error {
    case invalidData
}

extension Data {
    func locationsGzipped() throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8,
            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw LocationsCompressionError.invalidData
        }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(compressBound(uLong(count))) + 32)
        let size = output.count
        let result = withUnsafeBytes { input in
            output.withUnsafeMutableBytes { bytes in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(count)
                stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(size)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { throw LocationsCompressionError.invalidData }

        return output.prefix(Int(stream.total_out))
    }

    func locationsGunzip() throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw LocationsCompressionError.invalidData
        }
        defer { inflateEnd(&stream) }

        return try withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                stream.avail_out = uInt(chunk.count)
                let result = chunk.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    return inflate(&stream, Z_NO_FLUSH)
                }
                output.append(contentsOf: chunk.prefix(chunk.count - Int(stream.avail_out)))
                guard output.count <= 32_000_000 else { throw LocationsCompressionError.invalidData }
                if result == Z_STREAM_END { return output }
                guard result == Z_OK else { throw LocationsCompressionError.invalidData }
            }
        }
    }
}
