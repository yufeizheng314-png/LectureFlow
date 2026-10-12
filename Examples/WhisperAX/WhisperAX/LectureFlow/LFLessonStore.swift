import Foundation

actor LFLessonStore {
    nonisolated let rootURL: URL
    private var recovered: Set<UUID> = []
    private var cancelledNoteRuns: Set<UUID> = []
    private var batchOwners: [UUID: UUID] = [:]

    init(rootURL: URL? = nil) throws {
        let base = rootURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LectureFlow", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.rootURL = base.standardizedFileURL.resolvingSymlinksInPath()
    }

    func createLesson(title: String) throws -> LFLesson {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 300 else { throw LFError.invalid("课程名称应为 1–300 个字符。") }
        let now = Date()
        let lesson = LFLesson(id: UUID(), title: clean, createdAt: now, modifiedAt: now)
        try persist(lesson)
        recovered.insert(lesson.id)
        return lesson
    }

    func loadLesson(_ id: UUID) throws -> LFLesson {
        let data = try Data(contentsOf: directory(id).appendingPathComponent("lesson.json"))
        var lesson = try JSONDecoder().decode(LFLesson.self, from: data)
        guard lesson.schemaVersion == 1, lesson.id == id else { throw LFError.invalid("课程文件版本或标识不匹配。") }
        if !recovered.contains(id) {
            if lesson.recordingState == .recording { lesson.recordingState = .paused }
            if lesson.notesState == .generating { lesson.notesState = .idle }
            for i in lesson.batches.indices where lesson.batches[i].state == .running {
                lesson.batches[i].state = .queued
                lesson.batches[i].error = nil
            }
            try persist(lesson)
            recovered.insert(id)
        }
        return lesson
    }

    func listLessons() throws -> [LFLesson] {
        try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .map { try loadLesson($0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func appendConfirmedSegments(_ segments: [LFConfirmedSegment], to id: UUID) throws -> LFLesson {
        var lesson = try loadLesson(id)
        var byID = Dictionary(uniqueKeysWithValues: lesson.segments.map { ($0.id, $0) })
        for segment in segments {
            guard !segment.id.isEmpty, segment.id.count <= 200,
                  segment.startTime.isFinite, segment.endTime.isFinite,
                  segment.startTime >= 0, segment.endTime >= segment.startTime,
                  !segment.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LFError.invalid("确认转写片段的标识、时间或内容无效。")
            }
            if let existing = byID[segment.id], existing != segment {
                throw LFError.conflict("确认片段 ID 已存在且内容不同；已保存的原文未被覆盖。")
            }
            byID[segment.id] = segment
        }
        lesson.segments = byID.values.sorted { $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime }
        return try save(lesson)
    }

    func setRecordingState(_ state: LFRecordingState, for id: UUID) throws -> LFLesson {
        var lesson = try loadLesson(id)
        lesson.recordingState = state
        return try save(lesson)
    }

    func renameLesson(_ id: UUID, title: String) throws -> LFLesson {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 300 else { throw LFError.invalid("课程名称应为 1–300 个字符。") }
        var lesson = try loadLesson(id)
        lesson.title = clean
        return try save(lesson)
    }

    func nextRecordingURL(for id: UUID) throws -> URL {
        var lesson = try loadLesson(id)
        let recordingID = UUID()
        let fileName = recordingID.uuidString + ".wav"
        lesson.audioFiles.append(LFRecordingFile(id: recordingID, fileName: fileName, duration: 0, offset: lesson.timelineDuration))
        _ = try save(lesson)
        return directory(id).appendingPathComponent(fileName)
    }

    func audioURL(for id: UUID) throws -> URL { try nextRecordingURL(for: id) }

    func cancelUnusedRecording(lessonID: UUID, url: URL) throws -> LFLesson {
        var lesson = try loadLesson(lessonID)
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.deletingLastPathComponent().path == directory(lessonID).resolvingSymlinksInPath().path,
              let index = lesson.audioFiles.firstIndex(where: { $0.fileName == canonical.lastPathComponent }),
              lesson.audioFiles[index].duration == 0 else { throw LFError.invalid("只能取消本课程尚未写入的录音。") }
        if FileManager.default.fileExists(atPath: canonical.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == 0 else {
                throw LFError.invalid("录音文件已有内容，已保留供恢复。")
            }
            try FileManager.default.removeItem(at: canonical)
        }
        lesson.audioFiles.remove(at: index)
        return try save(lesson)
    }

    func registerRecording(lessonID: UUID, url: URL, duration: Double, offset: Double) throws -> LFLesson {
        var lesson = try loadLesson(lessonID)
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        guard duration.isFinite, duration >= 0, offset.isFinite, offset >= 0,
              canonical.deletingLastPathComponent().path == directory(lessonID).resolvingSymlinksInPath().path,
              let index = lesson.audioFiles.firstIndex(where: { $0.fileName == canonical.lastPathComponent }),
              abs(lesson.audioFiles[index].offset - offset) < 0.001,
              FileManager.default.fileExists(atPath: canonical.path) else {
            throw LFError.invalid("录音文件、时间或课程目录不匹配；文件没有被移动或删除。")
        }
        lesson.audioFiles[index].duration = max(lesson.audioFiles[index].duration, duration)
        return try save(lesson)
    }

    func recordingURL(lessonID: UUID, file: LFRecordingFile) throws -> URL {
        let lesson = try loadLesson(lessonID)
        guard lesson.audioFiles.contains(where: { $0.id == file.id && $0.fileName == file.fileName }),
              file.fileName == file.id.uuidString + ".wav" else { throw LFError.invalid("未知录音文件。") }
        return directory(lessonID).appendingPathComponent(file.fileName)
    }

    func recordingURL(lessonID: UUID, fileID: UUID) throws -> URL {
        let lesson = try loadLesson(lessonID)
        guard let file = lesson.audioFiles.first(where: { $0.id == fileID }) else { throw LFError.invalid("未知录音文件。") }
        let url = try recordingURL(lessonID: lessonID, file: file).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == directory(lessonID).resolvingSymlinksInPath().path else {
            throw LFError.invalid("录音文件不在课程目录内。")
        }
        return url
    }

    func updateNote(lessonID: UUID, noteID: UUID, english: String, chinese: String) throws -> LFLesson {
        var lesson = try loadLesson(lessonID)
        guard let index = lesson.notes.firstIndex(where: { $0.id == noteID }) else { throw LFError.invalid("笔记不存在。") }
        lesson.notes[index].editedEnglishNotes = english
        lesson.notes[index].editedChineseNotes = chinese
        return try save(lesson)
    }

    func setNotesState(_ state: LFNotesState, error: String? = nil, for id: UUID, runToken: UUID? = nil) throws -> LFLesson {
        try checkRun(runToken)
        var lesson = try loadLesson(id)
        lesson.notesState = state
        lesson.notesError = error
        return try save(lesson)
    }

    func prepareNextBatch(for id: UUID, runToken: UUID? = nil) throws -> LFNoteBatch? {
        try checkRun(runToken)
        var lesson = try loadLesson(id)
        if let index = lesson.batches.firstIndex(where: { $0.state == .queued || $0.state == .failed }) {
            lesson.batches[index].state = .running
            lesson.batches[index].error = nil
            lesson.notesState = .generating
            lesson.notesError = nil
            _ = try save(lesson)
            if let runToken { batchOwners[lesson.batches[index].id] = runToken }
            return lesson.batches[index]
        }
        guard !lesson.batches.contains(where: { $0.state == .running }) else {
            throw LFError.conflict("本课程的笔记请求仍在进行。")
        }
        var consumed: [String: Int] = [:]
        for input in lesson.batches.flatMap(\.inputs) {
            consumed[input.segmentID] = max(consumed[input.segmentID] ?? 0, input.characterEnd)
        }
        var inputs: [LFNoteInput] = []
        var budget = 8000
        for segment in lesson.segments where inputs.count < 8 && budget > 0 {
            let characters = Array(segment.english)
            let start = consumed[segment.id] ?? 0
            guard start < characters.count else { continue }
            let end = min(characters.count, start + budget)
            inputs.append(LFNoteInput(segmentID: segment.id, startTime: segment.startTime, endTime: segment.endTime,
                                      characterStart: start, characterEnd: end, english: String(characters[start..<end])))
            budget -= end - start
        }
        guard !inputs.isEmpty else { return nil }
        let batch = LFNoteBatch(id: UUID(), inputs: inputs, state: .running)
        lesson.batches.append(batch)
        lesson.notesState = .generating
        lesson.notesError = nil
        _ = try save(lesson)
        if let runToken { batchOwners[batch.id] = runToken }
        return batch
    }

    func finishBatch(lessonID: UUID, batchID: UUID, notes: LFGeneratedNotes, runToken: UUID? = nil) throws -> LFLesson {
        try checkRun(runToken)
        if let runToken, batchOwners[batchID] != runToken { throw CancellationError() }
        var lesson = try loadLesson(lessonID)
        guard let index = lesson.batches.firstIndex(where: { $0.id == batchID }) else { throw LFError.invalid("笔记批次不存在。") }
        if lesson.batches[index].state == .completed { return lesson }
        guard lesson.batches[index].state == .running else { throw CancellationError() }
        try notes.validate(for: lesson.batches[index])
        lesson.notes.append(LFNoteBlock(id: UUID(), batchID: batchID,
            generatedEnglishNotes: notes.englishNotes, generatedChineseNotes: notes.chineseNotes,
            keyTerms: notes.keyTerms, sourceSegmentIDs: notes.sourceSegmentIDs))
        lesson.batches[index].state = .completed
        lesson.batches[index].error = nil
        lesson.notesState = .ready
        lesson.notesError = nil
        let saved = try save(lesson)
        batchOwners.removeValue(forKey: batchID)
        return saved
    }

    func failBatch(lessonID: UUID, batchID: UUID, message: String, runToken: UUID? = nil) throws -> LFLesson {
        try checkRun(runToken)
        if let runToken, batchOwners[batchID] != runToken { throw CancellationError() }
        var lesson = try loadLesson(lessonID)
        if let index = lesson.batches.firstIndex(where: { $0.id == batchID }), lesson.batches[index].state != .completed {
            lesson.batches[index].state = .failed
            lesson.batches[index].error = message
        }
        lesson.notesState = .failed
        lesson.notesError = message
        return try save(lesson)
    }

    func cancelBatches(for id: UUID, runToken: UUID? = nil) throws -> LFLesson {
        if let runToken { cancelledNoteRuns.insert(runToken) }
        var lesson = try loadLesson(id)
        for index in lesson.batches.indices where lesson.batches[index].state == .running &&
            (runToken == nil || batchOwners[lesson.batches[index].id] == runToken) {
            lesson.batches[index].state = .queued
            lesson.batches[index].error = nil
            batchOwners.removeValue(forKey: lesson.batches[index].id)
        }
        lesson.notesState = lesson.batches.contains(where: { $0.state == .running }) ? .generating : (lesson.notes.isEmpty ? .idle : .ready)
        lesson.notesError = nil
        return try save(lesson)
    }

    func exportLesson(_ id: UUID, format: LFExportFormat) throws -> URL {
        let lesson = try loadLesson(id)
        let heading = format == .markdown ? "# " : ""
        var text = "\(heading)\(lesson.title)\n\n"
        for note in lesson.notes {
            text += "English notes\n\(note.englishNotes)\n\n中文笔记\n\(note.chineseNotes)\n\n"
            text += note.keyTerms.map { "\($0.english) — \($0.chinese)" }.joined(separator: "\n")
            text += "\nSources: \(note.sourceSegmentIDs.joined(separator: ", "))\n\n"
        }
        text += "\(heading)Confirmed transcript / 确认转写\n\n"
        for segment in lesson.segments {
            text += String(format: "[%.2f–%.2f] ", segment.startTime, segment.endTime) + "\(segment.id): \(segment.english)\n\n"
        }
        let exports = rootURL.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let url = exports.appendingPathComponent(id.uuidString + (format == .markdown ? ".md" : ".txt"))
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private func directory(_ id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }

    private func checkRun(_ token: UUID?) throws {
        if let token, cancelledNoteRuns.contains(token) { throw CancellationError() }
    }

    private func save(_ lesson: LFLesson) throws -> LFLesson {
        var updated = lesson
        updated.modifiedAt = Date()
        try persist(updated)
        return updated
    }

    private func persist(_ lesson: LFLesson) throws {
        let folder = directory(lesson.id)
        guard folder.resolvingSymlinksInPath().deletingLastPathComponent().path == rootURL.path else {
            throw LFError.invalid("课程目录越界。")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(lesson).write(to: folder.appendingPathComponent("lesson.json"), options: .atomic)
    }
}
