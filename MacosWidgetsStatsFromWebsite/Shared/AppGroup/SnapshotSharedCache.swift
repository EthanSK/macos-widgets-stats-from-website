//
//  SnapshotSharedCache.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  In-memory cross-process cache for latest Snapshot-mode PNG bytes.
//

import Darwin
import Foundation

@_silgen_name("shm_open")
private func c_shm_open(_ name: UnsafePointer<CChar>, _ oflag: CInt, _ mode: mode_t) -> CInt

@_silgen_name("shm_unlink")
private func c_shm_unlink(_ name: UnsafePointer<CChar>) -> CInt

enum SnapshotSharedCacheError: LocalizedError {
    case snapshotTooLarge(Int)
    case posix(operation: String, code: Int32)
    case invalidMapping

    var errorDescription: String? {
        switch self {
        case .snapshotTooLarge(let count):
            return "Snapshot is too large to cache in memory (\(count) bytes)."
        case .posix(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))."
        case .invalidMapping:
            return "Snapshot cache mapping is invalid."
        }
    }
}

final class SnapshotSharedCache {
    static let shared = SnapshotSharedCache()

    private let maximumSnapshotBytes = 8 * 1024 * 1024
    private let magic = UInt32(0x4d535753)
    private let headerSize = MemoryLayout<UInt32>.size * 2

    private init() {}

    func cacheKey(for trackerID: UUID) -> String {
        "shm:\(sharedMemoryName(for: trackerID))"
    }

    @discardableResult
    func store(_ data: Data, for trackerID: UUID) throws -> String {
        guard data.count <= maximumSnapshotBytes else {
            throw SnapshotSharedCacheError.snapshotTooLarge(data.count)
        }

        let name = sharedMemoryName(for: trackerID)
        let fd = name.withCString { c_shm_open($0, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR)) }
        guard fd != -1 else {
            throw SnapshotSharedCacheError.posix(operation: "shm_open", code: errno)
        }
        defer { close(fd) }

        let totalSize = headerSize + data.count
        guard ftruncate(fd, off_t(totalSize)) != -1 else {
            throw SnapshotSharedCacheError.posix(operation: "ftruncate", code: errno)
        }

        let rawPointer = mmap(nil, totalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard rawPointer != MAP_FAILED, let rawPointer else {
            throw SnapshotSharedCacheError.posix(operation: "mmap", code: errno)
        }
        defer {
            msync(rawPointer, totalSize, MS_SYNC)
            munmap(rawPointer, totalSize)
        }

        rawPointer.storeBytes(of: magic.littleEndian, as: UInt32.self)
        rawPointer.advanced(by: MemoryLayout<UInt32>.size)
            .storeBytes(of: UInt32(data.count).littleEndian, as: UInt32.self)

        data.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else {
                return
            }
            memcpy(rawPointer.advanced(by: headerSize), source, data.count)
        }

        return cacheKey(for: trackerID)
    }

    func data(for trackerID: UUID) -> Data? {
        let name = sharedMemoryName(for: trackerID)
        let fd = name.withCString { c_shm_open($0, O_RDONLY, 0) }
        guard fd != -1 else {
            return nil
        }
        defer { close(fd) }

        var statBuffer = stat()
        guard fstat(fd, &statBuffer) != -1 else {
            return nil
        }

        let totalSize = Int(statBuffer.st_size)
        guard totalSize >= headerSize else {
            return nil
        }

        let rawPointer = mmap(nil, totalSize, PROT_READ, MAP_SHARED, fd, 0)
        guard rawPointer != MAP_FAILED, let rawPointer else {
            return nil
        }
        defer { munmap(rawPointer, totalSize) }

        let storedMagic = UInt32(littleEndian: rawPointer.load(as: UInt32.self))
        guard storedMagic == magic else {
            return nil
        }

        let countPointer = rawPointer.advanced(by: MemoryLayout<UInt32>.size)
        let byteCount = Int(UInt32(littleEndian: countPointer.load(as: UInt32.self)))
        guard byteCount > 0, byteCount <= totalSize - headerSize else {
            return nil
        }

        return Data(bytes: rawPointer.advanced(by: headerSize), count: byteCount)
    }

    func remove(for trackerID: UUID) {
        _ = sharedMemoryName(for: trackerID).withCString {
            c_shm_unlink($0)
        }
    }

    private func sharedMemoryName(for trackerID: UUID) -> String {
        let compactID = trackerID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "/macos_stats_widget_\(compactID)"
    }
}
