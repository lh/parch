import CryptoKit
import Foundation

enum FileHasher {
    static func sha256(of url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .ENOENT)
        }
        defer { close(fd) }

        var hasher = SHA256()
        let bufferSize = 1_048_576
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = read(fd, buffer, bufferSize)
            if bytesRead < 0 {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: bytesRead))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
