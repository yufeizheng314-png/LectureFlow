// LectureFlow additions to the existing WhisperAX app.
import SwiftUI
import UIKit

struct LectureFlowView: View {
    @ObservedObject var model: LectureFlowModel
    @State private var showingSettings = false
    @State private var showingNewLesson = false
    @State private var lessonTitle = ""
    @State private var editingNote: LFNoteBlock?
    @State private var editingLessonID: UUID?
    @State private var sharedDocument: LectureShareDocument?
    @State private var showingMindMap = false
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationSplitView {
            List {
                Section("课程") {
                    ForEach(model.lessons) { lesson in
                        Button {
                            Task { await model.selectLesson(lesson.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(lesson.title).font(.headline).foregroundStyle(.primary)
                                Text(lesson.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                Text("\(lesson.segments.count) 段原文 · \(lesson.notes.count) 组双语笔记")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!model.canChangeLesson)
                        .listRowBackground(model.lesson?.id == lesson.id ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                    if model.lessons.isEmpty {
                        Text("创建课程，准备中英课堂模型后开始录音。")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("LectureFlow")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("新课程", systemImage: "plus") {
                        lessonTitle = "课堂 \(Date.now.formatted(date: .abbreviated, time: .shortened))"
                        showingNewLesson = true
                    }.disabled(!model.canChangeLesson)
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
        } detail: {
            VStack(spacing: 0) {
                controls
                Divider()
                if let lesson = model.lesson {
                    if sizeClass == .compact {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                transcript(lesson)
                                notes(lesson)
                            }.padding()
                        }
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                            ScrollView { transcript(lesson).padding() }
                            Divider()
                            ScrollView { notes(lesson).padding() }
                        }
                    }
                } else {
                    ContentUnavailableView("开始一堂课", systemImage: "book.closed",
                                           description: Text("点击“新课程”，英文原音和转写保存在 iPad。"))
                }
            }
            .navigationTitle(model.lesson?.title ?? "课堂双语笔记")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("AI 设置", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Markdown") { Task { await model.export(.markdown) } }
                        Button("TXT") { Task { await model.export(.text) } }
                        Button("PDF") { Task { await model.exportPDF() } }
                    } label: { Label("导出笔记", systemImage: "square.and.arrow.up") }
                        .disabled(model.lesson == nil)
                }
            }
        }
        .task { await model.initialize() }
        .sheet(isPresented: $showingSettings) { LectureCloudSettings(model: model) }
        .fullScreenCover(isPresented: $showingMindMap) {
            if let lesson = model.lesson, let nodes = lesson.courseSummary?.mindMap {
                NavigationStack {
                    GeometryReader { geometry in
                        LFNotesMapView(title: lesson.title, nodes: nodes,
                                       viewportHeight: max(420, geometry.size.height - 110)).padding()
                    }
                        .navigationTitle("课堂思维导图")
                        .toolbar { Button("完成") { showingMindMap = false } }
                }
            }
        }
        .sheet(item: $editingNote) { note in
            if let lessonID = editingLessonID { LectureNoteEditor(model: model, note: note, lessonID: lessonID) }
        }
        .sheet(item: $sharedDocument, onDismiss: { model.exportURL = nil }) { document in
            LectureShareView(url: document.url)
        }
        .onChange(of: model.exportURL) { _, url in
            if let url { sharedDocument = LectureShareDocument(url: url) }
        }
        .alert("新建课程", isPresented: $showingNewLesson) {
            TextField("课程名称", text: $lessonTitle)
            Button("创建") { Task { await model.createLesson(title: lessonTitle) } }
            Button("取消", role: .cancel) {}
        }
        .alert("需要处理", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Label(recordingStatus, systemImage: model.hasCapture ? "waveform" : "mic")
                    .foregroundStyle(model.hasCapture ? Color.red : Color.secondary)
                Spacer()
                if model.playing {
                    Button("停止播放", systemImage: "stop.circle") { model.stopPlayback() }
                }
                if model.hasCapture {
                    Button(model.busy ? "正在收尾…" : "暂停并保存", systemImage: "pause.circle.fill") {
                        Task { await model.pauseRecording() }
                    }.buttonStyle(.borderedProminent).disabled(model.busy)
                } else {
                    Button("开始 / 继续录音", systemImage: "record.circle") {
                        Task { await model.startRecording() }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!model.modelReady || model.lesson == nil || model.busy)
                }
            }
            HStack {
                Picker("课堂语言", selection: Binding(
                    get: { model.lectureLanguage },
                    set: { language in Task { await model.setLectureLanguage(language) } }
                )) {
                    Text("英文课").tag(LFLectureLanguage.english)
                    Text("中文课").tag(LFLectureLanguage.chinese)
                }.pickerStyle(.segmented).frame(width: 180)
                    .accessibilityIdentifier("lectureflow.language")
                    .disabled(model.lesson == nil || model.hasCapture || model.busy || model.preparingModel)
                Text(model.modelStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.modelReady {
                    Button(model.preparingModel ? "准备中…" : "准备课堂模型") {
                        Task { await model.prepareModel() }
                    }.disabled(model.preparingModel || model.hasCapture)
                }
            }
            if model.preparingModel { ProgressView(value: model.modelProgress) }
            if model.hasCapture {
                Text("原音已录 \(clock(model.audio.recordedDuration)) · 转写到 \(clock(model.audio.transcribedThrough))。识别落后时继续保存原音。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.audio.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                Toggle("AI 双语笔记", isOn: Binding(
                    get: { model.autoNotesEnabled }, set: { enabled in
                        if enabled && model.configuration == nil { showingSettings = true }
                        else { Task { await model.setAutoNotes(enabled) } }
                    }
                )).fixedSize()
                Spacer()
                if model.generatingNotes {
                    ProgressView()
                    Text(model.rebuildingSummary ? "正在梳理整堂课…" : "正在更新课程梳理…").font(.caption)
                }
                Button("更新 / 重试") { model.generateNotesNow() }
                    .disabled(!model.autoNotesEnabled || model.generatingNotes || model.lesson?.segments.isEmpty != false)
            }
            Text(model.autoNotesEnabled
                 ? "将课程标题、确认原文和已有笔记发送到你配置的服务；原音保留在本机。"
                 : "AI 未启用。录音和原文正常保存；启用前请设置服务和个人 Key。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(.bar)
    }

    private var recordingStatus: String {
        switch model.audio.state {
        case .idle: return "尚未录音"
        case .starting: return "正在开启麦克风"
        case .recording: return "正在录音 · 16 kHz 单声道"
        case .stopping: return "麦克风已停，正在转写尾部并保存"
        case .finished: return "已暂停，可继续同一课程"
        case .interrupted: return "录音中断，请确认后继续"
        case .failed: return "录音或转写出错，请查看提示"
        }
    }

    private func transcript(_ lesson: LFLesson) -> some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            Text(lesson.effectiveLanguage == .chinese ? "中文实时转写" : "英文实时转写").font(.title2.bold())
            Text("按课堂语言识别。点时间可回听原音，专业术语可结合前后文核对。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(lesson.segments) { segment in
                VStack(alignment: .leading, spacing: 6) {
                    Button(clock(segment.startTime), systemImage: "play.circle") {
                        Task { await model.play(at: segment.startTime) }
                    }.font(.caption).disabled(model.hasCapture)
                    Text(segment.english).textSelection(.enabled)
                }
                Divider()
            }
            if model.hasCapture, !model.audio.partialText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("识别中 · 尚未确认").font(.caption).foregroundStyle(.secondary)
                    Text(model.audio.partialText).foregroundStyle(.secondary)
                }
            }
            if lesson.segments.isEmpty && !model.hasCapture {
                Text("录音开始后，确认的课堂原文会保存在这里。")
                    .foregroundStyle(.secondary)
            }
            if !lesson.audioFiles.isEmpty {
                Text("原音文件").font(.headline).padding(.top)
                ForEach(lesson.audioFiles) { file in
                    HStack {
                        Text("\(clock(file.offset)) · \(clock(file.duration))")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Button("播放") { Task { await model.play(fileID: file.id) } }
                        Menu {
                            Button("导出 WAV 原音") { Task { await model.exportAudio(file.id) } }
                            Button("补转写原音") { Task { await model.recoverAudio(file.id) } }
                                .disabled(!model.modelReady || model.busy)
                        } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("录音操作") }
                    }.disabled(model.hasCapture)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notes(_ lesson: LFLesson) -> some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("课堂笔记").font(.title2.bold())
                Spacer()
                Button("梳理整堂课") { Task { await model.rebuildCourseNotes() } }
                    .disabled(!model.autoNotesEnabled || model.generatingNotes || model.hasCapture || lesson.segments.isEmpty)
            }
            if let error = lesson.notesError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let summary = lesson.courseSummary {
                if let nodes = summary.mindMap, !nodes.isEmpty {
                    HStack {
                        Text("中英思维导图").font(.headline)
                        Spacer()
                        Button("全屏") { showingMindMap = true }
                            .accessibilityIdentifier("lectureflow.map.fullscreen")
                    }
                    LFNotesMapView(title: lesson.title, nodes: nodes)
                    DisclosureGroup("双语详细笔记") { summaryText(summary) }
                } else {
                    summaryText(summary)
                    Text("点击“梳理整堂课”生成课程思维导图。").font(.caption).foregroundStyle(.secondary)
                }
                if let through = lesson.courseSummaryThrough {
                    Text("梳理到：" + clock(through)).font(.caption).foregroundStyle(.secondary)
                }
            } else if !lesson.notes.isEmpty {
                Text("点击“梳理整堂课”，将已保存的原文串成课程主线和思维导图。原有过程笔记和手动编辑会保留。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("过程笔记 · \(lesson.notes.count) 组") {
            ForEach(lesson.notes) { note in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(note.isEdited ? "已手动编辑" : "课堂要点").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("编辑") { editingLessonID = lesson.id; editingNote = note }
                    }
                    Text(note.englishNotes).textSelection(.enabled)
                    Divider()
                    Text(note.chineseNotes).textSelection(.enabled)
                    if !note.keyTerms.isEmpty {
                        Text(note.keyTerms.map { "\($0.english) — \($0.chinese)" }.joined(separator: "\n"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("来源：" + note.sourceSegmentIDs.compactMap { id in
                        lesson.segments.first(where: { $0.id == id }).map { clock($0.startTime) }
                    }.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                }
                .padding().background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            }
            if lesson.notes.isEmpty {
                Text("启用 AI 后，思维导图与双语笔记随课堂内容持续更新。暂停后可用“梳理整堂课”整理已有原文。网络失败会保留原文和已有笔记。")
                    .foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryText(_ summary: LFNotesSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.englishNotes).textSelection(.enabled)
            Divider()
            Text(summary.chineseNotes).textSelection(.enabled)
            if !summary.keyTerms.isEmpty {
                Text(summary.keyTerms.map { "\($0.english) — \($0.chinese)" }.joined(separator: "\n"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding().background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

private struct LectureCloudSettings: View {
    @ObservedObject var model: LectureFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var modelName = ""
    @State private var key = ""
    @State private var enabled = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenAI 兼容服务") {
                    TextField("完整 HTTPS chat/completions 地址", text: $endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("服务提供的模型名称", text: $modelName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("个人 API Key；同地址可留空保留", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("保存后启用 AI 双语笔记", isOn: $enabled)
                }
                Section {
                    Text("服务必须支持 chat/completions 和 JSON 对象输出。费用由你的服务账号承担。Key 仅保存在本机钥匙串；换服务地址需重新填 Key。")
                    Text("启用后会向填写的服务发送课程标题、已确认原文、来源片段 ID、已有笔记、手动编辑和累计课程梳理。麦克风原音不会随 AI 请求上传。每次重新打开 App 都需再次启用 AI。")
                    Text("中英课堂模型首次从 Hugging Face 下载；加载完成后，英文或中文识别在 iPad 本机进行。")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("AI 与隐私设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") {
                        saving = true
                        Task {
                            do {
                                try await model.saveCloudSettings(endpoint: endpoint, model: modelName, newKey: key, enabled: enabled)
                                key = ""
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(saving)
                }
            }
            .onAppear {
                endpoint = model.configuration?.endpoint.absoluteString ?? ""
                modelName = model.configuration?.model ?? ""
                enabled = model.autoNotesEnabled
            }
        }.presentationDetents([.large])
    }
}

private struct LectureNoteEditor: View {
    @ObservedObject var model: LectureFlowModel
    let note: LFNoteBlock
    let lessonID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var english = ""
    @State private var chinese = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("English") { TextEditor(text: $english).frame(minHeight: 180) }
                Section("中文") { TextEditor(text: $chinese).frame(minHeight: 180) }
                Section { Text("手动修改独立保存，后续 AI 更新不会覆盖这一组编辑。") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("编辑双语笔记")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saving = true
                        Task {
                            do { try await model.editNote(note, lessonID: lessonID, english: english, chinese: chinese); dismiss() }
                            catch { self.error = error.localizedDescription }
                            saving = false
                        }
                    }.disabled(saving)
                }
            }
            .onAppear { english = note.englishNotes; chinese = note.chineseNotes }
        }
    }
}

private struct LectureShareDocument: Identifiable { let id = UUID(); let url: URL }
private struct LectureShareView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
