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

enum LFVisualKind: String, Codable, CaseIterable, Sendable {
    case table, flow, causal, bar, line, scatter, formula
}

struct LFVisualTable: Codable, Equatable, Sendable {
    let columns: [LFKeyTerm]
    let rows: [[LFKeyTerm]]
}

struct LFVisualNode: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: LFKeyTerm
}

struct LFVisualEdge: Codable, Equatable, Sendable {
    let from: String
    let to: String
    var label: LFKeyTerm? = nil
}

struct LFVisualDiagram: Codable, Equatable, Sendable {
    let nodes: [LFVisualNode]
    let edges: [LFVisualEdge]
}

struct LFVisualPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    var label: LFKeyTerm? = nil
}

struct LFVisualSeries: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: LFKeyTerm
    let points: [LFVisualPoint]
}

struct LFVisualChart: Codable, Equatable, Sendable {
    let xLabel: LFKeyTerm
    let yLabel: LFKeyTerm
    let series: [LFVisualSeries]

    enum CodingKeys: String, CodingKey {
        case xLabel = "x_label", yLabel = "y_label", series
    }
}

struct LFFormulaSymbol: Codable, Equatable, Sendable {
    let symbol: String
    let meaning: LFKeyTerm
}

struct LFVisualFormula: Codable, Equatable, Sendable {
    let expression: String
    let symbols: [LFFormulaSymbol]
    let steps: [LFKeyTerm]
}

// Structured, local-rendered teaching visuals. Keeping the payload typed avoids
// executing model-supplied HTML, SVG, image URLs or arbitrary drawing code.
struct LFVisualBlock: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: LFVisualKind
    let title: LFKeyTerm
    let caption: LFKeyTerm
    let sourceSegmentIDs: [String]
    var table: LFVisualTable? = nil
    var diagram: LFVisualDiagram? = nil
    var chart: LFVisualChart? = nil
    var formula: LFVisualFormula? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, title, caption, table, diagram, chart, formula
        case sourceSegmentIDs = "source_segment_ids"
    }

    static func validateBlocks(_ blocks: [LFVisualBlock], allowedSourceIDs: Set<String>? = nil) throws {
        guard blocks.count <= 6 else { throw LFError.invalidResponse("课程图表超过 6 个") }
        guard ((try? JSONEncoder().encode(blocks).count) ?? Int.max) <= 98_304 else {
            throw LFError.invalidResponse("课程图表编码超过 96 KB")
        }
        var blockIDs = Set<String>()
        var totalText = 0
        func text(_ value: String, limit: Int) throws {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= limit else { throw LFError.invalidResponse("课程图表文字为空或过长") }
            totalText += value.count
            guard totalText <= 12000 else { throw LFError.invalidResponse("课程图表文字总量过长") }
        }
        func term(_ value: LFKeyTerm, limit: Int = 240) throws {
            try text(value.english, limit: limit)
            try text(value.chinese, limit: limit)
        }
        func identifier(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 128
        }
        for block in blocks {
            guard identifier(block.id), blockIDs.insert(block.id).inserted,
                  !block.sourceSegmentIDs.isEmpty, block.sourceSegmentIDs.count <= 64,
                  block.sourceSegmentIDs.allSatisfy(identifier),
                  Set(block.sourceSegmentIDs).count == block.sourceSegmentIDs.count else {
                throw LFError.invalidResponse("课程图表标识或来源无效")
            }
            if let allowedSourceIDs,
               !Set(block.sourceSegmentIDs).isSubset(of: allowedSourceIDs) {
                throw LFError.invalidResponse("课程图表引用了未知或尚未覆盖的片段")
            }
            try term(block.title, limit: 160)
            try term(block.caption, limit: 600)
            let payloadCount = [block.table != nil, block.diagram != nil, block.chart != nil, block.formula != nil]
                .filter { $0 }.count
            guard payloadCount == 1 else { throw LFError.invalidResponse("课程图表必须包含且仅包含一种内容") }
            switch block.kind {
            case .table:
                guard let table = block.table, (2...6).contains(table.columns.count),
                      (1...12).contains(table.rows.count),
                      table.rows.allSatisfy({ $0.count == table.columns.count }) else {
                    throw LFError.invalidResponse("表格须为 2 至 6 列、1 至 12 行的完整矩形")
                }
                for column in table.columns { try term(column, limit: 120) }
                for row in table.rows { for cell in row { try term(cell) } }
            case .flow, .causal:
                guard let diagram = block.diagram, (2...10).contains(diagram.nodes.count),
                      (1...14).contains(diagram.edges.count) else {
                    throw LFError.invalidResponse("关系图节点或连线数量无效")
                }
                var nodeIDs = Set<String>()
                for node in diagram.nodes {
                    guard identifier(node.id), nodeIDs.insert(node.id).inserted else {
                        throw LFError.invalidResponse("关系图节点标识重复或无效")
                    }
                    try term(node.label, limit: 160)
                }
                var pairs = Set<[String]>()
                var linked = Set<String>()
                for edge in diagram.edges {
                    guard nodeIDs.contains(edge.from), nodeIDs.contains(edge.to), edge.from != edge.to,
                          pairs.insert([edge.from, edge.to]).inserted else {
                        throw LFError.invalidResponse("关系图存在无效、重复或指向自身的连线")
                    }
                    linked.insert(edge.from)
                    linked.insert(edge.to)
                    if let label = edge.label { try term(label, limit: 160) }
                }
                guard linked == nodeIDs else { throw LFError.invalidResponse("关系图存在没有连线的节点") }
            case .bar, .line, .scatter:
                guard let chart = block.chart, (1...3).contains(chart.series.count) else {
                    throw LFError.invalidResponse("数据图须包含 1 至 3 组数据")
                }
                try term(chart.xLabel, limit: 160)
                try term(chart.yLabel, limit: 160)
                var seriesIDs = Set<String>()
                for series in chart.series {
                    guard identifier(series.id), seriesIDs.insert(series.id).inserted,
                          ((block.kind == .bar ? 1 : 2)...24).contains(series.points.count) else {
                        throw LFError.invalidResponse("数据图系列标识或数据点数量无效")
                    }
                    try term(series.label, limit: 160)
                    var previousX: Double?
                    var barX = Set<Double>()
                    for point in series.points {
                        guard point.x.isFinite, point.y.isFinite,
                              abs(point.x) <= 1e12, abs(point.y) <= 1e12 else {
                            throw LFError.invalidResponse("数据图包含非有限或超出范围的数值")
                        }
                        if block.kind == .line, let previousX, point.x <= previousX {
                            throw LFError.invalidResponse("折线图横坐标须严格递增")
                        }
                        if block.kind == .bar, !barX.insert(point.x).inserted {
                            throw LFError.invalidResponse("柱状图同一系列不能有重复横坐标")
                        }
                        previousX = point.x
                        if let label = point.label { try term(label, limit: 160) }
                    }
                }
            case .formula:
                guard let formula = block.formula, formula.symbols.count <= 16,
                      formula.steps.count <= 8 else { throw LFError.invalidResponse("公式说明超出长度限制") }
                try text(formula.expression, limit: 1000)
                var symbols = Set<String>()
                for symbol in formula.symbols {
                    try text(symbol.symbol, limit: 80)
                    guard symbols.insert(symbol.symbol).inserted else { throw LFError.invalidResponse("公式符号重复") }
                    try term(symbol.meaning)
                }
                for step in formula.steps { try term(step, limit: 400) }
            }
        }
    }
}

struct LFConceptNode: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let english: String
    let chinese: String
    let children: [LFConceptNode]

    static func validateTree(_ roots: [LFConceptNode]) throws {
        var ids = Set<String>()
        var count = 0
        func visit(_ nodes: [LFConceptNode], depth: Int) throws {
            guard nodes.isEmpty || depth <= 4 else { throw LFError.invalidResponse("思维导图超过 4 层") }
            for node in nodes {
                count += 1
                guard count <= 40, !node.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      ids.insert(node.id).inserted,
                      !node.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !node.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      node.english.count <= 160, node.chinese.count <= 160 else {
                    throw LFError.invalidResponse("思维导图节点、双语标签或唯一标识无效")
                }
                try visit(node.children, depth: depth + 1)
            }
        }
        try visit(roots, depth: 1)
    }
}

// A bounded, rolling understanding of the lecture. Detailed source notes stay
// independently editable; this snapshot is rebuilt from confirmed evidence.
struct LFNotesSummary: Codable, Equatable, Sendable {
    let englishNotes: String
    let chineseNotes: String
    let keyTerms: [LFKeyTerm]
    var mindMap: [LFConceptNode]? = nil
    var visuals: [LFVisualBlock]? = nil

    enum CodingKeys: String, CodingKey {
        case englishNotes = "english_notes", chineseNotes = "chinese_notes", keyTerms = "key_terms"
        case mindMap = "mind_map"
        case visuals
    }

    func validate(requireMindMap: Bool = false) throws {
        guard !englishNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !chineseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              englishNotes.count <= 4000, chineseNotes.count <= 4000, keyTerms.count <= 30,
              keyTerms.allSatisfy({ !$0.english.isEmpty && !$0.chinese.isEmpty && $0.english.count <= 300 && $0.chinese.count <= 300 }) else {
            throw LFError.invalidResponse("课程梳理缺少双语内容或超出长度限制")
        }
        if let mindMap { try LFConceptNode.validateTree(mindMap) }
        if let visuals { try LFVisualBlock.validateBlocks(visuals) }
        if requireMindMap && (mindMap?.isEmpty ?? true) {
            throw LFError.invalidResponse("缺少课程双语思维导图")
        }
    }
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
enum LFLectureLanguage: String, Codable, CaseIterable, Sendable { case english, chinese }

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
    // Optional additions keep existing schema-1 courses readable after upgrade.
    var courseSummary: LFNotesSummary?
    var courseSummaryThrough: Double?
    var lectureLanguage: LFLectureLanguage?
    var effectiveLanguage: LFLectureLanguage { lectureLanguage ?? .english }
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
    var courseSummary: LFNotesSummary? = nil

    enum CodingKeys: String, CodingKey {
        case englishNotes = "english_notes", chineseNotes = "chinese_notes"
        case keyTerms = "key_terms", sourceSegmentIDs = "source_segment_ids"
        case courseSummary = "course_summary"
    }

    func validate(for batch: LFNoteBatch) throws {
        try courseSummary?.validate()
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
