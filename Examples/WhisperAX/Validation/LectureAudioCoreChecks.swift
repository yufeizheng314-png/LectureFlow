import Foundation

@main
struct LectureAudioCoreChecks {
    static func main() throws {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }
        func rejects(_ operation: () throws -> Void) -> Bool {
            do { try operation(); return false } catch { return true }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audio-test.wav")
        let store = try LecturePCMStore(url: url)
        try store.append([0, 0.5, -0.5, 1, -1])
        let live = try LecturePCMStore.read(url: url, from: 0, through: 5)
        expect(live.count == 5 && abs(live[1] - 0.5) < 0.001, "live reads must see written payload before close")
        try store.finish()
        let wav = try Data(contentsOf: url)
        expect(wav.count == 54, "five PCM16 samples plus the 44-byte header")
        expect(Array(wav[40..<44]) == [10, 0, 0, 0], "WAV data length finalized")
        expect(rejects { try store.append([1]) }, "closed file rejects append")
        expect(rejects { _ = try LecturePCMStore(url: url) }, "existing audio is never overwritten")
        expect(rejects { _ = try LecturePCMStore.read(url: url, from: 0, through: 6) }, "short disk reads are errors")
        expect(rejects { _ = try LecturePCMStore.read(url: url, from: 0, through: LectureAudioWindowing.maximumReadFrames + 1) }, "no unbounded read")
        let crash = directory.appendingPathComponent("crash.wav")
        var stale = wav
        stale.replaceSubrange(4..<8, with: [36, 0, 0, 0])
        stale.replaceSubrange(40..<44, with: [0, 0, 0, 0])
        stale.append(255) // torn final half-sample
        try stale.write(to: crash)
        let restoredCount = try LecturePCMStore.repairClosedFile(at: crash)
        expect(restoredCount == 5, "recovery measures actual payload, not the stale header")
        expect(try Data(contentsOf: crash) == wav, "repair preserves complete samples and removes torn byte")
        let invalid = directory.appendingPathComponent("foreign.wav")
        var foreign = wav
        foreign[22] = 2 // two channels is not the app's recording format
        try foreign.write(to: invalid)
        expect(rejects { _ = try LecturePCMStore.repairClosedFile(at: invalid) }, "foreign WAV is not silently rewritten")

        let rate = LectureAudioWindowing.sampleRate
        let partial = LectureAudioWindowing.next(committed: 0, available: 2 * rate, closed: false)!
        expect(!partial.canCommit && partial.ownedEnd == 2 * rate, "live text starts without waiting for silence")
        let first = LectureAudioWindowing.next(committed: 0, available: 10 * rate, closed: false)!
        expect(first.canCommit && first.ownedEnd == 8 * rate, "continuous speech commits on time rather than VAD")
        let second = LectureAudioWindowing.next(committed: 8 * rate, available: 18 * rate, closed: false)!
        expect(second.readStart == 6 * rate && second.readEnd == 18 * rate, "both sides retain context")
        var cursor = 0
        let total = 90 * 60 * rate + 17
        var windows = 0
        while let window = LectureAudioWindowing.next(committed: cursor, available: total, closed: true) {
            precondition(window.ownedStart == cursor && window.ownedEnd > cursor)
            precondition(window.readEnd - window.readStart <= LectureAudioWindowing.maximumReadFrames)
            cursor = window.ownedEnd
            windows += 1
        }
        expect(cursor == total && windows == 676, "90-minute backlog is complete with bounded windows and a 17-sample tail")
        expect(LectureAudioWindowing.next(committed: total, available: total, closed: true) == nil, "repeated stop has no duplicate final window")

        let words = [LectureRecognizedWord(start: 7.7, end: 8.1, text: " before"),
                     LectureRecognizedWord(start: 8.0, end: 8.2, text: " after")]
        let a = LectureAudioWindowing.segment(words: words, window: first, recordingID: "file-A", baseOffset: 100)!
        // Same absolute words in the second window's local time coordinate.
        let shifted = words.map { LectureRecognizedWord(start: $0.start - 6, end: $0.end - 6, text: $0.text) }
        let b = LectureAudioWindowing.segment(words: shifted, window: second, recordingID: "file-A", baseOffset: 100)!
        expect(a.text == "before" && b.text == "after", "overlap belongs to exactly one core interval")
        expect(a.end <= b.start && b.start >= 108, "lesson offset is applied without time reversal")
        let replay = LectureAudioWindowing.segment(words: words, window: first, recordingID: "file-A", baseOffset: 100)!
        expect(replay.id == a.id, "recovery reuses segment identities")
        let nextFile = LectureAudioWindowing.segment(words: words, window: first, recordingID: "file-B", baseOffset: 200)!
        expect(nextFile.id != a.id, "new recording in same lesson cannot collide")
        let saved = LectureAudioCheckpoint(recordingID: "file-A", baseOffset: 100, committedFrames: 8 * rate,
            segments: [a], captureClosed: false, interrupted: false)
        let restored = try JSONDecoder().decode(LectureAudioCheckpoint.self, from: JSONEncoder().encode(saved))
        expect(restored.committedFrames == saved.committedFrames && restored.segments == [a], "watermark and transcript survive as one checkpoint")
        print("LectureAudioCoreChecks: \(count) checks passed")
    }
}
