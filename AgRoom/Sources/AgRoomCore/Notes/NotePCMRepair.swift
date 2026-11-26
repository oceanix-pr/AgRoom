import Foundation
import AVFoundation

// Container repair adapted from Memonta (MIT); never modifies the original.
enum NotePCMRepair {
    static func playableCopy(_ original: URL) async -> URL? {
        guard ["caf", "wav"].contains(original.pathExtension.lowercased()) else { return nil }
        let copy = original.deletingLastPathComponent().appendingPathComponent(".repaired-" + UUID().uuidString).appendingPathExtension(original.pathExtension)
        var accepted = false
        defer { if !accepted { try? FileManager.default.removeItem(at: copy) } }
        do { try FileManager.default.copyItem(at: original, to: copy) } catch { return nil }
        guard repairPCMContainerHeader(at: copy), let duration = try? await AVURLAsset(url: copy).load(.duration),
              duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        accepted = true
        return copy
    }
    static func repairPCMContainerHeader(at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "wav" || ext == "caf" else { return false }
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 44,
              let handle = FileHandle(forUpdatingAtPath: url.path) else { return false }
        defer { try? handle.close() }
        // 该 SDK 中 read(upToCount:) 返回非可选 Data（读到 EOF 返回空 Data）
        guard let header = try? handle.read(upToCount: 4096), header.count >= 12 else {
            return false
        }
        if ext == "wav" {
            return patchWAVHeader(header, fileSize: size, handle: handle)
        } else {
            return patchCAFHeader(header, fileSize: size, handle: handle)
        }
    }

    /// 修补 WAV 头：逐 chunk 定位 data 块，回写 RIFF 总长与 data 长度（均小端）
    private static func patchWAVHeader(_ header: Data, fileSize: Int, handle: FileHandle) -> Bool {
        func le32(_ d: Data, _ o: Int) -> Int {
            Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8
                | Int(d[d.startIndex + o + 2]) << 16 | Int(d[d.startIndex + o + 3]) << 24
        }
        guard header.subdata(in: 0..<4) == Data("RIFF".utf8),
              header.subdata(in: 8..<12) == Data("WAVE".utf8),
              fileSize - 8 <= Int(UInt32.max) else { return false }
        var offset = 12
        while offset + 8 <= header.count {
            let chunkID = header.subdata(in: offset..<(offset + 4))
            let chunkSize = le32(header, offset + 4)
            if chunkID == Data("data".utf8) {
                let dataStart = offset + 8
                guard fileSize >= dataStart else { return false }
                do {
                    try handle.seek(toOffset: 4)
                    try handle.write(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Data($0) })
                    try handle.seek(toOffset: UInt64(offset + 4))
                    try handle.write(contentsOf: withUnsafeBytes(of: UInt32(fileSize - dataStart).littleEndian) { Data($0) })
                    return true
                } catch {
                    return false
                }
            }
            // RIFF chunk 按 2 字节对齐；size 为占位 0 时仍前进 8 字节，循环可终止
            offset += 8 + chunkSize + (chunkSize & 1)
        }
        return false
    }

    /// 修补 CAF 头：逐 chunk 定位 data 块，回写块长度（8 字节大端）
    private static func patchCAFHeader(_ header: Data, fileSize: Int, handle: FileHandle) -> Bool {
        func be64(_ d: Data, _ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 {
                v = (v << 8) | UInt64(d[d.startIndex + o + i])
            }
            return v
        }
        guard header.subdata(in: 0..<4) == Data("caff".utf8) else { return false }
        var offset = 8
        while offset + 12 <= header.count {
            let chunkType = header.subdata(in: offset..<(offset + 4))
            let chunkSize = be64(header, offset + 4)
            if chunkType == Data("data".utf8) {
                let dataStart = offset + 12
                guard fileSize >= dataStart else { return false }
                do {
                    try handle.seek(toOffset: UInt64(offset + 4))
                    try handle.write(contentsOf: withUnsafeBytes(of: UInt64(fileSize - dataStart).bigEndian) { Data($0) })
                    return true
                } catch {
                    return false
                }
            }
            // 前置 chunk 声称的长度超过文件总长 → 头部已损坏，放弃
            guard chunkSize <= UInt64(fileSize) else { return false }
            offset += 12 + Int(chunkSize)
        }
        return false
    }

}
