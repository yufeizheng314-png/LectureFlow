import Foundation

enum LectureAudioError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

/// PCM16 mono WAV. The capture queue is the sole writer. No whole-recording arrays.
/// A crashed file can be repaired from its actual PCM payload, even if the last
/// header update did not reach disk. Closed recordings are never overwritten.
final class LecturePCMStore {
    static let headerSize = 44
    private let handle: FileHandle
    private(set) var frames = 0
    private var lastSyncedFrames = 0
    private var closed = false

    init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw LectureAudioError.message("录音文件已存在；请为每次录制创建新的文件名。")
        }
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(frames: 0)) else {
            throw LectureAudioError.message("无法创建录音文件，请检查可用储存空间。")
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ samples: [Float]) throws {
        guard !closed else { throw LectureAudioError.message("录音文件已经关闭。") }
        guard samples.count <= LectureAudioWindowing.sampleRate * 2,
              frames <= (Int(UInt32.max) - 36) / 2 - samples.count else {
            throw LectureAudioError.message("录音缓冲或 WAV 大小超过安全上限。")
        }
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let value = Int16((max(-1, min(1, finite)) * 32767).rounded())
            let bits = UInt16(bitPattern: value)
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        try handle.write(contentsOf: bytes)
        frames += samples.count
        if frames - lastSyncedFrames >= LectureAudioWindowing.sampleRate {
            try updateHeader()
            try handle.synchronize()
            lastSyncedFrames = frames
        }
    }

    func finish() throws {
        guard !closed else { return }
        var failure: Error?
        do { try updateHeader(); try handle.synchronize() } catch { failure = error }
        do { try handle.close(); closed = true } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    private func updateHeader() throws {
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(frames: frames))
        try handle.seek(toOffset: UInt64(Self.headerSize + frames * 2))
    }

    static func read(url: URL, from start: Int, through end: Int) throws -> [Float] {
        guard start >= 0, end > start, end - start <= LectureAudioWindowing.maximumReadFrames else {
            throw LectureAudioError.message("无效的识别音频窗口。")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64(headerSize + start * 2))
        let byteCount = (end - start) * 2
        guard let data = try file.read(upToCount: byteCount), data.count == byteCount else {
            throw LectureAudioError.message("录音文件不完整；原音已保留，请稍后恢复识别。")
        }
        return data.withUnsafeBytes { raw -> [Float] in
            let bytes = raw.bindMemory(to: UInt8.self)
            return stride(from: 0, to: byteCount, by: 2).map { i in
                Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32768
            }
        }
    }

    /// Only called for our own checkpointed, inactive files, never imported audio.
    static func repairClosedFile(at url: URL) throws -> Int {
        let file = try FileHandle(forUpdating: url)
        var failure: Error?
        var count = 0
        do {
            let size = try file.seekToEnd()
            guard size >= UInt64(headerSize), size <= UInt64(UInt32.max) else {
                throw LectureAudioError.message("无法恢复此录音文件的 WAV 数据。")
            }
            try file.seek(toOffset: 0)
            guard let oldHeader = try file.read(upToCount: headerSize),
                  oldHeader.count == headerSize,
                  oldHeader.prefix(4) == Data("RIFF".utf8),
                  oldHeader.subdata(in: 8..<12) == Data("WAVE".utf8),
                  oldHeader.subdata(in: 20..<36) == header(frames: 0).subdata(in: 20..<36),
                  oldHeader.subdata(in: 36..<40) == Data("data".utf8) else {
                throw LectureAudioError.message("只支持恢复 LectureFlow 的 16 kHz 单声道 PCM 录音。")
            }
            count = (Int(size) - headerSize) / 2
            try file.truncate(atOffset: UInt64(headerSize + count * 2))
            try file.seek(toOffset: 0)
            try file.write(contentsOf: header(frames: count))
            try file.synchronize()
        } catch { failure = error }
        do { try file.close() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
        return count
    }

    private static func header(frames: Int) -> Data {
        var result = Data()
        func text(_ text: String) { result.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) {
            result.append(UInt8(truncatingIfNeeded: value)); result.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        let bytes = UInt32(frames * 2)
        text("RIFF"); u32(36 + bytes); text("WAVE"); text("fmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        text("data"); u32(bytes)
        return result
    }
}
