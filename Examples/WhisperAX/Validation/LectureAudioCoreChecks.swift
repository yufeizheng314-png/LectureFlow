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
        func rms(_ samples: [Float]) -> Double {
            sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
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

        let quiet = (0..<16_000).map { Float(0.014 * sin(2 * Double.pi * 220 * Double($0) / 16_000)) }
        let quietOriginal = quiet
        let boosted = try LectureAudioNormalization.prepareForInference(quiet)
        expect(boosted.aboveNoiseFloor && boosted.gain > 7 && boosted.gain <= 8, "quiet speech receives bounded inference gain")
        expect(rms(boosted.samples) > 0.075 && rms(boosted.samples) <= LectureAudioNormalization.targetRMS,
               "quiet speech approaches the RMS target without exceeding the maximum gain")
        expect(boosted.samples.count == quiet.count && quiet == quietOriginal, "normalization preserves source samples and frame count")
        let quietURL = directory.appendingPathComponent("quiet.wav")
        let quietStore = try LecturePCMStore(url: quietURL)
        try quietStore.append(quiet)
        try quietStore.finish()
        let quietWAV = try Data(contentsOf: quietURL)
        let diskQuiet = try LecturePCMStore.read(url: quietURL, from: 0, through: quiet.count)
        _ = try LectureAudioNormalization.prepareForInference(diskQuiet)
        expect(try Data(contentsOf: quietURL) == quietWAV, "inference gain never changes the original WAV")
        let withTransient = [Float(1)] + Array(repeating: Float(0.005), count: 15_999)
        let limited = try LectureAudioNormalization.prepareForInference(withTransient)
        expect(limited.samples.allSatisfy { abs($0) <= 0.950001 } && limited.samples[0] > 0.949,
               "a loud transient limits gain before the signal can clip")
        let normal: [Float] = [0.1, -0.1, 0.15, -0.15]
        let normalInput = try LectureAudioNormalization.prepareForInference(normal)
        expect(normalInput.samples == normal && normalInput.gain == 1, "ordinary-level audio is not unnecessarily amplified or attenuated")
        let silence = Array(repeating: Float(0), count: 16_000)
        let silentInput = try LectureAudioNormalization.prepareForInference(silence)
        expect(!silentInput.aboveNoiseFloor && silentInput.gain == 1 && silentInput.samples == silence,
               "silence is not amplified or sent to inference")
        let nearZero: [Float] = [0.00002, -0.00002, 0.00003, -0.00003]
        let nearZeroInput = try LectureAudioNormalization.prepareForInference(nearZero)
        expect(!nearZeroInput.aboveNoiseFloor && nearZeroInput.samples == nearZero && nearZeroInput.gain == 1,
               "near-zero noise is not promoted to apparent speech")
        expect(rejects { _ = try LectureAudioNormalization.prepareForInference([0.01, .nan]) }, "nonfinite NaN input is rejected before inference")
        expect(rejects { _ = try LectureAudioNormalization.prepareForInference([.infinity, -0.01]) }, "nonfinite infinite input is rejected before inference")
        expect(rejects { _ = try LectureAudioNormalization.prepareForInference(Array(repeating: 0.01, count: LectureAudioWindowing.maximumReadFrames + 1)) },
               "normalization cannot allocate an unbounded recording window")
        let maximumInput = try LectureAudioNormalization.prepareForInference(Array(repeating: 0.01, count: LectureAudioWindowing.maximumReadFrames))
        expect(maximumInput.samples.count == LectureAudioWindowing.maximumReadFrames && maximumInput.samples.allSatisfy(\.isFinite),
               "a full bounded context window remains finite and keeps frame alignment")
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
        let beforeReady = LectureAudioWindowing.next(committed: 0, available: 10 * rate, closed: false)!
        expect(!beforeReady.canCommit, "expanded right context is complete before committing a live core")
        let first = LectureAudioWindowing.next(committed: 0, available: 12 * rate, closed: false)!
        expect(first.canCommit && first.ownedEnd == 8 * rate, "continuous speech commits on time rather than VAD")
        let second = LectureAudioWindowing.next(committed: 8 * rate, available: 20 * rate, closed: false)!
        expect(second.readStart == 4 * rate && second.readEnd == 20 * rate, "both sides retain four seconds of bounded context")
        let clearTimings = [LectureRecognizedWord(start: 0, end: 0.4, text: " water"),
                            LectureRecognizedWord(start: 0.4, end: 0.9, text: " cycle")]
        expect(!rejects { try LectureAudioWindowing.validateWordTimings(clearTimings, sampleCount: rate) },
               "normal speech timings within the actual read duration are accepted")
        let contextualTimings = [LectureRecognizedWord(start: 0.2, end: 0.6, text: " left context"),
                                 LectureRecognizedWord(start: 14, end: 14.6, text: " right context")]
        expect(!rejects { try LectureAudioWindowing.validateWordTimings(contextualTimings, sampleCount: second.readEnd - second.readStart) },
               "valid words in either context are accepted even outside the owned core")
        expect(!rejects { try LectureAudioWindowing.validateWordTimings([], sampleCount: rate) },
               "an empty no-speech result remains valid")
        expect(!rejects { try LectureAudioWindowing.validateWordTimings([
            LectureRecognizedWord(start: 0.9, end: 1.2, text: " tail")], sampleCount: rate) },
               "up to 0.2 seconds of end alignment tolerance is accepted")
        expect(rejects { try LectureAudioWindowing.validateWordTimings([
            LectureRecognizedWord(start: -0.01, end: 0.2, text: " invalid")], sampleCount: rate) },
               "negative nonempty word timings are rejected")
        expect(rejects { try LectureAudioWindowing.validateWordTimings([
            LectureRecognizedWord(start: .nan, end: 0.2, text: " invalid")], sampleCount: rate) },
               "nonfinite word starts are rejected")
        expect(rejects { try LectureAudioWindowing.validateWordTimings([
            LectureRecognizedWord(start: 0, end: .infinity, text: " invalid")], sampleCount: rate) },
               "nonfinite word ends are rejected")
        expect(rejects { try LectureAudioWindowing.validateWordTimings([
            LectureRecognizedWord(start: 0.4, end: 0.3, text: " invalid")], sampleCount: rate) },
               "reversed word timings are rejected")
        expect(rejects { try LectureAudioWindowing.validateWordTimings([
            LectureRecognizedWord(start: 0.9, end: 1.201, text: " invalid")], sampleCount: rate) },
               "timings beyond the actual read duration and tolerance are rejected")
        expect(rejects { try LectureAudioWindowing.validateWordTimings([], sampleCount: LectureAudioWindowing.maximumReadFrames + 1) },
               "timestamp validation cannot accept an unbounded read window")
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
        let shifted = words.map { LectureRecognizedWord(start: $0.start - 4, end: $0.end - 4, text: $0.text) }
        let b = LectureAudioWindowing.segment(words: shifted, window: second, recordingID: "file-A", baseOffset: 100)!
        expect(a.text == "before" && b.text == "after", "overlap belongs to exactly one core interval")
        expect(a.end <= b.start && b.start >= 108, "lesson offset is applied without time reversal")
        let replay = LectureAudioWindowing.segment(words: words, window: first, recordingID: "file-A", baseOffset: 100)!
        expect(replay.id == a.id, "recovery reuses segment identities")
        let nextFile = LectureAudioWindowing.segment(words: words, window: first, recordingID: "file-B", baseOffset: 200)!
        expect(nextFile.id != a.id, "new recording in same lesson cannot collide")
        let chinese = LectureAudioWindowing.segment(words: [
            LectureRecognizedWord(start: 0, end: 0.4, text: "今天"),
            LectureRecognizedWord(start: 0.4, end: 0.8, text: "天气"),
            LectureRecognizedWord(start: 0.8, end: 1.2, text: "很好。")
        ], window: first, recordingID: "file-zh", baseOffset: 50)!
        expect(chinese.text == "今天天气很好。" && chinese.start == 50 && chinese.end == 51.2,
               "Unicode-aligned Chinese groups join without invented spaces or changed source times")
        let saved = LectureAudioCheckpoint(recordingID: "file-A", baseOffset: 100, committedFrames: 8 * rate,
            segments: [a], captureClosed: false, interrupted: false, language: "zh")
        let restored = try JSONDecoder().decode(LectureAudioCheckpoint.self, from: JSONEncoder().encode(saved))
        expect(restored.committedFrames == saved.committedFrames && restored.segments == [a] && restored.language == "zh",
               "watermark, transcript and chosen language survive as one checkpoint")
        var guardedCheckpoint = restored
        let invalidDecodedWords = [LectureRecognizedWord(start: 29.63, end: 29.98, text: " [")]
        expect(rejects {
            // Reproduce the observed decoder result from a 14.8578-second file.
            // The same guard runs before segment filtering and checkpoint commit.
            try LectureAudioWindowing.validateWordTimings(invalidDecodedWords, sampleCount: 237_725)
            guardedCheckpoint.committedFrames = second.ownedEnd
        }, "nonempty words wholly outside the audio must fail instead of committing empty text")
        expect(guardedCheckpoint.committedFrames == restored.committedFrames &&
               guardedCheckpoint.segments == restored.segments && guardedCheckpoint.language == restored.language,
               "a rejected timing result preserves the prior transcript and consumption watermark")
        expect(try Data(contentsOf: quietURL) == quietWAV,
               "timestamp rejection never rewrites the original WAV")
        expect(try restored.languageForRecovery(fallback: "en") == "zh", "recovery uses the original recording's language before the current selection")
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        legacyJSON.removeValue(forKey: "language")
        let legacy = try JSONDecoder().decode(LectureAudioCheckpoint.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        expect(legacy.language == nil && legacy.segments == saved.segments && legacy.committedFrames == saved.committedFrames,
               "legacy checkpoints decode without losing transcript or watermark")
        expect(try legacy.languageForRecovery(fallback: "zh") == "zh" && legacy.languageForRecovery(fallback: "en") == "en",
               "legacy recovery uses the caller's selected language")
        expect(rejects { _ = try legacy.languageForRecovery(fallback: "fr") }, "unsupported caller languages are rejected")
        var invalidLanguage = restored
        invalidLanguage.language = "fr"
        expect(rejects { _ = try invalidLanguage.languageForRecovery(fallback: "en") }, "invalid saved language never silently falls back to English")
        print("LectureAudioCoreChecks: \(count) checks passed")
    }
}
