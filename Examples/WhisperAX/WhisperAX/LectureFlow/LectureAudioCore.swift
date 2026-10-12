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
    static let contextFrames = sampleRate * 2
    static let updateFrames = sampleRate * 2
    static let maximumReadFrames = coreFrames + 2 * contextFrames

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
}
