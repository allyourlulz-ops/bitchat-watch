//
// CompressionUtil.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import struct Foundation.Data
#if canImport(Compression)
import Compression
#endif

struct CompressionUtil {
    // Compression threshold - don't compress if data is smaller than this
    static let compressionThreshold = Constants.compressionThresholdBytes // bytes
    
    // Compress data using zlib algorithm (most compatible)
    static func compress(_ data: Data) -> Data? {
        #if !canImport(Compression)
        return nil  // [bitchat-watch] Linux typecheck harness only; Apple platforms use Compression.framework
        #else
        // Skip compression for small data
        guard data.count >= compressionThreshold else { return nil }
        
        let maxCompressedSize = data.count + (data.count / 255) + 16
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: maxCompressedSize)
        defer { destinationBuffer.deallocate() }
        
        let compressedSize = data.withUnsafeBytes { sourceBuffer in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer, data.count,
                sourcePtr, data.count,
                nil, COMPRESSION_ZLIB
            )
        }
        
        guard compressedSize > 0 && compressedSize < data.count else { return nil }
        
        return Data(bytes: destinationBuffer, count: compressedSize)
        #endif
    }
    
    // Decompress zlib compressed data
    static func decompress(_ compressedData: Data, originalSize: Int) -> Data? {
        #if !canImport(Compression)
        return nil
        #else
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: originalSize)
        defer { destinationBuffer.deallocate() }
        
        let decompressedSize = compressedData.withUnsafeBytes { sourceBuffer in
            guard let sourcePtr = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, originalSize,
                sourcePtr, compressedData.count,
                nil, COMPRESSION_ZLIB
            )
        }
        
        guard decompressedSize > 0 else { return nil }
        
        return Data(bytes: destinationBuffer, count: decompressedSize)
        #endif
    }
    
    // Helper to check if compression is worth it
    static func shouldCompress(_ data: Data) -> Bool {
        // Don't compress if:
        // 1. Data is too small
        // 2. Data appears to be already compressed (high entropy)
        guard data.count >= compressionThreshold else { return false }

        // Quick uniqueness check — a high diversity of bytes usually means the
        // payload is already compressed. We only need to know how many unique
        // values exist rather than keeping full frequency counts.
        let uniqueByteCount = Set(data).count
        let sampleSize = min(data.count, 256)
        let uniqueByteRatio = Double(uniqueByteCount) / Double(sampleSize)
        return uniqueByteRatio < 0.9 // Compress if less than 90% unique bytes
    }
}
