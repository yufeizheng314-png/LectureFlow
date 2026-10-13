// LectureFlow integration of the existing WhisperAX / WhisperKit project.
import AVFoundation
import Combine
import Foundation
import WhisperKit

@MainActor
final class LectureFlowModel: ObservableObject {
    @Published private(set) var lessons: [LFLesson] = []
    @Published private(set) var lesson: LFLesson?
    @Published private(set) var modelStatus = "尚未准备英文模型"
    @Published private(set) var modelProgress: Double = 0
    @Published private(set) var preparingModel = false
    @Published private(set) var modelReady = false
    @Published private(set) var busy = false
    @Published private(set) var generatingNotes = false
    @Published private(set) var rebuildingSummary = false
    @Published private(set) var configuration: LFCloudConfiguration?
    @Published private(set) var autoNotesEnabled = false
    @Published var errorMessage: String?
    @Published var exportURL: URL?
    @Published private(set) var playing = false
    let audio = LectureAudioSession()

    private var store: LFLessonStore?
    private var notesService: LFNotesService?
    private var whisper: WhisperKit?
    private var observations = Set<AnyCancellable>()
    private var notesTask: Task<Void, Never>?
    private var notesToken: UUID?
    private var notesNeedAnotherPass = false
    private var notesForceFlush = false
    private var player: AVAudioPlayer?
    private var playbackToken = UUID()
    private struct Capture {
        let id: UUID
        let lessonID: UUID
        let url: URL
        let offset: Double
        let previousAudioGeneration: UUID
        let isRecovery: Bool
    }
    private var capture: Capture?
    private var finalizingCapture = false
    private var initialized = false

    var hasCapture: Bool { capture != nil || finalizingCapture }
    var canChangeLesson: Bool { !hasCapture && !busy }
    var lectureLanguage: LFLectureLanguage { lesson?.effectiveLanguage ?? .english }
    private var decodingLanguage: String { lectureLanguage == .chinese ? "zh" : "en" }

    init() {
        do {
            let storage = try LFLessonStore()
            store = storage
            notesService = LFNotesService(store: storage)
            configuration = try LFCloudConfiguration.load()
            // Reopening the app does not silently restart cloud transmission.
            autoNotesEnabled = false
        } catch { errorMessage = error.localizedDescription }
        audio.$confirmedSegments.dropFirst().sink { [weak self] _ in
            guard let self, let current = self.capture else { return }
            Task { _ = await self.persistConfirmed(for: current) }
        }.store(in: &observations)
        audio.$state.dropFirst().sink { [weak self] state in
            guard let self else { return }
            self.objectWillChange.send()
            switch state {
            case .finished, .interrupted, .failed:
                if let message = self.audio.errorMessage { self.errorMessage = message }
                if self.capture != nil { Task { await self.finishCapture() } }
            default: break
            }
        }.store(in: &observations)
        audio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    func initialize() async {
        guard !initialized, let store else { return }
        initialized = true
        do {
            lessons = try await store.listLessons()
            if let first = lessons.first { lesson = try await store.loadLesson(first.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func createLesson(title: String) async {
        guard canChangeLesson, let store else { return }
        busy = true
        defer { busy = false }
        await cancelNotes()
        stopPlayback()
        do {
            lesson = try await store.createLesson(title: title)
            lessons = try await store.listLessons()
        } catch { errorMessage = error.localizedDescription }
    }

    func selectLesson(_ id: UUID) async {
        guard canChangeLesson, lesson?.id != id, let store else { return }
        busy = true
        defer { busy = false }
        await cancelNotes()
        stopPlayback()
        do { lesson = try await store.loadLesson(id) }
        catch { errorMessage = error.localizedDescription }
    }

    func setLectureLanguage(_ language: LFLectureLanguage) async {
        guard canChangeLesson, !preparingModel, let current = lesson, let store else { return }
        busy = true
        defer { busy = false }
        await cancelNotes()
        guard lesson?.id == current.id else { return }
        do {
            lesson = try await store.setLectureLanguage(language, for: current.id)
            lessons = try await store.listLessons()
        } catch { errorMessage = error.localizedDescription }
    }

    func prepareModel() async {
        guard !preparingModel, !hasCapture else { return }
        preparingModel = true
        modelReady = false
        modelProgress = 0
        defer { preparingModel = false }
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LectureFlow/Models", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let cachedName = UserDefaults.standard.string(forKey: "LectureFlow.multilingual-base.folder")
            let cached = cachedName.map { base.appendingPathComponent($0, isDirectory: true) }
            let folder: URL
            if let cached, FileManager.default.fileExists(atPath: cached.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                modelStatus = "正在加载已缓存的中英课堂模型"
                folder = cached
            } else {
                modelStatus = "首次下载中英课堂模型，需要联网"
                folder = try await WhisperKit.download(variant: "openai_whisper-base", downloadBase: base) { [weak self] progress in
                    Task { @MainActor in self?.modelProgress = progress.fractionCompleted }
                }
                let relative = folder.path.replacingOccurrences(of: base.path + "/", with: "")
                UserDefaults.standard.set(relative, forKey: "LectureFlow.multilingual-base.folder")
            }
            modelStatus = "正在准备本机模型，首次可能需要几分钟"
            let kit = try await WhisperKit(WhisperKitConfig(
                model: "base", modelFolder: folder.path,
                verbose: false, logLevel: .none, prewarm: true, load: true, download: false
            ))
            guard let tokenizer = kit.tokenizer, kit.modelState == .loaded,
                  kit.modelVariant == .base, kit.textDecoder.isModelMultilingual,
                  let chineseToken = tokenizer.convertTokenToId("<|zh|>"),
                  tokenizer.allLanguageTokens.contains(chineseToken) else {
                throw LFError.invalid("模型尚未完整加载，请重新准备。")
            }
            whisper = kit
            modelReady = true
            modelProgress = 1
            modelStatus = "中英课堂模型已准备 · 识别在 iPad 本机运行"
        } catch {
            whisper = nil
            modelStatus = "课堂模型准备失败，可重试"
            errorMessage = error.localizedDescription
        }
    }

    func startRecording() async {
        guard !hasCapture, !busy, let store, let whisper, modelReady, let current = lesson else { return }
        busy = true
        defer { busy = false }
        stopPlayback()
        do {
            let url = try await store.nextRecordingURL(for: current.id)
            let reservation = try await store.loadLesson(current.id)
            let offset = reservation.audioFiles.first(where: { $0.fileName == url.lastPathComponent })?.offset ?? current.timelineDuration
            let next = Capture(id: UUID(), lessonID: current.id, url: url, offset: offset,
                               previousAudioGeneration: audio.sessionGeneration, isRecovery: false)
            capture = next
            try await audio.start(using: whisper, outputURL: url, baseOffset: offset, language: decodingLanguage)
            lesson = try await store.setRecordingState(.recording, for: current.id)
        } catch {
            errorMessage = error.localizedDescription
            // A storage failure after the microphone starts must close it as well.
            await audio.stop()
            await finishCapture()
        }
    }

    func pauseRecording() async {
        guard capture != nil, !busy else { return }
        busy = true
        await audio.stop()
        await finishCapture()
        busy = false
    }

    private func persistConfirmed(for current: Capture) async -> Bool {
        guard capture?.id == current.id, ownsAudio(current), let store else { return false }
        let segments = audio.confirmedSegments.map {
            LFConfirmedSegment(id: $0.id, startTime: $0.start, endTime: $0.end, english: $0.text)
        }
        do {
            let saved = try await store.appendConfirmedSegments(segments, to: current.lessonID)
            if lesson?.id == current.lessonID { lesson = saved }
            scheduleNotes()
            return true
        } catch {
            errorMessage = "转写保存失败：\(error.localizedDescription)。请保留原录音后重试。"
            await audio.stop()
            return false
        }
    }

    private func finishCapture() async {
        guard !finalizingCapture, let current = capture, let store else { return }
        finalizingCapture = true
        defer { finalizingCapture = false }
        guard ownsAudio(current) else {
            // Recovery validates before resetting the audio session. A failed preflight
            // must never attach the previous session's transcript or duration here.
            do {
                if !current.isRecovery && !FileManager.default.fileExists(atPath: current.url.path) {
                    _ = try await store.cancelUnusedRecording(lessonID: current.lessonID, url: current.url)
                    let saved = try await store.setRecordingState(.paused, for: current.lessonID)
                    if lesson?.id == current.lessonID { lesson = saved }
                }
                capture = nil
            } catch { errorMessage = error.localizedDescription }
            return
        }
        guard await persistConfirmed(for: current) else { return }
        do {
            if FileManager.default.fileExists(atPath: current.url.path) {
                _ = try await store.registerRecording(lessonID: current.lessonID, url: current.url,
                                                      duration: audio.recordedDuration, offset: current.offset)
            } else {
                _ = try await store.cancelUnusedRecording(lessonID: current.lessonID, url: current.url)
            }
            let saved = try await store.setRecordingState(.paused, for: current.lessonID)
            if lesson?.id == current.lessonID { lesson = saved }
            lessons = try await store.listLessons()
            capture = nil
            scheduleNotes()
        } catch {
            errorMessage = "录音检查点保存失败：\(error.localizedDescription)。原音仍在课程目录，请重试保存。"
            // Keep the reservation/capture so users cannot accidentally start a second session.
        }
    }

    private func ownsAudio(_ current: Capture) -> Bool {
        audio.sessionGeneration != current.previousAudioGeneration &&
        audio.recordingURL?.standardizedFileURL.resolvingSymlinksInPath().path ==
            current.url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func saveCloudSettings(endpoint: String, model: String, newKey: String, enabled: Bool) async throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LFError.invalid("请输入完整 HTTPS chat/completions 地址。")
        }
        let value = LFCloudConfiguration(endpoint: url, model: model.trimmingCharacters(in: .whitespacesAndNewlines))
        try value.validate()
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            guard configuration?.endpoint == value.endpoint, try LFKeychain.read(for: value.endpoint) != nil else {
                throw LFError.invalid("首次设置或更换服务地址时，请重新填写该服务的 API Key。")
            }
        }
        await cancelNotes()
        if !key.isEmpty { try LFKeychain.save(key, for: value.endpoint) }
        try value.save()
        configuration = value
        autoNotesEnabled = enabled
        if enabled { scheduleNotes(immediate: true) }
    }

    func setAutoNotes(_ enabled: Bool) async {
        autoNotesEnabled = enabled && configuration != nil
        if autoNotesEnabled { scheduleNotes(immediate: true) }
        else { await cancelNotes() }
    }

    func generateNotesNow() {
        guard autoNotesEnabled else {
            errorMessage = "请先在 AI 设置中明确启用双语笔记。仅发送已确认文本，录音保留在本机。"
            return
        }
        scheduleNotes(immediate: true)
    }

    func rebuildCourseNotes() async {
        guard let id = lesson?.id, autoNotesEnabled, configuration != nil, !hasCapture, !busy,
              lesson?.segments.isEmpty == false, !generatingNotes else { return }
        await cancelNotes()
        guard lesson?.id == id, !busy, !hasCapture else { return }
        scheduleNotes(immediate: true, rebuildSummary: true)
    }

    private func scheduleNotes(immediate: Bool = false, rebuildSummary: Bool = false) {
        guard autoNotesEnabled, let current = lesson, !current.segments.isEmpty,
              let config = configuration, let notesService else { return }
        guard immediate || current.notesState != .failed else { return }
        guard notesTask == nil else {
            notesNeedAnotherPass = true
            notesForceFlush = notesForceFlush || immediate
            return
        }
        notesNeedAnotherPass = false
        let token = UUID()
        notesToken = token
        notesTask = Task { [weak self] in
            guard let self else { return }
            if !immediate {
                do { try await Task.sleep(nanoseconds: 8_000_000_000) }
                catch { return }
            }
            guard !Task.isCancelled, self.notesToken == token else { return }
            self.generatingNotes = true
            self.rebuildingSummary = rebuildSummary
            // Show each persisted batch while a longer cloud catch-up is still running.
            let refresh = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                    guard let self, self.notesToken == token, self.lesson?.id == current.id,
                          let store = self.store else { return }
                    do {
                        let latest = try await store.loadLesson(current.id)
                        guard self.notesToken == token, self.lesson?.id == current.id else { return }
                        self.lesson = latest
                    } catch { return }
                }
            }
            defer { refresh.cancel() }
            var succeeded = false
            do {
                let flush = immediate || self.notesForceFlush || !self.hasCapture
                self.notesForceFlush = false
                let saved = try await notesService.generatePending(lessonID: current.id, configuration: config,
                    flushPending: flush, rebuildSummary: rebuildSummary)
                if self.lesson?.id == current.id, self.notesToken == token { self.lesson = saved }
                if let store = self.store { self.lessons = try await store.listLessons() }
                succeeded = true
            } catch {
                if !Task.isCancelled, self.notesToken == token { self.errorMessage = error.localizedDescription }
                if let store = self.store, self.lesson?.id == current.id {
                    if let latest = try? await store.loadLesson(current.id), self.notesToken == token,
                       self.lesson?.id == current.id {
                        self.lesson = latest
                    }
                }
            }
            if self.notesToken == token {
                self.generatingNotes = false
                self.rebuildingSummary = false
                self.notesTask = nil
                self.notesToken = nil
                if succeeded && self.notesNeedAnotherPass { self.scheduleNotes(immediate: self.notesForceFlush) }
            }
        }
    }

    private func cancelNotes() async {
        notesToken = nil
        notesTask?.cancel()
        notesTask = nil
        generatingNotes = false
        rebuildingSummary = false
        notesNeedAnotherPass = false
        notesForceFlush = false
        if let id = lesson?.id, let notesService {
            do { _ = try await notesService.cancel(lessonID: id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func editNote(_ note: LFNoteBlock, lessonID: UUID, english: String, chinese: String) async throws {
        guard let store else { return }
        let saved = try await store.updateNote(lessonID: lessonID, noteID: note.id, english: english, chinese: chinese)
        if lesson?.id == lessonID { lesson = saved }
    }

    func export(_ format: LFExportFormat) async {
        guard let id = lesson?.id, let store else { return }
        do { exportURL = try await store.exportLesson(id, format: format) }
        catch { errorMessage = error.localizedDescription }
    }

    func exportPDF() async {
        guard let current = lesson, let store else { return }
        do {
            let textURL = try await store.exportLesson(current.id, format: .text)
            let text = try String(contentsOf: textURL, encoding: .utf8)
            let target = textURL.deletingPathExtension().appendingPathExtension("pdf")
            try LecturePDFExport.write(text: text, title: current.title, to: target)
            exportURL = target
        } catch { errorMessage = error.localizedDescription }
    }

    func play(at seconds: Double = 0, fileID: UUID? = nil) async {
        guard !hasCapture, let current = lesson, let store else { return }
        guard let file = fileID.flatMap({ id in current.audioFiles.first { $0.id == id } })
                ?? current.audioFiles.first(where: { $0.duration > 0 && seconds >= $0.offset && seconds < $0.offset + $0.duration }) else { return }
        let token = UUID()
        playbackToken = token
        do {
            let url = try await store.recordingURL(lessonID: current.id, fileID: file.id)
            guard playbackToken == token, !hasCapture, lesson?.id == current.id else { return }
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let value = try AVAudioPlayer(contentsOf: url)
            value.currentTime = max(0, seconds - file.offset)
            guard value.play() else { throw LFError.invalid("录音暂时不能播放。") }
            player = value
            playing = true
        } catch { if playbackToken == token { errorMessage = error.localizedDescription } }
    }

    func stopPlayback() {
        playbackToken = UUID()
        player?.stop()
        player = nil
        playing = false
    }

    func exportAudio(_ id: UUID) async {
        guard !hasCapture, let current = lesson, let store else { return }
        do { exportURL = try await store.recordingURL(lessonID: current.id, fileID: id) }
        catch { errorMessage = error.localizedDescription }
    }

    func recoverAudio(_ id: UUID) async {
        guard !hasCapture, !busy, let current = lesson, let store, let whisper, modelReady,
              let file = current.audioFiles.first(where: { $0.id == id }) else { return }
        busy = true
        defer { busy = false }
        stopPlayback()
        do {
            let url = try await store.recordingURL(lessonID: current.id, fileID: id)
            capture = Capture(id: UUID(), lessonID: current.id, url: url, offset: file.offset,
                              previousAudioGeneration: audio.sessionGeneration, isRecovery: true)
            try await audio.resumeTranscription(using: whisper, from: url, baseOffset: file.offset, language: decodingLanguage)
            await finishCapture()
        } catch {
            errorMessage = error.localizedDescription
            await finishCapture()
        }
    }
}
