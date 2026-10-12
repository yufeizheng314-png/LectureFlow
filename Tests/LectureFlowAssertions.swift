import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func check(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

private func mustFail(_ body: () async throws -> Void) async {
    do { try await body(); preconditionFailure("Expected failure") } catch { }
}

private func checkNoStoredKey(root: URL) throws {
    let allFiles = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
    for case let url as URL in allFiles where url.pathExtension == "json" {
        check(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("fixture-key-never-on-disk"), "Key must never be persisted in lesson JSON")
    }
}

private func response(for request: URLRequest, status: Int = 200, english: String = "New facts.") throws -> (Data, HTTPURLResponse) {
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let messages = body["messages"] as! [[String: String]]
    let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
    let segments = input["new_confirmed_segments"] as! [[String: Any]]
    let ids = Array(Set(segments.map { $0["segmentID"] as! String })).sorted()
    let notes = LFGeneratedNotes(englishNotes: english, chineseNotes: "新增的课程要点。", keyTerms: [], sourceSegmentIDs: ids)
    let content = String(decoding: try JSONEncoder().encode(notes), as: UTF8.self)
    let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
    return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}

private actor ScriptedHTTP {
    var requests: [URLRequest] = []
    let firstStatus: Int
    init(firstStatus: Int = 200) { self.firstStatus = firstStatus }
    func call(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try response(for: request, status: requests.count == 1 ? firstStatus : 200)
    }
}

private actor HeldHTTP {
    var request: URLRequest?
    var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    var arrived: CheckedContinuation<Void, Never>?
    func call(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            arrived?.resume()
            arrived = nil
        }
    }
    func waitForRequest() async {
        if request != nil { return }
        await withCheckedContinuation { arrived = $0 }
    }
    func release() throws {
        pending?.resume(returning: try response(for: request!, english: "STALE RESPONSE MUST NOT COMMIT"))
        pending = nil
    }
}

@main
struct LectureFlowAssertions {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LectureFlow-assertions-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LFLessonStore(rootURL: root)
        let lesson = try await store.createLesson(title: "Biology / 生物")
        let other = try await store.createLesson(title: "Other lesson")
        let first = LFConfirmedSegment(id: "s1", startTime: 0, endTime: 8, english: "Cells use energy.")
        _ = try await store.appendConfirmedSegments([first, first], to: lesson.id)
        check(try await store.loadLesson(lesson.id).segments.count == 1, "Stable IDs must deduplicate")
        await mustFail {
            _ = try await store.appendConfirmedSegments([LFConfirmedSegment(id: "s1", startTime: 0, endTime: 8, english: "Changed")], to: lesson.id)
        }
        check(try await store.loadLesson(lesson.id).segments == [first], "Conflicting append must not partially write")

        let old = UUID(), fresh = UUID()
        let batch = try await store.prepareNextBatch(for: lesson.id, runToken: old)!
        _ = try await store.cancelBatches(for: lesson.id, runToken: old)
        let retried = try await store.prepareNextBatch(for: lesson.id, runToken: fresh)!
        check(batch.id == retried.id, "A cancelled batch must reuse its persisted ID")
        let generated = LFGeneratedNotes(englishNotes: "Energy in cells.", chineseNotes: "细胞中的能量。", keyTerms: [LFKeyTerm(english: "cell", chinese: "细胞")], sourceSegmentIDs: ["s1"])
        await mustFail { _ = try await store.finishBatch(lessonID: lesson.id, batchID: batch.id, notes: generated, runToken: old) }
        await mustFail { _ = try await store.failBatch(lessonID: lesson.id, batchID: batch.id, message: "stale", runToken: old) }
        _ = try await store.cancelBatches(for: lesson.id, runToken: old)
        check(try await store.loadLesson(lesson.id).batches[0].state == .running, "Old cancellation must not cancel a new attempt")
        let done = try await store.finishBatch(lessonID: lesson.id, batchID: batch.id, notes: generated, runToken: fresh)
        _ = try await store.updateNote(lessonID: lesson.id, noteID: done.notes[0].id, english: "My edited English", chinese: "我的中文修改")
        let cancelledBeforePrepare = UUID()
        _ = try await store.cancelBatches(for: other.id, runToken: cancelledBeforePrepare)
        await mustFail { _ = try await store.prepareNextBatch(for: other.id, runToken: cancelledBeforePrepare) }

        let longText = String(repeating: "A中🙂", count: 3001)
        _ = try await store.appendConfirmedSegments([LFConfirmedSegment(id: "long", startTime: 8, endTime: 90, english: longText)], to: lesson.id)
        let firstSlice = try await store.prepareNextBatch(for: lesson.id)!
        check(firstSlice.inputs[0].english.count == 8000, "Long segment must split at a character boundary")
        let reopened = try LFLessonStore(rootURL: root)
        let recovered = try await reopened.loadLesson(lesson.id)
        check(recovered.recordingState == .paused && recovered.batches.last?.state == .queued, "Restart must recover recording and pending request")
        let replay = try await reopened.prepareNextBatch(for: lesson.id)!
        check(replay.id == firstSlice.id && replay.inputs == firstSlice.inputs, "Restart must replay the same batch payload")
        let longNotes = LFGeneratedNotes(englishNotes: "Long excerpt.", chineseNotes: "长段内容。", keyTerms: [], sourceSegmentIDs: ["long"])
        _ = try await reopened.finishBatch(lessonID: lesson.id, batchID: replay.id, notes: longNotes)
        let secondSlice = try await reopened.prepareNextBatch(for: lesson.id)!
        check(firstSlice.inputs[0].english + secondSlice.inputs[0].english == longText, "Splitting must neither drop nor duplicate text")
        _ = try await reopened.finishBatch(lessonID: lesson.id, batchID: secondSlice.id, notes: longNotes)
        check(try await reopened.prepareNextBatch(for: lesson.id) == nil, "Completed source ranges must not be resent")
        check(try await reopened.loadLesson(lesson.id).notes[0].englishNotes == "My edited English", "New notes must preserve edits")
        check(try await reopened.loadLesson(other.id).notes.isEmpty, "Lessons must remain isolated")

        let reserved = try await reopened.nextRecordingURL(for: lesson.id)
        _ = try await reopened.cancelUnusedRecording(lessonID: lesson.id, url: reserved)
        let audio = try await reopened.nextRecordingURL(for: lesson.id)
        try Data([1, 2, 3]).write(to: audio)
        await mustFail { _ = try await reopened.cancelUnusedRecording(lessonID: lesson.id, url: audio) }
        let audioLesson = try await reopened.registerRecording(lessonID: lesson.id, url: audio, duration: 5, offset: 90)
        check(audioLesson.timelineDuration == 95, "Resume timeline must include earlier recordings")
        let safeAudio = try await reopened.recordingURL(lessonID: lesson.id, fileID: audioLesson.audioFiles[0].id)
        check(safeAudio == audio.resolvingSymlinksInPath(), "Playback lookup must not allocate another file")
        await mustFail { _ = try await reopened.registerRecording(lessonID: other.id, url: audio, duration: 5, offset: 0) }

        let config = LFCloudConfiguration(endpoint: URL(string: "https://example.invalid/v1/chat/completions")!, model: "personal-model")
        try config.validate()
        await mustFail { try LFCloudConfiguration(endpoint: URL(string: "http://example.invalid/chat")!, model: "x").validate() }
        await mustFail { try LFCloudConfiguration(endpoint: URL(string: "https://user:secret@example.invalid/chat")!, model: "x").validate() }
        let noConfig = LFNotesService(store: reopened, keyProvider: { nil })
        let notConfigured = try await noConfig.generatePending(lessonID: other.id, configuration: nil)
        check(notConfigured.notesState == .notConfigured && notConfigured.notesError != nil, "No AI must be explicit")

        _ = try await reopened.appendConfirmedSegments([LFConfirmedSegment(id: "new", startTime: 95, endTime: 99, english: "ONLY NEW CONFIRMED TEXT")], to: lesson.id)
        let mock = ScriptedHTTP(firstStatus: 503)
        let service = LFNotesService(store: reopened, transport: { try await mock.call($0) }, keyProvider: { "fixture-key-never-on-disk" })
        let withNew = try await service.generatePending(lessonID: lesson.id, configuration: config)
        let sent = await mock.requests
        check(sent.count == 2, "A transient HTTP failure must retry")
        check(sent[0].httpBody == sent[1].httpBody && sent[0].value(forHTTPHeaderField: "Idempotency-Key") == sent[1].value(forHTTPHeaderField: "Idempotency-Key"), "Retry payload and batch identity must be stable")
        let requestText = String(decoding: sent[0].httpBody!, as: UTF8.self)
        check(requestText.contains("My edited English") && requestText.contains("ONLY NEW CONFIRMED TEXT"), "Request must use edited bounded prior notes plus new excerpts")
        check(!requestText.contains("Cells use energy.") && !requestText.contains(longText) && !requestText.contains("fixture-key-never-on-disk"), "Do not resend the full transcript or place keys in body")
        check(withNew.notes.count == 4 && withNew.notes[0].isEdited, "Append only, preserving edited blocks")

        _ = try await reopened.appendConfirmedSegments([LFConfirmedSegment(id: "other-segment", startTime: 0, endTime: 1, english: "Other source")], to: other.id)
        let held = HeldHTTP()
        let lateService = LFNotesService(store: reopened, transport: { try await held.call($0) }, keyProvider: { "fixture" })
        let oldRequest = Task { try await lateService.generatePending(lessonID: other.id, configuration: config) }
        await held.waitForRequest()
        _ = try await lateService.cancel(lessonID: other.id)
        let quick = ScriptedHTTP()
        let replacement = LFNotesService(store: reopened, transport: { try await quick.call($0) }, keyProvider: { "fixture" })
        _ = try await replacement.generatePending(lessonID: other.id, configuration: config)
        try await held.release()
        await mustFail { _ = try await oldRequest.value }
        let afterLate = try await reopened.loadLesson(other.id)
        check(afterLate.notes.count == 1 && !afterLate.notes[0].englishNotes.contains("STALE"), "Late response must not commit after cancellation/restart")

        let invalid = LFGeneratedNotes(englishNotes: "x", chineseNotes: "中", keyTerms: [], sourceSegmentIDs: ["foreign-lesson"])
        await mustFail { try invalid.validate(for: batch) }
        let missingSource = LFGeneratedNotes(englishNotes: "x", chineseNotes: "中", keyTerms: [], sourceSegmentIDs: [])
        await mustFail { try missingSource.validate(for: batch) }
        let markdown = try await reopened.exportLesson(lesson.id, format: .markdown)
        let plain = try await reopened.exportLesson(lesson.id, format: .text)
        check(try String(contentsOf: markdown, encoding: .utf8).contains("我的中文修改"), "Export must preserve edited Unicode notes")
        check(try String(contentsOf: plain, encoding: .utf8).contains(longText), "TXT export must include the full confirmed transcript")
        try checkNoStoredKey(root: root)
        print("LectureFlow assertions passed: dedup/conflict, 8k splitting, restart, token race, stale HTTP, retry, edit/context, isolation, audio containment, exports, key redaction.")
    }
}
