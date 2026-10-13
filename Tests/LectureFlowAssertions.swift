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

// These deliberately small economics/statistics examples are scripted fixtures,
// not measured student results or evidence of a cloud model's reasoning quality.
private func visualTerm(_ english: String, _ chinese: String) -> [String: String] {
    ["english": english, "chinese": chinese]
}

private func visualFixture(_ kind: String, id: String? = nil, source: String = "visual-regression-1") -> [String: Any] {
    let term = visualTerm
    let titles = ["table": ("Observed sample", "样本数据表"), "flow": ("OLS workflow", "估计步骤"),
                  "causal": ("Confounding hypothesis", "混杂路径"), "scatter": ("Hours and score", "样本散点"),
                  "formula": ("OLS slope", "斜率公式"), "bar": ("Annual output", "年度产出柱图"),
                  "line": ("Output trend", "产出趋势折线")]
    let title = titles[kind]!
    var value: [String: Any] = ["id": id ?? "econ-\(kind)", "kind": kind, "title": term(title.0, title.1),
        "caption": term("Scripted classroom example for automated tests; not a live AI result.", "自动化课堂示例，使用预设数据，不是真实云 AI 结果。"),
        "source_segment_ids": [source]]
    switch kind {
    case "table":
        value["table"] = ["columns": [term("Hours (h)", "时长（小时）"), term("Score (points)", "得分（分）")],
                           "rows": [[term("1", "1"), term("2", "2")], [term("2", "2"), term("3", "3")], [term("3", "3"), term("5", "5")]]]
    case "flow":
        value["diagram"] = ["nodes": [["id": "observe", "label": term("Observe sample", "观察样本")],
                                        ["id": "estimate", "label": term("Minimize squared residuals", "最小化残差平方和")],
                                        ["id": "check", "label": term("Check assumptions", "核对假设")]],
                              "edges": [["from": "observe", "to": "estimate"], ["from": "estimate", "to": "check"]]]
    case "causal":
        value["caption"] = term("Classroom causal hypothesis only; these arrows are not effects estimated from the three-point sample.", "课堂因果假设图；箭头不是从三点样本估计出的因果效应。")
        value["diagram"] = ["nodes": [["id": "ability", "label": term("Ability", "能力")],
                                        ["id": "education", "label": term("Education", "教育")],
                                        ["id": "wage", "label": term("Wage", "工资")]],
                              "edges": [["from": "ability", "to": "education", "label": term("Hypothesis", "假设")],
                                        ["from": "ability", "to": "wage", "label": term("Hypothesis", "假设")],
                                        ["from": "education", "to": "wage", "label": term("Target relationship", "研究关系")]]]
    case "scatter", "bar", "line":
        let scatter = kind == "scatter"
        let xs = scatter ? [1.0, 2.0, 3.0] : [2023.0, 2024.0, 2025.0]
        let ys = scatter ? [2.0, 3.0, 5.0] : [100.0, 110.0, 121.0]
        let points: [[String: Any]] = zip(xs, ys).map { ["x": $0.0, "y": $0.1, "label": term(String(Int($0.0)), String(Int($0.0)))] }
        value["chart"] = ["x_label": term(scatter ? "Hours (h)" : "Year", scatter ? "时长（小时）" : "年份"),
                           "y_label": term(scatter ? "Score (points)" : "Output (100 million yuan)", scatter ? "得分（分）" : "产出（亿元）"),
                           "series": [["id": "observations", "label": term("Given sample", "课堂给定样本"), "points": points]]]
    case "formula":
        value["formula"] = ["expression": "β̂₁ = Σᵢ(xᵢ − x̄)(yᵢ − ȳ) / Σᵢ(xᵢ − x̄)² = 3 / 2 = 1.5",
            "symbols": [["symbol": "xᵢ", "meaning": term("Study hours (h)", "学习时长（小时）")],
                        ["symbol": "yᵢ", "meaning": term("Score (points)", "得分（分）")],
                        ["symbol": "β̂₁", "meaning": term("Estimated slope (points/h)", "斜率估计值（分/小时）")]],
            "steps": [term("For the supplied three observations, x̄ = 2 and ȳ = 10/3.", "给定三个观测，x 均值为 2，y 均值为 10/3。"),
                      term("Cross-deviation sum = 3; squared x-deviation sum = 2.", "离差乘积和为 3；x 离差平方和为 2。"),
                      term("Slope = 1.5 points/h; intercept = 1/3 points. Association alone does not prove causation.", "斜率为 1.5 分/小时，截距为 1/3 分。相关关系本身不能证明因果。")]]
    default: preconditionFailure("Unknown test visual kind")
    }
    return value
}

private func visualBlocks(_ objects: [[String: Any]]) throws -> [LFVisualBlock] {
    try JSONDecoder().decode([LFVisualBlock].self, from: JSONSerialization.data(withJSONObject: objects))
}

private func longEconomicsTable() -> [String: Any] {
    let term = visualTerm
    // Six useful comparison dimensions across twelve concepts, with row markers
    // that make a clipped final page or overwritten table export detectable.
    let concepts: [(String, String, String, String, String, String, String, String, String, String)] = [
        ("Sample mean", "样本均值", "Add the observed values and divide by the number of observations.", "观测值之和除以观测个数。", "Same unit as the measured variable.", "与变量原单位相同。", "Describe the sample center before fitting a model.", "建模前描述样本中心。", "A mean can hide skewness and does not describe the spread.", "均值可能掩盖偏态，也不能描述离散程度。"),
        ("Sample variance", "样本方差", "Summarize squared deviations from the sample mean.", "概括各观测相对样本均值的离差平方。", "Squared unit of the original variable.", "原变量单位的平方。", "Quantify dispersion; distinguish it from a standard deviation.", "衡量离散程度，并区分标准差。", "State the denominator convention before comparing estimates.", "比较估计值前说明分母约定。"),
        ("Covariance", "协方差", "Track whether two centered variables tend to move together.", "刻画两个中心化变量是否倾向于共同变化。", "Product of the two variable units.", "两个变量单位的乘积。", "Connect co-movement to the numerator of an OLS slope.", "把共同变化与回归斜率的分子联系起来。", "Changing either measurement scale changes the covariance.", "改变任一变量的计量尺度都会改变协方差。"),
        ("Correlation", "相关系数", "Standardize covariance using the two standard deviations.", "用两个标准差将协方差标准化。", "Unitless when both variances are positive.", "两变量方差均为正时无量纲。", "Compare the direction and strength of a linear association.", "比较线性关联的方向与强度。", "Strong correlation alone cannot identify a causal effect.", "强相关本身不能识别因果效应。"),
        ("OLS slope", "OLS 斜率", "Choose coefficients to minimize the sum of squared residuals.", "选择使残差平方和最小的回归系数。", "Outcome units per one predictor unit.", "结果变量单位除以解释变量单位。", "Describe the fitted conditional linear association.", "描述拟合得到的条件线性关联。", "Causal interpretation needs assumptions beyond a fitted line.", "因果解释需要拟合直线之外的额外假设。"),
        ("Standard error", "标准误", "Estimate the sampling uncertainty of a coefficient estimator.", "估计回归系数估计量的抽样不确定性。", "Same unit as its coefficient.", "与相应回归系数单位相同。", "Support uncertainty intervals and statistical tests.", "用于不确定性区间和统计检验。", "Use a variance estimator appropriate for the data dependence.", "应根据数据依赖结构选择合适的方差估计方法。"),
        ("Confidence interval", "置信区间", "Combine an estimate, standard error and a reference critical value.", "结合估计值、标准误和参考临界值。", "Same unit as the parameter being estimated.", "与被估计参数单位相同。", "Communicate a range of parameter values compatible with the procedure.", "表达与所用统计程序相容的参数取值范围。", "Coverage is a repeated-sampling property under stated assumptions.", "覆盖率是在指定假设下的重复抽样性质。"),
        ("Homoskedasticity", "同方差性", "Assume that conditional error variance is constant across observations.", "假设误差项的条件方差在不同观测间保持不变。", "A variance assumption, not a new measured variable.", "它是方差假设，并非新增测量变量。", "Justify a particular classical variance formula when other assumptions hold.", "在其他假设成立时支持经典方差公式。", "Check the error-variance assumption instead of reading it from a slope.", "应检查误差方差假设，不能从斜率数值推出。"),
        ("Heteroskedasticity", "异方差性", "Allow conditional error variance to differ across observations.", "允许误差项条件方差随观测而不同。", "Variance is still measured in squared outcome units.", "方差仍以结果变量单位的平方计量。", "Motivate an appropriate robust uncertainty calculation.", "提示采用合适的稳健不确定性计算。", "Robust standard errors do not by themselves remove omitted-variable bias.", "稳健标准误本身不能消除遗漏变量偏误。"),
        ("Omitted variable", "遗漏变量", "A relevant excluded factor can be related to an included predictor.", "被遗漏的相关因素可能与已纳入的解释变量相关。", "Units depend on the omitted concept.", "单位取决于所遗漏的具体概念。", "Explain why a fitted association may differ from the target effect.", "解释拟合关联为什么可能不同于目标效应。", "Decide controls using the substantive causal structure, not only significance.", "应结合实际因果结构选择控制变量，而不只看显著性。"),
        ("Instrumental variable", "工具变量", "Use a variable linked to the endogenous predictor under identifying restrictions.", "在识别限制下使用与内生解释变量相关的变量。", "Instrument and predictor units can differ.", "工具变量与解释变量单位可以不同。", "Provide an identification strategy when its assumptions are defensible.", "在假设可辩护时提供识别策略。", "Relevance alone is insufficient; exclusion and exogeneity also matter.", "仅有相关性还不够，排除限制和外生性同样重要。"),
        ("Causal identification", "因果识别", "Link a target causal quantity to observable evidence using explicit assumptions.", "借助明确假设，把目标因果量与可观察证据联系起来。", "Use the target effect's substantive unit.", "使用目标效应对应的实际单位。", "Separate the research question, design and estimation step.", "区分研究问题、研究设计与估计步骤。", "A persuasive diagram is not proof that its causal assumptions hold.", "图示清晰并不能证明其因果假设成立。")
    ]
    let rows = concepts.enumerated().map { index, value -> [[String: String]] in
        let number = index + 1
        return [term(number == 1 ? "R01 STRESS_ROW_01_BEGIN" : "R\(String(format: "%02d", number))", "第\(number)行"),
                term(value.0, value.1), term(value.2, value.3), term(value.4, value.5), term(value.6, value.7),
                term(value.8 + (number == 12 ? " STRESS_ROW_12_END R12C6" : ""), value.9 + (number == 12 ? " 第12行结束。" : ""))]
    }
    return ["id": "econ-long-table", "kind": "table", "title": term("Twelve-concept comparison", "计量统计概念长表"),
            "caption": term("Automated pagination fixture with predefined teaching content; not a live AI result.", "用于自动化分页验收的预设教学内容，不是真实云 AI 结果。"),
            "source_segment_ids": ["visual-regression-2"],
            "table": ["columns": [term("Row", "行号"), term("Concept", "概念"), term("Definition", "定义"), term("Unit", "单位"), term("Role", "用途"), term("Caveat", "注意事项")], "rows": rows]]
}

private func visualResponseObject(for request: URLRequest, blocks: [[String: Any]]) throws -> [String: Any] {
    let context = try requestContext(request)
    let inputs = context["new_confirmed_segments"] as! [[String: Any]]
    var notes = LFGeneratedNotes(englishNotes: "Scripted visual fixture: connected classroom explanation.", chineseNotes: "自动化图文夹具：连接此前与本批课堂内容。", keyTerms: [], sourceSegmentIDs: inputs.map { $0["segmentID"] as! String })
    notes.courseSummary = LFNotesSummary(englishNotes: "Automated economics/statistics fixture. Observations, estimation and assumptions belong to one cumulative explanation; no claim of real cloud quality.", chineseNotes: "自动化计量统计课程：在累计梳理中连接观察、估计和假设；不代表真实云生成质量。", keyTerms: [], mindMap: [LFConceptNode(id: "econometrics", english: "Evidence and estimation", chinese: "证据与估计", children: [])])
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(notes)) as! [String: Any]
    var summary = object["course_summary"] as! [String: Any]
    summary["visuals"] = blocks
    object["course_summary"] = summary
    return object
}

private func visualHTTPEnvelope(_ object: [String: Any], request: URLRequest) throws -> (Data, HTTPURLResponse) {
    let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": try contextText(object)]]]])
    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

private actor EconomicsHTTP {
    var requests: [URLRequest] = []
    func call(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let context = try requestContext(request)
        check(context["source_language"] as? String == "zh", "Economics fixture must use actual Chinese source mode")
        try checkPromptContract(request)
        let previous = try summaryInContext(context)
        let inputs = context["new_confirmed_segments"] as! [[String: Any]]
        let ids = Set(inputs.map { $0["segmentID"] as! String })
        var blocks = try previous?.visuals.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) as! [[String: Any]] } ?? []
        if ids.contains("visual-regression-1") {
            blocks += ["table", "flow", "causal"].map { visualFixture($0) }
        }
        if ids.contains("visual-regression-2") {
            blocks += ["scatter", "formula"].map { visualFixture($0, source: "visual-regression-2") }
            blocks.append(longEconomicsTable())
        }
        if ids.contains("visual-output-1") {
            blocks += ["bar", "line"].map { visualFixture($0, source: "visual-output-1") }
        }
        return try visualHTTPEnvelope(visualResponseObject(for: request, blocks: blocks), request: request)
    }
}

private actor FixedVisualHTTP {
    let blocks: Data
    var requests: [URLRequest] = []
    init(blocks: Data) { self.blocks = blocks }
    func call(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return try visualHTTPEnvelope(visualResponseObject(for: request, blocks: JSONSerialization.jsonObject(with: blocks) as! [[String: Any]]), request: request)
    }
}

private enum OptionalVisualReply: String { case present, missing, null, empty, invalid }

private actor OptionalVisualHTTP {
    let replies: [OptionalVisualReply]
    var requests: [URLRequest] = []
    init(_ replies: [OptionalVisualReply]) { precondition(!replies.isEmpty); self.replies = replies }
    func call(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let reply = replies[min(requests.count, replies.count - 1)]
        requests.append(request)
        let context = try requestContext(request)
        let inputs = context["new_confirmed_segments"] as! [[String: Any]]
        let source = inputs.last!["segmentID"] as! String
        var object = try visualResponseObject(for: request, blocks: [])
        var summary = object["course_summary"] as! [String: Any]
        switch reply {
        case .present: summary["visuals"] = [visualFixture("table", source: source)]
        case .missing: summary.removeValue(forKey: "visuals")
        case .null: summary["visuals"] = NSNull()
        case .empty: summary["visuals"] = []
        case .invalid:
            var block = visualFixture("table", source: source)
            var table = block["table"] as! [String: Any]
            table["rows"] = [[visualTerm("ragged", "缺列")]]
            block["table"] = table
            summary["visuals"] = [block]
        }
        object["course_summary"] = summary
        return try visualHTTPEnvelope(object, request: request)
    }
}

private func visualContractChecks() async throws {
    let kinds = ["table", "flow", "causal", "bar", "line", "scatter", "formula"]
    for kind in kinds {
        let original = try visualBlocks([visualFixture(kind)])
        try LFVisualBlock.validateBlocks(original, allowedSourceIDs: ["visual-regression-1"])
        let roundTrip = try JSONDecoder().decode([LFVisualBlock].self, from: JSONEncoder().encode(original))
        check(roundTrip == original, "Every visual kind must preserve all bilingual data and numeric values through Codable")
        let markdown = LFVisualTextExport.render(original, format: .markdown)
        let plain = LFVisualTextExport.render(original, format: .text)
        for output in [markdown, plain] {
            check(output.contains(original[0].title.english) && output.contains(original[0].title.chinese) && output.contains("visual-regression-1"), "Every visual kind needs bilingual titles and source references in both portable formats")
        }
        if ["bar", "line", "scatter"].contains(kind) {
            check(markdown.contains(kind == "scatter" ? "3.0 | 5.0" : "2025.0 | 121.0") && plain.contains(kind == "scatter" ? "3.0\t5.0" : "2025.0\t121.0"), "Charts must export actual source x/y values instead of only a picture")
        }
        if kind == "flow" || kind == "causal" {
            check(markdown.contains("```mermaid\nflowchart TD") && markdown.contains(" -->") && plain.contains("→"), "Diagram export must contain relationships in both machine-renderable and plain-readable forms")
        }
        if kind == "formula" { check(markdown.contains("= 3 / 2 = 1.5") && plain.contains("1.5 分/小时") && plain.contains("β̂₁"), "Formula exports must preserve expression, symbols, units and derivation") }
        print("VISUAL_CHECK PASS kind=\(kind) roundtrip+bilingual+source+markdown+text")
    }

    func mustReject(_ object: [String: Any], reason: String) async {
        await mustFail { try LFVisualBlock.validateBlocks(visualBlocks([object]), allowedSourceIDs: ["visual-regression-1"]) }
        print("VISUAL_CHECK PASS reject=\(reason)")
    }
    var bad = visualFixture("table")
    bad["source_segment_ids"] = ["other-course"]
    await mustReject(bad, reason: "foreign-source")
    bad["source_segment_ids"] = ["visual-regression-1", "visual-regression-1"]
    await mustReject(bad, reason: "duplicate-source")
    bad["source_segment_ids"] = []
    await mustReject(bad, reason: "empty-source")
    bad = visualFixture("table"); bad["chart"] = visualFixture("line")["chart"]
    await mustReject(bad, reason: "mismatched-multiple-payloads")
    bad = visualFixture("table"); bad["table"] = NSNull()
    await mustReject(bad, reason: "missing-required-payload")
    bad = visualFixture("table"); bad["kind"] = "unrecognized-future-kind"
    await mustReject(bad, reason: "unknown-kind")
    bad = visualFixture("table"); bad["title"] = visualTerm(" ", "表格")
    await mustReject(bad, reason: "blank-title")

    let six = try visualBlocks((0..<6).map { visualFixture("table", id: "limit-\($0)") })
    try LFVisualBlock.validateBlocks(six)
    await mustFail { try LFVisualBlock.validateBlocks(six + [six[0]]) }
    await mustFail { try LFVisualBlock.validateBlocks([six[0], six[0]]) }
    var maximumTable = visualFixture("table")
    maximumTable["table"] = ["columns": (1...6).map { visualTerm("C\($0)", "列\($0)") }, "rows": (1...12).map { row in (1...6).map { _ in visualTerm("\(row)", "\(row)") } }]
    try LFVisualBlock.validateBlocks(visualBlocks([maximumTable]))
    for (columns, rows, reason) in [(1, 1, "one-column"), (7, 1, "seven-columns"), (2, 0, "empty-table"), (2, 13, "thirteen-rows")] {
        bad = visualFixture("table")
        bad["table"] = ["columns": (0..<columns).map { visualTerm("C\($0)", "列\($0)") }, "rows": (0..<rows).map { _ in (0..<columns).map { _ in visualTerm("Cell", "单元格") } }]
        await mustReject(bad, reason: reason)
    }
    bad = visualFixture("table")
    bad["table"] = ["columns": [visualTerm("X", "横"), visualTerm("Y", "纵")], "rows": [[visualTerm("1", "1")]]]
    await mustReject(bad, reason: "ragged-table")

    for kind in ["flow", "causal"] {
        var maxDiagram = visualFixture(kind)
        let nodes = (0..<10).map { ["id": "n\($0)", "label": visualTerm("Node \($0)", "节点 \($0)")] as [String: Any] }
        let edges = (0..<9).map { ["from": "n\($0)", "to": "n\($0 + 1)"] } + (2..<7).map { ["from": "n0", "to": "n\($0)"] }
        maxDiagram["diagram"] = ["nodes": nodes, "edges": edges]
        try LFVisualBlock.validateBlocks(visualBlocks([maxDiagram]))
        for (edgeList, reason) in [([["from": "observe", "to": "missing"]], "dangling-edge"), ([["from": "observe", "to": "observe"]], "self-edge"), ([["from": "observe", "to": "estimate"], ["from": "observe", "to": "estimate"]], "duplicate-edge")] {
            bad = visualFixture("flow"); bad["kind"] = kind
            var diagram = bad["diagram"] as! [String: Any]; diagram["edges"] = edgeList; bad["diagram"] = diagram
            await mustReject(bad, reason: "\(kind)-\(reason)")
        }
        bad = maxDiagram; var diagram = bad["diagram"] as! [String: Any]
        diagram["nodes"] = nodes + [["id": "isolated", "label": visualTerm("Extra", "多余")]]
        bad["diagram"] = diagram; await mustReject(bad, reason: "\(kind)-eleven-nodes")
    }

    for kind in ["bar", "line", "scatter"] {
        var maxChart = visualFixture(kind)
        let points = (0..<24).map { ["x": Double($0), "y": 1e12 - Double($0)] }
        let series = (0..<3).map { ["id": "s\($0)", "label": visualTerm("Series \($0)", "系列 \($0)"), "points": points] as [String: Any] }
        maxChart["chart"] = ["x_label": visualTerm("Time (h)", "时间（小时）"), "y_label": visualTerm("Value (yuan)", "值（元）"), "series": series]
        try LFVisualBlock.validateBlocks(visualBlocks([maxChart]))
        let invalidCoordinates: [(Any, Any, String)] = [("NaN", 1, "nonnumeric-x"), (1, "Infinity", "nonnumeric-y"), (1, 1e13, "out-of-range-y"), (NSNull(), 1, "null-x")]
        for (x, y, reason) in invalidCoordinates {
            bad = visualFixture(kind); var chart = bad["chart"] as! [String: Any]
            chart["series"] = [["id": "bad", "label": visualTerm("Series", "系列"), "points": [["x": x, "y": y], ["x": 2, "y": 2]]]]; bad["chart"] = chart
            await mustReject(bad, reason: "\(kind)-\(reason)")
        }
        bad = maxChart; var chart = bad["chart"] as! [String: Any]
        chart["series"] = series + [["id": "s4", "label": visualTerm("Extra", "多余"), "points": points]]; bad["chart"] = chart
        await mustReject(bad, reason: "\(kind)-four-series")
        bad = maxChart; chart["series"] = [["id": "s", "label": visualTerm("Series", "系列"), "points": points + [["x": 24.0, "y": 1.0]]]]; bad["chart"] = chart
        await mustReject(bad, reason: "\(kind)-twenty-five-points")
        if kind != "bar" {
            bad = visualFixture(kind); chart = bad["chart"] as! [String: Any]
            chart["series"] = [["id": "short", "label": visualTerm("Series", "系列"), "points": [["x": 1, "y": 1]]]]; bad["chart"] = chart
            await mustReject(bad, reason: "\(kind)-one-point")
        }
    }
    bad = visualFixture("line"); var chart = bad["chart"] as! [String: Any]
    chart["series"] = [["id": "unsorted", "label": visualTerm("Series", "系列"), "points": [["x": 2, "y": 1], ["x": 1, "y": 2]]]]; bad["chart"] = chart
    await mustReject(bad, reason: "line-unsorted-x")
    bad = visualFixture("formula"); var formula = bad["formula"] as! [String: Any]
    formula["expression"] = String(repeating: "x", count: 1001); bad["formula"] = formula
    await mustReject(bad, reason: "formula-expression-limit")
    formula["expression"] = "x"; formula["symbols"] = [["symbol": "x", "meaning": visualTerm("First", "一")], ["symbol": "x", "meaning": visualTerm("Second", "二")]]; bad["formula"] = formula
    await mustReject(bad, reason: "formula-duplicate-symbols")
    formula["symbols"] = []; formula["steps"] = (0..<9).map { _ in visualTerm("Step", "步骤") }; bad["formula"] = formula
    await mustReject(bad, reason: "formula-nine-steps")
    var maximumFormula = visualFixture("formula")
    maximumFormula["formula"] = ["expression": String(repeating: "x", count: 1000),
        "symbols": (0..<16).map { ["symbol": "s\($0)", "meaning": visualTerm("Meaning", "含义")] as [String: Any] },
        "steps": (0..<8).map { visualTerm("Step \($0)", "步骤 \($0)") }]
    try LFVisualBlock.validateBlocks(visualBlocks([maximumFormula]))
    bad = maximumFormula; formula = bad["formula"] as! [String: Any]
    formula["symbols"] = (0..<17).map { ["symbol": "s\($0)", "meaning": visualTerm("Meaning", "含义")] as [String: Any] }; bad["formula"] = formula
    await mustReject(bad, reason: "formula-seventeen-symbols")
    var largeTable = maximumTable
    var largePayload = largeTable["table"] as! [String: Any]
    largePayload["rows"] = (0..<12).map { _ in (0..<6).map { _ in visualTerm(String(repeating: "e", count: 240), String(repeating: "中", count: 240)) } }
    largeTable["table"] = largePayload
    await mustReject(largeTable, reason: "aggregate-text-budget")
    print("VISUAL_CHECK PASS collection/table/diagram/chart/formula limits")

    var escapedTable = visualFixture("table")
    escapedTable["table"] = ["columns": [visualTerm("A|B", "甲|乙"), visualTerm("C", "丙")], "rows": [[visualTerm("<tag>\n`code`", "一\n二"), visualTerm("quoted \"value\"", "引号")]]]
    var escapedDiagram = visualFixture("flow")
    escapedDiagram["diagram"] = ["nodes": [["id": "hostile --> syntax", "label": visualTerm("A\"|\n```mermaid", "甲")], ["id": "b", "label": visualTerm("B", "乙")]], "edges": [["from": "hostile --> syntax", "to": "b"]]]
    var escapedFormula = visualFixture("formula")
    escapedFormula["formula"] = ["expression": "a = ``` + b", "symbols": [], "steps": []]
    let portable = LFVisualTextExport.render(try visualBlocks([escapedTable, escapedDiagram, escapedFormula]), format: .markdown)
    check(portable.contains("A&#124;B") && portable.contains("&lt;tag&gt;<br>&#96;code&#96;") && portable.contains("#quot;") && portable.contains("#96;#96;#96;mermaid") && portable.contains("````text\na = ``` + b\n````") && !portable.contains("hostile --> syntax") && !portable.contains("A\"|\n```mermaid") && !portable.contains("<tag>"), "Portable formats must escape table pipes/newlines/ticks, diagram labels and generated IDs, and fence formulas without truncation")
    print("VISUAL_CHECK PASS portable-format escaping")
}

private func visualResponseContractChecks() async throws {
    let batch = LFNoteBatch(id: UUID(), inputs: [LFNoteInput(segmentID: "visual-regression-1", startTime: 0, endTime: 10, characterStart: 0, characterEnd: 4, english: "Data")], state: .running)
    let request = URLRequest(url: URL(string: "https://example.invalid/chat/completions")!)
    func object(_ visuals: Any?) throws -> [String: Any] {
        var notes = LFGeneratedNotes(englishNotes: "Scripted economics example.", chineseNotes: "预设计量示例。", keyTerms: [], sourceSegmentIDs: ["visual-regression-1"])
        notes.courseSummary = LFNotesSummary(englishNotes: "Course overview.", chineseNotes: "课程梳理。", keyTerms: [], mindMap: fixtureMindMap())
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(notes)) as! [String: Any]
        if let visuals {
            var summary = value["course_summary"] as! [String: Any]
            summary["visuals"] = visuals; value["course_summary"] = summary
        }
        return value
    }
    func decode(_ value: [String: Any]) throws -> LFGeneratedNotes {
        try LFNotesService.decodeResponse(visualHTTPEnvelope(value, request: request).0, for: batch, requireSummary: true, allowedVisualSourceIDs: ["visual-regression-1"])
    }
    let legacy = try decode(object(nil))
    check(legacy.courseSummary?.visuals == nil, "Existing 0.2 summaries without visuals must stay readable without fabricating diagrams")
    check(try decode(object(NSNull())).courseSummary?.visuals == nil, "Explicit null must retain optional legacy summary compatibility")
    check(try decode(object([])).courseSummary?.visuals?.isEmpty == true, "A valid source without useful chart material may have no visual blocks")
    for kind in ["table", "flow", "causal", "bar", "line", "scatter", "formula"] {
        let value = visualFixture(kind)
        check(try decode(object([value])).courseSummary?.visuals?.first?.kind.rawValue == kind, "Strict service response validation must accept each supported typed payload")
        var extra = value; extra["image_url"] = "https://example.invalid/untrusted.svg"
        await mustFail { _ = try decode(object([extra])) }
        var extraNull = value
        extraNull[kind == "table" ? "chart" : "table"] = NSNull()
        await mustFail { _ = try decode(object([extraNull])) }
        var unknownNested = value
        let payload = kind == "table" ? "table" : (kind == "flow" || kind == "causal" ? "diagram" : (kind == "formula" ? "formula" : "chart"))
        var nested = unknownNested[payload] as! [String: Any]; nested["unexpected"] = "ignored content must be rejected"
        unknownNested[payload] = nested
        await mustFail { _ = try decode(object([unknownNested])) }
    }
    let invalidVisualValues: [Any] = ["not an array", ["kind": "table"]]
    for invalidVisuals in invalidVisualValues {
        await mustFail { _ = try decode(object(invalidVisuals)) }
    }
    var invalidNumber = visualFixture("scatter")
    var chart = invalidNumber["chart"] as! [String: Any]
    chart["series"] = [["id": "bad", "label": visualTerm("Series", "系列"), "points": [["x": "NaN", "y": 1], ["x": 2, "y": 2]]]]
    invalidNumber["chart"] = chart
    await mustFail { _ = try decode(object([invalidNumber])) }
    let nonfinite = LFVisualBlock(id: "infinite", kind: .scatter, title: LFKeyTerm(english: "Data", chinese: "数据"), caption: LFKeyTerm(english: "Fixture", chinese: "夹具"), sourceSegmentIDs: ["visual-regression-1"], chart: LFVisualChart(xLabel: LFKeyTerm(english: "X", chinese: "横轴"), yLabel: LFKeyTerm(english: "Y", chinese: "纵轴"), series: [LFVisualSeries(id: "s", label: LFKeyTerm(english: "Series", chinese: "系列"), points: [LFVisualPoint(x: .nan, y: 1), LFVisualPoint(x: 2, y: .infinity)])]))
    await mustFail { try LFVisualBlock.validateBlocks([nonfinite]) }
    print("VISUAL_CHECK PASS strict-service seven-kinds/legacy/empty/unknown-keys/nonnumeric/nonfinite")
}

private func createEconomicsFixtures(root: URL, configuration: LFCloudConfiguration) async throws {
    let store = try LFLessonStore(rootURL: root)
    let regression = try await store.createLesson(title: "自动化测试 · 计量与统计图文（预设数据）")
    _ = try await store.setLectureLanguage(.chinese, for: regression.id)
    let first = LFConfirmedSegment(id: "visual-regression-1", startTime: 0, endTime: 45, english: "自动化教学示例，不是真实课堂结果。三名虚拟观测的学习时长（小时）与得分（分）分别为 (1,2)、(2,3)、(3,5)。估计顺序是观察样本、最小化残差平方和、核对假设。另一个课堂因果假设中，能力影响教育和工资，教育影响工资；这不是上述三点样本的因果估计。")
    _ = try await store.appendConfirmedSegments([first], to: regression.id)
    let mock = EconomicsHTTP()
    let service = LFNotesService(store: store, transport: { try await mock.call($0) }, keyProvider: { _ in "fixture-key-never-on-disk" })
    let opening = try await service.generatePending(lessonID: regression.id, configuration: configuration)
    check(opening.courseSummary?.visuals?.count == 3, "First economics passage must store the sample, workflow and hypothetical causal diagram together")
    _ = try await store.updateNote(lessonID: regression.id, noteID: opening.notes[0].id, english: "USER_EDIT: association is not causation.", chinese: "用户编辑：相关不等于因果。")
    let longTable = longEconomicsTable()["table"] as! [String: Any]
    let longRows = longTable["rows"] as! [[[String: String]]]
    let longSource = longRows.map { row in row.map { $0["english"]! + " / " + $0["chinese"]! }.joined(separator: "；") }.joined(separator: "\n")
    let secondText = "继续使用刚才同一组观测：(1小时,2分)、(2小时,3分)、(3小时,5分)。画散点图。x 均值是2，y均值是10/3；离差乘积和为3，x离差平方和为2。所以 OLS 斜率是 3/2=1.5 分/小时，截距是1/3分。相关关系本身不能证明因果。\n以下概念比较均为自动化预设原文，依次按行号、概念、定义、单位、用途和注意事项列出：\n" + longSource
    check(secondText.count < 8000, "The complete long-table evidence must fit its intended source batch")
    let second = LFConfirmedSegment(id: "visual-regression-2", startTime: 45, endTime: 90, english: secondText)
    _ = try await store.appendConfirmedSegments([second], to: regression.id)
    let complete = try await service.generatePending(lessonID: regression.id, configuration: configuration)
    let requests = await mock.requests
    check(requests.count == 2, "The regression fixture must use two real service rounds")
    let previousSummary = try summaryInContext(requestContext(requests[1]))
    check(previousSummary == opening.courseSummary, "Second visual generation must receive the exact first cumulative chart/table summary")
    check(complete.courseSummary?.visuals?.count == 6 && complete.notes[0].englishNotes.contains("USER_EDIT") && complete.courseSummaryThrough == 90, "A later formula, scatter and maximum-size comparison table must join the retained visuals without losing edits")
    let savedLongTable = complete.courseSummary?.visuals?.first(where: { $0.id == "econ-long-table" })?.table
    check(savedLongTable?.rows.count == 12 && savedLongTable?.columns.count == 6 && savedLongTable?.rows.last?.last?.english.contains("STRESS_ROW_12_END") == true, "The sixth visual must retain all twelve rows and six bilingual columns through the real service")
    let reopened = try LFLessonStore(rootURL: root)
    check(try await reopened.loadLesson(regression.id).courseSummary == complete.courseSummary, "All structured visuals must survive actual disk reload")
    let rebuildMock = EconomicsHTTP()
    let rebuild = LFNotesService(store: reopened, transport: { try await rebuildMock.call($0) }, keyProvider: { _ in "fixture" })
    let rebuilt = try await rebuild.generatePending(lessonID: regression.id, configuration: configuration, rebuildSummary: true)
    check(rebuilt.courseSummary == complete.courseSummary && rebuilt.notes == complete.notes && rebuilt.segments == complete.segments && rebuilt.batches == complete.batches, "Visual rebuild must be atomic and preserve edited notes, historical batches and source transcripts")
    for format in [LFExportFormat.markdown, .text] {
        let output = try String(contentsOf: await reopened.exportLesson(regression.id, format: format), encoding: .utf8)
        check(output.contains("样本数据表") && output.contains("混杂路径") && output.contains("β̂₁") && output.contains("USER_EDIT") && output.contains("visual-regression-2"), "Actual store exports must include all visual types, source IDs and manual corrections")
    }
    print("VISUAL_CHECK PASS real-service two-round cumulative/rebuild/disk/export/edit-preservation")

    // A damaged service response must never replace the last useful snapshot.
    _ = try await reopened.appendConfirmedSegments([LFConfirmedSegment(id: "visual-regression-3", startTime: 90, endTime: 100, english: "继续检查残差。")], to: regression.id)
    var invalid = visualFixture("table", source: "visual-regression-3")
    var invalidTable = invalid["table"] as! [String: Any]; invalidTable["rows"] = [[visualTerm("ragged", "缺列")]]; invalid["table"] = invalidTable
    let failingMock = FixedVisualHTTP(blocks: try JSONSerialization.data(withJSONObject: [invalid]))
    let failingService = LFNotesService(store: reopened, transport: { try await failingMock.call($0) }, keyProvider: { _ in "fixture" })
    await mustFail { _ = try await failingService.generatePending(lessonID: regression.id, configuration: configuration) }
    let retained = try await reopened.loadLesson(regression.id)
    check(retained.courseSummary == rebuilt.courseSummary && retained.notes == rebuilt.notes && retained.courseSummaryThrough == 90, "Malformed rich content must retain the complete previous cumulative snapshot and coverage")
    _ = try await reopened.cancelBatches(for: regression.id)
    let recoveryMock = EconomicsHTTP()
    let recovery = LFNotesService(store: reopened, transport: { try await recoveryMock.call($0) }, keyProvider: { _ in "fixture" })
    let recovered = try await recovery.generatePending(lessonID: regression.id, configuration: configuration)
    await mustFail { _ = try await failingService.generatePending(lessonID: regression.id, configuration: configuration, rebuildSummary: true) }
    let afterFailedRebuild = try await reopened.loadLesson(regression.id)
    check(afterFailedRebuild.courseSummary == recovered.courseSummary && afterFailedRebuild.notes == recovered.notes && afterFailedRebuild.batches == recovered.batches && afterFailedRebuild.segments == recovered.segments, "A malformed rebuilt visual must not partially replace a complete rich summary or its underlying saved course")
    _ = try await recovery.generatePending(lessonID: regression.id, configuration: configuration, rebuildSummary: true)
    _ = try await reopened.setRecordingState(.paused, for: regression.id)
    print("VISUAL_CHECK PASS malformed-progress/rebuild preserves prior snapshot and retry recovers")

    let outputLesson = try await reopened.createLesson(title: "自动化测试 · 经济趋势图文（预设数据）")
    _ = try await reopened.setLectureLanguage(.chinese, for: outputLesson.id)
    _ = try await reopened.appendConfirmedSegments([LFConfirmedSegment(id: "visual-output-1", startTime: 0, endTime: 45, english: "自动化课堂样本。某虚拟经济体2023、2024、2025年的产出分别为100、110、121亿元。用柱形图比较各年数值，用折线图表示随年份变化。所有数字均为预设教学数据。")], to: outputLesson.id)
    let outputMock = EconomicsHTTP()
    let outputService = LFNotesService(store: reopened, transport: { try await outputMock.call($0) }, keyProvider: { _ in "fixture" })
    let output = try await outputService.generatePending(lessonID: outputLesson.id, configuration: configuration)
    check(output.courseSummary?.visuals?.count == 2 && output.courseSummary?.visuals?.map(\.kind.rawValue) == ["bar", "line"], "Economics trends must provide separate bar and line representations of the same given numeric sample")
    _ = try await reopened.setRecordingState(.paused, for: outputLesson.id)
    try checkNoStoredKey(root: root)
    print("VISUAL_FIXTURE regression=\(regression.id.uuidString) output=\(outputLesson.id.uuidString)")
}

private func visualSourceCoverageChecks(root: URL, configuration: LFCloudConfiguration) async throws {
    let store = try LFLessonStore(rootURL: root)
    let lesson = try await store.createLesson(title: "Visual source coverage")
    let sources = (1...9).map { LFConfirmedSegment(id: "source-\($0)", startTime: Double($0 - 1) * 10, endTime: Double($0) * 10, english: "Confirmed classroom fact \($0).") }
    _ = try await store.appendConfirmedSegments(sources, to: lesson.id)
    for forbidden in ["source-9", "other-lesson-source"] {
        let mock = FixedVisualHTTP(blocks: try JSONSerialization.data(withJSONObject: [visualFixture("table", source: forbidden)]))
        let service = LFNotesService(store: store, transport: { try await mock.call($0) }, keyProvider: { _ in "fixture" })
        await mustFail { _ = try await service.generatePending(lessonID: lesson.id, configuration: configuration) }
        let saved = try await store.loadLesson(lesson.id)
        check(saved.notes.isEmpty && saved.courseSummary == nil, "A current-batch visual cannot borrow a source from a future batch or another lesson")
        check(await mock.requests.count == 1, "Invalid visual references must fail without entering a retry loop")
        _ = try await store.cancelBatches(for: lesson.id)
    }
    print("VISUAL_CHECK PASS real-service future/foreign-source rejection")
}

private func visualExportSnapshotChecks(root: URL) async throws {
    let store = try LFLessonStore(rootURL: root)
    let lesson = try await store.createLesson(title: "Export snapshot regression")
    _ = try await store.appendConfirmedSegments([LFConfirmedSegment(id: "snapshot-1", startTime: 0, endTime: 10, english: "Old observed sample.")], to: lesson.id)
    let batch = try await store.prepareNextBatch(for: lesson.id)!
    var generated = LFGeneratedNotes(englishNotes: "SNAPSHOT_OLD_NOTE", chineseNotes: "旧笔记", keyTerms: [], sourceSegmentIDs: ["snapshot-1"])
    generated.courseSummary = LFNotesSummary(englishNotes: "SNAPSHOT_OLD_SUMMARY", chineseNotes: "旧课程梳理", keyTerms: [], mindMap: fixtureMindMap(), visuals: try visualBlocks([visualFixture("table", source: "snapshot-1")]))
    let old = try await store.finishBatch(lessonID: lesson.id, batchID: batch.id, notes: generated)
    let snapshotA = try await store.exportLessonSnapshot(lesson.id, format: .text)
    _ = try await store.updateNote(lessonID: lesson.id, noteID: old.notes[0].id, english: "SNAPSHOT_NEW_NOTE", chinese: "新笔记")
    _ = try await store.appendConfirmedSegments([LFConfirmedSegment(id: "snapshot-2", startTime: 10, endTime: 20, english: "NEW_SOURCE_FOR_CHART: 2023=100, 2024=110, 2025=121 (100 million yuan).")], to: lesson.id)
    let replacement = LFNotesSummary(englishNotes: "SNAPSHOT_NEW_SUMMARY", chineseNotes: "新课程梳理", keyTerms: [], mindMap: fixtureMindMap(), visuals: try visualBlocks([visualFixture("bar", source: "snapshot-2")]))
    _ = try await store.updateCourseSummary(replacement, throughTime: 20, for: lesson.id)
    let snapshotB = try await store.exportLessonSnapshot(lesson.id, format: .text)
    let latestDiskText = try String(contentsOf: snapshotA.url, encoding: .utf8)
    check(snapshotA.url == snapshotB.url && latestDiskText == snapshotB.text, "The new export must replace the shared disk path while retaining an immutable old in-memory snapshot")
    check(snapshotA.text.contains("SNAPSHOT_OLD_NOTE") && snapshotA.text.contains("SNAPSHOT_OLD_SUMMARY") && !snapshotA.text.contains("SNAPSHOT_NEW_NOTE") && !snapshotA.text.contains("NEW_SOURCE_FOR_CHART"), "Snapshot A text must not change when the live lesson and shared export path change")
    check(snapshotA.lesson.notes == old.notes && snapshotA.lesson.courseSummary == old.courseSummary && snapshotA.lesson.segments.count == 1, "Snapshot A must keep exactly the lesson version that produced its text")
    check(snapshotB.text.contains("SNAPSHOT_NEW_NOTE") && snapshotB.text.contains("SNAPSHOT_NEW_SUMMARY") && snapshotB.text.contains("NEW_SOURCE_FOR_CHART") && snapshotB.text.contains("年度产出柱图"), "Snapshot B text must include the new notes, summary, source evidence and visual")
    check(snapshotB.lesson.courseSummary == replacement && snapshotB.lesson.notes[0].englishNotes == "SNAPSHOT_NEW_NOTE" && snapshotB.lesson.segments.last?.id == "snapshot-2" && snapshotB.lesson.courseSummary?.visuals?.first?.sourceSegmentIDs == ["snapshot-2"], "Snapshot B graphics and source references must come from the same new lesson as its text")
    print("VISUAL_CHECK PASS export-snapshot text+lesson consistency across shared-path overwrite")
}

private func optionalVisualUpdateChecks(root: URL, configuration: LFCloudConfiguration) async throws {
    let scenarios: [(String, [OptionalVisualReply], Bool, Bool)] = [
        ("missing", [.missing], false, false), ("null", [.null], false, false),
        ("empty", [.empty], true, false), ("invalid", [.invalid], false, true),
        ("empty-then-missing", [.empty, .missing], true, false)
    ]
    for rebuilding in [false, true] {
        for (name, replies, clears, fails) in scenarios {
            if !rebuilding && replies.count > 1 { continue }
            let store = try LFLessonStore(rootURL: root.appendingPathComponent("\(rebuilding)-\(name)", isDirectory: true))
            let lesson = try await store.createLesson(title: "Optional visual compatibility")
            let segments = (1...9).map { index in
                LFConfirmedSegment(id: "optional-\(index)", startTime: Double(index - 1) * 10,
                    endTime: Double(index) * 10, english: "Confirmed example \(index).")
            }
            _ = try await store.appendConfirmedSegments(segments, to: lesson.id)
            let baselineHTTP = OptionalVisualHTTP([.present])
            let baselineService = LFNotesService(store: store, transport: { try await baselineHTTP.call($0) }, keyProvider: { _ in "fixture" })
            let baseline = try await baselineService.generatePending(lessonID: lesson.id, configuration: configuration)
            check(baseline.courseSummary?.visuals?.first?.sourceSegmentIDs == ["optional-9"], "Compatibility fixture must end with a visual referring to the second batch")
            let edited = try await store.updateNote(lessonID: lesson.id, noteID: baseline.notes[0].id,
                english: "OPTIONAL_VISUAL_USER_EDIT", chinese: "保留用户编辑")
            if !rebuilding {
                _ = try await store.appendConfirmedSegments([LFConfirmedSegment(id: "optional-10", startTime: 90,
                    endTime: 100, english: "A new confirmed example.")], to: lesson.id)
            }
            let mock = OptionalVisualHTTP(replies)
            let service = LFNotesService(store: store, transport: { try await mock.call($0) }, keyProvider: { _ in "fixture" })
            if fails {
                await mustFail { _ = try await service.generatePending(lessonID: lesson.id, configuration: configuration, rebuildSummary: rebuilding) }
            } else {
                _ = try await service.generatePending(lessonID: lesson.id, configuration: configuration, rebuildSummary: rebuilding)
            }
            let saved = try await store.loadLesson(lesson.id)
            let requests = await mock.requests
            check(!requests.isEmpty, "Compatibility tests must exercise the real request path")
            check(saved.notes.first?.englishNotes == "OPTIONAL_VISUAL_USER_EDIT", "Legacy visual replies must preserve manually edited detailed notes")
            if fails {
                check(saved.courseSummary == edited.courseSummary && saved.notes == edited.notes,
                      "Invalid visual replies must preserve the last complete snapshot and all detailed notes")
            } else if clears {
                check(saved.courseSummary?.visuals?.isEmpty == true, "An explicitly empty visual collection must clear old visuals, including before a later omitted response")
            } else {
                check(saved.courseSummary?.visuals == baseline.courseSummary?.visuals, "Missing and null visuals must retain the previously saved collection")
            }
            if rebuilding {
                let firstContext = try requestContext(requests[0])
                check(try summaryInContext(firstContext) == nil, "A rebuild must not send old full-course diagrams into its first source batch")
                let firstInputs = firstContext["new_confirmed_segments"] as! [[String: Any]]
                check(!firstInputs.contains { $0["segmentID"] as? String == "optional-9" }, "Old retained diagram must reference a source not yet covered by the first rebuild batch")
                if !fails { check(requests.count == 2, "The compatibility rebuild must cover both source batches before committing") }
                check(saved.notes == edited.notes && saved.batches == edited.batches && saved.segments == edited.segments,
                      "Rebuild compatibility must not replace historical notes, batches or source text")
            }
            let reopened = try LFLessonStore(rootURL: store.rootURL)
            check(try await reopened.loadLesson(lesson.id).courseSummary == saved.courseSummary,
                  "Preserved or explicitly cleared visual state must survive reopening the store")
            print("VISUAL_CHECK PASS optional-visual \(rebuilding ? "rebuild" : "progressive")-\(name)")
        }
    }
    for reply in [OptionalVisualReply.missing, .null] {
        let store = try LFLessonStore(rootURL: root.appendingPathComponent("first-\(reply.rawValue)", isDirectory: true))
        let lesson = try await store.createLesson(title: "First legacy response")
        _ = try await store.appendConfirmedSegments([LFConfirmedSegment(id: "first", startTime: 0, endTime: 10,
            english: "A first confirmed passage.")], to: lesson.id)
        let mock = OptionalVisualHTTP([reply])
        let service = LFNotesService(store: store, transport: { try await mock.call($0) }, keyProvider: { _ in "fixture" })
        let saved = try await service.generatePending(lessonID: lesson.id, configuration: configuration)
        check(saved.courseSummary != nil && saved.courseSummary?.visuals == nil && saved.notes.count == 1,
              "The first legacy response must still work without inventing any visual collection")
    }
    print("VISUAL_CHECK PASS first legacy missing/null visual compatibility")
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
        try await visualContractChecks()
        try await visualResponseContractChecks()
        try await createEconomicsFixtures(root: root.appendingPathComponent("economics", isDirectory: true), configuration: config)
        try await visualSourceCoverageChecks(root: root.appendingPathComponent("visual-coverage", isDirectory: true), configuration: config)
        try await visualExportSnapshotChecks(root: root.appendingPathComponent("visual-export-snapshot", isDirectory: true))
        try await optionalVisualUpdateChecks(root: root.appendingPathComponent("optional-visual-update", isDirectory: true), configuration: config)
        try checkNoStoredKey(root: root)
        print("LectureFlow assertions passed: dedup/conflict, 8k splitting, restart, token race, stale HTTP, retry, rolling summary/context, accumulation/flush, legacy migration/rebuild, bounded bilingual mind map, Chinese source, prompt contract, atomic failure preservation, edit/audio/tree export preservation, isolation, key redaction. Scripted responses do not verify live AI or ASR quality.")
        if let uiFixtureRoot {
            try await createEconomicsFixtures(root: uiFixtureRoot, configuration: config)
            // Keep the original water-cycle lesson newest, preserving its existing
            // default-selection regression while UI tests explicitly pick economics.
            try await createUIFixture(root: uiFixtureRoot, configuration: config)
        }
    }
}
