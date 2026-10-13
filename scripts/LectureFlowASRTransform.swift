import Foundation

// A smoke-test bridge to the production audio code; no normalization formula
// is reproduced here. Input is the script's canonical 16 kHz PCM16 mono WAV.
@main
struct LectureFlowASRTransform {
    struct Window: Codable {
        let startFrame: Int
        let endFrame: Int
        let gain: Double
        let aboveNoiseFloor: Bool
    }
    struct Report: Codable {
        let synthetic: Bool
        let offDevice: Bool
        let sampleRate: Int
        let frames: Int
        let method: String
        let windows: [Window]
    }

    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            throw LectureAudioError.message("Usage: asr-transform <input.wav> <new-output.wav> <metadata.json>")
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        guard input != output else { throw LectureAudioError.message("Source and inference copy must differ") }
        let source = try FileHandle(forReadingFrom: input)
        let size = try source.seekToEnd()
        try source.seek(toOffset: 0)
        let header = try source.read(upToCount: LecturePCMStore.headerSize) ?? Data()
        try source.close()
        func u16(_ index: Int) -> UInt16 {
            UInt16(header[index]) | UInt16(header[index + 1]) << 8
        }
        func u32(_ index: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[index + $1]) << (8 * $1) }
        }
        guard header.count == LecturePCMStore.headerSize, size >= 44, size <= 10_000_000,
              header.prefix(4) == Data("RIFF".utf8), header.subdata(in: 8..<12) == Data("WAVE".utf8),
              header.subdata(in: 12..<16) == Data("fmt ".utf8), u32(16) == 16,
              u16(20) == 1, u16(22) == 1, u32(24) == 16_000, u16(32) == 2, u16(34) == 16,
              header.subdata(in: 36..<40) == Data("data".utf8), UInt64(u32(40)) == size - 44,
              (size - 44) % 2 == 0, size > 44 else {
            throw LectureAudioError.message("Input must be a canonical nonempty PCM16 mono 16 kHz WAV")
        }
        let frames = Int((size - 44) / 2)
        let writer = try LecturePCMStore(url: output)
        var windows: [Window] = []
        do {
            var start = 0
            while start < frames {
                let end = min(frames, start + LectureAudioWindowing.maximumReadFrames)
                let samples = try LecturePCMStore.read(url: input, from: start, through: end)
                let prepared = try LectureAudioNormalization.prepareForInference(samples)
                guard prepared.samples.count == samples.count else {
                    throw LectureAudioError.message("Production normalization changed the frame count")
                }
                windows.append(Window(startFrame: start, endFrame: end, gain: prepared.gain,
                                      aboveNoiseFloor: prepared.aboveNoiseFloor))
                let writeLimit = LectureAudioWindowing.sampleRate * 2
                for offset in stride(from: 0, to: prepared.samples.count, by: writeLimit) {
                    try writer.append(Array(prepared.samples[offset..<min(offset + writeLimit, prepared.samples.count)]))
                }
                start = end
            }
            try writer.finish()
        } catch {
            try? writer.finish()
            throw error
        }
        let report = Report(synthetic: true, offDevice: true, sampleRate: 16_000, frames: frames,
                            method: "Production LectureAudioNormalization.prepareForInference + LecturePCMStore; bounded nonoverlapping file windows, not microphone capture/ownership testing",
                            windows: windows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
    }
}
