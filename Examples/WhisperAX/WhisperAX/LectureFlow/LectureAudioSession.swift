import AVFoundation
import Combine
import Foundation
import WhisperKit

/// Audio lifecycle adapted from VivaDicta's StreamingAudioCapture / teardown
/// pattern, MIT, copyright © 2026 Anton Novoselov (see LectureFlowAudio-LICENSE.txt).
/// Uses the pinned Argmax WhisperKit public transcribe API; does not replace it.
@MainActor
final class LectureAudioSession: ObservableObject {
    enum State: String, Equatable {
        case idle, starting, recording, stopping, finished, interrupted, failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var partialText = ""
    @Published private(set) var partialSegments: [LectureTranscriptSegment] = []
    @Published private(set) var confirmedSegments: [LectureTranscriptSegment] = []
    @Published private(set) var recordingURL: URL?
    /// Durations here are relative to this file; segment timestamps include baseOffset.
    @Published private(set) var recordedDuration: Double = 0
    @Published private(set) var transcribedThrough: Double = 0
    @Published private(set) var errorMessage: String?
    var onConfirmedSegments: (([LectureTranscriptSegment]) -> Void)?
    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .starting || state == .recording || state == .stopping }
    var sessionGeneration: UUID { runID }

    private var capture: LectureAudioCapture?
    private var checkpoint: LectureAudioCheckpoint?
    private var runID = UUID()
    private var transcriptionTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var closedFrames: Int?
    private var asrFailure: String?
    private var terminalFailure: String?
    private var interrupted = false
    private var decodingLanguage = "en"

    func start(using whisper: WhisperKit, outputURL: URL, baseOffset: Double = 0, language: String = "en") async throws {
        guard !isBusy else { throw LectureAudioError.message("请先结束当前录音和尾部识别。") }
        let selectedLanguage = try LectureDecodingLanguage.validate(language)
        try validateModel(whisper, language: selectedLanguage)
        guard baseOffset.isFinite, baseOffset >= 0, outputURL.isFileURL else {
            throw LectureAudioError.message("无效的课程录音位置或时间偏移。")
        }
        reset()
        decodingLanguage = selectedLanguage
        state = .starting
        let generation = runID
        guard await AudioProcessor.requestRecordPermission() else {
            state = .failed
            errorMessage = "麦克风权限未获准，未开始录音。"
            throw LectureAudioError.message(errorMessage!)
        }
        guard runID == generation, state == .starting else {
            throw CancellationError()
        }
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: outputURL.path),
                  !FileManager.default.fileExists(atPath: checkpointURL(for: outputURL).path) else {
                throw LectureAudioError.message("该录音已存在；继续上课时应创建新的录音文件。")
            }
            recordingURL = outputURL
            checkpoint = LectureAudioCheckpoint(recordingID: outputURL.deletingPathExtension().lastPathComponent, baseOffset: baseOffset,
                committedFrames: 0, segments: [], captureClosed: false, interrupted: false, language: selectedLanguage)
            try saveCheckpoint()
            let recorder = try LectureAudioCapture(url: outputURL) { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.runID == generation else { return }
                    self.terminalFailure = message
                    await self.stop()
                }
            }
            capture = recorder
            try recorder.start()
            // Only a successful engine start can publish recording=true.
            state = .recording
            observeAudioChanges(generation: generation)
            transcriptionTask = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.transcribeLoop(using: whisper, generation: generation)
            }
            monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.runID == generation else { return }
                    self.updateDuration()
                    if self.state == .recording, self.capture?.isRunning == false {
                        await self.handleInterruption(generation)
                        return
                    }
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                }
            }
        } catch {
            terminalFailure = error.localizedDescription
            await stop()
            if state == .starting { state = .failed }
            errorMessage = error.localizedDescription
            throw error
        }
    }

    /// Stops the producer first, drains queued disk writes, closes the WAV, then
    /// drains every remaining bounded ASR window including the final short tail.
    func stop() async {
        if let stopTask { await stopTask.value; return }
        guard state == .recording || state == .starting else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.closeAndDrain()
        }
        stopTask = task
        await task.value
    }

    /// Replays only uncommitted audio from a prior interrupted/failed recording.
    /// Does not reopen the microphone or append to an old WAV.
    func recover(recordingURL url: URL, using whisper: WhisperKit, language: String = "en") async throws {
        try await resumeTranscription(using: whisper, from: url, baseOffset: nil, language: language)
    }

    func resumeTranscription(using whisper: WhisperKit, from url: URL, baseOffset: Double, language: String = "en") async throws {
        try await resumeTranscription(using: whisper, from: url, baseOffset: Optional(baseOffset), language: language)
    }

    private func resumeTranscription(using whisper: WhisperKit, from url: URL, baseOffset: Double?, language: String) async throws {
        guard !isBusy else { throw LectureAudioError.message("请先结束当前录音。") }
        guard whisper.modelState == .loaded, whisper.tokenizer != nil else {
            throw LectureAudioError.message("请先成功加载转写模型。")
        }
        var saved: LectureAudioCheckpoint
        if FileManager.default.fileExists(atPath: checkpointURL(for: url).path) {
            let data = try Data(contentsOf: checkpointURL(for: url))
            saved = try JSONDecoder().decode(LectureAudioCheckpoint.self, from: data)
            if let baseOffset, abs(baseOffset - saved.baseOffset) > 0.001 {
                throw LectureAudioError.message("此录音的课程时间偏移与检查点不一致。")
            }
        } else {
            guard let baseOffset, baseOffset.isFinite, baseOffset >= 0 else {
                throw LectureAudioError.message("录音缺少检查点，请从课程的补转写入口恢复。")
            }
            saved = LectureAudioCheckpoint(recordingID: url.deletingPathExtension().lastPathComponent,
                baseOffset: baseOffset, committedFrames: 0, segments: [], captureClosed: true, interrupted: true)
        }
        let selectedLanguage = try saved.languageForRecovery(fallback: language)
        try validateModel(whisper, language: selectedLanguage)
        let frames = try LecturePCMStore.repairClosedFile(at: url)
        guard saved.committedFrames >= 0, saved.committedFrames <= frames,
              saved.baseOffset.isFinite, saved.baseOffset >= 0, !saved.recordingID.isEmpty else {
            throw LectureAudioError.message("录音检查点与原音不一致，未覆盖已有文字。")
        }
        reset()
        decodingLanguage = selectedLanguage
        recordingURL = url
        saved.captureClosed = true
        saved.language = selectedLanguage
        checkpoint = saved
        closedFrames = frames
        confirmedSegments = saved.segments
        transcribedThrough = Double(saved.committedFrames) / 16_000
        recordedDuration = Double(frames) / 16_000
        state = .stopping
        do { try saveCheckpoint() } catch { state = .failed; errorMessage = error.localizedDescription; throw error }
        onConfirmedSegments?(saved.segments)
        await transcribeLoop(using: whisper, generation: runID)
        state = asrFailure == nil ? .finished : .failed
    }

    private func reset() {
        removeObservers()
        monitorTask?.cancel()
        runID = UUID()
        stopTask = nil
        capture = nil
        checkpoint = nil
        closedFrames = nil
        asrFailure = nil
        terminalFailure = nil
        interrupted = false
        decodingLanguage = "en"
        errorMessage = nil
        partialText = ""
        partialSegments = []
        confirmedSegments = []
        recordedDuration = 0
        transcribedThrough = 0
        recordingURL = nil
    }

    private func validateModel(_ whisper: WhisperKit, language: String) throws {
        guard whisper.modelState == .loaded, let tokenizer = whisper.tokenizer else {
            throw LectureAudioError.message("请先准备转写模型；模型尚未成功加载。")
        }
        if language == "zh" {
            guard whisper.textDecoder.isModelMultilingual,
                  let token = tokenizer.convertTokenToId("<|zh|>"),
                  tokenizer.allLanguageTokens.contains(token) else {
                throw LectureAudioError.message("中文转写需要支持中文的多语言模型，请重新准备模型。")
            }
        }
    }

    private func closeAndDrain() async {
        state = .stopping
        removeObservers()
        if let capture {
            do {
                closedFrames = try await capture.stop()
                checkpoint?.captureClosed = true
            } catch {
                terminalFailure = terminalFailure ?? error.localizedDescription
                // The raw file remains recoverable. Do not advertise successful closure.
                closedFrames = capture.snapshotFrames()
            }
        } else {
            closedFrames = 0
        }
        updateDuration()
        checkpoint?.interrupted = interrupted
        do { try saveCheckpoint() } catch { terminalFailure = terminalFailure ?? error.localizedDescription }
        await transcriptionTask?.value
        monitorTask?.cancel()
        monitorTask = nil
        capture = nil
        partialText = ""
        partialSegments = []
        if let message = terminalFailure ?? asrFailure {
            errorMessage = "录音已停止，请检查并恢复原音：" + message
            state = .failed
        } else if interrupted {
            errorMessage = "音频被系统或输入设备变化中断；已关闭并保存本段，继续时请新建录音。"
            state = .interrupted
        } else {
            state = .finished
        }
    }

    private func updateDuration() {
        let frames = closedFrames ?? capture?.snapshotFrames() ?? 0
        recordedDuration = Double(frames) / 16_000
    }

    private func transcribeLoop(using whisper: WhisperKit, generation: UUID) async {
        var lastReadEnd = -LectureAudioWindowing.updateFrames
        while runID == generation, !Task.isCancelled {
            guard let url = recordingURL, let saved = checkpoint else { return }
            let available = closedFrames ?? capture?.snapshotFrames() ?? 0
            let isClosed = closedFrames != nil
            guard let window = LectureAudioWindowing.next(committed: saved.committedFrames,
                                                         available: available, closed: isClosed) else {
                if isClosed { return }
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                continue
            }
            if !window.canCommit && (window.readEnd - lastReadEnd < LectureAudioWindowing.updateFrames ||
                                     window.readEnd - window.ownedStart < LectureAudioWindowing.updateFrames) {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                continue
            }
            do {
                let samples = try LecturePCMStore.read(url: url, from: window.readStart, through: window.readEnd)
                let input = try LectureAudioNormalization.prepareForInference(samples)
                var words: [LectureRecognizedWord] = []
                if input.aboveNoiseFloor {
                    let options = DecodingOptions(verbose: false, task: .transcribe, language: decodingLanguage,
                        temperatureFallbackCount: 1, sampleLength: 224, usePrefillPrompt: true,
                        detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: false,
                        wordTimestamps: true, windowClipTime: 0, concurrentWorkerCount: 1)
                    let results = try await whisper.transcribe(audioArray: input.samples, decodeOptions: options)
                    guard runID == generation else { return }
                    let segments = results.flatMap(\.segments)
                    // Chinese uses WhisperKit's Unicode-token alignment, not spaces.
                    // Missing timings must not silently discard a crossing segment.
                    if segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.words?.isEmpty ?? true) }) {
                        throw LectureAudioError.message("识别未返回逐词时间戳；原音保留，稍后可重新识别。")
                    }
                    words = segments.flatMap { $0.words ?? [] }.map {
                        LectureRecognizedWord(start: Double($0.start), end: Double($0.end), text: $0.word)
                    }
                }
                guard runID == generation else { return }
                try LectureAudioWindowing.validateWordTimings(words, sampleCount: samples.count)
                let segment = LectureAudioWindowing.segment(words: words, window: window,
                    recordingID: saved.recordingID, baseOffset: saved.baseOffset)
                lastReadEnd = window.readEnd
                if window.canCommit {
                    var next = checkpoint!
                    // A disk checkpoint atomically owns both text and its consumed watermark.
                    if let segment { next.segments.append(segment) }
                    next.committedFrames = window.ownedEnd
                    try saveCheckpoint(next)
                    checkpoint = next
                    confirmedSegments = next.segments
                    transcribedThrough = Double(next.committedFrames) / 16_000
                    partialText = ""
                    partialSegments = []
                    if let segment { onConfirmedSegments?([segment]) }
                    lastReadEnd = -LectureAudioWindowing.updateFrames
                } else {
                    partialText = segment?.text ?? ""
                    partialSegments = segment.map { [$0] } ?? []
                }
            } catch {
                asrFailure = error.localizedDescription
                errorMessage = "实时识别暂停，原音继续保存在磁盘；结束后可恢复识别：" + error.localizedDescription
                return
            }
        }
    }

    private func checkpointURL(for url: URL) -> URL { url.appendingPathExtension("transcript.json") }
    private func saveCheckpoint(_ value: LectureAudioCheckpoint? = nil) throws {
        guard let value = value ?? checkpoint, let url = recordingURL else { return }
        let path = checkpointURL(for: url)
        try JSONEncoder().encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path.path)
    }

    private func observeAudioChanges(generation: UUID) {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
            object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in await self?.handleInterruption(generation) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ||
                  raw == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue else { return }
            Task { @MainActor [weak self] in await self?.handleInterruption(generation) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.handleInterruption(generation) }
        })
    }

    private func handleInterruption(_ generation: UUID) async {
        guard runID == generation, state == .recording else { return }
        interrupted = true
        await stop()
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}

/// The tap only copies into a two-second bounded queue. The serial disk queue
/// converts and writes; Whisper decoding never owns or blocks that queue.
private final class LectureAudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "LectureFlow.audio.disk", qos: .userInitiated)
    private let lock = NSLock()
    private let onFailure: @Sendable (String) -> Void
    private let store: LecturePCMStore
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var pendingFrames = 0
    private var writtenFrames = 0
    private var accepting = false
    private var failed = false
    private var tapInstalled = false
    private var sessionActivated = false
    private var writeError: Error?
    var isRunning: Bool { engine.isRunning }

    init(url: URL, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.onFailure = onFailure
        store = try LecturePCMStore(url: url)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setActive(true)
        sessionActivated = true
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw LectureAudioError.message("麦克风音频格式不可用。")
        }
        self.converter = converter
        outputFormat = output
        lock.lock(); accepting = true; lock.unlock()
        installLectureInputTap(engine.inputNode, format: format, capture: self)
        tapInstalled = true
        engine.prepare()
        try engine.start()
        guard engine.isRunning else { throw LectureAudioError.message("麦克风引擎未能启动。") }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        lock.lock()
        guard accepting, !failed else { lock.unlock(); return }
        guard pendingFrames + count <= Int(buffer.format.sampleRate * 2) else {
            failed = true
            lock.unlock()
            onFailure("磁盘写入跟不上录音，已停止接收新音频；已写原音仍保留。")
            return
        }
        pendingFrames += count
        lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            lock.lock(); pendingFrames -= count; lock.unlock()
            reportFailure(LectureAudioError.message("无法分配有限录音缓冲。"))
            return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData else {
                lock.lock(); pendingFrames -= count; lock.unlock()
                reportFailure(LectureAudioError.message("麦克风缓冲不可读。")); return
            }
            memcpy(dst, src, Int(from.mDataByteSize))
        }
        queue.async { [self] in
            defer { lock.lock(); pendingFrames -= count; lock.unlock() }
            lock.lock(); let hasWriteError = writeError != nil; lock.unlock()
            guard !hasWriteError else { return }
            do { try convert(copy, finishing: false) } catch { reportFailure(error) }
        }
    }

    func snapshotFrames() -> Int {
        lock.lock(); defer { lock.unlock() }
        return writtenFrames
    }

    func stop() async throws -> Int {
        // Silence the producer before the barrier closes the file.
        stopAccepting()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        let result: Result<Int, Error> = await withCheckedContinuation { continuation in
            queue.async { [self] in
                lock.lock(); var failure = writeError; lock.unlock()
                if failure == nil {
                    do { try convert(nil, finishing: true) } catch { failure = error }
                }
                do { try store.finish() } catch { failure = failure ?? error }
                lock.lock(); writtenFrames = store.frames; lock.unlock()
                continuation.resume(returning: failure.map { .failure($0) } ?? .success(store.frames))
            }
        }
        if sessionActivated {
            do { try AVAudioSession.sharedInstance().setActive(false) }
            catch { onFailure("音频会话停用失败：" + error.localizedDescription) }
            sessionActivated = false
        }
        return try result.get()
    }

    private func convert(_ input: AVAudioPCMBuffer?, finishing: Bool) throws {
        guard let converter, let outputFormat else { return }
        let capacity = input.map { AVAudioFrameCount(ceil(Double($0.frameLength) * 16_000 / $0.format.sampleRate)) + 512 } ?? 1024
        var delivered = false
        for _ in 0..<(finishing ? 4 : 1) {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw LectureAudioError.message("无法转换麦克风音频。")
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                if finishing { state.pointee = .endOfStream; return nil }
                if delivered { state.pointee = .noDataNow; return nil }
                delivered = true; state.pointee = .haveData; return input
            }
            if let conversionError { throw conversionError }
            if status == .error { throw LectureAudioError.message("麦克风格式转换失败。") }
            if output.frameLength > 0, let samples = output.floatChannelData?[0] {
                try store.append(Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))))
                lock.lock(); writtenFrames = store.frames; lock.unlock()
            }
            if !finishing || status == .endOfStream || output.frameLength == 0 { return }
        }
        throw LectureAudioError.message("音频转换器尾部未能完整写盘。")
    }

    private func reportFailure(_ error: Error) {
        lock.lock()
        let shouldReport = !failed
        failed = true
        if writeError == nil { writeError = error }
        lock.unlock()
        if shouldReport { onFailure(error.localizedDescription) }
    }

    private func stopAccepting() {
        lock.lock(); accepting = false; lock.unlock()
    }
}

/// Deliberately outside MainActor: an AVAudioEngine tap runs on its audio thread.
private func installLectureInputTap(_ node: AVAudioInputNode, format: AVAudioFormat, capture: LectureAudioCapture) {
    node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in capture.enqueue(buffer) }
}
