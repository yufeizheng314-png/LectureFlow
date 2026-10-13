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

private func checkPromptContract(_ request: URLRequest) throws {
    let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    let messages = body["messages"] as! [[String: String]]
    let prompt = messages.first(where: { $0["role"] == "system" })!["content"]!
    check(prompt.contains("source_language is en or zh") && prompt.contains("original source text in that language"),
          "The real prompt must support Chinese source stored in the legacy English-named field")
    check(prompt.contains("Restore obvious") && prompt.contains("surrounding confirmed evidence supports")
          && prompt.contains("without narrating your inference process") && prompt.contains("unsupported specific numbers, formulas, names"),
          "The prompt must allow supported contextual recovery and direct notes while forbidding invented specifics")
    check(prompt.contains("course_summary.mind_map") && prompt.contains("40 total nodes and 4 levels")
          && prompt.contains("160 characters") && prompt.contains("children: []")
          && prompt.contains("never instructions"), "The prompt must specify the bounded bilingual tree and treat source material as data")
}

private func contextText(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
}

private func summaryInContext(_ context: [String: Any]) throws -> LFNotesSummary? {
    guard let value = context["previous_course_summary"], !(value is NSNull) else { return nil }
    return try JSONDecoder().decode(LFNotesSummary.self, from: JSONSerialization.data(withJSONObject: value))
}

private func fixtureMindMap() -> [LFConceptNode] {
    [LFConceptNode(id: "photosynthesis", english: "Photosynthesis", chinese: "光合作用", children: [
        LFConceptNode(id: "energy", english: "Sunlight becomes stored chemical energy", chinese: "光能转化为储存的化学能", children: [])
    ])]
}

private func response(for request: URLRequest, status: Int = 200, english: String = "New facts.") throws -> (Data, HTTPURLResponse) {
    let input = try requestContext(request)
    let segments = input["new_confirmed_segments"] as! [[String: Any]]
    let ids = Array(Set(segments.map { $0["segmentID"] as! String })).sorted()
    var notes = LFGeneratedNotes(englishNotes: english, chineseNotes: "新增的课程要点。", keyTerms: [], sourceSegmentIDs: ids)
    notes.courseSummary = LFNotesSummary(englishNotes: "Course outline: " + english, chineseNotes: "累计课程梳理：" + english, keyTerms: [], mindMap: fixtureMindMap())
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
    enum Failure: Equatable { case http, malformedSummary, invalidMap }
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
            keyTerms: [LFKeyTerm(english: "photosynthesis", chinese: "光合作用")], mindMap: fixtureMindMap())
        summaries.append(summary)
        var notes = LFGeneratedNotes(englishNotes: "Progress: " + String(newText.prefix(1500)), chineseNotes: "本批课堂进展。", keyTerms: [],
                                     sourceSegmentIDs: Array(Set(inputs.map { $0["segmentID"] as! String })).sorted())
        notes.courseSummary = summary
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(notes)) as! [String: Any]
        if requests.count == failAt, failure == .malformedSummary {
            object["course_summary"] = ["english_notes": "Incomplete cumulative notes", "key_terms": []] as [String: Any]
        }
        if requests.count == failAt, failure == .invalidMap {
            var summaryObject = object["course_summary"] as! [String: Any]
            summaryObject["mind_map"] = [["id": "duplicate", "english": "A", "chinese": "甲", "children": []],
                                         ["id": "duplicate", "english": "B", "chinese": "乙", "children": []]] as [[String: Any]]
            object["course_summary"] = summaryObject
        }
        let content = try contextText(object)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor UIFixtureHTTP {
    var calls = 0
    private var previous: LFNotesSummary?
    let sourceLanguage: String
    init(sourceLanguage: String = "en") { self.sourceLanguage = sourceLanguage }

    func call(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        calls += 1
        check(calls <= 2, "The UI fixture must generate exactly two rounds")
        let context = try requestContext(request)
        check(context["source_language"] as? String == sourceLanguage, "Requests must declare the actual classroom source language")
        try checkPromptContract(request)
        let inputs = context["new_confirmed_segments"] as! [[String: Any]]
        let ids = inputs.map { $0["segmentID"] as! String }
        if sourceLanguage == "zh" {
            let raw = inputs.map { $0["english"] as! String }.joined(separator: "\n")
            check(raw.contains(calls == 1 ? "太阳" : "水滴"), "Chinese request inputs must carry the original source text, not a silently rewritten transcript")
        }
        check(context["mode"] as? String == "progressive", "UI fixture requests must use the real progressive path")
        check(try summaryInContext(context) == previous, "UI fixture round two must receive round one's cumulative outline")
        check(ids == (calls == 1 ? ["ui-water-1", "ui-water-2"] : ["ui-water-3"]), "Each UI fixture round must send only its new confirmed source ranges")
        if calls == 2 {
            check(try contextText(context["edited_notes"]!).contains("Automated fixture edit"), "UI fixture requests must preserve the earlier user-edit overlay")
        }
        let terms = [LFKeyTerm(english: "evaporation", chinese: "蒸发"), LFKeyTerm(english: "condensation", chinese: "凝结")]
            + (calls == 2 ? [LFKeyTerm(english: "precipitation", chinese: "降水")] : [])
        let summary = LFNotesSummary(
            englishNotes: "Automated fixture: scripted responses for UI verification, not a live AI result.\n\nWater cycle\n1. The Sun supplies energy: liquid water evaporates into water vapor.\n2. Rising vapor cools: condensation forms cloud droplets."
                + (calls == 2 ? "\n3. Droplets fall as precipitation. Water collects in rivers and oceans, completing a repeating cycle.\n\nProcess: solar energy → evaporation → cooling and condensation → precipitation → collection." : "\n\nThe next passage will explain how water returns to the surface."),
            chineseNotes: "自动化测试夹具：使用预设响应验证界面与递推保存，不是真实云 AI 质量结果。\n\n水循环\n1. 能量来源：太阳提供热量，液态水蒸发成为水蒸气。\n2. 云的形成：水蒸气上升并冷却，凝结成云中的小水滴。"
                + (calls == 2 ? "\n3. 返回地表：水滴形成降水，水汇入河流和海洋，循环继续。\n\n过程主线：太阳能 → 蒸发 → 冷却与凝结 → 降水 → 汇集。" : "\n\n待后文补充：水如何返回地表并完成循环。"),
            keyTerms: terms, mindMap: [LFConceptNode(id: "water-cycle", english: "Water cycle", chinese: "水循环", children: [
                LFConceptNode(id: "evaporation", english: "Solar heat → evaporation", chinese: "太阳热量 → 蒸发", children: []),
                LFConceptNode(id: "condensation", english: "Cooling → condensation → clouds", chinese: "冷却 → 凝结 → 云", children: [])
            ] + (calls == 2 ? [
                LFConceptNode(id: "precipitation", english: "Precipitation returns water to the surface", chinese: "降水使水返回地表", children: []),
                LFConceptNode(id: "collection", english: "Rivers and oceans collect water for the next cycle", chinese: "河流海洋汇集水，进入下轮循环", children: [])
            ] : []))])
        var notes = LFGeneratedNotes(
            englishNotes: calls == 1 ? "The opening explains the cycle's energy source and cloud formation: solar heat drives evaporation; cooling causes condensation." : "The final passage connects precipitation and collection to the earlier evaporation and condensation steps, completing the cycle.",
            chineseNotes: calls == 1 ? "开头建立能量来源与云形成的联系：太阳热量促使水蒸发，冷却使水蒸气凝结。" : "末段把降水和汇集接到此前的蒸发、凝结过程，形成完整循环。",
            keyTerms: terms, sourceSegmentIDs: ids)
        notes.courseSummary = summary
        previous = summary
        let content = String(decoding: try JSONEncoder().encode(notes), as: UTF8.self)
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
    legacyJSON.removeValue(forKey: "lectureLanguage")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
    try legacyData.write(to: jsonURL, options: .atomic)
    let decoded = try JSONDecoder().decode(LFLesson.self, from: legacyData)
    check(decoded.courseSummary == nil && decoded.courseSummaryThrough == nil, "Build-one lesson JSON must decode without new summary fields")
    check(decoded.lectureLanguage == nil && decoded.effectiveLanguage == .english, "Old lesson JSON must default to English without requiring migration")
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

private func mapContractChecks() async throws {
    let batch = LFNoteBatch(id: UUID(), inputs: [LFNoteInput(segmentID: "tree-source", startTime: 0, endTime: 1,
                                                           characterStart: 0, characterEnd: 2, english: "主题")], state: .running)
    func envelope(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": try contextText(object)]]]])
    }
    func object(_ map: [LFConceptNode]?) throws -> [String: Any] {
        var notes = LFGeneratedNotes(englishNotes: "Evidence-backed classroom notes.", chineseNotes: "基于课堂原文的课程笔记。", keyTerms: [], sourceSegmentIDs: ["tree-source"])
        notes.courseSummary = LFNotesSummary(englishNotes: "Course overview.", chineseNotes: "课程梳理。", keyTerms: [], mindMap: map)
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(notes)) as! [String: Any]
    }
    func chain(_ levels: Int) -> LFConceptNode {
        var node = LFConceptNode(id: "level-\(levels)", english: "Concept", chinese: "概念", children: [])
        if levels > 1 {
            for level in (1..<levels).reversed() {
                node = LFConceptNode(id: "level-\(level)", english: "Concept", chinese: "概念", children: [node])
            }
        }
        return node
    }
    let legacyObject = try object(nil)
    let legacy = try LFNotesService.decodeResponse(envelope(legacyObject), for: batch)
    check(legacy.courseSummary?.mindMap == nil, "Existing three-key summaries must decode without fabricating a mind map")
    await mustFail { _ = try LFNotesService.decodeResponse(envelope(legacyObject), for: batch, requireSummary: true) }
    let boundary = [chain(4)] + (1...36).map { LFConceptNode(id: "root-\($0)", english: "Concept", chinese: "概念", children: []) }
    let decoded = try LFNotesService.decodeResponse(envelope(object(boundary)), for: batch, requireSummary: true)
    check(decoded.courseSummary?.mindMap == boundary, "Exactly forty nodes and four levels must pass and retain bilingual relationships")
    let longLabel = [LFConceptNode(id: "label", english: String(repeating: "x", count: 160), chinese: String(repeating: "中", count: 160), children: [])]
    _ = try LFNotesService.decodeResponse(envelope(object(longLabel)), for: batch, requireSummary: true)
    let invalidMaps: [[LFConceptNode]] = [
        [], [chain(5)], boundary + [LFConceptNode(id: "node-41", english: "Extra", chinese: "多余", children: [])],
        [LFConceptNode(id: "same", english: "Root", chinese: "根", children: [LFConceptNode(id: "same", english: "Child", chinese: "子", children: [])])],
        [LFConceptNode(id: " ", english: "Root", chinese: "根", children: [])],
        [LFConceptNode(id: "blank", english: " ", chinese: "中文", children: [])],
        [LFConceptNode(id: "large-en", english: String(repeating: "x", count: 161), chinese: "中文", children: [])],
        [LFConceptNode(id: "large-zh", english: "English", chinese: String(repeating: "中", count: 161), children: [])]
    ]
    for map in invalidMaps {
        await mustFail { _ = try LFNotesService.decodeResponse(envelope(object(map)), for: batch, requireSummary: true) }
    }
    let malformedMaps: [Any] = [
        NSNull(), "not a tree",
        [["id": "missing-children", "english": "Root", "chinese": "根"] as [String: Any]],
        [["id": "null-children", "english": "Root", "chinese": "根", "children": NSNull()] as [String: Any]],
        [["id": "extra", "english": "Root", "chinese": "根", "children": [], "unsupported": "value"] as [String: Any]]
    ]
    for map in malformedMaps {
        var value = try object(fixtureMindMap())
        var summary = value["course_summary"] as! [String: Any]
        summary["mind_map"] = map
        value["course_summary"] = summary
        await mustFail { _ = try LFNotesService.decodeResponse(envelope(value), for: batch, requireSummary: true) }
    }
}

private func chineseCourseChecks(root: URL, configuration: LFCloudConfiguration) async throws {
    let store = try LFLessonStore(rootURL: root)
    let lesson = try await store.createLesson(title: "中文课堂自动化测试 · 水循环")
    check(lesson.effectiveLanguage == .english, "New and legacy unspecified courses default to English")
    _ = try await store.setLectureLanguage(.chinese, for: lesson.id)
    let opening = [
        LFConfirmedSegment(id: "ui-water-1", startTime: 0, endTime: 18, english: "太阳提供能量，使液态水蒸发成为水蒸气。"),
        LFConfirmedSegment(id: "ui-water-2", startTime: 18, endTime: 36, english: "水蒸气上升后冷却，凝……结成小水滴，形成云。")
    ]
    let audioURL = try await store.nextRecordingURL(for: lesson.id)
    let audio = Data([82, 73, 70, 70, 1, 3, 5, 7])
    try audio.write(to: audioURL)
    _ = try await store.registerRecording(lessonID: lesson.id, url: audioURL, duration: 54, offset: 0)
    _ = try await store.appendConfirmedSegments(opening, to: lesson.id)
    let mock = UIFixtureHTTP(sourceLanguage: "zh")
    let service = LFNotesService(store: store, transport: { try await mock.call($0) }, keyProvider: { _ in "fixture-key-never-on-disk" })
    let first = try await service.generatePending(lessonID: lesson.id, configuration: configuration)
    _ = try await store.updateNote(lessonID: lesson.id, noteID: first.notes[0].id,
                                 english: "Automated fixture edit: solar energy powers evaporation.", chinese: "保留用户编辑：太阳能驱动蒸发。")
    let final = LFConfirmedSegment(id: "ui-water-3", startTime: 36, endTime: 54, english: "水滴形成降水，水汇入河流和海洋，水循环重复进行。")
    _ = try await store.appendConfirmedSegments([final], to: lesson.id)
    let done = try await service.generatePending(lessonID: lesson.id, configuration: configuration)
    check(done.effectiveLanguage == .chinese && done.segments == opening + [final], "Bilingual generation must preserve original Chinese text, including ASR imperfections, in the historical source field")
    check(done.notes.count == 2 && done.notes[0].englishNotes.contains("Automated fixture edit") && done.courseSummary?.mindMap?.first?.children.count == 4,
          "Chinese requests must support two cumulative rounds, preserved edits and a complete bilingual concept tree")
    let reopened = try LFLessonStore(rootURL: root)
    let saved = try await reopened.loadLesson(lesson.id)
    check(saved.lectureLanguage == .chinese && saved.courseSummary == done.courseSummary && saved.audioFiles == done.audioFiles,
          "Language and concept-tree checkpoints must survive reopening alongside original audio references")
    for format in [LFExportFormat.markdown, .text] {
        let path = try await reopened.exportLesson(lesson.id, format: format)
        let exported = try String(contentsOf: path, encoding: .utf8)
        check(exported.contains("思维导图 / Mind map") && exported.contains("- Water cycle / 水循环")
              && exported.contains("  - Solar heat → evaporation / 太阳热量 → 蒸发")
              && exported.contains("保留用户编辑") && exported.contains(opening[1].english),
              "TXT and Markdown must export bilingual tree indentation, edits and untouched Chinese source")
    }
    _ = try await reopened.setLectureLanguage(.english, for: lesson.id)
    let switched = try await reopened.setLectureLanguage(.chinese, for: lesson.id)
    let savedAudio = try Data(contentsOf: audioURL)
    check(switched.notes == saved.notes && switched.segments == saved.segments && switched.courseSummary == saved.courseSummary
          && switched.audioFiles == saved.audioFiles && savedAudio == audio,
          "Changing language outside activity must preserve all existing course content and audio bytes")
    _ = try await reopened.appendConfirmedSegments([LFConfirmedSegment(id: "invalid-map-source", startTime: 54, endTime: 60, english: "水循环继续。")], to: lesson.id)
    let batch = try await reopened.prepareNextBatch(for: lesson.id)!
    let jsonURL = root.appendingPathComponent(lesson.id.uuidString).appendingPathComponent("lesson.json")
    let checkpoint = try Data(contentsOf: jsonURL)
    await mustFail { _ = try await reopened.setLectureLanguage(.english, for: lesson.id) }
    let invalidSummary = LFNotesSummary(englishNotes: "Must not replace.", chineseNotes: "不得覆盖。", keyTerms: [],
                                       mindMap: [LFConceptNode(id: "bad", english: "Invalid", chinese: String(repeating: "中", count: 161), children: [])])
    var invalidNotes = LFGeneratedNotes(englishNotes: "Must not append.", chineseNotes: "不得追加。", keyTerms: [], sourceSegmentIDs: ["invalid-map-source"])
    invalidNotes.courseSummary = invalidSummary
    await mustFail { _ = try await reopened.finishBatch(lessonID: lesson.id, batchID: batch.id, notes: invalidNotes) }
    await mustFail { _ = try await reopened.updateCourseSummary(invalidSummary, throughTime: 60, for: lesson.id) }
    check(try Data(contentsOf: jsonURL) == checkpoint, "Invalid concept trees and busy language switches must not partially persist notes, summary or language")
    _ = try await reopened.cancelBatches(for: lesson.id)
    let failure = RollingHTTP(failAt: 1, failure: .invalidMap)
    let failing = LFNotesService(store: reopened, transport: { try await failure.call($0) }, keyProvider: { _ in "fixture" })
    await mustFail { _ = try await failing.generatePending(lessonID: lesson.id, configuration: configuration) }
    let retained = try await reopened.loadLesson(lesson.id)
    check(retained.courseSummary == saved.courseSummary && retained.notes == saved.notes && retained.audioFiles == saved.audioFiles,
          "A real request path rejecting an invalid tree must retain the previous complete course summary, edits and audio")
}

private func createUIFixture(root: URL, configuration: LFCloudConfiguration) async throws {
    let store = try LFLessonStore(rootURL: root)
    let lesson = try await store.createLesson(title: "自动化测试课程 · 水循环（非真实云生成）")
    _ = try await store.appendConfirmedSegments([
        LFConfirmedSegment(id: "ui-water-1", startTime: 0, endTime: 18, english: "The Sun supplies energy for evaporation, turning liquid water into water vapor."),
        LFConfirmedSegment(id: "ui-water-2", startTime: 18, endTime: 36, english: "As water vapor rises and cools, condensation produces tiny droplets that form clouds.")
    ], to: lesson.id)
    let mock = UIFixtureHTTP()
    let service = LFNotesService(store: store, transport: { try await mock.call($0) }, keyProvider: { _ in "fixture-key-never-on-disk" })
    let first = try await service.generatePending(lessonID: lesson.id, configuration: configuration)
    check(first.notes.count == 1 && first.courseSummary != nil, "UI fixture round one must persist an outline and an editable progress note")
    let editedEnglish = first.notes[0].englishNotes + "\n\nAutomated fixture edit: keep the Sun as the cycle's energy source."
    let editedChinese = first.notes[0].chineseNotes + "\n\n自动化测试编辑：保留太阳作为循环能量来源。"
    _ = try await store.updateNote(lessonID: lesson.id, noteID: first.notes[0].id, english: editedEnglish, chinese: editedChinese)
    _ = try await store.appendConfirmedSegments([
        LFConfirmedSegment(id: "ui-water-3", startTime: 36, endTime: 54, english: "Droplets become precipitation; water collects in rivers and oceans, so the water cycle repeats.")
    ], to: lesson.id)
    _ = try await service.generatePending(lessonID: lesson.id, configuration: configuration)
    _ = try await store.setRecordingState(.paused, for: lesson.id)
    let reopened = try LFLessonStore(rootURL: root)
    let saved = try await reopened.loadLesson(lesson.id)
    check(await mock.calls == 2, "UI fixture must execute two real service rounds through injected HTTP")
    check(saved.segments.count == 3 && saved.notes.count == 2 && saved.notes[0].englishNotes == editedEnglish && saved.notes[0].chineseNotes == editedChinese,
          "UI fixture must preserve earlier edits while appending the second passage contribution")
    check(saved.courseSummaryThrough == 54 && saved.courseSummary?.englishNotes.contains("evaporation") == true && saved.courseSummary?.englishNotes.contains("precipitation") == true,
          "Persisted UI fixture must show both the earlier premise and later conclusion")
    check(saved.courseSummary?.mindMap?.first?.children.count == 4, "The populated UI fixture must include the final bilingual water-cycle concept tree")
    for format in [LFExportFormat.markdown, .text] {
        let url = try await reopened.exportLesson(lesson.id, format: format)
        let text = try String(contentsOf: url, encoding: .utf8)
        check(text.contains("自动化测试课程") && text.contains(saved.courseSummary!.englishNotes) && text.contains(saved.courseSummary!.chineseNotes)
              && text.contains("Automated fixture edit") && text.contains("思维导图 / Mind map") && text.contains("  - Solar heat → evaporation / 太阳热量 → 蒸发"),
              "UI fixture exports must include cumulative bilingual notes and preserved edits with a fixture label")
        print("UI fixture export: \(url.path)")
    }
    try checkNoStoredKey(root: root)
    print("UI fixture lesson: \(lesson.id.uuidString)")
    print("UI fixture JSON: \(root.appendingPathComponent(lesson.id.uuidString).appendingPathComponent("lesson.json").path)")
    print("UI fixture is scripted automation data; no microphone, real cloud inference or iPad acceptance is implied.")
}

@main
struct LectureFlowAssertions {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let uiFixtureRoot: URL?
        if arguments.count == 1 { uiFixtureRoot = nil }
        else {
            guard arguments.count == 3, arguments[1] == "--ui-fixture", !arguments[2].isEmpty else {
                throw LFError.invalid("Usage: notes-checks [--ui-fixture <store-root>]")
            }
            uiFixtureRoot = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        }
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
        try checkPromptContract(sent[0])
        check(sentContext["source_language"] as? String == "en", "Existing English courses must explicitly send en as their source language")
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
        try await mapContractChecks()
        try await chineseCourseChecks(root: root.appendingPathComponent("chinese", isDirectory: true), configuration: config)
        try checkNoStoredKey(root: root)
        print("LectureFlow assertions passed: dedup/conflict, 8k splitting, restart, token race, stale HTTP, retry, rolling summary/context, accumulation/flush, legacy migration/rebuild, bounded bilingual mind map, Chinese source, prompt contract, atomic failure preservation, edit/audio/tree export preservation, isolation, key redaction. Scripted responses do not verify live AI or ASR quality.")
        if let uiFixtureRoot { try await createUIFixture(root: uiFixtureRoot, configuration: config) }
    }
}
