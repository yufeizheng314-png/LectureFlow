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

private func requestContext(_ request: URLRequest) throws -> [String: Any] {
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let messages = body["messages"] as! [[String: String]]
    let content = messages.last(where: { $0["role"] == "user" })!["content"]!
    return try JSONSerialization.jsonObject(with: Data(content.utf8)) as! [String: Any]
}

private func contextText(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
}

private func summaryInContext(_ context: [String: Any]) throws -> LFNotesSummary? {
    guard let value = context["previous_course_summary"], !(value is NSNull) else { return nil }
    return try JSONDecoder().decode(LFNotesSummary.self, from: JSONSerialization.data(withJSONObject: value))
}

private func response(for request: URLRequest, status: Int = 200, english: String = "New facts.") throws -> (Data, HTTPURLResponse) {
    let input = try requestContext(request)
    let segments = input["new_confirmed_segments"] as! [[String: Any]]
    let ids = Array(Set(segments.map { $0["segmentID"] as! String })).sorted()
    var notes = LFGeneratedNotes(englishNotes: english, chineseNotes: "新增的课程要点。", keyTerms: [], sourceSegmentIDs: ids)
    notes.courseSummary = LFNotesSummary(englishNotes: "Course outline: " + english, chineseNotes: "累计课程梳理：" + english, keyTerms: [])
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

private actor RollingHTTP {
    enum Failure: Equatable { case http, malformedSummary }
    var requests: [URLRequest] = []
    var summaries: [LFNotesSummary] = []
    let failAt: Int?
    let failure: Failure

    init(failAt: Int? = nil, failure: Failure = .http) {
        self.failAt = failAt
        self.failure = failure
    }

    func call(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if requests.count == failAt, failure == .http {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        let context = try requestContext(request)
        let inputs = context["new_confirmed_segments"] as! [[String: Any]]
        let previous = try summaryInContext(context)
        let newText = inputs.map { $0["english"] as! String }.joined(separator: "\n")
        let newFacts = inputs.map { String(($0["english"] as! String).components(separatedBy: ".").first!.prefix(200)) + "." }.joined(separator: "\n")
        // The fixture can retain earlier facts only if the service actually sends its prior summary.
        let summary = LFNotesSummary(
            englishNotes: [previous?.englishNotes, newFacts].compactMap { $0 }.joined(separator: "\n"),
            chineseNotes: (previous?.chineseNotes ?? "课程梳理") + "；本次新增 \(inputs.count) 段。",
            keyTerms: [LFKeyTerm(english: "photosynthesis", chinese: "光合作用")])
        summaries.append(summary)
        var notes = LFGeneratedNotes(englishNotes: "Progress: " + String(newText.prefix(1500)), chineseNotes: "本批课堂进展。", keyTerms: [],
                                     sourceSegmentIDs: Array(Set(inputs.map { $0["segmentID"] as! String })).sorted())
        notes.courseSummary = summary
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(notes)) as! [String: Any]
        if requests.count == failAt, failure == .malformedSummary {
            object["course_summary"] = ["english_notes": "Incomplete cumulative notes", "key_terms": []] as [String: Any]
        }
        let content = try contextText(object)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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

private func gatingChecks(root: URL) async throws {
    let store = try LFLessonStore(rootURL: root)
    let lesson = try await store.createLesson(title: "Accumulate a classroom explanation")
    _ = try await store.appendConfirmedSegments([
        LFConfirmedSegment(id: "fragment-1", startTime: 0, endTime: 12, english: "During photosynthesis,"),
        LFConfirmedSegment(id: "fragment-2", startTime: 12, endTime: 24, english: "plants convert sunlight")
    ], to: lesson.id)
    check(try await store.prepareNextBatch(for: lesson.id, flush: false) == nil, "Short one- or two-fragment explanations must accumulate")
    check(try await store.loadLesson(lesson.id).batches.isEmpty, "Waiting for more speech must not reserve or consume a batch")
    let waitingHTTP = RollingHTTP()
    let waitingService = LFNotesService(store: store, transport: { try await waitingHTTP.call($0) }, keyProvider: { _ in "fixture" })
    _ = try await waitingService.generatePending(lessonID: lesson.id, configuration: LFCloudConfiguration(endpoint: URL(string: "https://example.invalid/v1/chat/completions")!, model: "fixture"), flushPending: false)
    check(await waitingHTTP.requests.isEmpty, "Live generation must honor accumulation and avoid a premature cloud request")
    _ = try await store.appendConfirmedSegments([
        LFConfirmedSegment(id: "fragment-3", startTime: 24, endTime: 34, english: "into chemical energy stored in glucose.")
    ], to: lesson.id)
    let ready = try await store.prepareNextBatch(for: lesson.id, flush: false)!
    check(ready.inputs.map(\.segmentID) == ["fragment-1", "fragment-2", "fragment-3"], "Three accumulated fragments must form one request")
    let notes = LFGeneratedNotes(englishNotes: "Plants store sunlight as chemical energy.", chineseNotes: "植物将光能储存为化学能。", keyTerms: [], sourceSegmentIDs: ready.inputs.map(\.segmentID))
    _ = try await store.finishBatch(lessonID: lesson.id, batchID: ready.id, notes: notes)
    _ = try await store.appendConfirmedSegments([
        LFConfirmedSegment(id: "tail", startTime: 34, endTime: 40, english: "Oxygen is released.")
    ], to: lesson.id)
    check(try await store.prepareNextBatch(for: lesson.id, flush: false) == nil, "A short final fragment must wait during live recording")
    let tail = try await store.prepareNextBatch(for: lesson.id, flush: true)!
    check(tail.inputs.map(\.segmentID) == ["tail"], "Explicit flush must process the final fragment without resending previous ranges")

    let characters = try await store.createLesson(title: "Character threshold")
    _ = try await store.appendConfirmedSegments([
        LFConfirmedSegment(id: "long-enough", startTime: 0, endTime: 12, english: String(repeating: "x", count: 350))
    ], to: characters.id)
    check(try await store.prepareNextBatch(for: characters.id, flush: false) != nil, "350 characters must be sufficient even with one segment")

    let duration = try await store.createLesson(title: "Time threshold")
    _ = try await store.appendConfirmedSegments([
        LFConfirmedSegment(id: "slow-enough", startTime: 0, endTime: 45, english: "A slower classroom explanation.")
    ], to: duration.id)
    check(try await store.prepareNextBatch(for: duration.id, flush: false) != nil, "45 seconds must be sufficient even with a short segment")
}

private func rollingCourseChecks(root: URL, configuration: LFCloudConfiguration) async throws {
    let store = try LFLessonStore(rootURL: root)
    let lesson = try await store.createLesson(title: "Photosynthesis across a whole lesson")
    let segments = (1...9).map { index in
        LFConfirmedSegment(id: "course-\(index)", startTime: Double(index - 1) * 10, endTime: Double(index) * 10,
                           english: "FACT_\(index): classroom explanation. " + String(repeating: "detail ", count: 95))
    }
    _ = try await store.appendConfirmedSegments(segments, to: lesson.id)
    let mock = RollingHTTP()
    let service = LFNotesService(store: store, transport: { try await mock.call($0) }, keyProvider: { _ in "fixture-key-never-on-disk" })
    let done = try await service.generatePending(lessonID: lesson.id, configuration: configuration)
    let requests = await mock.requests
    let summaries = await mock.summaries
    check(requests.count == 2 && done.notes.count == 2, "Nine segments must catch up through two bounded batches")
    let first = try requestContext(requests[0]), second = try requestContext(requests[1])
    check(first["mode"] as? String == "progressive" && second["mode"] as? String == "progressive", "Live notes must explicitly use progressive mode")
    check(try summaryInContext(first) == nil, "The first course request has no fabricated prior summary")
    check(try summaryInContext(second) == summaries[0], "The next batch must receive the previous persisted cumulative summary")
    let firstInputs = first["new_confirmed_segments"] as! [[String: Any]]
    let secondInputs = second["new_confirmed_segments"] as! [[String: Any]]
    check(firstInputs.count == 8 && secondInputs.map { $0["segmentID"] as! String } == ["course-9"], "Only new source ranges belong in each incremental batch")
    let firstHistory = first["previous_confirmed_context"] as! [[String: Any]]
    let secondHistory = second["previous_confirmed_context"] as! [[String: Any]]
    check(firstHistory.isEmpty, "First-batch history cannot leak a current or future source segment")
    check(secondHistory.count <= 8 && secondHistory.compactMap { $0["english"] as? String }.reduce(0) { $0 + $1.count } <= 4000,
          "Raw predecessor context must stay within eight segments and 4000 characters")
    let historyText = try contextText(secondHistory)
    check(historyText.contains("FACT_8") && !historyText.contains("FACT_9"), "The preceding sentence must be available without leaking the current batch into its history")
    check(done.courseSummary == summaries[1] && done.courseSummary?.englishNotes.contains("FACT_1") == true && done.courseSummary?.englishNotes.contains("FACT_9") == true,
          "Cumulative notes must retain early course facts while adding the latest explanation")
    check(done.courseSummaryThrough == 90, "Summary coverage must persist the last completed source time")

    let finalBatch = done.batches.last!
    var duplicate = LFGeneratedNotes(englishNotes: "DUPLICATE MUST NOT APPEND", chineseNotes: "不应追加", keyTerms: [], sourceSegmentIDs: ["course-9"])
    duplicate.courseSummary = LFNotesSummary(englishNotes: "DUPLICATE MUST NOT REPLACE", chineseNotes: "不应替换", keyTerms: [])
    let repeated = try await store.finishBatch(lessonID: lesson.id, batchID: finalBatch.id, notes: duplicate)
    check(repeated.notes.count == done.notes.count && repeated.courseSummary == done.courseSummary, "Finishing a completed batch must preserve both progress notes and the course summary")
    let reopened = try LFLessonStore(rootURL: root)
    let persisted = try await reopened.loadLesson(lesson.id)
    check(persisted.notes.count == 2 && persisted.batches.allSatisfy { $0.state == .completed } && persisted.courseSummary == done.courseSummary,
          "Completed batch, progress notes and cumulative summary must survive the same checkpoint")

    _ = try await store.appendConfirmedSegments([LFConfirmedSegment(id: "course-10", startTime: 90, endTime: 100, english: "FACT_10: A new explanation.")], to: lesson.id)
    let failedHTTP = RollingHTTP(failAt: 1)
    let failureService = LFNotesService(store: store, transport: { try await failedHTTP.call($0) }, keyProvider: { _ in "fixture" })
    await mustFail { _ = try await failureService.generatePending(lessonID: lesson.id, configuration: configuration) }
    let afterHTTPFailure = try await store.loadLesson(lesson.id)
    check(afterHTTPFailure.notes.count == done.notes.count && afterHTTPFailure.courseSummary == done.courseSummary && afterHTTPFailure.courseSummaryThrough == 90,
          "An HTTP failure must preserve the last valid course summary and progress notes")
    let malformed = RollingHTTP(failAt: 1, failure: .malformedSummary)
    let malformedService = LFNotesService(store: store, transport: { try await malformed.call($0) }, keyProvider: { _ in "fixture" })
    await mustFail { _ = try await malformedService.generatePending(lessonID: lesson.id, configuration: configuration) }
    check(try await store.loadLesson(lesson.id).courseSummary == done.courseSummary, "Malformed course-summary JSON must not replace a valid checkpoint")
}

private func splitContextChecks() throws {
    let earlierText = String(repeating: "EARLIER_DETAIL ", count: 500)
    let currentText = "CURRENT_SLICE_MARKER."
    let source = earlierText + currentText + "FUTURE_WITHIN_SAME_SOURCE."
    let now = Date()
    var lesson = LFLesson(id: UUID(), title: "A split source sentence", createdAt: now, modifiedAt: now)
    lesson.segments = [
        LFConfirmedSegment(id: "preceding", startTime: 0, endTime: 10, english: "A preceding explanation."),
        LFConfirmedSegment(id: "split", startTime: 10, endTime: 100, english: source),
        LFConfirmedSegment(id: "future", startTime: 100, endTime: 110, english: "FUTURE_SOURCE_SEGMENT.")
    ]
    let batch = LFNoteBatch(id: UUID(), inputs: [LFNoteInput(segmentID: "split", startTime: 10, endTime: 100,
        characterStart: earlierText.count, characterEnd: earlierText.count + currentText.count, english: currentText)], state: .running)
    let context = LFNotesService.previousContext(for: batch, in: lesson)
    let text = try contextText(context)
    check(context.count <= 8 && context.compactMap { $0["english"] as? String }.reduce(0) { $0 + $1.count } <= 4000,
          "A split segment's consumed prefix must remain a bounded history window")
    check(text.contains("EARLIER_DETAIL") && !text.contains("CURRENT_SLICE_MARKER") && !text.contains("FUTURE_WITHIN_SAME_SOURCE") && !text.contains("FUTURE_SOURCE_SEGMENT"),
          "Context for a split segment must stop at its consumed character offset, excluding current and future text")
}

private func splitEditRebuildChecks(root: URL, configuration: LFCloudConfiguration) async throws {
    let store = try LFLessonStore(rootURL: root)
    let lesson = try await store.createLesson(title: "Corrections from a later part of one long source")
    _ = try await store.appendConfirmedSegments([
        LFConfirmedSegment(id: "long-course", startTime: 0, endTime: 180,
                           english: String(repeating: "Course premise and example. ", count: 600))
    ], to: lesson.id)
    while let batch = try await store.prepareNextBatch(for: lesson.id) {
        _ = try await store.finishBatch(lessonID: lesson.id, batchID: batch.id,
            notes: LFGeneratedNotes(englishNotes: "Old notes for this source range.", chineseNotes: "旧原文范围的笔记。", keyTerms: [], sourceSegmentIDs: ["long-course"]))
    }
    let complete = try await store.loadLesson(lesson.id)
    check(complete.batches.count == 3, "The long-source fixture must contain three separate historical character ranges")
    let marker = "LAST_BATCH_EDIT_ONLY"
    let edited = try await store.updateNote(lessonID: lesson.id, noteID: complete.notes.last!.id, english: marker, chinese: "仅最后一批的修正。")
    check(LFNotesService.editedNotes(for: complete.batches[0], in: edited).isEmpty, "A future character-range correction must not leak into an earlier chunk of the same source")
    check(LFNotesService.editedNotes(for: complete.batches[2], in: edited).map(\.englishNotes) == [marker], "The correction becomes available when its original range is covered")
    var ambiguous = edited
    var unknown = LFNoteBlock(id: UUID(), batchID: UUID(), generatedEnglishNotes: "Unknown historical range", generatedChineseNotes: "未知历史范围", keyTerms: [], sourceSegmentIDs: ["long-course"])
    unknown.editedEnglishNotes = "UNKNOWN_RANGE_EDIT"
    ambiguous.notes.append(unknown)
    check(!LFNotesService.editedNotes(for: complete.batches[2], in: ambiguous).contains(where: { $0.id == unknown.id }),
          "An edited note sharing the current source but lacking batch-range metadata must be excluded")
    let mock = RollingHTTP()
    let service = LFNotesService(store: store, transport: { try await mock.call($0) }, keyProvider: { _ in "fixture-key-never-on-disk" })
    let rebuilt = try await service.generatePending(lessonID: lesson.id, configuration: configuration, rebuildSummary: true)
    let requests = await mock.requests
    check(requests.count == 3 && rebuilt.notes == edited.notes, "Rebuilding split sources must preserve existing edited notes without duplicate progress cards")
    let first = try requestContext(requests[0]), last = try requestContext(requests[2])
    check(first["mode"] as? String == "rebuild" && last["mode"] as? String == "rebuild", "The character-range regression must inspect actual reconstruction requests")
    let firstEdits = try contextText(first["edited_notes"]!), lastEdits = try contextText(last["edited_notes"]!)
    check(!firstEdits.contains(marker), "The first actual rebuild request must not contain a correction from its source's last batch")
    check(lastEdits.contains(marker), "The final actual rebuild request must include the now-covered correction")
}

private func legacyRebuildChecks(root: URL, configuration: LFCloudConfiguration) async throws {
    let store = try LFLessonStore(rootURL: root)
    let lesson = try await store.createLesson(title: "Existing installed course")
    let segments = (1...9).map { index in
        LFConfirmedSegment(id: "legacy-\(index)", startTime: Double(index - 1) * 10, endTime: Double(index) * 10,
                           english: "LEGACY_FACT_\(index): Photosynthesis is part of this classroom explanation.")
    }
    _ = try await store.appendConfirmedSegments(segments, to: lesson.id)
    while let batch = try await store.prepareNextBatch(for: lesson.id) {
        let oldNotes = LFGeneratedNotes(englishNotes: "Old incremental notes.", chineseNotes: "旧增量笔记。", keyTerms: [], sourceSegmentIDs: batch.inputs.map(\.segmentID))
        _ = try await store.finishBatch(lessonID: lesson.id, batchID: batch.id, notes: oldNotes)
    }
    var before = try await store.loadLesson(lesson.id)
    _ = try await store.updateNote(lessonID: lesson.id, noteID: before.notes[0].id, english: "USER_CORRECTED_PHOTOSYNTHESIS", chinese: "用户修正的光合作用笔记。")
    let audioURL = try await store.nextRecordingURL(for: lesson.id)
    let originalAudio = Data([82, 73, 70, 70, 11, 22, 33, 44])
    try originalAudio.write(to: audioURL)
    before = try await store.registerRecording(lessonID: lesson.id, url: audioURL, duration: 30, offset: 90)

    let jsonURL = root.appendingPathComponent(lesson.id.uuidString).appendingPathComponent("lesson.json")
    var legacyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as! [String: Any]
    legacyJSON.removeValue(forKey: "courseSummary")
    legacyJSON.removeValue(forKey: "courseSummaryThrough")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
    try legacyData.write(to: jsonURL, options: .atomic)
    let decoded = try JSONDecoder().decode(LFLesson.self, from: legacyData)
    check(decoded.courseSummary == nil && decoded.courseSummaryThrough == nil, "Build-one lesson JSON must decode without new summary fields")
    let migratedStore = try LFLessonStore(rootURL: root)
    let migrated = try await migratedStore.loadLesson(lesson.id)
    check(migrated.notes.map(\.id) == before.notes.map(\.id) && migrated.notes[0].englishNotes == "USER_CORRECTED_PHOTOSYNTHESIS" && migrated.audioFiles == before.audioFiles,
          "Opening an existing course must preserve note identities, edits and audio references")

    let mock = RollingHTTP()
    let service = LFNotesService(store: migratedStore, transport: { try await mock.call($0) }, keyProvider: { _ in "fixture-key-never-on-disk" })
    let rebuilt = try await service.generatePending(lessonID: lesson.id, configuration: configuration, rebuildSummary: true)
    let requests = await mock.requests
    check(requests.count == 2 && rebuilt.courseSummary?.englishNotes.contains("LEGACY_FACT_1") == true && rebuilt.courseSummary?.englishNotes.contains("LEGACY_FACT_9") == true,
          "Rebuild must process already-consumed transcript in bounded batches and retain the whole-course explanation")
    check(rebuilt.courseSummaryThrough == 90 && rebuilt.notes.map(\.id) == before.notes.map(\.id) && rebuilt.batches == before.batches,
          "Rebuild must checkpoint summary coverage without appending or changing historical note batches")
    let savedAudio = try Data(contentsOf: audioURL)
    check(rebuilt.notes[0].englishNotes == "USER_CORRECTED_PHOTOSYNTHESIS" && rebuilt.audioFiles == before.audioFiles && rebuilt.segments == before.segments && savedAudio == originalAudio,
          "Course reconstruction must preserve edited notes, confirmed transcript and original audio bytes")
    for request in requests {
        let context = try requestContext(request)
        let inputs = context["new_confirmed_segments"] as! [[String: Any]]
        check(context["mode"] as? String == "rebuild" && inputs.count <= 8 && inputs.compactMap { $0["english"] as? String }.reduce(0) { $0 + $1.count } <= 8000,
              "Rebuild requests must use explicit mode and bounded original source text")
        check(try contextText(context["edited_notes"]!).contains("USER_CORRECTED_PHOTOSYNTHESIS"), "Rebuilding the course must carry the user's corrections as context")
    }
    for format in [LFExportFormat.markdown, .text] {
        let exported = try await migratedStore.exportLesson(lesson.id, format: format)
        let text = try String(contentsOf: exported, encoding: .utf8)
        check(text.contains(rebuilt.courseSummary!.englishNotes) && text.contains(rebuilt.courseSummary!.chineseNotes) && text.contains("USER_CORRECTED_PHOTOSYNTHESIS") && text.contains("legacy-9"),
              "Exports must include cumulative bilingual notes, existing edits and source transcript")
    }
    let failedRebuildHTTP = RollingHTTP(failAt: 2)
    let failedRebuild = LFNotesService(store: migratedStore, transport: { try await failedRebuildHTTP.call($0) }, keyProvider: { _ in "fixture" })
    await mustFail { _ = try await failedRebuild.generatePending(lessonID: lesson.id, configuration: configuration, rebuildSummary: true) }
    let afterFailedRebuild = try await migratedStore.loadLesson(lesson.id)
    check(afterFailedRebuild.courseSummary == rebuilt.courseSummary && afterFailedRebuild.courseSummaryThrough == rebuilt.courseSummaryThrough && afterFailedRebuild.notes == rebuilt.notes,
          "A failed later rebuild batch must retain the complete existing summary and all edits")
    let savedSummary = LFNotesSummary(englishNotes: "A valid replacement course outline.", chineseNotes: "有效的课程梳理更新。", keyTerms: [])
    let replaced = try await migratedStore.updateCourseSummary(savedSummary, throughTime: 90, for: lesson.id)
    check(replaced.courseSummary == savedSummary && replaced.notes.map(\.id) == rebuilt.notes.map(\.id) && replaced.audioFiles == rebuilt.audioFiles,
          "A summary-only checkpoint must preserve historical notes and original audio")
    let cancelled = UUID()
    _ = try await migratedStore.cancelBatches(for: lesson.id, runToken: cancelled)
    await mustFail { _ = try await migratedStore.updateCourseSummary(LFNotesSummary(englishNotes: "STALE SUMMARY", chineseNotes: "过期梳理", keyTerms: []), throughTime: 90, for: lesson.id, runToken: cancelled) }
    check(try await migratedStore.loadLesson(lesson.id).courseSummary == savedSummary, "Cancelled summary reconstruction must not commit a late result")
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
        let endpointB = URL(string: "https://other.example.invalid/v1/chat/completions")!
        let boundKey = try LFKeychain.credentialData("fixture-B-key", for: endpointB)
        check(LFKeychain.matchingKey(in: boundKey, for: config.endpoint) == nil, "Crash between config/key writes must not send B's key to A")
        check(LFKeychain.matchingKey(in: boundKey, for: endpointB) == "fixture-B-key", "Bound key must match the complete endpoint")
        check(LFKeychain.matchingKey(in: boundKey, for: URL(string: "https://other.example.invalid/other/path")!) == nil, "Binding includes the path, not just the origin")
        check(LFKeychain.matchingKey(in: Data("legacy-unbound-key".utf8), for: config.endpoint) == nil, "Legacy unbound keys must never be sent")
        let noConfig = LFNotesService(store: reopened, keyProvider: { _ in nil })
        let notConfigured = try await noConfig.generatePending(lessonID: other.id, configuration: nil)
        check(notConfigured.notesState == .notConfigured && notConfigured.notesError != nil, "No AI must be explicit")

        _ = try await reopened.appendConfirmedSegments([LFConfirmedSegment(id: "new", startTime: 95, endTime: 99, english: "ONLY NEW CONFIRMED TEXT")], to: lesson.id)
        let mock = ScriptedHTTP(firstStatus: 503)
        let service = LFNotesService(store: reopened, transport: { try await mock.call($0) }, keyProvider: { _ in "fixture-key-never-on-disk" })
        let withNew = try await service.generatePending(lessonID: lesson.id, configuration: config)
        let sent = await mock.requests
        check(sent.count == 2, "A transient HTTP failure must retry")
        check(sent[0].httpBody == sent[1].httpBody && sent[0].value(forHTTPHeaderField: "Idempotency-Key") == sent[1].value(forHTTPHeaderField: "Idempotency-Key"), "Retry payload and batch identity must be stable")
        let requestText = String(decoding: sent[0].httpBody!, as: UTF8.self)
        check(requestText.contains("My edited English") && requestText.contains("ONLY NEW CONFIRMED TEXT"), "Request must use edited bounded prior notes plus new excerpts")
        let sentContext = try requestContext(sent[0])
        let sentNew = sentContext["new_confirmed_segments"] as! [[String: Any]]
        let sentHistory = sentContext["previous_confirmed_context"] as! [[String: Any]]
        check(sentNew.map { $0["segmentID"] as! String } == ["new"], "Already-consumed transcript must not be sent as new evidence")
        check(sentHistory.count <= 8 && sentHistory.compactMap { $0["english"] as? String }.reduce(0) { $0 + $1.count } <= 4000,
              "Continuity may resend only a bounded predecessor transcript window")
        check(!requestText.contains(longText) && !requestText.contains("fixture-key-never-on-disk"), "Do not resend an unbounded transcript or place keys in body")
        check(withNew.notes.count == 4 && withNew.notes[0].isEdited, "Append only, preserving edited blocks")

        _ = try await reopened.appendConfirmedSegments([LFConfirmedSegment(id: "other-segment", startTime: 0, endTime: 1, english: "Other source")], to: other.id)
        let held = HeldHTTP()
        let lateService = LFNotesService(store: reopened, transport: { try await held.call($0) }, keyProvider: { _ in "fixture" })
        let oldRequest = Task { try await lateService.generatePending(lessonID: other.id, configuration: config) }
        await held.waitForRequest()
        _ = try await lateService.cancel(lessonID: other.id)
        let quick = ScriptedHTTP()
        let replacement = LFNotesService(store: reopened, transport: { try await quick.call($0) }, keyProvider: { _ in "fixture" })
        _ = try await replacement.generatePending(lessonID: other.id, configuration: config)
        try await held.release()
        await mustFail { _ = try await oldRequest.value }
        let afterLate = try await reopened.loadLesson(other.id)
        check(afterLate.notes.count == 1 && !afterLate.notes[0].englishNotes.contains("STALE"), "Late response must not commit after cancellation/restart")
        check(afterLate.courseSummary != nil && afterLate.courseSummary?.englishNotes.contains("STALE") == false, "Cancelled late responses must not replace a newer course summary")

        let invalid = LFGeneratedNotes(englishNotes: "x", chineseNotes: "中", keyTerms: [], sourceSegmentIDs: ["foreign-lesson"])
        await mustFail { try invalid.validate(for: batch) }
        let missingSource = LFGeneratedNotes(englishNotes: "x", chineseNotes: "中", keyTerms: [], sourceSegmentIDs: [])
        await mustFail { try missingSource.validate(for: batch) }
        await mustFail { _ = try LFNotesService.decodeResponse(Data(repeating: 32, count: 1_048_577), for: batch) }
        await mustFail { _ = try LFNotesService.decodeResponse(Data("{broken-json".utf8), for: batch) }
        let legacyContent = String(decoding: try JSONEncoder().encode(generated), as: UTF8.self)
        let legacyEnvelope = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": legacyContent]]]])
        let legacyDecoded = try LFNotesService.decodeResponse(legacyEnvelope, for: batch)
        check(legacyDecoded.courseSummary == nil && legacyDecoded.englishNotes == generated.englishNotes, "Legacy four-key responses must remain decodable without a fabricated course summary")
        await mustFail { _ = try LFNotesService.decodeResponse(legacyEnvelope, for: batch, requireSummary: true) }
        let markdown = try await reopened.exportLesson(lesson.id, format: .markdown)
        let plain = try await reopened.exportLesson(lesson.id, format: .text)
        check(try String(contentsOf: markdown, encoding: .utf8).contains("我的中文修改"), "Export must preserve edited Unicode notes")
        check(try String(contentsOf: plain, encoding: .utf8).contains(longText), "TXT export must include the full confirmed transcript")
        try await gatingChecks(root: root.appendingPathComponent("gating", isDirectory: true))
        try await rollingCourseChecks(root: root.appendingPathComponent("rolling", isDirectory: true), configuration: config)
        try splitContextChecks()
        try await splitEditRebuildChecks(root: root.appendingPathComponent("split-edits", isDirectory: true), configuration: config)
        try await legacyRebuildChecks(root: root.appendingPathComponent("legacy", isDirectory: true), configuration: config)
        try checkNoStoredKey(root: root)
        print("LectureFlow assertions passed: dedup/conflict, 8k splitting, restart, token race, stale HTTP, retry, rolling summary/context, accumulation/flush, legacy migration/rebuild, failure preservation, edit/audio/export preservation, isolation, key redaction.")
    }
}
