import Foundation

/// Source times include the lesson's offset; IDs remain stable across recovery.
struct LectureTranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let start: Double
    let end: Double
    let text: String
}

struct LectureRecognizedWord: Sendable {
    let start: Double
    let end: Double
    let text: String
}

enum LectureDecodingLanguage {
    static func validate(_ language: String) throws -> String {
        guard language == "en" || language == "zh" else {
            throw LectureAudioError.message("转写语言仅支持英语或中文。")
        }
        return language
    }
}

struct LectureInferenceAudio: Sendable {
    let samples: [Float]
    let gain: Double
    let aboveNoiseFloor: Bool
}

/// A bounded inference-only gain. This never rewrites the original PCM/WAV.
/// The floor is an amplitude guard, not a speech/noise classifier.
enum LectureAudioNormalization {
    static let maximumGain = 8.0
    static let targetRMS = 0.08
    static let peakLimit = 0.95
    static let minimumRMS = 0.0005
    static let minimumPeak = 0.0015

    static func prepareForInference(_ samples: [Float]) throws -> LectureInferenceAudio {
        guard samples.count <= LectureAudioWindowing.maximumReadFrames else {
            throw LectureAudioError.message("识别音频窗口超过安全上限。")
        }
        guard !samples.isEmpty else {
            return LectureInferenceAudio(samples: [], gain: 1, aboveNoiseFloor: false)
        }
        var squareSum = 0.0
        var peak = 0.0
        for sample in samples {
            guard sample.isFinite else {
                throw LectureAudioError.message("识别音频包含无效采样；原音保留，未提交此窗口。")
            }
            let value = Double(sample)
            squareSum += value * value
            peak = max(peak, abs(value))
        }
        let rms = sqrt(squareSum / Double(samples.count))
        guard rms >= minimumRMS, peak >= minimumPeak else {
            // Do not turn silence or near-zero input into apparent speech.
            return LectureInferenceAudio(samples: samples, gain: 1, aboveNoiseFloor: false)
        }
        let gain = min(maximumGain, min(max(1, targetRMS / rms), peakLimit / peak))
        return LectureInferenceAudio(samples: samples.map { Float(Double($0) * gain) },
                                     gain: gain, aboveNoiseFloor: true)
    }
}

struct LectureAudioWindow: Equatable, Sendable {
    let readStart: Int
    let readEnd: Int
    let ownedStart: Int
    let ownedEnd: Int
    let canCommit: Bool
}

/// Fixed ownership intervals, with context on both sides. No silence is required.
/// Only the current bounded window is decoded; the recording on disk is the backlog.
enum LectureAudioWindowing {
    static let sampleRate = 16_000
    static let coreFrames = sampleRate * 8
    static let contextFrames = sampleRate * 4
    static let updateFrames = sampleRate * 2
    static let maximumReadFrames = coreFrames + 2 * contextFrames

    /// Word alignment is relative to the whole read window, including context.
    /// Invalid decoder timings must not turn a failed window into consumed silence.
    static func validateWordTimings(_ words: [LectureRecognizedWord], sampleCount: Int) throws {
        guard sampleCount >= 0, sampleCount <= maximumReadFrames else {
            throw LectureAudioError.message("识别音频窗口超过安全上限；此窗口未提交，原音保留。")
        }
        // WhisperKit timings arrive as Float; avoid rejecting its rounded boundary.
        let latestEnd = Double(sampleCount) / Double(sampleRate) + 0.2 + 0.000001
        for word in words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard sampleCount > 0, word.start.isFinite, word.end.isFinite,
                  word.start >= 0, word.end >= word.start, word.end <= latestEnd else {
                throw LectureAudioError.message("识别时间戳无效或超出音频范围；此窗口未提交，原音保留，可稍后补转写。")
            }
        }
    }

    static func next(committed: Int, available: Int, closed: Bool) -> LectureAudioWindow? {
        guard committed >= 0, available > committed else { return nil }
        let ownedEnd = min(available, committed + coreFrames)
        let ready = closed || available >= committed + coreFrames + contextFrames
        return LectureAudioWindow(
            readStart: max(0, committed - contextFrames),
            readEnd: min(available, committed + coreFrames + contextFrames),
            ownedStart: committed,
            ownedEnd: ownedEnd,
            canCommit: ready
        )
    }

    static func segment(words: [LectureRecognizedWord], window: LectureAudioWindow,
                        recordingID: String, baseOffset: Double) -> LectureTranscriptSegment? {
        let rate = Double(sampleRate)
        let readOffset = Double(window.readStart) / rate
        let ownedStart = Double(window.ownedStart) / rate
        let ownedEnd = Double(window.ownedEnd) / rate
        let selected = words.filter { word in
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end >= word.start else { return false }
            let center = readOffset + (word.start + word.end) / 2
            return center >= ownedStart && center < ownedEnd
        }
        let text = selected.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = selected.first, let last = selected.last, !text.isEmpty else { return nil }
        return LectureTranscriptSegment(
            id: recordingID + ":" + String(window.ownedStart),
            start: baseOffset + max(ownedStart, readOffset + first.start),
            end: baseOffset + min(ownedEnd, readOffset + last.end),
            text: text
        )
    }
}

struct LectureAudioCheckpoint: Codable, Sendable {
    var recordingID: String
    var baseOffset: Double
    var committedFrames: Int
    var segments: [LectureTranscriptSegment]
    var captureClosed: Bool
    var interrupted: Bool
    // Optional so checkpoints written before language selection still decode.
    var language: String? = nil

    func languageForRecovery(fallback: String) throws -> String {
        try LectureDecodingLanguage.validate(language ?? fallback)
    }
}
