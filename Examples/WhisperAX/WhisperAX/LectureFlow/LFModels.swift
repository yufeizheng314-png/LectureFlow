import Foundation

struct LFConfirmedSegment: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let startTime: Double
    let endTime: Double
    let english: String
}

struct LFKeyTerm: Codable, Equatable, Sendable {
    let english: String
    let chinese: String
}

struct LFRecordingFile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let fileName: String
    var duration: Double
    let offset: Double
}

struct LFNoteBlock: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let batchID: UUID
    let generatedEnglishNotes: String
    let generatedChineseNotes: String
    let keyTerms: [LFKeyTerm]
    let sourceSegmentIDs: [String]
    var editedEnglishNotes: String?
    var editedChineseNotes: String?
    var englishNotes: String { editedEnglishNotes ?? generatedEnglishNotes }
    var chineseNotes: String { editedChineseNotes ?? generatedChineseNotes }
    var isEdited: Bool { editedEnglishNotes != nil || editedChineseNotes != nil }
}

enum LFRecordingState: String, Codable, Sendable { case recording, paused, ended }
enum LFNotesState: String, Codable, Sendable { case notConfigured, idle, generating, ready, failed }
enum LFExportFormat: String, Sendable { case markdown, text }
enum LFBatchState: String, Codable, Sendable { case queued, running, completed, failed }

struct LFNoteInput: Codable, Equatable, Sendable {
    let segmentID: String
    let startTime: Double
    let endTime: Double
    let characterStart: Int
    let characterEnd: Int
    let english: String
}

struct LFNoteBatch: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let inputs: [LFNoteInput]
    var state: LFBatchState
    var error: String?
}

struct LFLesson: Codable, Identifiable, Sendable {
    var schemaVersion = 1
    let id: UUID
    var title: String
    let createdAt: Date
    var modifiedAt: Date
    var recordingState: LFRecordingState = .recording
    var notesState: LFNotesState = .notConfigured
    var notesError: String?
    var segments: [LFConfirmedSegment] = []
    var notes: [LFNoteBlock] = []
    var batches: [LFNoteBatch] = []
    var audioFiles: [LFRecordingFile] = []
    var timelineDuration: Double {
        max(audioFiles.map { $0.offset + $0.duration }.max() ?? 0,
            segments.map(\.endTime).max() ?? 0)
    }
}

struct LFCloudConfiguration: Codable, Equatable, Sendable {
    let endpoint: URL
    let model: String
    private static let storageKey = "LectureFlow.cloud.configuration.v1"

    func validate() throws {
        guard let parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", !(parts.host ?? "").isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.count <= 200 else {
            throw LFError.invalid("请填写完整 HTTPS chat/completions 地址和模型；地址不能包含凭据、查询参数或片段。")
        }
    }

    func save() throws {
        try validate()
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.storageKey)
    }

    static func load() throws -> Self? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        let config = try JSONDecoder().decode(Self.self, from: data)
        try config.validate()
        return config
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: storageKey) }
}

enum LFError: Error, LocalizedError {
    case invalid(String), conflict(String), notConfigured, network, server(Int), invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let text), .conflict(let text): return text
        case .notConfigured: return "未配置 AI：请设置 HTTPS 地址、模型和个人 API Key。转写仍会保存。"
        case .network: return "AI 网络请求失败或超时。已有转写和笔记已保留，可以重试。"
        case .server(let code): return "AI 服务返回 HTTP \(code)。请检查配置或稍后重试。"
        case .invalidResponse(let text): return "AI 返回的笔记格式无效：\(text)。原有笔记已保留。"
        }
    }
}

struct LFGeneratedNotes: Codable, Sendable {
    let englishNotes: String
    let chineseNotes: String
    let keyTerms: [LFKeyTerm]
    let sourceSegmentIDs: [String]

    enum CodingKeys: String, CodingKey {
        case englishNotes = "english_notes", chineseNotes = "chinese_notes"
        case keyTerms = "key_terms", sourceSegmentIDs = "source_segment_ids"
    }

    func validate(for batch: LFNoteBatch) throws {
        let allowed = Set(batch.inputs.map(\.segmentID))
        guard !englishNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !chineseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              englishNotes.count <= 16000, chineseNotes.count <= 16000, keyTerms.count <= 30,
              keyTerms.allSatisfy({ !$0.english.isEmpty && !$0.chinese.isEmpty && $0.english.count <= 300 && $0.chinese.count <= 300 }),
              !sourceSegmentIDs.isEmpty, Set(sourceSegmentIDs).count == sourceSegmentIDs.count,
              Set(sourceSegmentIDs) == allowed else {
            throw LFError.invalidResponse("缺少双语内容、超出长度限制或引用了未知片段")
        }
    }
}
